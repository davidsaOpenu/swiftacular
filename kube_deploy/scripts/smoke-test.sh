#!/usr/bin/env bash
# smoke-test.sh — Full regression gate.
#
# Runs in order:
#   1. Unit tests        (U1 helm lint, U2 dry-run, U3 image check,
#                         U4 PMDA syntax, U5 ansible-lint, U6 dashboards)
#   2. Integration tests (I1 nodes, I2 registry, I3 pods, I4 rings,
#                         I5 Keystone, I6 proxy, I7 swiftdbinfo all nodes)
#   3. End-to-end Swift  (create/upload/list/download/SHA-256/delete)
#   4. Stress test       (N parallel uploads + downloads with throughput)
#   5. PCP monitoring    (swiftdbinfo + Redis timeseries on all storage nodes)
#
# All failures are collected; the script never aborts mid-suite.
# Exit 0 = PASS, non-zero = FAIL.
#
# Tuning env vars (override at call site):
#   NAMESPACE=swiftacular
#   REGISTRY=localhost:5001
#   PROXY_HOST_PORT=8080   (host port for Swift proxy NodePort — must match bootstrap)
#   KEYSTONE_HOST_PORT=5000 (host port for Keystone NodePort — must match bootstrap)
#   STRESS_OBJECTS=30      (number of parallel objects)
#   STRESS_SIZE_KB=64      (size of each object in KB)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib-logging.sh"

# ── configuration ─────────────────────────────────────────────────────────────
NAMESPACE="${NAMESPACE:-swiftacular}"
REGISTRY="${REGISTRY:-localhost:5001}"
if [[ -n "${JENKINS_HOME:-}" ]] || [[ -n "${CI:-}" ]]; then
  PROXY_HOST_PORT="${PROXY_HOST_PORT:-18080}"
  KEYSTONE_HOST_PORT="${KEYSTONE_HOST_PORT:-15000}"
else
  PROXY_HOST_PORT="${PROXY_HOST_PORT:-8080}"
  KEYSTONE_HOST_PORT="${KEYSTONE_HOST_PORT:-5000}"
fi
CHART_PATH="${SCRIPT_DIR}/../charts/swiftacular"
VALUES_FILE="${CHART_PATH}/values.dev.yaml"
STRESS_OBJECTS="${STRESS_OBJECTS:-30}"
STRESS_SIZE_KB="${STRESS_SIZE_KB:-64}"
SMOKE_CONTAINER="swiftacular-smoke"
STRESS_CONTAINER="swiftacular-stress"

# ── result tracking ───────────────────────────────────────────────────────────
PASS_COUNT=0; FAIL_COUNT=0; SKIP_COUNT=0
declare -a RESULTS=()

t_pass() {
  local n="$1"
  RESULTS+=("  PASS  ${n}")
  PASS_COUNT=$((PASS_COUNT + 1))
  info "  \033[0;32m✓\033[0m  ${n}"
}
t_fail() {
  local n="$1" r="${2:-}"
  RESULTS+=("  FAIL  ${n}${r:+  (${r})}")
  FAIL_COUNT=$((FAIL_COUNT + 1))
  error "  ✗  ${n}${r:+  (${r})}"
}
t_skip() {
  local n="$1" r="${2:-}"
  RESULTS+=("  SKIP  ${n}${r:+  (${r})}")
  SKIP_COUNT=$((SKIP_COUNT + 1))
  warn "  -  ${n}${r:+  (${r})}"
}
section() { echo ""; step "${*}"; }

# ── helpers ───────────────────────────────────────────────────────────────────
get_secret() {
  kubectl get secret swift-secrets -n "${NAMESPACE}" \
    -o jsonpath="{.data.${1}}" 2>/dev/null | base64 -d
}
get_proxy_pod() {
  kubectl get pod -n "${NAMESPACE}" -l app=proxy \
    --field-selector=status.phase=Running \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null
}
get_storage_pods() {
  kubectl get pod -n "${NAMESPACE}" -l app=storage \
    --field-selector=status.phase=Running \
    -o jsonpath='{.items[*].metadata.name}' 2>/dev/null
}

# swift_env: env vars for kubectl exec calls into the proxy pod
swift_env() {
  echo "OS_AUTH_URL=http://keystone-svc:5000/v3"
  echo "OS_USERNAME=${TEST_USER}"
  echo "OS_PASSWORD=${TEST_USER_PASSWORD}"
  echo "OS_PROJECT_NAME=demo"
  echo "OS_USER_DOMAIN_NAME=Default"
  echo "OS_PROJECT_DOMAIN_NAME=Default"
  echo "OS_IDENTITY_API_VERSION=3"
}

# _ks_auth: authenticate against Keystone, print "TOKEN\nPROJECT_ID".
#
# Runs curl from INSIDE the proxy pod (proxy pod → keystone-svc:5000 via
# cluster DNS).  Pod-to-pod traffic stays on the cluster network — no WSL2
# NAT hop.  --max-time 90 exceeds keystone.conf pool_timeout=60 so curl
# outlasts any DB-pool wait and receives the HTTP response instead of racing it.
#
# The JSON payload is base64-encoded and written to a temp file inside the
# proxy pod via a bash -c command.  Base64 characters (A-Za-z0-9+/=) have no
# special meaning in any shell, so the encoding survives all quoting layers.
# curl reads the body from the file (-d @/tmp/_ks_payload.json) rather than
# from an argv element, which guarantees Keystone sees the complete JSON body.
_ks_auth() {
  local payload payload_b64 result http_status token proj_id body

  payload=$(_U="${TEST_USER}" _P="${TEST_USER_PASSWORD}" python3 -c "
import json, os
print(json.dumps({'auth':{'identity':{'methods':['password'],'password':{'user':{'name':os.environ['_U'],'domain':{'name':'Default'},'password':os.environ['_P']}}},'scope':{'project':{'name':'demo','domain':{'name':'Default'}}}}}))
")

  # Encode so all JSON special chars are safe to embed in the bash -c argument.
  payload_b64=$(printf '%s' "${payload}" | base64 | tr -d '\n')

  # Write the decoded payload into a file inside the proxy pod.
  kubectl exec -n "${NAMESPACE}" "${PROXY_POD}" -- \
    bash -c "printf '%s' '${payload_b64}' | base64 -d > /tmp/_ks_payload.json" \
    2>/dev/null || true

  # Quick connectivity check: GET /v3 requires no DB, responds in <1 s.
  if ! kubectl exec -n "${NAMESPACE}" "${PROXY_POD}" -- \
      curl -sf --max-time 5 "http://keystone-svc:5000/v3" \
      >/dev/null 2>/dev/null; then
    echo "keystone-svc:5000 unreachable from proxy pod (GET /v3 timed out in 5 s)" >&2
    return 1
  fi

  # POST auth — curl reads body from the file written above.
  result=$(kubectl exec -n "${NAMESPACE}" "${PROXY_POD}" -- \
    curl -si --max-time 90 \
      -X POST "http://keystone-svc:5000/v3/auth/tokens" \
      -H "Content-Type: application/json" \
      -d "@/tmp/_ks_payload.json" \
    2>/dev/null)
  local rc=$?

  if [[ ${rc} -ne 0 ]]; then
    echo "kubectl exec failed (rc=${rc})" >&2; return 1
  fi

  http_status=$(printf '%s\n' "${result}" | head -1 | tr -d '\r' | awk '{print $2}')

  # HTTP 500 with HTML body = Apache mod_wsgi daemon crashed.
  # apache2ctl graceful restarts WSGI worker processes without dropping
  # connections; the daemon is live again after a few seconds.
  if [[ "${http_status}" == "500" ]]; then
    local ks_pod
    ks_pod=$(kubectl get pod -n "${NAMESPACE}" -l app=keystone \
      --field-selector=status.phase=Running \
      -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    if [[ -n "${ks_pod}" ]]; then
      echo "Keystone WSGI daemon unresponsive (HTTP 500) — restarting Apache WSGI processes" >&2
      kubectl exec -n "${NAMESPACE}" "${ks_pod}" -- \
        bash -c "apache2ctl graceful 2>/dev/null; true" >/dev/null 2>&1 || true
      sleep 5
      result=$(kubectl exec -n "${NAMESPACE}" "${PROXY_POD}" -- \
        curl -si --max-time 90 \
          -X POST "http://keystone-svc:5000/v3/auth/tokens" \
          -H "Content-Type: application/json" \
          -d "@/tmp/_ks_payload.json" \
        2>/dev/null)
      rc=$?
      if [[ ${rc} -ne 0 ]]; then
        echo "kubectl exec failed after WSGI restart (rc=${rc})" >&2; return 1
      fi
      http_status=$(printf '%s\n' "${result}" | head -1 | tr -d '\r' | awk '{print $2}')
    fi
  fi

  token=$(printf '%s\n' "${result}" | grep -i '^x-subject-token:' | tr -d '\r' | awk '{print $2}')
  proj_id=$(printf '%s\n' "${result}" | awk 'p; /^\r?$/{p=1}' | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['token']['project']['id'])" 2>/dev/null)

  if [[ -z "${token}" ]] || [[ -z "${proj_id}" ]]; then
    body=$(printf '%s\n' "${result}" | awk 'p; /^\r?$/{p=1}')
    echo "HTTP ${http_status:-?}: ${body}" >&2
    local ks_pod
    ks_pod=$(kubectl get pod -n "${NAMESPACE}" -l app=keystone \
      --field-selector=status.phase=Running \
      -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    if [[ -n "${ks_pod}" ]]; then
      echo "--- /var/log/keystone/keystone.log (last 60 lines) ---" >&2
      kubectl exec -n "${NAMESPACE}" "${ks_pod}" -- \
        bash -c "tail -60 /var/log/keystone/keystone.log 2>/dev/null \
                 || echo '(log not found or empty)'" >&2 2>/dev/null || true
    fi
    return 1
  fi
  printf '%s\n%s\n' "${token}" "${proj_id}"
}

cleanup() {
  # Best-effort: delete test containers if we already obtained a token.
  if [[ -n "${KS_TOKEN:-}" ]] && [[ -n "${PROJECT_ID:-}" ]]; then
    local _url="http://localhost:${PROXY_HOST_PORT}/v1/AUTH_${PROJECT_ID}"
    for _c in "${SMOKE_CONTAINER}" "${STRESS_CONTAINER}"; do
      curl -sf "${_url}/${_c}" -H "X-Auth-Token: ${KS_TOKEN}" 2>/dev/null \
        | while read -r _obj; do
            curl -sf -X DELETE "${_url}/${_c}/${_obj}" \
                 -H "X-Auth-Token: ${KS_TOKEN}" >/dev/null 2>&1 || true
          done
      curl -sf -X DELETE "${_url}/${_c}" \
           -H "X-Auth-Token: ${KS_TOKEN}" >/dev/null 2>&1 || true
    done
  fi
  rm -f /tmp/e2e-src.txt /tmp/e2e-dl.txt 2>/dev/null || true
  [[ -n "${PROXY_POD:-}" ]] && \
    kubectl exec -n "${NAMESPACE}" "${PROXY_POD}" -- \
      rm -f /tmp/_ks_payload.json >/dev/null 2>&1 || true
}
trap cleanup EXIT

# ── pre-flight (fatal — abort if cluster unreachable) ─────────────────────────
step "Pre-flight"

kubectl cluster-info >/dev/null 2>&1 \
  || { error "Cannot reach Kubernetes cluster. Is kind-swiftacular running?"; exit 1; }

PROXY_POD="$(get_proxy_pod)"
[[ -n "${PROXY_POD}" ]] \
  || { error "No running proxy pod found in namespace ${NAMESPACE}"; exit 1; }
info "Proxy pod:  ${PROXY_POD}"

TEST_USER_PASSWORD="$(get_secret keystoneTestUserPassword)"
TEST_USER="achilles"
info "Test user:  ${TEST_USER}"

# ─────────────────────────────────────────────────────────────────────────────
section "1 / UNIT TESTS"
# ─────────────────────────────────────────────────────────────────────────────

# U1 — helm lint
if command -v helm >/dev/null 2>&1; then
  if helm lint "${CHART_PATH}" >/dev/null 2>&1; then
    t_pass "U1 helm lint"
  else
    t_fail "U1 helm lint" "run 'helm lint ${CHART_PATH}' for details"
  fi
else
  t_skip "U1 helm lint" "helm not found"
fi

# U2 — helm template | kubectl apply --dry-run=client
if command -v helm >/dev/null 2>&1; then
  if helm template swiftacular "${CHART_PATH}" \
       --values "${VALUES_FILE}" 2>/dev/null \
     | kubectl apply --dry-run=client -f - >/dev/null 2>&1; then
    t_pass "U2 helm template | kubectl apply --dry-run"
  else
    t_fail "U2 helm template | kubectl apply --dry-run"
  fi
else
  t_skip "U2 helm template | kubectl apply --dry-run" "helm not found"
fi

# U3 — bluestore image in registry (S8; non-blocking, just a skip if absent)
if curl -sf "http://${REGISTRY}/v2/swiftacular-bluestore/tags/list" >/dev/null 2>&1; then
  t_pass "U3 swiftacular-bluestore image in registry"
else
  t_skip "U3 swiftacular-bluestore image in registry" "S8 build not completed yet"
fi

# U4 — swiftdbinfo PMDA Python syntax (exec into first storage pod)
FIRST_STORAGE="$(kubectl get pod -n "${NAMESPACE}" -l app=storage \
  --field-selector=status.phase=Running \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)"
PMDA_PY="/var/lib/pcp/pmdas/swiftdbinfo/pmdaswiftdbinfo.py"
if [[ -n "${FIRST_STORAGE}" ]]; then
  if kubectl exec -n "${NAMESPACE}" "${FIRST_STORAGE}" -- \
       python3 -m py_compile "${PMDA_PY}" >/dev/null 2>&1; then
    t_pass "U4 swiftdbinfo PMDA syntax (${FIRST_STORAGE})"
  else
    t_fail "U4 swiftdbinfo PMDA syntax (${FIRST_STORAGE})"
  fi
else
  t_skip "U4 swiftdbinfo PMDA syntax" "no running storage pod"
fi

# U5 — ansible-lint (informational; guards the Vagrant playbook, not the k8s stack)
if command -v ansible-lint >/dev/null 2>&1; then
  PLAYBOOK="$(cd "${SCRIPT_DIR}/../.." && pwd)/deploy_swift_cluster.yml"
  if [[ -f "${PLAYBOOK}" ]]; then
    if ansible-lint "${PLAYBOOK}" -q 2>/dev/null; then
      t_pass "U5 ansible-lint"
    else
      t_skip "U5 ansible-lint" "lint warnings in Vagrant playbook (non-blocking)"
    fi
  else
    t_skip "U5 ansible-lint" "playbook not found"
  fi
else
  t_skip "U5 ansible-lint" "ansible-lint not installed"
fi

# U6 — compile-dashboards.sh
# Requires jsonnet; jb only needed if vendor/ is absent (it is committed, so normally not needed).
# Falls back to Docker if jsonnet is not on PATH.
if command -v jsonnet >/dev/null 2>&1 || command -v docker >/dev/null 2>&1; then
  _u6_out="$(bash "${SCRIPT_DIR}/compile-dashboards.sh" 2>&1)"; _u6_rc=$?
  if [[ ${_u6_rc} -eq 0 ]]; then
    t_pass "U6 compile-dashboards.sh"
  else
    t_fail "U6 compile-dashboards.sh"
    echo "${_u6_out}" | tail -10 >&2
  fi
else
  t_skip "U6 compile-dashboards.sh" "jsonnet not installed and Docker unavailable"
fi

# ─────────────────────────────────────────────────────────────────────────────
section "2 / INTEGRATION TESTS"
# ─────────────────────────────────────────────────────────────────────────────

# I1 — ≥4 nodes Ready
READY_NODES=$(kubectl get nodes --no-headers 2>/dev/null | grep -c " Ready" || echo 0)
if [[ "${READY_NODES}" -ge 4 ]]; then
  t_pass "I1 cluster nodes Ready (${READY_NODES}/4)"
else
  t_fail "I1 cluster nodes Ready" "found ${READY_NODES}, expected ≥4"
fi

# I2 — all service images present in registry
IMGS_OK=1
for img in swiftacular-base swiftacular-storage swiftacular-proxy \
           swiftacular-keystone swiftacular-package-cache; do
  if curl -sf "http://${REGISTRY}/v2/${img}/tags/list" >/dev/null 2>&1; then
    t_pass "I2 registry: ${img}"
  else
    t_fail "I2 registry: ${img}" "not found — run build-images.sh"
    IMGS_OK=0
  fi
done

# I3 — all namespace pods Running or Completed
# awk never exits non-zero; avoids the grep -c + || echo double-output trap.
NOT_OK=$(kubectl get pods -n "${NAMESPACE}" --no-headers 2>/dev/null \
  | awk '$0 !~ /Running|Completed/{n++} END{print n+0}')
if [[ "${NOT_OK}" -eq 0 ]]; then
  t_pass "I3 all pods Running/Completed"
else
  STUCK=$(kubectl get pods -n "${NAMESPACE}" --no-headers 2>/dev/null \
    | awk '$0 !~ /Running|Completed/{printf "%s ", $1}')
  t_fail "I3 all pods Running/Completed" "${NOT_OK} stuck: ${STUCK}"
fi

# I4 — ring-builder completed AND swift-rings ConfigMap exists with ring entries.
# Ring gz files land in binaryData (not data), so we count them from the JSON
# representation of the full object; awk never exits non-zero.
RB_SUCCEEDED=$(kubectl get job ring-builder -n "${NAMESPACE}" \
  -o jsonpath='{.status.succeeded}' 2>/dev/null || true)
RB_DONE=$([[ "${RB_SUCCEEDED:-0}" -ge 1 ]] && echo "True" || echo "False")
RING_KEYS=$(kubectl get cm swift-rings -n "${NAMESPACE}" \
  -o json 2>/dev/null \
  | awk -F'"' '{for(i=2;i<=NF;i+=2) if($i ~ /ring\.gz/) n++} END{print n+0}')
if [[ "${RB_DONE}" == "True" ]] && [[ "${RING_KEYS}" -ge 3 ]]; then
  t_pass "I4 ring-builder complete, swift-rings has ${RING_KEYS} ring files"
else
  t_fail "I4 ring-builder / swift-rings" \
    "job_complete=${RB_DONE} ring_keys=${RING_KEYS}"
fi

# I5 — Keystone HTTP 200
KS_CODE=$(curl -so /dev/null -w "%{http_code}" "http://localhost:${KEYSTONE_HOST_PORT}/v3" 2>/dev/null || echo 0)
if [[ "${KS_CODE}" == "200" ]]; then
  t_pass "I5 Keystone HTTP ${KS_CODE}"
else
  t_fail "I5 Keystone HTTP 200" "got ${KS_CODE}"
fi

# I6 — Swift proxy healthcheck HTTP 200
PR_CODE=$(curl -so /dev/null -w "%{http_code}" "http://localhost:${PROXY_HOST_PORT}/healthcheck" 2>/dev/null || echo 0)
if [[ "${PR_CODE}" == "200" ]]; then
  t_pass "I6 Swift proxy healthcheck HTTP ${PR_CODE}"
else
  t_fail "I6 Swift proxy healthcheck HTTP 200" "got ${PR_CODE}"
fi

# I7 — swiftdbinfo PMDA on EVERY running storage pod
STORAGE_PODS="$(get_storage_pods)"
if [[ -z "${STORAGE_PODS}" ]]; then
  t_fail "I7 swiftdbinfo PMDA" "no running storage pods"
else
  for pod in ${STORAGE_PODS}; do
    if kubectl exec -n "${NAMESPACE}" "${pod}" -- \
         pminfo -f swiftdbinfo >/dev/null 2>&1; then
      t_pass "I7 swiftdbinfo PMDA on ${pod}"
    else
      t_fail "I7 swiftdbinfo PMDA on ${pod}"
    fi
  done
fi

# ─────────────────────────────────────────────────────────────────────────────
section "3 / END-TO-END SWIFT TEST"
# ─────────────────────────────────────────────────────────────────────────────
# Auth runs inside the proxy pod (cluster-internal DNS, no WSL2 NAT hop).
# Swift operations use the NodePort at localhost:${PROXY_HOST_PORT} which is fine — those
# transfers keep the connection busy and are not affected by the idle-timeout.

KS_TOKEN=""; PROJECT_ID=""
echo "  → Keystone auth (port-forward)..."
_auth_out=$(_ks_auth 2>&1)
_auth_rc=$?
if [[ ${_auth_rc} -eq 0 ]]; then
  KS_TOKEN=$(echo "${_auth_out}"  | head -1)
  PROJECT_ID=$(echo "${_auth_out}" | sed -n '2p')
  echo "  token=${KS_TOKEN:0:16}...  project=${PROJECT_ID}"
else
  echo "  auth error: ${_auth_out}"
fi

E2E_PASS=0
_e2e_err="Keystone auth failed"

# _curl_put: issue a PUT, print HTTP code, set _e2e_err on failure.
# Usage: _curl_put <label> <url> [extra curl args...]
_curl_put() {
  local label="$1" url="$2"; shift 2
  local body_file; body_file=$(mktemp /tmp/e2e-resp-XXXXXX.txt)
  local code
  code=$(curl -s -o "${body_file}" -w "%{http_code}" \
    -X PUT "${url}" \
    -H "X-Auth-Token: ${KS_TOKEN}" \
    "$@" 2>/dev/null)
  if [[ "${code}" =~ ^2 ]]; then
    rm -f "${body_file}"
    return 0
  fi
  _e2e_err="${label} PUT HTTP ${code}"
  echo "  ✗ ${label} PUT → HTTP ${code}" >&2
  head -5 "${body_file}" >&2
  rm -f "${body_file}"
  return 1
}

# _diag_e2e: print proxy logs and storage connectivity on E2E failure.
_diag_e2e() {
  echo "  --- proxy logs (last 40 lines) ---" >&2
  kubectl logs -n "${NAMESPACE}" "${PROXY_POD}" --tail=40 >&2 2>/dev/null || true
  echo "  --- storage connectivity from proxy pod ---" >&2
  for _sn in 0 1 2; do
    local _host="storage-${_sn}.storage-headless"
    kubectl exec -n "${NAMESPACE}" "${PROXY_POD}" -- \
      bash -c "timeout 3 bash -c \"echo >/dev/tcp/${_host}/6002\" 2>&1 \
               && echo '  ${_host}:6002 REACHABLE' \
               || echo '  ${_host}:6002 UNREACHABLE'" >&2 2>/dev/null || true
  done
  echo "  --- authtoken validation (user token, from proxy pod) ---" >&2
  kubectl exec -n "${NAMESPACE}" "${PROXY_POD}" -- \
    curl -si --max-time 10 \
      -X GET "http://keystone-svc:5000/v3/auth/tokens" \
      -H "X-Auth-Token: ${KS_TOKEN}" \
      -H "X-Subject-Token: ${KS_TOKEN}" 2>/dev/null \
    | head -5 >&2 || true
  echo "  --- swift service user auth test (from proxy pod) ---" >&2
  local _svc_pass
  _svc_pass=$(get_secret keystoneGenericServicePassword 2>/dev/null || true)
  if [[ -n "${_svc_pass}" ]]; then
    local _svc_b64
    _svc_b64=$(printf '%s' \
      "{\"auth\":{\"identity\":{\"methods\":[\"password\"],\"password\":{\"user\":{\"name\":\"swift\",\"domain\":{\"name\":\"Default\"},\"password\":\"${_svc_pass}\"}}},\"scope\":{\"project\":{\"name\":\"service\",\"domain\":{\"name\":\"Default\"}}}}}" \
      | base64 | tr -d '\n')
    kubectl exec -n "${NAMESPACE}" "${PROXY_POD}" -- \
      bash -c "printf '%s' '${_svc_b64}' | base64 -d > /tmp/_svc_payload.json && \
               curl -si --max-time 10 \
                 -X POST 'http://keystone-svc:5000/v3/auth/tokens' \
                 -H 'Content-Type: application/json' \
                 -d '@/tmp/_svc_payload.json' | head -5" \
      >&2 2>/dev/null || true
  else
    echo "  (keystoneGenericServicePassword not found in swift-secrets)" >&2
  fi
}

if [[ -n "${KS_TOKEN}" ]] && [[ -n "${PROJECT_ID}" ]]; then
  SWIFT_URL="http://localhost:${PROXY_HOST_PORT}/v1/AUTH_${PROJECT_ID}"
  _e2e_err=""

  echo "  → create container..."
  if ! _curl_put "container" "${SWIFT_URL}/${SMOKE_CONTAINER}"; then
    _diag_e2e
  fi

  if [[ -z "${_e2e_err}" ]]; then
    echo "  → write + upload..."
    echo "swiftacular-e2e-$(date +%s)" > /tmp/e2e-src.txt
    EXPECTED=$(sha256sum /tmp/e2e-src.txt | cut -d' ' -f1)
    if ! _curl_put "object" "${SWIFT_URL}/${SMOKE_CONTAINER}/e2e.txt" \
        -T /tmp/e2e-src.txt; then
      _diag_e2e
    fi
  fi

  if [[ -z "${_e2e_err}" ]]; then
    echo "  → list..."
    curl -sf "${SWIFT_URL}/${SMOKE_CONTAINER}" \
         -H "X-Auth-Token: ${KS_TOKEN}" 2>/dev/null \
      | grep -q "e2e.txt" \
      || _e2e_err="object not in listing"
  fi

  if [[ -z "${_e2e_err}" ]]; then
    echo "  → download..."
    _dl_code=$(curl -s -o /tmp/e2e-dl.txt -w "%{http_code}" \
      "${SWIFT_URL}/${SMOKE_CONTAINER}/e2e.txt" \
      -H "X-Auth-Token: ${KS_TOKEN}" 2>/dev/null)
    [[ "${_dl_code}" =~ ^2 ]] || _e2e_err="object GET HTTP ${_dl_code}"
  fi

  if [[ -z "${_e2e_err}" ]]; then
    echo "  → SHA-256 verify..."
    ACTUAL=$(sha256sum /tmp/e2e-dl.txt | cut -d' ' -f1)
    if [[ "${EXPECTED}" == "${ACTUAL}" ]]; then
      echo "  SHA-256 ${ACTUAL}  OK"
      echo "  → delete..."
      curl -sf -X DELETE "${SWIFT_URL}/${SMOKE_CONTAINER}/e2e.txt" \
           -H "X-Auth-Token: ${KS_TOKEN}" >/dev/null 2>&1 || true
      curl -sf -X DELETE "${SWIFT_URL}/${SMOKE_CONTAINER}" \
           -H "X-Auth-Token: ${KS_TOKEN}" >/dev/null 2>&1 || true
      E2E_PASS=1
    else
      _e2e_err="SHA-256 mismatch expected=${EXPECTED} actual=${ACTUAL}"
    fi
  fi
fi

if [[ "${E2E_PASS}" -eq 1 ]]; then
  t_pass "E2E Swift create/upload/list/download/SHA-256/delete"
else
  t_fail "E2E Swift create/upload/list/download/SHA-256/delete" "${_e2e_err}"
fi

# ─────────────────────────────────────────────────────────────────────────────
section "4 / STRESS TEST  (${STRESS_OBJECTS} objects × ${STRESS_SIZE_KB} KB)"
# ─────────────────────────────────────────────────────────────────────────────

STRESS_PASS=0
_stress_err=""

# Reuse token from E2E section; re-auth only if E2E auth failed.
if [[ -z "${KS_TOKEN:-}" ]]; then
  echo "  → Keystone auth (port-forward)..."
  _auth_out=$(_ks_auth 2>&1)
  _auth_rc=$?
  if [[ ${_auth_rc} -eq 0 ]]; then
    KS_TOKEN=$(echo "${_auth_out}"  | head -1)
    PROJECT_ID=$(echo "${_auth_out}" | sed -n '2p')
  else
    echo "  auth error: ${_auth_out}"
  fi
fi

if [[ -z "${KS_TOKEN:-}" ]]; then
  t_fail "Stress ${STRESS_OBJECTS}× ${STRESS_SIZE_KB} KB parallel upload/download/SHA-256" \
    "Keystone auth failed"
else
  SWIFT_URL="http://localhost:${PROXY_HOST_PORT}/v1/AUTH_${PROJECT_ID}"
  STRESS_DIR=$(mktemp -d /tmp/stress-XXXXXX)

  # Create container (idempotent)
  curl -sf -X PUT "${SWIFT_URL}/${STRESS_CONTAINER}" \
       -H "X-Auth-Token: ${KS_TOKEN}" >/dev/null 2>&1 || true

  # Generate objects on the host
  TOTAL_MB=$(python3 -c "print(round(${STRESS_OBJECTS} * ${STRESS_SIZE_KB} / 1024, 2))")
  echo "  → Generating ${STRESS_OBJECTS} × ${STRESS_SIZE_KB} KB objects..."
  for i in $(seq 1 "${STRESS_OBJECTS}"); do
    dd if=/dev/urandom of="${STRESS_DIR}/obj-${i}.bin" \
       bs=1024 count="${STRESS_SIZE_KB}" 2>/dev/null
    sha256sum "${STRESS_DIR}/obj-${i}.bin" >> "${STRESS_DIR}/sums.txt"
  done

  # Parallel upload via curl
  echo "  → Uploading ${STRESS_OBJECTS} objects (${TOTAL_MB} MB) in parallel..."
  T0=$(python3 -c "import time; print(time.time())")
  PIDS=()
  for i in $(seq 1 "${STRESS_OBJECTS}"); do
    curl -sf -X PUT "${SWIFT_URL}/${STRESS_CONTAINER}/obj-${i}.bin" \
         -H "X-Auth-Token: ${KS_TOKEN}" \
         -T "${STRESS_DIR}/obj-${i}.bin" >/dev/null 2>&1 &
    PIDS+=($!)
  done
  UPL_FAIL=0
  for pid in "${PIDS[@]}"; do wait "${pid}" || UPL_FAIL=1; done
  T1=$(python3 -c "import time; print(time.time())")

  if [[ "${UPL_FAIL}" -ne 0 ]]; then
    _stress_err="upload errors"
  else
    python3 -c "
t=${T1}-${T0}; mbs=${STRESS_OBJECTS}*${STRESS_SIZE_KB}/1024/max(t,0.001)
print(f'  Upload  {t:.1f}s  →  {mbs:.1f} MB/s')"

    # List & count
    echo "  → Listing (expected ${STRESS_OBJECTS})..."
    LISTED=$(curl -sf "${SWIFT_URL}/${STRESS_CONTAINER}" \
      -H "X-Auth-Token: ${KS_TOKEN}" 2>/dev/null | wc -l)
    if [[ "${LISTED}" -ne "${STRESS_OBJECTS}" ]]; then
      _stress_err="listed ${LISTED} objects, expected ${STRESS_OBJECTS}"
    else
      echo "  Listed ${LISTED}/${STRESS_OBJECTS} OK"

      # Parallel download via curl
      echo "  → Downloading ${STRESS_OBJECTS} objects in parallel..."
      T0=$(python3 -c "import time; print(time.time())")
      PIDS=()
      for i in $(seq 1 "${STRESS_OBJECTS}"); do
        curl -sf "${SWIFT_URL}/${STRESS_CONTAINER}/obj-${i}.bin" \
             -H "X-Auth-Token: ${KS_TOKEN}" \
             -o "${STRESS_DIR}/dl-${i}.bin" >/dev/null 2>&1 &
        PIDS+=($!)
      done
      DL_FAIL=0
      for pid in "${PIDS[@]}"; do wait "${pid}" || DL_FAIL=1; done
      T1=$(python3 -c "import time; print(time.time())")

      if [[ "${DL_FAIL}" -ne 0 ]]; then
        _stress_err="download errors"
      else
        python3 -c "
t=${T1}-${T0}; mbs=${STRESS_OBJECTS}*${STRESS_SIZE_KB}/1024/max(t,0.001)
print(f'  Download  {t:.1f}s  →  {mbs:.1f} MB/s')"

        # SHA-256 verify all
        echo "  → SHA-256 verifying all ${STRESS_OBJECTS} objects..."
        CHKSUM_FAIL=0
        for i in $(seq 1 "${STRESS_OBJECTS}"); do
          EXP=$(grep "${STRESS_DIR}/obj-${i}.bin" "${STRESS_DIR}/sums.txt" | cut -d' ' -f1)
          ACT=$(sha256sum "${STRESS_DIR}/dl-${i}.bin" | cut -d' ' -f1)
          [[ "${EXP}" == "${ACT}" ]] \
            || { echo "  FAIL: SHA-256 mismatch on obj-${i}.bin"; CHKSUM_FAIL=1; }
        done
        if [[ "${CHKSUM_FAIL}" -eq 0 ]]; then
          echo "  All ${STRESS_OBJECTS} SHA-256 checksums verified"
          STRESS_PASS=1
        else
          _stress_err="SHA-256 mismatch(es)"
        fi
      fi
    fi
  fi

  # Cleanup stress container
  curl -sf "${SWIFT_URL}/${STRESS_CONTAINER}" \
       -H "X-Auth-Token: ${KS_TOKEN}" 2>/dev/null \
    | while read -r _obj; do
        curl -sf -X DELETE "${SWIFT_URL}/${STRESS_CONTAINER}/${_obj}" \
             -H "X-Auth-Token: ${KS_TOKEN}" >/dev/null 2>&1 || true
      done
  curl -sf -X DELETE "${SWIFT_URL}/${STRESS_CONTAINER}" \
       -H "X-Auth-Token: ${KS_TOKEN}" >/dev/null 2>&1 || true
  rm -rf "${STRESS_DIR}"

  if [[ "${STRESS_PASS}" -eq 1 ]]; then
    t_pass "Stress ${STRESS_OBJECTS}× ${STRESS_SIZE_KB} KB parallel upload/download/SHA-256"
  else
    t_fail "Stress ${STRESS_OBJECTS}× ${STRESS_SIZE_KB} KB parallel upload/download/SHA-256" \
      "${_stress_err:-unknown}"
  fi
fi

# ─────────────────────────────────────────────────────────────────────────────
section "5 / PCP MONITORING  (all storage nodes)"
# ─────────────────────────────────────────────────────────────────────────────

STORAGE_PODS="$(get_storage_pods)"

if [[ -z "${STORAGE_PODS}" ]]; then
  t_fail "PCP monitoring" "no running storage pods"
else
  for pod in ${STORAGE_PODS}; do

    # swiftdbinfo PMDA registered with pmcd
    if kubectl exec -n "${NAMESPACE}" "${pod}" -- \
         pminfo -f swiftdbinfo >/dev/null 2>&1; then
      t_pass "PCP swiftdbinfo PMDA on ${pod}"
    else
      t_fail "PCP swiftdbinfo PMDA on ${pod}"
    fi

    # pmlogger → pmproxy → Redis timeseries populated
    REDIS_KEYS=$(kubectl exec -n "${NAMESPACE}" "${pod}" -- \
      redis-cli KEYS '*' 2>/dev/null | wc -l || echo 0)
    if [[ "${REDIS_KEYS}" -ge 1 ]]; then
      t_pass "PCP Redis timeseries on ${pod} (${REDIS_KEYS} keys)"
    else
      t_fail "PCP Redis timeseries on ${pod}" \
        "${REDIS_KEYS} keys — pmlogger/pmproxy may not have started yet"
    fi

  done

  # swift-recon replication health from the first storage pod
  RECON_POD=$(echo "${STORAGE_PODS}" | tr ' ' '\n' | head -1)
  if kubectl exec -n "${NAMESPACE}" "${RECON_POD}" -- \
       swift-recon -r >/dev/null 2>&1; then
    t_pass "swift-recon replication on ${RECON_POD}"
  else
    t_fail "swift-recon replication on ${RECON_POD}"
  fi
fi

# ─────────────────────────────────────────────────────────────────────────────
section "REGRESSION GATE — SUMMARY"
# ─────────────────────────────────────────────────────────────────────────────

echo ""
printf '%s\n' "────────────────────────────────────────────────────────────"
for r in "${RESULTS[@]}"; do echo "${r}"; done
printf '%s\n' "────────────────────────────────────────────────────────────"
echo ""
echo "  Passed:  ${PASS_COUNT}"
echo "  Failed:  ${FAIL_COUNT}"
echo "  Skipped: ${SKIP_COUNT}"
echo ""

if [[ "${FAIL_COUNT}" -eq 0 ]]; then
  step "REGRESSION GATE: PASS"
  exit 0
else
  error "REGRESSION GATE: FAIL  (${FAIL_COUNT} test(s) failed)"
  exit 1
fi
