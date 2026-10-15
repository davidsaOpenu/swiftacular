#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib-common.sh"

SWIFT_BACKEND="${SWIFT_BACKEND:-MISSING}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --backend) SWIFT_BACKEND="$2"; shift 2 ;;
    *) shift 1;;
  esac
done

[[ $SWIFT_BACKEND =~ ^(posix|bs_fork|bs_bind)$ ]] || { printf 'Unknown backend "%s"\n' "$SWIFT_BACKEND" >&2; exit 1; }

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
# Tagged swiftacular/${SWIFT_BACKEND}/<name> and swiftacular/<name>;
# Dockerfiles use the latter in FROM.

_BUILD_STATUS_DIR=$(mktemp -d)

build_and_push() {
  local name="$1"
  local dockerfile="${DOCKERFILES}/$2"
  local extra_opts="${3:-}"
  local t0 t1 dur log="${_BUILD_STATUS_DIR}/${name}.log"
  t0=$(date +%s)
  # shellcheck disable=SC2086 -- intentional word-split on _PROGRESS_FLAG / extra_opts
  if docker build \
      ${_PROGRESS_FLAG} \
      ${extra_opts} \
      --build-arg "ANSIBLE_PUBLIC_KEY=${PUB_KEY}" \
      --build-arg "SWIFT_BACKEND=${SWIFT_BACKEND}" \
      -t "${REGISTRY}/swiftacular/${SWIFT_BACKEND}/${name}:latest" \
      -t "${REGISTRY}/swiftacular/${name}:latest" \
      -f "${dockerfile}" \
      "${REPO_ROOT}" 2>&1 | tee "${log}" | sed "s/^/    [${name}] /" \
     && docker push "${REGISTRY}/swiftacular/${SWIFT_BACKEND}/${name}:latest" >>"${log}" 2>&1 \
     && docker push "${REGISTRY}/swiftacular/${name}:latest" >>"${log}" 2>&1; then
    t1=$(date +%s); dur=$((t1 - t0))
    info "✓ ${name} built+pushed in $((dur / 60))m$((dur % 60))s"
    echo "OK ${dur}" > "${_BUILD_STATUS_DIR}/${name}.status"
  else
    t1=$(date +%s); dur=$((t1 - t0))
    error "✗ ${name} build/push failed after ${dur}s — last 30 log lines:"
    tail -30 "${log}" | sed 's/^/      /' >&2
    echo "FAIL ${dur}" > "${_BUILD_STATUS_DIR}/${name}.status"
    return 1
  fi
}

# ── build / await ─────────────────────────────────────────────────────────────
# BuildKit (content-addressed cache) is safe to run in parallel.
# The legacy builder GC-s in-flight intermediate images under memory pressure
# when multiple builds run concurrently, causing "unknown parent image ID"
# failures mid-build — even within a single image's own steps.  Serialize.
#
# build <name> <dockerfile> [extra_opts]
#   Starts one image: in the background under BuildKit, inline under the
#   legacy builder.  Skipped once an await has seen a failure.
# await <name>...
#   Blocks until those images are pushed.  Call it before building anything
#   FROM them; if one failed, every later build is skipped.

FAIL=0
_STOP=0

build() {
  if [[ "${_STOP}" -ne 0 ]]; then
    echo "SKIP 0" > "${_BUILD_STATUS_DIR}/$1.status"
    warn "⊘ $1 skipped — an image awaited before it failed"
    return 0
  fi
  echo "PENDING 0" > "${_BUILD_STATUS_DIR}/$1.status"
  if [[ "${DOCKER_BUILDKIT}" == "1" ]]; then
    build_and_push "$@" &
  else
    build_and_push "$@" || true
  fi
}

await() {
  local n st
  for n in "$@"; do
    [[ -f "${_BUILD_STATUS_DIR}/${n}.status" ]] || { error "await ${n}: not built yet"; exit 1; }
    until read -r st _ < "${_BUILD_STATUS_DIR}/${n}.status"; [[ "${st:-}" =~ ^(OK|FAIL|SKIP)$ ]]; do
      sleep 2
    done
    if [[ "${st}" != "OK" ]]; then _STOP=1; FAIL=1; fi
  done
}

# ── What each backend builds ──────────────────────────────────────────────────
# images_<backend> runs for SWIFT_BACKEND=<backend>.  Every image is built with
# that SWIFT_BACKEND; Dockerfiles that don't read it reuse the cached layers
# from any other backend's build.  Start long independent builds before an
# await, so they run while it blocks.  Grafana uses the stock public image.

common_images() {
  build base          Dockerfile.base
  await base

  build keystone      Dockerfile.keystone
  build package-cache Dockerfile.package-cache
  build storage Dockerfile.storage
  build proxy   Dockerfile.proxy
}

images_posix() {
  common_images
}

images_bs_fork() {
  build bluestore bs_fork/Dockerfile.bluestore "${_BLUESTORE_BUILD_OPTS}"
  images_posix
}

images_bs_bind() {
    error "Not yet implemented"
    exit 1
}

if [[ "${DOCKER_BUILDKIT}" == "1" ]]; then
  step "Building ${SWIFT_BACKEND} images in parallel"
else
  step "Building ${SWIFT_BACKEND} images sequentially (legacy builder)"
fi

"images_${SWIFT_BACKEND}"
for _f in "${_BUILD_STATUS_DIR}"/*.status; do await "$(basename "${_f}" .status)"; done

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
