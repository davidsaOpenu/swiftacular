#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPOSITORY_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${SCRIPT_DIR}/probe.env"
TEMPLATE_FILE="${SCRIPT_DIR}/probe.env.template"
INVENTORY_FILE="${REPOSITORY_ROOT}/hosts"

fail() {
    echo "ERROR: $*" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"
}

require_command ansible-inventory
require_command python3
require_command vagrant

[[ -f "${INVENTORY_FILE}" ]] || fail "inventory file not found: ${INVENTORY_FILE}"
[[ -f "${REPOSITORY_ROOT}/Vagrantfile" ]] || \
    fail "Vagrantfile not found: ${REPOSITORY_ROOT}/Vagrantfile"
[[ -f "${TEMPLATE_FILE}" ]] || fail "environment template not found: ${TEMPLATE_FILE}"

# Load the standard topology for values that are not topology selectors.
# Discovered runner, proxy, configuration, and credential values below replace
# their template defaults before probe.env is written.
# shellcheck disable=SC1090
source "${TEMPLATE_FILE}"

cd "${REPOSITORY_ROOT}"

INVENTORY_JSON="$(
    ANSIBLE_CONFIG=ansible.cfg ANSIBLE_LIBRARY=library \
        ansible-inventory -i "${INVENTORY_FILE}" --list
)"

discover_group() {
    local preferred_group="$1"
    local role_pattern="$2"

    INVENTORY_JSON="${INVENTORY_JSON}" python3 - \
        "${preferred_group}" "${role_pattern}" <<'PY'
import json
import os
import re
import sys

inventory = json.loads(os.environ["INVENTORY_JSON"])
preferred, pattern = sys.argv[1:]

def hosts(group):
    value = inventory.get(group, {})
    return value.get("hosts", []) if isinstance(value, dict) else []

if hosts(preferred):
    print(preferred)
    raise SystemExit(0)

matches = [
    group
    for group in inventory
    if not group.startswith("_")
    and re.search(pattern, group, re.IGNORECASE)
    and hosts(group)
]

if len(matches) != 1:
    raise SystemExit(
        "could not select one inventory group for " + repr(pattern)
        + "; candidates=" + repr(matches)
    )

print(matches[0])
PY
}

group_hosts() {
    local group="$1"

    INVENTORY_JSON="${INVENTORY_JSON}" python3 - "${group}" <<'PY'
import json
import os
import sys

inventory = json.loads(os.environ["INVENTORY_JSON"])
group = sys.argv[1]
for host in inventory.get(group, {}).get("hosts", []):
    print(host)
PY
}

PROBE_RUNNER_GROUP="$(discover_group swiftclient 'swift.*client|client|package.*cache')"
SWIFT_PROXY_GROUP="$(discover_group proxy 'proxy')"

mapfile -t PROBE_RUNNERS < <(group_hosts "${PROBE_RUNNER_GROUP}")
mapfile -t PROXY_NODES < <(group_hosts "${SWIFT_PROXY_GROUP}")

[[ ${#PROBE_RUNNERS[@]} -eq 1 ]] || \
    fail "expected one probe runner in ${PROBE_RUNNER_GROUP}; found ${#PROBE_RUNNERS[@]}"
[[ ${#PROXY_NODES[@]} -eq 1 ]] || \
    fail "expected one proxy in ${SWIFT_PROXY_GROUP}; found ${#PROXY_NODES[@]}"

PROBE_RUNNER="${PROBE_RUNNERS[0]}"
SWIFT_PROXY_NODE="${PROXY_NODES[0]}"

VAGRANT_STATUS="$(vagrant status --machine-readable)"

vagrant_state() {
    local machine="$1"
    awk -F, -v machine="${machine}" \
        '$2 == machine && $3 == "state" { state=$4 } END { print state }' \
        <<<"${VAGRANT_STATUS}"
}

PROBE_RUNNER_STATE="$(vagrant_state "${PROBE_RUNNER}")"
SWIFT_PROXY_STATE="$(vagrant_state "${SWIFT_PROXY_NODE}")"

[[ -n "${PROBE_RUNNER_STATE}" ]] || \
    fail "${PROBE_RUNNER} exists in Ansible inventory but not in Vagrant"
[[ -n "${SWIFT_PROXY_STATE}" ]] || \
    fail "${SWIFT_PROXY_NODE} exists in Ansible inventory but not in Vagrant"
[[ "${PROBE_RUNNER_STATE}" == "running" ]] || \
    fail "probe runner ${PROBE_RUNNER} is ${PROBE_RUNNER_STATE}, not running"
[[ "${SWIFT_PROXY_STATE}" == "running" ]] || \
    fail "proxy ${SWIFT_PROXY_NODE} is ${SWIFT_PROXY_STATE}, not running"

SWIFT_CONFIG_DIR="$(
    vagrant ssh "${SWIFT_PROXY_NODE}" -c \
        'for directory in /etc/swift /opt/swift/etc; do
             if sudo test -r "${directory}/container.ring.gz"; then
                 printf "%s\n" "${directory}"
                 exit 0
             fi
         done
         exit 1' 2>/dev/null | tr -d '\r' | tail -n 1
)"

[[ -n "${SWIFT_CONFIG_DIR}" ]] || \
    fail "could not discover a readable container.ring.gz on ${SWIFT_PROXY_NODE}"

vagrant ssh "${SWIFT_PROXY_NODE}" -c "
    sudo python3 -c '
from swift.common.ring import Ring
ring = Ring(\"${SWIFT_CONFIG_DIR}\", ring_name=\"container\")
assert any(ring.devs), \"container ring contains no devices\"
'
" >/dev/null || fail "Swift could not load the discovered container ring"

vagrant ssh "${PROBE_RUNNER}" -c \
    "sudo test -d '${SWIFT_CONFIG_DIR}'" >/dev/null || \
    fail "Swift configuration directory is absent on ${PROBE_RUNNER}"

SWIFT_TEST_RC="$(
    vagrant ssh "${PROBE_RUNNER}" -c \
        'for file in /home/vagrant/testrc /home/vagrant/openrc /etc/swift/testrc; do
             if test -r "${file}"; then
                 printf "%s\n" "${file}"
                 exit 0
             fi
         done
         exit 1' 2>/dev/null | tr -d '\r' | tail -n 1
)"

[[ -n "${SWIFT_TEST_RC}" ]] || \
    fail "could not discover a readable test credential file on ${PROBE_RUNNER}"

vagrant ssh "${PROBE_RUNNER}" -c "
    set -eu
    set -a
    source '${SWIFT_TEST_RC}'
    set +a
    test -n \"\${OS_AUTH_URL:-}\"
    test -n \"\${OS_USERNAME:-}\"
    test -n \"\${OS_PASSWORD:-}\"
    test -n \"\${OS_PROJECT_NAME:-\${OS_TENANT_NAME:-}}\"
" >/dev/null || fail "credential file is missing required OpenStack variables"

EXPECTED_SHARD_CONTAINER_THRESHOLD="$(
    python3 -c '
from probe.set_sharding_threshold import inspect_live_profile

profile = inspect_live_profile(
    setting_names=("shard_container_threshold",), verbose=False
)
values = {
    value
    for values_by_path in profile["shard_container_threshold"].values()
    for value in (values_by_path,)
}
if len(values) != 1:
    raise SystemExit("live shard thresholds are inconsistent")
print(values.pop())
'
)" || fail "could not read the consistent live sharding threshold"

[[ "${EXPECTED_SHARD_CONTAINER_THRESHOLD}" =~ ^[0-9]+$ ]] || \
    fail "invalid live sharding threshold: ${EXPECTED_SHARD_CONTAINER_THRESHOLD}"

SHARDING_PROFILE_LINES="$(
    python3 - <<'PY'
from probe.set_sharding_threshold import inspect_live_profile

profile = inspect_live_profile(verbose=False)
mapping = {
    "SHARDING_AUTO_SHARD": "auto_shard",
    "SHARDING_ROWS_PER_SHARD": "rows_per_shard",
    "SHARDING_MINIMUM_SHARD_SIZE": "minimum_shard_size",
    "SHARDING_SHRINK_THRESHOLD": "shrink_threshold",
    "SHARDING_SCANNER_BATCH_SIZE": "shard_scanner_batch_size",
    "SHARDING_CLEAVE_BATCH_SIZE": "cleave_batch_size",
}
for env_name, profile_name in mapping.items():
    values = set(profile[profile_name].values())
    if len(values) != 1:
        raise SystemExit("live profile is inconsistent for " + profile_name)
    print(env_name + "=" + values.pop())
PY
)" || fail "could not read the complete consistent live sharding profile"

{
    echo "# Generated dynamically by generate_probe_env.sh"
    echo "# Active topology values were discovered and validated."
    echo "# Standard service values came from probe.env.template."
    echo "# Do not edit this generated file manually."
    printf 'PROBE_RUNNER=%q\n' "${PROBE_RUNNER}"
    printf 'PROBE_RUNNER_GROUP=%q\n' "${PROBE_RUNNER_GROUP}"
    printf 'EXPECTED_SHARD_CONTAINER_THRESHOLD=%q\n' \
        "${EXPECTED_SHARD_CONTAINER_THRESHOLD}"
    printf '%s\n' "${SHARDING_PROFILE_LINES}"
    printf 'SWIFT_PROXY_NODE=%q\n' "${SWIFT_PROXY_NODE}"
    printf 'SWIFT_PROXY_GROUP=%q\n' "${SWIFT_PROXY_GROUP}"
    printf 'SWIFT_TEST_RC=%q\n' "${SWIFT_TEST_RC}"
    printf 'SWIFT_ADMIN_RC=%q\n' "${SWIFT_ADMIN_RC}"
    printf 'SWIFT_CONFIG_DIR=%q\n' "${SWIFT_CONFIG_DIR}"
    printf 'SWIFT_STORAGE_1=%q\n' "${SWIFT_STORAGE_1}"
    printf 'SWIFT_STORAGE_2=%q\n' "${SWIFT_STORAGE_2}"
    printf 'SWIFT_STORAGE_3=%q\n' "${SWIFT_STORAGE_3}"
    printf 'SWIFT_STORAGE_1_IP=%q\n' "${SWIFT_STORAGE_1_IP}"
    printf 'SWIFT_STORAGE_2_IP=%q\n' "${SWIFT_STORAGE_2_IP}"
    printf 'SWIFT_STORAGE_3_IP=%q\n' "${SWIFT_STORAGE_3_IP}"
    printf 'SWIFT_OBJECT_PORT=%q\n' "${SWIFT_OBJECT_PORT}"
    printf 'SWIFT_CONTAINER_PORT=%q\n' "${SWIFT_CONTAINER_PORT}"
    printf 'SWIFT_ACCOUNT_PORT=%q\n' "${SWIFT_ACCOUNT_PORT}"
    printf 'SWIFT_DEVICE_DIR=%q\n' "${SWIFT_DEVICE_DIR}"
} >"${ENV_FILE}"

echo "Generated ${ENV_FILE} from the active Swiftacular environment:"
echo "  runner:       ${PROBE_RUNNER} (${PROBE_RUNNER_GROUP})"
echo "  proxy:        ${SWIFT_PROXY_NODE} (${SWIFT_PROXY_GROUP})"
echo "  Swift config: ${SWIFT_CONFIG_DIR}"
echo "  credentials:  ${SWIFT_TEST_RC}"
echo "  threshold:    ${EXPECTED_SHARD_CONTAINER_THRESHOLD}"
