#!/usr/bin/env bash
# Unseal all 3 Vault pods using keys from vault-keys.json.
# Run after any cluster restart or pod eviction.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE=vault
KEYS_FILE="$SCRIPT_DIR/vault-keys.json"

if [ ! -f "$KEYS_FILE" ]; then
  echo "ERROR: $KEYS_FILE not found — run reinstall.sh first" >&2
  exit 1
fi

K1=$(jq -r '.unseal_keys_b64[0]' "$KEYS_FILE")
K2=$(jq -r '.unseal_keys_b64[1]' "$KEYS_FILE")
K3=$(jq -r '.unseal_keys_b64[2]' "$KEYS_FILE")

unseal_pod() {
  local pod=$1

  echo "==> $pod: checking seal status..."
  STATUS=$(kubectl exec -n "$NAMESPACE" "$pod" -- \
    env VAULT_SKIP_VERIFY=true vault status 2>/dev/null) || true

  if echo "$STATUS" | grep -q "Sealed.*false"; then
    echo "    already unsealed, skipping."
    return 0
  fi

  echo "    sealed — unsealing with 3 keys..."
  for key in "$K1" "$K2" "$K3"; do
    for attempt in $(seq 1 10); do
      OUT=$(kubectl exec -n "$NAMESPACE" "$pod" -- \
        env VAULT_SKIP_VERIFY=true vault operator unseal "$key" 2>&1) || true
      if echo "$OUT" | grep -qiE "not initialized|error making|400|500"; then
        echo "    attempt $attempt: $(echo "$OUT" | grep -i 'error\|not init' | head -1), retrying in 5s..."
        sleep 5
      else
        echo "$OUT" | grep -E "Sealed|Progress" || true
        break
      fi
    done
  done

  echo "    done."
}

for pod in vault-0 vault-1 vault-2; do
  unseal_pod "$pod"
done

echo ""
echo "==> Pod status:"
kubectl get pods -n "$NAMESPACE"
