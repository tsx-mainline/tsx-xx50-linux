#!/bin/sh
# Host test of rootfs/overlay/usr/local/sbin/tsx-kernel-slots on a card
# image file (TSX_CARD_DEV). It makes a 20 MiB card file with the MBR of
# image/mkcard.sh and random bytes everywhere else, and made-up uImage and
# uInitrd files (legacy U-Boot headers, random data). It checks:
#  - "write" puts each file, padded with zeros, in its normal and golden
#    slot, and changes no other byte of the card
#  - "show" prints the image names of the four slots
#  - the refusals, with no change to the card: a wrong disk id, a partition
#    below 16 MiB, a uImage larger than 4 MiB, a uInitrd larger than 384 KiB,
#    a file that is not a U-Boot image, a ramdisk given as the kernel
# It needs sh, python3, dd, od, cmp and sha256sum. It runs no compiler and
# writes no /dev file.
# Env: TEST_SH  the shell that runs tsx-kernel-slots (default: sh)
set -eu
HERE=$(cd "$(dirname "$0")/.." && pwd)
TOOL=$HERE/rootfs/overlay/usr/local/sbin/tsx-kernel-slots
SH=${TEST_SH:-sh}
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
N=0 F=0
ok()  { N=$((N + 1)); echo "  ok: $*"; }
bad() { F=$((F + 1)); echo "  FAIL: $*"; }
MIB=1048576

# mkimg FILE TYPE NAME DATA_BYTES: a legacy U-Boot image header (OS Linux,
# ARM, TYPE 2 kernel or 3 ramdisk) and DATA_BYTES of random data.
mkimg() {
	python3 - "$@" <<'EOF'
import os, struct, sys
f, typ, name, n = sys.argv[1], int(sys.argv[2]), sys.argv[3].encode(), int(sys.argv[4])
hdr = struct.pack(">IIIIIIIBBBB32s", 0x27051956, 0, 0, n, 0x70008000, 0x70008000, 0, 5, 2, typ, 0, name)
open(f, "wb").write(hdr + os.urandom(n))
EOF
}

# mkcard FILE DISK_ID P1_START: 20 MiB of random bytes with an MBR.
mkcard() {
	python3 - "$@" <<'EOF'
import os, struct, sys
f, disk_id, p1 = sys.argv[1], int(sys.argv[2], 0), int(sys.argv[3])
b = bytearray(os.urandom(20 * 1048576))
b[440:444] = struct.pack("<I", disk_id)
b[446:510] = bytes(64)
b[446 + 4] = 0x0e
b[446 + 8:446 + 16] = struct.pack("<II", p1, 2048)
b[510:512] = b"\x55\xaa"
open(f, "wb").write(b)
EOF
}

# range FILE OFFSET LEN: sha256 of a byte range (1 MiB blocks).
range() { dd if="$1" bs=$MIB skip=$(($2 / MIB)) count=$(($3 / MIB)) 2>/dev/null | sha256sum | cut -d' ' -f1; }
padded() { { cat "$1"; dd if=/dev/zero bs=1 count=$(($2 - $(wc -c < "$1"))) 2>/dev/null; } | sha256sum | cut -d' ' -f1; }

mkimg "$T/uImage" 2 "tsx-xx50 6.18.54-tsx-xx50" 3000000
mkimg "$T/uInitrd" 3 "tsx-xx50 initrd" 200
mkcard "$T/card" 0x7458a050 32768
cp "$T/card" "$T/card.orig"

echo "== write"
if TSX_CARD_DEV="$T/card" $SH "$TOOL" write "$T/uImage" "$T/uInitrd" > "$T/out" 2>&1; then ok "write ends with 0"; else bad "write: $(cat "$T/out")"; fi
for s in 0x800000 0xC00000; do
	[ "$(range "$T/card" $((s)) $((4 * MIB)))" = "$(padded "$T/uImage" $((4 * MIB)))" ] && ok "uImage slot $s" || bad "uImage slot $s"
done
for s in 0x100000 0x200000; do
	[ "$(range "$T/card" $((s)) $MIB)" = "$(padded "$T/uInitrd" $MIB)" ] && ok "uInitrd slot $s" || bad "uInitrd slot $s"
done
# Every other byte: the first MiB (MBR, U-Boot, env), 3..8 MiB, 16..20 MiB.
same=1
for r in "0 1" "3 5" "16 4"; do
	set -- $r
	[ "$(range "$T/card" $(($1 * MIB)) $(($2 * MIB)))" = "$(range "$T/card.orig" $(($1 * MIB)) $(($2 * MIB)))" ] || same=0
done
[ $same = 1 ] && ok "no other byte changed" || bad "bytes outside the slots changed"

echo "== show"
TSX_CARD_DEV="$T/card" $SH "$TOOL" show > "$T/out" 2>&1 || true
grep -q 'uImage normal  (0x800000): tsx-xx50 6.18.54-tsx-xx50' "$T/out" && grep -q 'uInitrd golden (0x200000): tsx-xx50 initrd' "$T/out" \
	&& ok "show" || bad "show: $(cat "$T/out")"

echo "== refusals"
# refuse WHAT CARD UIMAGE UINITRD: the command fails and the card stays the same.
refuse() {
	cp "$2" "$T/c"
	if TSX_CARD_DEV="$T/c" $SH "$TOOL" write "$3" "$4" > "$T/out" 2>&1; then
		bad "$1: no refusal"
	elif cmp -s "$2" "$T/c"; then
		ok "$1: refused ($(head -n1 "$T/out"))"
	else
		bad "$1: refused, but the card changed"
	fi
}
mkcard "$T/card.id" 0x12345678 32768
refuse "wrong disk id" "$T/card.id" "$T/uImage" "$T/uInitrd"
mkcard "$T/card.low" 0x7458a050 8192
refuse "partition below 16 MiB" "$T/card.low" "$T/uImage" "$T/uInitrd"
mkimg "$T/big" 2 "big" $((4 * MIB))
refuse "uImage larger than 4 MiB" "$T/card.orig" "$T/big" "$T/uInitrd"
mkimg "$T/bigrd" 3 "big" $((0x300 * 512))
refuse "uInitrd larger than 384 KiB" "$T/card.orig" "$T/uImage" "$T/bigrd"
head -c 4096 /dev/urandom > "$T/junk"
refuse "not a U-Boot image" "$T/card.orig" "$T/junk" "$T/uInitrd"
refuse "a ramdisk as the kernel" "$T/card.orig" "$T/uInitrd" "$T/uInitrd"
refuse "no uInitrd file" "$T/card.orig" "$T/uImage" "$T/uInitrd.none"

echo "== $N passed, $F failed"
[ "$F" = 0 ]
