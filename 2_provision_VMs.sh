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
