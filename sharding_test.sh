#!/usr/bin/env bash
# Configure and run the insertion performance benchmark.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

# Keep this threshold synchronized with probe/tests/test_insertion_benchmark.py.

python3 probe/set_sharding_threshold.py 10000
probe/generate_probe_env.sh
probe/run_probe.sh probe.tests.test_insertion_benchmark
