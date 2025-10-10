#!/usr/bin/env bash
set -e

SCRIPT_PATH="scripts/compile_and_test_bluestore.sh"

customize_box() {
    local box=$1
    local ceph_box="${box}-ceph"

    vagrant box list | grep -q "$ceph_box" && echo "$ceph_box exists, skipping" && return

    local tmp=$(mktemp -d)
    local orig_dir="$PWD"
    cd "$tmp"

    # Create Vagrantfile in isolated temp directory (won't overwrite user's Vagrantfile)
    cat > Vagrantfile.ceph <<EOF
Vagrant.configure("2") do |config|
  config.vm.box = "$box"
  config.vm.boot_timeout = 600
  config.ssh.insert_key = false

  config.vm.provider :libvirt do |v|
    v.memory = 20480
    v.cpus = \`nproc\`.to_i
    v.qemu_use_session = false
  end

  config.vm.provision "shell", path: "$orig_dir/$SCRIPT_PATH"
end
EOF

    echo "Customizing $box..."
    VAGRANT_VAGRANTFILE=Vagrantfile.ceph vagrant up --provider libvirt
    VAGRANT_VAGRANTFILE=Vagrantfile.ceph vagrant package --output box.box
    VAGRANT_VAGRANTFILE=Vagrantfile.ceph vagrant box add "$ceph_box" box.box --provider libvirt
    VAGRANT_VAGRANTFILE=Vagrantfile.ceph vagrant destroy -f
    cd "$orig_dir"
    rm -rf "$tmp"
    echo "Created: $ceph_box"
}

# Add base boxes
vagrant box list | grep -q 'eurolinux-vagrant/centos-stream-9' || \
    vagrant box add eurolinux-vagrant/centos-stream-9 --provider libvirt
vagrant box list | grep -q 'generic/ubuntu2204' || \
    vagrant box add generic/ubuntu2204 --provider libvirt

# Customize if --ceph flag
if [[ "$1" == "--ceph" ]]; then
    [ ! -f "$SCRIPT_PATH" ] && echo "Error: $SCRIPT_PATH not found" && exit 1
    customize_box "eurolinux-vagrant/centos-stream-9"
    customize_box "generic/ubuntu2204"
    echo "Done! Use: eurolinux-vagrant/centos-stream-9-ceph or generic/ubuntu2204-ceph"
fi

# Status display
echo -e "\nLibvirt: $(virsh uri)"
virsh pool-list --all
virsh -c qemu:///session list --all 2>/dev/null || echo "No user session VMs"
virsh -c qemu:///system list --all 2>/dev/null || echo "No system session VMs"
vagrant box list
