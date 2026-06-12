#!/usr/bin/env bash
# Inject the Swiftacular BlueStore tool sources into a Ceph source tree.
#
#   inject.sh <ceph_src_tools_dir>
#
# <ceph_src_tools_dir>  Ceph's src/tools directory (contains CMakeLists.txt),
#                       e.g. /ceph/src/tools (image build) or
#                       /home/vagrant/ceph/src/tools (VM flow).
#
# Copies every *.cc in this directory (plus tools.list) into the tools dir and
# appends the shared CMakeLists.txt snippet, which reads tools.list to declare the
# build targets.  Which tools get built is declared once, in ceph_patches/tools.list
# — adding a tool is: drop its .cc here + add its name to tools.list.  Nothing in
# this script or the Dockerfile/playbook needs to change.
#
# Single source of truth shared by the VM/Ansible flow
# (build_bluestore_utilities.yml) and the Kubernetes build (Dockerfile.bluestore).
# Idempotent: the CMakeLists append is guarded by a marker so re-runs (the VM
# flow re-runs the play) do not duplicate it.
set -euo pipefail

d="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

tools_dir="${1:-}"
if [ -z "${tools_dir}" ] || [ ! -d "${tools_dir}" ]; then
  echo "ERROR: usage: inject.sh <ceph_src_tools_dir>  (dir must exist)" >&2
  exit 2
fi

# ── Copy tool sources (glob — no hardcoded list) ─────────────────────────────
copied=0
for cc in "${d}"/*.cc; do
  [ -e "${cc}" ] || { echo "ERROR: no .cc sources found in ${d}" >&2; exit 1; }
  install -m 0644 "${cc}" "${tools_dir}/$(basename "${cc}")"
  copied=$((copied + 1))
done
echo "✓ copied ${copied} BlueStore tool source(s) into ${tools_dir}"

# ── Copy the tool list so the appended CMakeLists (and Dockerfile) can read it ─
# This is the single source of truth for which tools to build/verify.
install -m 0644 "${d}/tools.list" "${tools_dir}/swiftacular-tools.list"

# ── Append the shared CMakeLists snippet (idempotent) ────────────────────────
marker="SWIFTACULAR BLUESTORE TOOLS"
cml="${tools_dir}/CMakeLists.txt"
[ -f "${cml}" ] || { echo "ERROR: ${cml} not found" >&2; exit 1; }

if grep -q "${marker}" "${cml}"; then
  echo "⊘ CMakeLists snippet already present in ${cml} (skipped)"
else
  {
    printf '\n# BEGIN %s\n' "${marker}"
    cat "${d}/CMakeLists.txt"
    printf '# END %s\n' "${marker}"
  } >> "${cml}"
  echo "✓ appended BlueStore tool targets to ${cml}"
fi
