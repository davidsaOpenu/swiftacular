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

# ── 4. Helm deploy ────────────────────────────────────────────────────────────

step "Deploying swiftacular Helm chart"
helm upgrade --install "${RELEASE}" "${CHART_PATH}" \
  --namespace "${NAMESPACE}" \
  --create-namespace \
  --values "${VALUES_FILE}" \
  --timeout 15m

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
