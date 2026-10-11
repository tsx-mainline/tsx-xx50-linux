#!/bin/sh
# Host test of the ramdisk program image/initramfs/tsx-xx50-init.c in its
# test mode (not PID 1). It compiles the program in an armv7 Alpine
# container (as image/mkinitrd.sh does) and checks:
#  - --env: the retry counters of a U-Boot env with a good CRC, and the
#    refusal of a bad CRC
#  - --rescue: a rescue slot image (header + gzip cpio) unpacks with its
#    files, directories, symlinks, hard links, device nodes, modes and
#    owners; a damaged archive, a wrong header and a wrong size are refused
#  - --rescue at an offset of a card file (0x300000)
#  - --flag: RESCUE / RESCUE.TXT on the FAT partition, any case, is found,
#    read and deleted; other names are not
#  - --touch: the touch trigger with a fake touch screen and real time: the
#    1.5 s wait for a touch, the 3 s count-down, a lift, a touch after the
#    wait and no touch screen (no wait)
#  - with RESCUE_IMG=<tsx-xx50-rescue.img>: the real rescue system unpacks
#    and has /sbin/init, the rcS and the rescue screen
#
#   tests/test-init.sh
#
# Needs docker and python3 (the env fixtures). It compiles C: run it on a
# build host or in CI.
# Env: ALPINE_IMAGE (default alpine:3.24), RESCUE_IMG.
set -eu
HERE=$(cd "$(dirname "$0")/.." && pwd)
IMAGE=${ALPINE_IMAGE:-alpine:3.24}
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

# mkenv FILE CRC(good|bad) VARS...: a 128 KiB U-Boot env.
mkenv() {
	python3 - "$@" <<'EOF'
import struct, sys, zlib
f, crc, vs = sys.argv[1], sys.argv[2], sys.argv[3:]
data = ("\0".join(vs) + "\0\0").encode().ljust(0x20000 - 4, b"\0")
c = zlib.crc32(data) ^ (0 if crc == "good" else 1)
open(f, "wb").write(struct.pack("<I", c) + data)
EOF
}
mkenv "$T/env-golden" good bootdelay=3 boot_retry=11 golden_boot_retry=2 golden=1 rd_loadaddr=0x70D00000
mkenv "$T/env-normal" good boot_retry=9 golden_boot_retry=0 golden=0
mkenv "$T/env-bad" bad boot_retry=9 golden=1
if [ -n "${RESCUE_IMG:-}" ]; then cp "$RESCUE_IMG" "$T/real-rescue.img"; fi

cat > "$T/run.sh" <<'EOF'
set -u
apk add -q --no-cache build-base linux-headers zlib-dev zlib-static cpio >/dev/null
N=0 F=0
ok()  { N=$((N + 1)); echo "  ok: $*"; }
bad() { F=$((F + 1)); echo "  FAIL: $*"; }
gcc -static -Os -Wall -Wextra -Wno-unused-parameter -Werror -o /t/init /src/image/initramfs/tsx-xx50-init.c -lz \
	&& ok "compiles with -Wall -Wextra -Werror (static, zlib)" || { bad "compile"; exit 1; }

echo "== env"
out=$(/t/init --env /t/env-golden)
[ "$out" = "golden=1 boot_retry=11 golden_boot_retry=2" ] && ok "golden env: $out" || bad "golden env: $out"
out=$(/t/init --env /t/env-normal)
[ "$out" = "golden=0 boot_retry=9 golden_boot_retry=0" ] && ok "normal env: $out" || bad "normal env: $out"
/t/init --env /t/env-bad > /t/o 2>&1 && bad "bad CRC accepted: $(cat /t/o)" || ok "bad CRC: refused"
dd if=/dev/zero of=/t/card bs=1M count=1 2>/dev/null
dd if=/t/env-golden of=/t/card bs=4096 seek=$((0xC0000 / 4096)) conv=notrunc 2>/dev/null
out=$(/t/init --env /t/card 0xC0000)
[ "$out" = "golden=1 boot_retry=11 golden_boot_retry=2" ] && ok "env at 0xC0000 of a card" || bad "env at an offset: $out"

echo "== rescue archive"
S=/t/tree
mkdir -p $S/bin $S/etc/init.d $S/sbin $S/root/.ssh $S/dev $S/empty
printf '#!/bin/sh\necho hi\n' > $S/bin/prog; chmod 4755 $S/bin/prog
echo data > $S/etc/file; chmod 640 $S/etc/file; chown 12:34 $S/etc/file
ln -s /bin/prog $S/sbin/init
echo linked > $S/sbin/a; ln $S/sbin/a $S/sbin/b; ln $S/sbin/a $S/sbin/c
chmod 700 $S/root/.ssh; echo key > $S/root/.ssh/k
mknod $S/dev/console c 5 1
head -c 300000 /dev/urandom > $S/bin/big
# mkslot DIR OUT [VERSION]: the image of image/mkrescue.sh
mkslot() {
	(cd "$1" && find . | sort | cpio -o -H newc --quiet | gzip -9n) > /t/arch.gz
	{ printf 'TSX-RESCUE 1\nsize %s\nversion %s\n' "$(wc -c < /t/arch.gz)" "${3:-test 1}"; head -c 512 /dev/zero; } | head -c 512 > "$2"
	cat /t/arch.gz >> "$2"
}
mkslot $S /t/r.img
rm -rf /t/u; mkdir /t/u
out=$(/t/init --rescue /t/r.img /t/u) && ok "unpack: $out" || bad "unpack: $out"
listing() { (cd "$1" && find . | sort | while read -r p; do
	if [ -L "$p" ]; then echo "$p L $(readlink "$p")"
	elif [ -f "$p" ]; then echo "$p $(stat -c '%a %u %g %h' "$p") $(sha256sum < "$p" | cut -c1-16)"
	else echo "$p $(stat -c '%F %a %u %g %t %T' "$p")"; fi; done); }
listing $S > /t/l1; listing /t/u > /t/l2
cmp -s /t/l1 /t/l2 && ok "same files, modes, owners, links, devices" || { bad "the unpacked tree differs"; diff /t/l1 /t/l2 | head; }
[ "$(stat -c %i /t/u/sbin/a)" = "$(stat -c %i /t/u/sbin/c)" ] && ok "hard links share the inode" || bad "hard links are copies"
[ -c /t/u/dev/console ] && ok "device node" || bad "no device node"
[ "$(stat -c %a /t/u/bin/prog)" = 4755 ] && ok "setuid mode kept" || bad "mode of bin/prog: $(stat -c %a /t/u/bin/prog)"

cp /t/r.img /t/r-dmg.img; printf 'XXXXXXXX' | dd of=/t/r-dmg.img bs=1 seek=40000 conv=notrunc 2>/dev/null
rm -rf /t/u; mkdir /t/u
out=$(/t/init --rescue /t/r-dmg.img /t/u) && bad "damaged archive accepted" || ok "damaged archive: $out"
cp /t/r.img /t/r-hdr.img; printf 'TSX-RESCUE 2' | dd of=/t/r-hdr.img conv=notrunc 2>/dev/null
out=$(/t/init --rescue /t/r-hdr.img /t/u) && bad "wrong header accepted" || ok "wrong header: $out"
{ printf 'TSX-RESCUE 1\nsize 9999999\nversion x\n'; head -c 512 /dev/zero; } | head -c 512 > /t/r-size.img; cat /t/arch.gz >> /t/r-size.img
out=$(/t/init --rescue /t/r-size.img /t/u) && bad "wrong size accepted" || ok "size larger than the slot: $out"
{ printf 'TSX-RESCUE 1\nsize %s\nversion x\n' $(( $(wc -c < /t/arch.gz) - 10 )); head -c 512 /dev/zero; } | head -c 512 > /t/r-short.img; cat /t/arch.gz >> /t/r-short.img
out=$(/t/init --rescue /t/r-short.img /t/u) && bad "short size accepted" || ok "size shorter than the archive: $out"
dd if=/dev/zero of=/t/card2 bs=1M count=9 2>/dev/null
dd if=/t/r.img of=/t/card2 bs=4096 seek=$((0x300000 / 4096)) conv=notrunc 2>/dev/null
rm -rf /t/u; mkdir /t/u
out=$(/t/init --rescue /t/card2 0x300000 /t/u) && [ -x /t/u/bin/prog ] && ok "rescue slot at 0x300000 of a card" || bad "slot at an offset: $out"

echo "== RESCUE file"
mkdir -p /t/fat; printf 'tsx.ip=192.0.2.10/24,192.0.2.1\n' > /t/fat/Rescue.TXT; echo x > /t/fat/README.TXT
out=$(/t/init --flag /t/fat)
echo "$out" | grep -q '^flag: found' && echo "$out" | grep -q 'tsx.ip=192.0.2.10/24,192.0.2.1' && ok "Rescue.TXT found, content read" || bad "flag: $out"
[ ! -e /t/fat/Rescue.TXT ] && [ -e /t/fat/README.TXT ] && ok "the flag file is deleted, other files stay" || bad "flag file not deleted or README gone"
: > /t/fat/RESCUE
/t/init --flag /t/fat > /dev/null && [ ! -e /t/fat/RESCUE ] && ok "an empty RESCUE file counts" || bad "RESCUE without extension"
echo x > /t/fat/rescue.cfg
/t/init --flag /t/fat > /dev/null && bad "rescue.cfg counted" || ok "other names do not count"

echo "== touch trigger (1.5 s wait, 3 s hold, real time)"
# tcase SPEC WANT MIN MAX: the result is WANT after MIN..MAX seconds.
tcase() {
	out=$(/t/init --touch "$1"); r=$(echo "$out" | sed -n 's/^touch: \(.*\) after \([0-9.]*\) s$/\1 \2/p')
	t=${r##* }; res=${r% *}
	if [ "$res" = "$2" ] && awk -v t="$t" -v a="$3" -v b="$4" 'BEGIN { exit !(t >= a && t <= b) }'; then
		ok "touch $1: $res after $t s"
	else
		bad "touch $1: want $2 in $3..$4 s, got: $(echo "$out" | tr '\n' '|')"
	fi
}
tcase none "normal start" 0 0.2
/t/init --touch none | grep -q 'no touch screen' && ok "no touch screen: no wait, a log line" || bad "no log line without a touch screen"
tcase - "normal start" 1.45 1.9
/t/init --touch - | grep -q 'no touch: normal start' && ok "no touch: log line" || bad "no log line for no touch"
tcase 0 rescue 2.95 3.5
tcase 800 rescue 3.75 4.3
tcase 1400 rescue 4.35 4.9
tcase 800-2000 "normal start" 1.95 2.5
/t/init --touch 800-2000 | grep -q 'finger lifted: normal start' && ok "lift: log line" || bad "no log line for the lift"
tcase 1700 "normal start" 1.45 1.9

if [ -s /t/real-rescue.img ]; then
	echo "== the real rescue system"
	rm -rf /t/u; mkdir /t/u
	out=$(/t/init --rescue /t/real-rescue.img /t/u) && ok "unpack: $out" || bad "unpack: $out"
	for f in sbin/init etc/init.d/rcS etc/inittab usr/sbin/tsx-rescue-status usr/sbin/tsx-rescue-login usr/sbin/tsx-boot-mainline \
		usr/sbin/tsx-install-rootfs usr/sbin/tsx-data-backup usr/local/sbin/tsx-boot-ok usr/local/sbin/tsx-kernel-slots \
		usr/local/lib/tsx/board.sh usr/sbin/dropbear usr/bin/fw_printenv usr/share/udhcpc/default.script etc/tsx/rescue-version; do
		[ -e /t/u/$f ] || [ -L /t/u/$f ] || bad "missing /$f"
	done
	ok "the rescue tools are there"
	chroot /t/u /bin/busybox true && ok "busybox runs in the unpacked root" || bad "busybox does not run in the unpacked root"
	chroot /t/u /sbin/e2fsck -V > /dev/null 2>&1 && ok "e2fsck runs" || bad "e2fsck does not run"
	chroot /t/u /usr/bin/fw_printenv -h > /dev/null 2>&1; [ $? -le 1 ] && ok "fw_printenv runs" || bad "fw_printenv does not run"
	f=$(awk -F: '$1 == "root" {print $2}' /t/u/etc/shadow)
	[ "$f" = "*" ] && ok "root is locked (tsx-rescue-login chooses the login)" || echo "  note: root field is not locked (a test build)"
fi
echo "== $N passed, $F failed"
chmod -R a+rwX /t 2>/dev/null
[ $F -eq 0 ]
EOF
docker run --rm --platform linux/arm/v7 -v "$HERE:/src:ro" -v "$T:/t" "$IMAGE" sh /t/run.sh
