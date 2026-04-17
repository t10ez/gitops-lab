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

# Vault ใช้ TLS ด้วย cert จาก cert-manager (lab CA)
# ต้อง skip verify เพราะ CA ไม่ใช่ public trust
vault_status() {
  # vault status exits 2 when sealed — || true prevents pipefail from breaking pipes
  kubectl exec -n "$NAMESPACE" "$1" -- \
    env VAULT_SKIP_VERIFY=true vault status 2>/dev/null || true
}

vault_unseal() {
  kubectl exec -n "$NAMESPACE" "$1" -- \
    env VAULT_SKIP_VERIFY=true vault operator unseal "$2" 2>&1
}

unseal_pod() {
  local pod=$1

  echo "==> $pod: checking seal status..."

  # รอ vault process พร้อมรับ connection ก่อน
  local ready_attempts=0
  until vault_status "$pod" | grep -q "Initialized"; do
    ready_attempts=$((ready_attempts + 1))
    if [ $ready_attempts -ge 24 ]; then
      echo "    ERROR: $pod ไม่ตอบสนองหลัง 120s" >&2
      return 1
    fi
    echo "    รอ $pod พร้อม... (${ready_attempts}/24)"
    sleep 5
  done

  if vault_status "$pod" | grep -q "Sealed.*false"; then
    echo "    already unsealed, skipping."
    return 0
  fi

  echo "    sealed — applying 3 unseal keys..."

  for key in "$K1" "$K2" "$K3"; do
    local attempt=0
    while true; do
      attempt=$((attempt + 1))
      if [ $attempt -gt 10 ]; then
        echo "    ERROR: หมด retry สำหรับ key หนึ่งใน $pod" >&2
        return 1
      fi

      OUT=$(vault_unseal "$pod" "$key") || true

      if echo "$OUT" | grep -qiE "connection refused|i/o timeout|not initialized"; then
        echo "    attempt $attempt: pod ยังไม่พร้อม, รอ 5s..."
        sleep 5
        continue
      fi

      if echo "$OUT" | grep -qiE "error making api request|500"; then
        echo "    attempt $attempt: API error, รอ 5s..."
        sleep 5
        continue
      fi

      echo "$OUT" | grep -E "Sealed|Progress" || true
      break
    done
  done

  sleep 2
  if vault_status "$pod" | grep -q "Sealed.*false"; then
    echo "    unsealed successfully."
  else
    local progress
    progress=$(vault_status "$pod" | grep "Unseal Progress" || echo "unknown")
    echo "    WARNING: ยังไม่ unseal ($progress) — script จะ retry รอบสอง"
    return 2
  fi
}

# รอบแรก
failed_pods=()
for pod in vault-0 vault-1 vault-2; do
  unseal_pod "$pod" || failed_pods+=("$pod")
done

# รอบสอง: retry เฉพาะ pod ที่ยังค้าง (แก้ปัญหา nonce reset กลางคัน)
if [ ${#failed_pods[@]} -gt 0 ]; then
  echo ""
  echo "==> Retry รอบสอง: ${failed_pods[*]}"
  for pod in "${failed_pods[@]}"; do
    unseal_pod "$pod" || echo "WARNING: $pod ยังไม่ unseal หลัง retry"
  done
fi

echo ""
echo "==> Pod status:"
kubectl get pods -n "$NAMESPACE"
