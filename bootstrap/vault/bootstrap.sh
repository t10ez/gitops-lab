#!/bin/bash
set -e

LAB_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
VAULT_VERSION="0.29.1"

echo "================================================"
echo " Vault Production Bootstrap"
echo " Lab dir: $LAB_DIR"
echo "================================================"

echo ""
echo ">>> Step 1: Creating TLS certificate..."
kubectl apply -f "$LAB_DIR/bootstrap/vault/certificate.yaml"
kubectl wait certificate vault-tls \
  -n vault \
  --for=condition=Ready \
  --timeout=60s
echo "TLS cert ready"

echo ""
echo ">>> Step 2: Installing Vault $VAULT_VERSION..."
helm repo add hashicorp https://helm.releases.hashicorp.com --force-update
helm repo update hashicorp

kubectl create namespace vault \
  --dry-run=client -o yaml | kubectl apply -f -

helm upgrade --install vault hashicorp/vault \
  --version "$VAULT_VERSION" \
  --namespace vault \
  --values "$LAB_DIR/bootstrap/vault/values.yaml" \
  --wait --timeout 10m

kubectl apply -f "$LAB_DIR/bootstrap/vault/ingressroute.yaml"

echo ""
echo ">>> Step 3: Initializing Vault..."
sleep 5

if [ ! -f "$LAB_DIR/bootstrap/vault/vault-keys.json" ]; then
  kubectl exec vault-0 -n vault -- vault operator init \
    -key-shares=5 \
    -key-threshold=3 \
    -format=json >"$LAB_DIR/bootstrap/vault/vault-keys.json"
  echo "Init complete"
else
  echo "vault-keys.json exists, skipping init"
fi

echo ""
echo ">>> Step 4: Unsealing vault-0..."
"$LAB_DIR/bootstrap/vault/unseal.sh"

echo ""
echo ">>> Step 5: Joining Raft cluster..."
ROOT_TOKEN=$(jq -r '.root_token' \
  "$LAB_DIR/bootstrap/vault/vault-keys.json")

for pod in vault-1 vault-2; do
  kubectl exec $pod -n vault -- \
    vault operator raft join \
    https://vault-0.vault-internal:8200 \
    2>/dev/null || echo "$pod already joined"
done

"$LAB_DIR/bootstrap/vault/unseal.sh"

echo ""
echo ">>> Step 6: Setting up Vault..."
"$LAB_DIR/bootstrap/vault/setup-vault.sh"

echo ""
echo "================================================"
echo " Bootstrap Complete!"
echo "================================================"
echo ""
echo "Next steps:"
echo "  1. ตั้งค่า GitHub Secrets ตาม output ด้านบน"
echo "  2. Setup Self-hosted Runner:"
echo "     Settings → Actions → Runners"
echo "  3. Setup Environment protection สำหรับ prod:"
echo "     Settings → Environments → prod"
echo "================================================"
