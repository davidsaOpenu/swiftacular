#!/usr/bin/env bash
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "Please run this script as root or using sudo!"
  exit 1
fi

USERNAME="stack"

OS_ID=""
VERSION_ID=""

if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS_ID=${ID}
    VERSION_ID=${VERSION_ID:-}
elif [ -f /etc/lsb-release ]; then
    . /etc/lsb-release
    OS_ID=${DISTRIB_ID}
    VERSION_ID=${DISTRIB_RELEASE:-}
fi

if [ -z "$OS_ID" ]; then
    echo "Unsupported OS: Cannot determine distribution."
    exit 1
fi

# normalize OS_ID to lowercase for case-insensitive matching
OS_ID=$(echo "$OS_ID" | tr '[:upper:]' '[:lower:]')

check_success() {
    if [ $? -ne 0 ]; then
        echo "Error: $1 failed."
        exit 1
    fi
}

# Vagrant boxes are stored once, in a store shared by all users, instead of
# in every user's ~/.vagrant.d/boxes. Each user's boxes directory is a symlink to it.
GLOBAL_BOXES_DIR="/var/lib/vagrant/boxes"

# Move a user's boxes into the shared store (dropping copies it already has)
# and replace the user's boxes directory with a symlink to it
link_user_boxes() {
    local user=$1
    local home
    home=$(getent passwd "$user" | cut -d: -f6)
    if [ -z "$home" ] || [ ! -d "$home" ]; then
        return 0
    fi
    local boxes="$home/.vagrant.d/boxes"

    if [ -L "$boxes" ] && [ "$(readlink -f "$boxes")" = "$GLOBAL_BOXES_DIR" ]; then
        return 0
    fi

    if [ -d "$boxes" ] && [ ! -L "$boxes" ]; then
        local name_dir name version_dir version file
        for name_dir in "$boxes"/*/; do
            [ -d "$name_dir" ] || continue
            name=$(basename "$name_dir")
            mkdir -p "$GLOBAL_BOXES_DIR/$name"
            for version_dir in "$boxes/$name"/*/; do
                [ -d "$version_dir" ] || continue
                version=$(basename "$version_dir")
                if [ -e "$GLOBAL_BOXES_DIR/$name/$version" ]; then
                    echo "Removing $user's copy of $name $version (already in $GLOBAL_BOXES_DIR)"
                else
                    echo "Moving $user's $name $version to $GLOBAL_BOXES_DIR"
                    mv "$boxes/$name/$version" "$GLOBAL_BOXES_DIR/$name/"
                fi
            done
            # Box metadata such as metadata_url
            for file in "$boxes/$name"/*; do
                if [ -f "$file" ] && [ ! -e "$GLOBAL_BOXES_DIR/$name/$(basename "$file")" ]; then
                    mv "$file" "$GLOBAL_BOXES_DIR/$name/"
                fi
            done
        done
        rm -rf "$boxes"
    fi

    rm -f "$boxes"
    install -d -o "$user" -g "$(id -gn "$user")" "$home/.vagrant.d"
    ln -s "$GLOBAL_BOXES_DIR" "$boxes"
    chown -h "$user:" "$boxes"
    echo "Linked $boxes to $GLOBAL_BOXES_DIR"
}

# Link every libvirt user (including Jenkins) and the invoking user to the shared store
setup_global_boxes() {
    install -d -m 2775 -g libvirt "$GLOBAL_BOXES_DIR"
    check_success "!!"

    local user
    for user in $( { echo "$1"; getent group libvirt | cut -d: -f4 | tr ',' '\n'; } | sort -u); do
        link_user_boxes "$user"
        check_success "!!"
    done
}

user_exists() {
    id "$1" &>/dev/null
}

ensure_user_exists() {
    if user_exists "$USERNAME"; then
        echo "User $USERNAME already exists."
    else
        useradd -m "$USERNAME"
        check_success "!!"

        echo "$USERNAME:swiftaucular" | chpasswd
        check_success "!!"
    fi
}

post_install_common() {
    # Although the performancecopilot.metrics collection requires no special permissions,
    # Enabling pmcd/pmlogger services does. We could start them manually, but it's better
    # to spare the effort of managing logging, config, and monitoring, and instead rely on systemd.
    systemctl enable pmcd
    check_success "!!"
    systemctl enable pmlogger
    check_success "!!"
    systemctl start pmcd
    check_success "!!"
    systemctl start pmlogger
    check_success "!!"


    # Enable and start libvirt
    systemctl enable --now libvirtd
    check_success "!!"

    # Add user to libvirt group
    usermod -a -G libvirt "$USERNAME"
    check_success "!!"

    # Vagrant plugins and boxes live in the invoking user's ~/.vagrant.d, not root's.
    # fog-libvirt is pinned to 0.12.2 because vagrant-libvirt 0.12.x passes
    # libvirt_ip_command, which fog-libvirt >= 0.13 rejects with a warning.
    # fog-json is pinned to 1.2.0 because newer releases need a json gem newer
    # than the one embedded in Vagrant 2.4.0. Pins go first, or a clean install
    # of vagrant-libvirt pulls fog-json 1.5.0 and fails with Gem::ConflictError.
    local vagrant_user="${SUDO_USER:-root}"
    sudo -u "$vagrant_user" -H vagrant plugin install fog-json --plugin-version 1.2.0
    check_success "!!"
    sudo -u "$vagrant_user" -H vagrant plugin install fog-libvirt --plugin-version 0.12.2
    check_success "!!"
    sudo -u "$vagrant_user" -H vagrant plugin install vagrant-libvirt
    check_success "!!"

    setup_global_boxes "$vagrant_user"

    # Download the base box and build the -ceph box (precompiled bluestore) for the
    # storage nodes into the shared store. Boxes that already exist are skipped.
    # 2_provision_VMs.sh never downloads boxes, it fails if they are missing.
    sudo -u "$vagrant_user" -H ./vagrant_box.sh --ceph
    check_success "!!"

    # Let every libvirt user read the boxes, and update them through this script
    chgrp -R libvirt "$GLOBAL_BOXES_DIR"
    chmod -R g+rwX,o+rX "$GLOBAL_BOXES_DIR"
    check_success "!!"

}

install_for_fedora() {
    dnf install -y dnf-utils \
                   libvirt-devel \
                   qemu-kvm \
                   pcp-devel \
                   pcp-system-tools \
                   libxml2-devel \
                   libxslt-devel \
                   zlib-devel \
                   ruby-devel \
                   rsync
    check_success "!!"

    # Install Vagrant
    dnf install -y vagrant
    check_success "!!"

    dnf5 install -y @development-tools
    check_success "!!"

    # Install Ansible via dnf
    dnf install -y ansible
    check_success "!!"

    # Required for ansible-galaxy later in bootstrap script
    dnf install -y python3-resolvelib
    check_success "!!"

    dnf install -y python3-tox
    check_success "!!"
}

install_for_ubuntu() {
    apt-get update
    check_success "!!"
    apt-get install -y \
        qemu-kvm \
        libvirt-dev \
        libvirt-daemon-system \
        libvirt-clients \
        build-essential \
        python3-pip \
        python-is-python3 \
        ruby-dev \
        rsync \
        libxml2-dev \
        libxslt1-dev \
        zlib1g-dev \
        software-properties-common \
        pkg-config \
        golang-go \
        pcp \
        wget
    check_success "!!"

    # https://docs.ansible.com/ansible/latest/installation_guide/installation_distros.html#installing-ansible-on-ubuntu
    add-apt-repository --yes --update ppa:ansible/ansible
    check_success "!!"
    # Ubuntu's own ansible 2.10 package ships /usr/bin/ansible, which conflicts
    # with the PPA's ansible-core, so remove it before installing from the PPA
    if dpkg -s ansible &>/dev/null && ! dpkg -s ansible-core &>/dev/null; then
        apt remove -y ansible
        check_success "!!"
    fi
    apt install -y ansible
    check_success "!!"
    # On 22.04 tox is packaged as "tox", not "python3-tox"
    apt install -y tox
    check_success "!!"

    grep -qxF 'export PATH=$HOME/.local/bin:$PATH' ~/.bashrc || echo 'export PATH=$HOME/.local/bin:$PATH' >> ~/.bashrc

    wget -nc https://releases.hashicorp.com/vagrant/2.4.0/vagrant_2.4.0-1_amd64.deb
    apt install -y ./vagrant_2.4.0-1_amd64.deb
    check_success "!!"

    # Avoid Permission denied ~/swiftacular/.vagrant/bundler error
    # ($USER is root under sudo, so use the invoking user)
    if [ -d .vagrant ]; then
        chown -R "${SUDO_USER:-$USER}:" .vagrant
        check_success "!!"
    fi
}

install_for_arch() {
    pacman -Syu --noconfirm
    check_success "pacman -Syu"
    pacman -S --noconfirm --needed \
        qemu-desktop \
        libvirt \
        pcp \
        libxml2 \
        libxslt \
        zlib \
        ruby \
        rsync \
        base-devel \
        ansible \
        python-resolvelib \
        go \
        wget \
        python-pip \
        unzip \
        git
    check_success "!!"

    if ! command -v vagrant &> /dev/null; then
        echo "--------------------------------------------------------------------"
        echo "Vagrant not found."
        echo "Please install it as a regular user using an AUR helper like yay:"
        echo "  yay -S vagrant"
        echo "After installation, please re-run this script."
        echo "--------------------------------------------------------------------"
        exit 1
    fi
}

ensure_user_exists

case "$OS_ID" in
  fedora)
    if [[ "$VERSION_ID" != "42" ]]; then
      echo "Only Fedora 42 is supported. Detected: Fedora $VERSION_ID"
      exit 1
    fi
    install_for_fedora
    ;;
  ubuntu)
    if [[ "$VERSION_ID" != "22.04" ]]; then
      echo "Only Ubuntu 22.04 is supported. Detected: Ubuntu $VERSION_ID"
      exit 1
    fi
    install_for_ubuntu
    ;;
  arch)
    install_for_arch
    ;;
  *)
    echo "Unsupported OS: $OS_ID $VERSION_ID. Only Fedora 42, Ubuntu 22.04 and Arch are supported."
    exit 1
    ;;
esac

post_install_common

echo "System preparation for $OS_ID $VERSION_ID completed successfully."
