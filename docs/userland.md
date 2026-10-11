# The xx50 userland

The xx50 runs the shared TSX userland of tsx-linux-common, as the other
panel families do. The xx50 has no browser kiosk: the panel app shows the
Home Assistant cards on the screen. This page tells what runs on the panel,
how to set it up and what an update keeps.

## Packages

| Package | Source | Contents |
|---|---|---|
| tsx-base | tsx-linux-common `base/` | `tsx-config`, the boot services (`tsx-setup`, `tsx-hostname`, `tsx-data`, `tsx-config`), the clock, the console banner |
| tsx-setup | tsx-linux-common `setup/` | The setup page `tsx-setupd` and its root helper |
| tsx-autoupdate | tsx-linux-common `autoupdate/` | The automatic update (see "Automatic update"). tsx-xx50-board depends on it. |
| tsx-panel-app | tsx-linux-common `panel-app/` | The service `tsx-panel-app`, the layout checker, the layout editor of the setup page |
| tsx-xx50-board | this repo, `rootfs/overlay` | The board layer (see below) |
| tsx-xx50-panel-app | this repo, `esphome-lvgl/` | The panel app program for the xx50 |
| tsx-xx50-kernel-lts | the kernel bundle of a release of this repo | The kernel, the ramdisk (the boot splash) and the modules. Optional, see "Kernel package". |

The xx50 does not install tsx-kiosk and tsx-ha. Without tsx-kiosk, the setup
page has no page URL field. Without tsx-ha, the panel has no second ESPHome
device and no MQTT bridge. The panel app is the only Home Assistant device of
the panel.

## Board layer

| File | Function |
|---|---|
| `/usr/local/lib/tsx/board.sh` | The board values. The MAC, the model and the host name come from the stock U-Boot env on the card (0xC0000, read only). The serial console is `ttymxc0` |
| `/usr/local/sbin/tsx-hw` | The parts that the TSS-752 does not have (`/run/tsx/hw.conf`) |
| `/usr/local/sbin/tsx-kernel-slots` | Writes a uImage and a uInitrd into the normal raw slots of the boot card, copies a kernel that booted well to the golden slots, and writes the rescue slot (see "Kernel package") |
| `/usr/local/sbin/tsx-boot-rescue` | Starts the rescue system at the next boot (`--golden`: through the golden slots of U-Boot). See [recovery.md](recovery.md) |
| `/etc/tsx/panel-board.conf` | The backlight range, the CPU governor, the CPU boost of the panel app and the touch controller mode |
| `/etc/init.d/tsx-cpufreq` | Sets the governor of `panel-board.conf` (`ondemand`, `up_threshold` 40, sampling rate 20 ms) after `tsx-setup` |
| `/etc/init.d/tsx-touch` | Keeps the FT5x06 touch controller in its active scan mode (`TOUCH_ALWAYS_ACTIVE`), as the factory driver did |
| `/etc/init.d/tsx-boot-ok`, `/usr/local/sbin/tsx-boot-ok` | 60 s after the start of the default runlevel, if the panel app or sshd runs: sets `boot_retry=8` and `golden_boot_retry=0` in the U-Boot env after a boot from the normal slots. It writes only when a value differs, and it checks the CRC and all other variables after the write. The result is in the system log (`tsx-boot-ok`). `tsx-boot-ok --status` shows the counters |
| `/etc/conf.d/watchdog` | busybox watchdog on the SoC watchdog, 60 s |
| `/etc/modules-load.d/tsx-xx50.conf` | Loads the GPU module `msm` |
| `/etc/securetty` | The Alpine list plus `ttymxc0` |
| `/etc/tsx/buttons-board.conf` | The five touch keys (names `power`, `home`, `lights`, `up`, `down`) |
| `/etc/tsx/panel-app-board.conf` | The environment of the panel app (the display is `tsx_drm` on card0, the touch and keys `tsx_evdev`) and the device file that it waits for |
| `/etc/tsx/panel-layout.json` | The default layout: a clock. The `power` key opens the settings overlay, the `lights` key turns the light bars on or off |

## Card layout

| Partition | Label | Mount point | Contents |
|---|---|---|---|
| p1 | TSXLOG | `/mnt/tsxlog` | FAT, readable on any PC |
| p2 | tsxroot | `/` | Alpine and the packages |
| p3 | tsxdata | `/data` | The settings and the state of the panel |

At the first boot, `tsx-data` moves `/var/lib/tsx`, `/var/log`, `/root` and
`/home` to `/data`, and then bind-mounts them back at each boot. `/data` also
holds `panel.conf` (`/data/tsx/panel.conf`). So these files stay when p2
changes:

- the layout of the user, `/var/lib/tsx/panel-layout.json`
- the identity of the panel app, `/var/lib/tsx/panel-app.conf`
- the API encryption key (`HA_API_KEY` in `panel.conf`)
- the ssh key of root, `/root/.ssh/authorized_keys`

A package update (`apk upgrade`) changes only p2, and the kernel slots for
tsx-xx50-kernel-lts. Do not write a full card image to keep the data: the
image also writes an empty p3.

A card with no p3 also works. Then `tsx-data` does nothing, and the state
stays on p2.

## Automatic update

The panel installs its package updates by itself with `tsx-autoupdate` of
tsx-linux-common (its docs/autoupdate.md). The xx50 uses the defaults of
`/etc/tsx/autoupdate.conf`:

| Setting | Value |
|---|---|
| Window | `WINDOW=03:00-05:00`, the local time of the panel (`TZ_NAME` of `panel.conf`, else UTC) |
| Reboot | `REBOOT=auto`: a reboot inside the window when the update needs one |
| Check | Every 15 minutes (`crond`) |

The update installs only while the screen is off. The panel app writes the
screen state for it (`/run/tsx-idled.state`). After `BLANK_TIMEOUT` (300 s
by default) with no touch, the screen goes off and the update can start.

An update of tsx-xx50-board, tsx-xx50-panel-app, tsx-xx50-kernel-lts or
another `tsx-*` package needs a reboot. After the reboot, `tsx-autoupdate`
checks the panel app: the service runs, the app drew its first frame and,
if it had Home Assistant before the reboot, it connected again. The result
is in `tsx-autoupdate status` ("health") and in `/var/log/tsx-autoupdate.log`.

A kernel update writes only the normal kernel slots. `tsx-boot-ok` marks
each good boot. The golden slots keep the old kernel until you run
`tsx-kernel-slots promote` (see "Kernel package").

To install at once, run `tsx-autoupdate now`. The window still controls the
reboot. To stop the automatic updates, set `ENABLED=0` in
`/etc/tsx/autoupdate.conf` and run `rc-service tsx-autoupdate restart`.

A panel with tsx-xx50-board 0.3.1 or older has no automatic update. Run
`apk upgrade` one time, then reboot. The reboot starts the service.

### Repositories

`/etc/apk/repositories` of a new image lists the public tsx-aports
repositories `common` and `xx50`, then Alpine `main` and `community`.
`tsx-config apply` writes the tsx-aports lines at each boot from
`APK_URL` of `panel.conf`:

- No `APK_URL`: `https://tsx-aports.unexceptional.net`.
- `APK_URL=<url>`: a mirror or a local folder with the same tree.
- `APK_URL=off`: no tsx-aports lines.

`tsx-config apply` keeps the Alpine lines and every other line that you
added. Remove a test repository line by hand when you do not need it.

## Update a card

Use `image/update-card.sh` to put a new card image on a card that already
runs. The script keeps the data partition. The steps are in
[update-card.md](update-card.md).

## Setup page

The setup page is `http://<panel address>:8080/setup`. It works from a phone
or a PC on the same network, with a pairing code from the panel screen:

1. Push the `power` key (the top key) of the panel, or tap the screen with
   five fingers. The settings overlay opens. Tap "Open setup". The setup
   window opens for 15 minutes. Over ssh, `tsx-config setup` does the
   same.
2. Read the address and the code in the bar at the top of the panel screen.
3. Open the address in a browser and type the code.

A new panel has no settings. Until the first save, the setup page is open
with no key push. The setup page sets these values: the API encryption key
of the panel app, the panel name, the time zone, the ssh key for root and
the layout (the layout editor).

## Panel app

The service `tsx-panel-app` runs the program. Commands:

- `rc-service tsx-panel-app status | restart | stop`
- `tsx-panel-app-run --print`: the name, the MAC and the environment
- the log: `/var/log/tsx-panel-app.log`

To add the panel to Home Assistant:

1. Set the API encryption key on the setup page ("Make a new key", then
   copy the key).
2. In Home Assistant, go to Settings > Devices & services > Add integration >
   ESPHome.
3. Type the address of the panel and port 6053.
4. Paste the key.

The device name is the host name in lowercase, for example
`tss-752-00005e00532a`. The first start writes it to
`/var/lib/tsx/panel-app.conf`.

The device has these entities in Home Assistant:

| Entity | Function |
|---|---|
| Light bar left, Light bar right | The light bars (RGB, brightness). Off after each start. |
| Screen | On or off. Off turns the backlight and the display output off. |
| Backlight | The brightness, 1 to 100 %. |
| Blank timeout, Dim timeout, Dim level | The screen settings (`BLANK_TIMEOUT`, `DIM_TIMEOUT`, `DIM_LEVEL` of `panel.conf`). |
| Key power, Key home, Key lights, Key up, Key down | The keys: the event types `press` and `long` (0.8 s). |

Home Assistant can change the lights, the screen and the numbers. The
device setting "Allow the device to perform Home Assistant actions" controls
only the actions that the panel sends. These are card taps, card buttons and
popups.

The keys of the default layout:

| Key | Action |
|---|---|
| `power` | Opens the settings overlay (brightness, dim and off times, Screen off, Lights, Open setup, Reboot, the address and the versions) |
| `home` | Page 1 |
| `lights` | Light bars on or off (no Home Assistant call) |
| `up`, `down` | The previous or the next page |

A layout of the user can map the keys to other actions (the layout editor,
"Keys"). A key press on a dark or dim screen only wakes the screen.

## Kernel package

The card image has the kernel in its raw slots and the modules in p2. An
image update (`image/update-card.sh`) changes both. The package
tsx-xx50-kernel-lts gives the same kernel through `apk`:

| File | Content |
|---|---|
| `/boot/uImage-lts`, `/boot/uInitrd-lts` | The kernel and the ramdisk (the boot splash, the start of the rescue system) |
| `/boot/tsx-xx50-rescue-lts.img` | The rescue system for the rescue slot |
| `/lib/modules/<release>/` | The modules |

At install and at upgrade, the package runs
`tsx-kernel-slots write /boot/uImage-lts /boot/uInitrd-lts`, but only on a
TSS-752 that runs from its card. The command writes the normal slots and
reads them back. The golden slots keep the last good kernel. The new kernel
starts at the next boot. If the command reports an error, run it again
before a reboot. Then the package runs
`tsx-kernel-slots rescue /boot/tsx-xx50-rescue-lts.img`. It writes the rescue
slot only when its content differs.

If the new kernel fails two times, U-Boot boots the golden slots, and the
rescue system starts (see [recovery.md](recovery.md)). After good boots of
the new kernel, copy it to the golden slots:

```sh
tsx-kernel-slots promote
```

The command copies only the kernel of the current boot, and only after
`tsx-boot-ok` marked the boot good (60 s after the start). It refuses after
a boot from the golden slots, and when the normal slots changed after the
start. `tsx-kernel-slots promote --force` skips these checks.

`tsx-kernel-slots show` prints the kernel name in each slot, whether the
golden slots hold the same files as the normal slots, and the version of the
rescue system. The golden ramdisk starts the rescue system only from 0.3.3
on. So run `tsx-kernel-slots promote` once after the first good boot of a
0.3.3 kernel.

## Panel app on the xx50

| Item | Value |
|---|---|
| Display | `tsx_drm` on `card0` (DRM/KMS, RGB565, page flips). No SDL, no Mesa. |
| Input | `tsx_evdev` on the FT5x06 input device: touch, five fingers, the five keys. |
| First picture | About 0.2 s after the program start (0.7 s after a cold boot). |
| Page change | About 10 ms. |
| Clock | The time and the time zone of Home Assistant (Home Assistant 2026.3 or newer sends the time zone). With an older Home Assistant, the clock shows UTC. |

CPU speed: the board service `tsx-cpufreq` sets `ondemand` with
`up_threshold` 40. The panel app sets the CPU to 1 GHz for 1.5 s after a
touch, a key, a redraw or a wake (`CPUFREQ_BOOST_MS`). While the screen is
off, it keeps the CPU at the lowest point, 167 MHz
(`CPUFREQ_SCREEN_OFF=lowest`). The settings are in
`/etc/tsx/panel-board.conf`.

The dark screen: the panel app turns the backlight off and shows a black
frame. The display output stays on, so the panel shows no white frame at the
wake. The first touch on a dark or dim screen only wakes the screen.

The touch controller: `tsx-touch` keeps the FT5x06 in its active scan mode
(`TOUCH_ALWAYS_ACTIVE=yes`). In its monitor mode, the controller can lose a
short tap on a dark screen. `tsx-touch` writes the registers while the
driver owns the device. After a reload of the `edt-ft5x06` module, run
`rc-service tsx-touch restart`.

Card design: the CPU draws all cards in software. Shadows, opacity below
100 % and outlines cost the most. Radius, gradients and borders cost little.
