#!/usr/bin/env bash

set -euo pipefail

for cmd in vagrant ansible-playbook; do
  if ! command -v $cmd &> /dev/null; then
    echo "$cmd could not be found. Please install it."
    exit 1
  fi
done

if ! vagrant plugin list | grep -q 'vagrant-libvirt'; then
    echo "Installing vagrant-libvirt plugin..."
    vagrant plugin install vagrant-libvirt
fi

echo "Bringing up Jenkins VM..."
VAGRANT_VAGRANTFILE=Vagrantfile.jenkins vagrant up

echo "Updating SSH config for jenkins-01..."
if [ -f ~/.ssh/config ]; then
  awk '
    /^Host jenkins-/ { skip=1; next }
    /^Host / { skip=0 }
    !skip { print }
  ' ~/.ssh/config > ~/.ssh/config.tmp
  mv ~/.ssh/config.tmp ~/.ssh/config
fi
VAGRANT_VAGRANTFILE=Vagrantfile.jenkins vagrant ssh-config jenkins-01 >> ~/.ssh/config
chmod 600 ~/.ssh/config
echo "SSH config updated."

echo "Running Jenkins deployment playbook..."
ANSIBLE_CONFIG=ansible.cfg ANSIBLE_LIBRARY=library ansible-playbook -i hosts deploy_jenkins.yml -v --ask-vault-pass
