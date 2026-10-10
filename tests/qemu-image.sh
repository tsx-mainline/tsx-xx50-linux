#!/bin/sh
# Boot the xx50 card image in QEMU (vexpress-a9) and check the OpenRC boot,
# the shared tsx userland, the data partition, the setup page and the ssh
# login. The panel kernel cannot run in QEMU (no i.MX53 machine), so the
# test uses the kernel from tests/build-qemu-kernel.sh. QEMU has no display
# and no GPU, so the panel app service waits for its device files and then
# fails. The test does not check the panel app itself. The card image is not
# changed: the test runs on a copy.
#
#   tests/qemu-image.sh <card.img> <qemu-kernel-dir> <ssh-private-key> <work-dir>
#
# Env: PORT (local ssh port, default 22522), BOOT_LIMIT (seconds, default 600),
#      INITRD (initrd.cpio.gz of image/mkinitrd.sh: boot through the ramdisk
#      as on the panel, root=PARTUUID, and check its log lines; the QEMU
#      display gets the splash).
set -eu
[ $# -eq 4 ] || { awk 'NR > 1 && !/^#/ {exit} NR > 1 {print}' "$0"; exit 2; }
IMG=$1 QK=$(cd "$2" && pwd) KEY=$3
W=$(mkdir -p "$4" && cd "$4" && pwd)
PORT=${PORT:-22522}
LIMIT=${BOOT_LIMIT:-600}
fails=0
pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*"; fails=$((fails + 1)); }
SSH="ssh -q -i $KEY -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -p $PORT root@127.0.0.1"

echo "== copy the card image (QEMU needs a power-of-two SD size)"
cp "$IMG" "$W/card.img"
truncate -s 4G "$W/card.img"

if [ -n "${INITRD:-}" ]; then
	set -- -initrd "$INITRD"
	APPEND="console=ttyAMA0 fbcon=map:1 root=PARTUUID=7458a050-02 rootfstype=ext4 rootwait=60 rw panic=10 init=/sbin/init"
else
	set --
	APPEND="console=ttyAMA0 root=/dev/mmcblk0p2 rootwait rw panic=10"
fi
start_qemu() {
	n=$1; shift
	qemu-system-arm -M vexpress-a9 -m 1024 -display none -monitor none \
		-serial "file:$W/serial-$n.log" -pidfile "$W/qemu.pid" -daemonize \
		-kernel "$QK/zImage" -dtb "$QK/vexpress-v2p-ca9.dtb" "$@" \
		-append "$APPEND" \
		-drive if=sd,format=raw,file="$W/card.img" \
		-net nic -net "user,hostfwd=tcp:127.0.0.1:$PORT-:22"
}
stop_qemu() {
	[ -s "$W/qemu.pid" ] && kill "$(cat "$W/qemu.pid")" 2>/dev/null || true
	sleep 2
}
wait_ssh() {
	t0=$(date +%s)
	while :; do
		el=$(($(date +%s) - t0))
		if $SSH true 2>/dev/null; then echo "   ssh answers after ${el} s"; return 0; fi
		[ "$el" -ge "$LIMIT" ] && return 1
		echo "   waiting for ssh: ${el} s of ${LIMIT} s, last console line: $(tail -n 1 "$W/serial-$1.log" 2>/dev/null | tr -d '\r' | cut -c1-70)"
		sleep 15
	done
}
trap stop_qemu EXIT

echo "== boot 1"
start_qemu 1 "$@"
if wait_ssh 1; then pass "ssh login with the key (boot 1)"; else fail "no ssh after $LIMIT s (boot 1)"; tail -n 60 "$W/serial-1.log"; exit 1; fi
echo "   wait 30 s for the default runlevel"
sleep 30
$SSH 'rc-status -a' > "$W/rc-status-1.txt" 2>&1 || true
sed 's/^/   | /' "$W/rc-status-1.txt"
for s in tsx-setup tsx-hostname tsx-data tsx-config tsx-cpufreq tsx-touch tsx-setup-helper tsx-setupd networking sshd chronyd; do
	grep -E "^ *$s .*started" "$W/rc-status-1.txt" >/dev/null && pass "service $s started" || fail "service $s not started"
done
if [ -n "${INITRD:-}" ]; then
	grep -aq 'tsx-init: splash at' "$W/serial-1.log" && pass "the ramdisk drew the splash" || fail "no splash line of the ramdisk"
	grep -aq 'tsx-init: switch to' "$W/serial-1.log" && pass "the ramdisk switched to the root partition" || fail "the ramdisk did not switch to the root partition"
	$SSH 'mountpoint -q /dev && mountpoint -q /proc && mountpoint -q /sys && grep -q " / ext4 " /proc/mounts' &&
		pass "/dev, /proc and /sys moved to the root partition" || fail "mounts after the switch"
fi
$SSH 'mountpoint -q /data' && pass "/data is mounted (tsxdata)" || fail "/data is not mounted"
$SSH 'mountpoint -q /var/lib/tsx && test -e /data/var/lib/tsx/.tsx-moved' && pass "tsx-data moved /var/lib/tsx to /data" || fail "/var/lib/tsx is not on /data"
$SSH 'mountpoint -q /mnt/tsxlog' && pass "TSXLOG is mounted" || fail "TSXLOG is not mounted"
$SSH 'test -s /run/tsx/hw.conf && grep -qx LEDBAR=no /run/tsx/hw.conf' && pass "tsx-hw wrote hw.conf" || fail "no hw.conf"
$SSH 'test "$(grep ^root: /etc/shadow | cut -d: -f2)" = "*"' && pass "root password is locked" || fail "root password is not locked"
$SSH 'ip -4 addr show dev eth0 | grep -q inet' && pass "eth0 has an IPv4 address (DHCP)" || fail "eth0 has no IPv4 address"
# A slow boot can start tsx-setupd later than sshd: try for 60 s.
$SSH 'i=0; until wget -q -O - http://127.0.0.1:8080/setup | grep -q "<title>"; do i=$((i + 1)); [ $i -ge 12 ] && exit 1; sleep 5; done' && pass "the setup page answers on port 8080" || fail "no setup page on port 8080"
$SSH 'test -x /usr/local/bin/tsx-panel-app && test -s /etc/tsx/panel-layout.json' && pass "panel app program and board layout installed" || fail "panel app files missing"
$SSH 'tsx-layout-check /etc/tsx/panel-layout.json' > "$W/layout.txt" 2>&1 && pass "the board layout passes tsx-layout-check" || fail "board layout: $(cat "$W/layout.txt")"
$SSH '. /usr/local/lib/tsx/board.sh; test "$TSX_FAMILY" = xx50' && pass "board.sh of the xx50" || fail "board.sh"
$SSH 'apk verify -q 2>/dev/null; apk info -e tsx-base tsx-setup tsx-panel-app tsx-xx50-board tsx-xx50-panel-app' > "$W/apk.txt" 2>&1
[ "$(wc -l < "$W/apk.txt")" -ge 5 ] && pass "tsx packages installed" || fail "tsx packages: $(cat "$W/apk.txt")"

echo "== reboot"
old=$($SSH 'cat /proc/sys/kernel/random/boot_id' 2>/dev/null || echo none)
$SSH 'reboot' || true
# sshd answers for a short time after the reboot command. Wait for a new
# boot id, so the checks below see the new boot.
new_boot() {
	t0=$(date +%s)
	while [ $(($(date +%s) - t0)) -lt "$LIMIT" ]; do
		b=$($SSH 'cat /proc/sys/kernel/random/boot_id' 2>/dev/null || true)
		[ -n "$b" ] && [ "$b" != "$old" ] && { echo "   new boot after $(($(date +%s) - t0)) s"; return 0; }
		sleep 10
	done
	return 1
}
if new_boot; then pass "ssh login after a reboot"; else
	stop_qemu; start_qemu 2 "$@"
	wait_ssh 2 && pass "ssh login after a restart of QEMU" || fail "no ssh after the reboot"
fi
sleep 30
$SSH 'mountpoint -q /var/lib/tsx' && pass "/var/lib/tsx is on /data after the reboot" || fail "/var/lib/tsx not bind-mounted after the reboot"
$SSH 'test -s /root/.ssh/authorized_keys' && pass "/root (on /data) keeps the ssh key" || fail "authorized_keys lost"
$SSH 'poweroff' || true
sleep 15
stop_qemu
trap - EXIT

echo "== result: $([ "$fails" = 0 ] && echo 'ALL CHECKS PASS' || echo "$fails CHECK(S) FAILED")"
[ "$fails" = 0 ]
