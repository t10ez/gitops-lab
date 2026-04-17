# Vault ↔ ESO (External Secrets Operator) — คู่มือสำหรับทีม

> เอกสารนี้อธิบายว่า Vault กับ ESO เชื่อมกันยังไง ตรงไหนต้องดูเวลาแก้ไข และ trap ที่มักเจอ

---

## ภาพรวมระบบ

```
┌─────────────────────────────────────────────────────────────────┐
│  Developer / CI-CD                                              │
│   vault kv put secret/demo-app/dev DATABASE_URL="..."           │
└────────────────────────┬────────────────────────────────────────┘
                         │ เขียน secret เข้า Vault
                         ▼
┌─────────────────────────────────────────────────────────────────┐
│  Vault  (namespace: vault)                                      │
│   ├─ KV-v2 engine  →  path "secret/"                           │
│   │    ├─ secret/demo-app/dev                                   │
│   │    ├─ secret/demo-app/staging                               │
│   │    └─ secret/demo-app/prod                                  │
│   ├─ Auth method: kubernetes  →  eso-role                       │
│   └─ Policy: eso-policy  →  read-only บน secret/demo-app/*     │
└────────────────────────┬────────────────────────────────────────┘
                         │ ESO login ด้วย ServiceAccount token
                         │ Vault verify กับ Kubernetes TokenReview API
                         ▼
┌─────────────────────────────────────────────────────────────────┐
│  ESO  (namespace: external-secrets)                             │
│   ├─ ClusterSecretStore "vault-backend"                         │
│   │    └─ ระบุ Vault addr + auth method (kubernetes/eso-role)   │
│   └─ ExternalSecret (แต่ละ namespace)                           │
│        ├─ demo-dev    →  อ่าน secret/demo-app/dev              │
│        ├─ demo-staging →  อ่าน secret/demo-app/staging         │
│        └─ demo-prod   →  อ่าน secret/demo-app/prod             │
└────────────────────────┬────────────────────────────────────────┘
                         │ สร้าง / sync อัตโนมัติทุก refreshInterval
                         ▼
┌─────────────────────────────────────────────────────────────────┐
│  Kubernetes Secret (namespace เดียวกับ app)                     │
│   └─ demo-app-secret  →  Pod mount ผ่าน envFrom / volumeMount   │
└─────────────────────────────────────────────────────────────────┘
```

---

## ขั้นตอน Authentication (สิ่งที่เกิดขึ้นในเบื้องหลัง)

```
ESO Pod                    Vault                  Kubernetes API
   │                          │                        │
   │── POST /v1/auth/          │                        │
   │   kubernetes/login ──────►│                        │
   │   (ส่ง ServiceAccount     │                        │
   │    JWT token)             │── TokenReview ─────────►│
   │                          │◄─ valid: eso SA ────────│
   │◄─ Vault token (ttl=24h) ──│                        │
   │                          │                        │
   │── GET /v1/secret/data/    │                        │
   │   demo-app/dev ──────────►│                        │
   │◄─ { DATABASE_URL, ... } ──│                        │
   │                          │                        │
   │── kubectl create/patch Secret                      │
```

---

## ไฟล์ที่ต้องรู้จัก

| ไฟล์ | หน้าที่ | ต้องแก้เมื่อ |
|------|---------|-------------|
| `bootstrap/vault/setup-vault.sh` | ตั้งค่า policy, auth method, role, ใส่ secret เริ่มต้น | เพิ่ม secret path ใหม่, เปลี่ยน policy, เพิ่ม environment |
| `bootstrap/vault/values.yaml` | Helm values ของ Vault HA cluster | เปลี่ยน replica, TLS, storage |
| `bootstrap/eso/cluster-secret-store.yaml` | บอก ESO ให้ต่อไปหา Vault ที่ไหน, ใช้ auth อะไร | เปลี่ยน Vault addr, เปลี่ยน role name |
| `bootstrap/eso/external-secret-example.yaml` | ตัวอย่าง template สำหรับ ExternalSecret | — |
| `gitops/environments/{env}/values.yaml` | Helm values ต่อ environment | เพิ่ม config ต่อ env |

---

## จุดเชื่อมที่สำคัญ — "ถ้าแก้ตรงนี้ ต้องแก้ตรงนั้นด้วย"

### 1. Role Name ต้องตรงกัน

```
setup-vault.sh                          cluster-secret-store.yaml
─────────────────                       ──────────────────────────
vault write auth/kubernetes/role/       spec:
  eso-role          ◄─── ต้องตรงกัน ───►  provider:
  bound_service_account_names=              vault:
    external-secrets                          auth:
                                                kubernetes:
                                                  role: eso-role
```

### 2. ServiceAccount Name ต้องตรงกัน

```
setup-vault.sh                          Helm ติดตั้ง ESO
─────────────────                       ─────────────────────────
bound_service_account_names=            ESO สร้าง ServiceAccount ชื่อ
  external-secrets    ◄─── ต้องตรงกัน ── "external-secrets" อัตโนมัติ
bound_service_account_namespaces=       ใน namespace "external-secrets"
  external-secrets
```

### 3. Secret Path ต้องตรงกัน

```
setup-vault.sh                          ExternalSecret manifest
─────────────────                       ──────────────────────────
vault kv put                            spec:
  secret/demo-app/dev                     data:
  DATABASE_URL="..."  ◄─── ต้องตรงกัน ──►  - remoteRef:
                                              key: demo-app/dev
                                              property: DATABASE_URL
```

> **หมายเหตุ:** ใน KV-v2, path จริงใน API คือ `secret/data/demo-app/dev`
> แต่ใน ExternalSecret ระบุแค่ `demo-app/dev` (ESO จัดการ prefix ให้เอง)

### 4. Policy ต้องครอบคลุม Path

```
eso-policy ใน setup-vault.sh:
  path "secret/data/demo-app/*" { capabilities = ["read"] }
                       ▲
                       └── ถ้าเพิ่ม path ใหม่นอก demo-app/
                           ต้องอัปเดต policy นี้ด้วย
```

---

## วิธีเพิ่ม Secret ใหม่ (checklist)

```
[ ] 1. ใส่ secret เข้า Vault
        vault kv put secret/demo-app/dev MY_NEW_KEY="value"

[ ] 2. ตรวจว่า eso-policy ครอบคลุม path นั้น
        (ถ้าอยู่ใต้ secret/demo-app/* ไม่ต้องแก้)

[ ] 3. เพิ่ม remoteRef ใน ExternalSecret ของ namespace นั้น
        - remoteRef:
            key: demo-app/dev
            property: MY_NEW_KEY

[ ] 4. ESO จะ sync ภายใน refreshInterval (default: 1h)
        บังคับ sync ทันที: kubectl annotate es <name> force-sync=$(date +%s) -n <ns>
```

---

## วิธี Debug เมื่อ Secret ไม่ถูก Sync

```bash
# 1. ดูสถานะ ExternalSecret
kubectl get externalsecret -n demo-dev
kubectl describe externalsecret demo-app-secret -n demo-dev

# 2. ดู log ESO controller
kubectl logs -n external-secrets \
  -l app.kubernetes.io/name=external-secrets --tail=50

# 3. ตรวจ ClusterSecretStore ว่า connect ได้มั้ย
kubectl get clustersecretstore vault-backend
# STATUS ควรเป็น Valid

# 4. ทดสอบ Vault โดยตรง (จาก local)
export VAULT_ADDR=https://vault.localhost:8443
export VAULT_CACERT=/tmp/vault-ca.crt
vault kv get secret/demo-app/dev
```

### Error ที่มักเจอ

| Error | สาเหตุ | แก้ยังไง |
|-------|--------|---------|
| `permission denied` | eso-policy ไม่ครอบคลุม path | เพิ่ม path ใน policy แล้วรัน setup-vault.sh |
| `role not found` | ชื่อ role ใน ClusterSecretStore ไม่ตรง | ตรวจ `eso-role` ทั้งสองฝั่ง |
| `could not verify token` | Vault ต่อ Kubernetes API ไม่ได้ | ตรวจ `kubernetes_host` ใน vault write auth/kubernetes/config |
| `no secret data` | Path ใน Vault ไม่มี secret | `vault kv get secret/...` ตรวจดู |
| `ClusterSecretStore: Invalid` | TLS cert ไม่ตรง หรือ Vault down | ตรวจ VAULT_CACERT และ Vault pod status |

---

## Trap ที่มักเจอสำหรับมือใหม่

1. **KV-v2 double path** — เวลา `vault kv put secret/foo/bar` จริงๆ เก็บที่ `secret/data/foo/bar` ใน API
   ExternalSecret ใช้ `key: foo/bar` (ไม่ต้องใส่ `data/`)

2. **Vault sealed หลัง restart** — ทุกครั้งที่ pod restart ต้อง unseal ใหม่
   รัน: `./bootstrap/vault/unseal.sh`

3. **Token หมดอายุ** — ESO token มี ttl=24h ถ้า sync fail หลังผ่านไปนาน ให้ลอง delete+recreate ExternalSecret

4. **refreshInterval** — ESO ไม่ sync realtime, default คือ 1h
   ถ้าต้องการ sync เร็ว ให้ตั้ง `refreshInterval: 5m` หรือ annotate force-sync
