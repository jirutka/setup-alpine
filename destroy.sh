#!/usr/bin/env bash
# vim: set ts=4:
set -eo pipefail

readonly SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)

# Unmounts all filesystem under the specified directory tree.
cat /proc/mounts | cut -d' ' -f2 | grep "^$SCRIPT_DIR." | sort -r | while read path; do
	echo "Unmounting $path"
	umount -fn "$path" || exit 1
done

echo "Removing $SCRIPT_DIR" >&2
rm -rf --one-file-system "$SCRIPT_DIR"
