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
 *   4. mounts it as the kernel does (rootfstype=, rootflags=, ro or rw),
 *   5. moves /dev, /proc and /sys to it, deletes the ramdisk files and
 *      starts init= (default /sbin/init) of the root file system.
 * The splash stays on the screen until a program takes the display (the
 * panel app). The kernel command line keeps the text console off the LCD
 * (fbcon=map:1).
 *
 * Text console instead of the splash: tsx.verbose on the command line, or
 * /etc/tsx/boot-verbose on the root file system (panel.conf BOOT_VERBOSE).
 * If the root partition does not show up in rootwait= seconds (default 60),
 * or it does not mount, or init= is missing, the program gives the screen
 * to the text console, writes the reason to the kernel log and exits. The
 * kernel then panics and restarts after panic= seconds, as it does without
 * a ramdisk.
 *
 * Not PID 1 (a test on a running system): the program only finds the root
 * partition and prints what it would do.
 */
#define _GNU_SOURCE
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <sys/sysmacros.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#define SPLASH "/usr/local/bin/tsx-splash"
#define NEWROOT "/newroot"

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

/*
 * Find the block device of root=. PARTUUID=SSSSSSSS-PP is the MBR disk
 * signature (the 32-bit value at byte 440 of the disk) and the partition
 * number, in hex, as the kernel prints it. Write the device number to *dev.
 */
static int find_root(const char *spec, dev_t *dev, char *name, size_t nlen)
{
	unsigned long sig = 0, part = 0;
	DIR *d;
	struct dirent *e;

	if (!strncmp(spec, "/dev/", 5)) {
		struct stat st;

		/* devtmpfs makes the node when the device appears. */
		if (stat(spec, &st) || !S_ISBLK(st.st_mode))
			return -1;
		snprintf(name, nlen, "%s", spec + 5);
		*dev = st.st_rdev;
		return 0;
	}
	if (strncasecmp(spec, "PARTUUID=", 9) ||
	    sscanf(spec + 9, "%8lx-%2lx", &sig, &part) != 2)
		return -2;

	d = opendir("/sys/class/block");
	if (!d)
		return -1;
	while ((e = readdir(d))) {
		char p[300], b[64], disk[64];
		unsigned char s[4];
		unsigned int ma, mi;
		int fd, ok;

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
			snprintf(disk, sizeof(disk), "/dev/%s", base ? base + 1 : rp);
		}
		fd = open(disk, O_RDONLY | O_CLOEXEC);
		if (fd < 0)
			continue;
		ok = pread(fd, s, 4, 440) == 4;
		close(fd);
		if (!ok || (s[0] | s[1] << 8 | s[2] << 16 | (unsigned long)s[3] << 24) != sig)
			continue;
		snprintf(p, sizeof(p), "/sys/class/block/%s/dev", e->d_name);
		if (read_line(p, b, sizeof(b)) || sscanf(b, "%u:%u", &ma, &mi) != 2)
			continue;
		*dev = makedev(ma, mi);
		snprintf(name, nlen, "%s", e->d_name);
		closedir(d);
		return 0;
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

int main(void)
{
	char root[256], fstype[32] = "ext4", flags[256] = "", init[256] = "/sbin/init";
	char name[64], b[16];
	unsigned long mflags = 0;
	int wait_s = 60, verbose, fd, r;
	dev_t dev;
	double t0, end;
	struct stat st;

	test_mode = getpid() != 1;
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
	while ((r = find_root(root, &dev, name, sizeof(name))) == -1 && now() < end)
		nap(50);
	if (r == -2)
		fail("root=%s: use PARTUUID=<disk id>-<partition> or /dev/<name>", root);
	if (r)
		fail("root=%s did not show up (rootwait)", root);
	msg("root %s is %s after %.2f s", root, name, now() - t0);
	if (test_mode) {
		printf("would mount /dev/%s (%s, %s) and start %s\n", name, fstype,
		       mflags & MS_RDONLY ? "ro" : "rw", init);
		return 0;
	}

	/* Mount the device node of the partition, as the kernel does. */
	snprintf(b, sizeof(b), "/dev/root");
	unlink(b);
	if (mknod(b, S_IFBLK | 0600, dev))
		fail("mknod /dev/root failed%s", "");
	mkdir(NEWROOT, 0755);
	if (mount(b, NEWROOT, fstype, mflags, flags))
		fail("mount of the root file system failed (%s)", strerror(errno));
	{
		char p[300];

		/* /sbin/init is often an absolute link (to /bin/busybox). It
		 * resolves only after the switch, so check that it exists. */
		snprintf(p, sizeof(p), NEWROOT "%s", init);
		if (lstat(p, &st) || (!S_ISLNK(st.st_mode) && access(p, X_OK)))
			fail("no %s on the root file system", init);
	}
	if (!verbose && !access(NEWROOT "/etc/tsx/boot-verbose", F_OK))
		text_console();
	msg("switch to %s, %.2f s", name, now());

	/* Same steps as busybox switch_root. */
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
	return 1;
}
