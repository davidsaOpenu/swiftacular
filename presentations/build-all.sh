#!/bin/bash

# build-all.sh -- build every presentation in this repository.
#
#   ./build-all.sh          build everything into ./dist, wiping it first
#   ./build-all.sh <dir>    build only <dir>, leaving the rest of ./dist alone
#
# Nothing is required on the host but bash and docker. Every tool a
# presentation needs lives in its container.
#
#
# WHAT COUNTS AS A PRESENTATION
#
# There is no manifest and no list to keep up to date. A top-level directory is
# a presentation if it contains both of:
#
#   build.sh     its own build script, executed inside the container
#   container/   the image to run it in, normally a symlink into ./containers
#
# Everything else at the top level is skipped in the loop at the bottom. Adding
# a presentation means creating a directory with those two entries; this script
# does not change.
#
#
# THE CONTRACT
#
# This script knows nothing about marp, d2, or any other tool. It runs
# /src/build.sh with no arguments and then looks for a path named `.out` in the
# presentation directory. `.out` is how the build points at what it produced --
# in practice a symlink -- and its shape decides where the result lands:
#
#   a directory       ->  dist/<name>/       copied recursively
#   has an extension  ->  dist/<name>.<ext>
#   neither           ->  dist/<name>.pdf    the fallback
#
# realfile() resolves symlinks, so `.out -> slides.pdf` is seen as a path
# ending in .pdf and matches the extension rule. The bare .pdf fallback is only
# reached by an extensionless target.
#
# realfile() also refuses anything that resolves outside the directory it is
# given, which is what stops a presentation aiming `.out` at /etc and having it
# copied into dist.
#
#
# CONTAINERS
#
# A presentation names its image through container/, but that is normally a
# symlink to a shared definition under ./containers, so a toolchain is written
# once and used by every deck that needs it. container() memoises what it has
# built in container_images, keyed by the resolved directory -- so ten
# presentations pointing at containers/d2marp trigger one `docker build`, and
# the tag is stable regardless of which deck got there first.
#
# The tag comes from the directory name, or from its parent when the directory
# is literally called "container", lowercased with anything outside
# [a-z0-9_.-] replaced, under the swiftacular-presentations- prefix.
#
#
# FILE OWNERSHIP
#
# The build writes into a bind mount, so its output has to remain usable by the
# host user afterwards. Rather than run as root and chown the wreckage, the
# container runs under an unknown UID but a group we already own:
#
#   chmod g=u                 on the host, before: whatever the group can read
#                             it can also write
#   --user BUILD_UID:$(id -g) BUILD_UID is a real user baked into the image;
#                             the GID is the host user's own
#   umask 002 + reclaim()     inside the container, on entry and from an EXIT
#                             trap: new files stay group-owned and
#                             group-writable
#
# The result is that files come back out of the container owned by a group the
# invoking user is in, and both sides can read, write and delete them. The
# passes on either side of the run are deliberately redundant: the host pass
# fixes files that predate the build, the container pass fixes files the build
# itself creates.
#
# BUILD_UID must match the UID of the user created in the image's Dockerfile.
# See containers/README.md.
#
#
# WHY THE FULL-BUILD PATH WIPES DIST
#
# Building everything removes ./dist first, so a presentation that has since
# been deleted or renamed cannot leave a stale artifact behind. The
# single-presentation path does not, so that building one deck during
# development does not throw away the others.
#

set -eEu -o pipefail

BASE_DIR="$(realpath "$(dirname "$0")")"
DIST_DIR="$BASE_DIR/dist"

BUILD_UID=4099
USER_GID=$(id -g)

DOCKER_TTY=""
if [[ -t 1 ]]; then
	DOCKER_TTY="-t"
fi

log() {
	printf '>> %s\n' "$*" 1>&2
}

trap 'log "build-all: failed at line $LINENO: $BASH_COMMAND" >&2' ERR

realfile() {
	local file base

	if [[ -v "2" ]]; then
		base="$BASE_DIR/$(realpath --relative-to "$BASE_DIR" "$2")"
	else
		base="$BASE_DIR"
	fi

	file="$(realpath --relative-to "$base" "$1")"

	if [[ "${file:0:3}" == "../" ]]; then
		log "ERROR: $base/$file not in scope"
		exit 1
	elif [[ ! -e "$base/$file" ]]; then
		log "ERROR: $base/$file doesn't exist"
		exit 1
	fi

	printf "%s/%s" "${base}" "$file"
}

declare -A container_images
container() {
	local condir conid

	condir="$1"

	if [[ -v container_images[$condir] ]]; then
		log Reusing container image "${container_images[$condir]}"
		return
	fi

	conid="$(basename "$condir")"
	[[ "$conid" == "container" ]] && conid="$(basename "$(dirname "$condir")")"
	conid="$(printf "%s" "$conid" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9_.-' '-')"
	conid="swiftacular-presentations-$conid"

	log Building container image "$conid"
	docker build --build-arg "BUILD_UID=$BUILD_UID" -t "$conid" "$condir"
	container_images+=( [$condir]="$conid" )
}

presentation() {
	local name presdir condir conid presout presdest error

	name="$(basename "$1")"
	log "[$name]" Starting

	presdir="$(realfile "$1")"
	condir="$(realfile "$1/container")"

	log "[$name]" Building
	container "$condir"
	conid="${container_images[$condir]}"

	# Setup to ensure the container can read/write files.
	# When non BUILD_UID can write/execute but USER_GID can't.
	find "$presdir" ! -uid "$BUILD_UID" '(' \
		-perm -u+w ! -perm -g+w -o  \
		-perm -u+x ! -perm -g+x ')' \
		-exec chmod g=u {} + || true

	log "[$name]" Running

	error=""
	docker run --rm $DOCKER_TTY \
		--network none --read-only \
		--tmpfs /tmp:mode=1777 --tmpfs /home/user:mode=1777 \
		--user "$BUILD_UID:$USER_GID" \
		-v "$presdir:/src" \
		"$conid" "/src/build.sh" \
		|| error="$?"

	if [[ -n "$error" ]]; then
		log "[$name]" Failed with code "$error"
		exit 1
	fi

	presout="$(realfile "$1/.out" "$presdir")"
	presdest="$DIST_DIR/$(basename "$presdir")"

	if [[ -d "$presout" ]]; then
		presdest+="/"
	elif [[ "${presout##*/}" == *.* ]]; then
		presdest+=".${presout##*.}"
	else
		presdest+=".pdf"
	fi

	log "[$name]" Copying
	rm -rf "$presdest"
	cp -rP "$presout" "$presdest"

	log "[$name]" Done
}

is_presentation() {
	[[ -e "$1/build.sh" && -e "$1/container" ]]
}

if [[ -v "1" ]]; then
	dir="$BASE_DIR/$(basename "$1")"
	if ! is_presentation "$dir"; then
		log "ERROR: $dir is not a presentation (needs build.sh and container/)"
		exit 1
	fi
	mkdir -p "$DIST_DIR"
	presentation "$dir"
else
	rm -rf "$DIST_DIR"
	mkdir -p "$DIST_DIR"

	for dir in "$BASE_DIR"/*; do
		if is_presentation "$dir"; then
			presentation "$dir"
		fi
	done
fi
