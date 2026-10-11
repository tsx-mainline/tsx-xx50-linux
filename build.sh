#!/bin/sh
# Build the xx50 card image for the Crestron TSS-752.
#
#   TSX_COMMON=<tsx-linux-common checkout> [AUTHORIZED_KEYS=<pubkey file>] [TSX_APK_LOCAL=<apk tree>] \
#     ./build.sh <kernel-tree> <stock-card-dump> [out-dir]
#
# <kernel-tree>      a checkout of the tsx-xx50-lts kernel branch
# <stock-card-dump>  an image of the stock SD card of the panel (the first
#                    MiB is enough). It gives the stock U-Boot and its env.
# out-dir            default ./out
# Needs docker. A host that is not armv7 or arm64 needs qemu-user binfmt
# support for the armv7 rootfs step. Steps: kernel, rootfs, ramdisk, rescue
# system, card image, offline checks. AUTHORIZED_KEYS and TSX_APK_LOCAL: see
# rootfs/mkrootfs.sh. TSX_COMMON: see image/mkinitrd.sh (the boot splash)
# and image/mkrescue.sh (the rescue system).
# Output:
# <out-dir>/tsx-xx50-tss752.img.gz and its .sha256.
set -eu
[ $# -ge 2 ] || { awk 'NR > 1 && !/^#/ {exit} NR > 1 {print}' "$0"; exit 2; }
HERE=$(cd "$(dirname "$0")" && pwd)
KSRC=$1 STOCK=$2 OUT=${3:-$HERE/out}
mkdir -p "$OUT"
"$HERE/kernel/build-kernel.sh" "$KSRC" "$OUT/kernel"
"$HERE/rootfs/mkrootfs.sh" "$OUT/kernel" "$OUT/work"
"$HERE/image/mkinitrd.sh" "$OUT/kernel" "$OUT/work"
"$HERE/image/mkrescue.sh" "$OUT/work"
"$HERE/image/mkcard.sh" "$STOCK" "$OUT/kernel" "$OUT/work" "$OUT"
python3 "$HERE/image/check-card.py" "$OUT/tsx-xx50-tss752.img" "$STOCK"
