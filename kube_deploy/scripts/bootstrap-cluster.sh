#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib-common.sh"

# ── Linting ───────────────────────────────────────────────────────────────────
"${SCRIPT_DIR}/../../scripts/install_ansible_collections.sh"
tox

CLUSTER_NAME="swiftacular"
REGISTRY_NAME="swiftacular-registry"
REGISTRY_PORT="5001"
REGISTRY_IMAGE="registry:2"
LOCAL_PATH_PROVISIONER_VERSION="v0.0.30"

# Host-port mappings.
# Jenkins occupies port 8080, so CI gets offset ports automatically.
# Override any of these with env vars to suit your environment.
if [[ -n "${JENKINS_HOME:-}" ]] || [[ -n "${CI:-}" ]]; then
  PROXY_HOST_PORT="${PROXY_HOST_PORT:-18080}"
  KEYSTONE_HOST_PORT="${KEYSTONE_HOST_PORT:-15000}"
  GRAFANA_HOST_PORT="${GRAFANA_HOST_PORT:-13000}"
else
  PROXY_HOST_PORT="${PROXY_HOST_PORT:-8080}"
  KEYSTONE_HOST_PORT="${KEYSTONE_HOST_PORT:-5000}"
  GRAFANA_HOST_PORT="${GRAFANA_HOST_PORT:-3000}"
fi

# ── Prerequisite check ────────────────────────────────────────────────────────

step "Checking prerequisites"
for cmd in docker kind kubectl helm; do
  if ! command -v "${cmd}" &>/dev/null; then
    error "Required tool not found: ${cmd}"
    exit 1
  fi
done
info "docker : $(docker version --format '{{.Client.Version}}' 2>/dev/null || echo '?')"
info "kind   : $(kind version 2>/dev/null || echo '?')"
info "kubectl: $(kubectl version --client 2>/dev/null | head -1 || echo '?')"
info "helm   : $(helm version --short 2>/dev/null || echo '?')"

# Functional checks — command -v alone passes for broken snap wrappers and
# says nothing about whether the Docker daemon is up.
if ! docker info &>/dev/null; then
  error "Docker daemon unreachable. Start Docker Desktop (WSL integration) or 'sudo service docker start'."
  exit 1
fi
if ! kubectl version --client &>/dev/null; then
  error "kubectl is on PATH but cannot run (broken snap install?)."
  error "Fix: 'sudo snap refresh kubectl' or install a static binary to /usr/local/bin."
  exit 1
fi

# ── Local Docker registry ─────────────────────────────────────────────────────

step "Starting local registry (${REGISTRY_NAME})"
start_registry "${REGISTRY_NAME}" "${REGISTRY_PORT}" "${REGISTRY_IMAGE}"

# ── kind cluster ─────────────────────────────────────────────────────────────

step "Creating kind cluster '${CLUSTER_NAME}'"
if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
  info "Cluster already exists — skipping"
else
  # Render the kind topology from the single source of truth
  # (cluster/kind-config.yaml) with the (possibly CI-offset) host ports.
  command -v envsubst >/dev/null \
    || { error "envsubst not found — install gettext-base"; exit 1; }
  KIND_CONFIG_SRC="${SCRIPT_DIR}/../cluster/kind-config.yaml"
  KIND_CONFIG_TMP="$(mktemp /tmp/kind-config-XXXXXX.yaml)"
  export PROXY_HOST_PORT KEYSTONE_HOST_PORT GRAFANA_HOST_PORT
  envsubst '${PROXY_HOST_PORT} ${KEYSTONE_HOST_PORT} ${GRAFANA_HOST_PORT}' \
    < "${KIND_CONFIG_SRC}" > "${KIND_CONFIG_TMP}"

  KIND_CONFIG_ARG="${KIND_CONFIG_TMP}"
  if command -v cygpath &>/dev/null; then
    KIND_CONFIG_ARG="$(cygpath -w "${KIND_CONFIG_TMP}")"
  fi

  # kind node containers run systemd as PID 1; on some CI hosts the boot
  # times out transiently ("Reached target Multi-User System" not found).
  # Retry up to 3 times — kind cleans up failed node containers automatically.
  _KIND_CREATED=0
  for _attempt in 1 2 3; do
    if kind create cluster \
        --name "${CLUSTER_NAME}" \
        --config "${KIND_CONFIG_ARG}"; then
      _KIND_CREATED=1
      break
    fi
    warn "kind create cluster failed (attempt ${_attempt}/3) — host state:"
    df -h / 2>/dev/null | sed 's/^/      /' >&2 || true
    docker ps -a --format '{{.Names}}\t{{.Status}}' 2>/dev/null \
      | grep -i 'kind\|swiftacular' | sed 's/^/      /' >&2 || true
    kind delete cluster --name "${CLUSTER_NAME}" 2>/dev/null || true
    [[ $_attempt -lt 3 ]] && sleep 10
  done
  rm -f "${KIND_CONFIG_TMP}"
  [[ $_KIND_CREATED -eq 1 ]] || { error "kind create cluster failed after 3 attempts"; exit 1; }
  info "Cluster created"
fi

# ── Proxy bypass for kubectl ──────────────────────────────────────────────────
# All kubectl targets in this script are localhost (kind API server).
# If HTTPS_PROXY is set to an http:// proxy (misconfigured as https://), Go's
# http client TLS-handshakes the proxy and fails. Docker operations above are
# already complete, so unsetting here is safe.
unset_proxy_vars

# ── Connect registry to the kind Docker network ───────────────────────────────

step "Connecting registry to kind network"
ensure_registry_on_network "${REGISTRY_NAME}" "kind"

# ── local-path-provisioner ────────────────────────────────────────────────────

step "Installing local-path-provisioner ${LOCAL_PATH_PROVISIONER_VERSION}"
LPP_URL="https://raw.githubusercontent.com/rancher/local-path-provisioner/${LOCAL_PATH_PROVISIONER_VERSION}/deploy/local-path-storage.yaml"

if kubectl get storageclass local-path &>/dev/null; then
  info "local-path StorageClass already present — skipping"
else
  # Pin the helper-pod image to busybox:1.36 (the tag the chart already uses)
  # so only one busybox tag must be pre-loaded into kind. Upstream defaults the
  # helper to the floating "busybox" (== :latest); the helper mkdir's every PVC
  # directory, so its image must be present in the kind nodes for PVCs to bind.
  LPP_MANIFEST="$(mktemp)"
  curl -sSfL "${LPP_URL}" \
    | sed 's#image: busybox *$#image: busybox:1.36#' > "${LPP_MANIFEST}"
  grep -q 'image: busybox:1.36' "${LPP_MANIFEST}" \
    || warn "local-path helper image not pinned (upstream format changed?); PVC binding may need busybox:latest pre-loaded"
  kubectl apply -f "${LPP_MANIFEST}"
  rm -f "${LPP_MANIFEST}"
  kubectl patch storageclass local-path \
    -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
  info "local-path-provisioner installed and set as default StorageClass"
fi

# The first PVC of the Helm install can race a provisioner that is still
# pulling its image; wait for the rollout so PVC binding works immediately.
step "Waiting for local-path-provisioner rollout"
kubectl rollout status deployment/local-path-provisioner \
  -n local-path-storage --timeout=120s \
  || warn "local-path-provisioner not ready after 120s — first PVC bindings may be delayed"

# ── Worker node labels ────────────────────────────────────────────────────────

step "Labelling worker nodes"
# kind already applied labels from the config for new clusters.
# This loop is a safety net for re-runs or manual label removal.
INDEX=0
for NODE in $(kubectl get nodes --selector='!node-role.kubernetes.io/control-plane' \
                --no-headers -o custom-columns=NAME:.metadata.name | sort); do
  kubectl label node "${NODE}" \
    "swiftacular/role=storage" \
    "swiftacular/storage-index=${INDEX}" \
    --overwrite
  info "  ${NODE} → storage-index=${INDEX}"
  INDEX=$((INDEX + 1))
done

# ── Done ──────────────────────────────────────────────────────────────────────

step "Cluster ready"
info "Registry : localhost:${REGISTRY_PORT}"
info "Proxy    : localhost:${PROXY_HOST_PORT}"
info "Keystone : localhost:${KEYSTONE_HOST_PORT}"
info "Grafana  : localhost:${GRAFANA_HOST_PORT}"
info "kubectl  : $(kubectl config current-context)"
kubectl get nodes
