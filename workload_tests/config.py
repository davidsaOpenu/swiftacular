import os
import re

def get_keystone_host(inventory_path=None):
    if inventory_path is None:
        inventory_path = os.path.join(os.path.dirname(__file__), 'hosts')

    in_auth_section = False
    with open(inventory_path) as f:
        for line in f:
            line = line.strip()
            if line == '[authentication]':
                in_auth_section = True
                continue
            if line.startswith('['):
                in_auth_section = False
                continue
            if in_auth_section and not line.startswith('#') and line:
                match = re.search(r'ansible_ssh_host=(\S+)', line)
                if match:
                    return match.group(1)

    raise RuntimeError("Could not find keystone host in inventory")

KEYSTONE_HOST = get_keystone_host()
