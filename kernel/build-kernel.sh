#!/bin/sh
# Build the xx50 kernel for the stock Crestron U-Boot 2009.08.
#
#   kernel/build-kernel.sh <kernel-tree> <out-dir>
#
# <kernel-tree> is a checkout of the tsx-xx50-lts branch. The build runs in
# docker (image tsx-xx50-build from ci/Dockerfile, built on first use).
# Output in <out-dir>:
#   zImage-dtb     zImage with the board DTB appended
#   uImage         legacy U-Boot image of zImage-dtb, load and entry 0x70008000
#   <board>.dtb    the board DTB
#   modules/       the module tree (lib/modules/<release>)
#   kernel.release, kernel.config, kernel.commit
# The stock U-Boot reads 0x2000 sectors (4 MiB) from the kernel slot. The
# script stops with an error if uImage is larger.
set -eu
[ $# -eq 2 ] || { awk 'NR > 1 && !/^#/ {exit} NR > 1 {print}' "$0"; exit 2; }
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
KSRC=$(cd "$1" && pwd)
OUT=$(mkdir -p "$2" && cd "$2" && pwd)
B=$OUT/kbuild
BOARD=${BOARD:-imx53-crestron-tss752}
IMAGE=${IMAGE:-tsx-xx50-build}
J=${J:-$(nproc)}
SLOT_MAX=$((0x2000 * 512))
LOADADDR=0x70008000

docker image inspect "$IMAGE" >/dev/null 2>&1 || {
	echo "== build the docker image $IMAGE (one time)"
	docker build -q -t "$IMAGE" -f "$REPO/ci/Dockerfile" "$REPO/ci"
}
run() {
	docker run --rm -u "$(id -u):$(id -g)" -v "$KSRC:$KSRC" -v "$OUT:$OUT" -w "$KSRC" "$IMAGE" sh -ec "$1"
}
MK="make -s O=$B ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf- KBUILD_BUILD_USER=build KBUILD_BUILD_HOST=tsx-build LOCALVERSION= -j$J"

echo "== configure: imx_v6_v7_defconfig + tsx-xx50.config"
mkdir -p "$B"
run "$MK imx_v6_v7_defconfig tsx-xx50.config 2>&1 | tee $OUT/config.log"
if grep -q 'not in final' "$OUT/config.log"; then
	echo "== config warnings (requested value not in the final .config):"
	grep -A1 'not in final' "$OUT/config.log" | grep -E 'Value requested|Actual value' || true
fi

echo "== build zImage, $BOARD.dtb and the modules (-j$J)"
run "$MK zImage nxp/imx/$BOARD.dtb modules"
rm -rf "$OUT/modules"
run "$MK modules_install INSTALL_MOD_PATH=$OUT/modules INSTALL_MOD_STRIP=1 >/dev/null"

echo "== pack the uImage"
cp "$B/arch/arm/boot/dts/nxp/imx/$BOARD.dtb" "$OUT/$BOARD.dtb"
cat "$B/arch/arm/boot/zImage" "$OUT/$BOARD.dtb" > "$OUT/zImage-dtb"
REL=$(cat "$B/include/config/kernel.release")
echo "$REL" > "$OUT/kernel.release"
cp "$B/.config" "$OUT/kernel.config"
git -C "$KSRC" log -1 --format="%H %s" > "$OUT/kernel.commit" 2>/dev/null || echo unknown > "$OUT/kernel.commit"
run "mkimage -A arm -O linux -T kernel -C none -a $LOADADDR -e $LOADADDR -n 'tsx-xx50 $REL' -d $OUT/zImage-dtb $OUT/uImage >/dev/null"
SZ=$(stat -c %s "$OUT/uImage")
echo "uImage: $SZ bytes, slot limit $SLOT_MAX bytes ($((SZ * 100 / SLOT_MAX)) percent)"
if [ "$SZ" -gt "$SLOT_MAX" ]; then
	echo "ERROR: uImage is larger than the 4 MiB kernel slot of the stock U-Boot" >&2
	exit 1
fi
echo "== done: $OUT/uImage ($REL)"
