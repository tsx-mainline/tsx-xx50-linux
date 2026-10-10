# tsx-xx50-linux

Mainline Linux for the Crestron xx50 touch panels (NXP i.MX53, one
Cortex-A8 core). The supported panel is the TSS-752. The panel starts from
an SD card: the stock U-Boot of the card starts a mainline 6.18 kernel and
an Alpine armv7 root file system. The root file system has the shared TSX
userland (tsx-linux-common), the xx50 board layer and the panel app. The
panel app shows Home Assistant cards on the screen with no browser.

The card image does not change the panel. To go back to the Crestron
firmware, put the stock SD card back in the panel.

## What works

| Part | Status |
|---|---|
| Boot | The stock U-Boot starts the kernel and the ramdisk from the raw slots of the card. |
| Boot splash | The TSX splash shows 1.6 s after the kernel start and stays until the panel app shows its first frame. |
| Ethernet | 100 Mbit, the MAC address of the panel, DHCP, ssh, NTP. |
| Display | 800x480, DRM/KMS (`imx-drm`), PWM backlight. |
| Touch | FT5x06, five fingers. |
| Touch keys | Five keys right of the screen: `KEY_F13` to `KEY_F17`. |
| Light bars | Two RGB light bars (TLC59116), as multicolor LED devices. Blue is not checked by eye. |
| CPU frequency | 167 MHz to 1 GHz, `cpufreq-dt` with the vendor operating points. |
| GPU | Z430 (Adreno 200) with `drm/msm` and Mesa freedreno, OpenGL ES 2.0. |
| Audio playback | TLV320AIC3204 codec and the speaker amplifier. The clocks and rates are correct. Nobody has checked the speaker sound. |
| Audio capture | The digital microphone, tested at 16 kHz. No voice service uses it. |
| Panel app | Home Assistant cards, the settings overlay, screen dim and off, the light bars and the keys as Home Assistant entities. |
| Setup page | Pairing code on the screen, the panel settings, the layout editor. |
| Updates | `apk upgrade` from the TSX package repository. `image/update-card.sh` for a new image on a card that keeps its data. |

The hardware details are in [docs/hardware.md](docs/hardware.md). The
models and their status are in [docs/compatibility.md](docs/compatibility.md).

## Documentation

- [docs/install.md](docs/install.md): make the card, write it and start the panel.
- [docs/userland.md](docs/userland.md): the services, the setup page, the
  panel app in Home Assistant, the data partition and the updates.
- [docs/hardware.md](docs/hardware.md): the parts of the TSS-752 and how
  Linux uses them.
- [docs/build.md](docs/build.md): build from source, the tests, CI and the
  release assets.
- [docs/compatibility.md](docs/compatibility.md): the xx50 models.

## The card image

A card image has two parts:

- The stock U-Boot and its env. They come from the stock SD card of your
  panel. This repository and its releases do not hold them.
- The kernel, the ramdisk (the boot splash) and the root file system. The release
  assets hold them (`tsx-xx50-card-parts.tar.zst`), or you build them.

`image/mkcard.sh` puts the two parts together on your machine. See
[docs/install.md](docs/install.md).

## Boot path

The image keeps the stock Crestron U-Boot 2009.08 and its env, byte for byte.
That U-Boot reads fixed raw areas of the card and runs `bootm`:

| Path | Kernel (sector, count) | Ramdisk (sector, count) |
|---|---|---|
| normal | 0x4000, 0x2000 (4 MiB) | 0x0800, 0x300 (384 KiB) |
| golden | 0x6000, 0x2000 (4 MiB) | 0x1000, 0x300 (384 KiB) |

U-Boot selects the path at each start and saves its env. It adds 1 to
`boot_retry` and reads `golden_boot_retry`:

| `boot_retry` after the step | `golden_boot_retry` | Path | Saved values |
|---|---|---|---|
| 1 to 10 | any | normal | `boot_retry`, `golden_boot_retry=0` |
| 11 or more | 0 to 4 (adds 1) | golden | `boot_retry=11`, `golden_boot_retry` + 1 |
| 11 or more | 5 (adds 1) | normal | `boot_retry=9`, `golden_boot_retry=0` |

U-Boot sets `boot_retry` to 0 if it is larger than 12. Without a reset of
the counters, the panel boots the normal path 10 times. Then it boots the
golden path 5 times and the normal path 2 times, again and again.

The board service `tsx-boot-ok` sets `boot_retry=8` and `golden_boot_retry=0`
after a good boot from the normal path. So the next start boots the normal
path. If the normal path fails two times, U-Boot boots the golden path. The
image puts the same files in the normal and the golden slots.

The U-Boot has no FDT support and no `bootz`. The kernel is a zImage with the
board DTB appended (`CONFIG_ARM_APPENDED_DTB`), packed as a legacy uImage with
load and entry address 0x71000000. The decompressor merges the ATAG memory
banks into the DTB (`CONFIG_ARM_ATAG_DTB_COMPAT`). The U-Boot command line is
an Android one, so the kernel uses its own fixed command line
(`CONFIG_CMDLINE_FORCE`) with `root=PARTUUID=7458a050-02` and `fbcon=map:1`.

Memory at boot:

| Address | Content |
|---|---|
| 0x70008000 | the kernel that the zImage unpacks, up to the end of its bss |
| 0x70800000 | the uImage as U-Boot reads it from the slot |
| 0x70D00000 | the uInitrd. U-Boot gives it to the kernel at this address. |
| 0x71000000 | the zImage. U-Boot copies it from the uImage. |

The kernel must end below 0x70D00000. `kernel/build-kernel.sh` stops with an
error if it does not. The zImage starts above the kernel, so it does not move
itself over the ramdisk.

The ramdisk shows the boot splash (`image/mkinitrd.sh`). Its `/init` draws the
splash of tsx-linux-common on the framebuffer, mounts the root partition and
starts `/sbin/init` there. The kernel keeps its text console off the LCD
(`fbcon=map:1`), so the splash stays on the screen until the panel app takes
the display. See [docs/hardware.md](docs/hardware.md), "Boot splash".

## Card layout

| Offset | Content |
|---|---|
| 0x000000 | MBR, disk id 0x7458a050 |
| 0x000400 | stock U-Boot (from the stock card) |
| 0x0C0000 | stock U-Boot env, 128 KiB (from the stock card) |
| 0x100000, 0x200000 | uInitrd, normal and golden slot |
| 0x800000, 0xC00000 | uImage, normal and golden slot |
| 16 MiB | p1, FAT16 `TSXLOG`, 64 MiB |
| 80 MiB | p2, ext4 `tsxroot`, 1536 MiB |
| after p2 | p3, ext4 `tsxdata`, 512 MiB (`/data`) |

## Kernel

The kernel is the branch `tsx-xx50-lts` of
[tsx-mainline/linux](https://github.com/tsx-mainline/linux), on Linux
v6.18.54. `kernel/KERNEL_REV` names the commit that this repository builds.
The board DTS is `arch/arm/boot/dts/nxp/imx/imx53-crestron-tss752.dts`. The
config is `imx_v6_v7_defconfig` plus `arch/arm/configs/tsx-xx50.config`.

## Build

```sh
TSX_COMMON=<tsx-linux-common checkout> [AUTHORIZED_KEYS=<ssh public key file>] ./build.sh <kernel-tree> <stock-card-dump> [out-dir]
```

The build needs docker. Details, the single steps and the tests are in
[docs/build.md](docs/build.md).

## License

GPL-2.0-or-later, see [LICENSE](LICENSE).
