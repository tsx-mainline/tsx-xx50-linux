#!/bin/sh
# Build the rescue system of the xx50 card: the image of the rescue slot.
#
#   TSX_COMMON=<tsx-linux-common checkout> image/mkrescue.sh <out-dir>
#
# The card holds the rescue system in the rescue slot, a raw area of 5 MiB
# at 0x300000. The ramdisk (image/initramfs/tsx-xx50-init.c) unpacks it into
# RAM and starts it after a boot of the golden slots, on a RESCUE file on
# TSXLOG, a finger held on the screen, /etc/tsx/force-rescue
# (tsx-boot-rescue) or a root file system that does not start
# (docs/recovery.md). The image is a header of 512 bytes:
#   TSX-RESCUE 1
#   size <bytes of the archive>
#   version <the version line of the rescue screen>
# and then a gzip-compressed cpio (newc) of the rescue root file system:
#   - Alpine packages: busybox, dropbear, e2fsprogs (with resize2fs),
#     dosfstools, ssl_client (https for wget), zstd; fw_printenv and
#     fw_setenv of u-boot-tools,
#   - rescue/ of tsx-linux-common: the rescue screen tsx-rescue-status, the
#     login tsx-rescue-login, tsx-rescue-backlight, tsx-confont,
#     tsx-data-backup and tsx-data-restore,
#   - the board files of rootfs/overlay: board.sh, tsx-boot-ok,
#     tsx-kernel-slots,
#   - image/rescue/overlay: inittab, rcS, tsx-rescue-help,
#     tsx-boot-mainline, tsx-install-rootfs, tsx-restore-stock,
#   - Terminus console fonts for tsx-confont (SIL OFL 1.1).
# The build runs in an armv7 Alpine container (docker, --platform
# linux/arm/v7; a host of another architecture needs qemu-user binfmt
# support).
# Env: ALPINE_IMAGE (default alpine:3.24), RESCUE_VERSION (default from git
# describe). Test builds only, never in a public image: TSX_DEV_RESCUE_HASH
# (a sha-512 crypt hash for root) and AUTHORIZED_KEYS (a file with a
# developer key).
# Output: <out-dir>/tsx-xx50-rescue.img, its .sha256 and rescue.manifest
# (the package list).
set -eu
[ $# -eq 1 ] || { awk 'NR > 1 && !/^#/ {exit} NR > 1 {print}' "$0"; exit 2; }
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
OUT=$(mkdir -p "$1" && cd "$1" && pwd)
: "${TSX_COMMON:?set TSX_COMMON to a tsx-linux-common checkout (it has rescue/)}"
COMMON=$(cd "$TSX_COMMON" && pwd)
[ -x "$COMMON/rescue/usr/sbin/tsx-rescue-status" ] || { echo "ERROR: no rescue/usr/sbin/tsx-rescue-status in $COMMON" >&2; exit 1; }
[ -x "$COMMON/rescue/usr/sbin/tsx-data-backup" ] || { echo "ERROR: $COMMON has no tsx-data-backup (tsx-linux-common 0.3.3 or later)" >&2; exit 1; }
IMAGE=${ALPINE_IMAGE:-alpine:3.24}
VERSION=${RESCUE_VERSION:-$(git -C "$REPO" describe --tags --always --dirty 2>/dev/null || echo unknown)}
AREA=$((5 * 1048576))
KEYS=
if [ -n "${AUTHORIZED_KEYS:-}" ]; then
	[ -s "$AUTHORIZED_KEYS" ] || { echo "ERROR: AUTHORIZED_KEYS $AUTHORIZED_KEYS is empty" >&2; exit 1; }
	KEYS=$(cat "$AUTHORIZED_KEYS")
fi

echo "== rescue system $VERSION"
docker run --rm --platform linux/arm/v7 \
	-v "$REPO:/repo:ro" -v "$COMMON:/common:ro" -v "$OUT:/out" \
	-e VERSION="$VERSION" -e KEYS="$KEYS" -e DEVHASH="${TSX_DEV_RESCUE_HASH:-}" \
	-e OWNER="$(id -u):$(id -g)" -e AREA="$AREA" "$IMAGE" sh -euc '
	apk add -q --no-cache cpio u-boot-tools font-terminus gzip >/dev/null
	R=/tmp/rescue
	rm -rf $R; mkdir -p $R
	apk add -q --root $R --initdb --no-cache --repositories-file /etc/apk/repositories --keys-dir /etc/apk/keys \
		alpine-baselayout busybox busybox-binsh dropbear dropbear-scp e2fsprogs e2fsprogs-extra \
		dosfstools ssl_client zstd >/dev/null
	# pzstd (C++) and dbclient are not needed: no libstdc++ in the image.
	rm -f $R/usr/bin/pzstd $R/usr/bin/dbclient $R/usr/lib/libstdc++.so*
	apk info -q --root $R | grep -v -x -e libstdc++ -e dropbear-dbclient | sort > /out/rescue.manifest
	# fw_printenv and fw_setenv (one program) of u-boot-tools: tsx-boot-ok.
	install -D -m 755 /usr/bin/fw_printenv $R/usr/bin/fw_printenv
	ln -sf fw_printenv $R/usr/bin/fw_setenv
	echo "u-boot-tools (fw_printenv, fw_setenv)" >> /out/rescue.manifest
	# The shared rescue tools and the board files.
	for f in tsx-rescue-status tsx-rescue-login tsx-rescue-backlight tsx-confont tsx-data-backup tsx-data-restore; do
		install -D -m 755 /common/rescue/usr/sbin/$f $R/usr/sbin/$f
	done
	install -D -m 644 /repo/rootfs/overlay/usr/local/lib/tsx/board.sh $R/usr/local/lib/tsx/board.sh
	# Also in /usr/sbin: the PATH of an ssh command has no /usr/local/sbin.
	for f in tsx-boot-ok tsx-kernel-slots; do
		install -D -m 755 /repo/rootfs/overlay/usr/local/sbin/$f $R/usr/local/sbin/$f
		ln -s ../local/sbin/$f $R/usr/sbin/$f
	done
	cp -a /repo/image/rescue/overlay/. $R/
	chmod 755 $R/etc/init.d/rcS $R/usr/sbin/*
	# Console fonts for tsx-confont (800x480: ter-118b gives 80x26).
	mkdir -p $R/usr/share/tsx/consolefonts
	for f in ter-116b ter-118b ter-120b; do
		zcat /usr/share/consolefonts/$f.psf.gz > $R/usr/share/tsx/consolefonts/$f.psf
	done
	mkdir -p $R/etc/tsx $R/dev $R/proc $R/sys $R/run $R/tmp $R/root $R/mnt
	chmod 1777 $R/tmp; chmod 700 $R/root
	echo "tsx-xx50 rescue $VERSION" > $R/etc/tsx/rescue-version
	echo tsx-rescue > $R/etc/hostname
	# root: locked. tsx-rescue-login chooses the login at each start.
	if [ -n "$DEVHASH" ]; then
		case $DEVHASH in \$6\$*) ;; *) echo "TSX_DEV_RESCUE_HASH is not a sha-512 crypt hash"; exit 1;; esac
		sed -i "s|^root:[^:]*:|root:$DEVHASH:|" $R/etc/shadow
		echo "rescue root password: TSX_DEV_RESCUE_HASH (test build, do not publish)"
	else
		sed -i "s|^root:[^:]*:|root:*:|" $R/etc/shadow
	fi
	if [ -n "$KEYS" ]; then
		mkdir -p $R/root/.ssh; printf "%s\n" "$KEYS" > $R/root/.ssh/authorized_keys
		chmod 700 $R/root/.ssh; chmod 600 $R/root/.ssh/authorized_keys
		echo "rescue ssh key: AUTHORIZED_KEYS (test build, do not publish)"
	fi
	rm -rf $R/var/cache/apk/* $R/lib/apk $R/usr/share/man $R/usr/share/doc $R/usr/share/apk $R/etc/apk
	[ -x $R/sbin/init ] || { echo "no /sbin/init in the rescue root"; exit 1; }
	[ -e $R/usr/share/udhcpc/default.script ] || { echo "no udhcpc script in the rescue root"; exit 1; }
	du -sk $R | sed "s/\t.*/ KiB unpacked/"
	(cd $R && find . | sort | cpio -o -H newc -R 0:0 --quiet | gzip -9n) > /tmp/rescue.cpio.gz
	SZ=$(wc -c < /tmp/rescue.cpio.gz)
	{ printf "TSX-RESCUE 1\nsize %s\nversion tsx-xx50 rescue %s\n" "$SZ" "$VERSION"; head -c 512 /dev/zero; } | head -c 512 > /out/tsx-xx50-rescue.img
	cat /tmp/rescue.cpio.gz >> /out/tsx-xx50-rescue.img
	TOTAL=$(wc -c < /out/tsx-xx50-rescue.img)
	echo "tsx-xx50-rescue.img: $TOTAL bytes, slot $AREA bytes ($((TOTAL * 100 / AREA)) percent)"
	[ "$TOTAL" -le "$AREA" ] || { echo "ERROR: the rescue system is larger than the rescue slot"; exit 1; }
	(cd /out && sha256sum tsx-xx50-rescue.img > tsx-xx50-rescue.img.sha256)
	chown $OWNER /out/tsx-xx50-rescue.img /out/tsx-xx50-rescue.img.sha256 /out/rescue.manifest
'
echo "== done: $OUT/tsx-xx50-rescue.img"
