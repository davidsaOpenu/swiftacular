#!/usr/bin/env bash

# Print the Vagrant setup of the host: every libvirt user's ~/.vagrant.d,
# the shared box store and the box images vagrant-libvirt uploaded to
# libvirt. Read-only; sizes of directories the caller can't read show as "?".

set -uo pipefail

GLOBAL_BOXES_DIR="/var/lib/vagrant/boxes"
LIBVIRT_URI="qemu:///system"

size_of() {
  local size
  size=$(du -sh "$1" 2>/dev/null | cut -f1)
  echo "${size:-?}"
}

# Installed plugins with versions, read from plugins.json so no other user's vagrant has to run
plugins_of() {
  local file="$1/plugins.json"
  [ -r "$file" ] || { echo "none"; return; }
  python3 -I -c '
import json, sys
installed = json.load(open(sys.argv[1])).get("installed", {})
print(", ".join("%s %s" % (n, p.get("installed_gem_version") or "?") for n, p in sorted(installed.items())) or "none")
' "$file" 2>/dev/null || echo "?"
}

echo "=== Vagrant $(vagrant --version 2>/dev/null | awk '{ print $2 }') on $(hostname -s) ==="

echo -e "\n--- Users (libvirt group and $(id -un)) ---"
for user in $( { id -un; getent group libvirt | cut -d: -f4 | tr ',' '\n'; } | sort -u); do
  home=$(getent passwd "$user" | cut -d: -f6)
  vagrant_home="$home/.vagrant.d"
  [ "$user" = "$(id -un)" ] && vagrant_home="${VAGRANT_HOME:-$vagrant_home}"
  boxes_dir="$vagrant_home/boxes"

  if [ ! -d "$vagrant_home" ]; then
    echo "$user: no $vagrant_home"
    continue
  fi
  if [ -L "$boxes_dir" ] && [ "$(readlink -f "$boxes_dir")" = "$GLOBAL_BOXES_DIR" ]; then
    boxes="shared"
  elif [ -L "$boxes_dir" ]; then
    boxes="linked to $(readlink "$boxes_dir"), not the shared store"
  elif [ -d "$boxes_dir" ]; then
    boxes="local copy, $(size_of "$boxes_dir"), not shared"
  else
    boxes="none"
  fi
  echo "$user: $vagrant_home $(size_of "$vagrant_home"), boxes: $boxes"
  echo "  plugins: $(plugins_of "$vagrant_home")"
done

echo -e "\n--- Shared box store ---"
if [ -d "$GLOBAL_BOXES_DIR" ]; then
  echo "$GLOBAL_BOXES_DIR $(size_of "$GLOBAL_BOXES_DIR"), $(stat -c '%A %U:%G' "$GLOBAL_BOXES_DIR")"
  for version_dir in "$GLOBAL_BOXES_DIR"/*/*/; do
    [ -d "$version_dir" ] || continue
    name=$(basename "$(dirname "$version_dir")")
    echo "  ${name//-VAGRANTSLASH-//} $(basename "$version_dir"): $(size_of "$version_dir")"
  done
else
  echo "$GLOBAL_BOXES_DIR missing"
fi

# vagrant-libvirt uploads each box once to the storage pool and creates VM disks from it.
# Images of old box versions stay there until removed with 'virsh vol-delete'.
echo -e "\n--- Box images in libvirt ($LIBVIRT_URI) ---"
for pool in $(virsh -c "$LIBVIRT_URI" pool-list --name 2>/dev/null); do
  for vol in $(virsh -c "$LIBVIRT_URI" vol-list "$pool" 2>/dev/null | awk '/_vagrant_box_image_/ { print $1 }'); do
    bytes=$(virsh -c "$LIBVIRT_URI" vol-info --pool "$pool" "$vol" --bytes 2>/dev/null | awk '/Allocation/ { print $2 }')
    echo "  $pool/$vol: $(numfmt --to=iec "${bytes:-0}")"
  done
done

echo -e "\n--- Vagrant VMs in libvirt ---"
domains=$(virsh -c "$LIBVIRT_URI" list --all 2>/dev/null | tail -n +3 | sed '/^$/d')
echo "${domains:-  none}"
echo
