```
  _________       .__  _____  __                      .__
 /   _____/_  _  _|__|/ ____\/  |______    ____  __ __|  | _____ _______
 \_____  \\ \/ \/ /  \   __\\   __\__  \ _/ ___\|  |  \  | \__  \\_  __ \
 /        \\     /|  ||  |   |  |  / __ \\  \___|  |  /  |__/ __ \|  | \/
/_______  / \/\_/ |__||__|   |__| (____  /\___  >____/|____(____  /__|
        \/                             \/     \/                \/
```

# OpenStack Swift and Ansible

This repository will create a virtualized OpenStack Swift cluster using Vagrant, libvirt, Ansible.

#### Table of Contents

- [OpenStack Swift and Ansible](#openstack-swift-and-ansible)
      - [Table of Contents](#table-of-contents)
  - [tl;dr](#tldr)
  - [Supported Operating Systems and OpenStack Releases](#supported-operating-systems-and-openstack-releases)
    - [Fedora 40](#hosting-on-fedora-40)
    - [Ubuntu 22.04](#hosting-on-ubuntu-2204)
  - [Features](#features)
  - [Requirements](#hardware-requirements)
  - [Virtual machines created](#virtual-machines-created)
  - [Jenkins CI](#jenkins-ci)
  - [Networking setup](#networking-setup)
  - [Self-signed certificates](#self-signed-certificates)
  - [Using the swift command line client](#using-the-swift-command-line-client)
  - [Starting over](#starting-over)
  - [Modules](#modules)
  - [Issues](#issues)


## tl;dr

*Note this will start seven virtual machines on your computer.*

```bash
# Clone swiftaucular repo
$ cd swiftacular

# Install prerequisites on the host (requires sudo)
$ ./1_install_prereqs.sh

# Prepare vagrant boxes with precompiled bluestore to be used as a storage nodes
$ ./vagrant_box.sh --ceph

# Provision VMs
$ ./2_provision_VMs.sh

# Deploy Swift and monitoring dashboards
$ ./3_deploy_swift_with_monitoring.sh
```

## Supported Operating Systems and OpenStack Releases

### Hosting on Fedora 40
| VM              | Swift Version           | Status    |
|-----------------|-------------------------|-----------|
| CentOS Stream 9 | OpenStack stable/2025.1 | Supported |
| Ubuntu 22.04    | OpenStack stable/2025.1 | WIP       |

### Hosting on Ubuntu 22.04
| VM              | Swift Version           | Status    |
|-----------------|-------------------------|-----------|
| CentOS Stream 9 | OpenStack stable/2025.1 | Supported |
| Ubuntu 22.04    | OpenStack stable/2025.1 | WIP       |


By default, vagrant will use CentOS Stream 9:
```bash
$ vagrant up
```

To use Ubuntu 22.04 instead:

```bash
$ VM_BOX=ubuntu vagrant up
```

Note: Vagrant box for 24.04 by Canonical is not supported anymore.
https://portal.cloud.hashicorp.com/vagrant/discover?providers=libvirt&query=24.04


## Features

* Run OpenStack Swift in vms on your local computer, but with multiple servers
* Replication network is used, which means this could be a basis for a geo-replication system
* SSL - Keystone is configured to use SSL and the Swift Proxy is proxied by an SSL server
* Sparse files to back Swift disks
* Tests for uploading files into Swift
* Use of [gauntlt](http://gauntlt.org/) attacks to verify installation


## Hardware Requirements

Minimal Host Requirements:
CPU: 6 vCPUs
RAM: 24 GB
Disk: ~120 GB

Recommended Host Requirements:
CPU: 16+ vCPUs
RAM: 64+ GB
Disk: 500 GB+ SSD (preferably NVMe)

## Virtual machines created

Seven Vagrant-based virtual machines are used for this playbook:

* __package_cache__ - One apt-cacher-ng server so that you don't have to download packages from the Internet over and over again, only once
* __authentication__ - One Keystone server for authentication
* __lbssl__ - One SSL termination server that will be used to proxy connections to the Swift Proxy server
* __swift-proxy__ - One Swift proxy server
* __swift-storage__ - Three Swift storage nodes


Also, running

```bash
vagrant_box.sh --ceph
```

creates a VM with 20 GB of ram for bluestore compilation. The VM is destroyed later.

## Jenkins CI

Jenkins is deployed as a separate VM (`jenkins-01`) via an Ansible role with full
Configuration as Code (JCasC). Each developer runs their own isolated Jenkins instance —
no shared university server.

### Prerequisites

Generate a dedicated SSH key pair for Jenkins to authenticate with GerritHub:

```bash
ssh-keygen -t ed25519 -f gerrit_jenkins_key -C "jenkins@swiftacular"
```

Register `gerrit_jenkins_key.pub` in your GerritHub account:
[https://review.gerrithub.io/settings/#SSHKeys](https://review.gerrithub.io/settings/#SSHKeys)

### Setup

**1. Create your credentials vault**
```bash
cp roles/jenkins/vars/vault.yml.example roles/jenkins/vars/vault.yml
```

Edit `roles/jenkins/vars/vault.yml` and fill in your values:
```yaml
vault_jenkins_admin_password: yourpassword
vault_gerrit_ssh_username: your_gerrithub_username
vault_gerrit_ssh_private_key: |
  -----BEGIN OPENSSH PRIVATE KEY-----
  <contents of gerrit_jenkins_key>
  -----END OPENSSH PRIVATE KEY-----
```

Encrypt it:
```bash
ansible-vault encrypt roles/jenkins/vars/vault.yml
```

**2. Boot the Jenkins VM**
```bash
LIBVIRT_DEFAULT_URI=qemu:///system vagrant up jenkins-01
```

**3. Deploy Jenkins**
```bash
ansible-playbook deploy_jenkins.yml --ask-vault-pass
```

**4. Open Jenkins**

URL: `http://192.168.100.170:8080` — login with the admin password you set in the vault.

> `vault.yml` is git-ignored and never committed. Each developer holds their own encrypted copy.

### CI Flow

Once deployed, Jenkins listens to GerritHub automatically. Every push to `refs/for/master` triggers the following:

```
git push origin HEAD:refs/for/master
        ↓
GerritHub creates a Change Request
        ↓
gerrit-trigger detects patchset-created event via SSH stream
        ↓
Jenkins checks: is the uploader me? → if not, marks NOT_BUILT and stops
        ↓
Runs swiftacular-workload-tests pipeline
        ↓
Posts Verified +1 (pass) or Verified -1 (fail) back to the change
```

To submit a change request:
```bash
git push origin HEAD:refs/for/master
```

View the result on your change page:
`https://review.gerrithub.io/c/davidsaOpenu/swiftacular/+/<change-number>`

Under **Labels** you will see `Verified +1` or `Verified -1` posted by Jenkins, and a comment with a direct link to the build log.

## Networking setup

Each vm will have four networks (technically five including the Vagrant network). In a real production system every server would not need to be attached to every network, and in fact you would want to avoid that. In this case, they are all attached to every network.

* __eth0__ - Used by Vagrant
* __eth1__ - 192.168.100.0/24 - The "public" network that users would connect to
* __eth2__ - 10.0.10.0/24 - This is the network between the SSL terminator and the Swift Proxy
* __eth3__ - 10.0.20.0/24 - The local Swift internal network
* __eth4__ - 10.0.30.0/24 - The replication network which is a feature of OpenStack Swift starting with the Havana release

## Self-signed certificates

Because this playbook configures self-signed SSL certificates and by default the swift client will complain about that fact, either the <code>--insecure</code> option needs to be used or alternatively the <code>SWIFTCLIENT_INSECURE</code> environment variable can be set to true.

## Using the swift command line client

You can install the swift client anywhere that you have access to the SSL termination point and Keystone. So you could put it on your local laptop as well, probably with:

```bash
# Fedora 42
sudo dnf install python3-swiftclient

# Ubuntu 22.04
sudo apt-get install python3-swiftclient

# PyPI:
# Mixing installations from system package managers like dnf or apt with Python's pip
# on virtual machines is strongly discouraged. This practice can lead to severe version
# conflicts, broken dependencies, and unpredictable system behavior, making
# troubleshooting extremely difficult. A virtual environment (virtualenv) should be used
# when proceeding this way.
python -m venv venv
. ./venv/bin/activate
pip install python-swiftclient
```

However, I usually login to the package_cache server and use swift from there.

```bash
$ vagrant ssh swift-package-cache-01
vagrant@swift-package-cache-01:~$ . /vagrant/testrc
vagrant@swift-package-cache-01:~$ swift list
vagrant@swift-package-cache-01:~$ echo "swift is cool" > swift.txt
vagrant@swift-package-cache-01:~$ swift upload swifty swift.txt
swift.txt
vagrant@swift-package-cache-01:~$ swift list
swifty
vagrant@swift-package-cache-01:~$ swift list swifty
swift.txt
```

## Starting over

If you want to redo the installation there are a few ways.

To restart completely:

```bash
$ ./cleanup.sh
$ ./bootstrap_swift_with_monitoring.sh
```

There is a script to destroy and rebuild everything but the package cache:

```bash
$ ./bin/redo
$ ansible -m ping all # just to check if networking is up
$ ansible-playbook deploy_swift_cluster.yml
```

To remove and redo only the rings and fake/sparse disks without destroying any virtual machines:

```bash
$ ansible-playbook playbooks/remove_rings.yml
$ ansible-playbook deploy_swift_cluster.yml
```

To remove the keystone database and redo the endpoints, users, regions, etc:

```bash
$ ansible-playbook ./playbook/remove_keystone.yml
$ ansible-playbook deploy_swift_cluster.yml
```

To change debug level output of Vagrant

```bash
export VAGRANT_LOG=debug
```

## Modules

- library/swift-ansible-modules/keystone_user
