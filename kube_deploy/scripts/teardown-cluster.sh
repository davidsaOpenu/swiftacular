#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib-logging.sh"

CLUSTER_NAME="swiftacular"
REGISTRY_NAME="swiftacular-registry"

step "Deleting kind cluster '${CLUSTER_NAME}'"
if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
  kind delete cluster --name "${CLUSTER_NAME}"
  info "Cluster deleted"
else
  info "No cluster named '${CLUSTER_NAME}' found — skipping"
fi

step "Removing local registry '${REGISTRY_NAME}'"
if docker inspect "${REGISTRY_NAME}" &>/dev/null; then
  docker rm -f "${REGISTRY_NAME}"
  info "Registry removed"
else
  info "No registry named '${REGISTRY_NAME}' found — skipping"
fi

step "Done"
