# Update a card on a PC

`image/update-card.sh` puts a new card image on a card that already runs.
It keeps the data partition. Use it for a new kernel and a new root file
system. Do not use it for a new card. For a new card, write the full image
(see [install.md](install.md)).

The panel cannot update the card that it runs from. Take the card out of the
panel and use a Linux PC with a USB card reader.

## What the script does

The script writes only these ranges, from the new image to the same offsets:

- the two uInitrd slots (1 MiB each, at 0x100000 and 0x200000)
- the two uImage slots (4 MiB each, at 0x800000 and 0xC00000)
- p2 (`tsxroot`, the root file system)

The script keeps the MBR, the stock U-Boot and its env, p1 (`TSXLOG`) and p3
(`tsxdata`). So the settings, the layout, the keys and the logs stay.

The new p2 replaces the old p2. A change outside `/var/lib/tsx`, `/var/log`,
`/root` and `/home` is lost. Examples are a package that you installed and a
file that you changed in `/etc`. The data partition holds these four folders
(see [userland.md](userland.md), "Card layout").

After the write, the script reads each range back from the card. It compares
the sha256 with the new image. A card is good only when the script ends with
no error.

If p2 of the card is larger than the new p2, the script also runs `e2fsck`
and `resize2fs` on p2. The file system then fills the partition. p3 does not
move.

## What you need

- A Linux PC with a USB card reader.
- The image `tsx-xx50-tss752.img.gz` and its `.sha256` file in the same
  folder.
- This repository, or a copy of `image/update-card.sh`.
- Root access (`sudo`).
- 2.1 GiB of free space in the temporary directory (`/tmp`). The script
  unpacks the image there. The unpacked image has 2128 MiB.
- The tools `dd`, `od`, `awk`, `sha256sum` and `gzip`. For the p2 grow,
  also `e2fsck` and `resize2fs`.

## Steps

1. Shut down the panel. Over ssh, run
   `ssh -i ~/.ssh/TSX-XX50 root@<panel-ip> poweroff`.
2. Wait 30 seconds.
3. Disconnect the PoE cable.
4. Remove the card from the card slot of the panel.
5. Check the download:
   `sha256sum -c tsx-xx50-tss752.img.gz.sha256`
6. Find the disks of the PC before you insert the card:
   `lsblk -o NAME,SIZE,MODEL,LABEL,PARTUUID`
7. Insert the card in the card reader.
8. Connect the reader to the PC.
9. Run the `lsblk` command again. The new disk is the card. For example
   `sdc` or `mmcblk1`.
10. Make sure that the disk is the card. Check these points:
    - The size is the size of the card, not the size of a PC disk.
    - The partitions have the labels `TSXLOG`, `tsxroot` and `tsxdata`.
    - The PARTUUID of the partitions starts with `7458a050`.
11. If you are not sure, stop. A wrong device name destroys the data on that
    disk.
12. If the desktop mounted partitions of the card, unmount them:
    `sudo umount /dev/sdX1 /dev/sdX2 /dev/sdX3`
    Use the desktop eject for the partitions. Do not power off the reader.
13. Do a dry run. Replace `sdX` with the disk of the card. The dry run
    also unpacks the image, but it writes nothing:
    `sudo image/update-card.sh --dry-run tsx-xx50-tss752.img.gz /dev/sdX`
14. Read the plan. The plan must list the five ranges. It must say that p1
    and p3 stay.
15. Run the script:
    `sudo image/update-card.sh tsx-xx50-tss752.img.gz /dev/sdX`
16. Type `yes` when the script asks.
17. Wait until the last line starts with `== done`. Do not remove the card
    before this line.
18. Run `sync`.
19. Disconnect the card reader.
20. Remove the card.
21. Insert the card in the card slot of the panel.
22. Connect the PoE cable. The panel starts.

A disk name that ends in a digit, such as `mmcblk1`, has the partitions
`mmcblk1p1`, `mmcblk1p2` and `mmcblk1p3`.

## What the output shows

The script prints these parts, in this order:

1. The check of the image against the `.sha256` file (`sha256 ok`).
2. The unpack of the image to the temporary directory, with MiB and percent.
3. The partition tables of the image and of the card.
4. The plan: the ranges, their offsets and sizes.
5. The write of each range, with MiB and percent.
6. The read-back check: one line `ok` for each range.
7. If p2 of the card is larger than the new p2, the grow step.
8. The last line: `== done in <n> s: kernel slots and p2 updated, p3 kept`.

The write and the read-back check each handle about 1.5 GiB. The time
depends on the card and the reader. Expect about 5 minutes. A slow card or
reader needs longer.

## Check the panel

1. Wait about 2 minutes after the PoE cable is connected.
2. Log in over the network:
   `ssh -i ~/.ssh/TSX-XX50 root@<panel-ip>`
3. Check the version of the kernel: `uname -r`
4. Look at the screen. The panel app must show your layout.
5. Make sure that the top bar with the setup code is not on the screen. The
   bar shows only when the panel has no saved settings.
6. Open the setup page and check the settings:
   `http://<panel-ip>:8080/setup`

## Options

| Option | Function |
|---|---|
| `--dry-run`, `-n` | Do all checks, show the plan, write nothing |
| `--yes`, `-y` | Do not ask for `yes` |
| `--no-data` | Accept a card with no p3 (no data partition) |
| `--tmpdir DIR` | Unpack the image in `DIR` (default: `$TMPDIR`, then `/tmp`) |
| `--force-id` | Accept a disk id other than `0x7458a050` |
| `--sha256 FILE` | Use `FILE` as the checksum file (default: `<image>.sha256`) |

`sudo` removes `TMPDIR` from the environment. Use `--tmpdir` to select
another folder.

## Troubleshooting

| Message or problem | Cause | Action |
|---|---|---|
| `ERROR: /dev/sdX is a partition. Give the whole disk.` | The target is a partition, for example `/dev/sdX2` | Give the disk, for example `/dev/sdX` |
| `ERROR: /dev/sdX or one of its partitions is mounted or is swap. Unmount it first.` | A partition of the card is mounted | Unmount all partitions of the card (step 12) |
| `ERROR: no write access to /dev/sdX (run as root)` | The script does not run as root | Run it with `sudo` |
| `the target has no p3 (no data partition). Use --no-data to write it anyway.` | The card has no data partition | If the card has no data to keep, add `--no-data`. Otherwise stop |
| `the disk id of the target is not 0x7458a050. It may not be an xx50 card (--force-id accepts it)` | The disk is not a card of this image | Check the device name again. Add `--force-id` only for a card that you know |
| `the new p2 (<n> sectors) is larger than the p2 of the target (<n> sectors)` | The p2 of the card is smaller than the new p2 | Write the full image ([install.md](install.md)). This erases p3. Copy `/data` first |
| `p2 starts at sector <n> in the new image and at sector <n> on the target` | The card has another layout | Write the full image ([install.md](install.md)) |
| `p3 of the target (sector <n>) starts before the end of the new p2` | The new p2 does not fit before p3 | Write the full image ([install.md](install.md)) |
| `partition <n> of the target starts at sector <n>, below the kernel slots (sector 32768)` | A partition of the card is below 16 MiB. The slots would overwrite it | Stop. The card is not an xx50 card |
| `not enough free space in <dir>: need <n> MiB, have <n> MiB (use --tmpdir)` | The temporary directory is too small | Use `--tmpdir` with a folder on a larger disk |
| `the sha256 of <image> does not match <file>` | The download is not complete or not correct | Download the image again |
| `the read-back check failed. The card is NOT good. Write it again.` | A range on the card differs from the image | Run the script again with the same arguments. If it fails again, use another card or reader |
| The script stopped in the middle | The power or the reader failed, or you pressed Ctrl-C | Run the script again with the same arguments. The card does not boot before the script ends with no error |
| The panel does not start from the card | A write error, or the card is not good | Put the stock card in the panel. Or write the full image ([install.md](install.md)) |

The stock card is the way back. The update does not change it.
