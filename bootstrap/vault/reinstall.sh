#!/usr/bin/env bash
# Reinstall Vault in HA Raft mode (3 replicas) on a kind cluster.
# Run from anywhere — paths are resolved relative to this script.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE=vault
RELEASE=vault
CHART=hashicorp/vault
VALUES="$SCRIPT_DIR/values.yaml"
CERT_MANIFEST="$SCRIPT_DIR/certificate.yaml"
KEYS_FILE="$SCRIPT_DIR/vault-keys.json"
LOCAL_PORT=8300  # port-forward target on localhost

export VAULT_ADDR="https://127.0.0.1:${LOCAL_PORT}"
export VAULT_SKIP_VERIFY=true

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

pf_start() {
  local pod=$1
  kubectl port-forward -n "$NAMESPACE" "pod/$pod" "${LOCAL_PORT}:8200" &
  PF_PID=$!
  # Give the tunnel a moment to open
  sleep 2
}

pf_stop() {
  kill "${PF_PID:-}" 2>/dev/null || true
  sleep 1
}

wait_vault_api() {
  echo "  waiting for Vault API at $VAULT_ADDR..."
  for i in $(seq 1 30); do
    vault status 2>/dev/null && return 0 || true
    sleep 2
  done
  echo "ERROR: Vault API did not become available" >&2
  return 1
}

unseal_via_exec() {
  local pod=$1
  echo "  unsealing $pod via kubectl exec..."
  kubectl exec -n "$NAMESPACE" "$pod" -- \
    env VAULT_SKIP_VERIFY=true vault operator unseal "$K1"
  kubectl exec -n "$NAMESPACE" "$pod" -- \
    env VAULT_SKIP_VERIFY=true vault operator unseal "$K2"
  kubectl exec -n "$NAMESPACE" "$pod" -- \
    env VAULT_SKIP_VERIFY=true vault operator unseal "$K3"
}

wait_pod_exec_ready() {
  local pod=$1
  echo "  waiting for $pod to accept exec..."
  for i in $(seq 1 30); do
    if kubectl exec -n "$NAMESPACE" "$pod" -- \
        env VAULT_SKIP_VERIFY=true vault status 2>/dev/null \
        | grep -q "Initialized"; then
      return 0
    fi
    sleep 4
  done
  echo "ERROR: $pod did not become exec-ready in time" >&2
  return 1
}

# ---------------------------------------------------------------------------
# 1. Uninstall existing release
# ---------------------------------------------------------------------------
echo "==> [1/7] Uninstalling existing Vault release..."
helm uninstall "$RELEASE" -n "$NAMESPACE" 2>/dev/null || true

echo "     Deleting PVCs..."
kubectl delete pvc -n "$NAMESPACE" \
  -l app.kubernetes.io/name=vault --ignore-not-found

echo "     Deleting old TLS secret..."
kubectl delete secret vault-tls -n "$NAMESPACE" --ignore-not-found

# ---------------------------------------------------------------------------
# 2. Apply cert-manager Certificate, wait for Ready
# ---------------------------------------------------------------------------
echo "==> [2/7] Applying TLS certificate..."
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f "$CERT_MANIFEST"
kubectl wait --for=condition=Ready certificate/vault-tls \
  -n "$NAMESPACE" --timeout=90s
echo "     Certificate is Ready."

# ---------------------------------------------------------------------------
# 3. Install Vault via Helm
# ---------------------------------------------------------------------------
echo "==> [3/7] Installing Vault (hashicorp/vault)..."
helm repo add hashicorp https://helm.releases.hashicorp.com 2>/dev/null || true
helm repo update
helm install "$RELEASE" "$CHART" \
  -n "$NAMESPACE" \
  --create-namespace \
  -f "$VALUES"

# ---------------------------------------------------------------------------
# 4. Init Vault on vault-0
# ---------------------------------------------------------------------------
echo "==> [4/7] Initializing Vault on vault-0..."
# vault-0 starts in an uninitialized state; its container runs but the
# readiness probe fails until it is initialized + unsealed.
echo "  waiting for vault-0 container to start..."
for i in $(seq 1 40); do
  PHASE=$(kubectl get pod vault-0 -n "$NAMESPACE" \
    -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
  [ "$PHASE" = "Running" ] && break
  echo "  phase=$PHASE, retrying ($i/40)..."
  sleep 5
done

pf_start vault-0
trap 'pf_stop' EXIT

wait_vault_api

vault operator init \
  -key-shares=5 \
  -key-threshold=3 \
  -format=json > "$KEYS_FILE"
echo "  Keys saved to $KEYS_FILE"

K1=$(jq -r '.unseal_keys_b64[0]' "$KEYS_FILE")
K2=$(jq -r '.unseal_keys_b64[1]' "$KEYS_FILE")
K3=$(jq -r '.unseal_keys_b64[2]' "$KEYS_FILE")

# ---------------------------------------------------------------------------
# 5. Unseal vault-0 (via port-forward already open)
# ---------------------------------------------------------------------------
echo "==> [5/7] Unsealing vault-0..."
vault operator unseal "$K1"
vault operator unseal "$K2"
vault operator unseal "$K3"

pf_stop
trap - EXIT

# ---------------------------------------------------------------------------
# 6. Unseal vault-1 and vault-2 via kubectl exec
# ---------------------------------------------------------------------------
echo "==> [6/7] Unsealing vault-1 and vault-2..."
for pod in vault-1 vault-2; do
  wait_pod_exec_ready "$pod"
  unseal_via_exec "$pod"
  echo "  $pod unsealed."
done

# ---------------------------------------------------------------------------
# 7. Verify Raft cluster
# ---------------------------------------------------------------------------
echo "==> [7/7] Verifying Raft peers..."
pf_start vault-0
trap 'pf_stop' EXIT

export VAULT_TOKEN=$(jq -r '.root_token' "$KEYS_FILE")
vault operator raft list-peers

pf_stop
trap - EXIT

echo ""
echo "==> Vault HA cluster is ready."
echo "    Unseal keys + root token: $KEYS_FILE"
echo "    (vault-keys.json is gitignored — do not commit it)"
