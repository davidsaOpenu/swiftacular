#!/usr/bin/env bash
# Shared logging helpers. Source this file; do not execute it directly.
# Usage: source "$(dirname "$0")/lib-logging.sh"

_BOLD='\033[1m'
_GREEN='\033[0;32m'
_YELLOW='\033[1;33m'
_RED='\033[0;31m'
_RESET='\033[0m'

step()  { echo -e "${_BOLD}${_GREEN}==> ${*}${_RESET}"; }
info()  { echo -e "    ${*}"; }
warn()  { echo -e "${_YELLOW}warn: ${*}${_RESET}" >&2; }
error() { echo -e "${_RED}error: ${*}${_RESET}" >&2; }
