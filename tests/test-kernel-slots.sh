#!/bin/sh
# Host test of rootfs/overlay/usr/local/sbin/tsx-kernel-slots on a card
# image file (TSX_CARD_DEV). It makes a 20 MiB card file with the MBR of
# image/mkcard.sh and random bytes everywhere else, and made-up uImage and
# uInitrd files (legacy U-Boot headers, random data). It checks:
#  - "write" puts each file, padded with zeros, in its normal slot, and
#    changes no other byte of the card (the golden slots stay)
#  - "show" prints the image names of the four slots and whether golden and
#    normal are the same
#  - "promote" copies the normal slots to the golden slots only after a good
#    boot of the same normal slots ($TSX_RUN/tsx/boot-ok), or with --force
#  - "check" finds a kernel and a ramdisk that can start the rescue system
#  - "restore" copies the golden slots back to the normal slots
#  - "rescue" writes a rescue slot image (header + gzip) at 0x300000, refuses
#    a damaged or too large one, and writes nothing when the slot has it
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
mkimg "$T/uInitrd" 3 "tsx-xx50 initrd (rescue 1)" 200
mkcard "$T/card" 0x7458a050 32768
cp "$T/card" "$T/card.orig"

echo "== write"
if TSX_CARD_DEV="$T/card" $SH "$TOOL" write "$T/uImage" "$T/uInitrd" > "$T/out" 2>&1; then ok "write ends with 0"; else bad "write: $(cat "$T/out")"; fi
[ "$(range "$T/card" $((0x800000)) $((4 * MIB)))" = "$(padded "$T/uImage" $((4 * MIB)))" ] && ok "uImage normal slot" || bad "uImage normal slot"
[ "$(range "$T/card" $((0x100000)) $MIB)" = "$(padded "$T/uInitrd" $MIB)" ] && ok "uInitrd normal slot" || bad "uInitrd normal slot"
# Every other byte, the golden slots too: 0..1 MiB (MBR, U-Boot, env),
# 2..8 MiB (the golden ramdisk slot and the gap), 12..20 MiB.
unchanged() {
	for r in "0 1" "2 6" "12 8"; do
		set -- $r
		[ "$(range "$T/card" $(($1 * MIB)) $(($2 * MIB)))" = "$(range "$T/card.orig" $(($1 * MIB)) $(($2 * MIB)))" ] || return 1
	done
}
unchanged && ok "no other byte changed (the golden slots stay)" || bad "bytes outside the normal slots changed"

echo "== show and sum"
TSX_CARD_DEV="$T/card" $SH "$TOOL" show > "$T/out" 2>&1 || true
grep -q 'uImage normal  (0x800000): tsx-xx50 6.18.54-tsx-xx50' "$T/out" && grep -q 'golden = normal: no' "$T/out" \
	&& ok "show" || bad "show: $(cat "$T/out")"
sum=$(TSX_CARD_DEV="$T/card" $SH "$TOOL" sum 2>&1)
want=$({ dd if="$T/card" bs=$MIB skip=8 count=4 2>/dev/null; dd if="$T/card" bs=$MIB skip=1 count=1 2>/dev/null; } | sha256sum | cut -d' ' -f1)
[ "$sum" = "$want" ] && ok "sum of the normal slots" || bad "sum: $sum"

echo "== promote"
mkdir -p "$T/run/tsx"
cp "$T/card" "$T/card.w"
pr() { TSX_CARD_DEV="$T/card" TSX_RUN="$T/run" $SH "$TOOL" promote "$@" > "$T/out" 2>&1; }
if pr; then bad "promote with no good boot: no refusal"; else cmp -s "$T/card" "$T/card.w" && ok "promote with no good boot: refused" || bad "promote with no good boot: card changed"; fi
echo "slots=0000" > "$T/run/tsx/boot-ok"
if pr; then bad "promote after another kernel booted: no refusal"; else cmp -s "$T/card" "$T/card.w" && ok "promote after another kernel booted: refused ($(head -n1 "$T/out"))" || bad "promote, other kernel: card changed"; fi
echo "slots=$sum" > "$T/run/tsx/boot-ok"
if pr; then ok "promote after a good boot"; else bad "promote: $(cat "$T/out")"; fi
[ "$(range "$T/card" $((0xC00000)) $((4 * MIB)))" = "$(padded "$T/uImage" $((4 * MIB)))" ] && ok "uImage golden slot" || bad "uImage golden slot"
[ "$(range "$T/card" $((0x200000)) $MIB)" = "$(padded "$T/uInitrd" $MIB)" ] && ok "uInitrd golden slot" || bad "uInitrd golden slot"
same=1
for r in "0 1" "3 5" "16 4"; do
	set -- $r
	[ "$(range "$T/card" $(($1 * MIB)) $(($2 * MIB)))" = "$(range "$T/card.orig" $(($1 * MIB)) $(($2 * MIB)))" ] || same=0
done
[ $same = 1 ] && ok "promote: no byte outside the slots changed" || bad "promote: bytes outside the slots changed"
TSX_CARD_DEV="$T/card" $SH "$TOOL" show 2>&1 | grep -q 'golden = normal: yes' && ok "show after promote: the same" || bad "show after promote"
pr && grep -q "already hold" "$T/out" && ok "promote again: nothing to copy" || bad "promote again: $(cat "$T/out")"
cp "$T/card.orig" "$T/card"; rm -f "$T/run/tsx/boot-ok"
if pr --force; then ok "promote --force"; else bad "promote --force: $(cat "$T/out")"; fi
[ "$(range "$T/card" $((0xC00000)) $((4 * MIB)))" = "$(range "$T/card.orig" $((0x800000)) $((4 * MIB)))" ] && ok "--force copies the normal kernel slot" || bad "--force: golden kernel slot"

echo "== check and restore"
ck() { TSX_CARD_DEV="$T/card" $SH "$TOOL" check "$@" > "$T/out" 2>&1; }
cp "$T/card.orig" "$T/card"
if ck golden; then bad "check golden on random bytes: passed"; else ok "check golden: no kernel in random bytes ($(head -n1 "$T/out"))"; fi
TSX_CARD_DEV="$T/card" $SH "$TOOL" write "$T/uImage" "$T/uInitrd" >/dev/null 2>&1
ck normal && ok "check normal: kernel and ramdisk with rescue support" || bad "check normal: $(cat "$T/out")"
mkimg "$T/uInitrd.old" 3 "tsx-xx50 initrd" 200
TSX_CARD_DEV="$T/card" $SH "$TOOL" write "$T/uImage" "$T/uInitrd.old" >/dev/null 2>&1
if ck normal; then bad "check normal: an old ramdisk passed"; else grep -q 'cannot start the rescue' "$T/out" && ok "check normal: an old ramdisk cannot start the rescue" || bad "check normal: $(cat "$T/out")"; fi
cp "$T/card" "$T/card.w"
if TSX_CARD_DEV="$T/card" $SH "$TOOL" restore > "$T/out" 2>&1; then bad "restore from random golden slots: no refusal"; else cmp -s "$T/card" "$T/card.w" && ok "restore: refused without a golden kernel" || bad "restore: card changed"; fi
TSX_CARD_DEV="$T/card" $SH "$TOOL" write "$T/uImage" "$T/uInitrd" >/dev/null 2>&1
TSX_CARD_DEV="$T/card" TSX_RUN="$T/run" $SH "$TOOL" promote --force >/dev/null 2>&1
mkimg "$T/uImage2" 2 "tsx-xx50 broken" 100000
TSX_CARD_DEV="$T/card" $SH "$TOOL" write "$T/uImage2" "$T/uInitrd.old" >/dev/null 2>&1
if TSX_CARD_DEV="$T/card" $SH "$TOOL" restore > "$T/out" 2>&1; then ok "restore ends with 0"; else bad "restore: $(cat "$T/out")"; fi
[ "$(range "$T/card" $((0x800000)) $((4 * MIB)))" = "$(padded "$T/uImage" $((4 * MIB)))" ] && ok "restore: the golden kernel is in the normal slot" || bad "restore: normal kernel slot"
[ "$(range "$T/card" $((0x100000)) $MIB)" = "$(padded "$T/uInitrd" $MIB)" ] && ok "restore: the golden ramdisk is in the normal slot" || bad "restore: normal ramdisk slot"
TSX_CARD_DEV="$T/card" $SH "$TOOL" restore 2>&1 | grep -q "already hold" && ok "restore again: nothing to copy" || bad "restore again"

echo "== rescue slot"
# mkrescue FILE BYTES: a rescue slot image with a gzip archive of BYTES random bytes.
mkrescue() {
	head -c "$2" /dev/urandom | gzip -c > "$T/arch.gz"
	{ printf 'TSX-RESCUE 1\nsize %s\nversion tsx-xx50 rescue test\n' "$(wc -c < "$T/arch.gz")"; dd if=/dev/zero bs=1 count=512 2>/dev/null; } | head -c 512 > "$1"
	cat "$T/arch.gz" >> "$1"
}
rs() { TSX_CARD_DEV="$T/card" $SH "$TOOL" rescue "$@" > "$T/out" 2>&1; }
cp "$T/card.orig" "$T/card"
mkrescue "$T/rescue.img" 100000
if rs "$T/rescue.img"; then ok "rescue ends with 0"; else bad "rescue: $(cat "$T/out")"; fi
[ "$(range "$T/card" $((0x300000)) $((5 * MIB)))" = "$(padded "$T/rescue.img" $((5 * MIB)))" ] && ok "rescue: the image, padded, at 0x300000" || bad "rescue slot content"
same=1
for r in "0 3" "8 12"; do
	set -- $r
	[ "$(range "$T/card" $(($1 * MIB)) $(($2 * MIB)))" = "$(range "$T/card.orig" $(($1 * MIB)) $(($2 * MIB)))" ] || same=0
done
[ $same = 1 ] && ok "rescue: no byte outside the rescue slot changed" || bad "rescue: bytes outside the slot changed"
rs "$T/rescue.img" && grep -q "already holds" "$T/out" && ok "rescue again: nothing written" || bad "rescue again: $(cat "$T/out")"
TSX_CARD_DEV="$T/card" $SH "$TOOL" show 2>&1 | grep -q 'rescue         (0x300000): tsx-xx50 rescue test' && ok "show: the rescue version" || bad "show: no rescue version"
cp "$T/card" "$T/card.w"
cp "$T/rescue.img" "$T/r.bad"; printf 'XXXX' | dd of="$T/r.bad" bs=1 seek=600 conv=notrunc 2>/dev/null
if rs "$T/r.bad"; then bad "a damaged archive: no refusal"; else cmp -s "$T/card" "$T/card.w" && ok "a damaged archive: refused ($(head -n1 "$T/out"))" || bad "damaged: card changed"; fi
head -c 600 "$T/rescue.img" > "$T/r.short"
if rs "$T/r.short"; then bad "a short image: no refusal"; else cmp -s "$T/card" "$T/card.w" && ok "a short image: refused" || bad "short: card changed"; fi
mkrescue "$T/r.big" $((6 * MIB))
if rs "$T/r.big"; then bad "a rescue larger than 5 MiB: no refusal"; else cmp -s "$T/card" "$T/card.w" && ok "a rescue larger than 5 MiB: refused" || bad "big: card changed"; fi
if rs "$T/uImage"; then bad "a kernel as the rescue: no refusal"; else cmp -s "$T/card" "$T/card.w" && ok "a kernel as the rescue: refused" || bad "kernel: card changed"; fi
cp "$T/card.orig" "$T/card"
TSX_CARD_DEV="$T/card" $SH "$TOOL" show 2>&1 | grep -q 'rescue         (0x300000): (no rescue system)' && ok "show: no rescue system" || bad "show without a rescue"

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
