# board.sh: the values and the small functions of the xx50 board (TSS-752).
# The shared scripts of tsx-linux-common source it:
#   . "${TSX_BOARD_CONF:-/usr/local/lib/tsx/board.sh}"
# The names are the board interface of tsx-linux-common (docs/layout.md
# there, "Board interface"). The file has plain variables and functions and no
# side effects. A value that is in the environment wins (host tests use that).
#
# The xx50 boots from an SD card with the stock U-Boot. The stock U-Boot env
# is on the same card at 0xC0000 (768 KiB), 128 KiB. It holds ethaddr,
# lan_hostname, product_name ("TSS-752_[v1.002.0013,_#<tsid>]") and tsid.
# The functions read it as text with dd (read only). They never write it.
#
# The parts that the TSS-752 lacks are not here: tsx-hw writes them to
# /run/tsx/hw.conf at boot.
#
# Test hooks: TSX_MAC_DEV (the card or a file with the env at the same
# offset), TSX_ENV_OFFSET, TSX_ENV_SIZE.

TSX_FAMILY=${TSX_FAMILY:-xx50}
TSX_APK_CATEGORY=${TSX_APK_CATEGORY:-xx50}
TSX_HA_MODEL=${TSX_HA_MODEL:-xx50}
# The codec (TLV320AIC3204, simple-audio-card). No board service uses it.
TSX_SOUND_CARD=${TSX_SOUND_CARD-}
TSX_DISPLAY_DRM=${TSX_DISPLAY_DRM:-imx-drm}
TSX_RENDER_DRM=${TSX_RENDER_DRM:-msm}
TSX_DISPLAY_ENV=${TSX_DISPLAY_ENV-}
TSX_BT_CHIP=${TSX_BT_CHIP:-none}
TSX_BT_PROXY_DEFAULT=${TSX_BT_PROXY_DEFAULT:-off}
TSX_BT_MAC_SETTABLE=${TSX_BT_MAC_SETTABLE:-no}
TSX_MAC_SOURCE=${TSX_MAC_SOURCE:-uboot}
TSX_MAC_DEV=${TSX_MAC_DEV:-/dev/mmcblk0}
TSX_ENV_OFFSET=${TSX_ENV_OFFSET:-786432}
TSX_ENV_SIZE=${TSX_ENV_SIZE:-131072}
TSX_SERIAL_CONSOLE=${TSX_SERIAL_CONSOLE:-ttymxc0}
TSX_RENDER_ENV=${TSX_RENDER_ENV-}
TSX_BROWSER_GL_FLAGS=${TSX_BROWSER_GL_FLAGS-}
TSX_VOLUME_CMD=${TSX_VOLUME_CMD-}
TSX_RESCUE_BACKLIGHT=${TSX_RESCUE_BACKLIGHT:-50}

# _tb_env_text: the env area as text lines (NAME=value).
_tb_env_text() {
	[ -b "$TSX_MAC_DEV" ] || [ -f "$TSX_MAC_DEV" ] || return 1
	dd if="$TSX_MAC_DEV" bs=4096 skip=$((TSX_ENV_OFFSET / 4096)) count=$((TSX_ENV_SIZE / 4096)) 2>/dev/null |
		tr '\0' '\n' | grep -a '^[A-Za-z_][A-Za-z0-9_]*='
}

# tsx_board_load: read the env once (TSX_BOARD_ENV). dd reads 128 KiB and
# cannot hang like fw_printenv.
tsx_board_load() {
	TSX_BOARD_ENV=$(_tb_env_text) || TSX_BOARD_ENV=
	return 0
}

# tsx_board_env NAME: one variable of the env.
tsx_board_env() {
	[ -n "${TSX_BOARD_ENV:-}" ] || tsx_board_load
	_tb_v=$(printf '%s\n' "${TSX_BOARD_ENV:-}" | sed -n "s/^$1=//p" | head -n 1)
	[ -n "$_tb_v" ] || return 1
	printf '%s\n' "$_tb_v"
}

tsx_board_probe() { [ -b "$TSX_MAC_DEV" ]; }

# product_name looks like "TSS-752_[v1.002.0013,_#1A2B3C4D]": the model, the
# stock firmware version and the tsid.
tsx_board_model() {
	_tb_p=$(tsx_board_env product_name 2>/dev/null) || _tb_p=
	printf '%s\n' "${_tb_p%%_\[*}"
}
tsx_board_stock_fw() {
	_tb_p=$(tsx_board_env product_name 2>/dev/null) || _tb_p=
	printf '%s\n' "$_tb_p" | sed -n 's/^[^[]*\[\(v[0-9][0-9.]*\).*/\1/p'
}
tsx_board_unit_id() {
	_tb_m=$(tsx_board_env ethaddr 2>/dev/null) && [ -n "$_tb_m" ] && { echo "$_tb_m" | tr -d ':' | tr 'A-F' 'a-f'; return; }
	_tb_m=$(tsx_board_env tsid 2>/dev/null) && [ -n "$_tb_m" ] && { echo "tsid-$_tb_m"; return; }
	echo unknown
}
tsx_board_hostname_hint() {
	tsx_board_env lan_hostname 2>/dev/null || true
}
tsx_board_mac() {
	_tb_m=$(tsx_board_env ethaddr 2>/dev/null) || return 0
	echo "$_tb_m" | grep -qiE '^[0-9a-f]{2}(:[0-9a-f]{2}){5}$' && echo "$_tb_m"
	return 0
}
# The same at early boot: one dd, no other tool.
tsx_board_mac_early() {
	_tb_m=$(_tb_env_text 2>/dev/null | sed -n 's/^ethaddr=//p' | head -n 1)
	echo "$_tb_m" | grep -qiE '^[0-9a-f]{2}(:[0-9a-f]{2}){5}$' && echo "$_tb_m"
	return 0
}
tsx_board_mac_source() { echo "$TSX_MAC_SOURCE"; }
tsx_board_ha_model() { tsx_board_model; }
tsx_board_rescue_extra() { :; }
# The xx50 has no USB port, so no USB LED bar.
tsx_board_ledbar_map() { return 0; }
