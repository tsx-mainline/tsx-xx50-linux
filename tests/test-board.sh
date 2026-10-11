#!/bin/sh
# Host test of the xx50 board layer with the shared code of tsx-linux-common
# (TSX_COMMON, default: the checkout next to this repo). It checks:
#  - board.sh reads the model, the stock firmware, the MAC, the unit id and
#    the host name from a made-up U-Boot env at the card offset 0xC0000
#  - tsx-hw writes the facts of the TSS-752
#  - the board file of the panel app gives the panel app service its
#    environment (tsx-panel-app-run --print)
#  - the default layout and the example layout pass tsx-layout-check
#  - the apk repositories: the image block and tsx-config apply give the
#    public tsx-aports common and xx50 and Alpine main and community
#  - tsx-autoupdate: the image runs it, and the xx50 packages need a reboot
#  - audio: the card of board.sh, asound.conf and tsx-audio with a fake amixer
#  - least privilege: the image users and services, the LEDs of the panel app
# It needs sh, python3 and dd. It runs no compiler.
set -eu
HERE=$(cd "$(dirname "$0")/.." && pwd)
COMMON=${TSX_COMMON:-$HERE/../tsx-linux-common}
OV=$HERE/rootfs/overlay
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
N=0 F=0
ok()  { N=$((N + 1)); echo "  ok: $*"; }
bad() { F=$((F + 1)); echo "  FAIL: $*"; }

echo "== board.sh =="
# A made-up env (CRC and values are not those of a real panel).
truncate -s 1M "$T/card.img"
printf 'bootdelay=3\0ethaddr=00:00:5E:00:53:2A\0lan_hostname=TSS-752-00005E00532A\0product_name=TSS-752_[v1.002.0013,_#0A0B0C0D]\0tsid=0A0B0C0D\0\0' |
	dd of="$T/card.img" bs=1 seek=$((0xC0000 + 4)) conv=notrunc 2>/dev/null
v=$(TSX_MAC_DEV="$T/card.img" sh -c ". '$OV/usr/local/lib/tsx/board.sh'; tsx_board_load; echo \"\$(tsx_board_model)|\$(tsx_board_stock_fw)|\$(tsx_board_mac)|\$(tsx_board_mac_early)|\$(tsx_board_unit_id)|\$(tsx_board_hostname_hint)|\$TSX_FAMILY|\$TSX_SERIAL_CONSOLE\"")
[ "$v" = "TSS-752|v1.002.0013|00:00:5E:00:53:2A|00:00:5E:00:53:2A|00005e00532a|TSS-752-00005E00532A|xx50|ttymxc0" ] && ok "board values" || bad "board values: $v"
v=$(TSX_MAC_DEV="$T/none" sh -c ". '$OV/usr/local/lib/tsx/board.sh'; tsx_board_load; echo \"\$(tsx_board_model)|\$(tsx_board_mac_early)|\$(tsx_board_unit_id)\"")
[ "$v" = "||unknown" ] && ok "no card: empty values" || bad "no card: $v"

echo "== tsx-hw =="
TSX_RUN_DIR="$T/run" sh "$OV/usr/local/sbin/tsx-hw" detect >/dev/null
grep -qx LEDBAR=no "$T/run/hw.conf" && grep -qx BT=no "$T/run/hw.conf" && ok "hw.conf" || bad "hw.conf: $(cat "$T/run/hw.conf")"

echo "== panel app board file =="
mkdir -p "$T/net/eth0"
echo 00:00:5e:00:53:2a > "$T/net/eth0/address"
out=$(TSX_PANEL_APP_CONF="$COMMON/panel-app/etc/tsx/panel-app.conf" TSX_PANEL_APP_BOARD_CONF="$OV/etc/tsx/panel-app-board.conf" \
	TSX_PANEL_APP_STATE_CONF="$T/state.conf" TSX_SYS_NET="$T/net" TSX_HOSTNAME=TSS-752-00005E00532A \
	sh "$COMMON/panel-app/usr/local/sbin/tsx-panel-app-run" --print)
echo "$out" | grep -qx 'NAME=tss-752-00005e00532a' && ok "device name from the host name" || bad "name: $out"
echo "$out" | grep -qx 'MAC=02:00:5E:00:53:2A' && ok "device MAC" || bad "MAC: $out"
echo "$out" | grep -q 'ESPHOME_SNAPSHOT_DIR=' && ok "board environment" || bad "environment: $out"

echo "== default layout =="
TSX_ICON_FILE="$COMMON/panel-app/usr/local/share/tsx/panel-app/icons.txt" python3 "$COMMON/panel-app/usr/local/bin/tsx-layout-check" "$OV/etc/tsx/panel-layout.json" > "$T/check" 2>&1 \
	&& ok "panel-layout.json passes" || bad "panel-layout.json: $(cat "$T/check")"
TSX_ICON_FILE="$COMMON/panel-app/usr/local/share/tsx/panel-app/icons.txt" python3 "$COMMON/panel-app/usr/local/bin/tsx-layout-check" "$HERE/esphome-lvgl/panel-layout.json" > "$T/check" 2>&1 \
	&& ok "the example layout passes" || bad "esphome-lvgl/panel-layout.json: $(cat "$T/check")"

echo "== apk repositories =="
# The file of a new image (rootfs/mkrootfs.sh), then tsx-config apply at the
# boot, with the board file of the xx50.
mkdir -p "$T/root/etc/apk" "$T/root/etc/tsx"
U=https://tsx-aports.unexceptional.net A=https://dl-cdn.alpinelinux.org/alpine/v3.24
printf '# tsx-aports (tsx-config apply. panel.conf APK_URL)\n%s/v3.24/common\n%s/v3.24/xx50\n%s/main\n%s/community\n' "$U" "$U" "$A" "$A" > "$T/root/etc/apk/repositories"
echo "$U" > "$T/root/etc/tsx/apk-url.default"
grep -q 'echo "$TSX_APK_URL/$ALPINE/common"; echo "$TSX_APK_URL/$ALPINE/xx50"' "$HERE/rootfs/mkrootfs.sh" \
	&& grep -q 'printf "%s\\n" "$TSX_APK_URL" > $T/etc/tsx/apk-url.default' "$HERE/rootfs/mkrootfs.sh" \
	&& ok "mkrootfs.sh writes the repository block and the default URL" || bad "mkrootfs.sh repository block changed: update this test"
tc() {
	env TSX_BOARD_CONF="$OV/usr/local/lib/tsx/board.sh" TSX_MAC_DEV="$T/none" TSX_CONF="$T/panel.conf" TSX_RUN="$T/run" \
		TSX_STATE_DIR="$T/root/var/lib/tsx" TSX_APPLY_PREFIX="$T/root" TSX_APPLY_ALLOW_NONROOT=1 \
		sh "$COMMON/base/usr/local/sbin/tsx-config" "$@" >"$T/tc.log" 2>&1 || bad "tsx-config $*: $(cat "$T/tc.log")"
}
apply() { tc apply; }
cfg() { tc "$@"; }
cfg set PANEL_NAME TSS-752-TEST
apply
want="$U/v3.24/common
$U/v3.24/xx50
$A/main
$A/community"
[ "$(grep -v '^#' "$T/root/etc/apk/repositories")" = "$want" ] \
	&& ok "default: tsx-aports common and xx50, then Alpine main and community" || bad "default repositories: $(cat "$T/root/etc/apk/repositories")"
echo "$U/v3.24/xx60" >> "$T/root/etc/apk/repositories"
apply
grep -q '/xx60$' "$T/root/etc/apk/repositories" && bad "a line of another family stays" || ok "a line of another family goes"
cfg set APK_URL https://mirror.example.org/tsx
apply
[ "$(grep -v '^#' "$T/root/etc/apk/repositories" | head -n 2 | tr '\n' ' ')" = "https://mirror.example.org/tsx/v3.24/common https://mirror.example.org/tsx/v3.24/xx50 " ] \
	&& ok "APK_URL replaces the tsx-aports lines" || bad "APK_URL: $(cat "$T/root/etc/apk/repositories")"
cfg unset APK_URL
apply
[ "$(grep -v '^#' "$T/root/etc/apk/repositories")" = "$want" ] && ok "no APK_URL: back to the public repositories" || bad "unset APK_URL: $(cat "$T/root/etc/apk/repositories")"

echo "== tsx-autoupdate =="
grep -q 'tsx-boot-ok tsx-autoupdate tsx-panel-app' "$HERE/rootfs/mkrootfs.sh" && ok "the image runs tsx-autoupdate in the default runlevel" || bad "tsx-autoupdate not in the default runlevel of the image"
needs() { TSX_BOARD_CONF="$OV/usr/local/lib/tsx/board.sh" sh "$COMMON/autoupdate/usr/local/sbin/tsx-autoupdate" __needs_reboot "$1"; }
for p in tsx-xx50-kernel-lts tsx-xx50-board tsx-xx50-panel-app tsx-panel-app tsx-autoupdate; do
	needs "$p" && ok "$p needs a reboot" || bad "$p needs no reboot"
done
needs tsx-xx60-kernel-lts && bad "the kernel package of another family needs a reboot" || ok "the kernel package of another family needs no reboot"

echo "== audio =="
card=$(sh -c ". '$OV/usr/local/lib/tsx/board.sh'; echo \$TSX_SOUND_CARD")
[ "$card" = tss752aic3204 ] && ok "board.sh names the sound card" || bad "TSX_SOUND_CARD: $card"
n=$(grep -c "card $card }\|hw:$card,0,0\|card $card\$" "$OV/etc/asound.conf")
[ "$n" -ge 5 ] && ok "asound.conf uses the card of board.sh ($n places)" || bad "asound.conf names the card $n times"
for p in media speaker tsx_master_ctl tsx_media_ctl; do grep -q "^pcm\.$p " "$OV/etc/asound.conf" && ok "asound.conf has the PCM $p" || bad "no PCM $p"; done
grep -q 'ipc_perm 0666' "$OV/etc/asound.conf" && grep -q 'ipc_key_add_uid false' "$OV/etc/asound.conf" && ok "the dmix is shared by all users" || bad "the dmix is not shared"
mkdir -p "$T/asound/$card" "$T/abin"
cat > "$T/abin/amixer" <<EOF
#!/bin/sh
echo "amixer \$*" >> "$T/amixer.log"
case "\$*" in *"sget Master"*) echo "  Front Left: Playback 50 [50%] [-25.00dB]";; esac
EOF
printf '#!/bin/sh\necho "aplay $*" >> "%s/amixer.log"\n' "$T" > "$T/abin/aplay"
printf '#!/bin/sh\nexit 1\n' > "$T/abin/alsactl"
chmod 755 "$T/abin/amixer" "$T/abin/aplay" "$T/abin/alsactl"
sed 's/^CARD_WAIT=.*/CARD_WAIT=0/' "$OV/etc/tsx/audio.conf" > "$T/audio.conf"
au() { env PATH="$T/abin:$PATH" TSX_BOARD_CONF="$OV/usr/local/lib/tsx/board.sh" TSX_AUDIO_CONF="$T/audio.conf" TSX_ASOUND_DIR="$T/asound" sh "$OV/usr/local/bin/tsx-audio" "$@"; }
au init > "$T/init.out" 2>&1
for want in "aplay -q -D tsx_master_ctl" "sset Master 50%" "sset Media 100%" "sset LOL Output Mixer L_DAC on" "sset LO DAC on" "sset LO Driver Gain 6" "sset PCM 115"; do
	grep -qF "$want" "$T/amixer.log" && ok "init: $want" || bad "init misses '$want': $(cat "$T/amixer.log")"
done
[ "$(au volume)" = 50 ] && ok "tsx-audio volume prints Master" || bad "volume: $(au volume)"
: > "$T/amixer.log"; au volume 130 > /dev/null
grep -qF "sset Master 100%" "$T/amixer.log" && ok "volume 130 is capped at 100" || bad "cap: $(cat "$T/amixer.log")"
rm -rf "$T/asound/$card"; : > "$T/amixer.log"
au init > "$T/init2.out" 2>&1 && [ ! -s "$T/amixer.log" ] && ok "no card: init exits 0 and sets nothing" || bad "init with no card"

echo "== least privilege =="
for s in tsx-audio tsx-panelctl; do grep -q "for s in tsx-cpufreq.* $s .*; do" "$HERE/rootfs/mkrootfs.sh" && ok "the image runs $s" || bad "$s not in the default runlevel of the image"; done
for u in "getent passwd tsx-panel-app" "addgroup -S tsx-setup-screen" "addgroup tsx-panel-app \\\$g"; do grep -qF "$u" "$HERE/rootfs/mkrootfs.sh" && ok "image: $u" || bad "image misses: $u"; done
grep -q '^PANEL_APP_LEDS="rgb:lightbar-\*"$' "$OV/etc/tsx/panel-app-board.conf" && ok "the panel app may write the two light bars" || bad "PANEL_APP_LEDS"

echo "== $N passed, $F failed"
[ "$F" = 0 ]
