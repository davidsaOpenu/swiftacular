#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib-logging.sh"

CLUSTER_NAME="swiftacular"
REGISTRY_NAME="swiftacular-registry"
REGISTRY_PORT="5001"
REGISTRY_IMAGE="registry:2"
LOCAL_PATH_PROVISIONER_VERSION="v0.0.30"
KIND_CONFIG="${SCRIPT_DIR}/../cluster/kind-config.yaml"

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
  # kind on Windows (Git Bash / MSYS2) needs a Windows-style path for --config.
  KIND_CONFIG_ARG="${KIND_CONFIG}"
  if command -v cygpath &>/dev/null; then
    KIND_CONFIG_ARG="$(cygpath -w "${KIND_CONFIG}")"
  fi
  kind create cluster \
    --name "${CLUSTER_NAME}" \
    --config "${KIND_CONFIG_ARG}"
  info "Cluster created"
fi

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
  kubectl apply -f "${LPP_URL}"
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
info "kubectl  : $(kubectl config current-context)"
kubectl get nodes
