#!/usr/bin/env bash
set -Eeuo pipefail

# Always run from the script directory (repo root expected)
cd "$(dirname "$0")"

echo "--- Starting Ceph Compilation ---"
ANSIBLE_CONFIG=ansible.cfg ANSIBLE_LIBRARY=library \
ansible-playbook ceph_playbook.yml -i hosts --tags compile

echo "--- Starting Ceph Verification ---"
ANSIBLE_CONFIG=ansible.cfg ANSIBLE_LIBRARY=library \
ansible-playbook ceph_playbook.yml -i hosts --tags verify
