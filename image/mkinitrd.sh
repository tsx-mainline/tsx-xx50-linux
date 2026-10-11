#!/bin/sh
# Build the boot ramdisk (uInitrd) for the stock U-Boot: the boot splash.
#
#   TSX_COMMON=<tsx-linux-common checkout> image/mkinitrd.sh <kernel-out-dir> <out-dir>
#
# The stock U-Boot loads 0x300 sectors (384 KiB) from the ramdisk slot to
# 0x70D00000 and gives the image data to the kernel where it is. It does not
# use the load address of the image header. The ramdisk holds:
#   /init                          image/initramfs/tsx-xx50-init.c (static)
#   /usr/local/bin/tsx-splash      splash/src/tsx-splash.c of tsx-linux-common (static)
#   /usr/share/tsx/splash/         the 800x480 frame and the 16-pixel status
#                                  font (splash/mksplash.sh of tsx-linux-common)
# /init draws the splash, mounts the root partition of the kernel command
# line and starts /sbin/init there, or unpacks the rescue system of the rescue
# slot (image/mkrescue.sh) and starts it (see the source). /init links zlib
# statically for the rescue archive. The build runs in an
# armv7 Alpine container (docker, --platform linux/arm/v7; a host of another
# architecture needs qemu-user binfmt support).
# Env: ALPINE_IMAGE (default alpine:3.24), SPLASH_SIZE (default 800x480).
# Output: <out-dir>/uInitrd and <out-dir>/initrd.cpio.gz
set -eu
[ $# -eq 2 ] || { awk 'NR > 1 && !/^#/ {exit} NR > 1 {print}' "$0"; exit 2; }
HERE=$(cd "$(dirname "$0")" && pwd)
KOUT=$(cd "$1" && pwd)
OUT=$(mkdir -p "$2" && cd "$2" && pwd)
: "${TSX_COMMON:?set TSX_COMMON to a tsx-linux-common checkout (it has splash/)}"
COMMON=$(cd "$TSX_COMMON" && pwd)
[ -r "$COMMON/splash/src/tsx-splash.c" ] || { echo "ERROR: no splash/src/tsx-splash.c in $COMMON" >&2; exit 1; }
IMAGE=${ALPINE_IMAGE:-alpine:3.24}
SIZE=${SPLASH_SIZE:-800x480}
REL=$(cat "$KOUT/kernel.release")
SLOT=$((0x300 * 512))

echo "== ramdisk: /init, tsx-splash and the $SIZE splash for kernel $REL"
docker run --rm --platform linux/arm/v7 \
	-v "$HERE:/src:ro" -v "$COMMON/splash:/splash:ro" -v "$OUT:/out" \
	-e SIZE="$SIZE" -e OWNER="$(id -u):$(id -g)" "$IMAGE" sh -euc '
	apk add -q --no-cache build-base linux-headers cpio u-boot-tools zlib-dev zlib-static >/dev/null
	R=/tmp/ramdisk
	mkdir -p $R/dev $R/proc $R/sys $R/newroot $R/usr/local/bin $R/usr/share/tsx/splash
	CFLAGS="-static -Os -s -Wall -Wextra -Wno-unused-parameter"
	gcc $CFLAGS -o $R/init /src/initramfs/tsx-xx50-init.c -lz
	gcc $CFLAGS -o $R/usr/local/bin/tsx-splash /splash/src/tsx-splash.c
	sh /splash/mksplash.sh /tmp/splash "$SIZE" >/dev/null
	cp /tmp/splash/splash-$SIZE.ppm /tmp/splash/font-16.psf $R/usr/share/tsx/splash/
	mknod -m 600 $R/dev/console c 5 1
	(cd $R && find . | sort | cpio -o -H newc -R 0:0 --quiet | gzip -9n) > /out/initrd.cpio.gz
	mkimage -A arm -O linux -T ramdisk -C none -a 0x70408000 -e 0x70408000 -n "tsx-xx50 initrd (rescue 1)" -d /out/initrd.cpio.gz /out/uInitrd >/dev/null
	ls -l $R/init $R/usr/local/bin/tsx-splash
	chown $OWNER /out/initrd.cpio.gz /out/uInitrd
'
SZ=$(stat -c %s "$OUT/uInitrd")
echo "uInitrd: $SZ bytes, slot limit $SLOT bytes ($((SZ * 100 / SLOT)) percent)"
[ "$SZ" -le "$SLOT" ] || { echo "ERROR: uInitrd is larger than the 384 KiB ramdisk slot" >&2; exit 1; }
echo "== done: $OUT/uInitrd"
