#!/bin/sh
# Write the time zone into the data partition image of a new card.
#
#   image/data-tz.sh <data.ext4> <zone>
#
# <data.ext4>  the empty ext4 image of the data partition (rootfs/mkrootfs.sh).
#              The script changes this file. Make a copy first. A card image
#              file works too: give the file, "?offset=" and the byte offset of
#              the partition, for example card.img?offset=41943040.
# <zone>       a time zone name, for example America/Denver.
#
# The script writes /tsx/timezone in that file system (mode 600, owner root,
# in a folder /tsx of mode 700), so the panel sees /data/tsx/timezone. At boot,
# tsx-setup of tsx-linux-common uses the zone while panel.conf has no
# TZ_NAME. The script does not write panel.conf: a panel with no kiosk counts as
# configured when panel.conf has any key, and the setup page must stay open
# until the first save. It needs debugfs (e2fsprogs).
set -eu
[ $# -eq 2 ] || { awk 'NR > 1 && !/^#/ {exit} NR > 1 {print}' "$0"; exit 2; }
IMG=$1 ZONE=$2
[ -f "${IMG%%\?offset=*}" ] || { echo "data-tz: ${IMG%%\?offset=*} is not a file" >&2; exit 1; }
printf '%s' "$ZONE" | grep -Eq '^[A-Za-z0-9_+/-]{1,64}$' || { echo "data-tz: '$ZONE' is not a time zone name" >&2; exit 2; }
case "$ZONE" in /*) echo "data-tz: '$ZONE' starts with a slash" >&2; exit 2;; esac
command -v debugfs >/dev/null 2>&1 || { echo "data-tz: debugfs (e2fsprogs) is missing" >&2; exit 1; }
TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT
printf '%s\n' "$ZONE" > "$TMP"
# debugfs prints its commands and results on stderr. Keep them for an error.
LOG=$(mktemp); trap 'rm -f "$TMP" "$LOG"' EXIT
if ! printf 'mkdir tsx\nwrite %s tsx/timezone\nset_inode_field tsx mode 040700\nset_inode_field tsx/timezone mode 0100600\nset_inode_field tsx uid 0\nset_inode_field tsx gid 0\nset_inode_field tsx/timezone uid 0\nset_inode_field tsx/timezone gid 0\n' "$TMP" |
	debugfs -w -f - "$IMG" > "$LOG" 2>&1; then
	cat "$LOG" >&2; echo "data-tz: debugfs failed" >&2; exit 1
fi
# debugfs exits 0 after a failed command: read the file back
GOT=$(debugfs -R 'cat tsx/timezone' "$IMG" 2>/dev/null || true)
[ "$GOT" = "$ZONE" ] || { cat "$LOG" >&2; echo "data-tz: the zone is not in $IMG after the write" >&2; exit 1; }
echo "data-tz: /data/tsx/timezone = $ZONE"
