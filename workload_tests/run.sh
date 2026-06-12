#!/usr/bin/env bash
# Run a Swiftacular workload test suite.
#
#   run.sh workload   the tiny end-to-end Swift workload (needs a live cluster
#                     + python-swiftclient + a hosts inventory in this dir)
#   run.sh bs         the BlueStore utility pytest suite (test_bs_*.py)
#
# The pytest invocations are the single source of truth shared by the VM/Ansible
# flow (setup_workload_test.yml) and the Kubernetes smoke test (smoke-test.sh).
# The bs suite is globbed (test_bs_*.py), so adding a future BlueStore test is
# just dropping the file here — no change to this script or its callers.
set -euo pipefail

d="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${d}"

suite="${1:-}"
case "${suite}" in
  workload)
    exec python3 -m pytest test_workload.py::test_tiny_workload -svx
    ;;
  bs)
    # shellcheck disable=SC2046 -- intentional glob expansion of the bs suite
    exec python3 -m pytest $(ls test_bs_*.py) -v
    ;;
  *)
    echo "ERROR: usage: run.sh <workload|bs>" >&2
    exit 2
    ;;
esac
