#!/usr/bin/env bash

set -euo -x pipefail

# Check for required commands
for cmd in python ansible-playbook ansible-galaxy; do
  if ! command -v $cmd &> /dev/null; then
    echo "$cmd could not be found. Please install it."
    exit 1
  fi
done

# Install collections from requirements (before running tox)
ansible-galaxy collection install -r collections_requirements.yml -p library/ansible_collections


# Pre-commit checks
tox


# Array of dashboard JSON files and their UIDs
declare -A dashboards
dashboards["swiftdbinfo.jsonnet"]="swiftdbinfo"
dashboards["pcp-redis-host-overview.jsonnet"]="pcp-host"

grafana_ip="192.168.100.150"

# Function to run ansible-playbook and log the time
run_playbook() {
  local playbook=$1
  local description=$2
  local tags=${3:-}  # Optional tags parameter (empty string if not provided)

  echo "*********************************************************************************************"
  echo "Running playbook $description..."
  echo "*********************************************************************************************"

  local start_time=$(date +%s%3N)  # Get start time in epoch milliseconds

  # Build the command with optional tags
  # local cmd="ANSIBLE_CONFIG=ansible.cfg ANSIBLE_LIBRARY=library ansible-playbook -i hosts $playbook" #default backend
  local cmd="ANSIBLE_CONFIG=ansible.cfg ANSIBLE_LIBRARY=library ansible-playbook -i hosts $playbook -e 'swift_backend=bs' -v"
  if [ -n "$tags" ]; then
    cmd="$cmd --tags $tags"
  fi

  eval $cmd

  local end_time=$(date +%s%3N)  # Get end time in epoch milliseconds
  local duration=$((end_time - start_time))  # Duration in milliseconds

  local duration_seconds=$((duration / 1000))
  local minutes=$((duration_seconds / 60))
  local seconds=$((duration_seconds % 60))

  echo "$description completed in $minutes minutes and $seconds seconds."

  # Generate Grafana link with epoch milliseconds
  for dashboard in "${!dashboards[@]}"; do
    uid=${dashboards[$dashboard]}
    local grafana_link="http://${grafana_ip}:3000/d/${uid}/?from=${start_time}&to=${end_time}"
    echo "Grafana Dashboard for $description: $grafana_link"
  done
}

cp group_vars/all.example group_vars/all

ANSIBLE_CONFIG=ansible.cfg ANSIBLE_LIBRARY=library ansible-playbook -i hosts setup-swift-monitoring.yml

# Install jsonnet on localhost
ansible-playbook -i 'localhost,' -c local jsonnet_install.yml


# Iterate over dashboard pairs and create each dashboard
for dashboard in "${!dashboards[@]}"; do
  uid=${dashboards[$dashboard]}
  python monitoring/grafana/configure_grafana.py create-dashboard ${grafana_ip}:3000 admin admin "monitoring/grafana/dashboards/${dashboard}" "${uid}"
  echo "Grafana Dashboard for ${dashboard}: http://${grafana_ip}:3000/d/${uid}/"
done

# Install all packages (ensures /usr/lib/python3.9/site-packages/swift/* exists)
run_playbook "install_packages_on_nodes.yml" "Install Packages" "packages"

# Apply Swift patches (requires Swift packages to be installed)
run_playbook "apply_patches.yml" "Apply Swift Patches"

# Build BlueStore C++ utilities (only when swift_backend=bs)
run_playbook "update_ceph_bs_tools.yml" "Build BlueStore Utilities"

# Deploy Swift Cluster (repository setup and configuration)
run_playbook "deploy_swift_cluster.yml" "Deploy Swift Cluster" "configure"

# Setup and run workload tests
run_playbook "setup_workload_test.yml" "Setup Workload Test"
