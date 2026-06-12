# Swiftacular — Kubernetes Deployment

Runs the full Swiftacular OpenStack Swift cluster in a local [kind](https://kind.sigs.k8s.io/) Kubernetes cluster. Three storage nodes, a Swift proxy, Keystone identity, MariaDB, an apt package cache, and Grafana with live PCP metrics.

---

## Prerequisites

| Tool | Minimum version | Install |
|------|----------------|---------|
| Docker | 24.x | [docs.docker.com](https://docs.docker.com/get-docker/) |
| kind | 0.23.x | `go install sigs.k8s.io/kind@latest` or [release binary](https://kind.sigs.k8s.io/docs/user/quick-start/#installation) |
| kubectl | 1.29+ | [kubernetes.io/docs](https://kubernetes.io/docs/tasks/tools/) |
| helm | 3.14+ | [helm.sh/docs](https://helm.sh/docs/intro/install/) |

### Platform notes

**Windows (WSL2)**  
All commands must run inside a WSL2 shell (Ubuntu 22.04+ recommended). Docker Desktop is not required — install Docker Engine directly inside WSL2. Ensure kind, kubectl, and helm are installed inside WSL2, not on the Windows host.

```bash
# Verify Docker is running inside WSL2
docker info
```

Line endings: `.gitattributes` pins LF for shell scripts, Dockerfiles, and
patch files. If you cloned before it existed and scripts fail with
`/usr/bin/env: 'bash\r': No such file or directory`, set
`git config core.autocrlf input` and re-checkout (or strip CRs with
`sed -i 's/\r$//'`).

**macOS**  
Use Homebrew: `brew install kind kubectl helm`. Docker Desktop or OrbStack works.

**Linux**  
Install Docker Engine, then kind/kubectl/helm via their official install scripts.

---

## Quick start

```bash
# Clone and enter the repo
git clone <repo-url>
cd swiftacular

# Full deploy: bootstrap cluster → build images → helm install → wait for ready
kube_deploy/scripts/deploy.sh
```

This single command:
1. Prints a system spec (kernel, CPU/memory/disk, proxy env, tool versions) for diagnosability
2. Creates a 4-node kind cluster (1 control-plane + 3 storage workers) with a local registry
3. Builds all Docker images (applying the shared Swift/Ceph patches — see below) and pushes them to the local registry
4. Pre-loads all images into kind (parallel pulls, one batched `kind load`) so no pod ever pulls over the network
5. Installs the Helm chart into the `swiftacular` namespace, with a background monitor printing pod states and stuck-pod logs every 30 s
6. Waits for the ring-builder Job, storage StatefulSet, and proxy Deployment to be ready
7. Runs the full smoke-test suite and prints access URLs and a per-phase timing summary

On any failure, deploy.sh dumps full cluster diagnostics (pod table, events, logs of every non-Running pod) before exiting — essential on CI where the cluster is torn down right after.

### Options

```bash
# Skip cluster creation if already running
kube_deploy/scripts/deploy.sh --skip-bootstrap

# Skip image builds if registry is already populated
kube_deploy/scripts/deploy.sh --skip-build

# Skip the smoke-test suite after deploy
kube_deploy/scripts/deploy.sh --skip-smoke

# Use a custom values file
kube_deploy/scripts/deploy.sh --values kube_deploy/charts/swiftacular/values.dev.yaml
```

### CI port offsets

When `JENKINS_HOME` or `CI` is set, host ports shift automatically so they
don't collide with Jenkins on 8080: proxy `18080`, Keystone `15000`,
Grafana `13000`. Override with `PROXY_HOST_PORT` / `KEYSTONE_HOST_PORT` /
`GRAFANA_HOST_PORT`.

---

## What gets deployed

| Component | Kind | Replicas | Access |
|-----------|------|----------|--------|
| `storage` | StatefulSet | 3 | internal only |
| `proxy` | Deployment | 1 | `http://localhost:8080` |
| `keystone` | Deployment | 1 | `http://localhost:5000/v3` |
| `mariadb` | StatefulSet | 1 | internal only |
| `package-cache` | Deployment | 1 | internal only |
| `grafana` | Deployment | 1 | `http://localhost:3000` |

Startup order is enforced by init containers and Job completion gates:  
`mariadb` → `keystone` → `ring-builder` → `storage (×3)` → `proxy` → `grafana`

---

## Swift & Ceph patches — shared with the VM/Ansible flow

Both deployment paths (Vagrant/Ansible and Kubernetes) consume patches and
workload tests from the **same repo-root directories** — nothing is
duplicated under `kube_deploy/`:

| Shared location | VM/Ansible consumer | Kubernetes consumer |
|-----------------|---------------------|---------------------|
| `swift_patches/` | `apply_patches.yml` | `Dockerfile.storage` (build time) |
| `ceph_patches/` | `update_ceph_bs_tools.yml` | `Dockerfile.bluestore` (build time) |
| `workload_tests/` | `setup_workload_test.yml` | `smoke-test.sh` section 6 |

**Swift patches** (`Dockerfile.storage`): applies `2_sharder.patch` with
`patch -p0` against the installed `swift/container` package, installs
`obj/bs_diskfile.py` + `obj/bs_server.py`, and registers the `bs_object`
paste `app_factory` entry point. Applied at image build, so a patch that
stops applying **fails the build loudly** instead of silently shipping
unpatched Swift.

**Ceph patches** (`Dockerfile.bluestore`): copies the five tool sources
into Ceph's `src/tools/` and appends the shared `ceph_patches/CMakeLists.txt`
— the exact mechanism of the Ansible flow. All five utilities ship in the
runtime image (`bs_util`, `objectstore_bench`, `test_kv`, `bs_ondisk`,
`bs_xattr`) together with the shared BlueStore pytest suites under
`/opt/workload_tests/`.

**Workload tests**: see the smoke-test section below — the same
`test_workload.py::test_tiny_workload` the instructor's flow runs.

---

## Accessing services

### Swift proxy

```bash
# Health check
curl http://localhost:8080/healthcheck

# List containers (requires Keystone auth — see smoke test section)
swift --os-auth-url http://localhost:5000/v3 \
  --os-username admin \
  --os-password devpassword \
  --os-project-name admin \
  --os-user-domain-name Default \
  --os-project-domain-name Default \
  --os-identity-api-version 3 \
  list
```

### Grafana

Open `http://localhost:3000` in a browser.  
Login: `admin` / `devgrafanapass` (or the value of `secrets.grafanaAdminPassword` in your values file).

Three dashboards are provisioned automatically:
- **Swift Storage** — per-node disk I/O, network, CPU, memory
- **Swift DB Info** — per-container object counts, sizes, and distribution (populated after objects are created)
- **Swift Proxy** — request rates and latencies (when proxy metrics are available)

Each dashboard has a `$host` variable to switch between `storage-0`, `storage-1`, and `storage-2`.

### Keystone

```bash
# Check API version
curl http://localhost:5000/v3

# Issue a token (Python openstack CLI)
export OS_AUTH_URL=http://localhost:5000/v3
export OS_USERNAME=admin
export OS_PASSWORD=devpassword
export OS_PROJECT_NAME=admin
export OS_USER_DOMAIN_NAME=Default
export OS_PROJECT_DOMAIN_NAME=Default
export OS_IDENTITY_API_VERSION=3
openstack token issue
```

---

## Smoke tests — the regression gate

`kube_deploy/scripts/smoke-test.sh` is the full regression gate. It runs
automatically at the end of `deploy.sh` (skip with `--skip-smoke`) or
standalone against a running cluster:

```bash
kube_deploy/scripts/smoke-test.sh
```

Six sections, all failures collected (the suite never aborts mid-run);
exit 0 = PASS, non-zero = FAIL, so CI needs no log parsing:

| Section | Tests |
|---------|-------|
| 1 Unit | U1 helm lint, U2 template dry-run, U3 image check, U4 PMDA syntax, U5 ansible-lint, U6 dashboard compilation |
| 2 Integration | I1 nodes Ready, I2 registry images, I3 pods Running, I4 rings published, I5 Keystone HTTP, I6 proxy healthcheck, I7 swiftdbinfo PMDA per pod |
| 3 End-to-end | Keystone auth → container → upload → list → download → SHA-256 verify → delete |
| 4 Stress | N parallel uploads + downloads with throughput figures and SHA-256 verification |
| 5 PCP | swiftdbinfo PMDA + Redis timeseries on every storage pod, swift-recon |
| 6 Workload | W1 shared `test_workload.py::test_tiny_workload` (pytest, run inside the proxy pod against `keystone-svc`), W2 all five BlueStore binaries present, W3 shared `test_bs_xattr.py` + `test_bs_ondisk.py` in the bluestore image |

The summary prints every test's PASS/FAIL/SKIP plus per-section durations.

Note: the Keystone test user is `achilles` with password `CHANGEME` —
hardcoded in the shared `workload_tests/test_workload.py`, which is why
`values.dev.yaml` must keep `keystoneTestUserPassword: CHANGEME`.

A minimal standalone Job also exists at `kube_deploy/jobs/swiftclient-smoke.yaml`
(container/upload/download/verify only) if you want a quick in-cluster check
without the full suite.

---

## Monitoring (Grafana + PCP)

Each storage pod runs a full PCP stack:
- `pmcd` — metric collection daemon with the `swiftdbinfo` PMDA
- `pmlogger` — archives metrics every 10 seconds
- `pmproxy --timeseries` — serves metrics to Grafana via Redis on port 44322

Grafana datasources are auto-provisioned pointing to each storage node's pmproxy. Metrics appear in Grafana within ~30 seconds of pod startup.

The `swiftdbinfo` PMDA scans `/srv/node` for Swift container SQLite databases and reports per-container object counts and sizes. It shows data only after Swift containers have been created.

---

## Configuration

All tunables live in `charts/swiftacular/values.yaml`. Override them in a values file:

```yaml
# values.dev.yaml
swift:
  hashPathSuffix: my-suffix
  hashPathPrefix: my-prefix

secrets:
  keystoneAdminPassword: devpassword
  grafanaAdminPassword: devgrafanapass
```

Key values:

| Key | Default | Description |
|-----|---------|-------------|
| `swift.replicas` | `2` | Swift replication factor |
| `swift.disksPerNode` | `2` | PVCs per storage pod |
| `swift.diskSizeGi` | `5` | Size of each PVC in GiB |
| `storage.storageClassName` | `local-path` | StorageClass for PVCs |
| `grafana.enabled` | `false` | Enable Grafana deployment |
| `secrets.keystoneAdminPassword` | `CHANGEME` | Keystone admin password |

---

## Teardown

```bash
# Delete the kind cluster and local registry (all data is lost)
kube_deploy/scripts/teardown-cluster.sh
```

To delete only the Helm release (keep the cluster):
```bash
helm uninstall swiftacular -n swiftacular
kubectl delete namespace swiftacular
```

---

## Troubleshooting

**Where to look first**  
`deploy.sh` output contains three built-in diagnostic layers:
- `[deploy-monitor HH:MM:SS]` blocks every 30 s during helm install — pod table plus events and last log lines of every stuck pod
- a full `CLUSTER DIAGNOSTICS` dump (pods, events, logs, previous logs, PVCs) printed automatically when the script fails, before CI teardown destroys the evidence
- a per-phase timing summary at the end of every run — a phase that took far longer than usual is usually the culprit

**Pods stuck in `Init`**  
The `wait-for-rings` init container blocks until the ring ConfigMap is populated by the ring-builder Job. Check if the Job completed:
```bash
kubectl get job ring-builder -n swiftacular
kubectl logs job/ring-builder -n swiftacular
```

**Keystone auth is slow / times out**  
MariaDB connection pool exhaustion under load. Check keystone logs:
```bash
kubectl logs deploy/keystone -n swiftacular | tail -30
```

**`pminfo swiftdbinfo` returns "Unknown metric name"**  
The storage image may be outdated. Rebuild with `--no-cache` and restart:
```bash
PUB_KEY=$(cat kube_deploy/ssh/ansible_user.pub)
docker build --no-cache --build-arg "ANSIBLE_PUBLIC_KEY=${PUB_KEY}" \
  -t swiftacular-storage:latest -f kube_deploy/dockerfiles/Dockerfile.storage .
docker tag swiftacular-storage:latest localhost:5001/swiftacular-storage:latest
docker push localhost:5001/swiftacular-storage:latest
kubectl rollout restart statefulset/storage -n swiftacular
```

**Grafana shows "no data"**  
Verify pmproxy is running on the storage pod and datasources are provisioned:
```bash
kubectl exec -n swiftacular storage-0 -- pgrep -a pmproxy
curl http://localhost:3000/api/datasources   # requires port-forward or NodePort
```

**ImagePullBackOff**  
The local registry must be reachable from the kind nodes. Re-run bootstrap to reconnect:
```bash
kube_deploy/scripts/bootstrap-cluster.sh
```
