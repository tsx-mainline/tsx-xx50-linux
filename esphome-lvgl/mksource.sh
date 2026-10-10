#!/bin/sh
# Pack the generated project of the panel app as the source archive of the
# package tsx-xx50-panel-app (tsx-aports). abuild compiles the program from
# it with compile.sh.
#
#   esphome-lvgl/mksource.sh <work-dir> <out-dir> <version>
#
# <work-dir>  the work dir of build.sh after a build of panel-app.yaml
# <version>   the release version, for example 0.3.0
# Env: XX50_REV, COMMON_REV   the commits of the two source trees (default:
#      git of this repo, and of TSX_COMMON or ../tsx-linux-common).
# Output: <out-dir>/tsx-xx50-panel-app-src-<version>.tar.gz with the folder
# tsx-xx50-panel-app-<version>/: platformio.ini, the PlatformIO scripts,
# src/, compile.sh and BUILDINFO (the ESPHome and PlatformIO versions, the
# two commits, the sha256 of the program that build.sh made). The archive
# has fixed owners, modes and times, so the same project gives the same
# archive.
set -eu
[ $# -eq 3 ] || { awk 'NR > 1 && !/^#/ {exit} NR > 1 {print}' "$0"; exit 2; }
HERE=$(cd "$(dirname "$0")" && pwd)
WORK=$(cd "$1" && pwd)
OUT=$(mkdir -p "$2" && cd "$2" && pwd)
VER=$3
NAME=$(sed -n 's/^  name: *//p' "$HERE/panel-app.yaml" | head -1)
PROJ=$WORK/config/.esphome/build/$NAME
BIN=$WORK/$NAME
[ -f "$PROJ/platformio.ini" ] && [ -x "$BIN" ] || { echo "ERROR: no project or program in $WORK (run build.sh panel-app.yaml first)" >&2; exit 1; }
if grep -rqF "$WORK" "$PROJ/platformio.ini" "$PROJ/src"; then
	echo "ERROR: the project names $WORK (build.sh did not finish)" >&2; exit 1
fi
COMMON=${TSX_COMMON:-$HERE/../../tsx-linux-common}
XX50_REV=${XX50_REV:-$(git -C "$HERE/.." rev-parse HEAD 2>/dev/null || echo unknown)}
COMMON_REV=${COMMON_REV:-$(git -C "$COMMON" rev-parse HEAD 2>/dev/null || echo unknown)}
ESPHOME=$("$WORK/venv/bin/esphome" version 2>/dev/null | sed 's/^Version: //' || echo unknown)
D=$(mktemp -d)
trap 'rm -rf "$D"' EXIT
T=$D/tsx-xx50-panel-app-$VER
mkdir -p "$T"
cp -r "$PROJ/src" "$T/"
cp "$PROJ/platformio.ini" "$PROJ"/*.py "$HERE/compile.sh" "$T/"
{
	echo "package: tsx-xx50-panel-app $VER"
	echo "esphome: $ESPHOME"
	echo "platformio: ${PIO_VERSION:-6.1.19}"
	echo "tsx-xx50-linux: $XX50_REV"
	echo "tsx-linux-common: $COMMON_REV"
	echo "program sha256 (build.sh): $(sha256sum "$BIN" | cut -d' ' -f1)"
} > "$T/BUILDINFO"
chmod -R u=rwX,go=rX "$T"
tar -C "$D" --sort=name --owner=0 --group=0 --numeric-owner --mtime=@0 -cf - "tsx-xx50-panel-app-$VER" |
	gzip -9n > "$OUT/tsx-xx50-panel-app-src-$VER.tar.gz"
cat "$T/BUILDINFO"
ls -l "$OUT/tsx-xx50-panel-app-src-$VER.tar.gz"
