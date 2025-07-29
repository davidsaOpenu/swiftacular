#!/bin/bash

set -euo pipefail

# Check for required commands
for cmd in python vagrant ansible-playbook ansible-galaxy; do
  if ! command -v $cmd &> /dev/null; then
    echo "$cmd could not be found. Please install it."
    exit 1
  fi
done

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

  echo "*********************************************************************************************"
  echo "Running playbook $description..."
  echo "*********************************************************************************************"

  local start_time=$(date +%s%3N)  # Get start time in epoch milliseconds

  ANSIBLE_CONFIG=ansible.cfg ANSIBLE_LIBRARY=library ansible-playbook -i hosts $playbook

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

# Check if vagrant-libvirt plugin is installed
if ! vagrant plugin list | grep -q 'vagrant-libvirt'; then
    echo "Installing vagrant-libvirt plugin..."
    vagrant plugin install vagrant-libvirt
else
    echo "vagrant-libvirt plugin is already installed."
fi

./vagrant_box.sh

# Install community.general module
ansible-galaxy collection install community.general

# Install community.mysql
ansible-galaxy collection install community.mysql

# Install performancecopilot.metrics collection
# Explicitly get v2.3.0. ansible-galaxy collection install performancecopilot.metrics
# installs lates 2.4.0 without redis roles.
# TODO: install latest, address the issue.
ansible-galaxy collection install git+https://github.com/performancecopilot/ansible-pcp.git,v2.3.0

# Run the playbooks with timing and logging
echo start
vagrant up


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

# Deploy Swift Cluster
run_playbook "deploy_swift_cluster.yml" "Deploy Swift Cluster"

run_playbook "setup_workload_test.yml" "Setup Workload Test"
