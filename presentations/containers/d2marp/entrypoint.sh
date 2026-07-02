#!/bin/bash

set -eu -o pipefail

BUILD_UID="${BUILD_UID:-4099}"
USER_GID="$(id -g)"

reclaim() {
	# When BUILD_UID owns a file but USER_GID doesn't.
	find /src -uid "$BUILD_UID" ! -gid "$USER_GID" \
		-exec chgrp -h "$USER_GID" {} + || true

	# When BUILD_UID can write/execute but USER_GID can't.
	find /src -uid "$BUILD_UID" '(' \
		-perm -u+w ! -perm -g+w -o  \
		-perm -u+x ! -perm -g+x ')' \
		-exec chmod g=u {} + || true
}

forward() {
	reclaim &

	kill -s "$1" "$child" 2> /dev/null
	return
}

trap 'reclaim' EXIT
umask 002
reclaim

command "$@" &
child="$!"

trap 'forward TERM' TERM
trap 'forward INT'  INT
trap 'forward HUP'  HUP
trap 'forward QUIT' QUIT

# kill -0 checks if the proccess exists
while kill -0 "$child" 2> /dev/null; do
	wait "$child" && ret="$?" || ret="$?"
done

exit "$ret"
