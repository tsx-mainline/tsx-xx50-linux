#!/bin/sh
# Build the xx50 root file system (Alpine armv7, OpenRC, the shared tsx
# userland of tsx-linux-common, the xx50 board layer and the panel app) as an
# ext4 image.
#
#   rootfs/mkrootfs.sh <kernel-out-dir> <out-dir>
#
# Env: AUTHORIZED_KEYS  optional, a file with the ssh public key(s) for root.
#                       Without it, the image has no root key. Set the key
#                       on the setup page (the root login field).
#      TSX_APK_LOCAL    optional, a tsx-aports repository tree with
#                       v3.24/common/armv7 and v3.24/xx50/armv7 (signed
#                       packages and APKINDEX.tar.gz), for packages that are
#                       not published yet.
#      TSX_APK_URL      the repository URL that the panel lists (default
#                       https://tsx-aports.unexceptional.net). The build
#                       takes the packages from there (common and xx50).
#                       apk takes the newest version of all repositories.
#      ROOTFS_MB        size of the ext4 image in MiB (default 1536).
#      DATA_MB          size of the empty data partition image in MiB (default 512).
#      ALPINE           Alpine branch (default v3.24).
#      TSX_REV          the repo revision for /etc/tsx/build.txt (default: git HEAD).
# The build runs in an armv7 Alpine container (docker, --platform linux/arm/v7;
# a host of another architecture needs qemu-user binfmt support).
# Output: <out-dir>/rootfs.ext4, rootfs.manifest (package versions) and
# data.ext4 (an empty ext4 "tsxdata" for p3: tsx-data moves the writable
# state there at the first boot).
# The root password is locked. Login is by ssh key only (AUTHORIZED_KEYS or
# the setup page).
set -eu
[ $# -eq 2 ] || { awk 'NR > 1 && !/^#/ {exit} NR > 1 {print}' "$0"; exit 2; }
HERE=$(cd "$(dirname "$0")" && pwd)
KOUT=$(cd "$1" && pwd)
OUT=$(mkdir -p "$2" && cd "$2" && pwd)
KEYS=/dev/null
if [ -n "${AUTHORIZED_KEYS:-}" ]; then
	KEYS=$(cd "$(dirname "$AUTHORIZED_KEYS")" && pwd)/$(basename "$AUTHORIZED_KEYS")
	grep -q -E '^(ssh-|ecdsa-|sk-)' "$KEYS" || { echo "ERROR: $KEYS holds no ssh public key" >&2; exit 1; }
	if grep -q 'PRIVATE KEY' "$KEYS"; then echo "ERROR: $KEYS is a private key" >&2; exit 1; fi
fi
APKS=
[ -z "${TSX_APK_LOCAL:-}" ] || APKS=$(cd "$TSX_APK_LOCAL" && pwd)
ROOTFS_MB=${ROOTFS_MB:-1536}
DATA_MB=${DATA_MB:-512}
ALPINE=${ALPINE:-v3.24}
IMAGE=${ALPINE_IMAGE:-alpine:3.24}
TSX_APK_URL=${TSX_APK_URL:-https://tsx-aports.unexceptional.net}
REL=$(cat "$KOUT/kernel.release")
REV=${TSX_REV:-$(git -C "$HERE/.." rev-parse --short HEAD 2>/dev/null || echo unknown)}
if [ -n "$APKS" ]; then
	for c in common xx50; do
		[ -r "$APKS/$ALPINE/$c/armv7/APKINDEX.tar.gz" ] || { echo "ERROR: no $ALPINE/$c/armv7/APKINDEX.tar.gz in $APKS" >&2; exit 1; }
	done
fi

echo "== rootfs: Alpine $ALPINE armv7, kernel modules $REL, ${ROOTFS_MB} MiB"
docker run --rm --platform linux/arm/v7 \
	-v "$HERE:/src:ro" -v "$KOUT:/kout:ro" -v "$KEYS:/keys:ro" -v "${APKS:-$HERE}:/apks:ro" -v "$OUT:/out" \
	-e LOCAL_APKS="${APKS:+yes}" \
	-e ALPINE="$ALPINE" -e ROOTFS_MB="$ROOTFS_MB" -e DATA_MB="$DATA_MB" -e REL="$REL" -e REV="$REV" -e OWNER="$(id -u):$(id -g)" \
	-e TSX_APK_URL="${TSX_APK_URL%/}" \
	"$IMAGE" sh -euc '
	printf "https://dl-cdn.alpinelinux.org/alpine/%s/main\nhttps://dl-cdn.alpinelinux.org/alpine/%s/community\n" $ALPINE $ALPINE > /etc/apk/repositories
	apk add -q --no-cache e2fsprogs figlet zstd >/dev/null
	T=/tmp/target
	mkdir -p $T/etc/apk/keys
	# The signing key of tsx-aports (the tsx-keys package ships the same file).
	cp /src/overlay/etc/apk/keys/*.rsa.pub /etc/apk/keys/
	cp -a /etc/apk/keys/. $T/etc/apk/keys/
	{
		[ -z "$LOCAL_APKS" ] || { echo /apks/$ALPINE/common; echo /apks/$ALPINE/xx50; }
		echo "$TSX_APK_URL/$ALPINE/common"; echo "$TSX_APK_URL/$ALPINE/xx50"
		cat /etc/apk/repositories
	} > /tmp/repositories
	echo "-- install packages"
	PKGS="$(grep -v -e "^#" -e "^$" /src/packages.txt | tr "\n" " ") $(grep -v -e "^#" -e "^$" /src/packages-tsx.txt | tr "\n" " ")"
	# A category that the public tree does not have yet (a local build with
	# TSX_APK_LOCAL) is not an error.
	apk add --root $T --initdb --update-cache -q --force-missing-repositories --keys-dir /etc/apk/keys --repositories-file /tmp/repositories $PKGS
	# The panel lists the repositories of this project first (tsx-config
	# apply keeps this block, panel.conf APK_URL changes it).
	{
		echo "# tsx-aports (tsx-config apply. panel.conf APK_URL)"
		echo "$TSX_APK_URL/$ALPINE/common"
		echo "$TSX_APK_URL/$ALPINE/xx50"
		cat /etc/apk/repositories
	} > $T/etc/apk/repositories
	printf "%s\n" "$TSX_APK_URL" > $T/etc/tsx/apk-url.default
	echo "-- GPU firmware: yamato_pm4.fw and yamato_pfp.fw (Z430) from linux-firmware-qcom"
	mkdir -p /tmp/fw $T/lib/firmware/qcom
	(cd /tmp/fw && apk fetch -q --no-cache linux-firmware-qcom >/dev/null &&
		gzip -dc linux-firmware-qcom-*.apk | tar -x lib/firmware/qcom/yamato_pfp.fw.zst lib/firmware/qcom/yamato_pm4.fw.zst &&
		zstd -dq --rm lib/firmware/qcom/yamato_pfp.fw.zst lib/firmware/qcom/yamato_pm4.fw.zst)
	cp /tmp/fw/lib/firmware/qcom/yamato_pfp.fw /tmp/fw/lib/firmware/qcom/yamato_pm4.fw $T/lib/firmware/qcom/
	echo "-- image files, modules, keys"
	# The packages own the panel software. The image owns only these files.
	for f in etc/inittab etc/fstab; do install -D -m 644 /src/overlay/$f $T/$f; done
	mkdir -p $T/lib/modules $T/data $T/mnt/tsxlog $T/var/lib/misc
	cp -a /kout/modules/lib/modules/$REL $T/lib/modules/
	mkdir -p $T/root/.ssh
	chmod 700 $T/root/.ssh
	if [ -s /keys ]; then
		cp /keys $T/root/.ssh/authorized_keys
		chmod 600 $T/root/.ssh/authorized_keys
	fi
	sed -i "s/^root:[^:]*:/root:*:/" $T/etc/shadow
	# The floor of the boot clock (swclock).
	touch $T/var/lib/misc/openrc-shutdowntime
	printf "xx50\nrepo: %s\nkernel: %s\nalpine: %s\nbuilt: %s\n" "$REV" "$REL" "$ALPINE" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > $T/etc/tsx/build.txt
	date -u +%Y%m%d%H%M > $T/etc/tsx/build-id
	echo "-- users and services"
	chroot $T /bin/sh -e <<CH
getent passwd tsx-setup >/dev/null || adduser -D -H -s /sbin/nologin -g "on-panel setup page" tsx-setup
for s in devfs dmesg udev udev-trigger udev-settle; do rc-update -q add \$s sysinit; done
for s in root localmount modules sysctl hostname bootmisc syslog swclock seedrng udev-postmount machine-id tsx-setup tsx-hostname tsx-data tsx-config; do
	[ -e /etc/init.d/\$s ] && rc-update -q add \$s boot || echo "no service \$s"
done
for s in tsx-cpufreq tsx-touch tsx-boot-ok tsx-panel-app tsx-setup-helper tsx-setupd networking chronyd sshd crond watchdog local; do
	[ -e /etc/init.d/\$s ] && rc-update -q add \$s default || { echo "MISSING service \$s"; exit 1; }
done
for s in mount-ro killprocs savecache; do rc-update -q add \$s shutdown; done
echo tsx-xx50 > /etc/hostname
printf "127.0.0.1\tlocalhost tsx-xx50\n::1\t\tlocalhost\n" > /etc/hosts
mkdir -p /etc/crontabs && touch /etc/crontabs/root
rm -f /etc/fw_env.config
CH
	chown -R 0:0 $T/etc $T/usr/local $T/root
	rm -rf $T/var/cache/apk/*
	apk --root $T info -v 2>/dev/null | sort > /out/rootfs.manifest
	echo "-- ext4 image"
	rm -f /out/rootfs.ext4
	mkfs.ext4 -q -L tsxroot -d $T /out/rootfs.ext4 ${ROOTFS_MB}M
	du -sh $T | sed "s/^/rootfs content: /"
	rm -f /out/data.ext4
	mkfs.ext4 -q -L tsxdata /out/data.ext4 ${DATA_MB}M
	chown $OWNER /out/rootfs.ext4 /out/rootfs.manifest /out/data.ext4
'
echo "== done: $OUT/rootfs.ext4"
