# Install on the TSS-752

The card image starts mainline Linux on a Crestron TSS-752 from a spare SD
card. It does not change the panel. The stock SD card stays as it is. To go
back to the Crestron firmware, put the stock card back.

The panel has no serial console that you can use. After the start, use the
setup page and ssh over the network. The services and the setup page are in
[userland.md](userland.md).

## What you need

- The TSS-752 with PoE.
- The stock SD card of the panel.
- A spare SD card, 4 GB to 32 GB (SDHC). The write erases all data on it.
- A Linux PC with an SD card reader, docker, python3 and zstd.
- A checkout of this repository at the release tag.
- A DHCP server on the panel network (your router).

Keep the stock card in a safe place. Never write to the stock card.

## Make a dump of the stock card

The card image needs the stock U-Boot and its env. They are in the first
MiB of the stock card. Only your own card gives them. This repository and its
releases do not hold them.

1. Disconnect the PoE cable from the panel.
2. Remove the stock SD card from the panel.
3. Put the stock card in the card reader of the PC.
4. Find the device name of the card:
   `lsblk -o NAME,SIZE,MODEL,TRAN`
5. Read the first MiB (replace `sdX` with the device name):
   `sudo dd if=/dev/sdX of=stock-card.img bs=1M count=1`
6. Optional: read the full card as a second file, for a restore of the
   stock firmware without the stock card ([recovery.md](recovery.md)):
   `sudo dd if=/dev/sdX bs=4M status=progress | gzip > stock-card-full.img.gz`
7. Remove the stock card from the PC.

The dump holds the MAC address and the unit id of your panel. Keep it
private.

## Make the card image

Use the card parts of a release, or build all parts from source
([build.md](build.md)).

1. Download `tsx-xx50-card-parts.tar.zst` and `SHA256SUMS` from the release.
2. Check the download:
   `sha256sum -c --ignore-missing SHA256SUMS`
3. Unpack the parts:
   `mkdir parts && tar --zstd -xf tsx-xx50-card-parts.tar.zst -C parts`
4. Make the image (in the repository checkout):
   `image/mkcard.sh --tz America/Denver stock-card.img parts/kernel parts/work out`
5. Check the image:
   `python3 image/check-card.py out/tsx-xx50-tss752.img stock-card.img`

The option `--tz` sets the time zone of the panel. Without it, `image/mkcard.sh`
shows the time zone of your PC at a terminal and asks. Press Enter to use it.
Without a terminal, the script uses that zone and prints it. `--tz none`
writes no zone, and the panel runs on UTC until you save the setup page.
The update window of the panel (03:00 to 05:00) uses this zone. The script
writes the zone to the data partition (`/data/tsx/timezone`). It does not
write `panel.conf`, so the setup page and the pairing code stay open for the
first setup. The first save of the setup page writes `TZ_NAME`, and that
value wins. To change the zone of a running panel, use the setup page or
`tsx-config set TZ_NAME <zone>` and `tsx-config apply`.

The result is `out/tsx-xx50-tss752.img.gz` and its `.sha256` file. The image
holds your stock U-Boot and env, so keep it private too.

The card parts of a release have no ssh key for root. Set the key on the
setup page after the first start. A build from source can add the key
(`AUTHORIZED_KEYS`, see [build.md](build.md)).

## Write the card on Linux

1. Insert the spare SD card in the PC.
2. Find the device name of the card:
   `lsblk -o NAME,SIZE,MODEL,TRAN`
   Look for a disk with the size of the card, for example `sdc` or `mmcblk0`.
3. Make sure that the name is correct. The next step erases the whole device.
   A wrong name erases a disk of your PC.
4. If the system mounted partitions of the card, unmount them:
   `sudo umount /dev/sdX?*`
5. Write the image (replace `sdX` with the device name):
   `gzip -dc out/tsx-xx50-tss752.img.gz | sudo dd of=/dev/sdX bs=4M conv=fsync status=progress`
6. Run `sync`. Then remove the card.

To put a new image on a card that already runs, and keep its data, use
`image/update-card.sh` ([userland.md](userland.md), "Update a card").

## Start the panel

1. Disconnect the PoE cable from the panel.
2. Remove the stock SD card from the SD card slot of the panel.
3. Insert the new card in the same slot.
4. Connect the PoE cable. The panel starts.
5. Wait about 2 minutes. At the first start, the panel moves its state to
   the data partition and makes its ssh host keys.

The stock U-Boot starts after about 3 seconds. The kernel starts after about
5 more seconds. The boot splash shows about 2 seconds after the kernel
start. The panel app shows its first picture about 20 seconds after the
kernel start.

## What to look for on the screen

- The Crestron logo of U-Boot, then the boot splash (Tux, "TSX-LINUX" and
  "starting"), then the panel app: a big clock. Until Home Assistant sends
  the time, the clock shows `--:--`.
- A bar at the top of the screen with the setup address and a code. A new
  panel shows it until the first save of the setup page.
- The boot splash stays: the kernel runs, but the panel app did not start.
  Log in with ssh and read `/var/log/tsx-panel-app.log`.
- Text on the screen and then a restart: the ramdisk did not find the root
  partition. The text gives the reason.
- The panel restarts again and again: a crash or the watchdog.

## First setup

1. Open the address of the bar in a browser on the same network, for example
   `http://<panel-ip>:8080/setup`.
2. Type the code of the bar.
3. Set the panel name, the time zone (the page shows `no change` until you
   choose one) and the ssh key for root.
4. Make the API encryption key of the panel app, and copy it.
5. Save.
6. Add the panel to Home Assistant ([userland.md](userland.md), "Panel app").

## Log in with ssh

`ssh root@<panel-ip>`

The root password is locked. Only an ssh key works: the key of the setup
page, or the key of `AUTHORIZED_KEYS` in a build from source.

## Logs

The logs are in `/var/log` on the panel: `messages`, `rc.log`,
`tsx-panel-app.log`, `tsx-setupd.log`. The FAT partition `TSXLOG` is at
`/mnt/tsxlog`. Use it to move files between a PC and the panel.

## Go back to the stock card

1. Disconnect the PoE cable.
2. Remove the new card.
3. Insert the stock SD card in the slot.
4. Connect the PoE cable. The panel starts the Crestron firmware.

The stock U-Boot saves its settings on the card that it starts from. So the
new card does not change the stock card. If the stock card is lost, see
[recovery.md](recovery.md), "Go back to the stock firmware".

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `image/mkcard.sh` stops with "is not a time zone of this computer" | The name is not in `/usr/share/zoneinfo` of the PC, or it has a wrong character. | Use a name like `America/Denver`, or `--tz none`. |
| `image/mkcard.sh` stops with "the stock dump is too short" | The dump is smaller than 1 MiB. | Read the first MiB of the stock card again. |
| `image/check-card.py` reports the U-Boot env CRC | The dump is not from a stock card, or the read failed. | Read the dump again from the stock card. |
| No DHCP lease and no picture | The kernel did not start. | Write the card again. Check the image with `image/check-card.py` first. |
| The rescue screen shows in place of the panel app | Two boots failed, or a rescue trigger was there. | Log in and read the reason. See [recovery.md](recovery.md). |
| The setup bar does not show | The panel has settings already. | Push the top key (`power`), then tap "Open setup". |
| ssh refuses the login | The image has no root key. | Set the key on the setup page. |
