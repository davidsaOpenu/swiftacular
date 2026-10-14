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
from collections import defaultdict
from pathlib import Path


TEMPLATE_PATHS = (
    Path("roles/storage/templates/container-server.conf.j2"),
    Path("roles/storage/templates/container-replication.conf.j2"),
)

LIVE_CONFIG_PATHS = (
    "/etc/swift/container-server/container-server.conf",
    "/etc/swift/container-server/container-replication.conf",
)

ENV_PROFILE_NAMES = {
    "auto_shard": "SHARDING_AUTO_SHARD",
    "shard_container_threshold": "EXPECTED_SHARD_CONTAINER_THRESHOLD",
    "rows_per_shard": "SHARDING_ROWS_PER_SHARD",
    "minimum_shard_size": "SHARDING_MINIMUM_SHARD_SIZE",
    "shrink_threshold": "SHARDING_SHRINK_THRESHOLD",
    "shard_scanner_batch_size": "SHARDING_SCANNER_BATCH_SIZE",
    "cleave_batch_size": "SHARDING_CLEAVE_BATCH_SIZE",
}

# Related values that Swift calculates automatically.
DERIVED_SETTINGS = (
    "rows_per_shard",
    "minimum_shard_size",
)


# ---------------------------------------------------------------------------
# Validation and repository checks
# ---------------------------------------------------------------------------


def fail(message):
    """Print a command-line error and stop the current operation."""
    print("ERROR:", message, file=sys.stderr)
    raise SystemExit(1)


def require_repository(root):
    """Ensure the operation is running from the Swiftacular repository."""
    missing = [
        path
        for path in (*TEMPLATE_PATHS, Path("hosts"))
        if not (root / path).is_file()
    ]
    if missing:
        rendered = ", ".join(str(path) for path in missing)
        fail("run from the Swiftacular repository root; missing: " + rendered)


def validate_profile(profile):
    """Validate a complete or partial sharding profile.

    The entry point can later supply additional Swift-version-specific values;
    this reusable function deliberately accepts any non-empty set of explicit
    settings and applies only those settings.  That makes partial profiles
    safe to use when a node is missing only some values.
    """
    if not isinstance(profile, dict) or not profile:
        fail("sharding profile must be a non-empty dictionary")

    normalized = {}
    for name, value in profile.items():
        if not isinstance(name, str) or not re.fullmatch(r"[A-Za-z0-9_]+", name):
            fail("invalid sharding setting name: " + repr(name))
        if value is None or isinstance(value, (dict, list, tuple)):
            fail("invalid value for sharding setting " + repr(name))
        normalized[name] = str(value)
    validate_profile_values(normalized)
    return normalized


def validate_profile_values(profile):
    """Reject profiles that violate Swift's sharder invariants."""
    numeric = (
        "shard_container_threshold", "shrink_threshold", "rows_per_shard",
        "minimum_shard_size", "shard_scanner_batch_size", "cleave_batch_size",
    )
    parsed = {}
    for name in numeric:
        if name in profile:
            try:
                parsed[name] = int(profile[name])
            except (TypeError, ValueError):
                fail(name + " must be an integer")
            if parsed[name] < 1:
                fail(name + " must be positive")
    if "shard_container_threshold" in parsed:
        if parsed["shard_container_threshold"] < 2:
            fail("shard_container_threshold must be at least 2")
        if parsed["shard_container_threshold"] > 1000000000:
            fail("shard_container_threshold must be <= 1000000000")
        if "rows_per_shard" in parsed:
            if parsed["rows_per_shard"] > parsed["shard_container_threshold"]:
                fail("rows_per_shard must be <= shard_container_threshold")
    if "shrink_threshold" in parsed and "minimum_shard_size" in parsed:
        if parsed["shrink_threshold"] > parsed["minimum_shard_size"]:
            fail("shrink_threshold must be <= minimum_shard_size")
    if "shrink_threshold" in parsed and parsed["shrink_threshold"] > 1000000000:
        fail("shrink_threshold must be <= 1000000000")
    if "minimum_shard_size" in parsed and parsed["minimum_shard_size"] > 1000000000:
        fail("minimum_shard_size must be <= 1000000000")
    if "rows_per_shard" in parsed and parsed["rows_per_shard"] > 1000000000:
        fail("rows_per_shard must be <= 1000000000")
    if "auto_shard" in profile and profile["auto_shard"].lower() not in {"true", "false"}:
        fail("auto_shard must be true or false")


# ---------------------------------------------------------------------------
# Profile construction
# ---------------------------------------------------------------------------


def make_settings(threshold):
    if threshold < 2:
        fail("threshold must be at least 2")

    return {
        "auto_shard": "true",
        "shard_container_threshold": str(threshold),
    }


def make_full_profile(threshold):
    """Build the complete small-workload profile from one threshold."""
    if threshold < 2:
        fail("threshold must be at least 2")
    return {
        "auto_shard": "true",
        "shard_container_threshold": str(threshold),
        "rows_per_shard": str(max(1, threshold // 2)),
        "minimum_shard_size": str(max(1, threshold // 10)),
        "shard_scanner_batch_size": "10",
        "cleave_batch_size": "2",
    }


# ---------------------------------------------------------------------------
# Live profile observation
# ---------------------------------------------------------------------------


def inspect_live_profile(setting_names=None, verbose=True):
    """Read and compare the selected profile settings on every storage node.

    Returns the common profile dictionary when every node/configuration agrees.
    Raises a clear error containing two differing nodes when inconsistency is
    found. This function never edits files or restarts services.
    """
    names = tuple(setting_names or (
        "auto_shard",
        "shard_container_threshold",
        "rows_per_shard",
        "minimum_shard_size",
        "shard_scanner_batch_size",
        "cleave_batch_size",
        "shrink_threshold",
    ))
    for name in names:
        if not re.fullmatch(r"[A-Za-z0-9_]+", name):
            fail("invalid inspection setting name: " + repr(name))

    paths = " ".join(json.dumps(path) for path in LIVE_CONFIG_PATHS)
    extraction = "; ".join(
        "printf '%s=' " + json.dumps(name)
        + "; grep -E '^[[:space:]]*" + name
        + "[[:space:]]*=' \"$path\" | head -n 1 | sed -E 's/^[[:space:]]*[^=]+[[:space:]]*=[[:space:]]*//' | tr -d '\\n'; printf ';'"
        for name in names
    )
    command = (
        "set -e; for path in " + paths + "; do "
        "printf 'CONFIG_BEGIN=%s;' \"$path\"; " + extraction + "; "
        "printf 'CONFIG_END;' ; "
        "done"
    )
    completed = subprocess.run(
        [
            "ansible", "storage", "-i", "hosts", "--become",
            "--one-line",
            "--module-name", "ansible.builtin.shell", "--args",
            json.dumps({"cmd": command}),
        ],
        check=True,
        capture_output=True,
        text=True,
    )

    node_profiles = defaultdict(dict)
    current_node = None
    current_config = None
    for line in completed.stdout.splitlines():
        match = re.match(r"^([^ |]+) \| (?:SUCCESS|CHANGED) \| .*? \| (.*)$", line)
        if match:
            current_node = match.group(1)
            payload = match.group(2).replace('\\n', '\n').replace('\\"', '"')
            for config_match in re.finditer(
                r"CONFIG_BEGIN=([^;]+);(.*?)CONFIG_END;", payload
            ):
                current_config = config_match.group(1)
                for item in config_match.group(2).split(";"):
                    if "=" not in item:
                        continue
                    name, value = item.split("=", 1)
                    node_profiles[current_node][current_config, name] = value

    if not node_profiles:
        fail("could not parse live profile data from Ansible output")

    normalized = {
        node: tuple(sorted(values.items()))
        for node, values in node_profiles.items()
    }
    groups = defaultdict(list)
    for node, profile in normalized.items():
        groups[profile].append(node)
    if len(groups) != 1:
        profiles = list(groups.items())
        first_nodes = profiles[0][1]
        second_nodes = profiles[1][1]
        fail(
            "inconsistent live sharding profiles between "
            + first_nodes[0] + " and " + second_nodes[0]
        )

    common = {}
    for (config_path, name), value in next(iter(normalized.values())):
        common.setdefault(name, {})[config_path] = value
    if verbose:
        print("All profiles configured are identical:")
        print(json.dumps(common, indent=2, sort_keys=True))
    return common


# ---------------------------------------------------------------------------
# Probe environment synchronization
# ---------------------------------------------------------------------------


def update_probe_env_file(path=None):
    """Refresh profile variables in an existing generated probe environment."""
    env_path = Path(path or "probe/probe.env")
    if not env_path.is_file():
        return False

    observed = inspect_live_profile(verbose=False)
    values = {}
    for setting, env_name in ENV_PROFILE_NAMES.items():
        by_path = observed.get(setting, {})
        unique = set(by_path.values())
        if len(unique) != 1:
            fail("live profile is inconsistent for " + setting)
        values[env_name] = unique.pop()

    original = env_path.read_text(encoding="utf-8")
    lines = original.splitlines()
    seen = set()
    updated = []
    for line in lines:
        name = line.split("=", 1)[0] if "=" in line else ""
        if name in values:
            updated.append(name + "=" + values[name])
            seen.add(name)
        else:
            updated.append(line)
    for name, value in values.items():
        if name not in seen:
            updated.append(name + "=" + value)
    rendered = "\n".join(updated) + "\n"
    if rendered != original:
        env_path.write_text(rendered, encoding="utf-8")
        print("Updated probe environment profile:", env_path)
    return True


# ---------------------------------------------------------------------------
# Persistent template updates
# ---------------------------------------------------------------------------


def replace_template_settings(path, settings, remove_derived=True):
    # Replaces the setting in the node to the new settings
    original_mode = path.stat().st_mode
    original = path.read_text(encoding="utf-8")
    updated = original

    for name, value in settings.items():
        pattern = re.compile(r"(?m)^" + re.escape(name) + r"\s*=.*$")
        updated, count = pattern.subn(name + " = " + value, updated)
        if count > 1:
            fail(
                "expected at most one " + repr(name) + " setting in "
                + str(path) + ", found " + str(count)
            )
        if count == 0:
            section = re.search(r"(?m)^\[container-sharder\]\s*$", updated)
            if not section:
                fail("missing [container-sharder] section in " + str(path))
            insertion = section.end()
            updated = updated[:insertion] + "\n" + name + " = " + value + updated[insertion:]

    if remove_derived:
        for name in DERIVED_SETTINGS:
            pattern = re.compile(r"(?m)^" + re.escape(name) + r"\s*=.*\n?")
            updated = pattern.sub("", updated)

    if updated == original:
        return False

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
    return True


# ---------------------------------------------------------------------------
# Live storage-node deployment and verification
# ---------------------------------------------------------------------------


def run_ansible(module, arguments):
    """Run one quiet Ansible operation and expose output only on failure."""
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
    try:
        subprocess.run(command, check=True, capture_output=True, text=True)
    except subprocess.CalledProcessError as error:
        if error.stdout:
            print(error.stdout, file=sys.stderr, end="")
        if error.stderr:
            print(error.stderr, file=sys.stderr, end="")
        raise


def deploy_live_settings(settings, remove_derived=True):
    """Apply the complete requested profile in one Ansible shell call."""
    payload = {
        "paths": list(LIVE_CONFIG_PATHS),
        "settings": settings,
        "remove_derived": remove_derived,
        "derived": DERIVED_SETTINGS,
    }
    script = (
        "import json, pathlib, re\n"
        "payload = json.loads(" + repr(json.dumps(payload)) + ")\n"
        "for filename in payload['paths']:\n"
        "    path = pathlib.Path(filename)\n"
        "    original = path.read_text(encoding='utf-8')\n"
        "    updated = original\n"
        "    names = list(payload['settings'])\n"
        "    if payload['remove_derived']:\n"
        "        names.extend(payload['derived'])\n"
        "    for name in dict.fromkeys(names):\n"
        "        updated = re.sub(r'(?m)^' + re.escape(name) + r'\\s*=.*\\n?', '', updated)\n"
        "    section = re.search(r'(?m)^\\[container-sharder\\]\\s*$', updated)\n"
        "    if not section:\n"
        "        raise RuntimeError('missing [container-sharder] in ' + filename)\n"
        "    insertion = section.end()\n"
        "    block = ''.join('\\n' + name + ' = ' + str(value) for name, value in payload['settings'].items())\n"
        "    updated = updated[:insertion] + block + updated[insertion:]\n"
        "    path.write_text(updated, encoding='utf-8')\n"
    )
    encoded = __import__('base64').b64encode(script.encode()).decode()
    run_ansible(
        "ansible.builtin.shell",
        {
            "cmd": "echo " + encoded + " | base64 -d | python3",
            "executable": "/bin/bash",
        },
    )


def restart_sharders(restart_all=False):
    if restart_all:
        print("SHARDING: profile written; restarting all Swift services", flush=True)
    else:
        print("SHARDING: profile written; restarting container sharder services", flush=True)
    command = (
        "swift-init all restart"
        if restart_all
        else "swift-init container-sharder stop || true\n"
        "swift-init container-sharder.container-replication start"
    )
    run_ansible(
        "ansible.builtin.shell",
        {
            "cmd": command,
            "executable": "/bin/bash",
        },
    )


def verify_live_settings(settings):
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


# ---------------------------------------------------------------------------
# Complete profile application workflow
# ---------------------------------------------------------------------------


def set_sharding_profile(profile, restart_all=False, remove_derived=False):
    """Apply a complete or partial profile to templates and every storage node.

    Only settings present in *profile* are changed. Existing matching values
    are left untouched, while missing or divergent values are repaired. The
    caller is responsible for deciding which services consume the selected
    settings; the current implementation restarts the container sharders,
    matching the threshold workflow.
    """
    profile = validate_profile(profile)
    root = Path.cwd()
    require_repository(root)

    profile_summary = ", ".join(
        name + "=" + value for name, value in profile.items()
    )
    print(
        "SHARDING: changing and setting a new profile: " + profile_summary,
        flush=True,
    )
    template_names = ", ".join(path.name for path in TEMPLATE_PATHS)
    print(
        "SHARDING: updating templates and live storage configs: "
        + template_names,
        flush=True,
    )
    for relative_path in TEMPLATE_PATHS:
        replace_template_settings(
            root / relative_path,
            profile,
            remove_derived=remove_derived,
        )

    deploy_live_settings(profile, remove_derived=remove_derived)
    restart_sharders(restart_all=restart_all)
    print("SHARDING: verifying the profile is applied on every storage node", flush=True)
    verify_live_settings(profile)
    update_probe_env_file()
    print("SHARDING: profile applied and verified successfully", flush=True)
    return profile


# ---------------------------------------------------------------------------
# Public threshold operations
# ---------------------------------------------------------------------------


def set_sharding_threshold(threshold, restart_all=False):
    """Change the threshold and its dependent shard-sizing settings."""
    # Keep dependent shard sizing valid when lowering a threshold. Swift
    # rejects a profile whose existing rows_per_shard is >= the new threshold.
    profile = make_settings(threshold)
    profile.update({
        "rows_per_shard": str(max(1, threshold // 2)),
        "minimum_shard_size": str(max(1, threshold // 10)),
    })
    return set_sharding_profile(
        profile,
        restart_all=restart_all,
        remove_derived=False,
    )


def configure_sharding(
    shard_container_threshold,
    shrink_container_threshold,
    restart_all,
):
    """Build and apply the standard profile from both public thresholds."""
    if not isinstance(restart_all, bool):
        fail("restart_all must be a boolean")
    if not 2 <= shard_container_threshold <= 1000000000:
        fail("shard_container_threshold must be between 2 and 1000000000")
    if not 0 <= shrink_container_threshold <= 100:
        fail("shrink_container_threshold must be between 0 and 100")

    profile = make_full_profile(shard_container_threshold)
    # Swift validates shrink_threshold <= minimum_shard_size. Keep the
    # threshold-derived profile valid even for very small test thresholds.
    profile["minimum_shard_size"] = str(
        max(int(profile["minimum_shard_size"]), shrink_container_threshold)
    )
    profile["shrink_threshold"] = str(shrink_container_threshold)
    return set_sharding_profile(
        profile,
        restart_all=restart_all,
        remove_derived=False,
    )


# ---------------------------------------------------------------------------
# Command-line interface
# ---------------------------------------------------------------------------


def parse_args():
    """Parse the threshold accepted by the command-line entry point."""
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


def main():
    args = parse_args()

    root = Path.cwd()
    require_repository(root)
    settings = make_full_profile(args.threshold)

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
    try:
        set_sharding_threshold(args.threshold, restart_all=False)
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

