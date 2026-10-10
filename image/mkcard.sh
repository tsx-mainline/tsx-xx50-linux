#!/bin/sh
# Assemble the xx50 SD card image for the TSS-752.
#
#   image/mkcard.sh <stock-card-dump> <kernel-out-dir> <work-dir> <out-dir>
#
# <stock-card-dump>  an image of the stock SD card of the panel (or at least
#                    its first MiB). The script copies the stock U-Boot and
#                    its env from it, byte for byte. No Crestron file is part
#                    of this repository.
# <kernel-out-dir>   output of kernel/build-kernel.sh (uImage)
# <work-dir>         holds uInitrd (image/mkinitrd.sh), rootfs.ext4 and
#                    data.ext4 (rootfs/mkrootfs.sh)
# Output: <out-dir>/$NAME.img.gz and $NAME.img.gz.sha256 (and the raw .img)
#
# Card layout (bytes, sectors of 512 bytes):
#   0x000000  MBR, disk id 0x7458a050 (the kernel finds root by PARTUUID)
#   0x000400  stock U-Boot 2009.08 with IVT and DCD   (copied from the dump)
#   0x0C0000  stock U-Boot env, 128 KiB               (copied from the dump)
#   0x100000  uInitrd, normal slot  (U-Boot reads sector 0x0800, 0x300 sectors)
#   0x200000  uInitrd, golden slot  (U-Boot reads sector 0x1000, 0x300 sectors)
#   0x800000  uImage, normal slot   (U-Boot reads sector 0x4000, 0x2000 sectors)
#   0xC00000  uImage, golden slot   (U-Boot reads sector 0x6000, 0x2000 sectors)
#   16 MiB    p1 FAT16 "TSXLOG", 64 MiB (logs, readable on any PC)
#   80 MiB    p2 ext4 "tsxroot" (Alpine armv7, the packages)
#   after p2  p3 ext4 "tsxdata" (/data: the settings, the layout, the logs)
# The stock U-Boot switches between the normal and the golden slots from its
# retry counters. Both slots hold the same files, so both paths boot this
# kernel.
set -eu
[ $# -eq 4 ] || { awk 'NR > 1 && !/^#/ {exit} NR > 1 {print}' "$0"; exit 2; }
HERE=$(cd "$(dirname "$0")" && pwd)
STOCK=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
KOUT=$(cd "$2" && pwd)
WORK=$(cd "$3" && pwd)
OUT=$(mkdir -p "$4" && cd "$4" && pwd)
NAME=${NAME:-tsx-xx50-tss752}
LOG_MB=64
IMAGE=${IMAGE:-tsx-xx50-build}
for f in "$KOUT/uImage" "$WORK/uInitrd" "$WORK/rootfs.ext4" "$WORK/data.ext4"; do
	[ -s "$f" ] || { echo "ERROR: $f is missing" >&2; exit 1; }
done
ROOT_BYTES=$(stat -c %s "$WORK/rootfs.ext4")
P1_START=32768
P1_SECTORS=$((LOG_MB * 2048))
P2_START=$((P1_START + P1_SECTORS))
P2_SECTORS=$((ROOT_BYTES / 512))
P3_START=$((P2_START + P2_SECTORS))
P3_SECTORS=$(($(stat -c %s "$WORK/data.ext4") / 512))
TOTAL_SECTORS=$((P3_START + P3_SECTORS))
echo "== card image: $((TOTAL_SECTORS / 2048)) MiB (TSXLOG $LOG_MB MiB, root $((P2_SECTORS / 2048)) MiB, data $((P3_SECTORS / 2048)) MiB)"

# Extract the stock U-Boot and env range [0x400, 0xE0000) to the work dir.
dd if="$STOCK" of="$WORK/stock-uboot-env.bin" bs=1024 skip=1 count=$(((0xE0000 - 0x400) / 1024)) status=none
[ "$(stat -c %s "$WORK/stock-uboot-env.bin")" -eq $((0xE0000 - 0x400)) ] || { echo "ERROR: the stock dump is too short" >&2; exit 1; }
cp "$HERE/TSXLOG-README.txt" "$WORK/TSXLOG-README.txt"

docker image inspect "$IMAGE" >/dev/null 2>&1 || docker build -q -t "$IMAGE" -f "$HERE/../ci/Dockerfile" "$HERE/../ci"
docker run --rm -v "$WORK:/w" -v "$KOUT:/k:ro" -v "$OUT:/out" -e NAME="$NAME" \
	-e P1_START=$P1_START -e P1_SECTORS=$P1_SECTORS -e P2_START=$P2_START -e P2_SECTORS=$P2_SECTORS \
	-e P3_START=$P3_START -e P3_SECTORS=$P3_SECTORS \
	-e TOTAL_SECTORS=$TOTAL_SECTORS -e OWNER="$(id -u):$(id -g)" "$IMAGE" sh -euc '
	I=/out/$NAME.img
	rm -f $I $I.gz
	truncate -s $((TOTAL_SECTORS * 512)) $I
	printf "label: dos\nlabel-id: 0x7458a050\nunit: sectors\n\nstart=%s, size=%s, type=e\nstart=%s, size=%s, type=83\nstart=%s, size=%s, type=83\n" \
		$P1_START $P1_SECTORS $P2_START $P2_SECTORS $P3_START $P3_SECTORS | sfdisk -q --wipe never --wipe-partitions never $I
	dd if=/w/stock-uboot-env.bin of=$I bs=1024 seek=1 conv=notrunc status=none
	for off in 1048576 2097152; do dd if=/w/uInitrd of=$I bs=4096 seek=$((off / 4096)) conv=notrunc status=none; done
	for off in 8388608 12582912; do dd if=/k/uImage of=$I bs=4096 seek=$((off / 4096)) conv=notrunc status=none; done
	rm -f /tmp/log.vfat
	mkfs.vfat -n TSXLOG -i 7458a051 -C /tmp/log.vfat $((P1_SECTORS / 2)) >/dev/null
	sed "s/\$/\r/" /w/TSXLOG-README.txt > /tmp/README.TXT
	mcopy -i /tmp/log.vfat /tmp/README.TXT ::README.TXT
	dd if=/tmp/log.vfat of=$I bs=512 seek=$P1_START conv=notrunc status=none
	dd if=/w/rootfs.ext4 of=$I bs=1M seek=$((P2_START / 2048)) conv=notrunc status=none
	dd if=/w/data.ext4 of=$I bs=1M seek=$((P3_START / 2048)) conv=notrunc status=none
	(cd /out && sha256sum $NAME.img > $NAME.img.sha256)
	gzip -9 -k $I
	(cd /out && sha256sum $NAME.img.gz > $NAME.img.gz.sha256)
	chown $OWNER $I $I.gz /out/$NAME.img.sha256 /out/$NAME.img.gz.sha256
'
rm -f "$WORK/stock-uboot-env.bin" "$WORK/TSXLOG-README.txt"
ls -l "$OUT/$NAME.img" "$OUT/$NAME.img.gz"
cat "$OUT/$NAME.img.gz.sha256"
