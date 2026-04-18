#!/bin/bash
set -euo pipefail

NAMESPACE="chatflow"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=== Deploying EMQX MQTT Broker to ${NAMESPACE} ==="

# Check kubectl access
if ! kubectl get namespace "${NAMESPACE}" &>/dev/null; then
  echo "ERROR: Namespace ${NAMESPACE} does not exist"
  exit 1
fi

SECRETS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../secrets/chatflow/emqx" && pwd)"

# Check if secret password has been set
if grep -q "REPLACE_WITH_STRONG_RANDOM_PASSWORD" "${SECRETS_DIR}/06-secret.yaml"; then
  echo "WARNING: Generating random password for MQTT superuser..."
  RANDOM_PASS=$(openssl rand -base64 32 | tr -d '=' | head -c 40)
  sed -i.bak "s|REPLACE_WITH_STRONG_RANDOM_PASSWORD|${RANDOM_PASS}|g" "${SECRETS_DIR}/06-secret.yaml"
  rm -f "${SECRETS_DIR}/06-secret.yaml.bak"
  echo "Password generated. Store this securely: ${RANDOM_PASS}"
fi

# Apply manifests in order
echo ""
echo "1/6 Applying ConfigMap..."
kubectl apply -f "${SCRIPT_DIR}/00-configmap.yaml"

echo "2/6 Applying Secret..."
kubectl apply -f "${SECRETS_DIR}/06-secret.yaml"

echo "3/6 Applying Certificate..."
kubectl apply -f "${SCRIPT_DIR}/05-certificate.yaml"

echo "4/6 Applying StatefulSet..."
kubectl apply -f "${SCRIPT_DIR}/01-statefulset.yaml"

echo "5/6 Applying Services..."
kubectl apply -f "${SCRIPT_DIR}/02-service.yaml"
kubectl apply -f "${SCRIPT_DIR}/03-service-external.yaml"

echo "6/6 Applying Gateway Route..."
kubectl apply -f "${SCRIPT_DIR}/04-gateway-route.yaml"

echo ""
echo "=== Waiting for EMQX to be ready ==="
kubectl rollout status statefulset/emqx -n "${NAMESPACE}" --timeout=120s

echo ""
echo "=== EMQX Deployment Complete ==="
echo ""
echo "Internal MQTT:  mqtt://emqx-service.${NAMESPACE}.svc.cluster.local:1883"
echo "Dashboard:      http://emqx-service.${NAMESPACE}.svc.cluster.local:18083"
echo "External WSS:   wss://mqtt.chatflowpro.live/mqtt (after DNS setup)"
echo "External MQTTS: mqtts://mqtt.chatflowpro.live:8883 (after DNS setup)"
echo ""
echo "Dashboard credentials: admin / chatflow-emqx-admin"
echo ""
echo "Next steps:"
echo "  1. Add DNS record: mqtt.chatflowpro.live -> ingress IP"
echo "  2. Verify cert-manager issues TLS certificate"
echo "  3. Test: mosquitto_pub -h emqx-service -p 1883 -t test -m hello"
echo "  4. Add MQTT auth endpoints to Go backend"
