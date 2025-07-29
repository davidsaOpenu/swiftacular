#!/bin/bash

GREEN='\033[32m'
YELLOW='\033[1;33m'
BLUE='\033[34m'
NC='\033[0m' # No Color

get_vm_count() {
    local uri=$1
    local count=$(virsh -c "$uri" list --all 2>/dev/null | grep -c "running\|shut off" 2>/dev/null || echo "0")
    # Ensure it's a valid number
    if [[ "$count" =~ ^[0-9]+$ ]]; then
        echo "$count"
    else
        echo "0"
    fi
}


# Check if the 'eurolinux-vagrant/centos-stream-9' is already added
if ! vagrant box list | grep -q 'eurolinux-vagrant/centos-stream-9'; then
    echo "Adding the 'eurolinux-vagrant/centos-stream-9' box..."
    vagrant box add eurolinux-vagrant/centos-stream-9 --provider libvirt
else
    echo "'eurolinux-vagrant/centos-stream-9' box is already added."
fi

# Check if the Ubuntu box is already added
if ! vagrant box list | grep -q 'generic/ubuntu2204'; then
    echo "Adding the 'generic/ubuntu2204' box..."
    vagrant box add generic/ubuntu2204 --provider libvirt
else
    echo "'generic/ubuntu2204' box is already added."
fi

# `qemu_use_session = true` in Vagrantfile implies user libvirt session is used
echo -e "${GREEN}Current libvirt session: $(virsh uri)${NC}"
echo -e "${GREEN}List all pools from current session${NC}"
virsh pool-list --all

echo -e "${GREEN}List vol details from available pools${NC}"
# Get first available pool name instead of assuming 'default'
pool_name=$(virsh pool-list --all --name | head -n1)

if [ -n "$pool_name" ]; then
    echo -e "${GREEN}Using pool: $pool_name${NC}"
    virsh vol-list --pool "$pool_name" --details 2>/dev/null || \
    echo -e "${YELLOW}No volumes found in pool '$pool_name' or pool not accessible${NC}"
else
    echo -e "${YELLOW}No storage pools found in current session${NC}"
fi

echo
echo -e "${BLUE}============================================${NC}"
echo -e "${BLUE}            VM Status Summary               ${NC}"
echo -e "${BLUE}============================================${NC}"

echo -e "${GREEN} User Session VMs (qemu:///session):${NC}"
user_vms=$(virsh -c qemu:///session list --all 2>/dev/null)
if echo "$user_vms" | grep -q "Id.*Name.*State"; then
    echo "$user_vms"
else
    echo -e "${YELLOW}  No VMs found in user session or session not accessible${NC}"
fi

echo
echo -e "${GREEN} System Session VMs (qemu:///system):${NC}"
system_vms=$(virsh -c qemu:///system list --all 2>/dev/null)
if echo "$system_vms" | grep -q "Id.*Name.*State"; then
    echo "$system_vms"
else
    echo -e "${YELLOW}  No VMs found in system session or session not accessible${NC}"
fi

echo
echo -e "${BLUE}============================================${NC}"

# Summary count
user_count=$(get_vm_count "qemu:///session")
system_count=$(get_vm_count "qemu:///system")
total_count=$((user_count + system_count))

echo -e "${GREEN} Summary:${NC}"
echo -e "  User session VMs: ${YELLOW}$user_count${NC}"
echo -e "  System session VMs: ${YELLOW}$system_count${NC}"
echo -e "  Total VMs: ${YELLOW}$total_count${NC}"
