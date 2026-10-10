#!/bin/sh
# Get the kernel tree that kernel/KERNEL_REV names (a shallow fetch of one
# commit of the kernel fork).
#
#   kernel/fetch-kernel.sh <dir>
#
# <dir>  the folder for the kernel tree. If it holds a git tree at the
#        commit already, the script does nothing.
# Env: KERNEL_URL  the kernel fork (default https://github.com/tsx-mainline/linux)
# The commit must be on a branch of the fork (GitHub gives a commit by its
# hash only when a branch or a tag holds it).
set -eu
[ $# -eq 1 ] || { awk 'NR > 1 && !/^#/ {exit} NR > 1 {print}' "$0"; exit 2; }
HERE=$(cd "$(dirname "$0")" && pwd)
DIR=$1
URL=${KERNEL_URL:-https://github.com/tsx-mainline/linux}
REV=$(sed -n 's/^commit=//p' "$HERE/KERNEL_REV")
BRANCH=$(sed -n 's/^branch=//p' "$HERE/KERNEL_REV")
[ -n "$REV" ] || { echo "ERROR: no commit= in $HERE/KERNEL_REV" >&2; exit 1; }
if [ "$(git -C "$DIR" rev-parse HEAD 2>/dev/null)" = "$REV" ]; then
	echo "== $DIR is at $REV"
	exit 0
fi
echo "== fetch $URL $REV ($BRANCH)"
mkdir -p "$DIR"
git -C "$DIR" init -q
git -C "$DIR" fetch -q --depth 1 "$URL" "$REV"
git -C "$DIR" -c advice.detachedHead=false checkout -q FETCH_HEAD
echo "== $DIR is at $(git -C "$DIR" log -1 --format='%h %s')"
