#!/bin/sh
# Choose the time zone for a new card (image/mkcard.sh runs this script).
#
#   image/tz-select.sh [ZONE]
#
# ZONE is a name of the tz database, for example America/Denver. The word
# "none" writes no zone: the panel then runs on UTC until the first save of
# the setup page. Without ZONE, the script uses the time zone of this
# computer as the default. At a terminal it shows the default and asks. Press
# Enter to accept it. In a script, with no terminal, it takes the default and
# says so. The answer goes to stdout: the zone, or "none". Messages go to
# stderr. Exit code 2: the zone is not valid.
#
# The host zone comes from /etc/timezone, then the link /etc/localtime, then
# timedatectl, then UTC. A zone is valid when it uses only the characters
# A-Z a-z 0-9 _ + / - (the check of tsx-config), does not start with a slash and,
# on a host with a zoneinfo folder, has a file there. A zone that this host does
# not know is refused for ZONE, and for an answer at the prompt.
#
# Env (tests): TSX_HOST_ZONEINFO, TSX_HOST_TIMEZONE_FILE, TSX_HOST_LOCALTIME,
# TSX_NO_TIMEDATECTL=1, TSX_TZ_ASK=1 (ask also without a terminal).
set -eu
ZI=${TSX_HOST_ZONEINFO:-/usr/share/zoneinfo}

# valid NAME: succeed when NAME can be a zone of the panel
valid() {
	printf '%s' "$1" | grep -Eq '^[A-Za-z0-9_+/-]{1,64}$' || return 1
	case "$1" in /*|*//*|*/) return 1;; esac
	[ ! -d "$ZI" ] || [ -f "$ZI/$1" ]
}

# host_zone: print the zone of this computer, else UTC
host_zone() {
	z=
	f=${TSX_HOST_TIMEZONE_FILE:-/etc/timezone}
	[ ! -r "$f" ] || z=$(head -n 1 "$f" | tr -d ' \r')
	if [ -z "$z" ] || ! valid "$z"; then
		z=$(readlink "${TSX_HOST_LOCALTIME:-/etc/localtime}" 2>/dev/null || true)
		z=${z##*/zoneinfo/}
	fi
	if { [ -z "$z" ] || ! valid "$z"; } && [ -z "${TSX_NO_TIMEDATECTL:-}" ] && command -v timedatectl >/dev/null 2>&1; then
		z=$(timedatectl show -p Timezone --value 2>/dev/null || true)
	fi
	if [ -n "$z" ] && valid "$z"; then printf '%s\n' "$z"; else printf 'UTC\n'; fi
}

refuse() { echo "tz-select: $1" >&2; exit 2; }

if [ $# -gt 1 ]; then refuse "usage: tz-select.sh [ZONE]"; fi
if [ $# -eq 1 ] && [ -n "$1" ]; then
	[ "$1" != none ] || { echo none; exit 0; }
	valid "$1" || refuse "'$1' is not a time zone of this computer (use a name like America/Denver, or none)"
	echo "$1"
	exit 0
fi

def=$(host_zone)
if [ -n "${TSX_TZ_ASK:-}" ] || { [ -t 0 ] && [ -t 2 ]; }; then
	while :; do
		printf 'Time zone of the panel, or "none" for UTC [%s]: ' "$def" >&2
		ans=
		# the end of the input takes the default
		read -r ans || { echo >&2; echo "$def"; exit 0; }
		[ -n "$ans" ] || ans=$def
		[ "$ans" != none ] || { echo none; exit 0; }
		if valid "$ans"; then echo "$ans"; exit 0; fi
		echo "  '$ans' is not a time zone of this computer. Use a name like America/Denver." >&2
	done
fi
echo "time zone of the panel: $def (the time zone of this computer. Use --tz ZONE or --tz none to change it)" >&2
echo "$def"
