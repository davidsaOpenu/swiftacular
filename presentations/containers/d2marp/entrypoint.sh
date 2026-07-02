#!/bin/bash

reclaim() {
	chgrp -R "$(id -g)" "/src" 2>/dev/null || true
	chmod -R "g=u" "/src" 2>/dev/null || true
}

umask 002
reclaim

trap 'reclaim'  EXIT
trap 'exit 143' TERM
trap 'exit 130' INT
trap 'exit 129' HUP
trap 'exit 131' QUIT

command "$@" &
wait "$!"
