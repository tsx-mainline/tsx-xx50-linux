#!/bin/sh
# Compile a generated ESPHome project for armv7 Alpine (PlatformIO "native").
#
#   compile.sh <project-dir> <out-file>
#
# <project-dir>  the project that build.sh generates, or the folder of the
#                source archive that mksource.sh makes (tsx-aports builds
#                the package tsx-xx50-panel-app from it with this script).
# <out-file>     the stripped program
# Needs pio (PlatformIO) in PATH, g++ and libdrm-dev. PlatformIO downloads
# the libraries of platformio.ini (lib_deps, exact versions) and the native
# platform to PLATFORMIO_CORE_DIR. Env: JOBS (default: the number of CPUs).
# platformio.ini names the project folder as @PROJECT_DIR@. The script
# writes a copy with the real folder and leaves platformio.ini as it is.
set -eu
[ $# -eq 2 ] || { awk 'NR > 1 && !/^#/ {exit} NR > 1 {print}' "$0"; exit 2; }
P=$(cd "$1" && pwd)
OUT=$2
NAME=$(sed -n 's/^\[env:\(.*\)\]$/\1/p' "$P/platformio.ini" | head -1)
[ -n "$NAME" ] || { echo "ERROR: no [env:...] in $P/platformio.ini" >&2; exit 1; }
sed "s|@PROJECT_DIR@|$P|g" "$P/platformio.ini" > "$P/platformio-build.ini"
pio run -d "$P" -c "$P/platformio-build.ini" -j "${JOBS:-$(nproc)}"
strip -o "$OUT" "$P/.pio/build/$NAME/program"
echo "compile.sh: $OUT ($(wc -c < "$OUT") bytes)"
