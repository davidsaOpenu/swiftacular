# -*- mode: ruby -*-
# vi: set ft=ruby :
nodes = {
  'swift-package-cache' => [1, 20],
  'swift-keystone'      => [1, 50],
  # 'swift-lbssl'       => [1, 30],
  'swift-proxy'         => [1, 100],
  'swift-storage'       => [3, 200],
  'grafana'             => [1, 150],
}

# Select box based on ENV variable
selected_box = ENV['VM_BOX'] || "centos"
box_config = {
  "centos" => {
    box:     "eurolinux-vagrant/centos-stream-9",
    box_url: "https://app.vagrantup.com/eurolinux-vagrant/boxes/centos-stream-9/versions/9.0.28/providers/libvirt.box"
  },
  "centos-ceph" => {
    box:     "eurolinux-vagrant/centos-stream-9-ceph",
  },
  "ubuntu" => {
    box:     "generic/ubuntu2204",
    box_url: "https://vagrantcloud.com/generic/boxes/ubuntu2204/versions/4.3.12/providers/libvirt/amd64/vagrant.box",
  },
  "ubuntu-ceph" => {
    box:     "generic/ubuntu2204-ceph",
  }
}

unless box_config[selected_box]
  abort "Unsupported VM_BOX '#{selected_box}'. Supported options: #{box_config.keys.join(', ')}"
end

Vagrant.configure("2") do |config|
  # Disable default synced folder to prevent NFS usage
  config.vm.synced_folder ".", "/vagrant", disabled: true

  config.vm.provider :libvirt do |libvirt|
    # false = Use system session (qemu:///system)
    # true = Use user session (qemu:///session)
    libvirt.qemu_use_session = false # use the user libvirt session
    # libvirt.uri = 'qemu:///system' # fallback if the above line doesn't work
  end

  nodes.each do |prefix, (count, ip_start)|
    count.times do |i|
      hostname = "%s-%02d" % [prefix, (i + 1)]
      config.vm.define "#{hostname}" do |box|
        # Use -ceph variant for storage nodes
        if prefix == 'swift-storage'
          ceph_box = "#{selected_box}-ceph"
          if box_config[ceph_box]
            box.vm.box     = box_config[ceph_box][:box]
            box.vm.box_url = box_config[ceph_box][:box_url] if box_config[ceph_box][:box_url]
          else
            abort "Ceph variant '#{ceph_box}' not available for storage nodes. Please use 'centos' or 'ubuntu' as VM_BOX."
          end
        else
          box.vm.box     = box_config[selected_box][:box]
          box.vm.box_url = box_config[selected_box][:box_url] if box_config[selected_box][:box_url]
        end

        # Configure synced folders - storage nodes don't need them, others use rsync
        if prefix == 'swift-storage'
          # Keep disabled for storage nodes
        else
          box.vm.synced_folder ".", "/vagrant", type: "rsync", rsync__exclude: ['.git/', '.vagrant/']
        end

        box.vm.provision "shell", privileged: false, inline: <<-SHELL
          if [ -f /etc/os-release ]; then
            . /etc/os-release
            echo "Working on #{hostname} running $NAME $VERSION"
          else
            echo "Working on #{hostname} (unknown OS)"
          fi
        SHELL

        box.vm.hostname = "#{hostname}.example.com"

        box.vm.provider :libvirt do |v|
          v.memory = 16384
          v.cpus = `nproc`.to_i
        end

        # ------- Networks
        # Public
        box.vm.network :private_network, ip: "192.168.100.#{ip_start + i}", netmask: "255.255.255.0"
        # SSL and loadbalancing
        box.vm.network :private_network, ip: "10.0.10.#{ip_start + i}",   netmask: "255.255.255.0"
        # Internal
        box.vm.network :private_network, ip: "10.0.20.#{ip_start + i}",   netmask: "255.255.255.0"
        # Replication
        box.vm.network :private_network, ip: "10.0.30.#{ip_start + i}",   netmask: "255.255.255.0"
      end
    end
  end
end
