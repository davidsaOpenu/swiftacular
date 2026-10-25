#!/usr/bin/env bash

set -euo pipefail

# Run from the repo root so the .vagrant removal below hits the right directory
cd "$(dirname "$0")"

export LIBVIRT_DEFAULT_URI="qemu:///system" # because we have libvirt.qemu_use_session = false in Vagrantfile

failures=0

echo "=== Current Libvirt Domains ==="
virsh list --all

echo -e "\n=== Tearing Down Vagrant Environments ==="
mapfile -t vagrant_ids < <(vagrant global-status --prune | awk '/virtualbox|libvirt/ { print $1 }')

if [ ${#vagrant_ids[@]} -eq 0 ]; then
  echo "No Vagrant environments found."
fi
for id in "${vagrant_ids[@]}"; do
  echo "Destroying Vagrant VM: $id"
  if ! vagrant destroy -f "$id"; then
    echo "Failed to destroy Vagrant VM: $id" >&2
    failures=$((failures + 1))
  fi
done

echo -e "\n=== Cleaning Residual Libvirt Domains ==="
mapfile -t domains < <(virsh list --all --name | grep swiftacular || true)

if [ ${#domains[@]} -eq 0 ]; then
  echo "No stray 'swiftacular' libvirt domains found."
fi
for domain in "${domains[@]}"; do
  echo "Destroying and undefining: $domain"
  # Fails harmlessly if the domain is already shut off
  virsh destroy "$domain" 2>/dev/null || true
  # --nvram is needed to undefine UEFI domains
  if ! virsh undefine "$domain" --remove-all-storage --snapshots-metadata --nvram; then
    echo "Failed to undefine libvirt domain: $domain" >&2
    failures=$((failures + 1))
  fi
done

echo -e "\n=== Verification ==="
vagrant global-status --prune

echo "Removing local Vagrant state (.vagrant)..."
rm -rf .vagrant

if [ "$failures" -gt 0 ]; then
  echo "Cleanup finished with $failures failure(s)." >&2
  exit 1
fi
echo "Cleanup complete!"
