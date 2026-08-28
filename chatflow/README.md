# ChatFlow Infrastructure (Phase 1)

Phase 1 baseline manifests for the rebuilt ChatFlow stack. The previous
v1 manifests live next to this directory in `../chatflow-v1-archive/`.

## Apply order

Numeric prefix is the apply order. The whole tree is safe to apply with:

```bash
kubectl apply -f .
```

`kubectl apply -f .` only matches `*.yaml`, so `09-wa-pod-template.yaml.tmpl`
is intentionally skipped — that file is consumed by the orchestrator at
runtime, not by kubectl.

The init Job in `05-openbao.yaml` is idempotent — re-applying after the
cluster is initialized is a no-op. The Postgres init script
(`03-postgres.yaml`) only runs on first boot of a fresh PVC.

If you want to be explicit:

```bash
for f in $(ls 0?-*.yaml 1?-*.yaml | sort); do
  kubectl apply -f "$f"
done
```

## File map

| File | What it deploys |
|------|-----------------|
| `00-namespace.yaml`        | `chatflow` namespace + Pod Security `restricted` enforcement |
| `01-secrets.yaml`          | Reused secret references + new placeholder secrets (TODO) |
| `02-network-policies.yaml` | Default-deny + per-workload Cilium policies |
| `03-postgres.yaml`         | StatefulSet, PVC 10 Gi, multi-DB init script |
| `04-emqx.yaml`             | StatefulSet + Headless / ClusterIP / LoadBalancer Services, JWT auth via JWKS |
| `05-openbao.yaml`          | StatefulSet (Raft single-node), idempotent init Job, RBAC |
| `06-auth-service.yaml`     | Deployment + ServiceAccount + Service |
| `07-orchestrator.yaml`     | Deployment + ServiceAccount + Role + RoleBinding + Service + base Role for wa-pods |
| `08-gateway.yaml`          | Deployment + ServiceAccount + Service |
| `09-wa-pod-template.yaml.tmpl` | DOCUMENTATION ONLY — kubectl skips `.tmpl`; rendered per-user by orchestrator |
| `10-web.yaml`              | Deployment + Service for the Next.js public site |
| `11-httproutes.yaml`       | api / apex / mqtt routes attaching to `platform-gateway` in the `gateway` namespace |
| `12-resource-quota.yaml`   | ResourceQuota: 50 pods / 8 cpu / 16 Gi |
| `13-pdb.yaml`              | minAvailable=1 PDBs for auth, orchestrator, gateway |

## Secrets you must apply manually

Backups for the v1 secrets the new stack reuses are in
`../secrets/chatflow-backup-2026-04-25/secrets/`.

| Secret | Source | Notes |
|--------|--------|-------|
| `dockerhub-secret`     | `01-secrets.yaml` (in backup tree) | image pull |
| `twilio-secret`        | `01j-twilio-secret.yaml`           | OTP SMS delivery |
| `firebase-credentials` | `11-firebase-secret.yaml`          | Phase 2+ APNs/FCM relay |

```bash
kubectl apply -f ../secrets/chatflow-backup-2026-04-25/secrets/01-secrets.yaml
kubectl apply -f ../secrets/chatflow-backup-2026-04-25/secrets/01j-twilio-secret.yaml
kubectl apply -f ../secrets/chatflow-backup-2026-04-25/secrets/11-firebase-secret.yaml
```

## Generating new secrets

`01-secrets.yaml` declares two secrets with `TODO_REPLACE_BEFORE_APPLY`
placeholders, plus references two more that the OpenBao init Job creates.

### postgres-secret

```bash
PG_SU=$(openssl rand -base64 24)
PG_AUTH=$(openssl rand -base64 24)
PG_ORCH=$(openssl rand -base64 24)
PG_WAPOD=$(openssl rand -base64 24)
kubectl -n chatflow create secret generic postgres-secret \
  --from-literal=POSTGRES_USER=postgres \
  --from-literal=POSTGRES_PASSWORD="$PG_SU" \
  --from-literal=POSTGRES_DB=postgres \
  --from-literal=AUTH_DB_USER=auth \
  --from-literal=AUTH_DB_PASSWORD="$PG_AUTH" \
  --from-literal=AUTH_DB_NAME=chatflow_auth \
  --from-literal=ORCHESTRATOR_DB_USER=orchestrator \
  --from-literal=ORCHESTRATOR_DB_PASSWORD="$PG_ORCH" \
  --from-literal=ORCHESTRATOR_DB_NAME=chatflow_orchestrator \
  --from-literal=SESSIONS_DB_USER=wa_pod \
  --from-literal=SESSIONS_DB_PASSWORD="$PG_WAPOD" \
  --from-literal=SESSIONS_DB_NAME=chatflow_sessions \
  --dry-run=client -o yaml > postgres-secret.yaml
# back up postgres-secret.yaml to infrastructure/secrets/chatflow/ (gitignored)
kubectl apply -f postgres-secret.yaml
```

### auth-jwt-keypair (Ed25519)

Consumers (mounted via projected Secret volume, kubelet-supplied — no
RBAC `get secrets` needed by the consumer's ServiceAccount):

- `auth-service` — issues access/refresh JWTs, publishes JWKS.
- `wa-pod` — signs the per-pod handshake on `chatflow/{user_id}/handshake`.
  Pod refuses to start without the key unless `ALLOW_UNSIGNED_HANDSHAKE=true`.
  See `chatflow/services/wa-pod/README.md` for the strict-by-default contract.

```bash
openssl genpkey -algorithm Ed25519 -out auth-jwt.key
openssl pkey -in auth-jwt.key -pubout -out auth-jwt.pub
kubectl -n chatflow create secret generic auth-jwt-keypair \
  --from-file=jwt-private.pem=auth-jwt.key \
  --from-file=jwt-public.pem=auth-jwt.pub \
  --from-literal=kid="auth-$(date +%Y-%m)" \
  --dry-run=client -o yaml > auth-jwt-keypair.yaml
kubectl apply -f auth-jwt-keypair.yaml
```

### openbao-root-token + openbao-unseal-keys

Created automatically by the init Job in `05-openbao.yaml` on first run
(`openbao operator init -key-shares=5 -key-threshold=3`).

**CRITICAL**: copy the unseal keys from the resulting Secret to an out-of-band
backup (printed receipt, password manager, etc.). Without them, a
single-node Raft cluster that gets sealed (e.g. after a restart) is
unrecoverable.

```bash
kubectl -n chatflow get secret openbao-unseal-keys -o jsonpath='{.data.keys}' | base64 -d
kubectl -n chatflow get secret openbao-root-token -o jsonpath='{.data.token}' | base64 -d
```

### Manual unseal after openbao restart (Phase 1 limitation)

Phase 1 uses Shamir unseal — auto-unseal (cloud KMS or transit-mounted seal)
is a Phase 4 deliverable. Until then, every restart of `openbao-0` requires:

```bash
KEYS=$(kubectl -n chatflow get secret openbao-unseal-keys -o jsonpath='{.data.keys}' | base64 -d)
for k in $(echo "$KEYS" | jq -r '.[]' | head -n3); do
  kubectl -n chatflow exec openbao-0 -- bao operator unseal "$k"
done
```

## DNS

Already configured by the user; nothing new required for Phase 1:

| Hostname               | Records to | Used by |
|------------------------|------------|---------|
| `chatflowpro.live`     | platform-gateway external IP | apex web (Next.js) |
| `api.chatflowpro.live` | platform-gateway external IP | gateway-service + auth-service (path-based) |
| `mqtt.chatflowpro.live`| platform-gateway external IP | EMQX MQTT-over-WS |

## Architecture decisions

- **Auth on `api.chatflowpro.live/auth/*`** (not `auth.chatflowpro.live`): one
  fewer DNS record / cert, and JWKS validators (gateway, EMQX) all reach
  Auth via in-cluster ClusterIP anyway. Public exposure of the JWKS endpoint
  is a transparency feature, not a functional dependency.
- **Single platform-gateway parent**: routes attach by `sectionName`
  (`chatflow-api`, `chatflow-web`, `chatflow-mqtt`) — same pattern the v1
  manifests used; nothing in the gateway namespace needs to change.
- **wa-pod label** is `chatflow.io/role: wa-client` (matches ARCHITECTURE.md
  examples). The 02-network-policies.yaml selectors and the
  09-wa-pod-template.yaml metadata both reference this label exactly.
- **JWKS endpoint** is fetched in-cluster via
  `http://auth-service.chatflow.svc.cluster.local:8080/.well-known/jwks.json`.
  External clients have no need to fetch it directly.

## Operational notes

- The OpenBao init Job uses `alpine/k8s:1.30.5` (kubectl 1.30) for
  bundled kubectl + curl + jq. If the cluster moves materially past 1.31
  bump the tag in `05-openbao.yaml` to keep within the +/-1 minor skew.
- `HOME` and `KUBECACHEDIR` are set to `/tmp` in the init container so
  kubectl's discovery cache lands on the writable tmpfs (root FS is
  read-only).

## Image tags TODO

The four ChatFlow services we own are listed with `:latest` tags pending
the build pipeline:

- `ghcr.io/sonic4002/chatflow-auth:latest`
- `ghcr.io/sonic4002/chatflow-orchestrator:latest`
- `ghcr.io/sonic4002/chatflow-gateway:latest`
- `ghcr.io/sonic4002/chatflow-web:latest`
- `ghcr.io/sonic4002/chatflow-wa-pod:latest` (referenced from 07-orchestrator
  via the `WA_POD_IMAGE` env var; pinned digest goes in 09-wa-pod-template
  once images exist)

Once `deploy-chatflow` builds them, swap to `@sha256:...` digests.

## Phase scope

This is the **Phase 1 baseline**. Things deliberately not present:

- xOffice integration manifests (Phase 3)
- Push notification config (Phase 2)
- Multi-device pairing flows (Phase 2)
- HA OpenBao + auto-unseal (Phase 4)
- Falco monitoring + audit log pipeline (Phase 4)
- TLS listeners on EMQX (Phase 2 via cert-manager)

## Validation after first apply

```bash
kubectl -n chatflow get pods
kubectl -n chatflow get cnp
kubectl -n chatflow get httproute
kubectl -n chatflow describe resourcequota chatflow-resource-quota
kubectl -n chatflow logs job/openbao-init
```

## Safe rollback

The whole stack lives in one namespace. To wipe:

```bash
kubectl delete namespace chatflow
```

…then re-apply this directory. (Postgres + OpenBao data lives on PVCs that
survive namespace deletion only if the underlying StorageClass uses a
Retain reclaim policy; verify before doing this on any cluster you care
about.)
