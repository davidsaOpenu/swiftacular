#!/usr/bin/env bash

set -euo pipefail

# Locate and verify probe.env.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPOSITORY_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${SCRIPT_DIR}/probe.env"

if [[ ! -f "${ENV_FILE}" ]]; then
    echo "Can't locate probe.env."
    echo "Please run ./probe/generate_probe_env.sh first."
    exit 1
fi

# shellcheck disable=SC1090
source "${ENV_FILE}"

cd "${REPOSITORY_ROOT}"

# Set inventory groups and the default test module.
PROBE_RUNNER_GROUP="${PROBE_RUNNER_GROUP:-swiftclient}"
SWIFT_PROXY_GROUP="${SWIFT_PROXY_GROUP:-proxy}"
TEST_MODULE="${1:-probe.tests.test_final_sharding_workload}"

# Verify TEST_MODULE is a safe dotted Python name.
if [[ ! "${TEST_MODULE}" =~ ^[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_][A-Za-z0-9_]*)*$ ]]; then
    echo "Invalid test name: ${TEST_MODULE}" >&2
    echo "Use a dotted Python name, for example: probe.tests.test_final_sharding_workload." >&2
    exit 1
fi

# Prepare ring information for the test.
RING_STAGE="$(mktemp -d)"
trap 'rm -rf "${RING_STAGE}"' EXIT

echo "Copying the current container ring to ${PROBE_RUNNER}..."
ANSIBLE_CONFIG=ansible.cfg ANSIBLE_LIBRARY=library \
    ansible "${SWIFT_PROXY_GROUP}" -i hosts --become \
    --module-name ansible.builtin.fetch \
    --args "src=${SWIFT_CONFIG_DIR}/container.ring.gz dest=${RING_STAGE}/container.ring.gz flat=true" \
    >/dev/null
ANSIBLE_CONFIG=ansible.cfg ANSIBLE_LIBRARY=library \
    ansible "${PROBE_RUNNER_GROUP}" -i hosts --become \
    --module-name ansible.builtin.copy \
    --args "src=${RING_STAGE}/container.ring.gz dest=${SWIFT_CONFIG_DIR}/container.ring.gz owner=root group=root mode=0644" \
    >/dev/null


# Resync files to the VM that executes the test.
echo "Syncing probe files to ${PROBE_RUNNER}..."
vagrant rsync "${PROBE_RUNNER}" >/dev/null

echo "Running probe test:"
echo "  runner: ${PROBE_RUNNER}"
echo "  test:   ${TEST_MODULE}"
echo

# Run unittest on the probe runner VM.
vagrant ssh "${PROBE_RUNNER}" -c "
    set -e
    source '${SWIFT_TEST_RC}'
    cd /vagrant
    sudo -E python3 -m unittest -v ${TEST_MODULE}
"
