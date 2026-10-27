#!/bin/bash

set -euo pipefail

declare -A DONE=()

# Run a task at most once (memoizes dependencies).
run() {
	local task=$1
	if ! declare -F "task_$task" > /dev/null; then
		echo "unknown task: $task" >&2
		echo "tasks: $(declare -F | sed -n 's/^declare -f task_//p' | tr '\n' ' ')" >&2
		exit 2
	fi
	[[ -v DONE[$task] ]] && return
	DONE[$task]=1
	"task_$task"
}

task_render() { for g in ./graphs/*.d2; do d2 --pad 0 "$g"; done }
task_build()  { run render; marp slides.md --pdf --allow-local-files < /dev/null; }
task_watch()  {
	trap 'kill 0' EXIT
	for g in ./graphs/*.d2; do d2 --pad 0 --watch --browser 0 "$g" & done
	marp slides.md -w < /dev/null
}
task_clean()  { rm -f graphs/*.svg slides.pdf slides.html .out; }
task_ci()     { run build; ln -srf slides.pdf .out; }

# Run the requested tasks, defaulting to `ci` when none are given.
for task in "${@:-ci}"; do
	run "$task"
done
