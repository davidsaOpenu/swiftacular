#!/usr/bin/env bash

set -euo pipefail

# Check for required commands
for cmd in python vagrant; do
  if ! command -v $cmd &> /dev/null; then
    echo "$cmd could not be found. Please install it."
    exit 1
  fi
done

# Check if vagrant-libvirt plugin is installed
if ! vagrant plugin list | grep -q 'vagrant-libvirt'; then
    echo "Installing vagrant-libvirt plugin..."
    vagrant plugin install vagrant-libvirt
else
    echo "vagrant-libvirt plugin is already installed."
fi

./vagrant_box.sh

# Run the playbooks with timing and logging
echo start
vagrant up

# Update SSH config for all Swift VMs
echo "Updating SSH config for Swift VMs..."

# Remove all existing "Host swift-*" blocks from ~/.ssh/config
if [ -f ~/.ssh/config ]; then
  # Create temp file without swift host entries
  awk '
    /^Host swift-/ { skip=1; next }
    /^Host / { skip=0 }
    !skip { print }
  ' ~/.ssh/config > ~/.ssh/config.tmp
  mv ~/.ssh/config.tmp ~/.ssh/config
fi

# Get list of all VMs and add their SSH config
vagrant status --machine-readable | \
  grep ",state," | \
  cut -d',' -f2 | \
  while read -r vm_name; do
    if [[ $vm_name == swift-* ]] || [[ $vm_name == grafana-* ]]; then
      echo "Adding SSH config for $vm_name"
      vagrant ssh-config "$vm_name" >> ~/.ssh/config
    fi
  done
chmod 600 /var/lib/jenkins/.ssh/config
echo "SSH config updated successfully"
