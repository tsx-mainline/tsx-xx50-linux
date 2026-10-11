// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * tsx-xx50-init: /init of the xx50 boot ramdisk.
 *
 * The stock U-Boot loads a ramdisk of at most 384 KiB with the kernel, so
 * the ramdisk holds only this program, tsx-splash (static) and one splash
 * frame. The program:
 *   1. mounts /dev, /proc and /sys,
 *   2. draws the boot splash on /dev/fb0 (tsx-splash show),
 *   3. waits for the root partition of the kernel command line
 *      (root=PARTUUID=<disk id>-<partition> of an MBR disk, or root=/dev/...),
 *   4. starts the rescue system instead when a rescue trigger is there (see
 *      below),
 *   5. mounts the root partition as the kernel does (rootfstype=, rootflags=,
 *      ro or rw),
 *   6. moves /dev, /proc and /sys to it, deletes the ramdisk files and
 *      starts init= (default /sbin/init) of the root file system.
 * The splash stays on the screen until a program takes the display (the
 * panel app). The kernel command line keeps the text console off the LCD
 * (fbcon=map:1).
 *
 * The rescue system. The card holds it in the rescue slot: a raw area at
 * 0x300000 (3 MiB) of 5 MiB, below the first partition. The slot starts with
 * a header of 512 bytes (text lines, padded with zeros):
 *   TSX-RESCUE 1
 *   size <bytes of the archive>
 *   version <text for the rescue screen>
 * The archive follows: a gzip-compressed cpio (newc) of the rescue root file
 * system (image/mkrescue.sh). The program checks the gzip checksum, unpacks
 * the archive into a tmpfs and starts /sbin/init there (busybox init). So
 * the rescue system runs from RAM and never writes the card by itself.
 * The rescue starts when:
 *   - the U-Boot env says golden=1: U-Boot booted the golden slots, after
 *     two failed boots of the normal slots (tsx-boot-ok) or on request
 *     (tsx-boot-rescue --golden),
 *   - the FAT partition (p1, TSXLOG) holds a file RESCUE or RESCUE.TXT (any
 *     case). The program deletes the file, so the next boot is normal. A line
 *     tsx.ip=A.B.C.D/NN[,GW] in the file gives the rescue a static address,
 *   - a finger touches the screen while the splash shows "touch and hold for
 *     the rescue system" (TOUCH_WAIT_MS, 1.5 s) and stays there for HOLD_S
 *     seconds (a count-down on the splash). The FT5x06 driver resets the
 *     touch controller when it starts, and the controller then ignores a
 *     finger that is already on the screen. So a finger that touches the
 *     screen before the splash shows does not count. Each boot waits for
 *     TOUCH_WAIT_MS at the splash. There is no wait with tsx.verbose or
 *     without a touch screen,
 *   - tsx.rescue is on the kernel command line,
 *   - /etc/tsx/force-rescue is on the root file system (tsx-boot-rescue). The
 *     program deletes it, so the next boot is normal,
 *   - the root partition does not show up, does not mount, or has no init.
 * The reason goes to /run/rescue-reason of the rescue system, the content
 * of the RESCUE file to /run/tsx-rescue-args. If the rescue slot holds no
 * valid rescue system, a requested rescue writes the reason to the kernel
 * log and the boot goes on normally.
 *
 * Text console instead of the splash: tsx.verbose on the command line, or
 * /etc/tsx/boot-verbose on the root file system (panel.conf BOOT_VERBOSE).
 * If the root partition is not usable and there is no rescue system, the
 * program gives the screen to the text console, writes the reason to the
 * kernel log and exits. The kernel then panics and restarts after panic=
 * seconds, as it does without a ramdisk.
 *
 * Not PID 1 (tests on a running system or a build host):
 *   tsx-xx50-init                       find the root partition and print
 *                                       what the program would do
 *   tsx-xx50-init --env FILE [OFFSET]   print the retry counters of a U-Boot
 *                                       env (128 KiB at OFFSET, default 0)
 *   tsx-xx50-init --rescue FILE [OFFSET] DIR
 *                                       check a rescue slot (at OFFSET of
 *                                       FILE, default 0) and unpack it to DIR
 *   tsx-xx50-init --flag DIR            look for the RESCUE file in DIR (it
 *                                       is deleted) and print its content
 *   tsx-xx50-init --touch SPEC          run the touch trigger with a fake
 *                                       touch screen and print the result and
 *                                       the time: SPEC "none" (no touch
 *                                       screen), "-" (no touch), "D" (a finger
 *                                       from D ms on) or "D-U" (a finger from
 *                                       D ms to U ms), from the start of the
 *                                       wait
 */
#define _GNU_SOURCE
#include <ctype.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/input.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <sys/sysmacros.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>
#include <zlib.h>

#define SPLASH "/usr/local/bin/tsx-splash"
#define NEWROOT "/newroot"
#define TSXLOG_DIR "/tsxlog"

#define ENV_OFFSET 0xC0000
#define ENV_SIZE 0x20000
#define RESCUE_OFFSET 0x300000
#define RESCUE_AREA 0x500000
#define RESCUE_HDR 512
#define RESCUE_MAX_UNPACKED (64 << 20)
#define HOLD_S 3
#define TOUCH_WAIT_MS 1500

static char cmdline[4096];
static int test_mode;

static void msg(const char *fmt, ...)
{
	char b[512];
	va_list ap;
	int fd, n;

	va_start(ap, fmt);
	n = vsnprintf(b, sizeof(b) - 1, fmt, ap);
	va_end(ap);
	if (n < 0)
		return;
	if (n > (int)sizeof(b) - 2)
		n = sizeof(b) - 2;
	b[n++] = '\n';
	if (test_mode) {
		fwrite(b, 1, n, stdout);
		return;
	}
	fd = open("/dev/kmsg", O_WRONLY | O_CLOEXEC);
	if (fd >= 0) {
		dprintf(fd, "tsx-init: %.*s", n, b);
		close(fd);
	}
}

/* The value of KEY= on the command line, or NULL. */
static const char *arg(const char *key, char *out, size_t len)
{
	size_t kl = strlen(key);
	const char *p = cmdline;

	while (*p) {
		const char *e;

		while (*p == ' ' || *p == '\n')
			p++;
		e = p + strcspn(p, " \n");
		if ((size_t)(e - p) > kl && !strncmp(p, key, kl) && p[kl] == '=') {
			size_t n = e - p - kl - 1;

			if (n >= len)
				n = len - 1;
			memcpy(out, p + kl + 1, n);
			out[n] = 0;
			return out;
		}
		p = e;
	}
	return NULL;
}

/* 1 if WORD is on the command line as a word of its own. */
static int flag(const char *word)
{
	size_t wl = strlen(word);
	const char *p = cmdline;

	while (*p) {
		const char *e;

		while (*p == ' ' || *p == '\n')
			p++;
		e = p + strcspn(p, " \n");
		if ((size_t)(e - p) == wl && !strncmp(p, word, wl))
			return 1;
		p = e;
	}
	return 0;
}

static int run(char *const argv[])
{
	pid_t pid = fork();
	int st;

	if (pid < 0)
		return -1;
	if (!pid) {
		execv(argv[0], argv);
		_exit(127);
	}
	while (waitpid(pid, &st, 0) < 0 && errno == EINTR)
		;
	return WIFEXITED(st) ? WEXITSTATUS(st) : -1;
}

static double now(void)
{
	struct timespec t;

	clock_gettime(CLOCK_MONOTONIC, &t);
	return t.tv_sec + t.tv_nsec / 1e9;
}

static void nap(long ms)
{
	struct timespec t = { ms / 1000, (ms % 1000) * 1000000L };

	nanosleep(&t, NULL);
}

static int read_line(const char *path, char *b, size_t len)
{
	FILE *f = fopen(path, "r");

	if (!f)
		return -1;
	if (!fgets(b, len, f))
		b[0] = 0;
	fclose(f);
	b[strcspn(b, "\n")] = 0;
	return 0;
}

/* The MBR disk signature (the 32-bit value at byte 440) of DEV, or -1. */
static long disk_sig(const char *dev)
{
	unsigned char s[4];
	int fd = open(dev, O_RDONLY | O_CLOEXEC), ok;

	if (fd < 0)
		return -1;
	ok = pread(fd, s, 4, 440) == 4;
	close(fd);
	if (!ok)
		return -1;
	return s[0] | s[1] << 8 | s[2] << 16 | (unsigned long)s[3] << 24;
}

/*
 * Find the block device of root=. PARTUUID=SSSSSSSS-PP is the MBR disk
 * signature and the partition number, in hex, as the kernel prints it.
 * Write the device number to *dev, the partition name to NAME and the disk
 * (/dev/...) to DISK. Return 0, -1 (not found yet) or -2 (bad root=).
 */
static int find_root(const char *spec, dev_t *dev, char *name, size_t nlen,
		     char *disk, size_t dlen)
{
	unsigned long sig = 0, part = 0;
	DIR *d;
	struct dirent *e;

	if (!strncmp(spec, "/dev/", 5)) {
		struct stat st;
		char p[300], rp[512], *base;

		/* devtmpfs makes the node when the device appears. */
		if (stat(spec, &st) || !S_ISBLK(st.st_mode))
			return -1;
		snprintf(name, nlen, "%s", spec + 5);
		*dev = st.st_rdev;
		snprintf(p, sizeof(p), "/sys/class/block/%s/..", name);
		if (realpath(p, rp) && (base = strrchr(rp, '/')) && strcmp(base + 1, "block"))
			snprintf(disk, dlen, "/dev/%s", base + 1);
		else
			snprintf(disk, dlen, "%s", spec);
		return 0;
	}
	if (strncasecmp(spec, "PARTUUID=", 9) ||
	    sscanf(spec + 9, "%8lx-%2lx", &sig, &part) != 2)
		return -2;

	d = opendir("/sys/class/block");
	if (!d)
		return -1;
	while ((e = readdir(d))) {
		char p[300], b[64], dsk[64];
		unsigned int ma, mi;

		if (e->d_name[0] == '.')
			continue;
		snprintf(p, sizeof(p), "/sys/class/block/%s/partition", e->d_name);
		if (read_line(p, b, sizeof(b)) || strtoul(b, NULL, 10) != part)
			continue;
		/* The parent directory of the partition in sysfs is the disk. */
		snprintf(p, sizeof(p), "/sys/class/block/%s/..", e->d_name);
		{
			char rp[512], *base;

			if (!realpath(p, rp))
				continue;
			base = strrchr(rp, '/');
			snprintf(dsk, sizeof(dsk), "/dev/%s", base ? base + 1 : rp);
		}
		if (disk_sig(dsk) != (long)sig)
			continue;
		snprintf(p, sizeof(p), "/sys/class/block/%s/dev", e->d_name);
		if (read_line(p, b, sizeof(b)) || sscanf(b, "%u:%u", &ma, &mi) != 2)
			continue;
		*dev = makedev(ma, mi);
		snprintf(name, nlen, "%s", e->d_name);
		snprintf(disk, dlen, "%s", dsk);
		closedir(d);
		return 0;
	}
	closedir(d);
	return -1;
}

/* The disk with the MBR signature of a PARTUUID= root, when the partition
 * itself is missing. Return 0 and the disk in DISK, or -1. */
static int find_disk(const char *spec, char *disk, size_t dlen)
{
	unsigned long sig = 0, part = 0;
	DIR *d;
	struct dirent *e;

	if (strncasecmp(spec, "PARTUUID=", 9) ||
	    sscanf(spec + 9, "%8lx-%2lx", &sig, &part) != 2)
		return -1;
	d = opendir("/sys/class/block");
	if (!d)
		return -1;
	while ((e = readdir(d))) {
		char p[300], dsk[64];

		if (e->d_name[0] == '.')
			continue;
		snprintf(p, sizeof(p), "/sys/class/block/%s/partition", e->d_name);
		if (!access(p, F_OK))
			continue;
		snprintf(dsk, sizeof(dsk), "/dev/%s", e->d_name);
		if (disk_sig(dsk) == (long)sig) {
			snprintf(disk, dlen, "%s", dsk);
			closedir(d);
			return 0;
		}
	}
	closedir(d);
	return -1;
}

static void splash(const char *status, const char *cmd)
{
	char *argv[] = { SPLASH, "-s", (char *)status, "-p", "-1", (char *)cmd, NULL };

	if (!test_mode)
		run(argv);
}

static void text_console(void)
{
	char *argv[] = { SPLASH, "console", NULL };

	if (!test_mode)
		run(argv);
}

/* Show the reason on the text console and the kernel log, then let the
 * kernel panic (it restarts after panic= seconds). */
static void fail(const char *fmt, const char *a)
{
	text_console();
	msg(fmt, a);
	sync();
	exit(1);
}

/* ---- the U-Boot env ------------------------------------------------------ */

struct env {
	int valid;		/* the CRC is right */
	int golden;		/* -1: not set */
	int boot_retry;
	int golden_boot_retry;
};

static int env_int(const char *v)
{
	return (*v >= '0' && *v <= '9') ? atoi(v) : -1;
}

/* Read the env (ENV_SIZE bytes at OFF of PATH): a CRC32 of the rest in the
 * first 4 bytes (little endian), then NAME=value strings, each ended by a
 * zero byte, and a second zero byte at the end. */
static int read_env(const char *path, off_t off, struct env *e)
{
	unsigned char *b = malloc(ENV_SIZE);
	int fd, ok;
	uint32_t want;
	const char *p, *end;

	e->valid = 0;
	e->golden = e->boot_retry = e->golden_boot_retry = -1;
	if (!b)
		return -1;
	fd = open(path, O_RDONLY | O_CLOEXEC);
	ok = fd >= 0 && pread(fd, b, ENV_SIZE, off) == ENV_SIZE;
	if (fd >= 0)
		close(fd);
	if (!ok) {
		free(b);
		return -1;
	}
	want = b[0] | b[1] << 8 | b[2] << 16 | (uint32_t)b[3] << 24;
	if (crc32(0L, b + 4, ENV_SIZE - 4) != want) {
		free(b);
		return -1;
	}
	e->valid = 1;
	p = (const char *)b + 4;
	end = (const char *)b + ENV_SIZE;
	while (p < end && *p) {
		size_t n = strnlen(p, end - p);

		if (!strncmp(p, "golden=", 7))
			e->golden = env_int(p + 7);
		else if (!strncmp(p, "boot_retry=", 11))
			e->boot_retry = env_int(p + 11);
		else if (!strncmp(p, "golden_boot_retry=", 18))
			e->golden_boot_retry = env_int(p + 18);
		p += n + 1;
	}
	free(b);
	return 0;
}

/* ---- the RESCUE file on TSXLOG -------------------------------------------- */

/* Look for RESCUE or RESCUE.TXT (any case) in DIR. Copy its first bytes to
 * ARGS, delete it and return 1. Return 0 when there is none. */
static int take_flag(const char *dir, char *args, size_t alen)
{
	DIR *d = opendir(dir);
	struct dirent *e;
	int found = 0;

	args[0] = 0;
	if (!d)
		return 0;
	while ((e = readdir(d))) {
		char p[512];
		struct stat st;
		int fd;
		ssize_t n;

		if (strcasecmp(e->d_name, "rescue") && strcasecmp(e->d_name, "rescue.txt"))
			continue;
		snprintf(p, sizeof(p), "%s/%s", dir, e->d_name);
		if (stat(p, &st) || !S_ISREG(st.st_mode))
			continue;
		fd = open(p, O_RDONLY | O_CLOEXEC);
		if (fd >= 0) {
			n = read(fd, args, alen - 1);
			args[n > 0 ? n : 0] = 0;
			close(fd);
		}
		if (unlink(p))
			msg("cannot delete %s (%s)", p, strerror(errno));
		found = 1;
		break;
	}
	closedir(d);
	if (found)
		sync();
	return found;
}

/* Partition 1 (TSXLOG) of DISK, mounted for the RESCUE file. */
static int tsxlog_flag(const char *disk, char *args, size_t alen)
{
	char p1[80], *tail;
	int r;

	tail = (char *)disk + strlen(disk) - 1;
	snprintf(p1, sizeof(p1), "%s%s1", disk, isdigit((unsigned char)*tail) ? "p" : "");
	mkdir(TSXLOG_DIR, 0755);
	if (mount(p1, TSXLOG_DIR, "vfat", MS_NOSUID | MS_NODEV | MS_NOEXEC | MS_NOATIME, "flush"))
		return 0;
	r = take_flag(TSXLOG_DIR, args, alen);
	umount(TSXLOG_DIR);
	return r;
}

/* ---- the touch screen ----------------------------------------------------- */

#define BIT(a, n) ((a)[(n) / 8] & (1 << ((n) % 8)))

/* Test mode (--touch): the fake touch screen SPEC and the start of the wait. */
static const char *touch_sim;
static double touch_t0;

/* The touch screen: the first event device with BTN_TOUCH and an X axis.
 * Return its fd, or -1. */
static int touch_open(void)
{
	DIR *d;
	struct dirent *e;
	int tfd = -1;

	if (touch_sim)
		return strcmp(touch_sim, "none") ? 0 : -1;
	d = opendir("/dev/input");
	if (!d)
		return -1;
	while ((e = readdir(d)) && tfd < 0) {
		unsigned char keys[KEY_MAX / 8 + 1], abs[ABS_MAX / 8 + 1];
		char p[300];
		int fd;

		if (strncmp(e->d_name, "event", 5))
			continue;
		snprintf(p, sizeof(p), "/dev/input/%s", e->d_name);
		fd = open(p, O_RDONLY | O_NONBLOCK | O_CLOEXEC);
		if (fd < 0)
			continue;
		memset(keys, 0, sizeof(keys));
		memset(abs, 0, sizeof(abs));
		if (ioctl(fd, EVIOCGBIT(EV_KEY, sizeof(keys)), keys) >= 0 &&
		    ioctl(fd, EVIOCGBIT(EV_ABS, sizeof(abs)), abs) >= 0 &&
		    BIT(keys, BTN_TOUCH) && (BIT(abs, ABS_X) || BIT(abs, ABS_MT_POSITION_X)))
			tfd = fd;
		else
			close(fd);
	}
	closedir(d);
	return tfd;
}

/* 1 if the touch screen reports a finger right now. */
static int touch_down(int tfd)
{
	unsigned char keys[KEY_MAX / 8 + 1];

	if (touch_sim) {
		long t = (long)((now() - touch_t0) * 1000), down = -1, up = -1;

		if (sscanf(touch_sim, "%ld-%ld", &down, &up) < 1)
			return 0;
		return t >= down && (up < 0 || t < up);
	}
	memset(keys, 0, sizeof(keys));
	if (ioctl(tfd, EVIOCGKEY(sizeof(keys)), keys) < 0)
		return 0;
	return !!BIT(keys, BTN_TOUCH);
}

/*
 * The touch trigger. Show a hint on the splash and wait TOUCH_WAIT_MS for a
 * finger on the screen. The controller does not report a finger that was on
 * the screen before the driver reset it, so the finger must come during the
 * wait. Then show a count-down and return 1 if the finger stays there for
 * HOLD_S seconds. Return 0 at once when there is no touch screen.
 */
static int touch_held(void)
{
	int tfd = touch_open(), ok = 0;
	double end;

	if (tfd < 0) {
		msg("no touch screen: no touch check");
		return 0;
	}
	splash("touch and hold for the rescue system", "status");
	touch_t0 = now();
	end = touch_t0 + TOUCH_WAIT_MS / 1000.0;
	msg("touch and hold for the rescue system: wait %d ms for a touch", TOUCH_WAIT_MS);
	while (!touch_down(tfd)) {
		if (now() >= end) {
			msg("no touch: normal start");
			splash("starting", "status");
			goto out;
		}
		nap(50);
	}
	msg("finger on the screen: hold %d s for the rescue system", HOLD_S);
	end = now() + HOLD_S;
	for (;;) {
		double left = end - now();
		char s[80];

		if (left <= 0) {
			ok = 1;
			break;
		}
		snprintf(s, sizeof(s), "hold for the rescue system: %d", (int)left + 1);
		splash(s, "status");
		nap(100);
		if (!touch_down(tfd)) {
			msg("finger lifted: normal start");
			splash("starting", "status");
			break;
		}
	}
out:
	if (tfd >= 0 && !touch_sim)
		close(tfd);
	return ok;
}

/* ---- the rescue system ---------------------------------------------------- */

static unsigned long hex8(const unsigned char *p)
{
	char b[9];

	memcpy(b, p, 8);
	b[8] = 0;
	return strtoul(b, NULL, 16);
}

/* Unpack a cpio (newc) archive into DEST. Hard links: the data comes with
 * the last name of an inode (as GNU cpio writes it). */
static int cpio_unpack(const unsigned char *b, size_t n, const char *dest)
{
	struct link { unsigned long ino; int data; char path[256]; } links[64];
	int nlinks = 0;
	size_t off = 0;
	int root = !getuid();

	while (off + 110 <= n) {
		const unsigned char *h = b + off;
		unsigned long ino, mode, uid, gid, nlink, mtime, fsize, rmaj, rmin, nsize;
		const char *name;
		const unsigned char *data;
		char path[512];
		struct timespec ts[2];

		if (memcmp(h, "070701", 6) && memcmp(h, "070702", 6))
			return -1;
		ino = hex8(h + 6);
		mode = hex8(h + 14);
		uid = hex8(h + 22);
		gid = hex8(h + 30);
		nlink = hex8(h + 38);
		mtime = hex8(h + 46);
		fsize = hex8(h + 54);
		rmaj = hex8(h + 78);
		rmin = hex8(h + 86);
		nsize = hex8(h + 94);
		if (!nsize || off + 110 + nsize > n)
			return -1;
		name = (const char *)h + 110;
		if (name[nsize - 1])
			return -1;
		off = (off + 110 + nsize + 3) & ~(size_t)3;
		data = b + off;
		if (off + fsize > n)
			return -1;
		off = (off + fsize + 3) & ~(size_t)3;
		if (!strcmp(name, "TRAILER!!!"))
			return 0;
		while (name[0] == '.' && name[1] == '/')
			name += 2;
		if (!strcmp(name, ".") || !name[0])
			continue;
		if (strstr(name, "..") || name[0] == '/')
			return -1;
		snprintf(path, sizeof(path), "%s/%s", dest, name);
		ts[0].tv_sec = ts[1].tv_sec = mtime;
		ts[0].tv_nsec = ts[1].tv_nsec = 0;

		if (S_ISDIR(mode)) {
			if (mkdir(path, mode & 07777) && errno != EEXIST)
				return -1;
		} else if (S_ISREG(mode)) {
			int fd;

			if (nlink > 1 && !fsize) {
				/* A name of an inode whose data comes with another
				 * name: link it now, or when the data comes. */
				int i;

				for (i = 0; i < nlinks; i++)
					if (links[i].ino == ino && links[i].data)
						break;
				if (i < nlinks) {
					unlink(path);
					if (link(links[i].path, path))
						return -1;
				} else if (nlinks < 64) {
					links[nlinks].ino = ino;
					links[nlinks].data = 0;
					snprintf(links[nlinks].path, sizeof(links[0].path), "%s", path);
					nlinks++;
				}
				continue;
			}
			unlink(path);
			fd = open(path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0600);
			if (fd < 0)
				return -1;
			if (fsize && write(fd, data, fsize) != (ssize_t)fsize) {
				close(fd);
				return -1;
			}
			if (root && fchown(fd, uid, gid))
				msg("chown %s failed", path);
			fchmod(fd, mode & 07777);
			futimens(fd, ts);
			close(fd);
			if (nlink > 1) {
				int i;

				for (i = 0; i < nlinks; i++) {
					if (links[i].ino != ino || links[i].data)
						continue;
					unlink(links[i].path);
					if (link(path, links[i].path))
						return -1;
					links[i].ino = (unsigned long)-1;
				}
				if (nlinks < 64) {
					links[nlinks].ino = ino;
					links[nlinks].data = 1;
					snprintf(links[nlinks].path, sizeof(links[0].path), "%s", path);
					nlinks++;
				}
			}
			continue;
		} else if (S_ISLNK(mode)) {
			char t[512];

			if (fsize >= sizeof(t))
				return -1;
			memcpy(t, data, fsize);
			t[fsize] = 0;
			unlink(path);
			if (symlink(t, path))
				return -1;
			if (root)
				lchown(path, uid, gid);
			utimensat(AT_FDCWD, path, ts, AT_SYMLINK_NOFOLLOW);
			continue;
		} else if (S_ISCHR(mode) || S_ISBLK(mode) || S_ISFIFO(mode) || S_ISSOCK(mode)) {
			if (!root)
				continue;
			unlink(path);
			if (mknod(path, mode, makedev(rmaj, rmin)))
				return -1;
		} else {
			continue;
		}
		if (root && lchown(path, uid, gid))
			msg("chown %s failed", path);
		chmod(path, mode & 07777);
		utimensat(AT_FDCWD, path, ts, 0);
	}
	return -1;
}

/*
 * Check the rescue slot at OFF of PATH and unpack it into DEST. The version
 * line goes to VER. Return 0, or -1 with the reason in WHY.
 */
static int rescue_unpack(const char *path, off_t off, const char *dest,
			 char *ver, size_t vlen, char *why, size_t wlen)
{
	char hdr[RESCUE_HDR + 1], *p;
	unsigned char *gz = NULL, *cpio = NULL;
	unsigned long size = 0;
	uint32_t isize;
	z_stream z;
	int fd, r = -1, zr;

	ver[0] = 0;
	fd = open(path, O_RDONLY | O_CLOEXEC);
	if (fd < 0) {
		snprintf(why, wlen, "cannot open %s", path);
		return -1;
	}
	if (pread(fd, hdr, RESCUE_HDR, off) != RESCUE_HDR) {
		snprintf(why, wlen, "cannot read the rescue slot");
		goto out;
	}
	hdr[RESCUE_HDR] = 0;
	if (strncmp(hdr, "TSX-RESCUE 1\n", 13)) {
		snprintf(why, wlen, "the rescue slot holds no rescue system");
		goto out;
	}
	p = strstr(hdr, "\nsize ");
	if (p)
		size = strtoul(p + 6, NULL, 10);
	p = strstr(hdr, "\nversion ");
	if (p)
		snprintf(ver, vlen, "%.*s", (int)strcspn(p + 9, "\n"), p + 9);
	if (size < 18 || size > RESCUE_AREA - RESCUE_HDR) {
		snprintf(why, wlen, "bad size %lu in the rescue slot", size);
		goto out;
	}
	gz = malloc(size);
	if (!gz || pread(fd, gz, size, off + RESCUE_HDR) != (ssize_t)size) {
		snprintf(why, wlen, "cannot read the rescue archive");
		goto out;
	}
	/* The gzip trailer: CRC32, then the unpacked size. */
	isize = gz[size - 4] | gz[size - 3] << 8 | gz[size - 2] << 16 | (uint32_t)gz[size - 1] << 24;
	if (!isize || isize > RESCUE_MAX_UNPACKED) {
		snprintf(why, wlen, "bad unpacked size %u", isize);
		goto out;
	}
	cpio = malloc(isize);
	if (!cpio) {
		snprintf(why, wlen, "no memory for %u bytes", isize);
		goto out;
	}
	memset(&z, 0, sizeof(z));
	if (inflateInit2(&z, 16 + MAX_WBITS) != Z_OK) {
		snprintf(why, wlen, "zlib init failed");
		goto out;
	}
	z.next_in = gz;
	z.avail_in = size;
	z.next_out = cpio;
	z.avail_out = isize;
	/* zlib checks the CRC32 of the gzip trailer at the end of the stream. */
	zr = inflate(&z, Z_FINISH);
	inflateEnd(&z);
	if (zr != Z_STREAM_END || z.total_out != isize) {
		snprintf(why, wlen, "the rescue archive is damaged (zlib %d)", zr);
		goto out;
	}
	if (cpio_unpack(cpio, isize, dest)) {
		snprintf(why, wlen, "the rescue archive is not a valid cpio");
		goto out;
	}
	r = 0;
out:
	free(gz);
	free(cpio);
	close(fd);
	return r;
}

static void write_file(const char *path, const char *text)
{
	int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);

	if (fd < 0)
		return;
	if (write(fd, text, strlen(text)) < 0)
		msg("cannot write %s", path);
	close(fd);
}

/* Delete the files of the ramdisk (they stay in RAM otherwise). Only on the
 * ramdisk file system, never below the mount points. */
static void wipe(const char *dir, dev_t rootdev)
{
	DIR *d = opendir(dir);
	struct dirent *e;

	if (!d)
		return;
	while ((e = readdir(d))) {
		char p[512];
		struct stat st;

		if (!strcmp(e->d_name, ".") || !strcmp(e->d_name, ".."))
			continue;
		snprintf(p, sizeof(p), "%s/%s", strcmp(dir, "/") ? dir : "", e->d_name);
		if (lstat(p, &st) || st.st_dev != rootdev)
			continue;
		if (S_ISDIR(st.st_mode)) {
			wipe(p, rootdev);
			rmdir(p);
		} else {
			unlink(p);
		}
	}
	closedir(d);
}

/* Move /dev, /proc and /sys to NEWROOT and start INIT there (the steps of
 * busybox switch_root). */
static void switch_to(const char *what, const char *init)
{
	struct stat st;

	msg("switch to %s, %.2f s", what, now());
	mount("/dev", NEWROOT "/dev", NULL, MS_MOVE, NULL);
	mount("/proc", NEWROOT "/proc", NULL, MS_MOVE, NULL);
	mount("/sys", NEWROOT "/sys", NULL, MS_MOVE, NULL);
	if (chdir(NEWROOT))
		fail("chdir failed%s", "");
	if (!stat("/", &st))
		wipe("/", st.st_dev);
	if (mount(".", "/", NULL, MS_MOVE, NULL) || chroot("."))
		fail("switch to the root file system failed (%s)", strerror(errno));
	if (chdir("/"))
		fail("chdir / failed%s", "");
	execl(init, init, (char *)NULL);
	fail("start of the init program failed (%s)", strerror(errno));
}

/*
 * Start the rescue system of the rescue slot of DISK. Return only when there
 * is none (the reason is in the kernel log): the caller goes on.
 */
static void rescue(const char *disk, const char *reason, const char *args)
{
	char ver[128], why[160], b[600];
	double t0 = now();

	msg("RESCUE: %s", reason);
	if (!disk || !disk[0]) {
		msg("no rescue system: the boot card is not known");
		return;
	}
	mkdir(NEWROOT, 0755);
	if (mount("tmpfs", NEWROOT, "tmpfs", MS_NOSUID, "mode=0755")) {
		msg("no rescue system: tmpfs mount failed (%s)", strerror(errno));
		return;
	}
	if (rescue_unpack(disk, RESCUE_OFFSET, NEWROOT, ver, sizeof(ver), why, sizeof(why))) {
		msg("no rescue system: %s", why);
		umount(NEWROOT);
		return;
	}
	msg("rescue system %s unpacked in %.2f s", ver[0] ? ver : "(no version)", now() - t0);
	text_console();
	mkdir(NEWROOT "/dev", 0755);
	mkdir(NEWROOT "/proc", 0555);
	mkdir(NEWROOT "/sys", 0555);
	mkdir(NEWROOT "/run", 0755);
	snprintf(b, sizeof(b), "%s\n", reason);
	write_file(NEWROOT "/run/rescue-reason", b);
	if (args && args[0])
		write_file(NEWROOT "/run/tsx-rescue-args", args);
	switch_to("the rescue system", "/sbin/init");
}

static int test_main(int argc, char **argv)
{
	if (argc >= 3 && !strcmp(argv[1], "--env")) {
		struct env e;

		if (read_env(argv[2], argc > 3 ? strtol(argv[3], NULL, 0) : 0, &e)) {
			printf("env: unreadable or bad CRC\n");
			return 1;
		}
		printf("golden=%d boot_retry=%d golden_boot_retry=%d\n",
		       e.golden, e.boot_retry, e.golden_boot_retry);
		return 0;
	}
	if (argc >= 4 && !strcmp(argv[1], "--rescue")) {
		char ver[128], why[160];
		const char *dir = argv[argc - 1];
		off_t off = argc > 4 ? strtol(argv[3], NULL, 0) : 0;

		if (rescue_unpack(argv[2], off, dir, ver, sizeof(ver), why, sizeof(why))) {
			printf("rescue: %s\n", why);
			return 1;
		}
		printf("rescue: %s unpacked to %s\n", ver, dir);
		return 0;
	}
	if (argc == 3 && !strcmp(argv[1], "--flag")) {
		char args[1024];

		if (!take_flag(argv[2], args, sizeof(args))) {
			printf("flag: none\n");
			return 1;
		}
		printf("flag: found\n%s", args);
		return 0;
	}
	if (argc == 3 && !strcmp(argv[1], "--touch")) {
		double t0 = now();
		int r;

		touch_sim = argv[2];
		r = touch_held();
		printf("touch: %s after %.2f s\n", r ? "rescue" : "normal start", now() - t0);
		return r ? 0 : 1;
	}
	return -1;
}

int main(int argc, char **argv)
{
	char root[256], fstype[32] = "ext4", flags[256] = "", init[256] = "/sbin/init";
	char name[64], disk[64] = "", b[300], args[1024] = "";
	unsigned long mflags = 0;
	int wait_s = 60, verbose, fd, r;
	dev_t dev;
	double t0, end;
	struct stat st;
	struct env env;

	test_mode = getpid() != 1;
	if (test_mode && argc > 1) {
		r = test_main(argc, argv);
		return r < 0 ? 2 : r;
	}
	if (!test_mode) {
		mkdir("/dev", 0755);
		mkdir("/proc", 0555);
		mkdir("/sys", 0555);
		mount("devtmpfs", "/dev", "devtmpfs", MS_NOSUID, "mode=0755");
		mount("proc", "/proc", "proc", MS_NOSUID | MS_NODEV | MS_NOEXEC, NULL);
		mount("sysfs", "/sys", "sysfs", MS_NOSUID | MS_NODEV | MS_NOEXEC, NULL);
	}
	fd = open("/proc/cmdline", O_RDONLY | O_CLOEXEC);
	if (fd >= 0) {
		ssize_t n = read(fd, cmdline, sizeof(cmdline) - 1);

		cmdline[n > 0 ? n : 0] = 0;
		close(fd);
	}
	t0 = now();

	verbose = flag("tsx.verbose") || flag("tsx.verbose=1");
	if (verbose) {
		text_console();
	} else {
		/* imx-drm registers fb0 before the kernel starts /init. Wait a
		 * short time in case the display driver probes late. */
		for (r = 0; r < 40 && stat("/dev/fb0", &st); r++)
			nap(50);
		splash("starting", "show");
		if (!test_mode)
			msg("splash at %.2f s", now());
	}

	if (!arg("root", root, sizeof(root)))
		fail("no root= on the kernel command line%s", "");
	arg("rootfstype", fstype, sizeof(fstype));
	arg("rootflags", flags, sizeof(flags));
	arg("init", init, sizeof(init));
	if (arg("rootwait", b, sizeof(b)))
		wait_s = atoi(b) > 0 ? atoi(b) : 60;
	if (flag("ro"))
		mflags |= MS_RDONLY;
	if (flag("rw"))
		mflags &= ~MS_RDONLY;

	end = now() + wait_s;
	while ((r = find_root(root, &dev, name, sizeof(name), disk, sizeof(disk))) == -1 && now() < end)
		nap(50);
	if (r == -2)
		fail("root=%s: use PARTUUID=<disk id>-<partition> or /dev/<name>", root);
	if (r) {
		if (!test_mode && !find_disk(root, disk, sizeof(disk))) {
			snprintf(b, sizeof(b), "the root partition %s did not show up in %d s", root, wait_s);
			rescue(disk, b, NULL);
		}
		fail("root=%s did not show up (rootwait)", root);
	}
	msg("root %s is %s after %.2f s", root, name, now() - t0);
	if (test_mode) {
		printf("would mount /dev/%s (%s, %s) and start %s, boot card %s\n", name, fstype,
		       mflags & MS_RDONLY ? "ro" : "rw", init, disk);
		return 0;
	}

	/* The rescue triggers before the root mount. */
	if (!read_env(disk, ENV_OFFSET, &env) && env.golden > 0) {
		snprintf(b, sizeof(b), "U-Boot started the golden slots (boot_retry=%d, golden_boot_retry=%d): "
			 "two normal boots failed, or tsx-boot-rescue --golden asked for it",
			 env.boot_retry, env.golden_boot_retry);
		rescue(disk, b, NULL);
	}
	if (flag("tsx.rescue") || flag("tsx.rescue=1"))
		rescue(disk, "requested on the kernel command line", NULL);
	if (tsxlog_flag(disk, args, sizeof(args)))
		rescue(disk, "the file RESCUE was on the TSXLOG partition (it is deleted, the next boot is normal)", args);
	if (!verbose && !test_mode && touch_held())
		rescue(disk, "a finger was held on the screen at boot", NULL);

	/* Mount the device node of the partition, as the kernel does. */
	snprintf(b, sizeof(b), "/dev/root");
	unlink(b);
	if (mknod(b, S_IFBLK | 0600, dev))
		fail("mknod /dev/root failed%s", "");
	mkdir(NEWROOT, 0755);
	if (mount(b, NEWROOT, fstype, mflags, flags)) {
		char why[300];

		snprintf(why, sizeof(why), "the root file system on %s does not mount (%s)", name, strerror(errno));
		rescue(disk, why, NULL);
		fail("%s", why);
	}
	if (!access(NEWROOT "/etc/tsx/force-rescue", F_OK)) {
		unlink(NEWROOT "/etc/tsx/force-rescue");
		sync();
		umount(NEWROOT);
		rescue(disk, "/etc/tsx/force-rescue was on the root file system (tsx-boot-rescue; it is deleted, the next boot is normal)", NULL);
		/* No rescue system: mount the root again and go on. */
		if (mount("/dev/root", NEWROOT, fstype, mflags, flags))
			fail("mount of the root file system failed (%s)", strerror(errno));
	}
	{
		char p[300];

		/* /sbin/init is often an absolute link (to /bin/busybox). It
		 * resolves only after the switch, so check that it exists. */
		snprintf(p, sizeof(p), NEWROOT "%s", init);
		if (lstat(p, &st) || (!S_ISLNK(st.st_mode) && access(p, X_OK))) {
			char why[300];

			snprintf(why, sizeof(why), "no %s on the root file system (%s)", init, name);
			umount(NEWROOT);
			rescue(disk, why, NULL);
			fail("%s", why);
		}
	}
	if (!verbose && !access(NEWROOT "/etc/tsx/boot-verbose", F_OK))
		text_console();
	switch_to(name, init);
	return 1;
}
