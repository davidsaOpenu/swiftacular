#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib-logging.sh"

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
  info "${cmd}: $(${cmd} version --short 2>/dev/null || ${cmd} version 2>/dev/null | head -1)"
done

# ── Local Docker registry ─────────────────────────────────────────────────────

step "Starting local registry (${REGISTRY_NAME})"
if docker inspect "${REGISTRY_NAME}" &>/dev/null; then
  info "Registry already running — skipping"
else
  docker run -d \
    --name "${REGISTRY_NAME}" \
    --restart=always \
    -p "127.0.0.1:${REGISTRY_PORT}:5000" \
    "${REGISTRY_IMAGE}"
  info "Registry started at localhost:${REGISTRY_PORT}"
fi

# ── kind cluster ─────────────────────────────────────────────────────────────

step "Creating kind cluster '${CLUSTER_NAME}'"
if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
  info "Cluster already exists — skipping"
else
  # Generate kind config at runtime so host ports can be overridden via env vars.
  KIND_CONFIG_TMP="$(mktemp /tmp/kind-config-XXXXXX.yaml)"
  cat > "${KIND_CONFIG_TMP}" <<KINDEOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4

nodes:
  - role: control-plane
    extraPortMappings:
      - containerPort: 30080
        hostPort: ${PROXY_HOST_PORT}
        protocol: TCP
      - containerPort: 30500
        hostPort: ${KEYSTONE_HOST_PORT}
        protocol: TCP
      - containerPort: 30300
        hostPort: ${GRAFANA_HOST_PORT}
        protocol: TCP

  - role: worker
    labels:
      swiftacular/role: storage
      swiftacular/storage-index: "0"

  - role: worker
    labels:
      swiftacular/role: storage
      swiftacular/storage-index: "1"

  - role: worker
    labels:
      swiftacular/role: storage
      swiftacular/storage-index: "2"

containerdConfigPatches:
  - |-
    [plugins."io.containerd.grpc.v1.cri".registry]
      [plugins."io.containerd.grpc.v1.cri".registry.mirrors]
        [plugins."io.containerd.grpc.v1.cri".registry.mirrors."localhost:5001"]
          endpoint = ["http://swiftacular-registry:5000"]
KINDEOF

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
    warn "kind create cluster failed (attempt ${_attempt}/3)"
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
unset HTTPS_PROXY HTTP_PROXY https_proxy http_proxy

# ── Connect registry to the kind Docker network ───────────────────────────────

step "Connecting registry to kind network"
KIND_NETWORK="kind"
if docker network inspect "${KIND_NETWORK}" \
    --format '{{range .Containers}}{{.Name}} {{end}}' 2>/dev/null \
    | grep -qw "${REGISTRY_NAME}"; then
  info "Registry already connected to ${KIND_NETWORK} — skipping"
else
  docker network connect "${KIND_NETWORK}" "${REGISTRY_NAME}"
  info "Registry connected"
fi

# ── local-path-provisioner ────────────────────────────────────────────────────

step "Installing local-path-provisioner ${LOCAL_PATH_PROVISIONER_VERSION}"
LPP_URL="https://raw.githubusercontent.com/rancher/local-path-provisioner/${LOCAL_PATH_PROVISIONER_VERSION}/deploy/local-path-storage.yaml"

if kubectl get storageclass local-path &>/dev/null; then
  info "local-path StorageClass already present — skipping"
else
  curl -sSfL "${LPP_URL}" | kubectl apply -f -
  kubectl patch storageclass local-path \
    -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
  info "local-path-provisioner installed and set as default StorageClass"
fi

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
