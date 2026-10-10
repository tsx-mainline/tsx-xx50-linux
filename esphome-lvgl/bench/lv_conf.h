/* lv_conf.h for lvbench (LVGL 9.5). The values that ESPHome writes for the
 * panel app are the same here (16 bit color, the software renderer, no OS),
 * so the numbers of lvbench apply to the panel app. build-bench.sh sets
 * LV_USE_DRAW_SW_ASM (NEON or not) on the command line. */
#ifndef LV_CONF_H
#define LV_CONF_H

#ifndef LV_COLOR_DEPTH
#define LV_COLOR_DEPTH 16
#endif
#define LV_USE_STDLIB_MALLOC LV_STDLIB_CLIB
#define LV_USE_STDLIB_STRING LV_STDLIB_CLIB
#define LV_USE_STDLIB_SPRINTF LV_STDLIB_CLIB
#define LV_USE_OS LV_OS_NONE
#define LV_DEF_REFR_PERIOD 16

#ifndef LV_DRAW_BUF_ALIGN
#define LV_DRAW_BUF_ALIGN 4
#endif
#define LV_DRAW_BUF_STRIDE_ALIGN 1

#define LV_USE_DRAW_SW 1
#define LV_DRAW_SW_COMPLEX 1
#define LV_DRAW_SW_DRAW_UNIT_CNT 1
#ifndef LV_USE_DRAW_SW_ASM
#define LV_USE_DRAW_SW_ASM LV_DRAW_SW_ASM_NONE
#endif
#define LV_DRAW_SW_SUPPORT_RGB565 1
#define LV_DRAW_SW_SUPPORT_RGB888 1
#define LV_DRAW_SW_SUPPORT_XRGB8888 1
#define LV_DRAW_SW_SUPPORT_ARGB8888 1
#define LV_DRAW_SW_SUPPORT_A8 1
#define LV_DRAW_SW_SUPPORT_L8 0
#define LV_DRAW_SW_SUPPORT_AL88 0
#define LV_DRAW_SW_SUPPORT_I1 0
#define LV_DRAW_SW_SUPPORT_RGB565A8 1
#define LV_GRADIENT_MAX_STOPS 2

#define LV_FONT_MONTSERRAT_14 1
#define LV_FONT_MONTSERRAT_20 1
#define LV_FONT_MONTSERRAT_28 1
#define LV_FONT_MONTSERRAT_48 1
#define LV_FONT_DEFAULT &lv_font_montserrat_14

#define LV_USE_LOG 1
#define LV_LOG_LEVEL LV_LOG_LEVEL_WARN
#define LV_LOG_PRINTF 1

#define LV_USE_THEME_DEFAULT 1
#define LV_THEME_DEFAULT_DARK 1

#ifndef LV_USE_LINUX_DRM
#define LV_USE_LINUX_DRM 1
#endif
#ifndef LV_LINUX_DRM_USE_EGL
#define LV_LINUX_DRM_USE_EGL 0
#endif

#define LV_BUILD_EXAMPLES 0
#define LV_BUILD_DEMOS 0

#endif
