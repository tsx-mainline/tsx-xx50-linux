#!/bin/sh
# Host test of the rescue tools of the xx50 with fakes and image files. No
# panel, no root, no compiler:
#  - tsx-boot-rescue (running system): the force-rescue file or the U-Boot
#    fallback (--golden), the checks before, --no-reboot
#  - tsx-boot-mainline (rescue system): the counters, --last-good, the
#    check of the normal slots, --force, --no-reboot
#  - tsx-restore-stock (rescue system) on card image files: the dump is
#    written except the U-Boot range, the bytes after the dump stay, the
#    refusals (another U-Boot, a TSX - LINUX card, a dump larger than the
#    card), stdin and gzip
#  - busybox sh -n of every script of the rescue overlay
# Run it with: sh tests/test-rescue-tools.sh (busybox sh on the build host).
set -eu
HERE=$(cd "$(dirname "$0")/.." && pwd)
BR=$HERE/rootfs/overlay/usr/local/sbin/tsx-boot-rescue
BM=$HERE/image/rescue/overlay/usr/sbin/tsx-boot-mainline
RS=$HERE/image/rescue/overlay/usr/sbin/tsx-restore-stock
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
N=0 F=0
ok()  { N=$((N + 1)); echo "  ok: $*"; }
bad() { F=$((F + 1)); echo "  FAIL: $*"; }
MB=1048576

echo "== syntax"
for f in "$HERE"/image/rescue/overlay/usr/sbin/* "$HERE"/image/rescue/overlay/etc/init.d/rcS "$BR" "$HERE/image/mkrescue.sh"; do
	busybox sh -n "$f" && ok "busybox sh -n $(basename "$f")" || bad "busybox sh -n $f"
done

# Fakes: tsx-kernel-slots (show, check, restore) and tsx-boot-ok log their
# calls. FAKE_RESCUE: the rescue version ("" = none), FAKE_BAD: slots that
# fail the check.
mkdir -p "$T/bin"
cat > "$T/bin/slots" <<'EOF'
#!/bin/sh
echo "slots $*" >> "$FAKE_T/calls"
case $1 in
show) echo "golden = normal: yes"; echo "rescue         (0x300000): ${FAKE_RESCUE:-(no rescue system)}";;
check) case " ${FAKE_BAD:-} " in *" $2 "*) echo "tsx-kernel-slots: $2 slots: bad" >&2; exit 1;; esac; echo "tsx-kernel-slots: $2 slots: ok";;
restore) [ -z "${FAKE_RESTORE_FAIL:-}" ] || exit 1;;
esac
exit 0
EOF
cat > "$T/bin/bootok" <<'EOF'
#!/bin/sh
echo "bootok $*" >> "$FAKE_T/calls"
exit "${FAKE_BOOTOK_RC:-0}"
EOF
cat > "$T/bin/reboot" <<'EOF'
#!/bin/sh
echo "reboot $*" >> "$FAKE_T/calls"
EOF
chmod 755 "$T/bin"/*
export FAKE_T=$T
br() { rm -rf "$T/etc"; : > "$T/calls"
	TSX_KERNEL_SLOTS=$T/bin/slots TSX_BOOT_OK=$T/bin/bootok TSX_FORCE_RESCUE=$T/etc/tsx/force-rescue TSX_REBOOT=$T/bin/reboot \
	busybox sh "$BR" "$@" > "$T/out" 2>&1; }
bm() { : > "$T/calls"
	TSX_KERNEL_SLOTS=$T/bin/slots TSX_BOOT_OK=$T/bin/bootok TSX_REBOOT=${TSX_REBOOT:-$T/bin/reboot} \
	busybox sh "$BM" "$@" > "$T/out" 2>&1; }
called() { grep -qx "$1" "$T/calls"; }

echo "== tsx-boot-rescue"
export FAKE_RESCUE="tsx-xx50 rescue 0.3.3" FAKE_BAD=
if br; then ok "default: exit 0"; else bad "default: $(cat "$T/out")"; fi
[ -s "$T/etc/tsx/force-rescue" ] && ok "default: the force-rescue file" || bad "default: no force-rescue file"
called "slots check normal" && ok "default: checks the normal slots" || bad "default: no check of the normal slots"
called "reboot " && ok "default: reboots" || bad "default: no reboot"
called "bootok --fallback" && bad "default: wrote the counters" || ok "default: the counters stay"
br --golden && ok "--golden: exit 0" || bad "--golden: $(cat "$T/out")"
called "bootok --fallback" && called "slots check golden" && ok "--golden: checks the golden slots, boot_retry=10 (tsx-boot-ok --fallback)" || bad "--golden: $(cat "$T/calls")"
[ ! -e "$T/etc/tsx/force-rescue" ] && ok "--golden: no force-rescue file" || bad "--golden: force-rescue file"
br --no-reboot && ! called "reboot " && [ -e "$T/etc/tsx/force-rescue" ] && ok "--no-reboot: the file, no reboot" || bad "--no-reboot"
FAKE_RESCUE= br && bad "no rescue system: no refusal" || { [ ! -e "$T/etc/tsx/force-rescue" ] && ! called "reboot " && ok "no rescue system: refused, nothing done" || bad "no rescue: something done"; }
FAKE_BAD=normal br && bad "old ramdisk: no refusal" || { [ ! -e "$T/etc/tsx/force-rescue" ] && ok "a ramdisk without rescue support: refused" || bad "old ramdisk: file written"; }
FAKE_BAD=golden br --golden && bad "golden slots without rescue: no refusal" || { ! called "bootok --fallback" && ok "--golden with old golden slots: refused, counters stay" || bad "--golden: counters written"; }
FAKE_BOOTOK_RC=1 br --golden && bad "--golden: a failed env write passed" || { ! called "reboot " && ok "--golden: a failed env write: no reboot" || bad "--golden: rebooted after a failed write"; }
br --bogus && bad "unknown argument accepted" || ok "unknown argument: refused"

echo "== tsx-boot-mainline"
bm --no-reboot && called "bootok --reset" && ! called "reboot -f" && ok "--no-reboot: counters reset, no reboot" || bad "--no-reboot: $(cat "$T/out")"
called "slots restore" && bad "restore without --last-good" || ok "no copy without --last-good"
TSX_REBOOT="$T/bin/reboot -f" bm && called "reboot -f" && ok "default: reboots" || bad "default: $(cat "$T/calls")"
bm --last-good --no-reboot && called "slots check golden" && called "slots restore" && called "bootok --reset" && ok "--last-good: copies the golden slots, then resets" || bad "--last-good: $(cat "$T/calls")"
FAKE_BAD=golden bm --last-good --no-reboot && bad "--last-good with bad golden slots: no refusal" || { ! called "slots restore" && ! called "bootok --reset" && ok "--last-good with bad golden slots: refused" || bad "--last-good: did something"; }
FAKE_RESTORE_FAIL=1 bm --last-good --no-reboot && bad "a failed copy passed" || { ! called "bootok --reset" && ok "--last-good: a failed copy: counters stay" || bad "counters written after a failed copy"; }
FAKE_BAD=normal bm --no-reboot && bad "normal slots without rescue support: no refusal" || { ! called "bootok --reset" && ok "bad normal slots: refused, counters stay" || bad "bad normal: counters written"; }
FAKE_BAD=normal bm --force --no-reboot && called "bootok --reset" && ok "--force: resets anyway" || bad "--force: $(cat "$T/out")"
FAKE_BOOTOK_RC=1 TSX_REBOOT="$T/bin/reboot -f" bm && bad "a failed reset passed" || { ! called "reboot -f" && ok "a failed reset: no reboot" || bad "rebooted after a failed reset"; }

echo "== tsx-restore-stock"
# pat FILE TAG OFF LEN: a tag-specific pattern
pat() { yes "$2" | head -c "$4" | dd of="$1" bs=4096 seek=$(($3 / 4096)) conv=notrunc 2>/dev/null; }
rsha() { dd if="$1" bs=4096 skip=$(($2 / 4096)) count=$(($3 / 4096)) 2>/dev/null | sha256sum | cut -d' ' -f1; }
# mbr FILE DISKID START SIZE: one partition
mbr() {
	python3 - "$@" <<'PY'
import struct, sys
f, did, start, size = sys.argv[1], int(sys.argv[2], 0), int(sys.argv[3]), int(sys.argv[4])
b = bytearray(open(f, "rb").read(512))
b[440:444] = struct.pack("<I", did)
b[446:510] = bytes(64)
b[446 + 4] = 0x83
b[446 + 8:446 + 16] = struct.pack("<II", start, size)
b[510:512] = b"\x55\xaa"
with open(f, "r+b") as o:
	o.write(b)
PY
}
mkcard() {   # the TSX card: 24 MiB, the U-Boot pattern "uboot"
	rm -f "$T/card"; truncate -s $((24 * MB)) "$T/card"
	pat "$T/card" card-all 0 $((24 * MB))
	pat "$T/card" uboot $((0x1000)) $((0xC0000 - 0x1000))
	dd if=/dev/zero of="$T/card" bs=1024 seek=1 count=3 conv=notrunc 2>/dev/null
	pat "$T/card" card-env $((0xC0000)) $((0x20000))
	mbr "$T/card" 0x7458a050 32768 8192
	cp "$T/card" "$T/card.orig"
}
mkdump() {   # the stock dump: 16 MiB, the same U-Boot, partitions end at 16 MiB
	rm -f "$T/dump"; truncate -s $((16 * MB)) "$T/dump"
	pat "$T/dump" stock-all 0 $((16 * MB))
	pat "$T/dump" "${1:-uboot}" $((0x1000)) $((0xC0000 - 0x1000))
	dd if=/dev/zero of="$T/dump" bs=1024 seek=1 count=3 conv=notrunc 2>/dev/null
	pat "$T/dump" stock-env $((0xC0000)) $((0x20000))
	mbr "$T/dump" "${2:-0x0a0b0c0d}" 2048 $((14 * 2048))
}
rs() { : > "$T/calls"; mkdir -p "$T/run"
	TSX_CARD_DEV=$T/card TSX_BOOT_OK=$T/bin/bootok TSX_RUN=$T/run busybox sh "$RS" "$@" > "$T/out" 2>&1; }
mkcard; mkdump
if rs --yes "$T/dump"; then ok "a file: exit 0"; else bad "a file: $(cat "$T/out")"; fi
[ "$(rsha "$T/card" 0 4096 | cut -c1-8)" ] && [ "$(dd if="$T/card" bs=1024 count=1 2>/dev/null | sha256sum)" = "$(dd if="$T/dump" bs=1024 count=1 2>/dev/null | sha256sum)" ] && ok "the MBR of the dump" || bad "the MBR"
[ "$(rsha "$T/card" $((0x1000)) $((0xDF000)))" = "$(rsha "$T/card.orig" $((0x1000)) $((0xDF000)))" ] && ok "the U-Boot and env range is not written" || bad "the U-Boot range changed"
[ "$(rsha "$T/card" $((0xE0000)) $((16 * MB - 0xE0000)))" = "$(rsha "$T/dump" $((0xE0000)) $((16 * MB - 0xE0000)))" ] && ok "the rest of the dump" || bad "the rest of the dump"
[ "$(rsha "$T/card" $((16 * MB)) $((8 * MB)))" = "$(rsha "$T/card.orig" $((16 * MB)) $((8 * MB)))" ] && ok "the bytes after the dump stay" || bad "bytes after the dump changed"
called "bootok --stock" && ok "the counters to the stock values (tsx-boot-ok --stock)" || bad "no tsx-boot-ok --stock"
mkcard
rs --yes - < "$T/dump" && [ "$(rsha "$T/card" $((0xE0000)) $((16 * MB - 0xE0000)))" = "$(rsha "$T/dump" $((0xE0000)) $((16 * MB - 0xE0000)))" ] && ok "stdin" || bad "stdin: $(cat "$T/out")"
mkcard; gzip -c "$T/dump" > "$T/dump.img.gz"
rs --yes "$T/dump.img.gz" && [ "$(rsha "$T/card" $((0xE0000)) $((16 * MB - 0xE0000)))" = "$(rsha "$T/dump" $((0xE0000)) $((16 * MB - 0xE0000)))" ] && ok "a .gz file" || bad "gz: $(cat "$T/out")"
refuse() {   # refuse WHAT TEXT
	if rs --yes "$T/dump"; then bad "$1: no refusal"
	elif cmp -s "$T/card" "$T/card.orig" && grep -q "$2" "$T/out"; then ok "$1: refused, card unchanged"
	else bad "$1: $(cat "$T/out")"; fi
}
mkcard; mkdump other-uboot; refuse "another U-Boot" "differs from the U-Boot"
mkcard; mkdump uboot 0x7458a050; refuse "a TSX - LINUX card as the dump" "not the stock card"
mkcard; mkdump; mbr "$T/dump" 0x0a0b0c0d 2048 $((40 * 2048)); refuse "partitions larger than the card" "the card has"
mkcard; mkdump; head -c 4096 "$T/dump" > "$T/d2"; mv "$T/d2" "$T/dump"; refuse "a short dump" "shorter than"
mkcard; mkdump
rs "$T/dump" < /dev/null && bad "no --yes and no terminal: no refusal" || { cmp -s "$T/card" "$T/card.orig" && ok "no --yes and no terminal: refused" || bad "no --yes: card changed"; }

echo "== $N passed, $F failed"
[ "$F" = 0 ]
