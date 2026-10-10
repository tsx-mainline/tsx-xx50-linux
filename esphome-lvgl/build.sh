#!/bin/sh
# Build an ESPHome LVGL program for the xx50 panels (Alpine armv7, DRM/KMS
# with the tsx_drm display and the tsx_evdev input).
#
#   esphome-lvgl/build.sh <yaml> [work-dir]
#
# <yaml>     panel-app.yaml or demo-drm.yaml of this folder (or a copy). A
#            YAML with !secret (demo-drm.yaml) needs secrets.yaml in its
#            folder (see secrets.yaml.example).
# work-dir   default ./out/esphome-lvgl. It holds the ESPHome venv, the
#            PlatformIO cache, the generated project and the program.
# Env: ESPHOME_VERSION  the ESPHome release (default 2026.9.1).
#      PIO_VERSION      the PlatformIO release (default 6.1.19).
#      TSX_COMMON       the tsx-linux-common checkout (default: the folder
#                       tsx-linux-common next to this repo). The YAML files
#                       need its folder panel-app/esphome (the components
#                       and the generic YAML). It goes to tsx-panel-app/
#                       next to the copy of the YAML. The tag that a release
#                       uses is in COMMON_REF of this repo.
# Steps:
#   1. ESPHome (Python venv on this host) checks the YAML and writes the C++
#      project (--only-generate), with TZ=UTC. Home Assistant sends its time
#      zone to the program when the API connects.
#   2. The patches of tsx-panel-app/patches go on src/esphome of the project.
#   3. The paths of this host in the project become relative, or the
#      placeholder @PROJECT_DIR@ (compile.sh fills it in). So the project
#      compiles in another folder, for example in abuild (mksource.sh).
#   4. An armv7 Alpine 3.24 container compiles the project with compile.sh
#      (PlatformIO "native": the g++ and libdrm of Alpine).
# Needs docker, python3 with venv, patch. A host that is not armv7 or arm64
# needs qemu-user binfmt support. Output: <work-dir>/<device name>, stripped.
# The panel needs the packages libdrm and libstdc++.
set -eu
[ $# -ge 1 ] || { awk 'NR > 1 && !/^#/ {exit} NR > 1 {print}' "$0"; exit 2; }
HERE=$(cd "$(dirname "$0")" && pwd)
YAML=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
WORK=$(mkdir -p "${2:-$PWD/out/esphome-lvgl}" && cd "${2:-$PWD/out/esphome-lvgl}" && pwd)
VER=${ESPHOME_VERSION:-2026.9.1}
PIO=${PIO_VERSION:-6.1.19}
IMG=tsx-xx50-esphome:armv7-pio$PIO
NAME=$(sed -n 's/^  name: *//p' "$YAML" | head -1)
[ -n "$NAME" ] || { echo "ERROR: no esphome name in $YAML" >&2; exit 1; }
SECRETS=$(dirname "$YAML")/secrets.yaml
if grep -q '!secret' "$YAML" && [ ! -f "$SECRETS" ]; then
	echo "ERROR: $SECRETS is missing" >&2; exit 1
fi
t0=$(date +%s)

echo "== ESPHome $VER (venv in $WORK/venv)"
[ -x "$WORK/venv/bin/esphome" ] || python3 -m venv "$WORK/venv"
"$WORK/venv/bin/esphome" version 2>/dev/null | grep -q " $VER\$" || "$WORK/venv/bin/pip" install -q "esphome==$VER"

echo "== armv7 build image $IMG"
if ! docker image inspect "$IMG" >/dev/null 2>&1; then
	docker pull -q --platform linux/arm/v7 alpine:3.24 >/dev/null
	printf '%s\n' 'FROM alpine:3.24' \
		'RUN apk add --no-cache build-base libdrm-dev python3 py3-pip git' \
		"RUN python3 -m venv /opt/pio && /opt/pio/bin/pip install --no-cache-dir platformio==$PIO" \
		'ENV PATH=/opt/pio/bin:$PATH PLATFORMIO_CORE_DIR=/pio-core' |
		docker build --platform linux/arm/v7 -q -t "$IMG" - >/dev/null
fi

echo "== generate the project for $NAME"
CONF=$WORK/config
mkdir -p "$CONF" "$WORK/pio-core"
cp "$YAML" "$HERE/tsx_perf.h" "$CONF/"
if grep -q 'tsx-panel-app/' "$YAML"; then
	COMMON=${TSX_COMMON:-$HERE/../../tsx-linux-common}
	[ -d "$COMMON/panel-app/esphome/components/tsx_cards" ] || { echo "ERROR: no panel-app/esphome in $COMMON (set TSX_COMMON)" >&2; exit 1; }
	rm -rf "$CONF/tsx-panel-app"
	cp -r "$COMMON/panel-app/esphome" "$CONF/tsx-panel-app"
fi
rm -f "$CONF/secrets.yaml"
if [ -f "$SECRETS" ]; then
	cp "$SECRETS" "$CONF/secrets.yaml"
	chmod 600 "$CONF/secrets.yaml"
fi
TZ=UTC "$WORK/venv/bin/esphome" compile --only-generate "$CONF/$(basename "$YAML")"
PROJ=$CONF/.esphome/build/$NAME
if [ -d "$CONF/tsx-panel-app/patches" ]; then
	for p in "$CONF"/tsx-panel-app/patches/*.patch; do
		[ -e "$p" ] || continue
		# ESPHome writes the project again at each run, so the files are
		# the unpatched ones here.
		patch -s -d "$PROJ/src/esphome" -p1 < "$p"
		echo "   patch $(basename "$p")"
	done
fi
# The project folder becomes @PROJECT_DIR@ (platformio.ini: LV_CONF_PATH),
# the YAML folder becomes relative (#line directives, the snapshot folder).
grep -rlF "$PROJ" "$PROJ/platformio.ini" "$PROJ/src" | while IFS= read -r f; do sed -i "s|$PROJ|@PROJECT_DIR@|g" "$f"; done
grep -rlF "$CONF/" "$PROJ/src" | while IFS= read -r f; do sed -i "s|$CONF/||g" "$f"; done
if grep -rqF "$WORK" "$PROJ/platformio.ini" "$PROJ/src"; then
	echo "ERROR: the project still names $WORK:" >&2
	grep -rlF "$WORK" "$PROJ/platformio.ini" "$PROJ/src" >&2
	exit 1
fi
cp "$HERE/compile.sh" "$PROJ/compile.sh"
t1=$(date +%s)

echo "== compile in the armv7 container"
# On an arm64 host the armv7 container runs natively, and uname -m says
# aarch64. linux32 makes it say armv8l, as on a 32-bit ARM machine.
L32=
[ "$(uname -m)" != aarch64 ] || L32=linux32
docker run --rm --platform linux/arm/v7 --user "$(id -u):$(id -g)" -e HOME=/tmp \
	-v "$WORK:$WORK" -v "$WORK/pio-core:/pio-core" -w "$PROJ" "$IMG" \
	$L32 sh "$PROJ/compile.sh" "$PROJ" "$WORK/$NAME"
t2=$(date +%s)
ls -l "$WORK/$NAME"
echo "== done: generate $((t1 - t0)) s, compile $((t2 - t1)) s"
