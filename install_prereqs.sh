#!/bin/bash
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "Please run this script as root or using sudo!"
  exit 1
fi

USERNAME="stack"

check_success() {
    if [ $? -ne 0 ]; then
        echo "Error: $1 failed."
        exit 1
    fi
}

user_exists() {
    id "$1" &>/dev/null
}

ensure_user_exists() {
    if user_exists "$USERNAME"; then
        echo "User $USERNAME already exists."
    else
        adduser "$USERNAME"
        check_success "!!"

        echo "swiftaucular" | passwd "$USERNAME" --stdin
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

    # Add vagrant boxes
    # this operation requires no sudo privilages
    # we need it at preparation stage to prevent
    # 'vagrant up' failure.
    ./vagrant_box.sh
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
    ccheck_success "!!"

    # Install Vagrant
    dnf install -y vagrant
    check_success "!!"

    dnf5 install -y @development-tools
    check_success "!!"

    # Install Ansible via dnf
    dnf install -y ansible
    check_success "!!"

    # Required for ansible-galaxy later in bootstrap script
    dnf install python3-resolvelib
    check_success "!!"
}

install_for_ubuntu() {
    apt-get update
    check_success "apt-get update"
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
        pcp
    check_success "!!"

    # https://docs.ansible.com/ansible/latest/installation_guide/installation_distros.html#installing-ansible-on-ubuntu
    apt install software-properties-common
    check_success "!!"
    add-apt-repository --yes --update ppa:ansible/ansible
    check_success "!!"
    apt install ansible
    check_success "!!"

    grep -qxF 'export PATH=$HOME/.local/bin:$PATH' ~/.bashrc || echo 'export PATH=$HOME/.local/bin:$PATH' >> ~/.bashrc

    wget https://releases.hashicorp.com/vagrant/2.4.0/vagrant_2.4.0-1_amd64.deb
    sudo apt install ./vagrant_2.4.0-1_amd64.deb
    check_success "!!"

    # Avoid Permission denied ~/swiftacular/.vagrant/bundler error
    chown -R "$USER:$USER" .vagrant
    check_success "!!"
}

ensure_user_exists

OS_ID=$(grep -oP '^ID=\K.*' /etc/os-release | tr -d '"')
VERSION_ID=$(grep -oP '^VERSION_ID=\K.*' /etc/os-release | tr -d '"')

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
  *)
    echo "Unsupported OS: $OS_ID $VERSION_ID. Only Fedora 40 and Ubuntu 22.04 are supported."
    exit 1
    ;;
esac

post_install_common

echo "System preparation for $OS_ID $VERSION_ID completed successfully."
