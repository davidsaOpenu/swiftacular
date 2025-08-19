#!/bin/bash
set -e

echo "--- Starting Ceph Compilation ---"
ansible-playbook ceph_playbook.yml --tags compile

echo "--- Starting Ceph Verification ---"
ansible-playbook ceph_playbook.yml --tags verify
