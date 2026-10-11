# Recovery

This page describes the rescue system of the TSS-752 and the ways back to the stock firmware. Use it when the panel does not start the panel app, when a new kernel or root file system does not boot, or when you want the stock firmware back.

For the boot path and the retry counters of U-Boot, see [README.md](../README.md), "Boot path". For the install, see [install.md](install.md).

## The rescue system

The rescue system is a small Linux system in RAM. It has the same rescue screen, the same login rules and the same repair tools as the rescue system of the other TSX panel families. It starts the network and an ssh server, and it shows the address and the login on the screen.

The card holds the rescue system in the rescue slot, a raw area of 5 MiB at 0x300000 (below the first partition). The ramdisk of the boot slots unpacks it into RAM and starts it. The rescue system never writes the card by itself. Only the tools that you start write the card.

The rescue system uses the kernel of the slots that U-Boot booted. It needs no kernel module and no file of the root file system. So it also starts when the root file system is damaged or missing.

## Start the rescue system

| Trigger | How | The next boot |
|---|---|---|
| Two failed boots | Automatic. U-Boot boots the golden slots after two failed boots of the normal slots. The ramdisk sees `golden=1` in the U-Boot env and starts the rescue system. | The rescue system again, for up to five boots. Then U-Boot tries the normal slots two times. Use `tsx-boot-mainline` |
| `tsx-boot-rescue` | Run it on the running panel. It writes `/etc/tsx/force-rescue` on the root file system and reboots. The ramdisk deletes the file. | Normal |
| `tsx-boot-rescue --golden` | Run it on the running panel. It sets `boot_retry=10` in the U-Boot env and reboots. U-Boot then boots the golden slots, as after two failed boots. Use it to test the fallback path. | The rescue system again, as after two failed boots. Use `tsx-boot-mainline` |
| A `RESCUE` file on TSXLOG | Put a file with the name `RESCUE` or `RESCUE.TXT` (any case) on the FAT partition of the card with a PC. The ramdisk deletes the file. Use it when the panel has no network or no ssh login. | Normal |
| A finger on the screen | Touch the screen when the Crestron logo shows. Hold the finger until the rescue screen shows. | Normal |
| No usable root file system | Automatic. The root partition is missing, does not mount or has no `/sbin/init`. | The same check again |

The panel has no reset pinhole. The button on the back is a hard reset. So the `RESCUE` file and the finger on the screen are the triggers that need no network. The running panel can also write the file: `touch /mnt/tsxlog/RESCUE.TXT`, then `reboot`.

### Start the rescue system with the RESCUE file

1. Power off the panel.
2. Remove the SD card from the panel.
3. Put the card in a card reader on a PC.
4. Open the drive `TSXLOG`.
5. Make an empty text file with the name `RESCUE.TXT` there.
6. Optional: for a static address, write one line `tsx.ip=ADDRESS/PREFIX,GATEWAY` in the file. Example: `tsx.ip=192.168.1.50/24,192.168.1.1`.
7. Eject the card on the PC.
8. Put the card back in the panel.
9. Power on the panel.
10. Wait for the rescue screen. It shows about 2 s after the kernel starts.

### Start the rescue system with a finger on the screen

1. Power on the panel, or press the button on the back.
2. Touch the middle of the screen when the Crestron logo shows.
3. Hold the finger on the screen. The splash shows `hold for the rescue system: 3`, then 2 and 1.
4. Lift the finger when the rescue screen shows.

If you lift the finger before the count ends, the panel starts normally. The touch keys right of the screen do not count.

## The rescue screen

The screen shows the TSX banner and these lines:

| Line | Content |
|---|---|
| `model` | The model and the stock firmware version from the U-Boot env, and the unit id (the MAC address) |
| `rescue` | The version of the rescue system |
| `kernel` | The kernel release |
| `network` | The address of `eth0`, DHCP or static, and the MAC address from the U-Boot env |
| `repair shell` | The ssh command |
| `login` | Which login the rescue system accepts (see "Log in") |

While a tool writes the card, the screen also shows the step, a progress bar and "DO NOT power off the system." The reason for the rescue is in `/run/rescue-reason`. The shell prints it at each login.

The TSS-752 has no USB port, so "Press Enter for a rescue shell" works only on the serial console (UART1 test points, 115200 baud). Use ssh.

## Log in

The rescue system has no fixed password. `tsx-rescue-login` decides the login at each start:

1. It reads `panel.conf` from the data partition (`tsxdata`). On a card with no data partition, it reads `/data/tsx/panel.conf` from the root file system. It uses `ROOT_PASSWORD_HASH` as the root password and `SSH_AUTHORIZED_KEY` as the root key. These are the login settings of the setup page.
2. It also takes the keys in `/root/.ssh/authorized_keys` of the normal system (on the data partition or the root file system). So the key that logs in to the panel also logs in to the rescue system. In both cases the screen says `the root password or SSH key of this panel`.
3. If it finds no password hash and no key, it makes a one-time password. Only the screen shows it. The password changes at each start of the rescue system.

Log in as root with ssh: `ssh root@ADDRESS`.

## Tools

| Command | Function |
|---|---|
| `tsx-boot-mainline` | Sets the U-Boot counters to `boot_retry=8` and `golden_boot_retry=0`, then reboots into the normal slots. It checks first that the normal slots hold a kernel and a ramdisk that can start the rescue system |
| `tsx-boot-mainline --last-good` | Copies the golden slots (the last kernel that booted well) to the normal slots first. Use it when a new kernel does not boot |
| `tsx-boot-ok --status` | Shows the U-Boot counters |
| `tsx-kernel-slots show` | Shows the kernel slots, the ramdisk slots and the version of the rescue system |
| `tsx-install-rootfs SOURCE` | Writes a new root file system into p2. SOURCE is a file, an `http://` or `https://` URL, or `-` (stdin). The tool takes `rootfs.ext4`, `.gz`, `.zst` and the card parts of a release (`tsx-xx50-card-parts.tar.zst`) |
| `tsx-install-rootfs --packages` | Installs the packages of p2 again (`apk fix --reinstall` in a chroot, with the network of the rescue system) |
| `tsx-install-rootfs --shell` | Opens a shell in a chroot of p2 |
| `tsx-data-backup FILE` or `-` | Writes a backup of the panel data (gzip tar) |
| `tsx-data-restore FILE` or `-` | Puts a backup back. `--clean` deletes the panel data first |
| `tsx-restore-stock SOURCE` | Writes a dump of the stock card onto this card (see "Go back to the stock firmware") |
| `e2fsck -f /dev/mmcblk0p2` | Checks the root file system |
| `reboot -f` | Starts the panel again |

Every tool shows its options with `--help`.

## Leave the rescue system

1. Repair the cause, if there is one (see "Repair").
2. Run `tsx-boot-mainline`.
3. Wait for the panel app.

After a rescue from the `RESCUE` file, the finger or `tsx-boot-rescue`, `reboot -f` also starts the normal system. `tsx-boot-mainline` also resets the counters, so use it in all cases.

## Repair

### A new kernel does not boot

U-Boot boots the golden slots after two failed boots, and the rescue system starts. The golden slots hold the last kernel that booted well (`tsx-kernel-slots promote`).

1. Log in to the rescue system.
2. Run `tsx-boot-mainline --last-good`.

The panel then boots the last good kernel from the normal slots. Its modules on the root file system can be the modules of the new kernel. Install a good kernel package as soon as possible.

### The root file system is damaged

1. Log in to the rescue system.
2. Run `e2fsck -f /dev/mmcblk0p2`.
3. Optional: run `tsx-install-rootfs --packages` to install the packages again.
4. Run `tsx-boot-mainline`.

### Install a new root file system

The tool keeps p3 (`tsxdata`). On a card with no p3, the panel data is on p2, and the tool refuses to write. Then back up the data first.

1. On a card with no p3, run `ssh root@ADDRESS tsx-data-backup - > panel-data.tar.gz` on a PC.
2. Run `ssh root@ADDRESS tsx-install-rootfs --yes - parts < tsx-xx50-card-parts.tar.zst` on the PC. On a card with no p3, add `--wipe-data`.
3. On a card with no p3, run `ssh root@ADDRESS tsx-data-restore - < panel-data.tar.gz` on the PC.
4. Run `ssh root@ADDRESS tsx-boot-mainline` on the PC.

The rescue system can also download the card parts itself: `tsx-install-rootfs --yes https://.../tsx-xx50-card-parts.tar.zst`.

## Go back to the stock firmware

The install does not change the stock card. To go back:

1. Power off the panel.
2. Remove the TSX card.
3. Put the stock card in the panel.
4. Power on the panel.

The rescue system cannot write U-Boot safely, and it never does. If the stock card is lost or damaged, `tsx-restore-stock` writes a dump of the stock card onto this card. You need a dump of the full stock card, made before the install ([install.md](install.md), "Make a dump of the stock card", step 6). The dump of the first MiB is not enough.

**Warning:** The restore deletes TSX - LINUX, the panel data, the rescue system and TSXLOG on this card. Do not power off the panel during the restore.

1. Start the rescue system.
2. On the PC, run `ssh root@ADDRESS tsx-restore-stock --yes - gz < stock-card-full.img.gz`. For a dump with no gzip, leave out `gz`.
3. Wait for the line `done`.
4. Power the panel off and on.

The tool writes the dump from byte 0 to its end, except the U-Boot and its env (0x400 to 0xE0000). That range stays as it is on the card. Before the write, the tool checks that the U-Boot of the dump is the same as the U-Boot on the card. After the write, it compares the sha256 of the written bytes with the dump, and it sets `boot_retry=0` and `golden_boot_retry=0`.

If the restore stops, the card can be without a working system. Write the dump onto the card with a card reader on a PC.

## Reference

### The decision of the ramdisk

The ramdisk program (`image/initramfs/tsx-xx50-init.c`) checks the triggers in this order:

1. The root partition does not show up in 60 s: rescue.
2. `golden=1` in the U-Boot env (with a valid CRC): rescue.
3. `tsx.rescue` on the kernel command line: rescue. The kernel uses its own command line, so only a test kernel can set it.
4. A `RESCUE` or `RESCUE.TXT` file on p1: rescue. The file is deleted.
5. A finger on the screen at the splash, held for 3 s: rescue.
6. The root file system does not mount: rescue.
7. `/etc/tsx/force-rescue` on the root file system: rescue. The file is deleted.
8. No `/sbin/init` on the root file system: rescue.

If the rescue slot holds no valid rescue system, the program writes the reason to the kernel log. Then it starts the root file system as usual. If the root file system is not usable either, the kernel restarts after 10 s.

### The rescue slot

| Offset in the slot | Content |
|---|---|
| 0 | A text header of 512 bytes: `TSX-RESCUE 1`, `size BYTES`, `version TEXT` |
| 512 | A gzip-compressed cpio (newc) of the rescue root file system |

The ramdisk checks the header and the gzip checksum. Then it unpacks the archive into a tmpfs and starts `/sbin/init` (busybox init). `image/mkrescue.sh` builds the image. The kernel package `tsx-xx50-kernel-lts` writes it with `tsx-kernel-slots rescue`. `image/mkcard.sh` and `image/update-card.sh` write it on a PC. The ramdisk name `tsx-xx50 initrd (rescue 1)` marks a ramdisk that can start it.

The rescue system holds busybox, dropbear, e2fsprogs (with `resize2fs`), dosfstools, `ssl_client` for https, zstd, `fw_printenv` and `fw_setenv`, the rescue tools of tsx-linux-common and the board files (`board.sh`, `tsx-boot-ok`, `tsx-kernel-slots`). It uses about 85 % of the slot.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| The panel starts normally after a `RESCUE` file | The file name is not `RESCUE` or `RESCUE.TXT`, or the PC did not write the file before the card came out | Check the name. Eject the card on the PC before you remove it |
| `tsx-boot-rescue` says the ramdisk cannot start the rescue system | The kernel package is older than 0.3.3 | Install the current `tsx-xx50-kernel-lts` and reboot |
| `tsx-boot-rescue --golden` refuses the golden slots | The golden slots hold an older ramdisk | Run `tsx-kernel-slots promote` after a good boot of the current kernel |
| After two failed boots the panel starts the root file system with the golden kernel | The golden slots hold a ramdisk that is older than 0.3.3 | Run `tsx-kernel-slots promote` after a good boot |
| The rescue screen shows `login: root, one-time password` | `panel.conf` has no password hash and no SSH key, and root of the normal system has no `authorized_keys` | Read the password on the screen, or set the login on the setup page |
| `tsx-kernel-slots show` says `(no rescue system)` | The card is older than 0.3.3, and no kernel package 0.3.3 or later ran its hook | Install the kernel package again, or run `image/update-card.sh` with a new image |
