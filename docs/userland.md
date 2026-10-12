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
| tsx-sendspin | tsx-linux-common `sendspin/` | The Sendspin player for Music Assistant. Optional, see "Sendspin". |

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
| `/etc/asound.conf` | The PCMs of the codec: `default`/`speaker` and `media`, on a dmix that all users share (see "Audio and volume") |
| `/etc/init.d/tsx-audio`, `/usr/local/bin/tsx-audio`, `/etc/tsx/audio.conf` | At boot: the codec path to the speaker, the softvol controls `Master` and `Media` and the saved levels. At shutdown: saves the levels |

## Audio and volume

`tsx-audio init` (the service `tsx-audio`, at boot) sets the codec path: the DAC to the line out mixer and the line out driver to the speaker amplifier. It sets the DAC level `PCM` to -6 dB and the line out gain to 0 dB (`CODEC_PCM`, `CODEC_LO_GAIN` of `/etc/tsx/audio.conf`). These two gains are the cap of the speaker. The vendor firmware drives the line out at +20 dB.

The panel has one volume. The setup page (Panel section), the Home Assistant number "Volume" of the panel app, the volume slider of the settings overlay and `tsx-panelctl send volume N` set it.

- While the Sendspin player runs (see "Sendspin"), the volume of the panel is the player volume of Music Assistant. A change in Music Assistant shows on the panel, and a change on the panel shows in Music Assistant. The mute is the mute of the player. At each start, the service `tsx-sendspin` runs `tsx-audio fixed`: `Master` goes to `MASTER_SENDSPIN` of `/etc/tsx/audio.conf` (100 %, 0 dB) and stays there. The codec gains below stay the cap of the speaker.
- Without the player, the volume of the panel is the softvol `Master` (0 to 100 %, linear in dB from -50 dB to 0 dB, 0 % is silence). The default is 50 %. `tsx-audio volume [N]` reads or sets it from a shell. That panel has no mute.

`tsx-audio status` shows the levels and the codec gains. The service saves the levels at shutdown in `/var/lib/tsx/asound.state`.

When the player stops (`SENDSPIN=off`), `Master` is the volume of the panel again. It starts at the fixed level (100 %), the safe maximum of the speaker.

The PCMs of `/etc/asound.conf`:

| PCM | Path | Users |
|---|---|---|
| `default`, `speaker` | `Master` -> dmix | Sounds of the panel |
| `media` | `Media` -> `Master` -> dmix | The Sendspin player |

The dmix lets several users play at the same time (`ipc_perm 0666`). `Media` stays at 100 %. A voice feature can turn it down to make the music quieter.

## Sendspin

The package tsx-sendspin plays music from Music Assistant on the speaker. The image does not have it. To add it to a panel:

1. Run `apk add tsx-sendspin`.
2. Run `tsx-config set SENDSPIN on`.
3. Run `tsx-config apply`.

The player starts as the user `tsx-sendspin` and tells Music Assistant about itself over mDNS. Home Assistant shows it as a media player with the host name of the panel (or `PANEL_NAME`). `tsx-config set SENDSPIN off` and `tsx-config apply` stop it again. See [sendspin.md of tsx-linux-common](https://github.com/tsx-mainline/tsx-linux-common/blob/main/docs/sendspin.md).

## Users and root

The services of the panel run with the least privilege that they need. [security.md of tsx-linux-common](https://github.com/tsx-mainline/tsx-linux-common/blob/main/docs/security.md) lists the users, the groups and the commands of the root helper `tsx-panelctl`. On the xx50:

| Service | User | Why |
|---|---|---|
| `tsx-panel-app` | `tsx-panel-app` | The program draws the screen and talks to Home Assistant. It needs the display, the touch, the keys, the sound, the backlight, the light bars and the CPU frequency limits (groups and sysfs write access, see `PANEL_APP_LEDS` in `/etc/tsx/panel-app-board.conf`). Reboot, the setup window, the screen times in `panel.conf` and the layout install go through `tsx-panelctl`. |
| `tsx-sendspin` | `tsx-sendspin` | The player needs only the sound and avahi. |
| `tsx-setupd` | `tsx-setup` | The setup page. `tsx-setup-helper` does its root actions. |
| `tsx-panelctl`, `tsx-setup-helper` | root | The two root helpers. Each takes only a fixed list of commands. |
| `tsx-boot-ok` | root | It writes the retry counters of the stock U-Boot env on the card. |
| `tsx-boot-rescue`, `tsx-kernel-slots` | root (commands for an administrator) | They write the U-Boot env and the raw kernel slots of the card. |
| `tsx-autoupdate` | root | `apk upgrade` and the reboot after an update. The kernel package writes the kernel slots. |
| `tsx-touch` | root, once at boot | It writes two registers of the touch controller on its I2C bus. |
| `tsx-cpufreq` | root, once at boot | It sets the CPU governor. |
| `tsx-audio` | root, at boot and shutdown | It sets the codec and saves the levels in `/var/lib/tsx`. |
| `tsx-config`, `tsx-data`, `tsx-hostname`, `tsx-setup` | root, once at boot | `panel.conf`, the run-time files, the host name, the MAC and the mounts. |
| `watchdog`, `sshd`, `crond`, `syslogd`, `udhcpc`, `getty` | root | The system services of Alpine. `chronyd` runs as `chrony`, `avahi-daemon` as `avahi`. |

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

The panel checks for package updates with `tsx-autoupdate` of
tsx-linux-common (its docs/autoupdate.md). The xx50 uses the defaults of
`/etc/tsx/autoupdate.conf`:

| Setting | Value |
|---|---|
| Mode | `MODE=auto`: the panel installs inside the window. `manual` only shows the update in Home Assistant. |
| Window | `WINDOW=03:00-05:00`, the local time of the panel (`TZ_NAME` of `panel.conf`, else UTC) |
| Restart | `AUTO_RESTART=on`: a restart right after an install that needs one |
| Check | Every 15 minutes (`crond`), in both modes |

The Home Assistant select "Update mode" and switch "Automatic restart" and
the Panel section of the setup page change the mode and the restart. They
save `UPDATE_MODE` and `UPDATE_AUTO_RESTART` in `panel.conf`, which win over
the file.

An automatic install runs only while the screen is off. The panel app writes
the screen state for it (`/run/tsx-idled.state`). After `BLANK_TIMEOUT` (300 s
by default) with no touch, the screen goes off and the update can start.

The Home Assistant version of the panel is the version of `tsx-xx50-board`,
for example `0.3.6`. An update of tsx-xx50-board, tsx-xx50-panel-app,
tsx-xx50-kernel-lts or another `tsx-*` package needs a restart. With
`AUTO_RESTART=off`, Home Assistant shows "Restart required" until the panel
restarts. In the meantime the Update entity stays in the list of updates. Its
title says "Restart required to finish" and the new release, and the latest
version has the text "(restart required)". After the restart, `tsx-autoupdate`
checks the panel app: the service runs, the app drew its first frame and,
if it had Home Assistant before the restart, it connected again. The result
is in `tsx-autoupdate status` ("health") and in `/var/log/tsx-autoupdate.log`.

A kernel update writes only the normal kernel slots. `tsx-boot-ok` marks
each good boot. The golden slots keep the old kernel until you run
`tsx-kernel-slots promote` (see "Kernel package").

To install at once, use Install in Home Assistant or run
`tsx-autoupdate now`. Both ignore the window and the mode. To stop the
automatic installs, set the mode to `manual`.

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
or a PC on the same network. There are two logins:

- **Log in with Home Assistant**: an administrator of Home Assistant opens
  the page at any time, with no code. The panel needs the URL of its Home
  Assistant for this: the field "Home Assistant URL for the login on this
  page" (`HA_URL`). Set it once with the pairing code.
- The pairing code from the panel screen:
  1. Push the `power` key (the top key) of the panel, or tap the screen with
     five fingers. The settings overlay opens. Tap "Open setup". The pairing
     code works for 15 minutes. Over ssh, `tsx-config setup` does the same.
  2. Read the address and the code in the bar at the top of the panel screen.
  3. Open the address in a browser and type the code.

A new panel has no settings. Until the first save, the pairing code works
with no key push. The setup page sets these values: the API encryption key
of the panel app, the Home Assistant URL for the login, the panel name, the
time zone, the ssh key for root and the layout (the layout editor). Its
Panel section has live controls: the screen, the brightness, the dim and off
times and the light bars. See `docs/setup.md` of tsx-linux-common.

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
| Layout hash | The SHA-256 of the layout file in use. |
| Update | The update of the panel packages. Install installs at once. |
| Restart required | On while an installed update waits for a restart. |
| Restart | A button that restarts the panel. |
| Update mode | A select: `auto` or `manual` (`UPDATE_MODE` of `panel.conf`). |
| Automatic restart | A switch (`UPDATE_AUTO_RESTART` of `panel.conf`). |

The device also has two actions: `esphome.<device>_set_layout` (a layout as
JSON text: the panel checks it, saves it and shows it) and
`esphome.<device>_get_layout` (the layout in use, as an answer of the
action). See "Layout from Home Assistant" in `docs/panel-app.md` of
tsx-linux-common.

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
