# Nginx to Cilium Gateway Migration Runbook

## Overview

Zero-downtime migration of all platform ingress traffic from nginx to Cilium Gateway API.

**Architecture:**
- Single Gateway (`platform-gateway`) in dedicated `gateway` namespace
- One LoadBalancer IP for all domains
- Host header determines routing to the correct HTTPRoute
- TLS: Cloudflare Flexible mode (edge termination, origin HTTP only)
- No cert-manager needed

```
Internet -> Cloudflare (TLS) -> 1 LB IP -> platform-gateway (gateway ns)
                                              |
                    Host header routing:      |
                    +--> api.chatflowpro.live  -> chatflow/api-route       -> orchestrator:8080
                    +--> chatflowpro.live      -> chatflow/main-route      -> chatflow-web:80
                    +--> mqtt.chatflowpro.live -> chatflow/mqtt-route      -> emqx:8083
                    +--> xoffice.cloud         -> xoffice/frontend-route   -> xoffice-frontend:80
                    +--> api.xoffice.cloud     -> xoffice/api-route        -> xoffice-backend:80
```

**What is being replaced:**

| nginx resource | Cilium replacement |
|---|---|
| `16-chatflow-ingress.yaml` (api + apex) | `04-httproutes-api.yaml` + `05-httproutes-main-domain.yaml` |
| `whatsapp_v2_web/k8s/02-ingress.yaml` (Flutter SPA) | Merged into `05-httproutes-main-domain.yaml` |
| `k8s/emqx/07-ingress.yaml` (MQTT WS) | `06-httproutes-mqtt.yaml` |
| xoffice `k8s/30-ingress.yaml` (frontend + API) | xoffice `k8s/50-gateway.yaml` (HTTPRoutes only) |
| xoffice `k8s/99-chatflow-ingress.yaml` (cross-ns) | No longer needed |
| `06-gateway.yaml` + `07-httproute.yaml` (partial Cilium) | Superseded |
| `k8s/emqx/04-gateway-route.yaml` (partial Cilium) | Superseded |
| `k8s/cilium/01-gateway.yaml` (partial Cilium) | Superseded |

---

## Prerequisites

```bash
# 1. Cilium is installed and the cilium GatewayClass exists
kubectl get gatewayclass cilium

# 2. Namespace labels are correct (needed for Gateway allowedRoutes selectors)
kubectl get ns chatflow --show-labels | grep part-of
# Must have: app.kubernetes.io/part-of=chatflow

kubectl get ns xoffice --show-labels | grep app.kubernetes.io/name
# Must have: app.kubernetes.io/name=xoffice

# 3. Record current nginx LB IP
NGINX_LB=$(kubectl get svc -n ingress-nginx ingress-nginx-controller \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
echo "Current nginx IP: $NGINX_LB"

# 4. Confirm nginx is serving all domains
for domain in api.chatflowpro.live chatflowpro.live mqtt.chatflowpro.live xoffice.cloud api.xoffice.cloud; do
  echo -n "$domain: "
  curl -s -o /dev/null -w "%{http_code}" "http://$domain/" --max-time 5
  echo
done
```

---

## Phase 1: Deploy Cilium Gateway alongside nginx

nginx serves 100% of traffic. Cilium Gateway deployed but receives nothing.

```bash
# Step 1.1: Ensure namespace labels
kubectl label namespace chatflow app.kubernetes.io/part-of=chatflow --overwrite
kubectl label namespace xoffice app.kubernetes.io/name=xoffice --overwrite

# Step 1.2: Create gateway namespace
kubectl apply -f prod-k8s-deployment/cilium/00-namespace.yaml

# Step 1.3: Deploy the consolidated Gateway
kubectl apply -f prod-k8s-deployment/cilium/01-gateway.yaml

# Wait for it to get an external IP
kubectl wait gateway/platform-gateway -n gateway \
  --for=condition=Programmed --timeout=120s

CILIUM_LB=$(kubectl get gateway platform-gateway -n gateway \
  -o jsonpath='{.status.addresses[0].value}')
echo "Cilium Gateway IP: $CILIUM_LB"

# Step 1.4: Deploy chatflow HTTPRoutes
kubectl apply -f prod-k8s-deployment/cilium/04-httproutes-api.yaml
kubectl apply -f prod-k8s-deployment/cilium/05-httproutes-main-domain.yaml
kubectl apply -f prod-k8s-deployment/cilium/06-httproutes-mqtt.yaml

# Step 1.5: Deploy xoffice HTTPRoutes
kubectl apply -f /path/to/xoffice/k8s/50-gateway.yaml

# Step 1.6: Deploy network policies (if applicable)
kubectl apply -f prod-k8s-deployment/cilium/07-network-policies.yaml

# Step 1.7: Verify all routes are accepted
kubectl get httproute -A
# All routes should show ACCEPTED=True

echo "Phase 1 complete. Cilium gateway at $CILIUM_LB (no DNS change yet)."
```

---

## Phase 1 Results

Completed: 2026-03-12

| Item | Value |
|---|---|
| Cilium GatewayClass | `cilium` - ACCEPTED, controller `io.cilium/gateway-controller` |
| Gateway | `platform-gateway` in namespace `gateway` - Programmed=True |
| Host-network mode | Enabled (`gateway-api-hostnetwork-enabled: true`) |
| Cilium LB IP | `159.198.32.218` (node IP; host-network mode, no separate LoadBalancer) |
| Nginx LB IP | `159.198.32.218` (same node, single-node cluster) |
| Gateway service | `cilium-gateway-platform-gateway` - ClusterIP (expected in host-network mode) |

**Listeners (all Programmed=True):**

| Listener | Hostname | Attached Routes |
|---|---|---|
| chatflow-api | api.chatflowpro.live | 1 |
| chatflow-web | chatflowpro.live | 1 |
| chatflow-mqtt | mqtt.chatflowpro.live | 1 |
| xoffice-frontend | xoffice.cloud | 1 |
| xoffice-api | api.xoffice.cloud | 1 |

**Namespace labels confirmed:**
- `chatflow`: `app.kubernetes.io/part-of=chatflow`
- `xoffice`: `app.kubernetes.io/name=xoffice`
- `gateway`: `app.kubernetes.io/name=gateway`, `app.kubernetes.io/part-of=platform`

**Baseline HTTP codes (nginx still serving):**
- api.chatflowpro.live: 404
- chatflowpro.live: 404
- mqtt.chatflowpro.live: 404
- xoffice.cloud: 301
- api.xoffice.cloud: 301

**Note:** Since this is a single-node cluster with Cilium in host-network mode, both nginx and Cilium gateway share the same node IP (159.198.32.218). The Cilium gateway listens on port 80 via the cilium-envoy DaemonSet. DNS currently routes to nginx via its LoadBalancer service. When switching DNS in Phase 3, traffic will be handled by Cilium's envoy proxy on the same IP.

---

## Phase 2: Validate all endpoints through Cilium

Test every endpoint by forcing requests to the Cilium IP. nginx still serves real traffic.

```bash
CILIUM_LB=$(kubectl get gateway platform-gateway -n gateway \
  -o jsonpath='{.status.addresses[0].value}')

# Test each domain via Host header against Cilium IP
echo "--- ChatFlow API ---"
curl -s -o /dev/null -w "%{http_code}" -H "Host: api.chatflowpro.live" "http://$CILIUM_LB/health"
# Expected: 200

echo "--- ChatFlow Web ---"
curl -s -o /dev/null -w "%{http_code}" -H "Host: chatflowpro.live" "http://$CILIUM_LB/"
# Expected: 200

echo "--- MQTT WebSocket ---"
curl -s -o /dev/null -w "%{http_code}" \
  -H "Host: mqtt.chatflowpro.live" \
  -H "Upgrade: websocket" -H "Connection: Upgrade" \
  -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" \
  -H "Sec-WebSocket-Version: 13" \
  "http://$CILIUM_LB/mqtt"
# Expected: 101

echo "--- XOFFICE Frontend ---"
curl -s -o /dev/null -w "%{http_code}" -H "Host: xoffice.cloud" "http://$CILIUM_LB/"
# Expected: 200

echo "--- XOFFICE API ---"
curl -s -o /dev/null -w "%{http_code}" -H "Host: api.xoffice.cloud" "http://$CILIUM_LB/api/health/"
# Expected: 200

# Or use the validation script:
./k8s/cilium/validate-endpoints.sh cilium "$CILIUM_LB"
```

All tests must pass before proceeding.

---

## Phase 3: Switch DNS to Cilium

Update DNS A records. nginx stays deployed as rollback target.

```bash
CILIUM_LB=$(kubectl get gateway platform-gateway -n gateway \
  -o jsonpath='{.status.addresses[0].value}')

echo "Update ALL DNS A records to: $CILIUM_LB"
echo "  api.chatflowpro.live"
echo "  chatflowpro.live"
echo "  mqtt.chatflowpro.live"
echo "  xoffice.cloud"
echo "  api.xoffice.cloud"
echo ""
echo "In Cloudflare: set TTL to 60s during migration."
```

After DNS propagation:

```bash
# Confirm DNS propagated
for domain in api.chatflowpro.live chatflowpro.live mqtt.chatflowpro.live xoffice.cloud api.xoffice.cloud; do
  echo -n "$domain -> "
  dig +short "$domain"
done

# Validate via real DNS
./k8s/cilium/validate-endpoints.sh production

# Monitor for 15 minutes
kubectl logs -f deployment/whatsapp-orchestrator -n chatflow --since=1m &
sleep 900 && kill %1
```

---

## Phase 4: Remove nginx (after 24h clean run)

```bash
# Remove chatflow nginx Ingress resources
kubectl delete ingress chatflow-ingress -n chatflow
kubectl delete ingress chatflow-web-ingress -n chatflow
kubectl delete ingress emqx-mqtt-ingress -n chatflow

# Remove xoffice nginx Ingress resources
kubectl delete ingress xoffice-frontend-ingress -n xoffice
kubectl delete ingress xoffice-api-ingress -n xoffice

# Remove cross-namespace nginx hack
kubectl delete ingress chatflow-ingress -n chatflow 2>/dev/null || true

# Remove old partial Cilium resources
kubectl delete gateway whatsapp-gateway -n chatflow 2>/dev/null || true
kubectl delete gateway chatflow-gateway -n chatflow 2>/dev/null || true
kubectl delete httproute orchestrator-route -n chatflow 2>/dev/null || true
kubectl delete httproute main-domain-route -n chatflow 2>/dev/null || true
kubectl delete httproute emqx-mqtt-route -n chatflow 2>/dev/null || true

# Final validation
./k8s/cilium/validate-endpoints.sh production

# Optional: remove nginx controller entirely (only if nothing else uses it)
# kubectl delete namespace ingress-nginx
```

---

## Rollback (any phase, <5 minutes)

```bash
# Re-apply all nginx Ingress resources
kubectl apply -f prod-k8s-deployment/16-chatflow-ingress.yaml
kubectl apply -f whatsapp_v2_web/k8s/02-ingress.yaml
kubectl apply -f k8s/emqx/07-ingress.yaml
kubectl apply -f /path/to/xoffice/k8s/30-ingress.yaml

# Revert DNS to nginx IP
NGINX_LB=$(kubectl get svc -n ingress-nginx ingress-nginx-controller \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
echo "Revert ALL DNS A records to: $NGINX_LB"

# Verify
for domain in api.chatflowpro.live chatflowpro.live xoffice.cloud api.xoffice.cloud; do
  echo -n "$domain: "
  curl -s -o /dev/null -w "%{http_code}" "http://$domain/" --max-time 5
  echo
done
```

---

## Endpoint Inventory

| Host | Path | Backend | Notes |
|---|---|---|---|
| `api.chatflowpro.live` | `/health` | orchestrator:8080 | Health probe |
| `api.chatflowpro.live` | `/ready` | orchestrator:8080 | Readiness probe |
| `api.chatflowpro.live` | `/metrics` | orchestrator:8080 | Prometheus |
| `api.chatflowpro.live` | `/api/v1/users/*/ws` | orchestrator:8080 | WebSocket, no timeout |
| `api.chatflowpro.live` | `/api/v1/` | orchestrator:8080 | REST API, 30s |
| `api.chatflowpro.live` | `/internal/` | orchestrator:8080 | Client-pod callbacks |
| `chatflowpro.live` | `/delete-account` | orchestrator:8080 | Google Play compliance |
| `chatflowpro.live` | `/api/v1/account/delete-request` | orchestrator:8080 | POST, Google Play |
| `chatflowpro.live` | `/health` | orchestrator:8080 | LB probe |
| `chatflowpro.live` | `/healthz` | chatflow-web:80 | Container health |
| `chatflowpro.live` | `/` | chatflow-web:80 | Flutter SPA (catch-all) |
| `mqtt.chatflowpro.live` | `/mqtt` | emqx:8083 | MQTT-over-WS, no timeout |
| `xoffice.cloud` | `/` | xoffice-frontend:80 | Next.js, WS unlimited |
| `api.xoffice.cloud` | `/` | xoffice-backend:80 | Django REST, 30s |
| `api.xoffice.cloud` | WS upgrade | xoffice-backend:80 | WebSocket, no timeout |

---

## Files

**Shared infra (`prod-k8s-deployment/cilium/`):**
- `00-namespace.yaml` - `gateway` namespace
- `01-gateway.yaml` - Consolidated Gateway (all 5 domains, HTTP only)
- `04-httproutes-api.yaml` - api.chatflowpro.live routes
- `05-httproutes-main-domain.yaml` - chatflowpro.live routes
- `06-httproutes-mqtt.yaml` - mqtt.chatflowpro.live routes
- `07-network-policies.yaml` - CiliumNetworkPolicy

**XOFFICE (`xoffice/k8s/`):**
- `50-gateway.yaml` - HTTPRoutes for xoffice.cloud + api.xoffice.cloud

**Validation (`k8s/cilium/`):**
- `validate-endpoints.sh` - Endpoint validation script
