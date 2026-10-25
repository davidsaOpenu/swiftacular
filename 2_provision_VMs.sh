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

# vagrant-libvirt 0.12.x passes libvirt_ip_command, which fog-libvirt >= 0.13 dropped
# ("[fog][WARNING] Unrecognized arguments: libvirt_ip_command"). Pin fog-libvirt 0.12.2,
# and fog-json 1.2.0 since newer fog-json needs a json gem newer than Vagrant 2.4.0 embeds.
pin_vagrant_plugin() {
    if ! vagrant plugin list | grep -qF "$1 ($2,"; then
        echo "Pinning $1 to $2..."
        vagrant plugin install "$1" --plugin-version "$2"
    fi
}
pin_vagrant_plugin fog-json 1.2.0
pin_vagrant_plugin fog-libvirt 0.12.2

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
chmod 600 ~/.ssh/config
echo "SSH config updated successfully"
