#!/usr/bin/env bash
# Apply the Swiftacular Swift patches to an installed Swift package.
#
#   apply.sh <swift_pkg_dir> [--with-bs]
#
# <swift_pkg_dir>  absolute path of the installed `swift` package (the directory
#                  that contains container/, obj/, …).  The caller resolves this
#                  per-OS — the deb layout via `python3 -c "import swift"`, the
#                  CentOS layout as /usr/lib/python3.9/site-packages/swift — so
#                  the recipe below stays OS-independent.
# --with-bs        also install the BlueStore object backend (obj/bs_*.py) and
#                  register its paste app_factory entry point.
#
# The list of patches lives in patches.manifest (this directory), not in this
# script: adding a patch is a one-row data change, never a code change here.
# This is the single source of truth shared by the VM/Ansible flow
# (apply_patches.yml) and the Kubernetes build (Dockerfile.storage).
set -euo pipefail

d="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

swift_dir="${1:-}"
with_bs=false
[ "${2:-}" = "--with-bs" ] && with_bs=true

if [ -z "${swift_dir}" ] || [ ! -d "${swift_dir}" ]; then
  echo "ERROR: usage: apply.sh <swift_pkg_dir> [--with-bs]  (dir must exist)" >&2
  exit 2
fi
echo "Swift package dir: ${swift_dir}"

# ── Patches (manifest-driven) ────────────────────────────────────────────────
manifest="${d}/patches.manifest"
[ -f "${manifest}" ] || { echo "ERROR: ${manifest} not found" >&2; exit 1; }

# `|| [ -n "${patch_file}" ]` processes a final row that lacks a trailing newline,
# so the last patch is never silently skipped by read hitting EOF.
while read -r patch_file level subdir _rest || [ -n "${patch_file}" ]; do
  # Skip blanks and comments.
  [ -z "${patch_file}" ] && continue
  case "${patch_file}" in \#*) continue ;; esac

  src="${d}/${patch_file}"
  target="${swift_dir}/${subdir}"
  [ -f "${src}" ]    || { echo "ERROR: patch file ${src} not found" >&2; exit 1; }
  [ -d "${target}" ] || { echo "ERROR: target dir ${target} not found" >&2; exit 1; }

  if patch -p"${level}" --dry-run --reverse -d "${target}" < "${src}" >/dev/null 2>&1; then
    echo "⊘ ${patch_file}: already applied in ${subdir}/ (skipped)"
  elif patch -p"${level}" --dry-run -d "${target}" < "${src}" >/dev/null 2>&1; then
    patch -p"${level}" -d "${target}" < "${src}"
    echo "✓ ${patch_file}: applied (-p${level}) in ${subdir}/"
  else
    echo "ERROR: ${patch_file} does not apply cleanly (-p${level}) in ${target}" >&2
    patch -p"${level}" --dry-run -d "${target}" < "${src}" >&2 || true
    exit 1
  fi
done < "${manifest}"

# ── BlueStore object backend (one-off, gated by --with-bs) ───────────────────
if [ "${with_bs}" = true ]; then
  install -m 0644 "${d}/obj/bs_diskfile.py" "${swift_dir}/obj/bs_diskfile.py"
  install -m 0644 "${d}/obj/bs_server.py"   "${swift_dir}/obj/bs_server.py"
  echo "✓ BlueStore backend files installed (bs_diskfile.py, bs_server.py)"

  # Register the bs_object paste app_factory entry point.  The metadata dir name
  # differs between the deb (.dist-info / .egg-info under dist-packages) and the
  # CentOS pip (.dist-info under site-packages) layouts, so discover it.
  ep="$(find /usr/lib/python3* \
          \( -path '*swift-*.dist-info/entry_points.txt' \
          -o -path '*swift-*.egg-info/entry_points.txt' \) 2>/dev/null | head -1)"
  [ -n "${ep}" ] || { echo "ERROR: swift entry_points.txt not found" >&2; exit 1; }
  if ! grep -q '^bs_object' "${ep}"; then
    sed -i '/^\[paste\.app_factory\]/a bs_object = swift.obj.bs_server:app_factory' "${ep}"
  fi
  grep -q '^bs_object' "${ep}" || { echo "ERROR: failed to register bs_object entry point" >&2; exit 1; }
  echo "✓ bs_object entry point registered in ${ep}"
fi

echo "Swift patches complete."
