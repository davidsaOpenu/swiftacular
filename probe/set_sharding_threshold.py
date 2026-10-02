#!/usr/bin/env python3
"""Set Swift's automatic container-sharding threshold.
Run this script from the Swiftacular repository root on the Vagrant host:

for example: python3 probe/set_sharding_threshold.py 2000

The script updates the persistent templates and live configurations
then restarts the container sharders, and verifies the change.
"""

import argparse
import json
import re
import subprocess
import sys
import tempfile
from pathlib import Path


TEMPLATE_PATHS = (
    Path("roles/storage/templates/container-server.conf.j2"),
    Path("roles/storage/templates/container-replication.conf.j2"),
)

LIVE_CONFIG_PATHS = (
    "/etc/swift/container-server/container-server.conf",
    "/etc/swift/container-server/container-replication.conf",
)

# Related values that Swift calculates automatically.
DERIVED_SETTINGS = (
    "rows_per_shard",
    "minimum_shard_size",
)


def make_settings(threshold):
    if threshold < 2:
        fail("threshold must be at least 2")

    return {
        "auto_shard": "true",
        "shard_container_threshold": str(threshold),
    }


def fail(message):
    print("ERROR:", message, file=sys.stderr)
    raise SystemExit(1)


def parse_args():
    parser = argparse.ArgumentParser(
        description=(
            "Set automatic sharding threshold on every Swift storage node."
        )
    )
    parser.add_argument(
        "threshold",
        type=int,
        help="object-row count at which automatic sharding becomes eligible",
    )
    return parser.parse_args()


def require_repository(root):
    #Making sure the file is being run from a valid directory
    missing = [
        path
        for path in (*TEMPLATE_PATHS, Path("hosts"))
        if not (root / path).is_file()
    ]
    if missing:
        rendered = ", ".join(str(path) for path in missing)
        fail("run from the Swiftacular repository root; missing: " + rendered)


def replace_template_settings(path, settings):
    # Replaces the setting in the node to the new settings
    original_mode = path.stat().st_mode
    original = path.read_text(encoding="utf-8")
    updated = original

    for name, value in settings.items():
        pattern = re.compile(r"(?m)^" + re.escape(name) + r"\s*=.*$")
        # Making sure structure is made of one config
        updated, count = pattern.subn(name + " = " + value, updated)
        if count != 1:
            fail(
                "expected exactly one " + repr(name) + " setting in "
                + str(path) + ", found " + str(count)
            )

    for name in DERIVED_SETTINGS:
        pattern = re.compile(r"(?m)^" + re.escape(name) + r"\s*=.*\n?")
        updated = pattern.sub("", updated)

    if updated == original:
        print("Persistent template already correct:", path)
        return

    with tempfile.NamedTemporaryFile(
        mode="w",
        encoding="utf-8",
        newline="",
        dir=path.parent,
        prefix="." + path.name + ".",
        delete=False,
    ) as temporary:
        temporary.write(updated)
        temporary_path = Path(temporary.name)

    temporary_path.chmod(original_mode)
    temporary_path.replace(path)
    print("Updated persistent template:", path)


def run_ansible(module, arguments):
    # Use Ansible directly.
    command = [
        "ansible",
        "storage",
        "-i",
        "hosts",
        "--become",
        "--module-name",
        module,
        "--args",
        json.dumps(arguments),
    ]
    subprocess.run(command, check=True)


def deploy_live_settings(settings):
    # For each node, use ansible to deploy the new settings
    for name in DERIVED_SETTINGS:
        for config_path in LIVE_CONFIG_PATHS:
            run_ansible(
                "ansible.builtin.replace",
                {
                    "path": config_path,
                    "regexp": r"(?m)^" + name + r"\s*=.*\n?",
                    "replace": "",
                },
            )

    previous_setting = "[container-sharder]"

    for name, value in settings.items():
        for config_path in LIVE_CONFIG_PATHS:
            # Remove every old instance first. This also removes a config
            # with duplicates left by an interrupted or older run.
            run_ansible(
                "ansible.builtin.replace",
                {
                    "path": config_path,
                    "regexp": r"(?m)^" + name + r"\s*=.*\n?",
                    "replace": "",
                },
            )
            run_ansible(
                "ansible.builtin.lineinfile",
                {
                    "path": config_path,
                    "line": name + " = " + value,
                    "insertafter": (
                        r"^" + re.escape(previous_setting) + r"\s*=.*$"
                        if previous_setting != "[container-sharder]"
                        else r"^\[container-sharder\]$"
                    ),
                },
            )
        previous_setting = name


def restart_sharders():
    # Restarting shards with the new profile
    run_ansible(
        "ansible.builtin.shell",
        {
            "cmd": (
                "swift-init container-sharder stop || true\n"
                "swift-init container-sharder.container-replication start"
            ),
            "executable": "/bin/bash",
        },
    )


def verify_live_settings(settings):
    # Verify live config has been updated to match settings
    expressions = []
    for path in LIVE_CONFIG_PATHS:
        for name, value in settings.items():
            quoted_path = json.dumps(path)
            expressions.append(
                "test \"$(grep -Ec '^" + name
                + "[[:space:]]*=' " + quoted_path + ")\" -eq 1"
            )
            expressions.append(
                "grep -Fx " + json.dumps(name + " = " + value)
                + " " + quoted_path
            )
        for name in DERIVED_SETTINGS:
            expressions.append(
                "! grep -Eq '^" + name + "[[:space:]]*=' " + quoted_path
            )
    expressions.append(
        "swift-init container-sharder.container-replication status"
    )

    run_ansible(
        "ansible.builtin.shell",
        {
            "cmd": "set -e\n" + "\n".join(expressions),
            "executable": "/bin/bash",
        },
    )

# When calling the code will start the main with the given value
def main():
    args = parse_args()

    root = Path.cwd()
    require_repository(root)
    settings = make_settings(args.threshold)

    print("Applying automatic sharding profile:")
    for name, value in settings.items():
        print(" ", name, "=", value)
    # Since the process changes multipole elements one by one, shutting down
    # or crushing can cause inconsistencies. Debugging this process is complicated
    # and will be done directly by the user if necessary.
    # We will warn the user of the possibility and update in case of failure.
    print(
        "WARNING: this operation is not transactional. Persistent templates "
        "are updated before live storage nodes; if deployment fails, inspect "
        "and reconcile both templates and every live configuration."
    )
    # Replace each of the templates(live node paths)
    for relative_path in TEMPLATE_PATHS:
        replace_template_settings(root / relative_path, settings)

    try:
        deploy_live_settings(settings)
        restart_sharders()
        verify_live_settings(settings)
    except FileNotFoundError:
        fail(
            "the 'ansible' executable was not found; configuration templates "
            "may already have changed. Check both templates and every storage "
            "node before continuing, then rerun the command when Ansible is "
            "available"
        )
    except subprocess.CalledProcessError as error:
        fail(
            "Ansible deployment failed with exit code "
            + str(error.returncode) + "; "
            "the sharding profile may now be only partially applied. Check "
            "both templates and both container configuration files on every "
            "storage node before continuing, then rerun the command"
        )

    print("Changed the sharding threshold and verified it successfully.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
