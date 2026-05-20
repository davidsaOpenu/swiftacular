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
  ensure_registry_on_network "${REGISTRY_NAME}" "${KIND_NETWORK}"
else
  info "No kind cluster found — skipping network check"
fi

# ── Helper: build, tag, push one image; intended to be run in background ──────
# Streams prefixed build output, tees the raw log to a file, and records a
# status line (OK/FAIL + duration) so the parent can print a summary table —
# parallel builds run in subshells, so files are the only channel back.

_BUILD_STATUS_DIR=$(mktemp -d)

build_and_push() {
  local name="$1"
  local dockerfile="$2"
  local extra_opts="${3:-}"
  local t0 t1 dur log="${_BUILD_STATUS_DIR}/${name}.log"
  t0=$(date +%s)
  # shellcheck disable=SC2086 -- intentional word-split on _PROGRESS_FLAG / extra_opts
  if docker build \
      ${_PROGRESS_FLAG} \
      ${extra_opts} \
      --build-arg "ANSIBLE_PUBLIC_KEY=${PUB_KEY}" \
      -t "${name}:latest" \
      -f "${dockerfile}" \
      "${REPO_ROOT}" 2>&1 | tee "${log}" | sed "s/^/    [${name}] /" \
     && docker tag  "${name}:latest" "${REGISTRY}/${name}:latest" \
     && docker push "${REGISTRY}/${name}:latest" >>"${log}" 2>&1; then
    t1=$(date +%s); dur=$((t1 - t0))
    echo "OK ${dur}" > "${_BUILD_STATUS_DIR}/${name}.status"
    info "✓ ${name} built+pushed in $((dur / 60))m$((dur % 60))s"
  else
    t1=$(date +%s); dur=$((t1 - t0))
    echo "FAIL ${dur}" > "${_BUILD_STATUS_DIR}/${name}.status"
    error "✗ ${name} build/push failed after ${dur}s — last 30 log lines:"
    tail -30 "${log}" | sed 's/^/      /' >&2
    return 1
  fi
}

# ── swiftacular-base (must finish before parallel builds start) ───────────────

step "Building swiftacular-base"
build_and_push swiftacular-base "${DOCKERFILES}/Dockerfile.base"

# ── Remaining five images ─────────────────────────────────────────────────────
# BuildKit (content-addressed cache) is safe to run in parallel.
# The legacy builder GC-s in-flight intermediate images under memory pressure
# when multiple builds run concurrently, causing "unknown parent image ID"
# failures mid-build — even within a single image's own steps.  Serialize.
# Grafana uses the stock public image; no build needed.

FAIL=0

if [[ "${DOCKER_BUILDKIT}" == "1" ]]; then
  step "Building service images in parallel"
  declare -a PIDS=()
  build_and_push swiftacular-storage       "${DOCKERFILES}/Dockerfile.storage"       & PIDS+=($!)
  build_and_push swiftacular-proxy         "${DOCKERFILES}/Dockerfile.proxy"          & PIDS+=($!)
  build_and_push swiftacular-keystone      "${DOCKERFILES}/Dockerfile.keystone"       & PIDS+=($!)
  build_and_push swiftacular-package-cache "${DOCKERFILES}/Dockerfile.package-cache"  & PIDS+=($!)
  build_and_push swiftacular-bluestore     "${DOCKERFILES}/Dockerfile.bluestore"      & PIDS+=($!)
  for pid in "${PIDS[@]}"; do wait "${pid}" || FAIL=1; done
else
  step "Building service images sequentially (legacy builder)"
  build_and_push swiftacular-storage       "${DOCKERFILES}/Dockerfile.storage"       || FAIL=1
  build_and_push swiftacular-proxy         "${DOCKERFILES}/Dockerfile.proxy"          || FAIL=1
  build_and_push swiftacular-keystone      "${DOCKERFILES}/Dockerfile.keystone"       || FAIL=1
  build_and_push swiftacular-package-cache "${DOCKERFILES}/Dockerfile.package-cache"  || FAIL=1
  build_and_push swiftacular-bluestore     "${DOCKERFILES}/Dockerfile.bluestore" \
    "${_BLUESTORE_BUILD_OPTS}"                                                         || FAIL=1
fi

# ── Build summary table ───────────────────────────────────────────────────────

step "Build summary"
for _f in "${_BUILD_STATUS_DIR}"/*.status; do
  [[ -f "${_f}" ]] || continue
  _name=$(basename "${_f}" .status)
  read -r _st _dur < "${_f}"
  info "$(printf '%-32s %-4s %02dm%02ds' "${_name}" "${_st}" $((_dur / 60)) $((_dur % 60)))"
done
rm -rf "${_BUILD_STATUS_DIR}"

if [[ "${FAIL}" -ne 0 ]]; then
  error "One or more image builds failed"
  exit 1
fi

# ── Pre-load auxiliary images into kind ──────────────────────────────────────
# bitnami/kubectl is used by the ring-builder Job.  Loading it here (after the
# host has it from a prior pull or cache) avoids a Docker Hub pull from inside
# kind during helm install, which can time out under CI network constraints.
# (deploy.sh pre-loads everything again, but this keeps build-images.sh useful
# standalone.)

step "Pre-loading bitnami/kubectl into kind"
if kind get clusters 2>/dev/null | grep -q "^${KIND_CLUSTER}$"; then
  run_logged "docker pull bitnami/kubectl:latest" \
    docker pull bitnami/kubectl:latest || true
  run_logged "kind load bitnami/kubectl:latest" \
    kind load docker-image bitnami/kubectl:latest --name "${KIND_CLUSTER}" || true
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
