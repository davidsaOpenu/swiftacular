#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")"

# 1) Ensure required Ansible collections (idempotent)
ansible-galaxy collection install "git+https://github.com/performancecopilot/ansible-pcp.git,v2.3.0"

echo "start"

# 2) Bring up Vagrant environment
vagrant up

# 3) Generate dynamic Ansible inventory from Vagrant ssh-config
#    This avoids hard-coding IPs/keys that change each run.
vagrant ssh-config > .vagrant/ssh-config

cat > hosts <<'INV'
[storage]
# The block below is auto-filled by the next awk; do not edit manually.
INV

awk '
  BEGIN { group="storage" }
  /^Host / && $2 != "*" { host=$2; next }
  /HostName/ { ip=$2; next }
  /User / { user=$2; next }
  /Port / { port=$2; next }
  /IdentityFile/ { key=$2; next }
  /UserKnownHostsFile/ { ukh=$2; next }
  /StrictHostKeyChecking/ { shk=$2; next }
  /^$/ {
    if (host && ip) {
      printf "%s ansible_host=%s ansible_port=%s ansible_user=%s ansible_ssh_private_key_file=%s ansible_ssh_common_args='\''-o UserKnownHostsFile=%s -o StrictHostKeyChecking=%s'\'' ansible_python_interpreter=/usr/bin/python3\n",
             host, ip, (port?port:22), (user?user:"vagrant"), key, (ukh?ukh:"/dev/null"), (shk?shk:"no")
    }
    host=ip=user=port=key=ukh=shk=""
  }
  END { if (host && ip) printf "%s ansible_host=%s\n", host, ip }
' .vagrant/ssh-config >> hosts

echo "Generated inventory:"
cat hosts

# 4) Ensure group_vars/all exists (if your repo provides an example)
if [[ -f group_vars/all.example && ! -f group_vars/all ]]; then
  cp group_vars/all.example group_vars/all
fi

# 5) Run the full Ceph automation (compile + verify)
./run_ceph_automation.sh

# 6) (Optional) Monitoring bootstrap — keep commented unless you need it.
# ANSIBLE_CONFIG=ansible.cfg ANSIBLE_LIBRARY=library ansible-playbook -i hosts setup-swift-monitoring.yml
# ansible-playbook -i 'localhost,' -c local jsonnet_install.yml
# python monitoring/grafana/configure_grafana.py create-dashboard "${grafana_ip}:3000" admin admin "monitoring/grafana/dashboards/..." "UID"

echo "done"
