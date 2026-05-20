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

# ── 1. Cluster bootstrap ──────────────────────────────────────────────────────

if [[ "${SKIP_BOOTSTRAP}" -eq 0 ]]; then
  step "Bootstrapping kind cluster"
  "${SCRIPT_DIR}/bootstrap-cluster.sh"
else
  info "Skipping bootstrap (--skip-bootstrap)"
fi

# ── 2. Image builds ───────────────────────────────────────────────────────────

if [[ "${SKIP_BUILD}" -eq 0 ]]; then
  step "Building and pushing Docker images"
  "${SCRIPT_DIR}/build-images.sh"
else
  info "Skipping image builds (--skip-build)"
fi

# ── 3. Pre-deploy checks ──────────────────────────────────────────────────────
# Run unconditionally — independent of --skip-bootstrap / --skip-build.

# After a Docker restart the registry container loses its kind network
# attachment; pods then get ImagePullBackOff on localhost:5001 images.
_REGISTRY_NAME="swiftacular-registry"
_KIND_NETWORK="kind"
_KIND_CLUSTER="swiftacular"

step "Ensuring registry is connected to kind network"
if docker network inspect "${_KIND_NETWORK}" \
    --format '{{range .Containers}}{{.Name}} {{end}}' 2>/dev/null \
    | grep -qw "${_REGISTRY_NAME}"; then
  info "Registry already on ${_KIND_NETWORK}"
else
  docker network connect "${_KIND_NETWORK}" "${_REGISTRY_NAME}" 2>/dev/null || true
  info "Registry reconnected to ${_KIND_NETWORK}"
fi

# Pre-load bitnami/kubectl into kind so the ring-builder Job never needs a
# Docker Hub pull during helm install (which would burn the 15-min timeout).
step "Pre-loading bitnami/kubectl into kind"
docker pull bitnami/kubectl:latest &>/dev/null || true
kind load docker-image bitnami/kubectl:latest \
  --name "${_KIND_CLUSTER}" &>/dev/null || true
info "bitnami/kubectl ready in kind"

# Pre-load swiftacular-storage into kind so the ring-builder init container
# (which runs swift-ring-builder) starts immediately without a registry pull.
# On a fresh kind cluster each node would otherwise pull the large storage
# image through the containerd mirror, which can exceed the 15-min Helm
# timeout before the ring-builder even starts.
step "Pre-loading swiftacular-storage into kind"
if docker image inspect "localhost:5001/swiftacular-storage:latest" &>/dev/null 2>&1; then
  kind load docker-image "localhost:5001/swiftacular-storage:latest" \
    --name "${_KIND_CLUSTER}" &>/dev/null || true
  info "swiftacular-storage loaded into kind"
else
  warn "localhost:5001/swiftacular-storage:latest not in local Docker store — ring-builder will pull via registry"
fi

# Pre-load swiftacular-keystone into kind so the Keystone Deployment and the
# keystone-setup post-install Job never need a registry pull during the Helm
# timeout window.  Without this the image pull consumes several minutes before
# the Job even starts, causing a context deadline exceeded.
step "Pre-loading swiftacular-keystone into kind"
if docker image inspect "localhost:5001/swiftacular-keystone:latest" &>/dev/null 2>&1; then
  kind load docker-image "localhost:5001/swiftacular-keystone:latest" \
    --name "${_KIND_CLUSTER}" &>/dev/null || true
  info "swiftacular-keystone loaded into kind"
else
  warn "localhost:5001/swiftacular-keystone:latest not in local Docker store — keystone will pull via registry"
fi

# Pre-load mariadb so the MariaDB StatefulSet starts without a Docker Hub pull.
# Keystone depends on MariaDB being up before the keystone-setup post-install
# hook can succeed; a cold pull from Docker Hub in CI burns several minutes of
# the Helm hook window before MariaDB even starts.
step "Pre-loading mariadb into kind"
docker pull mariadb:11.4 &>/dev/null || true
kind load docker-image mariadb:11.4 \
  --name "${_KIND_CLUSTER}" &>/dev/null || true
info "mariadb loaded into kind"

# ── 4. Helm deploy ────────────────────────────────────────────────────────────

# Background monitor: print pod states every 30 s while helm blocks.
# Gives CI logs enough detail to pinpoint slow pods without needing shell access.
_helm_monitor() {
  local ns="$1"
  while true; do
    sleep 30
    printf '\n  [deploy-monitor %s]\n' "$(date '+%H:%M:%S')"
    kubectl get pods -n "${ns}" --no-headers 2>/dev/null \
      | awk '{printf "    %-45s %-10s %-12s %s\n", $1, $2, $3, $5}' || true
    # Keystone and MariaDB details when not yet Running
    for _pod in $(kubectl get pods -n "${ns}" --no-headers 2>/dev/null \
        | grep -v ' Running ' | awk '{print $1}'); do
      printf '    --- %s events ---\n' "${_pod}"
      kubectl describe pod -n "${ns}" "${_pod}" 2>/dev/null \
        | grep -A2 'Warning\|pulling\|Pulled\|BackOff\|Failed\|Error' \
        | tail -10 | sed 's/^/      /' || true
    done
  done
}
_helm_monitor "${NAMESPACE}" &
_MONITOR_PID=$!
# shellcheck disable=SC2064
trap "kill ${_MONITOR_PID} 2>/dev/null || true" EXIT

step "Deploying swiftacular Helm chart"
helm upgrade --install "${RELEASE}" "${CHART_PATH}" \
  --namespace "${NAMESPACE}" \
  --create-namespace \
  --values "${VALUES_FILE}" \
  --timeout 20m

kill "${_MONITOR_PID}" 2>/dev/null || true
trap - EXIT

# ── 5. Wait for workloads ─────────────────────────────────────────────────────

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

if [[ "${SKIP_SMOKE}" -eq 0 ]]; then
  step "Running smoke tests"
  "${SCRIPT_DIR}/smoke-test.sh"
else
  info "Skipping smoke tests (--skip-smoke)"
fi
