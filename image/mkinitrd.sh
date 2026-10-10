#!/bin/sh
# Build the placeholder ramdisk (uInitrd) for the stock U-Boot.
#
#   image/mkinitrd.sh <kernel-out-dir> <out-dir>
#
# The stock bootm command needs a valid ramdisk image in the ramdisk slot
# (0x300 sectors, 384 KiB). The kernel does not need it: the ramdisk holds no
# /init, so the kernel mounts the root partition from its built-in command
# line. The archive holds one file, /tsx-initrd, with the build data.
# Output: <out-dir>/uInitrd
set -eu
[ $# -eq 2 ] || { awk 'NR > 1 && !/^#/ {exit} NR > 1 {print}' "$0"; exit 2; }
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
KOUT=$(cd "$1" && pwd)
OUT=$(mkdir -p "$2" && cd "$2" && pwd)
IMAGE=${IMAGE:-tsx-xx50-build}
REL=$(cat "$KOUT/kernel.release")
docker image inspect "$IMAGE" >/dev/null 2>&1 || docker build -q -t "$IMAGE" -f "$REPO/ci/Dockerfile" "$REPO/ci"
docker run --rm -u "$(id -u):$(id -g)" -v "$OUT:/out" -e REL="$REL" "$IMAGE" sh -euc '
	d=$(mktemp -d)
	printf "tsx-xx50 placeholder ramdisk for kernel %s\n" "$REL" > $d/tsx-initrd
	(cd $d && echo tsx-initrd | cpio -o -H newc --owner 0:0 --quiet | gzip -9n > /tmp/initrd.cpio.gz)
	mkimage -A arm -O linux -T ramdisk -C none -a 0x70408000 -e 0x70408000 -n "tsx-xx50 initrd" -d /tmp/initrd.cpio.gz /out/uInitrd >/dev/null
'
SZ=$(stat -c %s "$OUT/uInitrd")
[ "$SZ" -le $((0x300 * 512)) ] || { echo "ERROR: uInitrd is larger than the 384 KiB ramdisk slot" >&2; exit 1; }
echo "== done: $OUT/uInitrd ($SZ bytes)"
