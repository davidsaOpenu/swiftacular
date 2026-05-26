#!/bin/bash
#
# Memory Footprint Evaluation Script for SwiftBS
# Compares memory usage between regular and BlueStore backends
#
# Usage: ./evaluate_memory.sh [regular|bs]
#

set -e

BACKEND="${1:-current}"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
RESULTS_DIR="memory_results"
mkdir -p "$RESULTS_DIR"

BACKEND_LABEL="$BACKEND"
if [ "$BACKEND" == "current" ]; then
    # Detect current backend
    BACKEND_CONFIG=$(ANSIBLE_CONFIG=ansible.cfg ansible storage -i hosts -m shell \
        -a "grep '^use = ' /etc/swift/object-server.conf | head -1" 2>/dev/null | grep "egg:swift" || echo "unknown")

    if echo "$BACKEND_CONFIG" | grep -q "bs_object"; then
        BACKEND_LABEL="bluestore"
    elif echo "$BACKEND_CONFIG" | grep -q "swift#object"; then
        BACKEND_LABEL="regular"
    fi
fi

OUTPUT_FILE="$RESULTS_DIR/memory_${BACKEND_LABEL}_${TIMESTAMP}.txt"

echo "========================================" | tee "$OUTPUT_FILE"
echo "Memory Footprint Evaluation" | tee -a "$OUTPUT_FILE"
echo "Backend: $BACKEND_LABEL" | tee -a "$OUTPUT_FILE"
echo "Timestamp: $TIMESTAMP" | tee -a "$OUTPUT_FILE"
echo "========================================" | tee -a "$OUTPUT_FILE"
echo "" | tee -a "$OUTPUT_FILE"

echo "=== 1. Overall Memory Statistics ===" | tee -a "$OUTPUT_FILE"
ANSIBLE_CONFIG=ansible.cfg ansible storage -i hosts -m shell \
  -a "cat /proc/meminfo | grep -E 'MemTotal|MemFree|MemAvailable|Slab|Cached|SwapCached'" -b \
  2>/dev/null | tee -a "$OUTPUT_FILE"

echo "" | tee -a "$OUTPUT_FILE"
echo "=== 2. Kernel Slab Allocations (Top 20) ===" | tee -a "$OUTPUT_FILE"
ANSIBLE_CONFIG=ansible.cfg ansible storage -i hosts -m shell \
  -a "slabtop -o | head -20" -b \
  2>/dev/null | tee -a "$OUTPUT_FILE"

echo "" | tee -a "$OUTPUT_FILE"
echo "=== 3. Object Count ===" | tee -a "$OUTPUT_FILE"
ANSIBLE_CONFIG=ansible.cfg ansible storage -i hosts -m shell \
  -a "find /srv/node/*/objects -type f -name '*.data' 2>/dev/null | wc -l" -b \
  2>/dev/null | tee -a "$OUTPUT_FILE"

echo "" | tee -a "$OUTPUT_FILE"
echo "=== 4. Swift Object Server Memory (RSS) ===" | tee -a "$OUTPUT_FILE"
ANSIBLE_CONFIG=ansible.cfg ansible storage -i hosts -m shell \
  -a "ps aux | grep swift-object-server | grep -v grep | awk '{sum+=\$6} END {print sum \" KB\"}'" -b \
  2>/dev/null | tee -a "$OUTPUT_FILE"

echo "" | tee -a "$OUTPUT_FILE"
echo "=== 5. XFS Inode/Dentry Details ===" | tee -a "$OUTPUT_FILE"
ANSIBLE_CONFIG=ansible.cfg ansible storage -i hosts -m shell \
  -a "slabtop -o | grep -E 'xfs_inode|dentry|lsm_inode'" -b \
  2>/dev/null | tee -a "$OUTPUT_FILE"

echo "" | tee -a "$OUTPUT_FILE"
echo "=== 6. Backend Configuration ===" | tee -a "$OUTPUT_FILE"
ANSIBLE_CONFIG=ansible.cfg ansible storage -i hosts -m shell \
  -a "grep '^use = ' /etc/swift/object-server.conf" -b \
  2>/dev/null | tee -a "$OUTPUT_FILE"

echo "" | tee -a "$OUTPUT_FILE"
echo "========================================" | tee -a "$OUTPUT_FILE"
echo "Results saved to: $OUTPUT_FILE" | tee -a "$OUTPUT_FILE"
echo "========================================" | tee -a "$OUTPUT_FILE"

# Generate summary
echo "" | tee -a "$OUTPUT_FILE"
echo "=== SUMMARY ===" | tee -a "$OUTPUT_FILE"

# Extract key metrics (parse from output)
echo "Extracting summary metrics..." | tee -a "$OUTPUT_FILE"

# Calculate per-node averages
TOTAL_OBJECTS=$(grep -A1 "Object Count" "$OUTPUT_FILE" | grep "CHANGED" | awk '{print $NF}' | paste -sd+ | bc)
NUM_NODES=$(grep -c "swift-storage" "$OUTPUT_FILE" | head -1)
if [ "$NUM_NODES" -eq 0 ]; then NUM_NODES=3; fi

AVG_OBJECTS=$((TOTAL_OBJECTS / NUM_NODES))

echo "Average objects per node: $AVG_OBJECTS" | tee -a "$OUTPUT_FILE"

# Extract slab memory (approximate from first node)
SLAB_MB=$(grep -m1 "^Slab:" "$OUTPUT_FILE" | awk '{print int($2/1024)}')
echo "Approximate slab memory per node: ${SLAB_MB} MB" | tee -a "$OUTPUT_FILE"

if [ "$AVG_OBJECTS" -gt 0 ]; then
    PER_OBJ_KB=$((SLAB_MB * 1024 / AVG_OBJECTS))
    echo "Approximate memory per object: ${PER_OBJ_KB} KB" | tee -a "$OUTPUT_FILE"
fi

echo "" | tee -a "$OUTPUT_FILE"
echo "To compare backends, run:" | tee -a "$OUTPUT_FILE"
echo "  1. ./evaluate_memory.sh regular" | tee -a "$OUTPUT_FILE"
echo "  2. Switch backend and redeploy" | tee -a "$OUTPUT_FILE"
echo "  3. ./evaluate_memory.sh bs" | tee -a "$OUTPUT_FILE"
echo "  4. diff -u memory_results/memory_regular_*.txt memory_results/memory_bs_*.txt" | tee -a "$OUTPUT_FILE"
