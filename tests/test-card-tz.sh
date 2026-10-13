#!/bin/sh
# Host test of the time zone of a new card (image/tz-select.sh,
# image/data-tz.sh and the option --tz of image/mkcard.sh). It checks:
#  - the choice of the zone: an explicit zone, "none", the default from the
#    host (/etc/timezone, the link /etc/localtime, UTC), the prompt with
#    answers on stdin, and the refusals
#  - the file /tsx/timezone in the data partition: content, owner, modes, the
#    refusal of a bad name, a card image file with an offset
#  - mkcard.sh stops at once for a bad zone, before it starts docker
#  - with TSX_COMMON (a tsx-linux-common checkout): tsx-setup reads the zone
#    that data-tz.sh wrote
# It needs no docker and no root. The data partition tests need mke2fs and
# debugfs (e2fsprogs). Run it with: sh tests/test-card-tz.sh (or busybox sh).
set -eu
PATH=$PATH:/sbin:/usr/sbin
HERE=$(cd "$(dirname "$0")/.." && pwd)
SEL=$HERE/image/tz-select.sh DTZ=$HERE/image/data-tz.sh MK=$HERE/image/mkcard.sh
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
N=0 F=0
ok()  { N=$((N + 1)); echo "  ok: $*"; }
bad() { F=$((F + 1)); echo "  FAIL: $*"; }
eq() { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (got '$1', want '$2')"; fi; }

for f in "$SEL" "$DTZ" "$MK"; do
	busybox sh -n "$f" 2>/dev/null || sh -n "$f" || bad "syntax of $f"
	[ -x "$f" ] || bad "$f is not executable"
done

# a made-up host: a zoneinfo folder, no /etc/timezone, no timedatectl
ZI=$T/zoneinfo; mkdir -p "$ZI/America" "$ZI/Europe" "$ZI/US"
for z in UTC America/Denver America/New_York Europe/Berlin US/Mountain; do echo "$z" > "$ZI/$z"; done
sel() { # args... : run tz-select.sh on the made-up host
	env TSX_HOST_ZONEINFO="$ZI" TSX_HOST_TIMEZONE_FILE="$T/none" TSX_HOST_LOCALTIME="$T/none" TSX_NO_TIMEDATECTL=1 "$@"
}

echo "== an explicit zone =="
eq "$(sel sh "$SEL" America/Denver 2>/dev/null)" America/Denver "a zone of the host is accepted"
eq "$(sel sh "$SEL" Europe/Berlin 2>/dev/null)" Europe/Berlin "another zone"
eq "$(sel sh "$SEL" none 2>/dev/null)" none "none writes no zone"
for z in Not/AZone '../etc/passwd' '/usr/share/zoneinfo/UTC' 'America/Denver;reboot' 'America Denver' 'America/' 'America//Denver'; do
	if sel sh "$SEL" "$z" >"$T/out" 2>"$T/err"; then bad "zone '$z' accepted"
	else
		rc=0; sel sh "$SEL" "$z" >/dev/null 2>&1 || rc=$?
		[ "$rc" = 2 ] && [ ! -s "$T/out" ] && grep -q "is not a time zone" "$T/err" && ok "zone '$z' refused (exit 2, a message, no answer)" || bad "zone '$z': rc $rc, $(cat "$T/err")"
	fi
done
sel sh "$SEL" a b >/dev/null 2>&1 && bad "two arguments accepted" || ok "two arguments refused"

echo "== the default from the host =="
eq "$(sel sh "$SEL" 2>/dev/null)" UTC "no host zone: UTC"
sel sh "$SEL" 2>&1 >/dev/null | grep -q "UTC (the time zone of this computer" && ok "the message names the default and the options" || bad "no message: $(sel sh "$SEL" 2>&1 >/dev/null)"
echo "America/New_York" > "$T/etc-timezone"
eq "$(sel env TSX_HOST_TIMEZONE_FILE="$T/etc-timezone" sh "$SEL" 2>/dev/null)" America/New_York "/etc/timezone gives the default"
ln -s "$ZI/US/Mountain" "$T/localtime"
eq "$(sel env TSX_HOST_LOCALTIME="$T/localtime" sh "$SEL" 2>/dev/null)" US/Mountain "the link /etc/localtime gives the default"
eq "$(sel env TSX_HOST_TIMEZONE_FILE="$T/etc-timezone" TSX_HOST_LOCALTIME="$T/localtime" sh "$SEL" 2>/dev/null)" America/New_York "/etc/timezone wins over the link"
echo "Mars/Olympus" > "$T/bad-timezone"
eq "$(sel env TSX_HOST_TIMEZONE_FILE="$T/bad-timezone" TSX_HOST_LOCALTIME="$T/localtime" sh "$SEL" 2>/dev/null)" US/Mountain "a zone that the host does not know is skipped"
ln -sf "$T/none" "$T/localtime2"
eq "$(sel env TSX_HOST_LOCALTIME="$T/localtime2" sh "$SEL" 2>/dev/null)" UTC "a link to no zone: UTC"

echo "== the prompt (answers on stdin) =="
ask() { # ANSWERS...: the answers, one per line, and the environment of the made-up host with /etc/timezone
	printf '%s\n' "$@" | sel env TSX_HOST_TIMEZONE_FILE="$T/etc-timezone" TSX_TZ_ASK=1 sh "$SEL" 2>"$T/prompt"
}
eq "$(ask '')" America/New_York "Enter takes the default"
grep -q 'Time zone of the panel, or "none" for UTC \[America/New_York\]' "$T/prompt" && ok "the prompt shows the default" || bad "prompt: $(cat "$T/prompt")"
eq "$(ask Europe/Berlin)" Europe/Berlin "an answer"
eq "$(ask none)" none "the answer none"
eq "$(ask Mars/Olympus America/Denver)" America/Denver "a bad answer asks again"
grep -q "'Mars/Olympus' is not a time zone" "$T/prompt" && ok "the bad answer gets a message" || bad "no message for a bad answer"
eq "$(sel env TSX_HOST_TIMEZONE_FILE="$T/etc-timezone" TSX_TZ_ASK=1 sh "$SEL" </dev/null 2>/dev/null)" America/New_York "the end of the input takes the default"
eq "$(printf 'Europe/Berlin\n' | sel env TSX_HOST_TIMEZONE_FILE="$T/etc-timezone" TSX_TZ_ASK=1 sh "$SEL" America/Denver 2>/dev/null)" America/Denver "an explicit zone asks nothing"

echo "== the zone in the data partition =="
# the programs of e2fsprogs by their path: the busybox of some hosts has a mke2fs applet that is not the same
findbin() { for d in /usr/sbin /sbin /usr/bin /bin; do [ -x "$d/$1" ] && [ "$(basename "$(readlink -f "$d/$1")")" != busybox ] && { echo "$d/$1"; return 0; }; done; return 1; }
MKE2FS=$(findbin mke2fs || true) E2FSCK=$(findbin e2fsck || true)
if [ -n "$MKE2FS" ] && command -v debugfs >/dev/null 2>&1; then
	"$MKE2FS" -q -t ext4 -L tsxdata "$T/data.ext4" 8M
	cp "$T/data.ext4" "$T/empty.ext4"
	sh "$DTZ" "$T/data.ext4" America/Denver >/dev/null
	eq "$(debugfs -R 'cat tsx/timezone' "$T/data.ext4" 2>/dev/null)" America/Denver "/tsx/timezone holds the zone"
	st=$(debugfs -R 'stat tsx/timezone' "$T/data.ext4" 2>/dev/null)
	case "$st" in *"Mode:  0600"*"User:     0   Group:     0"*) ok "the file is mode 600, owner root";; *) bad "file stat: $st";; esac
	st=$(debugfs -R 'stat tsx' "$T/data.ext4" 2>/dev/null)
	case "$st" in *"Mode:  0700"*"User:     0   Group:     0"*) ok "the folder /tsx is mode 700, owner root";; *) bad "folder stat: $st";; esac
	eq "$(debugfs -R 'ls -l /' "$T/data.ext4" 2>/dev/null | grep -c ' tsx$')" 1 "one folder /tsx"
	"${E2FSCK:-true}" -fn "$T/data.ext4" >/dev/null 2>&1 && ok "the file system is clean after the write" || bad "e2fsck reports errors"
	for z in '../x' '/abs' 'a b' '' 'x;y'; do
		cp "$T/empty.ext4" "$T/d2.ext4"
		sh "$DTZ" "$T/d2.ext4" "$z" >/dev/null 2>&1 && bad "data-tz accepted '$z'" || ok "data-tz refused '$z'"
		eq "$(debugfs -R 'ls /' "$T/d2.ext4" 2>/dev/null | grep -c tsx)" 0 "a refused zone '$z' wrote nothing"
	done
	sh "$DTZ" "$T/none.ext4" UTC >/dev/null 2>&1 && bad "data-tz accepted a missing file" || ok "data-tz refused a missing file"
	sh "$DTZ" >/dev/null 2>&1 && bad "data-tz without arguments" || ok "data-tz without arguments prints the usage"
	# a card image file: p3 at an offset
	head -c 1048576 /dev/zero > "$T/zero1m"
	( cat "$T/zero1m"; cat "$T/empty.ext4" ) > "$T/card.img"
	sh "$DTZ" "$T/card.img?offset=1048576" Europe/Berlin >/dev/null
	eq "$(debugfs -R 'cat tsx/timezone' "$T/card.img?offset=1048576" 2>/dev/null)" Europe/Berlin "a card image file with an offset"
	head -c 1048576 "$T/card.img" | cmp -s - "$T/zero1m" && ok "the bytes before the partition are not changed" || bad "the bytes before the partition changed"
	# tsx-setup of tsx-linux-common reads the file that this script wrote
	if [ -n "${TSX_COMMON:-}" ] && grep -q '^default_tz()' "$TSX_COMMON/base/etc/init.d/tsx-setup" 2>/dev/null; then
		debugfs -R 'cat tsx/timezone' "$T/data.ext4" 2>/dev/null > "$T/tzfile"
		got=$(TSX_TZ_DEFAULT_FILE="$T/tzfile" busybox sh -c '. "$1"; default_tz' sh "$TSX_COMMON/base/etc/init.d/tsx-setup" 2>/dev/null)
		eq "$got" America/Denver "default_tz of tsx-setup reads the file of data-tz.sh"
	else
		echo "  (tsx-setup not checked: TSX_COMMON is not set, or its tsx-setup has no default_tz yet)"
	fi
else
	echo "  (the data partition tests need mke2fs and debugfs)"
fi

echo "== mkcard.sh stops for a bad zone before docker =="
mkdir -p "$T/k" "$T/w" "$T/o" "$T/bin"
echo x > "$T/k/uImage"; for f in uInitrd tsx-xx50-rescue.img rootfs.ext4 data.ext4; do echo x > "$T/w/$f"; done
echo x > "$T/stock.img"
# a docker that fails the test when it runs
printf '#!/bin/sh\necho docker >> "%s/docker.log"\nexit 1\n' "$T" > "$T/bin/docker"; chmod +x "$T/bin/docker"
: > "$T/docker.log"
if PATH="$T/bin:$PATH" sh "$MK" --tz Not/AZone "$T/stock.img" "$T/k" "$T/w" "$T/o" >"$T/mk.out" 2>"$T/mk.err"; then bad "mkcard.sh accepted a bad zone"
else
	grep -q "is not a time zone" "$T/mk.err" && [ ! -s "$T/docker.log" ] && ok "mkcard.sh --tz Not/AZone: refused, docker not started" || bad "mkcard.sh bad zone: $(cat "$T/mk.err")"
fi
if PATH="$T/bin:$PATH" TSX_TZ='Bad Zone' sh "$MK" "$T/stock.img" "$T/k" "$T/w" "$T/o" >"$T/mk.out" 2>"$T/mk.err"; then bad "mkcard.sh accepted TSX_TZ with a bad zone"
else grep -q "is not a time zone" "$T/mk.err" && [ ! -s "$T/docker.log" ] && ok "TSX_TZ with a bad zone: refused, docker not started" || bad "TSX_TZ bad zone: $(cat "$T/mk.err")"; fi
PATH="$T/bin:$PATH" sh "$MK" --tz >"$T/mk.out" 2>"$T/mk.err" && bad "--tz without a value accepted" || { grep -q "mkcard.sh" "$T/mk.out" && ok "--tz without a value prints the usage" || bad "usage: $(cat "$T/mk.out")"; }
PATH="$T/bin:$PATH" sh "$MK" --tz America/Denver "$T/stock.img" >"$T/mk.out" 2>"$T/mk.err" && bad "three arguments missing accepted" || ok "a wrong count of arguments prints the usage"
grep -q -- '--tz ZONE' "$T/mk.out" && ok "the usage names --tz" || bad "the usage has no --tz: $(cat "$T/mk.out")"
# with a good zone the script goes on to docker (the fake docker fails the run)
: > "$T/docker.log"
PATH="$T/bin:$PATH" sh "$MK" --tz America/New_York "$T/stock.img" "$T/k" "$T/w" "$T/o" >"$T/mk.out" 2>"$T/mk.err" || true
if [ -d /usr/share/zoneinfo ]; then
	grep -q "time zone of the panel: America/New_York" "$T/mk.out" && ok "mkcard.sh --tz America/New_York: the zone is shown, the script goes on" || bad "mkcard.sh good zone: $(cat "$T/mk.out" "$T/mk.err")"
fi
grep -q "^== time zone of the panel: none" "$T/mk.out" && bad "none chosen for a zone" || true
PATH="$T/bin:$PATH" sh "$MK" --tz none "$T/stock.img" "$T/k" "$T/w" "$T/o" >"$T/mk.out" 2>"$T/mk.err" || true
grep -q "time zone of the panel: none" "$T/mk.out" && ok "mkcard.sh --tz none: no zone" || bad "mkcard.sh --tz none: $(cat "$T/mk.out" "$T/mk.err")"

echo "== $N ok, $F failed =="
if [ "$F" = 0 ]; then echo "PASS test-card-tz"; else echo "FAIL test-card-tz"; exit 1; fi
