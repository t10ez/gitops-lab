# Bootstrap Guide — GitOps Lab

คู่มือนี้อธิบายขั้นตอนการติดตั้ง GitOps Lab environment ตั้งแต่ต้น รวมถึง architecture ของแต่ละ component และวิธี troubleshoot เมื่อเกิดปัญหา

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────┐
│  KinD Cluster: platform-lab  (4 nodes)                              │
│                                                                     │
│  control-plane ──── port 8080 (HTTP), 8443 (HTTPS), 9000 (metrics) │
│  worker (zone-a)  ─ node-type: workload                            │
│  worker (zone-b)  ─ node-type: workload                            │
│  worker (zone-c)  ─ node-type: platform                            │
│                                                                     │
│  ┌──────────────┐    ┌──────────────┐    ┌──────────────────────┐  │
│  │ cert-manager │    │   Traefik    │    │       ArgoCD         │  │
│  │  (TLS / CA)  │    │  (Ingress)   │    │  (GitOps controller) │  │
│  └──────┬───────┘    └──────┬───────┘    └──────────────────────┘  │
│         │                   │                                       │
│         │ ออก cert          │ route traffic                        │
│         ▼                   ▼                                       │
│  ┌──────────────────────────────────────────────────────────────┐  │
│  │  Vault (HA Raft, 3 replicas — vault-0/1/2)                  │  │
│  │   KV-v2: secret/demo-app/{dev,staging,prod}                 │  │
│  └──────────────────────┬───────────────────────────────────────┘  │
│                         │ Kubernetes auth (JWT)                    │
│                         ▼                                          │
│  ┌───────────────────────────────────────────────────────────────┐  │
│  │  External Secrets Operator (ESO)                             │  │
│  │   ClusterSecretStore: vault-backend                          │  │
│  │   ExternalSecret → sync → Kubernetes Secret                  │  │
│  └───────────────────────────────────────────────────────────────┘  │
│                                                                     │
│  ┌───────────────────────────────────────────────────────────────┐  │
│  │  Monitoring: Prometheus · Grafana · Loki · Promtail           │  │
│  └───────────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────┘
```

---

## Prerequisites

| Tool | เวอร์ชันแนะนำ | ติดตั้ง |
|------|--------------|---------|
| [kind](https://kind.sigs.k8s.io/) | ≥ 0.23 | `brew install kind` |
| [kubectl](https://kubernetes.io/docs/tasks/tools/) | ≥ 1.29 | `brew install kubectl` |
| [helm](https://helm.sh/docs/intro/install/) | ≥ 3.14 | `brew install helm` |
| [jq](https://jqlang.github.io/jq/) | ≥ 1.7 | `brew install jq` |
| [vault CLI](https://developer.hashicorp.com/vault/docs/install) | ≥ 1.17 | `brew install vault` |

> **Note:** `vault` CLI ใช้เฉพาะ `bootstrap/vault/bootstrap.sh` และ `setup-vault.sh` ไม่ต้องการ license

---

## Quick Start

```bash
# Clone repo
git clone https://github.com/t10ez/gitops-lab.git
cd gitops-lab

# Full setup (รวม monitoring)
./bootstrap/setup.sh

# หรือข้าม monitoring (เร็วกว่า ≈ 5 นาที)
./bootstrap/setup.sh --skip-monitoring
```

Script จะรันทุก phase อัตโนมัติและแสดง URL สรุปเมื่อเสร็จ

---

## Bootstrap Phases

### Phase 1 — KinD Cluster

สร้าง local Kubernetes cluster ด้วย [KinD](https://kind.sigs.k8s.io/) โดยใช้ config จาก `bootstrap/kind/kind-phase1.yaml`

| Node | Role | Label |
|------|------|-------|
| control-plane | API server + ingress-ready | — |
| worker-a | workload | `node-type: workload, zone: a` |
| worker-b | workload | `node-type: workload, zone: b` |
| worker-c | platform | `node-type: platform, zone: c` |

Port mappings ที่ expose ออก host:

| Host Port | Cluster NodePort | ใช้สำหรับ |
|-----------|-----------------|----------|
| 8080 | 30080 | HTTP (Traefik web) |
| 8443 | 30443 | HTTPS (Traefik websecure) |
| 9000 | 30900 | Traefik dashboard / metrics |

---

### Phase 2 — cert-manager

ติดตั้ง [cert-manager](https://cert-manager.io/) และสร้าง Certificate chain สำหรับ lab:

```
selfsigned-issuer (ClusterIssuer)
  └─ lab-ca (Certificate, isCA: true)
       └─ lab-ca-issuer (ClusterIssuer)  ← ใช้ออก cert ทุกอย่างใน lab
```

ทุก component ที่ต้องการ TLS (Vault, ArgoCD, ฯลฯ) จะอ้างอิง `lab-ca-issuer` นี้

**ไฟล์:** `bootstrap/cert-manager/values.yaml`, `cluster-issuer.yaml`

---

### Phase 3 — Traefik

ติดตั้ง [Traefik v2](https://traefik.io/) เป็น ingress controller แบบ NodePort

- Dashboard: `http://traefik.localhost:8080`  
- Metrics scrape: port 9100 (Prometheus)

**ไฟล์:** `bootstrap/traefik/traefik-values.yaml`

---

### Phase 4 — Vault (HA Raft)

ติดตั้ง [HashiCorp Vault](https://developer.hashicorp.com/vault) แบบ High Availability ด้วย Raft storage โดย script `bootstrap/vault/bootstrap.sh` จะทำครบทุกขั้นตอน:

1. สร้าง TLS certificate ด้วย cert-manager
2. ติดตั้ง Vault Helm chart (3 replicas)
3. `vault operator init` สร้าง unseal keys และ root token → บันทึกใน `vault-keys.json`
4. Unseal vault-0 แล้ว join vault-1, vault-2 เข้า Raft cluster
5. รัน `setup-vault.sh` เพื่อ config:
   - KV-v2 secret engine ที่ path `secret/`
   - Policies: `ci-cd-policy` (GitHub Actions), `eso-policy` (ESO read-only)
   - AppRole auth (GitHub Actions CI/CD)
   - Kubernetes auth (ESO)
   - สร้าง initial secrets สำหรับ demo-app

```
vault-keys.json  ← เก็บ root token + unseal keys (gitignore อยู่แล้ว)
                   ห้าม commit เด็ดขาด
```

**UI:** `https://vault.localhost:8443` (ใช้ root token จาก `vault-keys.json`)

**ไฟล์:** `bootstrap/vault/`

---

### Phase 5 — External Secrets Operator (ESO)

ติดตั้ง [ESO](https://external-secrets.io/) และสร้าง `ClusterSecretStore` ที่ชี้ไป Vault:

```yaml
# ภาพรวม ClusterSecretStore
server: https://vault.vault.svc.cluster.local:8200
path:   secret        # KV-v2 mount
auth:   kubernetes    # role: eso-role
```

ESO จะ authenticate เข้า Vault โดยใช้ ServiceAccount `external-secrets` ใน namespace `external-secrets` ผ่าน Kubernetes auth

**ไฟล์:** `bootstrap/external-secrets/values.yaml`, `cluster-secret-store.yaml`

---

### Phase 6 — ArgoCD

ติดตั้ง [ArgoCD](https://argo-cd.readthedocs.io/) พร้อม:

- `AppProject: lab` — อนุญาต deploy จาก repo นี้ไปทุก namespace
- `IngressRoute` สำหรับ Traefik

**UI:** `http://argocd.localhost:8080`  
**Login:** `admin` / รหัสผ่านจาก secret `argocd-initial-admin-secret`:

```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d
```

**ไฟล์:** `bootstrap/argocd/`

---

### Phase 7 — App-of-Apps

Apply `gitops/apps/app-of-apps.yaml` เพื่อให้ ArgoCD เริ่ม sync ApplicationSets ทั้งหมด:

```
app-of-apps.yaml
  └─ ApplicationSet: demo-app
       ├─ demo-dev      (namespace: demo-dev,      autoSync: true)
       ├─ demo-staging  (namespace: demo-staging,  autoSync: true)
       └─ demo-prod     (namespace: demo-prod,     autoSync: false)
```

ข้ามขั้นตอนนี้ได้ด้วย `--skip-apps` ถ้ายังไม่พร้อม push manifests

---

### Phase 8 — Monitoring (Optional)

ติดตั้ง observability stack ครบชุด:

| Component | ชื่อ Helm Release | Namespace |
|-----------|-----------------|-----------|
| Prometheus + Grafana + Alertmanager | `monitoring` | `monitoring` |
| Loki (log aggregation) | `loki` | `monitoring` |
| Promtail (log shipper) | `promtail` | `monitoring` |

**Grafana:** `http://grafana.localhost:8080` (admin/admin)

Dashboard ที่ pre-install:
- ArgoCD (Grafana ID: 14584)
- Traefik (Grafana ID: 17346)
- Kubernetes Cluster (Grafana ID: 7249)

ข้ามได้ด้วย `--skip-monitoring` เมื่อรัน setup.sh

---

## Access URLs

| Service | URL | Credentials |
|---------|-----|-------------|
| Traefik Dashboard | http://traefik.localhost:8080 | — |
| ArgoCD UI | http://argocd.localhost:8080 | admin / ดู secret |
| Vault UI | https://vault.localhost:8443 | root token จาก vault-keys.json |
| Grafana | http://grafana.localhost:8080 | admin / admin |
| Demo App (dev) | http://demo.localhost:8080 | — |

> **Tip:** เพิ่ม entries ต่อไปนี้ใน `/etc/hosts` ถ้า DNS ไม่ resolve อัตโนมัติ:
> ```
> 127.0.0.1  traefik.localhost argocd.localhost vault.localhost grafana.localhost demo.localhost
> ```

---

## After Setup: GitHub Actions Configuration

`setup-vault.sh` จะ print ค่าเหล่านี้ตอนจบ — นำไปเพิ่มเป็น GitHub Secrets:

| Secret Name | ค่า |
|------------|-----|
| `VAULT_ADDR` | `https://vault.localhost:8443` |
| `VAULT_ROLE_ID` | Role ID จาก AppRole `github-actions` |
| `VAULT_CA_CERT` | Base64-encoded CA cert จาก secret `vault-tls` |

จากนั้น:
1. **Self-hosted Runner:** Settings → Actions → Runners → New self-hosted runner
2. **Environment Protection (prod):** Settings → Environments → prod → Required reviewers

---

## Day-2 Operations

### Vault sealed หลัง cluster restart

Vault จะ seal ทุกครั้งที่ pod restart ให้รัน:

```bash
./bootstrap/vault/unseal.sh
```

### Reinstall Vault (ล้างทุกอย่าง)

```bash
./bootstrap/vault/reinstall.sh
```

> ข้อมูลทุกอย่างใน Vault จะหาย — ต้อง backup secrets ก่อน

### เพิ่ม secret ใหม่

```bash
# port-forward ไปที่ vault-0
kubectl port-forward -n vault pod/vault-0 8300:8200 &

export VAULT_ADDR=https://127.0.0.1:8300
export VAULT_TOKEN=$(jq -r '.root_token' bootstrap/vault/vault-keys.json)
export VAULT_SKIP_VERIFY=true

vault kv put secret/my-app/dev \
  MY_KEY="my-value"
```

แล้วสร้าง `ExternalSecret` ใน namespace ที่ต้องการ (ดูตัวอย่างที่ `bootstrap/external-secrets/test-external-secret.yaml`)

---

## Troubleshooting

### cert-manager webhook ไม่พร้อม

```bash
kubectl get pods -n cert-manager
kubectl describe certificate lab-ca -n cert-manager
```

ถ้า webhook ยัง `ContainerCreating` ให้รอแล้วลอง apply cluster-issuer ใหม่

### Vault pods ค้างที่ `0/1 Running`

```bash
kubectl logs vault-0 -n vault
kubectl describe pod vault-0 -n vault
```

มักเกิดจาก TLS cert ยังไม่ ready — ตรวจสอบ:
```bash
kubectl get certificate vault-tls -n vault
```

### ESO ไม่ sync secrets

```bash
# ดู status ของ ExternalSecret
kubectl get externalsecret -A
kubectl describe externalsecret <name> -n <namespace>

# ดู log ESO
kubectl logs -n external-secrets deploy/external-secrets -f

# ตรวจสอบ ClusterSecretStore
kubectl get clustersecretstore vault-backend -o yaml
```

Error ที่พบบ่อย:

| Error | สาเหตุ | วิธีแก้ |
|-------|--------|---------|
| `permission denied` | Policy ไม่ครอบคลุม path | เพิ่ม path ใน `eso-policy` |
| `no such host` | Vault addr ผิด | ตรวจ ClusterSecretStore spec.provider.vault.server |
| `x509: certificate signed by unknown authority` | CA ไม่ match | ตรวจ `caProvider` ใน ClusterSecretStore |
| `serviceaccount not found` | SA ชื่อผิดหรืออยู่ผิด namespace | ตรวจ `bound_service_account_names` ใน Vault role |

### ArgoCD ไม่ sync

```bash
argocd app list
argocd app sync <app-name>
argocd app logs <app-name>
```

หรือเปิด UI ที่ `http://argocd.localhost:8080` แล้วดู sync status

---

## Teardown

```bash
# ลบ KinD cluster ทั้งหมด
kind delete cluster --name platform-lab
```

> `vault-keys.json` ยังคงอยู่ใน `bootstrap/vault/` — ลบทิ้งด้วยตนเองถ้าไม่ต้องการแล้ว
