#!/usr/bin/env bash
# Install ansible collections required before running tox (pre-commit runs
# ansible-lint, which needs these collections present to resolve modules/roles).
set -euo pipefail

command -v ansible-galaxy &>/dev/null || {
  echo "ansible-galaxy could not be found. Please install it." >&2
  exit 1
}

ansible-galaxy collection install community.general --force
ansible-galaxy collection install community.mysql --force
# Explicitly get v2.3.0. ansible-galaxy collection install performancecopilot.metrics
# installs latest 2.4.0 without redis roles.
# TODO: install latest, address the issue.
ansible-galaxy collection install git+https://github.com/performancecopilot/ansible-pcp.git,v2.3.0 --force
ansible-galaxy collection install ansible.posix --force
