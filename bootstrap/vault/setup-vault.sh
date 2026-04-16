#!/bin/bash
set -e

KEYS_FILE="$(dirname "$0")/vault-keys.json"

if [ ! -f "$KEYS_FILE" ]; then
  echo "ERROR: vault-keys.json not found"
  exit 1
fi

export VAULT_ADDR=https://vault.localhost:8443
export VAULT_TOKEN=$(jq -r '.root_token' "$KEYS_FILE")
export VAULT_CACERT=/tmp/vault-ca.crt

# ดึง CA cert
kubectl get secret vault-tls -n vault \
  -o jsonpath='{.data.ca\.crt}' | base64 -d >/tmp/vault-ca.crt

echo "=== Enable KV secret engine ==="
vault secrets enable -path=secret kv-v2 || echo "already enabled"

echo "=== Create policies ==="
vault policy write ci-cd-policy - <<'POLICY'
path "secret/data/*" {
  capabilities = ["create", "update", "patch", "read"]
}
path "secret/metadata/*" {
  capabilities = ["read", "list"]
}
POLICY

vault policy write eso-policy - <<'POLICY'
path "secret/data/demo-app/*" {
  capabilities = ["read"]
}
POLICY

echo "=== Enable AppRole auth ==="
vault auth enable approle || echo "already enabled"

vault write auth/approle/role/github-actions \
  token_policies="ci-cd-policy" \
  token_ttl=30m \
  token_max_ttl=1h \
  secret_id_ttl=10m \
  secret_id_num_uses=1

echo "=== Enable Kubernetes auth ==="
vault auth enable kubernetes || echo "already enabled"

vault write auth/kubernetes/config \
  kubernetes_host="https://kubernetes.default.svc:443"

vault write auth/kubernetes/role/eso-role \
  bound_service_account_names=external-secrets \
  bound_service_account_namespaces=external-secrets \
  policies=eso-policy \
  ttl=24h

echo "=== Enable Audit log ==="
vault audit enable file \
  file_path=/vault/logs/audit.log || echo "already enabled"

echo "=== Create initial secrets ==="
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

CA_BASE64=$(base64 </tmp/vault-ca.crt)

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
