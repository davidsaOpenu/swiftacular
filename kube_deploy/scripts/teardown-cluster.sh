#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib-common.sh"

CLUSTER_NAME="swiftacular"
REGISTRY_NAME="swiftacular-registry"

step "Deleting kind cluster '${CLUSTER_NAME}'"
if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
  # "docker rm -f" occasionally hangs with "did not receive an exit event" —
  # a transient containerd-shim bug, not a real stuck container. Retrying
  # after a short pause usually clears it without operator intervention.
  _deleted=0
  for _attempt in 1 2 3; do
    if run_logged "kind delete cluster (attempt ${_attempt})" \
        kind delete cluster --name "${CLUSTER_NAME}"; then
      _deleted=1
      break
    fi
    [[ ${_attempt} -lt 3 ]] && { warn "Retrying cluster deletion in 10s"; sleep 10; }
  done

  if [[ ${_deleted} -eq 1 ]]; then
    info "Cluster deleted"
  else
    warn "kind delete cluster failed after 3 attempts — force-removing leftover containers"
    docker ps -a --filter "label=io.x-k8s.kind.cluster=${CLUSTER_NAME}" -q \
      | xargs -r docker rm -f -v || true
    if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
      error "Cluster '${CLUSTER_NAME}' still present — Docker daemon may need attention"
      exit 1
    fi
    info "Leftover containers removed"
  fi
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
