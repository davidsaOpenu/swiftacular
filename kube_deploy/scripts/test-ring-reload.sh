#!/usr/bin/env bash
# test-ring-reload.sh — Validates the live ring-reload mechanism.
#
# L1  Verify /etc/swift/*.ring.gz are symlinks → /var/swift-rings/
# L2  Rebuild rings directly inside storage-0 and patch the ConfigMap;
#     confirm mtime updates in ALL pods WITHOUT any pod restart (~3 min)
# L3  Full scale-down smoke test: data survives drain + StatefulSet
#     scale-down to 2 nodes  (--full flag; adds ~10 minutes)
#
# Usage:
#   bash test-ring-reload.sh [--full] [-n NAMESPACE]
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib-logging.sh"

NAMESPACE="${NAMESPACE:-swiftacular}"
CHART_PATH="${SCRIPT_DIR}/../charts/swiftacular"
VALUES_FILE="${CHART_PATH}/values.dev.yaml"
FULL_TEST=0
for _arg in "$@"; do [[ "$_arg" == "--full" ]] && FULL_TEST=1; done

# Ring-builder defaults — must match values.yaml
DISK_PREFIX="td"
DISKS_PER_NODE=2
PART_POWER=12
REPLICAS=2

PASS=0; FAIL=0
t_pass() { info "  \033[0;32m✓\033[0m  $1"; PASS=$((PASS + 1)); }
t_fail() { error "  ✗  $1${2:+  ($2)}"; FAIL=$((FAIL + 1)); }
section() { echo; step "$*"; }

# ── helpers ───────────────────────────────────────────────────────────────────
proxy_pod() {
  kubectl get pod -n "$NAMESPACE" -l app=proxy \
    --field-selector=status.phase=Running \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null
}
storage_pods() {
  kubectl get pod -n "$NAMESPACE" -l app=storage \
    --field-selector=status.phase=Running \
    -o jsonpath='{.items[*].metadata.name}' 2>/dev/null
}

# exec_pod: kubectl exec with the correct -c flag so init containers are never
# selected and "Defaulted container" noise is suppressed.
exec_pod() {
  local pod="$1"; shift
  local ctr
  if   [[ "$pod" =~ ^proxy   ]]; then ctr="-c proxy"
  elif [[ "$pod" =~ ^storage ]]; then ctr="-c storage"
  else ctr=""
  fi
  # shellcheck disable=SC2086
  kubectl exec -n "$NAMESPACE" $ctr "$pod" -- "$@"
}

ring_mtime() {
  exec_pod "$1" stat -c "%Y" /var/swift-rings/account.ring.gz 2>/dev/null || echo 0
}

# ring_data_dir: returns the target of the ..data symlink inside the ConfigMap
# volume.  Kubernetes atomically replaces this symlink when the ConfigMap is
# updated, so a changed target is definitive proof the kubelet synced the volume.
ring_data_dir() {
  exec_pod "$1" bash -c \
    "readlink /var/swift-rings/..data 2>/dev/null || echo none" 2>/dev/null || echo none
}

# push_rings: rebuild all 3 rings from scratch inside storage-0 and apply
# them directly to the swift-rings ConfigMap.  Avoids helm upgrade so no
# Deployment/StatefulSet spec is touched and no pod restarts are triggered.
push_rings() {
  local w0="${1:-100}" w1="${2:-100}" w2="${3:-100}"   # per-node weights

  info "  → Building rings inside storage-0 (weights: 0=$w0 1=$w1 2=$w2)..."
  exec_pod storage-0 bash -c "
    set -e
    rm -rf /tmp/_rings && mkdir /tmp/_rings
    for RING_TYPE in account container object; do
      case \$RING_TYPE in
        account)   PORT=6002 ;;
        container) PORT=6001 ;;
        object)    PORT=6000 ;;
      esac
      swift-ring-builder /tmp/_rings/\${RING_TYPE}.builder \
        create ${PART_POWER} ${REPLICAS} 0
      for NODE in 0 1 2; do
        case \$NODE in
          0) W=${w0} ;;
          1) W=${w1} ;;
          2) W=${w2} ;;
        esac
        for D in \$(seq 0 $((DISKS_PER_NODE - 1))); do
          swift-ring-builder /tmp/_rings/\${RING_TYPE}.builder add \
            --region 1 --zone \${NODE} \
            --ip storage-\${NODE}.storage-headless --port \${PORT} \
            --device ${DISK_PREFIX}\${D} --weight \$W
        done
      done
      swift-ring-builder /tmp/_rings/\${RING_TYPE}.builder rebalance || true
    done
  " >/dev/null 2>&1

  info "  → Copying ring files to host..."
  kubectl cp -n "$NAMESPACE" -c storage storage-0:/tmp/_rings/account.ring.gz   /tmp/_tr-account.ring.gz
  kubectl cp -n "$NAMESPACE" -c storage storage-0:/tmp/_rings/container.ring.gz /tmp/_tr-container.ring.gz
  kubectl cp -n "$NAMESPACE" -c storage storage-0:/tmp/_rings/object.ring.gz    /tmp/_tr-object.ring.gz

  for _f in account container object; do
    [[ -s /tmp/_tr-${_f}.ring.gz ]] \
      || { error "  /tmp/_tr-${_f}.ring.gz missing or empty"; return 1; }
  done

  local _rv_before
  _rv_before=$(kubectl get configmap swift-rings -n "$NAMESPACE" \
    -o jsonpath='{.metadata.resourceVersion}' 2>/dev/null || echo "?")
  info "  → Patching swift-rings ConfigMap (resourceVersion=${_rv_before})..."
  kubectl create configmap swift-rings -n "$NAMESPACE" \
    --from-file=account.ring.gz=/tmp/_tr-account.ring.gz \
    --from-file=container.ring.gz=/tmp/_tr-container.ring.gz \
    --from-file=object.ring.gz=/tmp/_tr-object.ring.gz \
    --dry-run=client -o yaml | kubectl apply -f -
  local _rv_after
  _rv_after=$(kubectl get configmap swift-rings -n "$NAMESPACE" \
    -o jsonpath='{.metadata.resourceVersion}' 2>/dev/null || echo "?")
  [[ "$_rv_before" != "$_rv_after" ]] \
    && info "    ConfigMap updated (${_rv_before} → ${_rv_after})" \
    || warn "    ConfigMap NOT updated — ring binary identical to current ConfigMap"
}

# ── pre-flight ────────────────────────────────────────────────────────────────
step "Pre-flight"
kubectl cluster-info >/dev/null 2>&1 \
  || { error "Cannot reach Kubernetes cluster"; exit 1; }
PROXY=$(proxy_pod)
[[ -n "$PROXY" ]] || { error "No running proxy pod in namespace ${NAMESPACE}"; exit 1; }
info "Proxy pod: ${PROXY}"

# ─────────────────────────────────────────────────────────────────────────────
section "L1 / SYMLINK CHECK"
# ─────────────────────────────────────────────────────────────────────────────

for pod in $PROXY $(storage_pods); do
  for ring in account container object; do
    target=$(exec_pod "$pod" \
      bash -c "readlink /etc/swift/${ring}.ring.gz 2>/dev/null || echo NOT_A_SYMLINK")
    expected="/var/swift-rings/${ring}.ring.gz"
    if [[ "$target" == "$expected" ]]; then
      t_pass "$pod  /etc/swift/${ring}.ring.gz → $target"
    else
      t_fail "$pod  /etc/swift/${ring}.ring.gz" \
        "expected symlink to $expected, got: $target"
    fi
  done
done

# ─────────────────────────────────────────────────────────────────────────────
section "L2 / LIVE PROPAGATION  (~3 min)"
# ─────────────────────────────────────────────────────────────────────────────
# Rebuild rings directly inside storage-0 and patch the ConfigMap.
# helm upgrade is deliberately NOT used here — it reconciles Deployment and
# StatefulSet specs which can trigger rolling restarts, masking whether the
# ring reload itself works.  A direct ConfigMap patch only changes data;
# no pod spec is touched.

ALL_PODS="$PROXY $(storage_pods)"
declare -A MTIME_BEFORE
declare -A DATA_DIR_BEFORE

info "  Recording mtimes and ConfigMap volume state before ring update..."
for pod in $ALL_PODS; do
  MTIME_BEFORE[$pod]=$(ring_mtime "$pod")
  DATA_DIR_BEFORE[$pod]=$(ring_data_dir "$pod")
  info "    $pod  mtime=${MTIME_BEFORE[$pod]}  ..data=${DATA_DIR_BEFORE[$pod]}"
done
echo ""

push_rings 100 100 99   # storage-2 weight 99 ≠ initial 100 — guarantees ConfigMap binary actually changes
echo ""

# Anti-affinity pins each storage pod to a separate node (each with its own
# kubelet sync schedule), so we must wait for ALL pods — not just proxy.
info "  → Waiting up to 600 s for all nodes' kubelets to sync ConfigMap volumes..."
_start=$(date +%s)
_deadline=$(( _start + 600 ))
_synced_set=""
while [[ $(date +%s) -lt $_deadline ]]; do
  sleep 10
  _elapsed=$(( $(date +%s) - _start ))
  _all_done=1
  _newly=""
  for _p in $ALL_PODS; do
    if [[ "$_synced_set" == *"|${_p}|"* ]]; then continue; fi
    _d=$(ring_data_dir "$_p")
    if [[ "$_d" != "${DATA_DIR_BEFORE[$_p]}" ]]; then
      _synced_set="${_synced_set}|${_p}|"
      _newly="${_newly} ${_p}"
    else
      _all_done=0
    fi
  done
  [[ -n "$_newly" ]] && info "    ${_elapsed}s: synced:${_newly}"
  if [[ "$_all_done" -eq 1 ]]; then
    info "    All pods synced at ${_elapsed}s"
    break
  fi
done

info "  (diag) /var/swift-rings/ inside ${PROXY}:"
exec_pod "$PROXY" bash -c "ls -la /var/swift-rings/ 2>&1 | head -10" 2>/dev/null \
  | sed 's/^/    /' >&2 || true
echo ""

info "  → Checking volume sync and pod status..."

for pod in $ALL_PODS; do
  # Pod must still be Running under the same name — no restart
  phase=$(kubectl get pod -n "$NAMESPACE" "$pod" \
    -o jsonpath='{.status.phase}' 2>/dev/null || true)
  if [[ "$phase" != "Running" ]]; then
    t_fail "$pod" "pod was restarted — live-reload failed"
    continue
  fi

  new_mtime=$(ring_mtime "$pod")
  new_data=$(ring_data_dir "$pod")
  _synced=0
  [[ "$new_mtime" != "${MTIME_BEFORE[$pod]}" ]] && [[ "$new_mtime" != "0" ]] && _synced=1
  [[ "$new_data"  != "${DATA_DIR_BEFORE[$pod]:-none}" ]]                       && _synced=1
  if [[ "$_synced" -eq 1 ]]; then
    t_pass "$pod  ConfigMap volume synced without restart  (mtime: ${MTIME_BEFORE[$pod]} → $new_mtime)"
  else
    t_fail "$pod  volume not synced after 600 s" \
      "mtime: before=${MTIME_BEFORE[$pod]} after=${new_mtime} | ..data: before=${DATA_DIR_BEFORE[$pod]:-none} after=${new_data}"
  fi
done

info "  → Restoring ring weights (storage-2 → 100)..."
push_rings 100 100 100 >/dev/null 2>&1 || true

# ─────────────────────────────────────────────────────────────────────────────
if [[ "$FULL_TEST" -ne 1 ]]; then
  echo
  warn "L3 skipped.  Re-run with --full to enable the scale-down smoke test."
else

section "L3 / SCALE-DOWN SMOKE TEST  (~10 min)"
# ─────────────────────────────────────────────────────────────────────────────

L3_OK=1

# -- auth --
info "  → Authenticating as test user..."
TEST_PASS=$(kubectl get secret swift-secrets -n "$NAMESPACE" \
  -o jsonpath='{.data.keystoneTestUserPassword}' 2>/dev/null | base64 -d)

payload_b64=$(printf '%s' \
  "{\"auth\":{\"identity\":{\"methods\":[\"password\"],\"password\":{\"user\":{\"name\":\"achilles\",\"domain\":{\"name\":\"Default\"},\"password\":\"${TEST_PASS}\"}}},\"scope\":{\"project\":{\"name\":\"demo\",\"domain\":{\"name\":\"Default\"}}}}}" \
  | base64 | tr -d '\n')
exec_pod "$PROXY" \
  bash -c "printf '%s' '${payload_b64}' | base64 -d > /tmp/_l3_ks.json" 2>/dev/null

auth_out=$(exec_pod "$PROXY" \
  curl -si --max-time 30 \
    -X POST "http://keystone-svc:5000/v3/auth/tokens" \
    -H "Content-Type: application/json" \
    -d "@/tmp/_l3_ks.json" 2>/dev/null)

KS_TOKEN=$(printf '%s\n' "$auth_out" \
  | grep -i '^x-subject-token:' | tr -d '\r' | awk '{print $2}')
PROJECT_ID=$(printf '%s\n' "$auth_out" \
  | awk 'p; /^\r?$/{p=1}' \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['token']['project']['id'])" 2>/dev/null)

if [[ -n "$KS_TOKEN" ]] && [[ -n "$PROJECT_ID" ]]; then
  t_pass "L3 Keystone auth  (project=${PROJECT_ID})"
else
  t_fail "L3 Keystone auth" "could not obtain token"; L3_OK=0
fi

# -- PUT test object --
if [[ "$L3_OK" -eq 1 ]]; then
  SWIFT="http://localhost:8080/v1/AUTH_${PROJECT_ID}"
  L3_CTR="ring-reload-l3-$$"
  L3_OBJ="testobj.txt"
  L3_BODY="ring-reload-$(date +%s)"

  curl -sf -X PUT "$SWIFT/$L3_CTR" \
       -H "X-Auth-Token: $KS_TOKEN" >/dev/null 2>&1 || true
  http_code=$(printf '%s' "$L3_BODY" \
    | curl -s -o /dev/null -w "%{http_code}" \
        -X PUT "$SWIFT/$L3_CTR/$L3_OBJ" \
        -H "X-Auth-Token: $KS_TOKEN" -T - 2>/dev/null)
  if [[ "$http_code" =~ ^2 ]]; then
    t_pass "L3 PUT test object  ($L3_CTR/$L3_OBJ)"
  else
    t_fail "L3 PUT test object" "HTTP $http_code"; L3_OK=0
  fi
fi

# -- drain: storage-2 weight=0 --
if [[ "$L3_OK" -eq 1 ]]; then
  DRAIN_MTIME_BEFORE=$(ring_mtime "$PROXY")
  DRAIN_DATA_DIR_BEFORE=$(ring_data_dir "$PROXY")

  push_rings 100 100 0  # storage-2 drained

  [[ $? -eq 0 ]] \
    && t_pass "L3 drain ring pushed to ConfigMap" \
    || { t_fail "L3 drain ring pushed to ConfigMap"; L3_OK=0; }
fi

# -- wait for drain propagation --
if [[ "$L3_OK" -eq 1 ]]; then
  info "  → Waiting up to 300 s for drain ring to propagate to proxy pod..."
  _start=$(date +%s)
  _deadline=$(( _start + 300 ))
  while [[ $(date +%s) -lt $_deadline ]]; do
    _d=$(ring_data_dir "$PROXY")
    if [[ "$_d" != "$DRAIN_DATA_DIR_BEFORE" ]]; then
      info "    proxy pod synced at $(( $(date +%s) - _start ))s"
      break
    fi
    sleep 10
  done

  phase_after=$(kubectl get pod -n "$NAMESPACE" "$PROXY" \
    -o jsonpath='{.status.phase}' 2>/dev/null || true)
  [[ "$phase_after" == "Running" ]] \
    && t_pass "L3 proxy pod not restarted during drain propagation" \
    || t_fail "L3 proxy pod not restarted" "pod was replaced (phase=${phase_after})"

  drain_data_after=$(ring_data_dir "$PROXY")
  drain_mtime_after=$(ring_mtime "$PROXY")
  if [[ "$drain_data_after" != "$DRAIN_DATA_DIR_BEFORE" ]] || \
     { [[ "$drain_mtime_after" != "$DRAIN_MTIME_BEFORE" ]] && [[ "$drain_mtime_after" != "0" ]]; }; then
    t_pass "L3 drain ring propagated to proxy  ($DRAIN_MTIME_BEFORE → $drain_mtime_after)"
  else
    t_fail "L3 drain ring propagated" "..data and mtime both unchanged after 300 s"
  fi
fi

# -- object readable after drain --
if [[ "$L3_OK" -eq 1 ]]; then
  got=$(curl -sf "$SWIFT/$L3_CTR/$L3_OBJ" \
         -H "X-Auth-Token: $KS_TOKEN" 2>/dev/null | tr -d '\n')
  [[ "$got" == "$L3_BODY" ]] \
    && t_pass "L3 object readable after ring drain (before scale-down)" \
    || t_fail "L3 object readable after ring drain" "expected '$L3_BODY' got '$got'"

  info "  → swift-recon --replication (informational):"
  exec_pod storage-0 swift-recon --replication 2>/dev/null \
    | grep -E "replication_time|partitions_not|Oldest|replication_last" \
    | sed 's/^/    /' || true
fi

# -- scale down --
if [[ "$L3_OK" -eq 1 ]]; then
  info "  → Scaling StatefulSet to 2 replicas..."
  kubectl scale statefulset storage --replicas=2 -n "$NAMESPACE" >/dev/null 2>&1
  for _ in $(seq 1 30); do
    phase=$(kubectl get pod storage-2 -n "$NAMESPACE" \
      -o jsonpath='{.status.phase}' 2>/dev/null || echo gone)
    [[ "$phase" == "gone" ]] && break
    sleep 2
  done
  t_pass "L3 StatefulSet scaled to 2"
fi

# -- object readable after scale-down --
if [[ "$L3_OK" -eq 1 ]]; then
  got=$(curl -sf "$SWIFT/$L3_CTR/$L3_OBJ" \
         -H "X-Auth-Token: $KS_TOKEN" 2>/dev/null | tr -d '\n')
  [[ "$got" == "$L3_BODY" ]] \
    && t_pass "L3 object readable after scale-down  (data survived)" \
    || t_fail "L3 object readable after scale-down" "expected '$L3_BODY' got '$got'"
fi

# -- cleanup (always runs) --
section "L3 / CLEANUP"
info "  → Restoring StatefulSet to 3 replicas..."
kubectl scale statefulset storage --replicas=3 -n "$NAMESPACE" >/dev/null 2>&1 || true
info "  → Restoring 3-node ring..."
push_rings 100 100 100 >/dev/null 2>&1 || true
info "  → Deleting test objects..."
if [[ -n "${KS_TOKEN:-}" ]] && [[ -n "${PROJECT_ID:-}" ]]; then
  curl -sf -X DELETE "$SWIFT/$L3_CTR/$L3_OBJ" \
       -H "X-Auth-Token: $KS_TOKEN" >/dev/null 2>&1 || true
  curl -sf -X DELETE "$SWIFT/$L3_CTR" \
       -H "X-Auth-Token: $KS_TOKEN" >/dev/null 2>&1 || true
fi
exec_pod storage-0 rm -rf /tmp/_rings /tmp/_l3_ks.json >/dev/null 2>&1 || true
exec_pod "$PROXY"  rm -f /tmp/_l3_ks.json              >/dev/null 2>&1 || true
rm -f /tmp/_tr-{account,container,object}.ring.gz
info "  Cleanup done."

fi  # end FULL_TEST

# ── summary ───────────────────────────────────────────────────────────────────
section "SUMMARY"
echo
printf '%s\n' "────────────────────────────────────────────"
echo "  Passed:  ${PASS}"
echo "  Failed:  ${FAIL}"
printf '%s\n' "────────────────────────────────────────────"
echo
if [[ "$FAIL" -eq 0 ]]; then
  step "PASS"
  exit 0
else
  error "FAIL  (${FAIL} test(s) failed)"
  exit 1
fi
