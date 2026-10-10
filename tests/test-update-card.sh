#!/bin/sh
# Host test of image/update-card.sh. It makes small fake card images with the
# layout of image/mkcard.sh (MBR, a made-up U-Boot and env, the kernel slots,
# p1, p2, p3), and runs the script on image files. It needs no root and
# writes no /dev file. It checks:
#  - an update writes the normal kernel slots and p2, and keeps the MBR, the
#    U-Boot and env range, the gap, the golden slots, p1 and p3 byte for
#    byte. --all-slots also writes the golden slots.
#  - a .img.gz with a .sha256 file works, a wrong checksum is refused
#  - the refusals: p2 start differs, new p2 larger, p3 too near, wrong disk
#    id (and --force-id), no p3 (and --no-data), no partition table, no
#    "yes", the dry run. A refused run does not change the target.
#  - the read-back check compares the sha256 of each written range (every
#    normal run shows it; a target that drops writes needs root to fake)
#  - a target with a larger p2: the new file system grows to fill p2 and
#    p3 stays (needs mke2fs, e2fsck, resize2fs, dumpe2fs and debugfs)
#  - the mount check (is_mounted) with made-up mount lists
# Run it with: sh tests/test-update-card.sh (or busybox sh, or dash).
# Env: TEST_SH  the shell that runs update-card.sh (default: sh)
set -eu
PATH=$PATH:/sbin:/usr/sbin
HERE=$(cd "$(dirname "$0")/.." && pwd)
UC=$HERE/image/update-card.sh
TEST_SH=${TEST_SH:-sh}
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
N=0 F=0
ok()  { N=$((N + 1)); echo "  ok: $*"; }
bad() { F=$((F + 1)); echo "  FAIL: $*"; }
check() { # description, command...
	_d=$1; shift
	if "$@"; then ok "$_d"; else bad "$_d"; fi
}

for t in sfdisk truncate dd sha256sum gzip od; do
	command -v $t >/dev/null 2>&1 || { echo "SKIP: the tool $t is missing"; exit 0; }
done

# ---- helpers ------------------------------------------------------------------
KB=1024 MB=1048576
SL_IN_N=$((0x100000)) SL_IN_G=$((0x200000)) SL_KN_N=$((0x800000)) SL_KN_G=$((0xC00000))
P1_START=32768 P1_SIZE=2048
P2_START=34816
NEW_P2=16384	# 8 MiB

pat() { # file tag offset length: write a repeating, tag-specific pattern
	yes "$2" | head -c "$4" | dd of="$1" bs=512 seek=$(($3 / 512)) conv=notrunc 2>/dev/null
}
rsha() { # file offset length
	dd if="$1" bs=512 skip=$(($2 / 512)) count=$(($3 / 512)) 2>/dev/null | sha256sum | cut -d' ' -f1
}
le32() {
	printf "$(printf '\\%03o\\%03o\\%03o\\%03o' $(($1 & 255)) $(($1 >> 8 & 255)) $(($1 >> 16 & 255)) $(($1 >> 24 & 255)))"
}
# mkimg FILE TAG ID P2SIZE P3START P3SIZE [P2START]   (P3SIZE 0: no p3)
# TAG makes the bytes of every range different from the other images.
mkimg() {
	_f=$1 _tag=$2 _id=$3 _p2s=$4 _p3st=$5 _p3s=$6 _p2st=${7:-$P2_START}
	if [ "$_p3s" -gt 0 ]; then _end=$((_p3st + _p3s)); else _end=$((_p2st + _p2s)); fi
	rm -f "$_f"; truncate -s $((_end * 512)) "$_f"
	{
		printf 'label: dos\nlabel-id: %s\nunit: sectors\n\n' "$_id"
		printf 'start=%s, size=%s, type=e\n' $P1_START $P1_SIZE
		printf 'start=%s, size=%s, type=83\n' "$_p2st" "$_p2s"
		[ "$_p3s" -le 0 ] || printf 'start=%s, size=%s, type=83\n' "$_p3st" "$_p3s"
	} | sfdisk -q --wipe never --wipe-partitions never "$_f"
	pat "$_f" "$_tag-uboot-and-env" $((0x400)) $((0xE0000 - 0x400))
	pat "$_f" "$_tag-initrd-normal" $SL_IN_N $MB
	pat "$_f" "$_tag-initrd-golden" $SL_IN_G $MB
	pat "$_f" "$_tag-uimage-normal" $SL_KN_N $((4 * MB))
	pat "$_f" "$_tag-uimage-golden" $SL_KN_G $((4 * MB))
	pat "$_f" "$_tag-gap" $((0x300000)) $((0x100000))
	pat "$_f" "$_tag-p1" $((P1_START * 512)) $((P1_SIZE * 512))
	pat "$_f" "$_tag-p2" $((_p2st * 512)) $((_p2s * 512))
	[ "$_p3s" -le 0 ] || pat "$_f" "$_tag-p3-the-data-of-the-user" $((_p3st * 512)) $((_p3s * 512))
	return 0
}
ID=0x7458a050
OLD_P3=$((P2_START + NEW_P2))	# sector of p3 when the old p2 has the new size
P3SIZE=4096

# Ranges for the checks (bytes).
R_GAP="$((0x300000)) $((0x500000))"
R_P1="$((P1_START * 512)) $((P1_SIZE * 512))"
same() { # description file-a file-b offset length
	[ "$(rsha "$2" "$4" "$5")" = "$(rsha "$3" "$4" "$5")" ] && ok "$1" || bad "$1"
}
differs() {
	[ "$(rsha "$2" "$4" "$5")" != "$(rsha "$3" "$4" "$5")" ] && ok "$1" || bad "$1"
}
whole() { sha256sum < "$1" | cut -d' ' -f1; }
run() { # args of update-card.sh. Sets RC, the output is in $T/out
	RC=0
	$TEST_SH "$UC" "$@" > "$T/out" 2>&1 < /dev/null || RC=$?
}
runin() { # input, then args
	_in=$1; shift
	RC=0
	printf '%s\n' "$_in" | $TEST_SH "$UC" "$@" > "$T/out" 2>&1 || RC=$?
}
refused() { # description, text that the output must have; the target is unchanged
	if [ "$RC" -eq 1 ] && grep -q "REFUSED" "$T/out" && grep -q -e "$2" "$T/out" && [ "$(whole "$TGT")" = "$BEFORE" ]; then
		ok "$1"
	else
		bad "$1 (rc=$RC)"; sed 's/^/      | /' "$T/out"
	fi
}
fresh_target() { # a copy of the old card
	cp "$T/old.img" "$T/tgt.img"; TGT=$T/tgt.img; BEFORE=$(whole "$TGT")
}

# ---- the images ---------------------------------------------------------------
echo "== make the fake cards =="
mkimg "$T/new.img" new $ID $NEW_P2 $((P2_START + NEW_P2)) 2048
mkimg "$T/old.img" old $ID $NEW_P2 $OLD_P3 $P3SIZE
check "the old and the new image differ in the slots" test "$(rsha "$T/new.img" $SL_KN_N 4096)" != "$(rsha "$T/old.img" $SL_KN_N 4096)"
UCARGS="--yes"

echo "== usage =="
run
[ "$RC" -eq 2 ] && grep -q "update-card.sh \[options\]" "$T/out" && ok "no arguments: usage, exit 2" || bad "no arguments (rc=$RC)"

echo "== update of a card with the same p2 size =="
fresh_target
run $UCARGS "$T/new.img" "$TGT"
check "exit 0" test "$RC" -eq 0
grep -q "ok   p2-tsxroot" "$T/out" && ok "read-back lines in the output" || bad "read-back lines"
same "kept: MBR, U-Boot and env, up to the slots" "$TGT" "$T/old.img" 0 $SL_IN_N
same "kept: the gap between the slots" "$TGT" "$T/old.img" $R_GAP
same "kept: p1" "$TGT" "$T/old.img" $R_P1
same "kept: p3" "$TGT" "$T/old.img" $((OLD_P3 * 512)) $((P3SIZE * 512))
same "written: uInitrd normal" "$TGT" "$T/new.img" $SL_IN_N $MB
same "kept: uInitrd golden" "$TGT" "$T/old.img" $SL_IN_G $MB
same "written: uImage normal" "$TGT" "$T/new.img" $SL_KN_N $((4 * MB))
same "kept: uImage golden" "$TGT" "$T/old.img" $SL_KN_G $((4 * MB))
same "written: p2" "$TGT" "$T/new.img" $((P2_START * 512)) $((NEW_P2 * 512))
differs "p2 changed" "$TGT" "$T/old.img" $((P2_START * 512)) $((NEW_P2 * 512))
check "the file size is unchanged" test "$(wc -c < "$TGT")" -eq "$(wc -c < "$T/old.img")"
grep -q "p3 kept" "$T/out" && ok "final line says p3 kept" || bad "final line"

echo "== --all-slots =="
fresh_target
run $UCARGS --all-slots "$T/new.img" "$TGT"
check "--all-slots: exit 0" test "$RC" -eq 0
same "--all-slots: uInitrd golden written" "$TGT" "$T/new.img" $SL_IN_G $MB
same "--all-slots: uImage golden written" "$TGT" "$T/new.img" $SL_KN_G $((4 * MB))
same "--all-slots: uImage normal written" "$TGT" "$T/new.img" $SL_KN_N $((4 * MB))
same "--all-slots: p3 kept" "$TGT" "$T/old.img" $((OLD_P3 * 512)) $((P3SIZE * 512))

echo "== gz image and checksum =="
cp "$T/new.img" "$T/nn.img"; gzip -k -f "$T/nn.img"
(cd "$T" && sha256sum nn.img.gz > nn.img.gz.sha256)
fresh_target
run $UCARGS --tmpdir "$T" "$T/nn.img.gz" "$TGT"
check "gz: exit 0" test "$RC" -eq 0
grep -q "sha256 ok" "$T/out" && ok "gz: checksum verified" || bad "gz: checksum"
same "gz: p2 written" "$TGT" "$T/new.img" $((P2_START * 512)) $((NEW_P2 * 512))
same "gz: p3 kept" "$TGT" "$T/old.img" $((OLD_P3 * 512)) $((P3SIZE * 512))
check "gz: the temporary image is removed" test -z "$(ls "$T" | grep '^update-card\.' || true)"
fresh_target
cp "$T/nn.img.gz.sha256" "$T/bad.sha256"; sed -i 's/^./X/' "$T/bad.sha256"
run $UCARGS --sha256 "$T/bad.sha256" "$T/nn.img.gz" "$TGT"
[ "$RC" -eq 1 ] && grep -q "does not match" "$T/out" && [ "$(whole "$TGT")" = "$BEFORE" ] && ok "wrong checksum: refused, target unchanged" || bad "wrong checksum (rc=$RC)"
fresh_target
run $UCARGS "$T/new.img" "$TGT"
grep -q "WARNING: no checksum" "$T/out" && ok "no .sha256 file: warning" || bad "no .sha256 warning"

echo "== refusals =="
mkimg "$T/other-start.img" new $ID $NEW_P2 $((P2_START + 2048 + NEW_P2)) 2048 $((P2_START + 2048))
fresh_target
run $UCARGS "$T/other-start.img" "$TGT"
refused "p2 start differs" "starts at sector"

mkimg "$T/big.img" new $ID $((NEW_P2 + 2048)) $((P2_START + NEW_P2 + 2048)) 2048
fresh_target
run $UCARGS "$T/big.img" "$TGT"
refused "new p2 larger than the p2 of the target" "is larger than the p2"

fresh_target
# p3 of the target starts 4000 sectors before the end of the new p2.
le32 $((P2_START + NEW_P2 - 4000)) | dd of="$TGT" bs=1 seek=$((446 + 32 + 8)) conv=notrunc 2>/dev/null
BEFORE=$(whole "$TGT")
run $UCARGS "$T/new.img" "$TGT"
refused "p3 starts before the end of the new p2" "starts before the end"

mkimg "$T/id.img" old 0x11111111 $NEW_P2 $OLD_P3 $P3SIZE
cp "$T/id.img" "$T/tgt.img"; TGT=$T/tgt.img; BEFORE=$(whole "$TGT")
run $UCARGS "$T/new.img" "$TGT"
refused "target with another disk id" "disk id of the target"
run $UCARGS --force-id "$T/new.img" "$TGT"
check "--force-id: exit 0" test "$RC" -eq 0
same "--force-id: p2 written" "$TGT" "$T/new.img" $((P2_START * 512)) $((NEW_P2 * 512))
same "--force-id: p3 kept" "$TGT" "$T/id.img" $((OLD_P3 * 512)) $((P3SIZE * 512))

mkimg "$T/newid.img" new 0x22222222 $NEW_P2 $OLD_P3 2048
fresh_target
run $UCARGS "$T/newid.img" "$TGT"
refused "new image with another disk id" "disk id of the new image"

mkimg "$T/nop3.img" old $ID $NEW_P2 0 0
cp "$T/nop3.img" "$T/tgt.img"; TGT=$T/tgt.img; BEFORE=$(whole "$TGT")
run $UCARGS "$T/new.img" "$TGT"
refused "target with no p3" "no p3"
run $UCARGS --no-data "$T/new.img" "$TGT"
check "--no-data: exit 0" test "$RC" -eq 0
same "--no-data: p2 written" "$TGT" "$T/new.img" $((P2_START * 512)) $((NEW_P2 * 512))
same "--no-data: uImage normal written" "$TGT" "$T/new.img" $SL_KN_N $((4 * MB))
same "--no-data: uImage golden kept" "$TGT" "$T/nop3.img" $SL_KN_G $((4 * MB))
same "--no-data: p1 kept" "$TGT" "$T/nop3.img" $R_P1
check "--no-data: the file did not grow" test "$(wc -c < "$TGT")" -eq "$(wc -c < "$T/nop3.img")"

truncate -s $((OLD_P3 * 512 + P3SIZE * 512)) "$T/blank.img"
cp "$T/blank.img" "$T/tgt.img"; TGT=$T/tgt.img; BEFORE=$(whole "$TGT")
run $UCARGS "$T/new.img" "$TGT"
[ "$RC" -eq 1 ] && grep -q "MBR signature" "$T/out" && [ "$(whole "$TGT")" = "$BEFORE" ] && ok "target with no partition table: refused" || bad "no partition table (rc=$RC)"

fresh_target
run $UCARGS "$T/new.img" "$T/nonexistent.img"
[ "$RC" -eq 1 ] && grep -q "does not exist" "$T/out" && ok "missing target: error" || bad "missing target (rc=$RC)"
run $UCARGS "$T/new.img" "$T/new.img"
[ "$RC" -eq 1 ] && grep -q "same file" "$T/out" && ok "image = target: error" || bad "image = target (rc=$RC)"

echo "== confirmation and dry run =="
fresh_target
runin "no" "$T/new.img" "$TGT"
[ "$RC" -eq 1 ] && [ "$(whole "$TGT")" = "$BEFORE" ] && grep -q "Nothing was written" "$T/out" && ok "answer no: nothing written" || bad "answer no (rc=$RC)"
runin "" "$T/new.img" "$TGT"
[ "$RC" -eq 1 ] && [ "$(whole "$TGT")" = "$BEFORE" ] && ok "no input: nothing written" || bad "no input (rc=$RC)"
run --dry-run "$T/new.img" "$TGT"
[ "$RC" -eq 0 ] && [ "$(whole "$TGT")" = "$BEFORE" ] && grep -q "dry run" "$T/out" && ok "--dry-run: plan shown, nothing written" || bad "--dry-run (rc=$RC)"
grep -q "0x00800000" "$T/out" && grep -q "p2-tsxroot" "$T/out" && ok "the plan lists offsets and sizes" || bad "plan lines"
runin "yes" "$T/new.img" "$TGT"
[ "$RC" -eq 0 ] && same "answer yes: p2 written" "$TGT" "$T/new.img" $((P2_START * 512)) $((NEW_P2 * 512)) || bad "answer yes (rc=$RC)"

echo "== mount check =="
(
	UPDATE_CARD_LIB=1; export UPDATE_CARD_LIB
	. "$UC"
	printf '/dev/sdb1 /mnt ext4 rw 0 0\n/dev/mmcblk0p2 / ext4 rw 0 0\n/dev/loop10p1 /x ext4 rw 0 0\nproc /proc proc rw 0 0\n' > "$T/mounts"
	printf 'Filename Type Size Used Priority\n/dev/sdc2 partition 1000 0 -2\n' > "$T/swaps"
	UPDATE_CARD_MOUNTS="$T/mounts $T/swaps"
	m() { is_mounted "$1"; }
	m /dev/sdb && echo "ok sdb" || echo "FAIL sdb mounted"
	m /dev/mmcblk0 && echo "ok mmcblk0" || echo "FAIL mmcblk0 mounted"
	m /dev/sdc && echo "ok sdc" || echo "FAIL sdc swap"
	m /dev/loop10 && echo "ok loop10" || echo "FAIL loop10 mounted"
	m /dev/loop1 && echo "FAIL loop1 not mounted" || echo "ok loop1"
	m /dev/sd && echo "FAIL sd not mounted" || echo "ok sd"
	m /dev/sdd && echo "FAIL sdd not mounted" || echo "ok sdd"
	m /dev/mmcblk1 && echo "FAIL mmcblk1 not mounted" || echo "ok mmcblk1"
) > "$T/m.out" 2>&1 || true
while read -r st what; do
	case $st in ok) ok "is_mounted: $what" ;; *) bad "is_mounted: $what" ;; esac
done < "$T/m.out"
[ -s "$T/m.out" ] || bad "is_mounted: no output"

echo "== larger p2 on the target: grow the file system =="
if command -v mke2fs >/dev/null 2>&1 && command -v e2fsck >/dev/null 2>&1 && command -v resize2fs >/dev/null 2>&1 &&
	command -v dumpe2fs >/dev/null 2>&1 && command -v debugfs >/dev/null 2>&1; then
	OLD_P2=24576	# 12 MiB
	mkdir "$T/rootdir"; echo "new-root-marker" > "$T/rootdir/marker"
	mkimg "$T/newfs.img" new $ID $NEW_P2 $((P2_START + NEW_P2)) 2048
	rm -f "$T/p2.ext4"; truncate -s $((NEW_P2 * 512)) "$T/p2.ext4"
	mke2fs -q -t ext4 -F -L tsxroot -d "$T/rootdir" "$T/p2.ext4" >/dev/null 2>&1
	dd if="$T/p2.ext4" of="$T/newfs.img" bs=512 seek=$P2_START conv=notrunc 2>/dev/null
	mkimg "$T/oldbig.img" old $ID $OLD_P2 $((P2_START + OLD_P2)) $P3SIZE
	cp "$T/oldbig.img" "$T/tgt.img"; TGT=$T/tgt.img
	run $UCARGS "$T/newfs.img" "$TGT"
	if [ "$RC" -eq 0 ]; then ok "exit 0"; else bad "exit 0 (rc=$RC)"; sed 's/^/      | /' "$T/out"; fi
	grep -q "grow the file system of p2" "$T/out" && ok "the output shows the grow step" || bad "grow step"
	same "p3 kept" "$TGT" "$T/oldbig.img" $(((P2_START + OLD_P2) * 512)) $((P3SIZE * 512))
	same "p1 kept" "$TGT" "$T/oldbig.img" $R_P1
	same "uImage normal written" "$TGT" "$T/newfs.img" $SL_KN_N $((4 * MB))
	dd if="$TGT" of="$T/p2.after" bs=512 skip=$P2_START count=$OLD_P2 2>/dev/null
	BC=$(dumpe2fs -h "$T/p2.after" 2>/dev/null | awk -F: '/^Block count/ {gsub(/ /, "", $2); print $2}')
	BS=$(dumpe2fs -h "$T/p2.after" 2>/dev/null | awk -F: '/^Block size/ {gsub(/ /, "", $2); print $2}')
	[ "$((BC * BS))" -eq $((OLD_P2 * 512)) ] && ok "the file system fills the 12 MiB p2 ($BC blocks of $BS)" || bad "file system size: ${BC:-?} x ${BS:-?}"
	[ "$(debugfs -R 'cat /marker' "$T/p2.after" 2>/dev/null)" = "new-root-marker" ] && ok "the marker file of the new root is there" || bad "marker file"
	e2fsck -f -n "$T/p2.after" >/dev/null 2>&1 && ok "e2fsck: the file system is clean" || bad "e2fsck after the grow"
	# Same size p2 with a file system: no grow step.
	mkimg "$T/oldeq.img" old $ID $NEW_P2 $((P2_START + NEW_P2)) $P3SIZE
	cp "$T/oldeq.img" "$T/tgt2.img"
	run $UCARGS "$T/newfs.img" "$T/tgt2.img"
	if [ "$RC" -eq 0 ] && ! grep -q "grow the file system" "$T/out"; then ok "same p2 size: no grow step"; else bad "same p2 size: grow step shown (rc=$RC)"; fi
else
	echo "  SKIP: mke2fs, e2fsck, resize2fs, dumpe2fs or debugfs is missing"
fi

echo
echo "$N checks passed, $F failed"
[ "$F" -eq 0 ]
