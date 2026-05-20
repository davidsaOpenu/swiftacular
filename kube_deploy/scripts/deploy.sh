#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib-logging.sh"

RELEASE="swiftacular"
NAMESPACE="swiftacular"
CHART_PATH="${SCRIPT_DIR}/../charts/swiftacular"
VALUES_FILE="${CHART_PATH}/values.dev.yaml"
SKIP_BOOTSTRAP=0
SKIP_BUILD=0
SKIP_SMOKE=0

usage() {
  echo "Usage: $0 [OPTIONS]"
  echo ""
  echo "Options:"
  echo "  --skip-bootstrap   Skip kind cluster creation (cluster already exists)"
  echo "  --skip-build       Skip Docker image builds (images already in registry)"
  echo "  --skip-smoke       Skip smoke tests after deploy"
  echo "  --values <file>    Helm values file (default: values.dev.yaml)"
  echo "  -h, --help         Show this help"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-bootstrap) SKIP_BOOTSTRAP=1; shift ;;
    --skip-build)     SKIP_BUILD=1;     shift ;;
    --skip-smoke)     SKIP_SMOKE=1;     shift ;;
    --values)         VALUES_FILE="$2"; shift 2 ;;
    -h|--help)        usage; exit 0 ;;
    *) error "Unknown flag: $1"; usage; exit 1 ;;
  esac
done

# ── exit handler ──────────────────────────────────────────────────────────────
# One EXIT trap for the whole script: kills the background helm monitor, dumps
# full cluster diagnostics on failure (CI tears the cluster down right after
# this script, destroying all evidence), and always prints the phase summary.
_MONITOR_PID=""
_cleanup() {
  local rc=$?
  if [[ -n "${_MONITOR_PID}" ]]; then
    kill "${_MONITOR_PID}" 2>/dev/null || true
  fi
  if [[ ${rc} -ne 0 ]]; then
    error "deploy.sh exiting with rc=${rc} — dumping cluster state before teardown"
    dump_cluster_diagnostics "${NAMESPACE}" || true
  fi
  print_phase_summary || true
  exit "${rc}"
}
trap _cleanup EXIT

# ── 0. System spec ────────────────────────────────────────────────────────────
# Print once per run so CI logs have enough context to diagnose environment
# issues (slow disks, low memory, proxy misconfiguration, missing tools).

phase "system-spec"
step "System spec"
info "--- kernel / CPU / memory ---"
uname -a || true
info "CPUs: $(nproc 2>/dev/null || echo '?')"
free -h 2>/dev/null || true
info "--- disk ---"
df -h / 2>/dev/null || true
info "--- proxy env vars ---"
for _v in HTTPS_PROXY HTTP_PROXY https_proxy http_proxy NO_PROXY no_proxy; do
  _val="${!_v:-}"
  [[ -n "${_val}" ]] && info "  ${_v}=${_val}" || true
done
info "--- tool versions ---"
_dv=$(docker version \
  --format 'Docker client {{.Client.Version}} / server {{.Server.Version}}' \
  2>/dev/null) || true
info "${_dv:-docker version unavailable}"
if docker info &>/dev/null; then
  docker info --format \
    'Storage driver: {{.Driver}}  Root dir: {{.DockerRootDir}}  HTTP proxy: {{.HTTPProxy}}  HTTPS proxy: {{.HTTPSProxy}}' \
    2>/dev/null || true
else
  error "Docker daemon unreachable — start Docker Desktop (WSL integration) or 'sudo service docker start'"
  exit 1
fi
kind version 2>/dev/null || true
kubectl version --client --short 2>/dev/null \
  || kubectl version --client 2>/dev/null | head -2 || true
helm version --short 2>/dev/null || helm version 2>/dev/null | head -1 || true
info "--- docker images already cached (may skip pulls) ---"
docker images --format '{{.Repository}}:{{.Tag}}\t{{.Size}}' 2>/dev/null \
  | grep -E 'mariadb|busybox|alpine|grafana|kind|bitnami|registry' || true

# ── 1. Cluster bootstrap ──────────────────────────────────────────────────────

phase "bootstrap"
if [[ "${SKIP_BOOTSTRAP}" -eq 0 ]]; then
  step "Bootstrapping kind cluster"
  "${SCRIPT_DIR}/bootstrap-cluster.sh"
else
  info "Skipping bootstrap (--skip-bootstrap)"
fi

# ── 2. Image builds ───────────────────────────────────────────────────────────

phase "build-images"
if [[ "${SKIP_BUILD}" -eq 0 ]]; then
  step "Building and pushing Docker images"
  "${SCRIPT_DIR}/build-images.sh"
else
  info "Skipping image builds (--skip-build)"
fi

# ── 3. Pre-deploy checks ──────────────────────────────────────────────────────
# Run unconditionally — independent of --skip-bootstrap / --skip-build.

phase "pre-deploy"
_KIND_CLUSTER="swiftacular"

# Everything from here on talks to localhost (kind API server, NodePorts) —
# corporate proxies must not intercept it.  Docker pulls below go through the
# Docker daemon, which has its own proxy config and ignores this environment.
unset_proxy_vars

step "Ensuring registry is connected to kind network"
ensure_registry_on_network "swiftacular-registry" "kind"

# Pre-load every image the chart references into kind's containerd so that
# imagePullPolicy: IfNotPresent never needs a network pull during the Helm
# timeout window:
#   - Docker Hub pulls fail inside kind nodes on CI (proxy breaks TLS) even
#     when the host Docker daemon pulls fine.
#   - The local registry can return 503 on manifest HEAD checks even when the
#     image data is present.
#   - busybox:latest is required by local-path-provisioner helper pods — PVCs
#     never bind without it.
HUB_IMAGES=(
  bitnami/kubectl:latest
  mariadb:11.4
  busybox:1.36
  busybox:latest
  alpine:3.19
  grafana/grafana:10.4.3
)
LOCAL_IMAGES=(
  localhost:5001/swiftacular-storage:latest
  localhost:5001/swiftacular-keystone:latest
  localhost:5001/swiftacular-proxy:latest
  localhost:5001/swiftacular-package-cache:latest
)

step "Pre-loading ${#HUB_IMAGES[@]} hub + ${#LOCAL_IMAGES[@]} local images into kind"
_PRELOAD_T0=$(date +%s)

# Phase A: pull missing hub images in parallel (local images are produced by
# build-images.sh and never pulled here).
_PULL_DIR=$(mktemp -d)
_pull_pids=()
_pull_imgs=()
for _img in "${HUB_IMAGES[@]}"; do
  if docker image inspect "${_img}" &>/dev/null; then
    info "cached:  ${_img}"
    continue
  fi
  docker pull "${_img}" >"${_PULL_DIR}/$(echo "${_img}" | tr '/:' '__').log" 2>&1 &
  _pull_pids+=($!)
  _pull_imgs+=("${_img}")
done
if [[ ${#_pull_pids[@]} -gt 0 ]]; then
  info "pulling ${#_pull_pids[@]} image(s) from Docker Hub in parallel..."
  for _i in "${!_pull_pids[@]}"; do
    if wait "${_pull_pids[${_i}]}"; then
      info "pulled:  ${_pull_imgs[${_i}]}"
    else
      warn "pull FAILED: ${_pull_imgs[${_i}]} — output:"
      sed 's/^/      /' \
        "${_PULL_DIR}/$(echo "${_pull_imgs[${_i}]}" | tr '/:' '__').log" >&2 || true
    fi
  done
fi
rm -rf "${_PULL_DIR}"

# Phase B: one batched kind load for everything present in the local Docker
# store — a single tar stream per node instead of one round-trip per image.
_LOAD_LIST=()
_SKIPPED=()
for _img in "${HUB_IMAGES[@]}" "${LOCAL_IMAGES[@]}"; do
  if docker image inspect "${_img}" &>/dev/null; then
    _LOAD_LIST+=("${_img}")
  else
    _SKIPPED+=("${_img}")
  fi
done
if [[ ${#_LOAD_LIST[@]} -gt 0 ]]; then
  run_logged "kind load ${#_LOAD_LIST[@]} images into '${_KIND_CLUSTER}'" \
    kind load docker-image "${_LOAD_LIST[@]}" --name "${_KIND_CLUSTER}" \
    || warn "kind load failed — pods will fall back to pulling via the registry"
fi
if [[ ${#_SKIPPED[@]} -gt 0 ]]; then
  warn "NOT pre-loaded (missing from local Docker store): ${_SKIPPED[*]}"
  warn "pods needing these images will pull over the network and may hit ImagePullBackOff"
fi
info "Pre-load done in $(( $(date +%s) - _PRELOAD_T0 ))s: ${#_LOAD_LIST[@]} loaded, ${#_SKIPPED[@]} skipped"

# ── 4. Helm deploy ────────────────────────────────────────────────────────────

phase "helm-install"

# Background monitor: print pod states + logs of stuck pods every 30 s while
# helm blocks.  Gives CI logs enough detail to pinpoint slow pods without
# needing shell access.
_helm_monitor() {
  local ns="$1"
  while true; do
    sleep 30
    printf '\n  [deploy-monitor %s]\n' "$(date '+%H:%M:%S')"
    kubectl get pods -n "${ns}" --no-headers 2>/dev/null \
      | awk '{printf "    %-45s %-10s %-12s %s\n", $1, $2, $3, $5}' || true
    for _pod in $(kubectl get pods -n "${ns}" --no-headers 2>/dev/null \
        | grep -v ' Running \| Completed ' | awk '{print $1}'); do
      printf '    --- %s events ---\n' "${_pod}"
      kubectl describe pod -n "${ns}" "${_pod}" 2>/dev/null \
        | grep -A2 'Warning\|pulling\|Pulled\|BackOff\|Failed\|Error\|Killing\|OOM' \
        | tail -15 | sed 's/^/      /' || true
      printf '    --- %s logs (last 20 lines) ---\n' "${_pod}"
      kubectl logs -n "${ns}" "${_pod}" --tail=20 2>/dev/null \
        | sed 's/^/      /' || true
      kubectl logs -n "${ns}" "${_pod}" --tail=20 --previous 2>/dev/null \
        | sed 's/^/      [prev] /' || true
    done
  done
}
_helm_monitor "${NAMESPACE}" &
_MONITOR_PID=$!

step "Deploying swiftacular Helm chart"
helm upgrade --install "${RELEASE}" "${CHART_PATH}" \
  --namespace "${NAMESPACE}" \
  --create-namespace \
  --values "${VALUES_FILE}" \
  --timeout 20m

kill "${_MONITOR_PID}" 2>/dev/null || true
_MONITOR_PID=""

# ── 5. Wait for workloads ─────────────────────────────────────────────────────
# On any timeout, set -e aborts and the EXIT trap dumps full diagnostics.

phase "wait-workloads"

step "Waiting for ring-builder Job"
kubectl wait --for=condition=complete job/ring-builder \
  -n "${NAMESPACE}" --timeout=120s

step "Waiting for storage StatefulSet (3 replicas)"
kubectl rollout status statefulset/storage \
  -n "${NAMESPACE}" --timeout=300s

step "Waiting for proxy Deployment"
kubectl rollout status deployment/proxy \
  -n "${NAMESPACE}" --timeout=120s

# ── 6. Summary ────────────────────────────────────────────────────────────────

GRAFANA_PASS=$(kubectl get secret swift-secrets -n "${NAMESPACE}" \
  -o jsonpath='{.data.grafanaAdminPassword}' 2>/dev/null | base64 -d || echo "devgrafanapass")

step "Cluster ready"
info "Grafana:     http://localhost:3000  (admin / ${GRAFANA_PASS})"
info "Swift proxy: http://localhost:8080"
info "Keystone:    http://localhost:5000/v3"
info ""
info "Tear down:"
info "  kube_deploy/scripts/teardown-cluster.sh"

# ── 7. Smoke tests ────────────────────────────────────────────────────────────

phase "smoke-tests"
if [[ "${SKIP_SMOKE}" -eq 0 ]]; then
  step "Running smoke tests"
  "${SCRIPT_DIR}/smoke-test.sh"
else
  info "Skipping smoke tests (--skip-smoke)"
fi
