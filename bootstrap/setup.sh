#!/usr/bin/env bash
# bootstrap/setup.sh — ติดตั้ง GitOps Lab environment ครบวงจร
#
# Usage:
#   ./bootstrap/setup.sh                   # Full setup (รวม monitoring)
#   ./bootstrap/setup.sh --skip-monitoring # ข้าม monitoring stack
#   ./bootstrap/setup.sh --skip-apps       # ไม่ deploy ArgoCD app-of-apps
#
# Prerequisites: kind, kubectl, helm, jq
set -euo pipefail

# ─── Versions ────────────────────────────────────────────────────────────────
CERT_MANAGER_VERSION="v1.16.3"
TRAEFIK_CHART_VERSION="32.1.0"
VAULT_CHART_VERSION="0.29.1"
ESO_CHART_VERSION="0.12.1"
ARGOCD_CHART_VERSION="7.8.23"
KUBE_PROMETHEUS_CHART_VERSION="67.9.0"
LOKI_CHART_VERSION="6.28.0"
PROMTAIL_CHART_VERSION="6.16.6"

# ─── Flags ───────────────────────────────────────────────────────────────────
SKIP_MONITORING=false
SKIP_APPS=false

for arg in "$@"; do
  case $arg in
  --skip-monitoring) SKIP_MONITORING=true ;;
  --skip-apps) SKIP_APPS=true ;;
  --help | -h)
    sed -n '/^# Usage/,/^$/p' "$0" | sed 's/^# //'
    exit 0
    ;;
  esac
done

# ─── Paths ───────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# ─── Helpers ─────────────────────────────────────────────────────────────────
log() {
  echo ""
  echo "━━━ $* ━━━"
}
info() { echo "    ▶ $*"; }
ok() { echo "    ✓ $*"; }

require_cmd() {
  command -v "$1" &>/dev/null || {
    echo "ERROR: '$1' not found — please install it first." >&2
    exit 1
  }
}

# ─── Prerequisite check ──────────────────────────────────────────────────────
log "Checking prerequisites"
for cmd in kind kubectl helm jq; do
  require_cmd "$cmd"
  ok "$cmd found"
done

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║           GitOps Lab — Bootstrap Setup                  ║"
echo "║  KinD → cert-manager → Traefik → Vault → ESO → ArgoCD  ║"
if [ "$SKIP_MONITORING" = "false" ]; then
  echo "║              → Prometheus + Grafana + Loki               ║"
fi
echo "╚══════════════════════════════════════════════════════════╝"
echo ""

# ─── Phase 1: KinD Cluster ───────────────────────────────────────────────────
log "Phase 1: KinD Cluster"

if kind get clusters 2>/dev/null | grep -q "^platform-lab$"; then
  ok "Cluster 'platform-lab' already exists, skipping creation"
else
  info "Creating KinD cluster (4 nodes)..."
  kind create cluster --config "$LAB_DIR/bootstrap/kind/kind-phase1.yaml"
  ok "KinD cluster created"
fi

kubectl cluster-info --context kind-platform-lab
kubectl config use-context kind-platform-lab

# ─── Phase 2: cert-manager ───────────────────────────────────────────────────
log "Phase 2: cert-manager $CERT_MANAGER_VERSION"

helm repo add jetstack https://charts.jetstack.io --force-update
helm repo update jetstack

kubectl create namespace cert-manager --dry-run=client -o yaml | kubectl apply -f -

helm upgrade --install cert-manager jetstack/cert-manager \
  --version "$CERT_MANAGER_VERSION" \
  --namespace cert-manager \
  --values "$LAB_DIR/bootstrap/cert-manager/values.yaml" \
  --wait --timeout 5m

info "Waiting for cert-manager webhook to be ready..."
kubectl wait deployment cert-manager-webhook \
  -n cert-manager \
  --for=condition=Available \
  --timeout=120s
ok "cert-manager ready"

info "Applying ClusterIssuers (selfsigned + lab-ca)..."
# Retry เพราะ webhook อาจยังไม่ sync CRD ทันที
for i in 1 2 3; do
  kubectl apply -f "$LAB_DIR/bootstrap/cert-manager/cluster-issuer.yaml" && break
  info "Retry $i/3 — รอ webhook..."
  sleep 10
done

info "Waiting for lab-ca Certificate to be ready..."
kubectl wait certificate lab-ca \
  -n cert-manager \
  --for=condition=Ready \
  --timeout=120s
ok "lab-ca Certificate ready"

# ─── Phase 3: Traefik ────────────────────────────────────────────────────────
log "Phase 3: Traefik $TRAEFIK_CHART_VERSION (Ingress Controller)"

helm repo add traefik https://traefik.github.io/charts --force-update
helm repo update traefik

kubectl create namespace traefik --dry-run=client -o yaml | kubectl apply -f -

helm upgrade --install traefik traefik/traefik \
  --version "$TRAEFIK_CHART_VERSION" \
  --namespace traefik \
  --values "$LAB_DIR/bootstrap/traefik/traefik-values.yaml" \
  --wait --timeout 5m

ok "Traefik ready — dashboard: http://traefik.localhost:8080"

# ─── Phase 4: Vault ──────────────────────────────────────────────────────────
log "Phase 4: Vault $VAULT_CHART_VERSION (HA Raft, 3 replicas)"

kubectl create namespace vault --dry-run=client -o yaml | kubectl apply -f -

"$LAB_DIR/bootstrap/vault/bootstrap.sh"

ok "Vault ready — UI: https://vault.localhost:8443"

# ─── Phase 5: External Secrets Operator ──────────────────────────────────────
log "Phase 5: External Secrets Operator $ESO_CHART_VERSION"

helm repo add external-secrets https://charts.external-secrets.io --force-update
helm repo update external-secrets

kubectl create namespace external-secrets --dry-run=client -o yaml | kubectl apply -f -

helm upgrade --install external-secrets external-secrets/external-secrets \
  --version "$ESO_CHART_VERSION" \
  --namespace external-secrets \
  --values "$LAB_DIR/bootstrap/external-secrets/values.yaml" \
  --wait --timeout 5m

info "Waiting for ESO webhook..."
kubectl wait deployment external-secrets-webhook \
  -n external-secrets \
  --for=condition=Available \
  --timeout=120s

info "Applying ClusterSecretStore (Vault backend)..."
for i in 1 2 3; do
  kubectl apply -f "$LAB_DIR/bootstrap/external-secrets/cluster-secret-store.yaml" && break
  info "Retry $i/3 — รอ ESO CRDs..."
  sleep 10
done

ok "ESO ready — ClusterSecretStore: vault-backend"

# ─── Phase 6: ArgoCD ─────────────────────────────────────────────────────────
log "Phase 6: ArgoCD $ARGOCD_CHART_VERSION"

helm repo add argo https://argoproj.github.io/argo-helm --force-update
helm repo update argo

kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -

helm upgrade --install argocd argo/argo-cd \
  --version "$ARGOCD_CHART_VERSION" \
  --namespace argocd \
  --values "$LAB_DIR/bootstrap/argocd/values.yaml" \
  --wait --timeout 10m

info "Applying ArgoCD project and IngressRoute..."
kubectl apply -f "$LAB_DIR/bootstrap/argocd/project.yaml"
kubectl apply -f "$LAB_DIR/bootstrap/argocd/ingressroute.yaml"

ok "ArgoCD ready — UI: http://argocd.localhost:8080"
info "Default login: admin / $(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)"

# ─── Phase 7: App-of-Apps ────────────────────────────────────────────────────
if [ "$SKIP_APPS" = "false" ]; then
  log "Phase 7: ArgoCD App-of-Apps (GitOps)"

  kubectl apply -f "$LAB_DIR/gitops/apps/app-of-apps.yaml"
  ok "App-of-Apps applied — ArgoCD จะ sync applicationsets อัตโนมัติ"
else
  info "Phase 7: ข้าม App-of-Apps (--skip-apps)"
fi

# ─── Phase 8: Monitoring (optional) ──────────────────────────────────────────
if [ "$SKIP_MONITORING" = "false" ]; then
  log "Phase 8: Monitoring Stack (Prometheus + Grafana + Loki)"

  helm repo add prometheus-community https://prometheus-community.github.io/helm-charts --force-update
  helm repo add grafana https://grafana.github.io/helm-charts --force-update
  helm repo update prometheus-community grafana

  kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -

  info "Installing kube-prometheus-stack..."
  helm upgrade --install monitoring prometheus-community/kube-prometheus-stack \
    --version "$KUBE_PROMETHEUS_CHART_VERSION" \
    --namespace monitoring \
    --values "$LAB_DIR/bootstrap/monitoring/monitoring-values.yaml" \
    --wait --timeout 15m

  info "Installing Loki..."
  helm upgrade --install loki grafana/loki \
    --version "$LOKI_CHART_VERSION" \
    --namespace monitoring \
    --values "$LAB_DIR/bootstrap/monitoring/loki-values.yaml" \
    --wait --timeout 10m

  info "Installing Promtail..."
  helm upgrade --install promtail grafana/promtail \
    --version "$PROMTAIL_CHART_VERSION" \
    --namespace monitoring \
    --values "$LAB_DIR/bootstrap/monitoring/promtail-values.yaml" \
    --wait --timeout 5m

  ok "Monitoring ready — Grafana: http://grafana.localhost:8080 (admin/admin)"
else
  info "Phase 8: ข้าม Monitoring (--skip-monitoring)"
fi

# ─── Summary ─────────────────────────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║               Setup Complete!                           ║"
echo "╠══════════════════════════════════════════════════════════╣"
echo "║  Service       URL                              Port    ║"
echo "║  ──────────── ─────────────────────────────── ──────── ║"
echo "║  Traefik       http://traefik.localhost          :8080  ║"
echo "║  ArgoCD        http://argocd.localhost            :8080  ║"
echo "║  Vault UI      https://vault.localhost            :8443  ║"
if [ "$SKIP_MONITORING" = "false" ]; then
  echo "║  Grafana       http://grafana.localhost           :8080  ║"
fi
echo "╠══════════════════════════════════════════════════════════╣"
echo "║  Next Steps:                                             ║"
echo "║  1. เพิ่ม GitHub Secrets ตาม output ของ setup-vault.sh   ║"
echo "║  2. Setup Self-hosted Runner:                            ║"
echo "║     Settings → Actions → Runners                        ║"
echo "║  3. Setup Environment protection สำหรับ prod:            ║"
echo "║     Settings → Environments → prod                      ║"
echo "║                                                          ║"
echo "║  IMPORTANT: อย่า commit vault-keys.json!                 ║"
echo "╚══════════════════════════════════════════════════════════╝"
