#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib-logging.sh"

# Use BuildKit when buildx is available; fall back to the legacy builder otherwise.
if docker buildx version &>/dev/null 2>&1; then
  export DOCKER_BUILDKIT=1
else
  export DOCKER_BUILDKIT=0
fi

REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
REGISTRY="localhost:5001"
SSH_DIR="${SCRIPT_DIR}/../ssh"
DOCKERFILES="${SCRIPT_DIR}/../dockerfiles"

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

# ── swiftacular-base (must finish before parallel builds start) ───────────────

step "Building swiftacular-base"
docker build \
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
  if docker build \
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

build_and_push swiftacular-storage      "${DOCKERFILES}/Dockerfile.storage"      & PIDS+=($!)
build_and_push swiftacular-proxy        "${DOCKERFILES}/Dockerfile.proxy"         & PIDS+=($!)
build_and_push swiftacular-keystone     "${DOCKERFILES}/Dockerfile.keystone"      & PIDS+=($!)
build_and_push swiftacular-package-cache "${DOCKERFILES}/Dockerfile.package-cache" & PIDS+=($!)
build_and_push swiftacular-bluestore    "${DOCKERFILES}/Dockerfile.bluestore"     & PIDS+=($!)
# Grafana uses the stock public image; plugin installed by init container at pod start.

FAIL=0
for pid in "${PIDS[@]}"; do
  wait "${pid}" || FAIL=1
done

if [[ "${FAIL}" -ne 0 ]]; then
  error "One or more image builds failed"
  exit 1
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
