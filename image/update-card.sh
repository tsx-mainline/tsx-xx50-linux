#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# Write a new xx50 card image onto an existing card and keep the data.
#
#   image/update-card.sh [options] <new-image> <target>
#
# <new-image>  the card image from image/mkcard.sh: NAME.img or NAME.img.gz.
#              If NAME.img.sha256 or NAME.img.gz.sha256 is next to it, the
#              script checks the file against it. A .gz image needs free
#              space in the temporary directory for the unpacked image.
# <target>     the card: a block device (/dev/sdX, /dev/mmcblkN) or a card
#              image file (for tests). Do not give a partition.
#
# Options:
#   --yes, -y     do not ask for "yes"
#   --dry-run, -n do all checks, show the plan, write nothing
#   --no-data     accept a target that has no p3 (no data partition)
#   --force-id    accept a disk id other than 0x7458a050
#   --tmpdir DIR  where the script unpacks a .gz image (default: $TMPDIR, /tmp)
#   --sha256 FILE the checksum file of <new-image> (default: <new-image>.sha256)
#   --all-slots   also write the golden slots (for a card with no good kernel
#                 in its golden slots)
#
# The script writes these ranges from the new image to the same offsets of
# the target, and nothing else:
#   0x100000  uInitrd, normal slot, 1 MiB
#   0x800000  uImage, normal slot, 4 MiB
#   p2        tsxroot, the root file system (start and size of the new image)
#   0x200000  uInitrd, golden slot, 1 MiB   (only with --all-slots)
#   0xC00000  uImage, golden slot, 4 MiB    (only with --all-slots)
# The script keeps these ranges of the target as they are: the MBR, the stock
# U-Boot and its env (0x400 to 0xE0000), the golden slots, p1 (TSXLOG) and p3
# (tsxdata, /data). So the settings, the layout, the keys and the logs on p3
# stay. The golden slots keep the last good kernel: U-Boot boots them after
# two failed boots of the normal slots. After good boots of the new kernel,
# "tsx-kernel-slots promote" on the panel copies it to the golden slots.
#
# The script refuses to write when:
#   - the new image has no valid p2, or is shorter than its p2
#   - the p2 of the new image starts at another sector than the p2 of the
#     target, or is larger than the p2 of the target
#   - p3 of the target starts before the end of the new p2
#   - the target has no p3 and --no-data is not set
#   - a partition of the target is mounted or is swap
#   - the disk id of the new image or of the target is not 0x7458a050
#     and --force-id is not set
#   - the target has a partition below 16 MiB (the slots would overwrite it)
#
# After the write, the script reads each written range back from the target
# and compares its sha256 with the same range of the new image. A card is
# bootable again only after the script ends without error. If it stops in the
# middle of a write, run it again with the same arguments.
#
# If p2 of the target is larger than the new p2, the new file system is
# smaller than the partition. After the read-back check, the script runs
# e2fsck -f -y and resize2fs on p2, to fill the partition. Only p2 changes,
# p3 does not move. This step needs e2fsck and resize2fs, and the script
# checks for them before it writes. For a card, the tools work on the p2
# device (/dev/sdX2 or /dev/mmcblkNp2). For an image file, the script copies
# p2 to a file in the temporary directory, grows the file system there, and
# writes the copy back with a second read-back check. This needs no root and
# free space of the size of p2 in the temporary directory. (resize2fs on a
# file with an offset would cut the file, so the script does not use it.)
#
# Needs: sh, dd, od, awk, sha256sum, gzip (for .gz), readlink, mktemp. Writing
# to a block device needs root. Progress shows as MiB and percent.
set -eu
PATH=$PATH:/sbin:/usr/sbin
export PATH

DISK_ID=$((0x7458a050))
MIB=1048576
CHUNK=$((16 * MIB))
RAW_END=$((32768))	# sectors: no partition may start below 16 MiB

usage() { awk 'NR > 2 && !/^#/ {exit} NR > 2 {sub(/^# ?/, ""); print}' "$0"; }
die() { echo "ERROR: $*" >&2; exit 1; }
say() { echo "== $*"; }

# ---- the partition table (read from the MBR bytes, no sfdisk needed) ------
# parse_mbr FILE PREFIX sets PREFIX_sig PREFIX_id and, for n = 1 to 4,
# PREFIX_type<n> PREFIX_start<n> PREFIX_size<n> (sectors).
parse_mbr() {
	_f=$1 _p=$2
	set -- $(dd if="$_f" bs=512 count=1 2>/dev/null | od -An -v -tu1)
	[ $# -eq 512 ] || die "cannot read the first sector of $_f"
	eval "${_p}_sig=$((${511} * 256 + ${512}))"
	shift 440
	eval "${_p}_id=$(($1 + $2 * 256 + $3 * 65536 + $4 * 16777216))"
	shift 6
	for _n in 1 2 3 4; do
		eval "${_p}_type$_n=$5"
		eval "${_p}_start$_n=$((${9} + ${10} * 256 + ${11} * 65536 + ${12} * 16777216))"
		eval "${_p}_size$_n=$((${13} + ${14} * 256 + ${15} * 65536 + ${16} * 16777216))"
		shift 16
	done
}

# ---- mounted? ---------------------------------------------------------------
# is_mounted DEVICE: succeed if DEVICE or one of its partitions is a source in
# the mount lists. A disk name that ends in a digit has partitions with "p".
is_mounted() {
	awk -v dev="$1" '
		BEGIN { pat = (dev ~ /[0-9]$/) ? "^" dev "p[0-9]+$" : "^" dev "[0-9]+$" }
		$1 == dev || $1 ~ pat { f = 1 }
		END { exit !f }' ${UPDATE_CARD_MOUNTS:-/proc/mounts /proc/swaps} 2>/dev/null
}

# ---- copy and hash with live progress -------------------------------------
progress() { # label done total
	_d=$(($2 / MIB)) _t=$(($3 / MIB))
	[ "$3" -gt 0 ] || return 0
	_pc=$(($2 * 100 / $3))
	if [ -t 2 ]; then
		printf '\r   %-26s %5d of %d MiB  %3d%%' "$1" "$_d" "$_t" "$_pc" >&2
		[ "$2" -lt "$3" ] || printf '\n' >&2
	elif [ "$_pc" -ge "${_next:-0}" ] || [ "$2" -ge "$3" ]; then
		printf '   %-26s %5d of %d MiB  %3d%%\n' "$1" "$_d" "$_t" "$_pc" >&2
		_next=$((_pc / 10 * 10 + 10))
	fi
}

# piece SRC DST SOFF DOFF LEN: copy LEN bytes from byte offset SOFF of SRC to
# byte offset DOFF of DST. DST "-" is stdout. Block sizes: 1 MiB while it
# fits, then 512, then single bytes.
piece() {
	_s=$1 _o=$2 _sp=$3 _dp=$4 _n=$5
	for _b in $MIB 512 1; do
		_k=$((_n / _b * _b))
		[ "$_k" -gt 0 ] && [ $((_sp % _b)) -eq 0 ] && [ $((_dp % _b)) -eq 0 ] || continue
		if [ "$_o" = "-" ]; then
			dd if="$_s" bs=$_b skip=$((_sp / _b)) count=$((_k / _b)) status=none || return 1
		else
			dd if="$_s" of="$_o" bs=$_b skip=$((_sp / _b)) seek=$((_dp / _b)) \
				count=$((_k / _b)) conv=$CONV status=none || return 1
		fi
		_sp=$((_sp + _k)) _dp=$((_dp + _k)) _n=$((_n - _k))
	done
}

# copy_range LABEL SRC DST SOFF DOFF LEN: copy in chunks, show progress.
copy_range() {
	_lbl=$1 _src=$2 _dst=$3 _soff=$4 _doff=$5 _len=$6
	_next=0 _done=0
	progress "$_lbl" 0 "$_len"
	while [ "$_done" -lt "$_len" ]; do
		_c=$((_len - _done))
		[ "$_c" -le "$CHUNK" ] || _c=$CHUNK
		piece "$_src" "$_dst" $((_soff + _done)) $((_doff + _done)) "$_c" || return 1
		_done=$((_done + _c))
		progress "$_lbl" "$_done" "$_len"
	done
}

# hash_range LABEL FILE OFF LEN: print the sha256 of the byte range.
hash_range() {
	copy_range "$1" "$2" - "$3" "$3" "$4" | sha256sum | cut -d' ' -f1
}

file_bytes() { # file or block device
	if [ -b "$1" ]; then
		blockdev --getsize64 "$1" 2>/dev/null && return 0
		_nm=$(basename "$(readlink -f "$1")")
		echo $(( $(cat "/sys/class/block/$_nm/size") * 512 ))
	else
		wc -c < "$1" | tr -d ' '
	fi
}

# ---- the main program ---------------------------------------------------------
[ -z "${UPDATE_CARD_LIB:-}" ] || return 0

YES=0 DRY=0 NODATA=0 FORCEID=0 ALLSLOTS=0 TMPD=${TMPDIR:-/tmp} SHAFILE=
while [ $# -gt 0 ]; do
	case $1 in
	--yes|-y) YES=1 ;;
	--dry-run|-n) DRY=1 ;;
	--no-data) NODATA=1 ;;
	--force-id) FORCEID=1 ;;
	--all-slots) ALLSLOTS=1 ;;
	--tmpdir) [ $# -ge 2 ] || { usage; exit 2; }; TMPD=$2; shift ;;
	--sha256) [ $# -ge 2 ] || { usage; exit 2; }; SHAFILE=$2; shift ;;
	-h|--help) usage; exit 0 ;;
	--) shift; break ;;
	-*) echo "unknown option: $1" >&2; usage; exit 2 ;;
	*) break ;;
	esac
	shift
done
[ $# -eq 2 ] || { usage; exit 2; }
IMG=$1 TARGET=$2
CONV=fsync
TMPW=
GZPID=
cleanup() {
	[ -z "$GZPID" ] || kill "$GZPID" 2>/dev/null || true
	[ -z "$TMPW" ] || rm -rf "$TMPW"
}
trap cleanup EXIT
trap 'echo "interrupted" >&2; exit 130' INT TERM

for t in dd od awk sha256sum cut readlink mktemp wc; do
	command -v $t >/dev/null 2>&1 || die "the tool $t is missing"
done
[ -f "$IMG" ] || die "$IMG is not a file"
[ -e "$TARGET" ] || die "$TARGET does not exist"
if [ -b "$TARGET" ]; then
	KIND=device
	REAL=$(readlink -f "$TARGET")
	CONV=fsync
	[ ! -e "/sys/class/block/$(basename "$REAL")/partition" ] || die "$TARGET is a partition. Give the whole disk."
	is_mounted "$REAL" && die "$TARGET or one of its partitions is mounted or is swap. Unmount it first."
	[ -w "$TARGET" ] || die "no write access to $TARGET (run as root)"
elif [ -f "$TARGET" ]; then
	KIND=file
	REAL=$(readlink -f "$TARGET")
	CONV=notrunc,fsync
	[ -w "$TARGET" ] || die "no write access to $TARGET"
else
	die "$TARGET is not a block device or a file"
fi
[ "$(readlink -f "$IMG")" != "$REAL" ] || die "the new image and the target are the same file"

# ---- 1. verify and unpack the new image -----------------------------------
[ -n "$SHAFILE" ] || SHAFILE=$IMG.sha256
if [ -r "$SHAFILE" ]; then
	say "check $(basename "$IMG") against $(basename "$SHAFILE")"
	read -r WANT _ < "$SHAFILE" || WANT=
	GOT=$(hash_range "sha256 of the image" "$IMG" 0 "$(file_bytes "$IMG")")
	[ "$GOT" = "$WANT" ] || die "the sha256 of $IMG does not match $SHAFILE (got $GOT)"
	echo "   sha256 ok"
else
	echo "== WARNING: no checksum file ($SHAFILE). The new image is not verified." >&2
fi
SRC=$IMG
case $IMG in
*.gz)
	command -v gzip >/dev/null 2>&1 || die "the tool gzip is missing"
	[ -d "$TMPD" ] && [ -w "$TMPD" ] || die "the temporary directory $TMPD is not writable"
	TMPW=$(mktemp -d "$TMPD/update-card.XXXXXX")
	SRC=$TMPW/new.img
	# The last 4 bytes of a gzip file hold the size of the data (modulo 4 GiB).
	set -- $(tail -c 4 "$IMG" | od -An -v -tu1)
	ISIZE=$(($1 + $2 * 256 + $3 * 65536 + $4 * 16777216))
	if command -v df >/dev/null 2>&1; then
		AVAIL=$(df -Pk "$TMPW" | awk 'NR == 2 {print $4}')
		if [ -n "$AVAIL" ] && [ "$ISIZE" -gt 0 ] && [ $((AVAIL / 1024)) -lt $((ISIZE / MIB + 8)) ]; then
			die "not enough free space in $TMPD: need $((ISIZE / MIB)) MiB, have $((AVAIL / 1024)) MiB (use --tmpdir)"
		fi
	fi
	say "unpack $(basename "$IMG") ($((ISIZE / MIB)) MiB) to $TMPD"
	gzip -dc "$IMG" > "$SRC" &
	GZPID=$!
	T0=$(date +%s)
	while kill -0 "$GZPID" 2>/dev/null; do
		_sz=$(wc -c < "$SRC" 2>/dev/null | tr -d ' ' || echo 0)
		[ "$ISIZE" -le 0 ] || _pc=$((_sz * 100 / ISIZE))
		[ "${_pc:-0}" -le 99 ] || _pc=99
		printf '   unpacked %5d MiB  %3d%%  (%ds)\n' $((_sz / MIB)) "${_pc:-0}" $(($(date +%s) - T0)) >&2
		sleep 2
	done
	if wait "$GZPID"; then GZPID=; else GZPID=; die "gzip could not unpack $IMG"; fi
	echo "   unpacked $(($(file_bytes "$SRC") / MIB)) MiB" ;;
esac

# ---- 2. read both partition tables ---------------------------------------
say "read the partition tables"
parse_mbr "$SRC" N
parse_mbr "$TARGET" T
[ "$N_sig" -eq $((0x55 * 256 + 0xAA)) ] || die "the new image has no MBR signature (is it a card image?)"
[ "$T_sig" -eq $((0x55 * 256 + 0xAA)) ] || die "the target has no MBR signature (no partition table)"
SRC_BYTES=$(file_bytes "$SRC")
TGT_BYTES=$(file_bytes "$TARGET")
printf '   %-8s %12s %12s %12s\n' "" "p2 start" "p2 sectors" "p3 start"
printf '   %-8s %12s %12s %12s\n' new "$N_start2" "$N_size2" "$N_start3"
printf '   %-8s %12s %12s %12s\n' target "$T_start2" "$T_size2" "$T_start3"
printf '   disk id: new 0x%08x, target 0x%08x\n' "$N_id" "$T_id"

# ---- 3. refusals ------------------------------------------------------------
REFUSE=
refuse() { REFUSE="$REFUSE
   - $*"; }
if [ "$FORCEID" -eq 0 ]; then
	[ "$N_id" -eq "$DISK_ID" ] || refuse "the disk id of the new image is not 0x7458a050 (--force-id accepts it)"
	[ "$T_id" -eq "$DISK_ID" ] || refuse "the disk id of the target is not 0x7458a050. It may not be an xx50 card (--force-id accepts it)"
fi
[ "$N_size2" -gt 0 ] && [ "$N_type2" -ne 0 ] || refuse "the new image has no p2"
[ "$T_size2" -gt 0 ] && [ "$T_type2" -ne 0 ] || refuse "the target has no p2"
if [ "$N_size2" -gt 0 ] && [ "$T_size2" -gt 0 ]; then
	[ "$N_start2" -eq "$T_start2" ] || refuse "p2 starts at sector $N_start2 in the new image and at sector $T_start2 on the target"
	[ "$N_size2" -le "$T_size2" ] || refuse "the new p2 ($N_size2 sectors) is larger than the p2 of the target ($T_size2 sectors)"
	[ $(((N_start2 + N_size2) * 512)) -le "$SRC_BYTES" ] || refuse "the new image is shorter than its p2 ($SRC_BYTES bytes)"
	[ $(((T_start2 + T_size2) * 512)) -le "$TGT_BYTES" ] || refuse "the target is smaller than its partition table says ($TGT_BYTES bytes)"
fi
if [ "$T_size3" -gt 0 ] && [ "$T_type3" -ne 0 ]; then
	[ "$N_size2" -le 0 ] || [ "$T_start3" -ge $((N_start2 + N_size2)) ] ||
		refuse "p3 of the target (sector $T_start3) starts before the end of the new p2 (sector $((N_start2 + N_size2)))"
	HAVE_P3=1
else
	HAVE_P3=0
	[ "$NODATA" -eq 1 ] || refuse "the target has no p3 (no data partition). Use --no-data to write it anyway."
fi
for n in 1 2 3 4; do
	eval "_s=\$T_size$n _st=\$T_start$n"
	if [ "$_s" -gt 0 ] && [ "$_st" -lt "$RAW_END" ]; then
		refuse "partition $n of the target starts at sector $_st, below the kernel slots (sector $RAW_END)"
	fi
done
if [ -n "$REFUSE" ]; then
	echo "REFUSED. Nothing was written. Reasons:$REFUSE" >&2
	exit 1
fi

# ---- 4. plan ----------------------------------------------------------------
P2_OFF=$((N_start2 * 512)) P2_LEN=$((N_size2 * 512)) P2_LEN2=$((T_size2 * 512))
RESIZE=0
[ "$N_size2" -eq "$T_size2" ] || RESIZE=1
if [ "$RESIZE" -eq 1 ]; then
	for t in e2fsck resize2fs; do
		command -v $t >/dev/null 2>&1 || die "the p2 of the target is larger than the new p2, and the tool $t is missing"
	done
	if [ "$KIND" = device ]; then
		case $(basename "$REAL") in
		*[0-9]) P2DEV=${REAL}p2 ;;
		*) P2DEV=${REAL}2 ;;
		esac
	else
		# resize2fs would truncate an image file at the new file system size
		# and ignore the offset of p2. So the script grows a copy of p2 and
		# writes the copy back.
		[ -d "$TMPD" ] && [ -w "$TMPD" ] || die "the temporary directory $TMPD is not writable"
		[ -n "$TMPW" ] || TMPW=$(mktemp -d "$TMPD/update-card.XXXXXX")
		AVAIL=$(df -Pk "$TMPW" | awk 'NR == 2 {print $4}')
		[ -z "$AVAIL" ] || [ $((AVAIL / 1024)) -ge $((T_size2 / 2048 + 8)) ] ||
			die "not enough free space in $TMPD for the p2 copy: need $((T_size2 / 2048)) MiB, have $((AVAIL / 1024)) MiB (use --tmpdir)"
	fi
fi
RANGES="initrd-normal:$((0x100000)):$MIB
uImage-normal:$((0x800000)):$((4 * MIB))
p2-tsxroot:$P2_OFF:$P2_LEN"
[ "$ALLSLOTS" -eq 0 ] || RANGES="$RANGES
initrd-golden:$((0x200000)):$MIB
uImage-golden:$((0xC00000)):$((4 * MIB))"
say "plan: write to $TARGET ($KIND, $((TGT_BYTES / MIB)) MiB)"
printf '   %-15s %12s %10s\n' range offset size
echo "$RANGES" | while IFS=: read -r nm off len; do
	printf '   %-15s 0x%08x %7d MiB\n' "$nm" "$off" $((len / MIB))
done
if [ "$ALLSLOTS" -eq 1 ]; then
	echo "   kept as they are: the MBR, the stock U-Boot and env (0x400 to 0xE0000), p1"
else
	echo "   kept as they are: the MBR, the stock U-Boot and env (0x400 to 0xE0000), the golden slots, p1"
fi
if [ "$HAVE_P3" -eq 1 ]; then
	echo "   kept as it is: p3, the data partition (sector $T_start3, $((T_size3 / 2048)) MiB)"
else
	echo "   the target has no p3 (--no-data)"
fi
if [ "$RESIZE" -eq 1 ]; then
	echo "   after the write: e2fsck and resize2fs of p2, from $((N_size2 / 2048)) MiB to $((T_size2 / 2048)) MiB"
fi
[ "$DRY" -eq 0 ] || { say "dry run: nothing written"; exit 0; }
if [ "$YES" -eq 0 ]; then
	printf 'Write this to %s? Type yes: ' "$TARGET" >&2
	ANS=
	read -r ANS || ANS=
	[ "$ANS" = yes ] || die "not confirmed. Nothing was written."
fi

# ---- 5. write ---------------------------------------------------------------
T0=$(date +%s)
say "write"
echo "$RANGES" | {
	while IFS=: read -r nm off len; do
		copy_range "$nm" "$SRC" "$TARGET" "$off" "$off" "$len" || exit 1
	done
}
sync
[ "$KIND" = device ] && command -v blockdev >/dev/null 2>&1 && blockdev --flushbufs "$TARGET" 2>/dev/null || true

# ---- 6. read back and compare --------------------------------------------
say "read back and compare sha256"
BAD=0
for r in $(echo "$RANGES" | tr '\n' ' '); do
	nm=${r%%:*} rest=${r#*:} off=${rest%%:*} len=${rest#*:}
	a=$(hash_range "read $nm (new)" "$SRC" "$off" "$len")
	b=$(hash_range "read $nm (target)" "$TARGET" "$off" "$len")
	if [ "$a" = "$b" ]; then
		echo "   ok   $nm  $a"
	else
		echo "   FAIL $nm  new $a  target $b" >&2
		BAD=1
	fi
done
[ "$BAD" -eq 0 ] || die "the read-back check failed. The card is NOT good. Write it again."

# ---- 7. grow p2 -------------------------------------------------------------
if [ "$RESIZE" -eq 1 ]; then
	say "grow the file system of p2 to $((T_size2 / 2048)) MiB"
	if [ "$KIND" = device ]; then
		blockdev --flushbufs "$P2DEV" 2>/dev/null || true
		[ -b "$P2DEV" ] || die "$P2DEV does not exist. Run e2fsck -f -y and resize2fs on the p2 of the card."
		FS=$P2DEV
	else
		FS=$TMPW/p2.img
		copy_range "copy p2 to a file" "$TARGET" "$FS" "$P2_OFF" 0 "$P2_LEN2"
	fi
	RC=0
	e2fsck -f -y "$FS" || RC=$?
	[ "$RC" -le 1 ] || die "e2fsck failed (exit $RC). The new files are written and the p2 file system keeps its old size."
	resize2fs -p "$FS" ||
		die "resize2fs failed. The new files are written and the p2 file system keeps its old size."
	e2fsck -f -n "$FS" >/dev/null || die "e2fsck found errors after the resize"
	if [ "$KIND" = file ]; then
		copy_range "write the grown p2" "$FS" "$TARGET" 0 "$P2_OFF" "$P2_LEN2"
		[ "$(hash_range "read grown p2 (copy)" "$FS" 0 "$P2_LEN2")" = "$(hash_range "read grown p2 (target)" "$TARGET" "$P2_OFF" "$P2_LEN2")" ] ||
			die "the read-back check of the grown p2 failed. Write the card again."
		rm -f "$FS"
	fi
	sync
fi

say "done in $(($(date +%s) - T0)) s: kernel slots and p2 updated$([ "$HAVE_P3" -eq 1 ] && echo ", p3 kept")"
