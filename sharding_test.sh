#!/usr/bin/env bash
# Configure and run the final sharding Observer + Workloader test.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

# Keep this profile synchronized with probe/tests/test_final_sharding_workload.py.
SHARDING_THRESHOLD=200

python3 probe/set_sharding_threshold.py "${SHARDING_THRESHOLD}"
probe/generate_probe_env.sh
probe/run_probe.sh probe.tests.test_final_sharding_workload
