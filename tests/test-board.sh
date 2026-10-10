#!/bin/sh
# Host test of the xx50 board layer with the shared code of tsx-linux-common
# (TSX_COMMON, default: the checkout next to this repo). It checks:
#  - board.sh reads the model, the stock firmware, the MAC, the unit id and
#    the host name from a made-up U-Boot env at the card offset 0xC0000
#  - tsx-hw writes the facts of the TSS-752
#  - the board file of the panel app gives the panel app service its
#    environment (tsx-panel-app-run --print)
#  - the default layout and the example layout pass tsx-layout-check
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

echo "== $N passed, $F failed"
[ "$F" = 0 ]
