#!/bin/sh
# build-bench.sh LVGL_DIR OUT_DIR: build lvbench for armv7 Alpine (run it
# on the build host). Makes OUT_DIR/lvbench (no NEON) and
# OUT_DIR/lvbench-neon (LV_USE_DRAW_SW_ASM = NEON, -mfpu=neon). With
# GL=1 also OUT_DIR/lvbench-gl (32 bit color, the LVGL DRM driver on
# EGL/GBM with the OpenGL ES draw unit) and OUT_DIR/lvbench-glsw (the same
# without the draw unit: software drawing, one texture upload per frame).
# Needs docker and an armv7 Alpine image with build-base and libdrm-dev
# (IMG, default tsx-xx50-accel:armv7). LVGL_DIR is an LVGL 9.5.0 tree.
set -eu
[ $# -eq 2 ] || { sed -n '2,7p' "$0"; exit 2; }
HERE=$(cd "$(dirname "$0")" && pwd)
LV=$(cd "$1" && pwd)
OUT=$(mkdir -p "$2" && cd "$2" && pwd)
IMG=${IMG:-tsx-xx50-accel:armv7}
docker run --rm --platform linux/arm/v7 --user "$(id -u):$(id -g)" \
	-e GL="${GL:-0}" -v "$HERE:/src:ro" -v "$LV:/lvgl:ro" -v "$OUT:/out" -w /out "$IMG" sh -euc '
V="plain neon"; [ "$GL" = 1 ] && V="$V gl glsw"
for v in $V; do
	L="-ldrm -lm"
	GLF="-DLV_COLOR_DEPTH=32 -DLV_LINUX_DRM_USE_EGL=1 -DLV_USE_OPENGLES=1 -DLV_USE_MATRIX=1 -DLV_USE_FLOAT=1"
	case $v in
	neon) F="-mfpu=neon -DLV_USE_DRAW_SW_ASM=LV_DRAW_SW_ASM_NEON";;
	gl) F="$GLF -DLV_USE_DRAW_OPENGLES=1"; L="$L -lEGL -lGLESv2 -lgbm";;
	glsw) F="$GLF"; L="$L -lEGL -lGLESv2 -lgbm";;
	*) F="";;
	esac
	CFLAGS="-O2 $F -I/src -I/lvgl -I/usr/include/libdrm -DLV_CONF_INCLUDE_SIMPLE"
	# objects are kept between runs; new flags or a new lv_conf.h: build all again
	stamp="$CFLAGS $(md5sum /src/lv_conf.h)"
	[ "$(cat obj-$v/flags 2>/dev/null)" = "$stamp" ] || rm -rf obj-$v
	mkdir -p obj-$v
	echo "$stamp" > obj-$v/flags
	find /lvgl/src -name "*.c" | sed "s|^/lvgl/||" > files.txt
	# compile in parallel; one object per source
	cat files.txt | xargs -P "$(nproc)" -I{} sh -c "o=obj-$v/\$(echo {} | tr / _).o; [ \$o -nt /lvgl/{} ] || gcc $CFLAGS -c /lvgl/{} -o \$o"
	gcc $CFLAGS -c /src/lvbench.c -o obj-$v/lvbench.o
	gcc -o lvbench-$v obj-$v/*.o $L
	strip lvbench-$v
done
mv lvbench-plain lvbench
ls -l lvbench*'
