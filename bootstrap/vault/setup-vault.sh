#!/bin/bash
# Flow การทำงานของ Vault ↔ ESO (External Secrets Operator)
#
#  ┌──────────────────────────────────────────────────────────────┐
#  │  Vault (namespace: vault)                                    │
#  │   └─ KV-v2 secret engine at path "secret/"                  │
#  │        └─ secret/demo-app/{dev,staging,prod}                 │
#  └────────────────────────┬─────────────────────────────────────┘
#                           │ Kubernetes auth (JWKS จาก kube API)
#                           │
#  ┌────────────────────────▼─────────────────────────────────────┐
#  │  ESO (namespace: external-secrets)                           │
#  │   ├─ ServiceAccount: external-secrets  ← bound กับ eso-role  │
#  │   ├─ ClusterSecretStore               ← ชี้ไปหา Vault addr   │
#  │   └─ ExternalSecret (ต่อ namespace)   ← map path → k8s secret│
#  └────────────────────────┬─────────────────────────────────────┘
#                           │ สร้าง/sync
#                           ▼
#                  Kubernetes Secret (ใช้งานใน Pod ได้ปกติ)
#
# ขั้นตอนการ authenticate ของ ESO เข้า Vault:
#   1. ESO pod ใช้ ServiceAccount token ของตัวเอง
#   2. ส่ง token ไปที่ Vault endpoint: POST /v1/auth/kubernetes/login
#   3. Vault ตรวจสอบ token กับ Kubernetes TokenReview API
#   4. ถ้าผ่าน → Vault ออก short-lived token (ttl=24h) ตาม eso-policy
#   5. ESO ใช้ token นั้นอ่าน secret จาก Vault แล้ว sync ลง k8s Secret
set -e

KEYS_FILE="$(dirname "$0")/vault-keys.json"

if [ ! -f "$KEYS_FILE" ]; then
  echo "ERROR: vault-keys.json not found"
  exit 1
fi

# ใช้ port-forward ตรงไปที่ vault-0 แทน ingress
# (Traefik serve cert ของตัวเอง ไม่ใช่ vault cert → TLS verify fail)
LOCAL_PORT=8300
export VAULT_ADDR=https://127.0.0.1:${LOCAL_PORT}
export VAULT_TOKEN=$(jq -r '.root_token' "$KEYS_FILE")
export VAULT_SKIP_VERIFY=true

kubectl port-forward -n vault pod/vault-0 "${LOCAL_PORT}:8200" &
PF_PID=$!
trap 'kill "${PF_PID}" 2>/dev/null || true' EXIT
sleep 2

echo "=== Enable KV secret engine ==="
# ESO จะอ่าน secret จาก path นี้ผ่าน ClusterSecretStore
vault secrets enable -path=secret kv-v2 || echo "already enabled"

echo "=== Create policies ==="
# ci-cd-policy: ใช้โดย GitHub Actions (AppRole) — สิทธิ์เขียน/อ่านทุก path
vault policy write ci-cd-policy - <<'POLICY'
path "secret/data/*" {
  capabilities = ["create", "update", "patch", "read"]
}
path "secret/metadata/*" {
  capabilities = ["read", "list"]
}
POLICY

# eso-policy: ใช้โดย ESO — สิทธิ์อ่านอย่างเดียว เฉพาะ demo-app
# Policy นี้จะถูก attach ให้ eso-role ด้านล่าง
vault policy write eso-policy - <<'POLICY'
path "secret/data/demo-app/*" {
  capabilities = ["read"]
}
POLICY

echo "=== Enable AppRole auth ==="
# AppRole ใช้สำหรับ GitHub Actions CI/CD pipeline (ไม่เกี่ยวกับ ESO)
vault auth enable approle || echo "already enabled"

vault write auth/approle/role/github-actions \
  token_policies="ci-cd-policy" \
  token_ttl=30m \
  token_max_ttl=1h \
  secret_id_ttl=10m \
  secret_id_num_uses=1

echo "=== Enable Kubernetes auth ==="
# Kubernetes auth คือช่องทางที่ ESO ใช้ login เข้า Vault
# Vault จะ verify token โดยโทรหา Kubernetes TokenReview API
vault auth enable kubernetes || echo "already enabled"

vault write auth/kubernetes/config \
  kubernetes_host="https://kubernetes.default.svc:443"

# eso-role: กำหนดว่า ServiceAccount ไหนใน namespace ไหนถึงจะ login ได้
# bound_service_account_names ต้องตรงกับ SA ที่ ESO ใช้งานจริง
# ClusterSecretStore จะอ้างอิง role ชื่อ "eso-role" นี้ใน spec.provider.vault.auth.kubernetes
vault write auth/kubernetes/role/eso-role \
  bound_service_account_names=external-secrets \
  bound_service_account_namespaces=external-secrets \
  policies=eso-policy \
  ttl=24h

echo "=== Enable Audit log ==="
vault audit enable file \
  file_path=/vault/logs/audit.log || echo "already enabled"

echo "=== Create initial secrets ==="
# Secret เหล่านี้คือข้อมูลที่ ESO จะดึงไปสร้างเป็น Kubernetes Secret
# ExternalSecret ใน namespace demo-{dev,staging,prod} จะ map path เหล่านี้
vault kv put secret/demo-app/dev \
  DATABASE_URL="postgres://dev:devpass@db:5432/devdb" \
  API_KEY="dev-api-key-12345"

vault kv put secret/demo-app/staging \
  DATABASE_URL="postgres://stg:stgpass@db:5432/stgdb" \
  API_KEY="staging-api-key-67890"

vault kv put secret/demo-app/prod \
  DATABASE_URL="postgres://prod:prodpass@db:5432/proddb" \
  API_KEY="prod-api-key-99999"

echo ""
echo "=== GitHub Actions Setup ==="
ROLE_ID=$(vault read -format=json \
  auth/approle/role/github-actions/role-id \
  | jq -r '.data.role_id')

CA_BASE64=$(kubectl get secret vault-tls -n vault \
  -o jsonpath='{.data.ca\.crt}')

echo "=============================="
echo " Setup Complete!"
echo "=============================="
echo ""
echo "เพิ่ม GitHub Secrets:"
echo "  VAULT_ADDR    = https://vault.localhost:8443"
echo "  VAULT_ROLE_ID = $ROLE_ID"
echo "  VAULT_CA_CERT = $CA_BASE64"
echo ""
echo "IMPORTANT: อย่า commit vault-keys.json!"
echo "=============================="
