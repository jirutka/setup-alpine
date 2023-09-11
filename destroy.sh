#!/usr/bin/env bash
# vim: set ts=4 sw=4:
set -eo pipefail

readonly SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)

# Kill all processes that have some file opened in the chroot, except this script.
echo 'Terminating remaining processes in the chroot'
if lsof -Fp -p ^$$ "$SCRIPT_DIR" | sed -n 's/^p//p' | xargs -r kill; then
	sleep 1

	if lsof -Fp -p ^$$ "$SCRIPT_DIR" >/dev/null; then
		echo 'Waiting 5 sec for processes to terminate before killing them...'
		sleep 5
		lsof -Fp -p ^$$ "$SCRIPT_DIR" | sed -n 's/^p//p' | xargs -r kill -SIGKILL
	fi
fi

# Unmounts all filesystem under the specified directory tree.
failed=false
for path in $(cat /proc/mounts | cut -d' ' -f2 | grep "^$SCRIPT_DIR." | sort -r); do
	echo "Unmounting $path"
	umount -fn "$path" || failed=true
done

if $failed; then
	echo "Skipping removal of $SCRIPT_DIR due to previous error(s)" >&2
else
	echo "Removing $SCRIPT_DIR" >&2
	rm -rf --one-file-system "$SCRIPT_DIR"
fi
