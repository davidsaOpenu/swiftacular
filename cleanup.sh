#!/usr/bin/env bash

set -e

export LIBVIRT_DEFAULT_URI="qemu:///system" # because we have libvirt.qemu_use_session = false in Vagrantfile

virsh list --all


for id in $(vagrant global-status --prune | grep -E 'virtualbox|libvirt' | awk '{ print $1 }'); do
  vagrant destroy -f "$id"
done


for domain in $(virsh list --all | awk '/swiftacular/ { print $2 }'); do
  virsh destroy "$domain" 2>/dev/null || true
  virsh undefine "$domain" --remove-all-storage || true
done


# vagrant box remove -f eurolinux-vagrant/centos-stream-9 || true

vagrant global-status --prune
rm -rf .vagrant
