#!/usr/bin/env bash
# Compile Grafana dashboards from Jsonnet source to JSON.
# Output JSON files land in kube_deploy/charts/swiftacular/dashboards-compiled/.
# To update the Helm chart after editing the Jsonnet sources, copy the compiled
# JSON into grafana-dashboards.yaml.
#
# jsonnet is resolved in this order:
#   1. host binary  (apt install jsonnet  OR  go install ...go-jsonnet.../jsonnet@latest)
#   2. Docker       (ubuntu:26.04 + apt install jsonnet, one container for all files)
#
# jb (jsonnet-bundler) is only needed when vendor/ is absent (e.g. a fresh CI
# checkout — vendor/ is not committed).  It is resolved the same way:
#   1. host binary  (go install github.com/jsonnet-bundler/jsonnet-bundler/cmd/jb@latest)
#   2. Docker       (golang image: go install jb, then jb init + install)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib-logging.sh"

REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
DASHBOARDS_DIR="${REPO_ROOT}/monitoring/grafana/dashboards"
OUTPUT_DIR="${SCRIPT_DIR}/../charts/swiftacular/dashboards-compiled"
GRAFONNET_VERSION="v11.0.0"

# ── vendor setup (jb only needed when vendor/ is absent) ─────────────────────

NEED_INSTALL=0
[[ ! -d "${DASHBOARDS_DIR}/vendor/github.com/grafana/grafonnet" ]]     && NEED_INSTALL=1
[[ ! -d "${DASHBOARDS_DIR}/vendor/github.com/grafana/grafonnet-lib" ]] && NEED_INSTALL=1

if [[ "${NEED_INSTALL}" -eq 1 ]]; then
  step "Installing jsonnet vendor dependencies"
  # jb panics on a stale jsonnetfile.json from a previous run — always start clean.
  rm -rf "${DASHBOARDS_DIR}/vendor"
  rm -f  "${DASHBOARDS_DIR}/jsonnetfile.json" "${DASHBOARDS_DIR}/jsonnetfile.lock.json"

  if command -v jb >/dev/null 2>&1; then
    pushd "${DASHBOARDS_DIR}" >/dev/null
    jb init
    jb install "github.com/grafana/grafonnet/gen/grafonnet-${GRAFONNET_VERSION}@main"
    jb install "github.com/grafana/grafonnet-lib@master"
    popd >/dev/null

  elif command -v docker >/dev/null 2>&1; then
    # Machine-independent path for CI: golang image ships with git (jb shells
    # out to it).  jb works in a container-local dir, NOT directly on the
    # mount: jb renames vendor/.tmp/* into place, and renames fail with
    # "permission denied" on Windows-backed mounts (WSL drvfs / OneDrive).
    # cp to the mount works everywhere.  chown so the host user owns the
    # result, not root.
    info "jb not on PATH — running jsonnet-bundler via Docker (golang:1.24)"
    _UIDGID="$(id -u):$(id -g)"
    docker run --rm \
      -v "${DASHBOARDS_DIR}:/work" \
      golang:1.24 \
      bash -c "
        set -e
        echo 'go install jsonnet-bundler...'
        go install github.com/jsonnet-bundler/jsonnet-bundler/cmd/jb@latest
        export PATH=\"\$(go env GOPATH)/bin:\${PATH}\"
        mkdir -p /tmp/jb && cd /tmp/jb
        jb init
        jb install 'github.com/grafana/grafonnet/gen/grafonnet-${GRAFONNET_VERSION}@main'
        jb install 'github.com/grafana/grafonnet-lib@master'
        rm -rf /work/vendor
        # -L dereferences jb's legacy-alias symlinks (grafonnet-v11.0.0 etc.)
        # into real directories — symlink creation is unsupported on
        # Windows-backed and shared-folder mounts.
        cp -rL vendor /work/vendor
        cp jsonnetfile.json jsonnetfile.lock.json /work/
        chown -R ${_UIDGID} /work/vendor /work/jsonnetfile.json /work/jsonnetfile.lock.json \
          || echo 'chown failed — harmless on Windows-backed mounts' >&2
      "

  else
    error "vendor/ is missing; neither jb nor Docker is available."
    error "Install jb: go install github.com/jsonnet-bundler/jsonnet-bundler/cmd/jb@latest"
    exit 1
  fi
else
  info "Vendor directory up to date — skipping jb"
fi

# ── compile ───────────────────────────────────────────────────────────────────

mkdir -p "${OUTPUT_DIR}"

# Relative paths used by the Docker path (repo-root-relative).
_DASH_REL="${DASHBOARDS_DIR#${REPO_ROOT}/}"
_OUT_REL="${OUTPUT_DIR#${REPO_ROOT}/}"

if command -v jsonnet >/dev/null 2>&1; then
  # ── host binary ──────────────────────────────────────────────────────────
  FAILED=0; COMPILED=0
  for src in "${DASHBOARDS_DIR}"/*.jsonnet; do
    [[ -f "${src}" ]] || continue
    name="$(basename "${src}" .jsonnet)"
    out="${OUTPUT_DIR}/${name}.json"
    step "Compiling ${name}.jsonnet"
    if jsonnet -J "${DASHBOARDS_DIR}/vendor" "${src}" > "${out}"; then
      info "  → ${out}"
      COMPILED=$((COMPILED + 1))
    else
      error "  Failed: ${name}.jsonnet"
      FAILED=1
    fi
  done
  [[ "${FAILED}" -ne 0 ]] && { error "One or more dashboards failed."; exit 1; }

elif command -v docker >/dev/null 2>&1; then
  # ── Docker fallback: one container compiles all .jsonnet files ────────────
  info "jsonnet not on PATH — compiling via Docker (ubuntu:26.04)"
  # Build an inline shell script that runs inside the container.
  # All paths are relative to /repo (the REPO_ROOT mount).
  # stderr is NOT suppressed: apt or compile failures must be visible in CI.
  _UIDGID="$(id -u):$(id -g)"
  COMPILED=$(docker run --rm \
    -v "${REPO_ROOT}:/repo:ro" \
    -v "${OUTPUT_DIR}:/out" \
    ubuntu:26.04 \
    bash -c "
      set -e
      apt-get update -qq
      apt-get install -y -qq --no-install-recommends jsonnet >/dev/null
      n=0
      for src in /repo/${_DASH_REL}/*.jsonnet; do
        [ -f \"\${src}\" ] || continue
        name=\$(basename \"\${src}\" .jsonnet)
        jsonnet -J /repo/${_DASH_REL}/vendor \"\${src}\" > /out/\${name}.json
        echo \"compiled \${name}\" >&2
        n=\$((n+1))
      done
      chown ${_UIDGID} /out/*.json
      echo \${n}
    ")
  info "Docker compiled ${COMPILED} dashboard(s)"

else
  error "jsonnet not found and Docker is not available."
  error "Install jsonnet:  sudo apt install jsonnet"
  error "            or:  go install github.com/google/go-jsonnet/cmd/jsonnet@latest"
  exit 1
fi

# ── result ────────────────────────────────────────────────────────────────────

COMPILED="${COMPILED:-0}"
if [[ "${COMPILED}" -eq 0 ]]; then
  warn "No .jsonnet files found in ${DASHBOARDS_DIR}/"
  exit 0
fi

info ""
info "Compiled ${COMPILED} dashboard(s) to ${OUTPUT_DIR}/"
info ""
info "To update the Helm chart, paste each JSON file's content into:"
info "  kube_deploy/charts/swiftacular/templates/configmaps/grafana-dashboards.yaml"
