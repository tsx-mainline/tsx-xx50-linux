/*
 * lvbench: drawing and memory speed tests for LVGL 9.5 on a Linux panel.
 *
 *   lvbench mem
 *       Memory speed: cached RAM, and a DRM dumb buffer (write-combined).
 *   lvbench [options] render SCENE...
 *       LVGL draws each scene into a RAM buffer. No display is used. The
 *       clock of LVGL is simulated (16 ms for each frame).
 *   lvbench [options] OUT SCENE...
 *       OUT is one of:
 *         drm-lvgl    the LVGL Linux DRM driver: LVGL draws straight into
 *                     two dumb buffers (direct mode) and flips them.
 *         drm-shadow  LVGL draws into one cached RAM frame (direct mode).
 *                     The changed areas of this frame and of the frame
 *                     before go to the back dumb buffer, then a page flip.
 *         drm-front   as drm-shadow, but one dumb buffer and no flip.
 *       These need the display (stop the panel app first). They use the
 *       real clock and run each scene for -t seconds.
 *
 * Options: -b FRAC      render: draw buffer of 1/FRAC frame (default 1)
 *          -f 565|8888  buffer format (default 565)
 *          -n FRAMES    frames for "render" (default 60)
 *          -t SECONDS   seconds for each scene on a display (default 5)
 * Scenes:  plain, cards[:MODS], spinner, arc, bar, clock, swipe[:MODS],
 *          press[:MODS]. MODS is a comma list of card styles: r0, shadow,
 *          grad, border, opa, outline, noicon, notext, bigtext.
 *
 * Output: one line for each scene with "key=value" pairs.
 *
 * SPDX-License-Identifier: GPL-2.0-or-later
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/resource.h>
#include <time.h>
#include <unistd.h>
#include <xf86drm.h>
#include <xf86drmMode.h>
#include <drm_fourcc.h>

#include "lvgl.h"

#define W 800
#define H 480

static uint64_t now_us(void)
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (uint64_t)ts.tv_sec * 1000000u + ts.tv_nsec / 1000;
}

static uint64_t cpu_us(void)
{
	struct rusage ru;
	getrusage(RUSAGE_SELF, &ru);
	return (uint64_t)(ru.ru_utime.tv_sec + ru.ru_stime.tv_sec) * 1000000u +
	       ru.ru_utime.tv_usec + ru.ru_stime.tv_usec;
}

static int cur_mhz(void)
{
	FILE *f = fopen("/sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq", "r");
	int khz = 0;
	if (f) {
		if (fscanf(f, "%d", &khz) != 1)
			khz = 0;
		fclose(f);
	}
	return khz / 1000;
}

/* ---------------------------------------------------------------- DRM */

struct dumb {
	uint32_t handle, fb, pitch, size;
	uint8_t *map;
};

struct kms {
	int fd;
	uint32_t conn, crtc;
	drmModeModeInfo mode;
	struct dumb buf[2];
	int nbuf;
	int front;		/* the buffer on the screen */
	int flip_pending;
	uint32_t fourcc;
};

static int dumb_create(int fd, struct dumb *d, int w, int h, int bpp, uint32_t fourcc, int addfb)
{
	struct drm_mode_create_dumb c = { .width = w, .height = h, .bpp = bpp };
	struct drm_mode_map_dumb m = { 0 };
	if (drmIoctl(fd, DRM_IOCTL_MODE_CREATE_DUMB, &c)) {
		perror("CREATE_DUMB");
		return -1;
	}
	d->handle = c.handle;
	d->pitch = c.pitch;
	d->size = c.size;
	m.handle = c.handle;
	if (drmIoctl(fd, DRM_IOCTL_MODE_MAP_DUMB, &m)) {
		perror("MAP_DUMB");
		return -1;
	}
	d->map = mmap(NULL, d->size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, m.offset);
	if (d->map == MAP_FAILED) {
		perror("mmap dumb");
		return -1;
	}
	if (addfb) {
		uint32_t handles[4] = { d->handle }, pitches[4] = { d->pitch }, offsets[4] = { 0 };
		if (drmModeAddFB2(fd, w, h, fourcc, handles, pitches, offsets, &d->fb, 0)) {
			perror("AddFB2");
			return -1;
		}
	}
	return 0;
}

static void page_flip_done(int fd, unsigned seq, unsigned s, unsigned us, void *data)
{
	(void)fd; (void)seq; (void)s; (void)us;
	((struct kms *)data)->flip_pending = 0;
}

static void kms_wait_flip(struct kms *k)
{
	drmEventContext ev = { .version = 2, .page_flip_handler = page_flip_done };
	struct pollfd p = { .fd = k->fd, .events = POLLIN };
	while (k->flip_pending) {
		if (poll(&p, 1, 1000) <= 0) {
			fprintf(stderr, "page flip timeout\n");
			k->flip_pending = 0;
			break;
		}
		drmHandleEvent(k->fd, &ev);
	}
}

static int kms_open(struct kms *k, int bpp, int nbuf)
{
	memset(k, 0, sizeof(*k));
	k->nbuf = nbuf;
	k->fourcc = bpp == 16 ? DRM_FORMAT_RGB565 : DRM_FORMAT_XRGB8888;
	k->fd = open("/dev/dri/card0", O_RDWR | O_CLOEXEC);
	if (k->fd < 0) {
		perror("/dev/dri/card0");
		return -1;
	}
	drmModeRes *r = drmModeGetResources(k->fd);
	if (!r)
		return -1;
	for (int i = 0; i < r->count_connectors && !k->conn; i++) {
		drmModeConnector *c = drmModeGetConnector(k->fd, r->connectors[i]);
		if (c && c->connection == DRM_MODE_CONNECTED && c->count_modes) {
			k->conn = c->connector_id;
			k->mode = c->modes[0];
			drmModeEncoder *e = drmModeGetEncoder(k->fd, c->encoder_id ? c->encoder_id : c->encoders[0]);
			k->crtc = (e && e->crtc_id) ? e->crtc_id : r->crtcs[0];
			if (e)
				drmModeFreeEncoder(e);
		}
		drmModeFreeConnector(c);
	}
	drmModeFreeResources(r);
	if (!k->conn) {
		fprintf(stderr, "no connected display\n");
		return -1;
	}
	for (int i = 0; i < nbuf; i++) {
		if (dumb_create(k->fd, &k->buf[i], k->mode.hdisplay, k->mode.vdisplay, bpp, k->fourcc, 1))
			return -1;
		memset(k->buf[i].map, 0, k->buf[i].size);
	}
	if (drmModeSetCrtc(k->fd, k->crtc, k->buf[0].fb, 0, 0, &k->conn, 1, &k->mode)) {
		perror("SetCrtc (is another program on the display?)");
		return -1;
	}
	return 0;
}

static void kms_close(struct kms *k)
{
	for (int i = 0; i < k->nbuf; i++) {
		struct drm_mode_destroy_dumb d = { .handle = k->buf[i].handle };
		drmModeRmFB(k->fd, k->buf[i].fb);
		munmap(k->buf[i].map, k->buf[i].size);
		drmIoctl(k->fd, DRM_IOCTL_MODE_DESTROY_DUMB, &d);
	}
	close(k->fd);
}

/* ------------------------------------------------------------ mem test */

static uint32_t sum32(const uint8_t *p, size_t n)
{
	const uint32_t *q = (const uint32_t *)p;
	uint32_t s = 0;
	for (size_t i = 0; i < n / 4; i++)
		s += q[i];
	return s;
}

static void copy_rect(uint8_t *dst, int dpitch, const uint8_t *src, int spitch, int x, int y, int w, int h, int bypp)
{
	for (int r = 0; r < h; r++)
		memcpy(dst + (size_t)(y + r) * dpitch + (size_t)x * bypp,
		       src + (size_t)(y + r) * spitch + (size_t)x * bypp, (size_t)w * bypp);
}

static volatile uint32_t sink;

#define MEMRUN(name, bytes, reps, stmt) do { \
		stmt; \
		uint64_t t0_ = now_us(); \
		for (int i_ = 0; i_ < (reps); i_++) { stmt; } \
		uint64_t dt_ = now_us() - t0_; \
		printf("mem test=%s MB/s=%.0f ms_per_op=%.3f\n", name, \
		       (double)(bytes) * (reps) / (dt_ ? dt_ : 1), dt_ / 1000.0 / (reps)); \
	} while (0)

static int cmd_mem(void)
{
	const size_t n = W * H * 2;	/* one RGB565 frame: 768000 bytes */
	const int reps = 40;
	uint8_t *a = aligned_alloc(64, 4 << 20), *b = aligned_alloc(64, 4 << 20);
	memset(a, 1, 4 << 20);
	memset(b, 2, 4 << 20);
	printf("mem cpu_mhz=%d bytes=%zu\n", cur_mhz(), n);

	MEMRUN("ram_memset", n, reps, memset(a, 3, n));
	MEMRUN("ram_read", n, reps, sink += sum32(a, n));
	MEMRUN("ram_to_ram_memcpy", n, reps, memcpy(b, a, n));
	MEMRUN("ram_to_ram_rect_400x200", 400 * 200 * 2, reps * 4, copy_rect(b, W * 2, a, W * 2, 200, 140, 400, 200, 2));
	MEMRUN("ram_to_ram_rect_110x110", 110 * 110 * 2, reps * 20, copy_rect(b, W * 2, a, W * 2, 300, 140, 110, 110, 2));

	int fd = open("/dev/dri/card0", O_RDWR | O_CLOEXEC);
	struct dumb d;
	if (fd < 0 || dumb_create(fd, &d, W, H, 16, DRM_FORMAT_RGB565, 0)) {
		printf("mem dumb=unavailable\n");
		return 0;
	}
	MEMRUN("dumb_memset", n, reps, memset(d.map, 3, n));
	MEMRUN("dumb_read", n, 4, sink += sum32(d.map, n));
	MEMRUN("ram_to_dumb_memcpy", n, reps, memcpy(d.map, a, n));
	MEMRUN("dumb_to_ram_memcpy", n, 4, memcpy(b, d.map, n));
	MEMRUN("ram_to_dumb_rect_400x200", 400 * 200 * 2, reps * 4,
	       copy_rect(d.map, d.pitch, a, W * 2, 200, 140, 400, 200, 2));
	MEMRUN("ram_to_dumb_rect_110x110", 110 * 110 * 2, reps * 20,
	       copy_rect(d.map, d.pitch, a, W * 2, 300, 140, 110, 110, 2));
	/* read-modify-write in the dumb buffer: what a blend into it costs */
	MEMRUN("dumb_rmw_blend_rect_400x200", 400 * 200 * 2, 4, {
		for (int y_ = 0; y_ < 200; y_++) {
			uint16_t *p_ = (uint16_t *)(d.map + (size_t)(140 + y_) * d.pitch) + 200;
			for (int x_ = 0; x_ < 400; x_++)
				p_[x_] = (uint16_t)((p_[x_] >> 1) & 0x7bef) + 0x1082;
		}
	});
	MEMRUN("ram_rmw_blend_rect_400x200", 400 * 200 * 2, reps, {
		for (int y_ = 0; y_ < 200; y_++) {
			uint16_t *p_ = (uint16_t *)(a + (size_t)(140 + y_) * W * 2) + 200;
			for (int x_ = 0; x_ < 400; x_++)
				p_[x_] = (uint16_t)((p_[x_] >> 1) & 0x7bef) + 0x1082;
		}
	});
	printf("mem cpu_mhz_end=%d\n", cur_mhz());
	return 0;
}

/* -------------------------------------------------------------- scenes */

static uint32_t fake_ms;
static int fake_clock;

static uint32_t tick_cb(void)
{
	return fake_clock ? fake_ms : (uint32_t)(now_us() / 1000);
}

struct mods {
	int r0, shadow, grad, border, opa, outline, noicon, notext, bigtext;
};

static void parse_mods(const char *s, struct mods *m)
{
	memset(m, 0, sizeof(*m));
	if (!s)
		return;
	char buf[128];
	snprintf(buf, sizeof buf, "%s", s);
	for (char *t = strtok(buf, ","); t; t = strtok(NULL, ",")) {
		if (!strcmp(t, "r0")) m->r0 = 1;
		else if (!strcmp(t, "shadow")) m->shadow = 1;
		else if (!strcmp(t, "grad")) m->grad = 1;
		else if (!strcmp(t, "border")) m->border = 1;
		else if (!strcmp(t, "opa")) m->opa = 1;
		else if (!strcmp(t, "outline")) m->outline = 1;
		else if (!strcmp(t, "noicon")) m->noicon = 1;
		else if (!strcmp(t, "notext")) m->notext = 1;
		else if (!strcmp(t, "bigtext")) m->bigtext = 1;
		else fprintf(stderr, "unknown style %s\n", t);
	}
}

/* A card page like the panel app: a 4x3 grid of cards with radius 14, an
 * icon, a name and a state, and a bar of 64 px at the bottom. */
static lv_obj_t *first_card;

static void build_cards(lv_obj_t *parent, const struct mods *m, int page)
{
	const int gap = 10, cols = 4, rows = 3, area_h = H - 64;
	const int cw = (W - gap * (cols + 1)) / cols, ch = (area_h - gap * (rows + 1)) / rows;
	static const char *icons[] = { LV_SYMBOL_HOME, LV_SYMBOL_POWER, LV_SYMBOL_SETTINGS, LV_SYMBOL_AUDIO,
				       LV_SYMBOL_WIFI, LV_SYMBOL_BELL, LV_SYMBOL_EYE_OPEN, LV_SYMBOL_CHARGE };
	for (int i = 0; i < cols * rows; i++) {
		lv_obj_t *o = lv_obj_create(parent);
		lv_obj_remove_style_all(o);
		lv_obj_set_pos(o, gap + (i % cols) * (cw + gap), gap + (i / cols) * (ch + gap));
		lv_obj_set_size(o, cw, ch);
		lv_obj_set_style_radius(o, m->r0 ? 0 : 14, 0);
		lv_obj_set_style_bg_opa(o, m->opa ? LV_OPA_70 : LV_OPA_COVER, 0);
		lv_obj_set_style_bg_color(o, lv_color_hex((i + page) % 3 ? 0x2a3038 : 0x3b5b8c), 0);
		if (m->grad) {
			lv_obj_set_style_bg_grad_color(o, lv_color_hex(0x101820), 0);
			lv_obj_set_style_bg_grad_dir(o, LV_GRAD_DIR_VER, 0);
		}
		if (m->shadow) {
			lv_obj_set_style_shadow_width(o, 16, 0);
			lv_obj_set_style_shadow_offset_y(o, 4, 0);
			lv_obj_set_style_shadow_opa(o, LV_OPA_50, 0);
			lv_obj_set_style_shadow_color(o, lv_color_hex(0x000000), 0);
		}
		if (m->border) {
			lv_obj_set_style_border_width(o, 2, 0);
			lv_obj_set_style_border_color(o, lv_color_hex(0x5a6a7a), 0);
		}
		if (m->outline) {
			lv_obj_set_style_outline_width(o, 2, 0);
			lv_obj_set_style_outline_color(o, lv_color_hex(0x80a0ff), 0);
		}
		lv_obj_set_style_pad_all(o, 12, 0);
		lv_obj_remove_flag(o, LV_OBJ_FLAG_SCROLLABLE);
		if (!first_card)
			first_card = o;
		if (!m->noicon) {
			lv_obj_t *ic = lv_label_create(o);
			lv_obj_set_style_text_font(ic, &lv_font_montserrat_28, 0);
			lv_obj_set_style_text_color(ic, lv_color_hex(0xf0c040), 0);
			lv_label_set_text(ic, icons[i % 8]);
			lv_obj_align(ic, LV_ALIGN_TOP_LEFT, 0, 0);
		}
		if (!m->notext) {
			lv_obj_t *n = lv_label_create(o);
			lv_obj_set_style_text_font(n, m->bigtext ? &lv_font_montserrat_28 : &lv_font_montserrat_20, 0);
			lv_obj_set_style_text_color(n, lv_color_hex(0xe0e0e0), 0);
			lv_label_set_text_fmt(n, "Kitchen %d", i + 1);
			lv_obj_align(n, LV_ALIGN_BOTTOM_LEFT, 0, -22);
			lv_obj_t *s = lv_label_create(o);
			lv_obj_set_style_text_font(s, &lv_font_montserrat_14, 0);
			lv_obj_set_style_text_color(s, lv_color_hex(0x9aa4b0), 0);
			lv_label_set_text(s, i % 2 ? "On - 80 %" : "Off");
			lv_obj_align(s, LV_ALIGN_BOTTOM_LEFT, 0, 0);
		}
	}
}

static void build_bar(lv_obj_t *scr)
{
	lv_obj_t *bar = lv_obj_create(scr);
	lv_obj_remove_style_all(bar);
	lv_obj_set_pos(bar, 0, H - 64);
	lv_obj_set_size(bar, W, 64);
	lv_obj_set_style_bg_opa(bar, LV_OPA_COVER, 0);
	lv_obj_set_style_bg_color(bar, lv_color_hex(0x181c20), 0);
	for (int i = 0; i < 4; i++) {
		lv_obj_t *b = lv_obj_create(bar);
		lv_obj_remove_style_all(b);
		lv_obj_set_pos(b, 10 + i * 130, 8);
		lv_obj_set_size(b, 120, 48);
		lv_obj_set_style_radius(b, 8, 0);
		lv_obj_set_style_bg_opa(b, LV_OPA_COVER, 0);
		lv_obj_set_style_bg_color(b, lv_color_hex(i ? 0x2a3038 : 0x3b5b8c), 0);
		lv_obj_t *l = lv_label_create(b);
		lv_obj_set_style_text_font(l, &lv_font_montserrat_20, 0);
		lv_obj_set_style_text_color(l, lv_color_hex(0xe0e0e0), 0);
		lv_label_set_text_fmt(l, "Page %d", i + 1);
		lv_obj_center(l);
	}
	lv_obj_t *clk = lv_label_create(bar);
	lv_obj_set_style_text_font(clk, &lv_font_montserrat_28, 0);
	lv_obj_set_style_text_color(clk, lv_color_hex(0xe0e0e0), 0);
	lv_label_set_text(clk, "12:34");
	lv_obj_align(clk, LV_ALIGN_RIGHT_MID, -16, 0);
}

enum kind { STATIC, ANIM, SWIPE, PRESS, CLOCK };

static lv_obj_t *swipe_cont, *clock_label;

static enum kind build_scene(const char *spec)
{
	char name[64];
	const char *colon = strchr(spec, ':');
	struct mods m;
	snprintf(name, sizeof name, "%.*s", colon ? (int)(colon - spec) : (int)strlen(spec), spec);
	parse_mods(colon ? colon + 1 : NULL, &m);

	lv_obj_t *scr = lv_obj_create(NULL);
	lv_obj_remove_style_all(scr);
	lv_obj_set_style_bg_opa(scr, LV_OPA_COVER, 0);
	lv_obj_set_style_bg_color(scr, lv_color_hex(0x101418), 0);
	lv_obj_remove_flag(scr, LV_OBJ_FLAG_SCROLLABLE);
	lv_screen_load(scr);
	first_card = NULL;

	if (!strcmp(name, "plain"))
		return STATIC;
	if (!strcmp(name, "cards") || !strcmp(name, "press")) {
		if (m.opa) {	/* something under the cards to blend with */
			lv_obj_set_style_bg_grad_color(scr, lv_color_hex(0x304050), 0);
			lv_obj_set_style_bg_grad_dir(scr, LV_GRAD_DIR_VER, 0);
		}
		build_cards(scr, &m, 0);
		build_bar(scr);
		return name[0] == 'c' ? STATIC : PRESS;
	}
	if (!strcmp(name, "swipe")) {
		/* Two pages in a scrolled container: each frame moves the view
		 * by 25 px, as a finger swipe or a page animation does. */
		swipe_cont = lv_obj_create(scr);
		lv_obj_remove_style_all(swipe_cont);
		lv_obj_set_size(swipe_cont, W, H - 64);
		lv_obj_set_scrollbar_mode(swipe_cont, LV_SCROLLBAR_MODE_OFF);
		for (int p = 0; p < 2; p++) {
			lv_obj_t *pg = lv_obj_create(swipe_cont);
			lv_obj_remove_style_all(pg);
			lv_obj_set_pos(pg, p * W, 0);
			lv_obj_set_size(pg, W, H - 64);
			lv_obj_remove_flag(pg, LV_OBJ_FLAG_SCROLLABLE);
			build_cards(pg, &m, p);
		}
		build_bar(scr);
		return SWIPE;
	}
	if (!strcmp(name, "spinner")) {
		lv_obj_t *s = lv_spinner_create(scr);
		lv_obj_set_size(s, 110, 110);
		lv_obj_set_pos(s, 670, 252);
		lv_spinner_set_anim_params(s, 1000, 90);
		return ANIM;
	}
	if (!strcmp(name, "arc")) {
		lv_obj_t *a = lv_arc_create(scr);
		lv_obj_set_size(a, 200, 200);
		lv_obj_center(a);
		lv_anim_t an;
		lv_anim_init(&an);
		lv_anim_set_var(&an, a);
		lv_anim_set_exec_cb(&an, (lv_anim_exec_xcb_t)lv_arc_set_value);
		lv_anim_set_values(&an, 0, 100);
		lv_anim_set_duration(&an, 1000);
		lv_anim_set_repeat_count(&an, LV_ANIM_REPEAT_INFINITE);
		lv_anim_start(&an);
		return ANIM;
	}
	if (!strcmp(name, "bar")) {
		lv_obj_t *b = lv_bar_create(scr);
		lv_obj_set_size(b, 620, 40);
		lv_obj_set_pos(b, 20, 262);
		lv_anim_t an;
		lv_anim_init(&an);
		lv_anim_set_var(&an, b);
		lv_anim_set_exec_cb(&an, (lv_anim_exec_xcb_t)lv_bar_set_value);
		lv_anim_set_values(&an, 0, 100);
		lv_anim_set_duration(&an, 1500);
		lv_anim_set_reverse_duration(&an, 1500);
		lv_anim_set_repeat_count(&an, LV_ANIM_REPEAT_INFINITE);
		lv_anim_start(&an);
		return ANIM;
	}
	if (!strcmp(name, "clock")) {
		build_cards(scr, &m, 0);
		build_bar(scr);
		clock_label = lv_label_create(scr);
		lv_obj_set_style_text_font(clock_label, &lv_font_montserrat_48, 0);
		lv_obj_set_style_text_color(clock_label, lv_color_hex(0xffffff), 0);
		lv_label_set_text(clock_label, "12:34:00");
		lv_obj_align(clock_label, LV_ALIGN_TOP_MID, 0, 150);
		return CLOCK;
	}
	fprintf(stderr, "unknown scene %s\n", name);
	exit(2);
}

/* One step of a scene that changes by itself. Returns 1 when it changed
 * something that a refresh draws. */
static void scene_step(enum kind k, int frame)
{
	switch (k) {
	case STATIC:
		lv_obj_invalidate(lv_screen_active());
		break;
	case SWIPE: {
		int x = (frame * 25) % (2 * W);
		lv_obj_scroll_to_x(swipe_cont, x < W ? x : 2 * W - x, LV_ANIM_OFF);
		break;
	}
	case PRESS:
		if (frame & 1)
			lv_obj_add_state(first_card, LV_STATE_PRESSED);
		else
			lv_obj_remove_state(first_card, LV_STATE_PRESSED);
		lv_obj_set_style_bg_opa(first_card, frame & 1 ? LV_OPA_60 : LV_OPA_COVER, 0);
		break;
	case CLOCK:
		lv_label_set_text_fmt(clock_label, "12:34:%02d", frame % 60);
		break;
	case ANIM:
		break;
	}
}

/* ------------------------------------------------------- display paths */

static uint64_t px_frame, areas_frame;
static uint64_t t_render0, render_us_sum, render_max;
static int render_frames;

static void ev_render(lv_event_t *e)
{
	if (lv_event_get_code(e) == LV_EVENT_RENDER_START) {
		t_render0 = now_us();
	} else {
		uint64_t d = now_us() - t_render0;
		render_us_sum += d;
		if (d > render_max)
			render_max = d;
		render_frames++;
	}
}

static void flush_null(lv_display_t *d, const lv_area_t *a, uint8_t *px)
{
	(void)px;
	px_frame += lv_area_get_size(a);
	areas_frame++;
	lv_display_flush_ready(d);
}

/* drm-shadow / drm-front state */
static struct kms kms;
static uint8_t *shadow;
static int bypp = 2;
#define MAXA 32
static lv_area_t cur_a[MAXA], prev_a[MAXA];
static int ncur, nprev, cur_full, prev_full;
static uint64_t copy_us_sum, wait_us_sum, copy_bytes;

static void copy_areas(uint8_t *dst, int pitch, const lv_area_t *a, int n, int full)
{
	if (full) {
		copy_rect(dst, pitch, shadow, W * bypp, 0, 0, W, H, bypp);
		copy_bytes += (uint64_t)W * H * bypp;
		return;
	}
	for (int i = 0; i < n; i++) {
		copy_rect(dst, pitch, shadow, W * bypp, a[i].x1, a[i].y1, lv_area_get_width(&a[i]),
			  lv_area_get_height(&a[i]), bypp);
		copy_bytes += (uint64_t)lv_area_get_size(&a[i]) * bypp;
	}
}

static void flush_shadow(lv_display_t *d, const lv_area_t *a, uint8_t *px)
{
	(void)px;
	px_frame += lv_area_get_size(a);
	areas_frame++;
	if (ncur < MAXA)
		cur_a[ncur++] = *a;
	else
		cur_full = 1;
	if (lv_display_flush_is_last(d)) {
		uint64_t t0 = now_us();
		if (kms.nbuf == 1) {
			copy_areas(kms.buf[0].map, kms.buf[0].pitch, cur_a, ncur, cur_full);
			copy_us_sum += now_us() - t0;
		} else {
			kms_wait_flip(&kms);
			uint64_t t1 = now_us();
			wait_us_sum += t1 - t0;
			int back = !kms.front;
			struct dumb *b = &kms.buf[back];
			if (!cur_full)	/* a full frame covers the areas before */
				copy_areas(b->map, b->pitch, prev_a, nprev, prev_full);
			copy_areas(b->map, b->pitch, cur_a, ncur, cur_full);
			copy_us_sum += now_us() - t1;
			if (drmModePageFlip(kms.fd, kms.crtc, b->fb, DRM_MODE_PAGE_FLIP_EVENT, &kms) == 0) {
				kms.flip_pending = 1;
				kms.front = back;
			} else {
				perror("PageFlip");
			}
		}
		memcpy(prev_a, cur_a, sizeof cur_a);
		nprev = ncur;
		prev_full = cur_full;
		ncur = 0;
		cur_full = 0;
	}
	lv_display_flush_ready(d);
}

static const char *out_name;
static lv_display_t *disp;
static int buf_frac = 1;	/* render: the draw buffer is 1/buf_frac of a frame */

static int make_display(int fmt8888)
{
	lv_color_format_t cf = fmt8888 ? LV_COLOR_FORMAT_XRGB8888 : LV_COLOR_FORMAT_RGB565;
	bypp = fmt8888 ? 4 : 2;
	if (!strcmp(out_name, "render")) {
		/* As the ESPHome lvgl component: partial mode, one buffer of a
		 * full frame in RAM. */
		disp = lv_display_create(W, H);
		lv_display_set_color_format(disp, cf);
		size_t sz = (size_t)W * H * bypp / buf_frac;
		lv_display_set_buffers(disp, aligned_alloc(64, sz), NULL, sz, LV_DISPLAY_RENDER_MODE_PARTIAL);
		lv_display_set_flush_cb(disp, flush_null);
	} else if (!strcmp(out_name, "drm-lvgl")) {
#if LV_USE_LINUX_DRM
		if (fmt8888 != (LV_COLOR_DEPTH == 32)) {
			fprintf(stderr, "drm-lvgl uses LV_COLOR_DEPTH only\n");
			return -1;
		}
		disp = lv_linux_drm_create();
		if (lv_linux_drm_set_file(disp, "/dev/dri/card0", -1) != LV_RESULT_OK)
			return -1;
#else
		return -1;
#endif
	} else if (!strcmp(out_name, "drm-shadow") || !strcmp(out_name, "drm-front")) {
		if (kms_open(&kms, fmt8888 ? 32 : 16, out_name[4] == 's' ? 2 : 1))
			return -1;
		disp = lv_display_create(W, H);
		lv_display_set_color_format(disp, cf);
		size_t sz = (size_t)W * H * bypp;
		shadow = aligned_alloc(64, sz);
		memset(shadow, 0, sz);
		lv_display_set_buffers(disp, shadow, NULL, sz, LV_DISPLAY_RENDER_MODE_DIRECT);
		lv_display_set_flush_cb(disp, flush_shadow);
	} else {
		fprintf(stderr, "unknown output %s\n", out_name);
		return -1;
	}
	lv_display_add_event_cb(disp, ev_render, LV_EVENT_RENDER_START, NULL);
	lv_display_add_event_cb(disp, ev_render, LV_EVENT_RENDER_READY, NULL);
	return 0;
}

static void reset_stats(void)
{
	px_frame = areas_frame = render_us_sum = render_max = 0;
	render_frames = 0;
	copy_us_sum = wait_us_sum = copy_bytes = 0;
}

static void run_scene(const char *spec, int frames, double secs)
{
	enum kind k = build_scene(spec);
	/* the first frame draws everything; not counted */
	lv_refr_now(disp);
	if (kms.nbuf == 2)
		kms_wait_flip(&kms);
	reset_stats();
	uint64_t c0 = cpu_us(), t0 = now_us();
	int mhz0 = cur_mhz();
	int f = 0;
	if (fake_clock) {
		for (f = 0; f < frames; f++) {
			fake_ms += 16;
			scene_step(k, f);
			lv_timer_handler();
			lv_refr_now(disp);
		}
	} else {
		uint64_t end = t0 + (uint64_t)(secs * 1e6);
		uint64_t next_step = t0;
		while (now_us() < end) {
			uint64_t t = now_us();
			if (k != ANIM && k != CLOCK) {
				/* a change in each frame, drawn at once: the page
				 * flip (or nothing, in drm-front) sets the pace */
				scene_step(k, f++);
				lv_timer_handler();
				lv_refr_now(disp);
				continue;
			}
			if (k == CLOCK && t >= next_step) {
				scene_step(k, f++);
				next_step = t + 1000000;
			}
			/* sleep until the next LVGL timer, as an app main loop does */
			uint32_t idle = lv_timer_handler();
			if (idle > 0)
				usleep((idle > 50 ? 50 : idle) * 1000);
		}
		if (kms.nbuf == 2)
			kms_wait_flip(&kms);
	}
	uint64_t wall = now_us() - t0, cpu = cpu_us() - c0;
	int n = render_frames ? render_frames : 1;
	printf("scene=%s out=%s buf=1/%d fmt=%s neon=%d frames=%d fps=%.1f render_ms=%.2f render_max_ms=%.2f "
	       "px_per_frame=%llu areas_per_frame=%.1f ns_per_px=%.1f copy_ms=%.2f copy_MBps=%.0f flipwait_ms=%.2f "
	       "cpu_pct=%.0f mhz=%d-%d\n",
	       spec, out_name, buf_frac, bypp == 4 ? "xrgb8888" : "rgb565", LV_USE_DRAW_SW_ASM == LV_DRAW_SW_ASM_NEON,
	       render_frames, render_frames * 1e6 / (wall ? wall : 1), render_us_sum / 1000.0 / n,
	       render_max / 1000.0, (unsigned long long)(px_frame / n), (double)areas_frame / n,
	       px_frame ? render_us_sum * 1000.0 / px_frame : 0, copy_us_sum / 1000.0 / n,
	       copy_us_sum ? (double)copy_bytes / copy_us_sum : 0, wait_us_sum / 1000.0 / n,
	       fake_clock ? 100.0 * cpu / (wall ? wall : 1) : 100.0 * cpu / (wall ? wall : 1), mhz0, cur_mhz());
	fflush(stdout);
	lv_obj_t *old = lv_screen_active();
	lv_screen_load(lv_obj_create(NULL));
	lv_obj_delete(old);
}

int main(int argc, char **argv)
{
	int fmt8888 = 0, frames = 60, opt;
	double secs = 5;
	while ((opt = getopt(argc, argv, "b:f:n:t:")) != -1) {
		switch (opt) {
		case 'f': fmt8888 = !strcmp(optarg, "8888"); break;
		case 'n': frames = atoi(optarg); break;
		case 'b': buf_frac = atoi(optarg) > 0 ? atoi(optarg) : 1; break;
		case 't': secs = atof(optarg); break;
		default: return 2;
		}
	}
	if (optind >= argc) {
		fprintf(stderr, "usage: lvbench mem | lvbench [-f 565|8888] [-n N] [-t S] render|drm-lvgl|drm-shadow|drm-front SCENE...\n");
		return 2;
	}
	if (!strcmp(argv[optind], "mem"))
		return cmd_mem();
	out_name = argv[optind++];
	fake_clock = !strcmp(out_name, "render");
	lv_init();
	lv_tick_set_cb(tick_cb);
	if (make_display(fmt8888))
		return 1;
	for (; optind < argc; optind++)
		run_scene(argv[optind], frames, secs);
	if (kms.fd > 0)
		kms_close(&kms);
	return 0;
}
