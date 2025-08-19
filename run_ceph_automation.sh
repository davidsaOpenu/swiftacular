#!/usr/bin/env bash
set -Eeuo pipefail

# Always run from the repo root (where this script lives)
cd "$(dirname "$0")"

# Nice, readable output and the config we ship in this repo
export ANSIBLE_STDOUT_CALLBACK=yaml
export ANSIBLE_LOAD_CALLBACK_PLUGINS=1
export ANSIBLE_CONFIG="${ANSIBLE_CONFIG:-ansible.cfg}"
export ANSIBLE_LIBRARY="${ANSIBLE_LIBRARY:-library}"

echo "--- Starting Ceph Compilation ---"
ansible-playbook -i hosts ceph_playbook.yml --tags compile -vv

echo "--- Starting Ceph Verification ---"
ansible-playbook -i hosts ceph_playbook.yml --tags verify -vv

echo "done"
