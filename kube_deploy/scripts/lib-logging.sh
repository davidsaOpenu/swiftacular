#!/usr/bin/env bash
# Shared logging helpers. Source this file; do not execute it directly.
# Usage: source "$(dirname "$0")/lib-logging.sh"
#
# Provides:
#   step/info/warn/error      — colored log lines (colors auto-disabled when not a tty)
#   run_logged                — run a command, show output only on failure
#   phase / print_phase_summary — named checkpoints with a duration table
#   ensure_registry_on_network  — reattach local registry to the kind network
#   unset_proxy_vars            — drop corporate proxy env vars
#   dump_cluster_diagnostics    — full pod/event/log dump for post-mortem in CI

# Colors only when stdout is a terminal; CI logs otherwise show raw escape codes.
if [[ -t 1 ]]; then
  _BOLD='\033[1m'
  _GREEN='\033[0;32m'
  _YELLOW='\033[1;33m'
  _RED='\033[0;31m'
  _RESET='\033[0m'
else
  _BOLD=''; _GREEN=''; _YELLOW=''; _RED=''; _RESET=''
fi

# Elapsed time since this library was sourced — Jenkins timestamps wall clock
# on every line already, so relative time is the more useful prefix.
_LOG_T0=$(date +%s)
_elapsed() {
  local s=$(( $(date +%s) - _LOG_T0 ))
  printf '%02dm%02ds' $((s / 60)) $((s % 60))
}

step()  { echo -e "${_BOLD}${_GREEN}==> [$(_elapsed)] ${*}${_RESET}"; }
info()  { echo -e "    ${*}"; }
warn()  { echo -e "${_YELLOW}warn: ${*}${_RESET}" >&2; }
error() { echo -e "${_RED}error: ${*}${_RESET}" >&2; }

# ── run_logged ────────────────────────────────────────────────────────────────
# run_logged "description" cmd [args...]
# Captures stdout+stderr; on success prints a one-line confirmation with the
# duration, on failure prints the full captured output and returns the
# command's exit code.  Use instead of `cmd &>/dev/null || true` so failures
# are never silent.
run_logged() {
  local desc="$1"; shift
  local out rc t0 t1
  out=$(mktemp)
  t0=$(date +%s)
  # Run inside an `if` so set -e in the caller can't abort before we print
  # the captured output.
  if "$@" >"${out}" 2>&1; then rc=0; else rc=$?; fi
  t1=$(date +%s)
  if [[ ${rc} -eq 0 ]]; then
    info "✓ ${desc} ($((t1 - t0))s)"
  else
    error "✗ ${desc} failed (rc=${rc}, $((t1 - t0))s) — output:"
    sed 's/^/      /' "${out}" >&2
  fi
  rm -f "${out}"
  return ${rc}
}

# ── phase timing ──────────────────────────────────────────────────────────────
# phase "name"            — mark the start of a named phase
# print_phase_summary     — print each phase's duration (closes the last phase)
_PHASE_NAMES=()
_PHASE_STARTS=()
phase() {
  _PHASE_NAMES+=("$1")
  _PHASE_STARTS+=("$(date +%s)")
}
print_phase_summary() {
  local now i dur next_start
  now=$(date +%s)
  [[ ${#_PHASE_NAMES[@]} -eq 0 ]] && return 0
  step "Phase timing summary"
  for i in "${!_PHASE_NAMES[@]}"; do
    if [[ $((i + 1)) -lt ${#_PHASE_NAMES[@]} ]]; then
      next_start=${_PHASE_STARTS[$((i + 1))]}
    else
      next_start=${now}
    fi
    dur=$((next_start - _PHASE_STARTS[i]))
    info "$(printf '%-30s %02dm%02ds' "${_PHASE_NAMES[i]}" $((dur / 60)) $((dur % 60)))"
  done
}

# ── proxy bypass ──────────────────────────────────────────────────────────────
# Corporate HTTP proxies on CI machines intercept even localhost traffic
# (kubectl → kind API server, curl → NodePorts/registry) and return Squid
# error pages.  Call once after all Docker-Hub-bound operations are done.
unset_proxy_vars() {
  unset HTTPS_PROXY HTTP_PROXY https_proxy http_proxy
}

# ── registry / kind network ───────────────────────────────────────────────────
# After a Docker restart the registry container loses its kind network
# attachment; pods then get ImagePullBackOff on localhost:5001 images.
# ensure_registry_on_network [registry-name] [network-name]
ensure_registry_on_network() {
  local reg="${1:-swiftacular-registry}" net="${2:-kind}"
  if docker network inspect "${net}" \
      --format '{{range .Containers}}{{.Name}} {{end}}' 2>/dev/null \
      | grep -qw "${reg}"; then
    info "Registry already on ${net} network"
  elif docker network connect "${net}" "${reg}" 2>&1; then
    info "Registry reconnected to ${net} network"
  else
    warn "Could not connect ${reg} to ${net} network — localhost:5001 pulls may fail"
  fi
}

# ── cluster diagnostics ───────────────────────────────────────────────────────
# dump_cluster_diagnostics <namespace>
# Full post-mortem: pod table, recent events, and describe + current/previous
# logs for every pod that is not Running/Completed.  Call BEFORE teardown —
# once the kind cluster is deleted all of this evidence is gone.
dump_cluster_diagnostics() {
  local ns="${1:-swiftacular}"
  step "CLUSTER DIAGNOSTICS (namespace: ${ns})"

  if ! kubectl cluster-info &>/dev/null; then
    warn "kubectl cannot reach any cluster — nothing to dump"
    return 0
  fi

  info "--- pods ---"
  kubectl get pods -n "${ns}" -o wide 2>&1 | sed 's/^/    /' || true

  info "--- events (last 50, by time) ---"
  kubectl get events -n "${ns}" --sort-by=.lastTimestamp 2>&1 \
    | tail -50 | sed 's/^/    /' || true

  local _pod
  for _pod in $(kubectl get pods -n "${ns}" --no-headers 2>/dev/null \
      | grep -v ' Running \| Completed ' | awk '{print $1}'); do
    info "--- describe ${_pod} (events) ---"
    kubectl describe pod -n "${ns}" "${_pod}" 2>&1 \
      | sed -n '/^Events:/,$p' | sed 's/^/    /' || true
    info "--- logs ${_pod} (all containers, last 50 lines) ---"
    kubectl logs -n "${ns}" "${_pod}" --all-containers --tail=50 2>&1 \
      | sed 's/^/    /' || true
    info "--- previous logs ${_pod} (last 50 lines) ---"
    kubectl logs -n "${ns}" "${_pod}" --all-containers --tail=50 --previous 2>&1 \
      | sed 's/^/    [prev] /' || true
  done

  info "--- PVCs ---"
  kubectl get pvc -n "${ns}" 2>&1 | sed 's/^/    /' || true
}
