#!/bin/sh
# Build a kernel for the QEMU vexpress-a9 machine, to test the
# card image and its services without the panel. QEMU has no i.MX53 machine.
#
#   tests/build-qemu-kernel.sh <kernel-tree> <out-dir>
#
# Output: <out-dir>/zImage and <out-dir>/vexpress-v2p-ca9.dtb
set -eu
[ $# -eq 2 ] || { awk 'NR > 1 && !/^#/ {exit} NR > 1 {print}' "$0"; exit 2; }
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
KSRC=$(cd "$1" && pwd)
OUT=$(mkdir -p "$2" && cd "$2" && pwd)
IMAGE=${IMAGE:-tsx-xx50-build}
J=${J:-$(nproc)}
docker image inspect "$IMAGE" >/dev/null 2>&1 || docker build -q -t "$IMAGE" -f "$REPO/ci/Dockerfile" "$REPO/ci"
cat > "$OUT/qemu.config" <<'CFG'
CONFIG_EXT4_FS=y
CONFIG_VFAT_FS=y
CONFIG_NLS_CODEPAGE_437=y
CONFIG_NLS_ISO8859_1=y
CONFIG_DEVTMPFS=y
CONFIG_DEVTMPFS_MOUNT=y
CONFIG_TMPFS=y
CONFIG_DEBUG_FS=y
CONFIG_PSTORE=y
CONFIG_IKCONFIG=y
CONFIG_IKCONFIG_PROC=y
CONFIG_WATCHDOG=y
CONFIG_ARM_SP805_WATCHDOG=y
CONFIG_MMC_ARMMMCI=y
CONFIG_SMSC911X=y
CONFIG_INPUT_EVDEV=y
CONFIG_I2C_CHARDEV=y
CFG
docker run --rm -u "$(id -u):$(id -g)" -v "$KSRC:$KSRC" -v "$OUT:$OUT" -w "$KSRC" "$IMAGE" sh -ec "
	make -s O=$OUT/kbuild ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf- vexpress_defconfig
	scripts/kconfig/merge_config.sh -m -O $OUT/kbuild $OUT/kbuild/.config $OUT/qemu.config >/dev/null
	make -s O=$OUT/kbuild ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf- olddefconfig
	make -s O=$OUT/kbuild ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf- -j$J zImage arm/vexpress-v2p-ca9.dtb
	cp $OUT/kbuild/arch/arm/boot/zImage $OUT/
	cp $OUT/kbuild/arch/arm/boot/dts/arm/vexpress-v2p-ca9.dtb $OUT/
"
echo "== done: $OUT/zImage"
