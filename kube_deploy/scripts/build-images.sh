#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib-logging.sh"

# On Docker 26+, DOCKER_BUILDKIT=1 routes through the buildx CLI plugin; if
# that plugin is absent the build fails immediately.  Use BuildKit only when
# buildx is present.  Without BuildKit the legacy builder's "unknown parent
# image ID" bug can bite multi-stage images when an intermediate stage image
# is evicted between runs — work around it with --no-cache on bluestore only.
_BLUESTORE_BUILD_OPTS=""
_PROGRESS_FLAG=""
if docker buildx version &>/dev/null 2>&1; then
  export DOCKER_BUILDKIT=1
  _PROGRESS_FLAG="--progress=plain"
else
  export DOCKER_BUILDKIT=0
  _BLUESTORE_BUILD_OPTS="--no-cache"
  warn "docker buildx not available — legacy builder; bluestore built without cache"
fi

REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
REGISTRY="localhost:5001"
SSH_DIR="${SCRIPT_DIR}/../ssh"
DOCKERFILES="${SCRIPT_DIR}/../dockerfiles"
REGISTRY_NAME="swiftacular-registry"
KIND_CLUSTER="swiftacular"
KIND_NETWORK="kind"

# ── SSH keypair ───────────────────────────────────────────────────────────────

step "Checking SSH keypair"
mkdir -p "${SSH_DIR}"
if [[ ! -f "${SSH_DIR}/ansible_user" ]]; then
  ssh-keygen -t ed25519 -f "${SSH_DIR}/ansible_user" -N "" -C "ansible_user@swiftacular"
  info "Generated ${SSH_DIR}/ansible_user{,.pub}"
else
  info "Keypair already present — skipping"
fi
PUB_KEY="$(cat "${SSH_DIR}/ansible_user.pub")"

# ── Ensure registry is reachable inside kind ─────────────────────────────────
# The containerd mirror config resolves "swiftacular-registry" via Docker DNS.
# If Docker restarted since bootstrap, the container loses its kind network
# attachment and pods get ImagePullBackOff.  Re-connect idempotently here so
# this is self-healing even when --skip-bootstrap is passed to deploy.sh.

step "Ensuring registry is connected to kind network"
if kind get clusters 2>/dev/null | grep -q "^${KIND_CLUSTER}$"; then
  if ! docker network inspect "${KIND_NETWORK}" \
      --format '{{range .Containers}}{{.Name}} {{end}}' 2>/dev/null \
      | grep -qw "${REGISTRY_NAME}"; then
    docker network connect "${KIND_NETWORK}" "${REGISTRY_NAME}" 2>/dev/null || true
    info "Registry reconnected to ${KIND_NETWORK}"
  else
    info "Registry already on ${KIND_NETWORK}"
  fi
else
  info "No kind cluster found — skipping network check"
fi

# ── swiftacular-base (must finish before parallel builds start) ───────────────

step "Building swiftacular-base"
# shellcheck disable=SC2086
docker build \
  ${_PROGRESS_FLAG} \
  --build-arg "ANSIBLE_PUBLIC_KEY=${PUB_KEY}" \
  -t "swiftacular-base:latest" \
  -f "${DOCKERFILES}/Dockerfile.base" \
  "${REPO_ROOT}"
docker tag  "swiftacular-base:latest" "${REGISTRY}/swiftacular-base:latest"
docker push "${REGISTRY}/swiftacular-base:latest"
info "swiftacular-base pushed"

# ── Helper: build, tag, push one image; intended to be run in background ──────

build_and_push() {
  local name="$1"
  local dockerfile="$2"
  local extra_opts="${3:-}"
  # shellcheck disable=SC2086 -- intentional word-split on _PROGRESS_FLAG / extra_opts
  if docker build \
      ${_PROGRESS_FLAG} \
      ${extra_opts} \
      --build-arg "ANSIBLE_PUBLIC_KEY=${PUB_KEY}" \
      -t "${name}:latest" \
      -f "${dockerfile}" \
      "${REPO_ROOT}" 2>&1 | sed "s/^/    [${name}] /"; then
    docker tag  "${name}:latest" "${REGISTRY}/${name}:latest"
    docker push "${REGISTRY}/${name}:latest"
    info "${name} pushed"
  else
    echo "ERROR: build failed for ${name}" >&2
    return 1
  fi
}

# ── Remaining five images in parallel ────────────────────────────────────────

step "Building service images in parallel"

declare -a PIDS=()

build_and_push swiftacular-storage      "${DOCKERFILES}/Dockerfile.storage"       & PIDS+=($!)
build_and_push swiftacular-proxy        "${DOCKERFILES}/Dockerfile.proxy"          & PIDS+=($!)
build_and_push swiftacular-keystone     "${DOCKERFILES}/Dockerfile.keystone"       & PIDS+=($!)
build_and_push swiftacular-package-cache "${DOCKERFILES}/Dockerfile.package-cache" & PIDS+=($!)
build_and_push swiftacular-bluestore    "${DOCKERFILES}/Dockerfile.bluestore" \
  "${_BLUESTORE_BUILD_OPTS}"                                                        & PIDS+=($!)
# Grafana uses the stock public image; plugin installed by init container at pod start.

FAIL=0
for pid in "${PIDS[@]}"; do
  wait "${pid}" || FAIL=1
done

if [[ "${FAIL}" -ne 0 ]]; then
  error "One or more image builds failed"
  exit 1
fi

# ── Pre-load auxiliary images into kind ──────────────────────────────────────
# bitnami/kubectl is used by the ring-builder Job.  Loading it here (after the
# host has it from a prior pull or cache) avoids a Docker Hub pull from inside
# kind during helm install, which can time out under CI network constraints.

step "Pre-loading bitnami/kubectl into kind"
if kind get clusters 2>/dev/null | grep -q "^${KIND_CLUSTER}$"; then
  docker pull bitnami/kubectl:latest &>/dev/null || true
  kind load docker-image bitnami/kubectl:latest \
    --name "${KIND_CLUSTER}" &>/dev/null || true
  info "bitnami/kubectl loaded into kind"
else
  info "No kind cluster found — skipping image pre-load"
fi

# ── Summary ───────────────────────────────────────────────────────────────────

step "All images pushed"
info "Registry catalog:"
curl -sf "http://${REGISTRY}/v2/_catalog" \
  | python3 -c "import sys,json; d=sys.stdin.read(); [print('    ' + r) for r in (json.loads(d)['repositories'] if d.strip() else [])]" \
  || true

step "Next step — deploy the cluster"
echo ""
echo "    helm upgrade --install swiftacular kube_deploy/charts/swiftacular \\"
echo "      -n swiftacular --create-namespace \\"
echo "      -f kube_deploy/charts/swiftacular/values.dev.yaml"
echo ""
