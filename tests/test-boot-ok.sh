#!/bin/sh
# Host test of tsx-boot-ok (the U-Boot retry counters) on made-up card
# images with an env at 0xC0000. The test runs the script in an Alpine
# container with u-boot-tools (fw_printenv, fw_setenv), as on the panel.
#
#   tests/test-boot-ok.sh
#
# Also: a good normal boot writes run/tsx/boot-ok with the slot sum
# (TSX_BOOT_SLOTS), a golden boot does not.
# Env: ALPINE_IMAGE (default alpine:3.24, armv7 as on the panel; a host of
# another architecture needs qemu-user binfmt support). Needs docker and
# python3. It runs no compiler.
set -eu
HERE=$(cd "$(dirname "$0")/.." && pwd)
IMAGE=${ALPINE_IMAGE:-alpine:3.24}
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

# mkenv FILE CRC(good|bad) VARS...: a 1 MiB card image with a 128 KiB env.
mkenv() {
	python3 - "$@" <<'EOF'
import struct, sys, zlib
f, crc, vs = sys.argv[1], sys.argv[2], sys.argv[3:]
data = ("\0".join(vs) + "\0\0").encode().ljust(0x20000 - 4, b"\0")
c = zlib.crc32(data) ^ (0 if crc == "good" else 1)
img = bytearray(1 << 20)
img[0xC0000:0xE0000] = struct.pack("<I", c) + data
open(f, "wb").write(img)
EOF
}
mkenv "$T/normal.img" good bootdelay=3 "bootcmd_SD2=mmc read 0 \${loadaddr} 0x4000 0x2000" rd_loadaddr=0x70D00000 boot_retry=9 golden_boot_retry=0 golden=0
mkenv "$T/golden.img" good bootdelay=3 "bootcmd_SD2=mmc read 0 \${loadaddr} 0x6000 0x2000" rd_loadaddr=0x70D00000 boot_retry=11 golden_boot_retry=3 golden=1
mkenv "$T/badcrc.img" bad bootdelay=3 "bootcmd_SD2=x" rd_loadaddr=0x70D00000 boot_retry=9 golden_boot_retry=0 golden=0
mkenv "$T/foreign.img" good bootdelay=3 bootcmd=boot boot_retry=9 golden=0
cp "$T/normal.img" "$T/dry.img"
cp "$T/normal.img" "$T/fallback.img"
cp "$T/golden.img" "$T/reset.img"
for f in "$T"/*.img; do sha256sum "$f" | cut -d' ' -f1 > "$f.before"; done

cat > "$T/run.sh" <<'EOF'
set -u
apk add -q --no-cache u-boot-tools >/dev/null 2>&1
N=0 F=0
ok()  { N=$((N + 1)); echo "  ok: $*"; }
bad() { F=$((F + 1)); echo "  FAIL: $*"; }
bo() { TSX_BOOT_SLOTS=${SLOTS:-} TSX_MAC_DEV=/t/$1 TSX_RUN=/t/run TSX_BOARD_CONF=/src/rootfs/overlay/usr/local/lib/tsx/board.sh sh /src/rootfs/overlay/usr/local/sbin/tsx-boot-ok $2 2>&1; }
penv() { printf '/t/%s 0xc0000 0x20000\n' "$1" > /t/run/cfg; fw_printenv -c /t/run/cfg 2>&1; }
same() { [ "$(sha256sum /t/$1 | cut -d' ' -f1)" = "$(cat /t/$1.before)" ]; }
mkdir -p /t/run

out=$(SLOTS=abc123 bo normal.img write)
echo "$out" | grep -q "env written and checked: boot_retry=8" && ok "normal boot: writes boot_retry=8" || bad "normal boot: $out"
grep -qx slots=abc123 /t/run/tsx/boot-ok 2>/dev/null && ok "normal boot: marked good for promote" || bad "no boot-ok mark"
rm -f /t/run/tsx/boot-ok
e=$(penv normal.img)
echo "$e" | grep -qi "bad crc" && bad "CRC bad after the write" || ok "CRC valid after the write"
echo "$e" | grep -qx boot_retry=8 && echo "$e" | grep -qx golden_boot_retry=0 && ok "values after the write" || bad "values: $e"
echo "$e" | grep -qx bootdelay=3 && echo "$e" | grep -qx rd_loadaddr=0x70D00000 && ok "other variables kept" || bad "other variables: $e"
out=$(bo normal.img write)
echo "$out" | grep -q "env already good" && ok "second run writes nothing" || bad "second run: $out"

out=$(SLOTS=abc123 bo golden.img write)
echo "$out" | grep -q "golden slots" && same golden.img && ok "golden boot: nothing written" || bad "golden boot: $out"
[ ! -e /t/run/tsx/boot-ok ] && ok "golden boot: not marked good" || bad "golden boot: marked good"
out=$(bo badcrc.img write); rc=$?
[ $rc -ne 0 ] && echo "$out" | grep -q "CRC is bad" && same badcrc.img && ok "bad CRC: refused" || bad "bad CRC ($rc): $out"
out=$(bo foreign.img write); rc=$?
[ $rc -ne 0 ] && echo "$out" | grep -q "does not look like" && same foreign.img && ok "foreign env: refused" || bad "foreign env ($rc): $out"
out=$(bo dry.img --dry-run)
echo "$out" | grep -q "would set: boot_retry=8" && same dry.img && ok "dry run: nothing written" || bad "dry run: $out"
out=$(bo dry.img --status)
echo "$out" | grep -q "boot_retry=9 golden_boot_retry=0 golden=0" && ok "status" || bad "status: $out"
# The rescue system: --reset after a golden boot, --fallback from the normal system.
out=$(SLOTS=abc123 bo reset.img --reset)
echo "$out" | grep -q "env written and checked: boot_retry=8,golden_boot_retry=0" && ok "--reset after a golden boot: boot_retry=8, golden_boot_retry=0" || bad "--reset: $out"
e=$(penv reset.img)
echo "$e" | grep -qx boot_retry=8 && echo "$e" | grep -qx golden_boot_retry=0 && echo "$e" | grep -qx golden=1 && ok "--reset: values, golden left to U-Boot" || bad "--reset values: $e"
[ ! -e /t/run/tsx/boot-ok ] && ok "--reset: no good-boot mark" || bad "--reset: marked good"
out=$(bo fallback.img --fallback)
echo "$out" | grep -q "env written and checked: boot_retry=10" && ok "--fallback: boot_retry=10 (the next start boots the golden slots)" || bad "--fallback: $out"
e=$(penv fallback.img)
echo "$e" | grep -qx boot_retry=10 && echo "$e" | grep -qx golden_boot_retry=0 && echo "$e" | grep -qx bootdelay=3 && ok "--fallback: values, other variables kept" || bad "--fallback values: $e"
out=$(bo fallback.img --fallback)
echo "$out" | grep -q "env already good" && ok "--fallback twice: nothing written" || bad "--fallback twice: $out"
out=$(bo badcrc.img --reset); rc=$?
[ $rc -ne 0 ] && same badcrc.img && ok "--reset with a bad CRC: refused" || bad "--reset bad CRC ($rc): $out"
out=$(bo dry.img --bogus); rc=$?
[ $rc -eq 2 ] && same dry.img && ok "unknown option: exit 2" || bad "unknown option ($rc): $out"
echo "== $N passed, $F failed"
chmod -R a+rwX /t
[ $F -eq 0 ]
EOF
docker run --rm --platform linux/arm/v7 -v "$HERE:/src:ro" -v "$T:/t" "$IMAGE" sh /t/run.sh
