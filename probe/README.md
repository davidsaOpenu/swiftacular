# Swiftacular probe

This folder contains the final Workloader/Observer probe and its end-to-end
container-sharding test. Copy it into the root of a working Swiftacular
checkout.

## 1. Folder structure

Expected location in Swiftacular:

```text
<swiftacular-root>/probe
```

Contents:

```text
probe/
├── README.md
├── __init__.py
├── generate_probe_env.sh
├── probe.env              # generated locally; not committed
├── probe.env.template
├── run_probe.sh
├── set_sharding_threshold.py
├── common/
│   ├── __init__.py
│   ├── observer.py
│   └── workloader.py
└── tests/
    ├── __init__.py
    └── test_final_sharding_workload.py
```

## 2. File descriptions

### `generate_probe_env.sh`

Generates `probe.env` dynamically from the active Swiftacular topology. It
reads the Ansible inventory, cross-checks its runner and proxy against Vagrant,
requires both VMs to be running, finds the active container ring and test
credential file, verifies that Swift can load the ring, and checks that the
credential file defines the required OpenStack variables without printing
their values. Values that identify the active runner, proxy, Swift
configuration directory, and credential file are discovered rather than
assumed.

### `probe.env.template`

Documents the complete default Swiftacular environment previously embedded in
the original generator. The dynamic generator loads this template for standard
storage-node names, addresses, service ports, the admin credential path, and
the device directory, then replaces topology-dependent runner and proxy values
with the values it discovers and validates. The template is committed;
generated `probe.env` remains local and must not be committed.

### `probe.env`

Defines the runner, proxy, and storage nodes; their addresses and Ansible
inventory groups; the Swift service ports, configuration directory, and device
directory; and the credential files used by the probe tools. The generator
discovers and validates topology-dependent values, while standard storage and
service values come from `probe.env.template`.

### `set_sharding_threshold.py`

Sets any requested sharding threshold. It updates both persistent container
templates and both live container configurations, removes explicit shard-size
settings so Swift derives them from the threshold, restarts the sharders, and
verifies the result on every storage node.

### `run_probe.sh`

Copies the current container ring from the configured proxy to the configured
probe runner, synchronizes the checkout, loads the Swift test credentials, and
runs the selected `unittest` module with preserved environment variables and
root access. With no argument, it runs the final test.

### `common/observer.py`

Read-only observation code. It reads account/container information through the
proxy and container-sharding information directly from container-server
primaries.

### `common/workloader.py`

Creates and removes test containers, enables or disables container sharding,
uploads deterministic per-object content through Swift, retrieves objects, and
cleans up only the resources it owns.

### `tests/test_final_sharding_workload.py`

The final end-to-end test creates three uniquely named containers and exercises
three workload shapes:

1. **2,001 real objects.** The objects are uploaded through Swift. The test
   waits for the 2,000-row threshold to trigger sharding, waits for the
   container to become fully sharded with all 2,001 objects visible, and reads
   sample objects back with exact payload verification.
2. **4,500 real objects.** The test waits for the complete sharding transition,
   confirms that cleaving is finished and all 4,500 objects are visible,
   reports the shard distribution, and reads sample objects back.
3. **7,000 real objects.** The largest workload follows the same complete
   sharding, exact-count, and read-back verification path.

While running, the test reports object counts, root sharding state, shard-range
states, cleaving progress, and per-shard distribution. A container passes only
when its root is `sharded`, cleaving is complete, and its visible object count
matches the number uploaded. It also checks that the shard count is within the
range implied by the 2,000-row threshold and Swift's derived 1,000-row shard
target, and that the sum of all shard object counts equals the container's
visible total. Each shard must contain between the derived 200-row minimum and
the configured 2,000-row threshold. The test then deletes the three containers
individually and verifies cleanup. A final safety cleanup also runs if the test
exits early.

### `__init__.py` files

Mark `probe`, `probe.common`, and `probe.tests` as Python packages.

## 3. Add and run the probe

Run these commands from the Swiftacular root.

Copy the probe folder into the checkout:

```bash
cp -a /path/to/saved/probe ./probe
chmod +x probe/generate_probe_env.sh probe/run_probe.sh
```

Apply the 2,000-row sharding profile with the threshold script:

```bash
python3 probe/set_sharding_threshold.py 2000
```

The profile uses:

```ini
auto_shard = true
shard_container_threshold = 2000
```

The script changes both Swiftacular template files and the corresponding live
configuration on every storage node. It removes explicit `rows_per_shard` and
`minimum_shard_size` settings so Swift always calculates shard sizing from the
selected threshold. The script restarts the container sharders and verifies the
live values. Because it also updates the templates, the selected threshold
remains in effect after a future Swiftacular configuration deployment.

This operation is not transactional: templates are changed before live nodes.
If live deployment fails, inspect and reconcile both templates and all storage
nodes before continuing. The script prints this warning before making changes.

Generate the probe environment:

```bash
./probe/generate_probe_env.sh
```

Run the final test:

```bash
./probe/run_probe.sh
```

The explicit form is:

```bash
./probe/run_probe.sh probe.tests.test_final_sharding_workload
```

## 4. Short test tutorial

### 1. Check that Swift is running

```bash
vagrant ssh swift-proxy-01 -c 'sudo swift-init proxy status'

ANSIBLE_CONFIG=ansible.cfg ansible -i hosts storage -m shell \
  -a 'sudo swift-init all status'
```

The proxy and storage services, including `container-sharder`, must report as
running.

### 2. Generate the environment

```bash
./probe/generate_probe_env.sh
```

The generator discovers and validates topology-dependent values. If storage
node names, addresses, ports, or device paths differ from the standard layout,
update `probe.env.template` before generating `probe.env`.

### 3. Run the test

```bash
./probe/run_probe.sh
```

The test may take several minutes because sharding is asynchronous. A successful
run finishes with:

```text
OK
```

## 5. Logs during a test

Swift writes its service output to the system journal in this Swiftacular
deployment; `/var/log/swift` may be empty. Open a second terminal in the
Swiftacular root before running the test.

Show recent account, container, and sharding activity on every storage node:

```bash
ANSIBLE_CONFIG=ansible.cfg ansible -i hosts storage -m shell \
  -a "sudo journalctl --since=-30min --no-pager | grep -E 'account-(server|replicator|auditor)|container-(server|replicator|sharder|updater)'"
```

Show only warnings and errors:

```bash
ANSIBLE_CONFIG=ansible.cfg ansible -i hosts storage -m shell \
  -a 'sudo journalctl --since=-30min --no-pager -p warning..alert'
```

Follow one storage node live while `run_probe.sh` is running:

```bash
vagrant ssh swift-storage-01 -c \
  "sudo journalctl -f -o short-iso | grep -E 'account-|container-'"
```

The most useful test messages are container-sharder state changes, cleaving and
shard-range progress, container-server response failures, and replication or
rsync failures. Memcache connection errors matter when they repeat during the
test; an isolated message during VM startup is normally transient. Ring
identity errors such as `Can't find itself ... in ring file` and repeated
`rsync failed` messages indicate a Swiftacular replication-network mismatch and
should not be ignored even if PUT and GET requests still succeed.

## 6. Swiftacular environment differences

The probe does not own the surrounding Swiftacular VM and service
configuration. Record and reproduce these external requirements when moving
the probe to another checkout or host.

### Replication-network rsync binding

Swift rings in the standard Vagrant topology use `10.0.30.x` as each device's
replication address. The rsync daemon must listen on that network. In this
topology `ens8` is the `10.0.20.x` internal network and `ens9` is the
`10.0.30.x` replication network, so
`roles/storage/templates/rsyncd.conf.j2` must contain:

```jinja2
address = {{ ansible_ens9.ipv4.address }}
```

Binding rsync to `ansible_ens8` leaves the replicators running but makes full
database transfers to ring replication addresses fail with rsync exit code 10
and `Connection refused`. After changing the template, redeploy it, restart
`rsyncd`, verify that port 873 listens on `10.0.30.x`, and confirm that
`rsync rsync://10.0.30.201/` lists the account, container, and object modules.
For a different topology, use the interface or explicit variable that owns the
ring's replication address instead of assuming the `ens9` name.

Deploy this template through a play that gathers Ansible facts. An ad-hoc
`ansible.builtin.template` call does not gather interface facts and will report
that `ansible_ens9` is undefined.

This deployment may start two container-replicator processes because both the
normal and replication container configurations are discovered by
`swift-init all`. The process using `container-replication.conf` is the
authoritative replication instance. Confirm that it attempts databases and
reports zero failures. The process using `container-server.conf` may report
`Can't find itself ... in ring file` and attempt zero databases; removing that
duplicate daemon configuration is a separate Swiftacular cleanup and is not a
probe requirement.

### Resource-constrained local development

The reference project builds a custom BlueStore box with 20 GB of guest RAM
and normally selects the `bs_fork` backend. A 15 GB host cannot build that box
locally. The development environment used for this probe run therefore used
the standard CentOS box for storage nodes and `SWIFT_BACKEND=""`, which selects
Swift's standard object backend. These are local environment accommodations,
not probe requirements, and should not silently replace the project defaults
on hosts capable of running the BlueStore configuration.

The container-sharding probe remains valid with the standard object backend
because sharding is implemented by container-server databases. A standard
backend run does not verify BlueStore integration.
