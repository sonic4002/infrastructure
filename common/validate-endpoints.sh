#!/usr/bin/env bash
# =============================================================================
# Platform Endpoint Validation Script
# Tests all endpoints through the consolidated Cilium platform-gateway.
# External HTTPS -> Cloudflare -> origin: Flexible (HTTP) for chatflowpro.live,
# Full (HTTPS :443, common/02-tls-terminator.yaml) for xoffice.cloud.
#
# The customer staff clock checks (SPEC 15.7) expect clock.xoffice.cloud to be
# live (DNS, the xoffice-clock listener and clock-route applied); until then
# they fail by design. Lighthouse on the clock page is run by hand.
#
# Usage:
#   ./validate-endpoints.sh [production] [--cilium-ip <ip>] [--tls] [--k8s-only]
#
# Modes:
#   production   Use HTTPS via Cloudflare (default if no IP overrides)
#   --cilium-ip  IP address of the Cilium Gateway LoadBalancer (direct HTTP)
#   --tls        Use HTTPS (requires valid certs or --insecure)
#   --insecure   Skip TLS certificate verification (staging certs)
#   --ws-only    Only run WebSocket tests
#   --mqtt-only  Only run MQTT tests
#   --k8s-only   Only run Kubernetes health checks (skip HTTP tests)
#   --quiet      Suppress passing test output
#
# Exit code: 0 = all tests passed, 1 = one or more tests failed
# =============================================================================
set -euo pipefail

# ---------------------- Defaults ----------------------
CILIUM_IP=""
USE_TLS=false
INSECURE=false
WS_ONLY=false
MQTT_ONLY=false
K8S_ONLY=false
QUIET=false
NAMESPACE="chatflow"

API_HOST="api.chatflowpro.live"
MAIN_HOST="chatflowpro.live"
MQTT_HOST="mqtt.chatflowpro.live"
XOFFICE_HOST="xoffice.cloud"
XOFFICE_API_HOST="api.xoffice.cloud"
XOFFICE_PORTAL_HOST="customer.xoffice.cloud"
XOFFICE_CLOCK_HOST="clock.xoffice.cloud"
# A token that matches no member or kiosk; for the manifest it has the shape
# the route accepts ([A-Za-z0-9_-]{16,256}), so the route itself answers.
BOGUS_CLOCK_TOKEN="validate-endpoints-not-a-real-token"

PASS=0
FAIL=0
SKIP=0

# ---------------------- Colours ----------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# ---------------------- Argument parsing ----------------------
while [[ $# -gt 0 ]]; do
  case $1 in
    production)   USE_TLS=true;   shift ;;
    --cilium-ip)  CILIUM_IP="$2"; shift 2 ;;
    --tls)        USE_TLS=true;   shift ;;
    --insecure)   INSECURE=true;  shift ;;
    --ws-only)    WS_ONLY=true;   shift ;;
    --mqtt-only)  MQTT_ONLY=true; shift ;;
    --k8s-only)   K8S_ONLY=true;  shift ;;
    --quiet)      QUIET=true;     shift ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

# ---------------------- Helper functions ----------------------
scheme() {
  if $USE_TLS; then echo "https"; else echo "http"; fi
}

ws_scheme() {
  if $USE_TLS; then echo "wss"; else echo "ws"; fi
}

curl_opts() {
  local ip="$1"
  local opts="-s -o /dev/null -w '%{http_code}' --connect-timeout 5 --max-time 10"
  if [[ -n "$ip" ]]; then
    opts="$opts --resolve ${API_HOST}:443:${ip} --resolve ${MAIN_HOST}:443:${ip} --resolve ${MQTT_HOST}:443:${ip}"
    opts="$opts --resolve ${API_HOST}:80:${ip}  --resolve ${MAIN_HOST}:80:${ip}  --resolve ${MQTT_HOST}:80:${ip}"
    opts="$opts --resolve ${XOFFICE_HOST}:443:${ip} --resolve ${XOFFICE_API_HOST}:443:${ip}"
    opts="$opts --resolve ${XOFFICE_HOST}:80:${ip}  --resolve ${XOFFICE_API_HOST}:80:${ip}"
    opts="$opts --resolve ${XOFFICE_PORTAL_HOST}:443:${ip} --resolve ${XOFFICE_PORTAL_HOST}:80:${ip}"
    opts="$opts --resolve ${XOFFICE_CLOCK_HOST}:443:${ip} --resolve ${XOFFICE_CLOCK_HOST}:80:${ip}"
  fi
  if $INSECURE; then opts="$opts -k"; fi
  echo "$opts"
}

pass() {
  local name="$1"
  PASS=$((PASS + 1))
  if ! $QUIET; then
    echo -e "  ${GREEN}PASS${NC}  $name"
  fi
}

fail() {
  local name="$1"
  local detail="${2:-}"
  FAIL=$((FAIL + 1))
  echo -e "  ${RED}FAIL${NC}  $name  ${detail}"
}

skip() {
  local name="$1"
  SKIP=$((SKIP + 1))
  if ! $QUIET; then
    echo -e "  ${YELLOW}SKIP${NC}  $name"
  fi
}

check_http() {
  local name="$1"
  local url="$2"
  local ip="$3"
  local expected="${4:-200}"
  local method="${5:-GET}"

  local opts
  opts=$(curl_opts "$ip")
  # shellcheck disable=SC2086
  local status
  status=$(eval curl $opts -X "$method" "\"$url\"" 2>/dev/null || echo "000")
  status="${status//\'/}"

  local matched=false
  for code in $expected; do
    if [[ "$status" == "$code" ]]; then
      matched=true
      break
    fi
  done

  if $matched; then
    pass "$name (HTTP $status)"
  else
    fail "$name" "(expected HTTP $expected, got $status)"
  fi
}

check_redirect() {
  local name="$1"
  local url="$2"
  local ip="$3"
  local expected_location="${4:-https}"

  local opts
  opts=$(curl_opts "$ip")
  local output
  # shellcheck disable=SC2086
  output=$(eval curl $opts -I -w '\nLOCATION:%{redirect_url}' "\"$url\"" 2>/dev/null || echo "")
  local location
  location=$(echo "$output" | grep "^LOCATION:" | cut -d: -f2- || echo "")

  if echo "$location" | grep -q "^$expected_location"; then
    pass "$name (redirects to $location)"
  else
    fail "$name" "(expected redirect to $expected_location, got '$location')"
  fi
}

check_ws() {
  local name="$1"
  local url="$2"   # e.g. ws://api.chatflowpro.live/api/v1/users/TEST/ws?api_key=test
  local ip="$3"

  if ! command -v websocat &>/dev/null && ! command -v wscat &>/dev/null; then
    skip "$name (neither websocat nor wscat installed)"
    return
  fi

  local tool=""
  if command -v websocat &>/dev/null; then tool="websocat"; else tool="wscat"; fi

  local resolve_flag=""
  if [[ -n "$ip" ]]; then
    # websocat does not support --resolve; use /etc/hosts override via env or skip
    skip "$name (websocat cannot use custom resolve; set DNS or /etc/hosts)"
    return
  fi

  local result="fail"
  if [[ "$tool" == "websocat" ]]; then
    # Send a ping and expect any response within 3 s
    if echo '{"type":"ping"}' | timeout 3 websocat --no-close "$url" 2>/dev/null | grep -q .; then
      result="pass"
    fi
  else
    # wscat: connect and immediately close
    if echo "" | timeout 3 wscat -c "$url" 2>/dev/null | grep -q "Connected"; then
      result="pass"
    fi
  fi

  if [[ "$result" == "pass" ]]; then
    pass "$name"
  else
    fail "$name" "(WebSocket connection failed or timed out)"
  fi
}

check_mqtt_ws() {
  local name="$1"
  local host="$2"
  local ip="$3"

  if ! command -v mosquitto_pub &>/dev/null; then
    skip "$name (mosquitto_pub not installed - install mosquitto-clients)"
    return
  fi

  local port=8083
  local scheme_flag=""
  if $USE_TLS; then
    port=443
    scheme_flag="--cafile /etc/ssl/certs/ca-certificates.crt"
    if $INSECURE; then scheme_flag="--insecure"; fi
  fi

  local result="fail"
  # Attempt a CONNECT packet. mosquitto_pub exits 0 on success.
  if timeout 5 mosquitto_pub \
      -h "$host" -p "$port" \
      --websockets -t "validate/test" -m "ping" \
      -u "test-user" -P "test-pass" \
      $scheme_flag 2>/dev/null; then
    result="pass"
  fi
  # Note: auth will fail (401) but a connection-refused or TLS error = real failure
  # We only care that the transport layer works here.
  # mosquitto_pub exit code 5 = connection refused by broker (auth) = transport OK
  local exit_code=$?
  if [[ $exit_code -eq 5 || $exit_code -eq 0 ]]; then
    result="pass"
  fi

  if [[ "$result" == "pass" ]]; then
    pass "$name"
  else
    fail "$name" "(MQTT-over-WS transport test failed, exit=$exit_code)"
  fi
}

# One request, no redirects followed. Sets RESP_STATUS, RESP_HEADERS (header
# lines, lower-cased), RESP_LOCATION and RESP_BODY. Extra curl arguments (for
# example -H 'X-Clock-Token: ...') follow the method and URL. Arguments are
# passed as an array, never through eval, so header values stay intact.
fetch_response() {
  local ip="$1" method="$2" url="$3"
  shift 3
  local hdr_file body_file
  hdr_file=$(mktemp)
  body_file=$(mktemp)
  local args=(-s -o "$body_file" -D "$hdr_file" -w '%{http_code}' --connect-timeout 5 --max-time 10 -X "$method")
  if [[ -n "$ip" ]]; then
    local h
    for h in "$XOFFICE_API_HOST" "$XOFFICE_PORTAL_HOST" "$XOFFICE_CLOCK_HOST"; do
      args+=(--resolve "${h}:443:${ip}" --resolve "${h}:80:${ip}")
    done
  fi
  if $INSECURE; then args+=(-k); fi
  RESP_STATUS=$(curl "${args[@]}" "$@" "$url" 2>/dev/null) || RESP_STATUS="000"
  RESP_HEADERS=$(tr -d '\r' < "$hdr_file" | tr '[:upper:]' '[:lower:]')
  RESP_LOCATION=$(tr -d '\r' < "$hdr_file" | grep -i '^location:' | tail -n 1 | sed 's/^[Ll][Oo][Cc][Aa][Tt][Ii][Oo][Nn]:[[:space:]]*//' || true)
  RESP_BODY=$(cat "$body_file")
  rm -f "$hdr_file" "$body_file"
}

# resp_header_has <lower-case header name> <lower-case substring>
resp_header_has() {
  grep "^$1:" <<<"$RESP_HEADERS" | grep -qF -- "$2"
}

# The security headers of SPEC 12.5 on the clock pages and the manifest; prints
# what is missing (empty when everything is there).
missing_clock_security_headers() {
  local missing=()
  resp_header_has "content-security-policy" "frame-ancestors 'none'" || missing+=("content-security-policy frame-ancestors 'none'")
  local perm
  for perm in "geolocation=(self)" "publickey-credentials-create=(self)" "publickey-credentials-get=(self)" "camera=()" "microphone=()"; do
    resp_header_has "permissions-policy" "$perm" || missing+=("permissions-policy $perm")
  done
  resp_header_has "referrer-policy" "no-referrer" || missing+=("referrer-policy no-referrer")
  resp_header_has "x-content-type-options" "nosniff" || missing+=("x-content-type-options nosniff")
  if [[ ${#missing[@]} -gt 0 ]]; then
    local IFS=';'
    echo "${missing[*]}"
  fi
}

# A public attendance or reminder-action route with a bogus token: the uniform
# 404, and (when asked) Cache-Control: no-store.
check_public_not_found() {
  local name="$1" ip="$2" method="$3" url="$4" want_no_store="$5"
  shift 5
  fetch_response "$ip" "$method" "$url" "$@"
  if [[ "$RESP_STATUS" != "404" ]]; then
    fail "$name" "(expected HTTP 404, got $RESP_STATUS)"
  elif $want_no_store && ! resp_header_has "cache-control" "no-store"; then
    fail "$name" "(HTTP 404 but Cache-Control is not no-store)"
  elif $want_no_store; then
    pass "$name (HTTP 404, Cache-Control: no-store)"
  else
    pass "$name (HTTP 404)"
  fi
}

# A clock or kiosk page on the clock host: 200, noindex, security headers.
check_clock_page() {
  local name="$1" ip="$2" url="$3"
  fetch_response "$ip" GET "$url"
  if [[ "$RESP_STATUS" != "200" ]]; then
    fail "$name" "(expected HTTP 200, got $RESP_STATUS)"
    return
  fi
  if ! resp_header_has "x-robots-tag" "noindex" \
     && ! grep -qiE '<meta[^>]*name="robots"[^>]*noindex' <<<"$RESP_BODY"; then
    fail "$name" "(HTTP 200 but no noindex meta tag or X-Robots-Tag)"
    return
  fi
  local missing
  missing=$(missing_clock_security_headers)
  if [[ -n "$missing" ]]; then
    fail "$name" "(missing: $missing)"
    return
  fi
  pass "$name (HTTP 200, noindex, security headers)"
}

# The clock's web manifest: 200 and the security headers.
check_clock_manifest() {
  local name="$1" ip="$2" url="$3"
  fetch_response "$ip" GET "$url"
  if [[ "$RESP_STATUS" != "200" ]]; then
    fail "$name" "(expected HTTP 200, got $RESP_STATUS)"
    return
  fi
  local missing
  missing=$(missing_clock_security_headers)
  if [[ -n "$missing" ]]; then
    fail "$name" "(missing: $missing)"
    return
  fi
  pass "$name (HTTP 200, security headers)"
}

# /c and /k on another host: a permanent 301 to the same path on the clock host.
check_clock_moved() {
  local name="$1" ip="$2" url="$3" expected_location="$4"
  fetch_response "$ip" GET "$url"
  if [[ "$RESP_STATUS" == "301" && "$RESP_LOCATION" == "$expected_location" ]]; then
    pass "$name (HTTP 301 to $RESP_LOCATION)"
  else
    fail "$name" "(expected HTTP 301 to $expected_location, got $RESP_STATUS '${RESP_LOCATION}')"
  fi
}

# ---------------------- Print header ----------------------
header() {
  local label="$1"
  echo ""
  echo -e "${BLUE}=== $label ===${NC}"
}

# ---------------------- Test suites ----------------------
run_http_tests() {
  local label="$1"
  local ip="$2"

  if $WS_ONLY || $MQTT_ONLY; then return; fi

  header "$label - HTTP Tests"

  local base
  base="$(scheme)://${API_HOST}"
  if [[ -n "$ip" ]]; then :; fi

  # API health endpoints
  check_http "GET /health" "${base}/health" "$ip" "200"
  check_http "GET /ready"  "${base}/ready"  "$ip" "200"

  # API v1 - expect 401 (no API key) which proves routing works
  check_http "GET /api/v1/ (no auth -> 401)" "${base}/api/v1/organizations" "$ip" "401"

  # Metrics endpoint
  check_http "GET /metrics" "${base}/metrics" "$ip" "200"

  # Internal endpoint (should be 401/403 from outside, NOT 404)
  check_http "GET /internal/ (routed, auth fails)" "${base}/internal/status" "$ip" "401 403"

  # Main domain: Flutter SPA
  local main_base
  main_base="$(scheme)://${MAIN_HOST}"
  check_http "GET chatflowpro.live/ (SPA index)" "${main_base}/" "$ip" "200"
  check_http "GET /healthz (Flutter web container)" "${main_base}/healthz" "$ip" "200"
  check_http "GET /delete-account (Google Play page)" "${main_base}/delete-account" "$ip" "200"
  check_http "GET /health (apex health)" "${main_base}/health" "$ip" "200"

  # Google Play compliance POST endpoint (empty body -> 400, not 404)
  check_http "POST /api/v1/account/delete-request (routed)" \
    "${main_base}/api/v1/account/delete-request" "$ip" "400" "POST"
}

run_redirect_tests() {
  local label="$1"
  local ip="$2"

  if $WS_ONLY || $MQTT_ONLY || ! $USE_TLS; then return; fi

  header "$label - HTTP->HTTPS Redirect Tests"

  check_redirect "api.chatflowpro.live HTTP redirect" \
    "http://${API_HOST}/health" "$ip" "https"
  check_redirect "chatflowpro.live HTTP redirect" \
    "http://${MAIN_HOST}/" "$ip" "https"
  check_redirect "mqtt.chatflowpro.live HTTP redirect" \
    "http://${MQTT_HOST}/mqtt" "$ip" "https"
}

run_ws_tests() {
  local label="$1"
  local ip="$2"

  if $MQTT_ONLY; then return; fi

  header "$label - WebSocket Tests"

  local ws_url
  ws_url="$(ws_scheme)://${API_HOST}/api/v1/users/TEST_USER_ID/ws?api_key=test-key"
  check_ws "WS /api/v1/users/{id}/ws" "$ws_url" "$ip"
}

run_mqtt_tests() {
  local label="$1"
  local ip="$2"

  if $WS_ONLY; then return; fi

  header "$label - MQTT-over-WebSocket Tests"

  check_mqtt_ws "MQTT WS mqtt.chatflowpro.live/mqtt" "$MQTT_HOST" "$ip"
}

run_xoffice_tests() {
  local label="$1"
  local ip="$2"

  if $WS_ONLY || $MQTT_ONLY; then return; fi

  header "$label - xoffice Tests"

  local xoffice_base xoffice_api_base xoffice_portal_base
  xoffice_base="$(scheme)://${XOFFICE_HOST}"
  xoffice_portal_base="$(scheme)://${XOFFICE_PORTAL_HOST}"
  xoffice_api_base="$(scheme)://${XOFFICE_API_HOST}"

  # xoffice frontend (Next.js SPA) - expected 200
  check_http "GET xoffice.cloud/" "${xoffice_base}/" "$ip" "200"

  # Customer portal (same frontend, portal mode by host) - the login page
  # answers 200; any other path on this host redirects into the portal.
  check_http "GET customer.xoffice.cloud/he/customer-portal/login" "${xoffice_portal_base}/he/customer-portal/login" "$ip" "200"

  # xoffice API health - expected 200
  check_http "GET api.xoffice.cloud/api/health/" "${xoffice_api_base}/api/health/" "$ip" "200"

  # xoffice API root (no auth) - expected 401 or 403, not 404
  check_http "GET api.xoffice.cloud/ (no auth -> 401|403)" "${xoffice_api_base}/" "$ip" "401 403"

  run_xoffice_clock_tests "$ip"
}

# Customer staff clock (SPEC 15.7): public API routes, the clock host, the 301
# from the portal host. Tokens travel only in headers, never in a URL.
run_xoffice_clock_tests() {
  local ip="$1"
  local api_base portal_base clock_base clock_origin
  api_base="$(scheme)://${XOFFICE_API_HOST}"
  portal_base="$(scheme)://${XOFFICE_PORTAL_HOST}"
  clock_base="$(scheme)://${XOFFICE_CLOCK_HOST}"
  # The frontend always redirects to the production clock origin (https).
  clock_origin="https://${XOFFICE_CLOCK_HOST}"

  check_public_not_found "GET api.xoffice.cloud/attendance-clock/state (bogus token)" "$ip" \
    GET "${api_base}/attendance-clock/state" true -H "X-Clock-Token: ${BOGUS_CLOCK_TOKEN}"
  check_public_not_found "GET api.xoffice.cloud/attendance-kiosk/state (bogus token)" "$ip" \
    GET "${api_base}/attendance-kiosk/state" true -H "X-Kiosk-Token: ${BOGUS_CLOCK_TOKEN}"
  check_public_not_found "POST api.xoffice.cloud/reminder-actions (bogus token)" "$ip" \
    POST "${api_base}/reminder-actions" false -H "X-Reminder-Action: ${BOGUS_CLOCK_TOKEN}" \
    -H "Content-Type: application/json" --data '{"action":"snooze"}'

  check_clock_moved "customer.xoffice.cloud/he/c/x -> 301 clock host" "$ip" \
    "${portal_base}/he/c/x" "${clock_origin}/he/c/x"

  check_clock_page "GET clock.xoffice.cloud/he/c/x" "$ip" "${clock_base}/he/c/x"
  check_clock_page "GET clock.xoffice.cloud/he/k/x" "$ip" "${clock_base}/he/k/x"
  check_clock_manifest "GET clock.xoffice.cloud/he/c/{token}/manifest.webmanifest" "$ip" \
    "${clock_base}/he/c/${BOGUS_CLOCK_TOKEN}/manifest.webmanifest"

  skip "Clock page Lighthouse (mobile, Slow 4G, 4x CPU: LCP <= 2.5 s, button interactive <= 3.5 s, JS <= 200 KB gz, no third-party request) - run by hand before release"
}

run_k8s_health_checks() {
  header "Kubernetes Resource Health"

  if ! command -v kubectl &>/dev/null; then
    skip "kubectl not available"
    return
  fi

  # Gateway status
  local gw_status
  gw_status=$(kubectl get gateway platform-gateway -n gateway \
    -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}' 2>/dev/null || echo "Unknown")
  if [[ "$gw_status" == "True" ]]; then
    pass "Gateway platform-gateway is Programmed"
  else
    fail "Gateway platform-gateway" "(Programmed=$gw_status)"
  fi

  # Check all HTTPRoutes are accepted (chatflow namespace)
  for route in api-route main-route mqtt-route; do
    local accepted
    accepted=$(kubectl get httproute "$route" -n chatflow \
      -o jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}' 2>/dev/null || echo "Unknown")
    if [[ "$accepted" == "True" ]]; then
      pass "HTTPRoute chatflow/$route is Accepted"
    else
      fail "HTTPRoute chatflow/$route" "(Accepted=$accepted)"
    fi
  done

  # Check all HTTPRoutes are accepted (xoffice namespace)
  for route in api-route frontend-route clock-route; do
    local accepted
    accepted=$(kubectl get httproute "$route" -n xoffice \
      -o jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}' 2>/dev/null || echo "Unknown")
    if [[ "$accepted" == "True" ]]; then
      pass "HTTPRoute xoffice/$route is Accepted"
    else
      fail "HTTPRoute xoffice/$route" "(Accepted=$accepted)"
    fi
  done

  # Verify no orphaned Ingress resources remain
  local ingress_count
  ingress_count=$(kubectl get ingress -A --no-headers 2>/dev/null | wc -l | tr -d ' ')
  if [[ "$ingress_count" -eq 0 ]]; then
    pass "No orphaned Ingress resources (kubectl get ingress -A)"
  else
    fail "Orphaned Ingress resources found" "($ingress_count remaining)"
  fi

  # Verify only platform-gateway exists
  local gw_count
  gw_count=$(kubectl get gateway -A --no-headers 2>/dev/null | wc -l | tr -d ' ')
  if [[ "$gw_count" -eq 1 ]]; then
    pass "Single gateway exists (platform-gateway)"
  else
    fail "Unexpected gateway count" "(expected 1, found $gw_count)"
  fi

  # Check orchestrator pods are Running
  local orch_ready
  orch_ready=$(kubectl get deployment whatsapp-orchestrator -n "$NAMESPACE" \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
  if [[ "${orch_ready:-0}" -ge 1 ]]; then
    pass "whatsapp-orchestrator has $orch_ready ready replica(s)"
  else
    fail "whatsapp-orchestrator" "(readyReplicas=${orch_ready:-0})"
  fi

  # Check EMQX StatefulSet
  local emqx_ready
  emqx_ready=$(kubectl get statefulset emqx -n "$NAMESPACE" \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
  if [[ "${emqx_ready:-0}" -ge 1 ]]; then
    pass "EMQX StatefulSet has $emqx_ready ready replica(s)"
  else
    fail "EMQX StatefulSet" "(readyReplicas=${emqx_ready:-0})"
  fi

  # Check chatflow-web deployment
  local web_ready
  web_ready=$(kubectl get deployment chatflow-web -n "$NAMESPACE" \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
  if [[ "${web_ready:-0}" -ge 1 ]]; then
    pass "chatflow-web has $web_ready ready replica(s)"
  else
    fail "chatflow-web" "(readyReplicas=${web_ready:-0})"
  fi
}

# ---------------------- Main ----------------------
echo ""
echo "============================================="
echo " Platform Endpoint Validation (Cilium Gateway)"
echo " API:  $(scheme)://${API_HOST}"
echo " Web:  $(scheme)://${MAIN_HOST}"
echo " MQTT: $(scheme)://${MQTT_HOST}/mqtt"
echo " xoffice: $(scheme)://${XOFFICE_HOST}"
echo " xoffice API: $(scheme)://${XOFFICE_API_HOST}"
echo " xoffice clock: $(scheme)://${XOFFICE_CLOCK_HOST}"
if [[ -n "$CILIUM_IP" ]]; then echo " Cilium IP: $CILIUM_IP"; fi
echo "============================================="

# Always run K8s health checks (they use kubectl, not HTTP)
run_k8s_health_checks

if ! $K8S_ONLY; then
  if [[ -n "$CILIUM_IP" ]]; then
    run_http_tests     "Cilium" "$CILIUM_IP"
    run_redirect_tests "Cilium" "$CILIUM_IP"
    run_ws_tests       "Cilium" "$CILIUM_IP"
    run_mqtt_tests     "Cilium" "$CILIUM_IP"
    run_xoffice_tests  "Cilium" "$CILIUM_IP"
  else
    # No IP overrides: rely on real DNS (via Cloudflare)
    run_http_tests     "Production DNS" ""
    run_redirect_tests "Production DNS" ""
    run_ws_tests       "Production DNS" ""
    run_mqtt_tests     "Production DNS" ""
    run_xoffice_tests  "Production DNS" ""
  fi
fi

# ---------------------- Summary ----------------------
echo ""
echo "============================================="
echo -e " Results: ${GREEN}${PASS} passed${NC}  ${RED}${FAIL} failed${NC}  ${YELLOW}${SKIP} skipped${NC}"
echo "============================================="
echo ""

if [[ $FAIL -gt 0 ]]; then
  echo -e "${RED}VALIDATION FAILED - do NOT proceed to next migration phase${NC}"
  exit 1
else
  echo -e "${GREEN}All tests passed - safe to proceed${NC}"
  exit 0
fi
