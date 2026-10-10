// tsx_perf.h: frame time counters for the LVGL tests on the TSS-752.
// Include it with `esphome: includes: [tsx_perf.h]`.
//   tsx_perf::install()   call once (on_boot): adds the display event hooks
//   tsx_perf::report()    returns a line with fps and render times, resets
//   tsx_perf::anim_bar()  starts an endless LVGL animation on a bar
//   tsx_perf::mark(what)  logs the time since the process start
// A frame is one LVGL render pass (LV_EVENT_RENDER_START to RENDER_READY),
// so it includes the flush to the display.
#pragma once
#include <cstdio>
#include <ctime>
#include <string>
#include "lvgl.h"
#include "esphome/core/log.h"

namespace tsx_perf {

static inline uint64_t mono_us() {
  timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return uint64_t(ts.tv_sec) * 1000000ULL + ts.tv_nsec / 1000;
}

static uint64_t t_render, win_start, frames, sum_us, max_us;
static bool first_done;
// Set when the program loads (static initialisation, before main).
static const uint64_t proc_start = mono_us();

static inline void mark(const char *what) {
  timespec rt;
  clock_gettime(CLOCK_REALTIME, &rt);
  ESP_LOGI("perf", "%s: %.3f s after process start (realtime %ld.%03ld)", what, (mono_us() - proc_start) / 1e6,
           (long) rt.tv_sec, rt.tv_nsec / 1000000);
}

static void on_event(lv_event_t *e) {
  lv_event_code_t code = lv_event_get_code(e);
  if (code == LV_EVENT_RENDER_START) {
    t_render = mono_us();
  } else if (code == LV_EVENT_RENDER_READY) {
    uint64_t d = mono_us() - t_render;
    frames++;
    sum_us += d;
    if (d > max_us)
      max_us = d;
    if (!first_done) {
      first_done = true;
      ESP_LOGI("perf", "first frame rendered in %.1f ms", d / 1000.0);
      mark("first frame");
    }
  }
}

static inline void install() {
  lv_display_t *disp = lv_display_get_default();
  lv_display_add_event_cb(disp, on_event, LV_EVENT_RENDER_START, nullptr);
  lv_display_add_event_cb(disp, on_event, LV_EVENT_RENDER_READY, nullptr);
  win_start = mono_us();
}

static inline std::string report() {
  uint64_t now = mono_us();
  double s = (now - win_start) / 1e6;
  char buf[96];
  snprintf(buf, sizeof buf, "%.1f fps, render avg %.1f ms, max %.1f ms", s > 0 ? frames / s : 0.0,
           frames ? sum_us / 1000.0 / frames : 0.0, max_us / 1000.0);
  win_start = now;
  frames = sum_us = max_us = 0;
  return buf;
}

// ESPHome turns on only the LVGL widgets that the YAML uses.
#if LV_USE_BAR
static void bar_exec(void *obj, int32_t v) { lv_bar_set_value((lv_obj_t *) obj, v, LV_ANIM_OFF); }

static inline void anim_bar(lv_obj_t *bar, uint32_t ms) {
  lv_anim_t a;
  lv_anim_init(&a);
  lv_anim_set_var(&a, bar);
  lv_anim_set_exec_cb(&a, bar_exec);
  lv_anim_set_values(&a, 0, 100);
  lv_anim_set_duration(&a, ms);
  lv_anim_set_playback_duration(&a, ms);
  lv_anim_set_repeat_count(&a, LV_ANIM_REPEAT_INFINITE);
  lv_anim_start(&a);
}

static inline void stop_bar(lv_obj_t *bar) { lv_anim_delete(bar, bar_exec); }
#endif

}  // namespace tsx_perf
