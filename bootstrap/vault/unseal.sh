#!/bin/bash
set -e

KEYS_FILE="$(dirname "$0")/vault-keys.json"

if [ ! -f "$KEYS_FILE" ]; then
  echo "ERROR: vault-keys.json not found"
  exit 1
fi

echo "=== Unsealing Vault pods ==="

for pod in vault-0 vault-1 vault-2; do
  echo "Checking $pod..."

  kubectl wait pod $pod -n vault \
    --for=condition=Ready \
    --timeout=60s 2>/dev/null || continue

  SEALED=$(kubectl exec $pod -n vault -- \
    vault status -format=json 2>/dev/null \
    | jq -r '.sealed' 2>/dev/null || echo "true")

  if [ "$SEALED" = "false" ]; then
    echo "$pod: already unsealed"
    continue
  fi

  echo "$pod: unsealing..."
  for i in 0 1 2; do
    KEY=$(jq -r ".unseal_keys_b64[$i]" "$KEYS_FILE")
    kubectl exec $pod -n vault -- \
      vault operator unseal "$KEY" >/dev/null
  done
  echo "$pod: unsealed"
done

echo ""
echo "=== Vault Status ==="
kubectl get pods -n vault
