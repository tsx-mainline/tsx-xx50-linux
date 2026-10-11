# Build

This page tells how to build the card image and its parts from source. It
also lists the tests and the output of CI and of a release.

## Requirements

- Linux with docker. The rootfs step and the panel app compile run in armv7
  Alpine containers. An arm64 host runs them natively. Another host needs
  qemu-user binfmt support.
- python3 with venv (the panel app build and `image/check-card.py`), git,
  zstd.
- A dump of the stock SD card of the panel, for the full card image
  ([install.md](install.md), "Make a dump of the stock card").

## Full card image

1. Get the kernel tree of `kernel/KERNEL_REV`:
   `kernel/fetch-kernel.sh ../linux`
2. Get tsx-linux-common at the tag of `COMMON_REF` (the ramdisk uses its
   `splash/`, the rescue system its `rescue/`):
   `git clone -b <tag> https://github.com/tsx-mainline/tsx-linux-common ../tsx-linux-common`
3. Build the image:
   `TSX_COMMON=../tsx-linux-common ./build.sh ../linux stock-card.img out`

`build.sh` runs these steps:

| Step | Script | Output in `out/` |
|---|---|---|
| Kernel | `kernel/build-kernel.sh` | `kernel/uImage`, the DTB, `kernel/modules/`, `kernel/kernel.release` |
| Root file system | `rootfs/mkrootfs.sh` | `work/rootfs.ext4`, `work/data.ext4`, `work/rootfs.manifest` |
| Ramdisk (boot splash) | `image/mkinitrd.sh` | `work/uInitrd` |
| Rescue system | `image/mkrescue.sh` | `work/tsx-xx50-rescue.img`, its `.sha256`, `work/rescue.manifest` |
| Card image | `image/mkcard.sh` | `tsx-xx50-tss752.img`, `.img.gz` and the `.sha256` files |
| Offline checks | `image/check-card.py` | none (it reports each check) |

Environment of `build.sh` and `rootfs/mkrootfs.sh`:

| Variable | Default | Function |
|---|---|---|
| `TSX_COMMON` | none (required) | A tsx-linux-common checkout. `image/mkinitrd.sh` compiles `tsx-splash` and renders the 800x480 splash from its `splash/` folder. `image/mkrescue.sh` takes the rescue tools from its `rescue/` folder. |
| `RESCUE_VERSION` | `git describe` | The version line of the rescue system. |
| `AUTHORIZED_KEYS` | none | A file with the ssh public keys for root. Without it, set the key on the setup page. |
| `TSX_APK_LOCAL` | none | A local tsx-aports tree (`v3.24/common/armv7`, `v3.24/xx50/armv7`) for packages that are not published yet. |
| `TSX_APK_URL` | `https://tsx-aports.unexceptional.net` | The package repository of the image and of the panel. |
| `ROOTFS_MB`, `DATA_MB` | 1536, 512 | The sizes of p2 and p3 in MiB. |

The kernel must fit the 4 MiB kernel slot. `kernel/build-kernel.sh` stops
with an error when the uImage is larger, or when the kernel in memory
reaches the ramdisk at 0x70D00000 (see README.md, "Boot path").

## Root file system

`rootfs/mkrootfs.sh` installs the Alpine packages of `rootfs/packages.txt`
and the TSX packages of `rootfs/packages-tsx.txt` from the package
repository. The image owns only `/etc/inittab` and `/etc/fstab`. The
packages own all other panel files:

| Package | Source |
|---|---|
| tsx-base, tsx-setup, tsx-panel-app | tsx-linux-common |
| tsx-xx50-board | `rootfs/overlay` of this repository (tag `board-v<version>`) |
| tsx-xx50-panel-app | the panel app program, built from the source archive of a release |

The image also gets the GPU firmware `qcom/yamato_pm4.fw` and
`qcom/yamato_pfp.fw` from the Alpine package `linux-firmware-qcom`.

## Panel app program

```sh
esphome-lvgl/build.sh esphome-lvgl/panel-app.yaml out/esphome-lvgl
```

The YAML of the board is `esphome-lvgl/panel-app.yaml`. The generic part
(the components, the fonts, the API) is in `panel-app/esphome` of
tsx-linux-common. `TSX_COMMON` names that checkout. `COMMON_REF` holds the
tag of tsx-linux-common that CI and a release use.

The build has three parts:

1. ESPHome (in a Python venv on the host) writes the C++ project.
2. The script changes the paths of the host in the project to relative
   paths, or to the placeholder `@PROJECT_DIR@`.
3. `esphome-lvgl/compile.sh` compiles the project with PlatformIO in an
   armv7 Alpine container.

`esphome-lvgl/mksource.sh` packs the project as
`tsx-xx50-panel-app-src-<version>.tar.gz`. The package tsx-xx50-panel-app
of tsx-aports compiles the program from this archive with `compile.sh`,
inside abuild.

The program holds no value of one panel. The service gives it the name, the
MAC and the API key at start ([userland.md](userland.md), "Panel app").

## Tests

| Test | What it checks | Needs |
|---|---|---|
| `ci/lint.sh` | `busybox sh -n` of the shell scripts, Python syntax, JSON, the doc links | busybox, python3 |
| `tests/test-board.sh` | The board values from a made-up U-Boot env, `tsx-hw`, the panel app environment, the layouts, the apk repositories after `tsx-config apply`, the reboot rule of `tsx-autoupdate` for the xx50 packages | python3, a tsx-linux-common checkout (`TSX_COMMON`) |
| `tests/test-kernel-slots.sh` | `tsx-kernel-slots` on a card image file: the write to the normal slots, `promote`, `restore`, `check`, the rescue slot, the refusals | python3 |
| `tests/test-boot-ok.sh` | `tsx-boot-ok` on made-up U-Boot envs: the write, `--reset`, `--fallback`, the read-back, the refusals | docker (an armv7 Alpine container with u-boot-tools), python3 |
| `tests/test-init.sh` | The ramdisk program in its test mode: the U-Boot env, the rescue archive (files, links, devices, modes, damaged archives), the `RESCUE` file. With `RESCUE_IMG`, also the real rescue system | docker (an armv7 Alpine container with gcc), python3 |
| `tests/test-rescue-tools.sh` | `tsx-boot-rescue`, `tsx-boot-mainline` and `tsx-restore-stock` with fakes and card image files | busybox, python3 |
| `tests/test-update-card.sh` | `image/update-card.sh` on small card image files | e2fsprogs for the grow checks |
| `tests/qemu-image.sh` | A full card image in QEMU (vexpress-a9): OpenRC, the data partition, the setup page, the ssh login. With `INITRD` (the `initrd.cpio.gz` of `image/mkinitrd.sh`), also the boot through the ramdisk | a card image, a kernel from `tests/build-qemu-kernel.sh`, qemu-system-arm |

Run the shell tests with busybox sh, the shell of the panel:
`busybox sh tests/test-board.sh`. The panel app needs the panel. QEMU has no
i.MX53 machine, no display and no GPU, so `tests/qemu-image.sh` does not
check the panel app.

## Development tools

| File | Function |
|---|---|
| `esphome-lvgl/demo-drm.yaml` | A test page with an animation and frame counters (`tsx_perf.h`). It needs `secrets.yaml` (see `secrets.yaml.example`). |
| `esphome-lvgl/inject.py` | Writes touch and key events into an input device: `tap`, `hold`, `mtap`, `swipe`, `drag`, `key`. Use it only with test pages. A tap on a real card sends its Home Assistant action. |
| `esphome-lvgl/bench/` | `lvbench`: the LVGL drawing speed and the DRM memory speed. `build-bench.sh` builds it. |

## CI

The workflows run on the arm64 runner `ubuntu-24.04-arm`.

| Workflow | Trigger | Jobs |
|---|---|---|
| `tests.yml` | push, pull request | `ci/lint.sh`, the host tests with busybox sh (and `test-update-card.sh` with dash) |
| `kernel.yml` | push, pull request | The kernel of `kernel/KERNEL_REV`, the ramdisk and the rescue system |
| `panel-app.yml` | push, pull request | The panel app program and its source archive |
| `release.yml` | tag `v*`, manual | The release assets (below) |

## Release

A release has two tags on the same commit:

- `board-v<version>`: the source of the package tsx-xx50-board (the GitHub
  archive of the tag).
- `v<version>`: `release.yml` builds the release assets.

| Asset | Content | User |
|---|---|---|
| `tsx-xx50-kernel-lts-bundle.tar.zst` | uImage, uInitrd, `tsx-xx50-rescue.img`, the DTB, the modules, `kernel.release`, `kernel.commit`, `CHECKSUMS.sha256` | the package tsx-xx50-kernel-lts |
| `tsx-xx50-panel-app-src-<version>.tar.gz` | the generated C++ project of the panel app, `compile.sh`, `BUILDINFO` | the package tsx-xx50-panel-app |
| `tsx-xx50-panel-app-<version>.tar.gz` | the program that CI compiled, with `BUILDINFO` | a check |
| `tsx-xx50-card-parts.tar.zst` | `kernel/uImage`, `work/uInitrd`, `work/tsx-xx50-rescue.img`, `work/rootfs.ext4`, `work/data.ext4`, `rootfs.manifest` | `image/mkcard.sh` |
| `SHA256SUMS` | the sha256 of each asset | |

CI cannot build a full card image. The image needs the stock U-Boot and its
env, and only the stock card of a panel holds them. The user completes the
card with the card parts and a dump of the stock card
([install.md](install.md)).

The card parts need the xx50 packages of the release in the package
repository. The order of a release:

1. Push the tags. `release.yml` builds the kernel bundle and the panel app
   assets. It skips the card parts when the repository has no xx50 packages
   of the release.
2. Change the xx50 recipes of tsx-aports to the new tags and assets, with
   their checksums. Its CI builds and publishes the packages.
3. Run `release.yml` again with the tag (images only):
   `gh workflow run release.yml -f tag=v<version>`. It builds the card parts
   from the kernel bundle of the release and the published packages.
