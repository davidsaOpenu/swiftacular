import swiftclient

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
PROXY_BASE_URL = f"http://{KEYSTONE_HOST}:5000"
AUTH_URL = f"{PROXY_BASE_URL}/v3"
AUTH_VERSION = '3'
USER = "achilles"
KEY = "CHANGEME"
PROJECT = 'demo'
DEFAULT_VALUE = 'Default'
OS_OPTIONS = {
    'user_domain_name': DEFAULT_VALUE,
    'project_domain_name': DEFAULT_VALUE,
    'project_name': PROJECT
}

def make_conn():
    return swiftclient.Connection(
        authurl=AUTH_URL,
        user=USER,
        key=KEY,
        os_options=OS_OPTIONS,
        auth_version=AUTH_VERSION
    )
