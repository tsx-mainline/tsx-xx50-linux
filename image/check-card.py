#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Check an xx50 card image without the panel.

    image/check-card.py <card.img> <stock-card-dump>

Checks:
  - the stock U-Boot and env range [0x400, 0xE0000) is byte-identical to the
    stock dump, and the env CRC is valid
  - the MBR: disk id, three partitions, no overlap with the raw area (16 MiB)
  - the uImage headers in both kernel slots: magic, CRCs, type, load and
    entry 0x70008000, size within the 4 MiB slot that U-Boot reads
  - the uInitrd headers in both ramdisk slots: size within 384 KiB, gzip cpio
  - the DTB appended to the zImage: FDT magic, structure, model, compatible
    (with dtc, if dtc is in PATH, also a full decompile)
  - the TSXLOG FAT label and the ext4 superblocks of the root and data
    partitions
Exit code 0 when all checks pass.
"""
import gzip
import shutil
import struct
import subprocess
import sys
import tempfile
import zlib

RAW_END = 16 << 20
UBOOT_START, ENV_START, ENV_END = 0x400, 0xC0000, 0xE0000
KERNEL_SLOTS = {"normal": 0x800000, "golden": 0xC00000}
INITRD_SLOTS = {"normal": 0x100000, "golden": 0x200000}
KERNEL_READ = 0x2000 * 512
INITRD_READ = 0x300 * 512
LOADADDR = 0x70008000
DISK_ID = 0x7458A050

failures = []


def check(cond, msg):
    print(("PASS  " if cond else "FAIL  ") + msg)
    if not cond:
        failures.append(msg)
    return cond


def read(f, off, n):
    f.seek(off)
    return f.read(n)


def uimage(buf, slot, want_type, read_max):
    (magic, hcrc, _time, size, load, ep, dcrc, os_, arch, typ, comp) = struct.unpack(
        ">IIIIIIIBBBB", buf[:32])
    name = buf[32:64].split(b"\0")[0].decode(errors="replace")
    hdr = bytearray(buf[:64])
    hdr[4:8] = b"\0\0\0\0"
    check(magic == 0x27051956, f"{slot}: uImage magic")
    check(zlib.crc32(bytes(hdr)) == hcrc, f"{slot}: header CRC")
    data = buf[64:64 + size]
    check(len(data) == size and zlib.crc32(data) == dcrc, f"{slot}: data CRC ({size} bytes)")
    check(64 + size <= read_max, f"{slot}: {64 + size} bytes fit the {read_max} bytes that U-Boot reads")
    check((os_, arch, typ, comp) == (5, 2, want_type, 0),
          f"{slot}: os linux, arch arm, type {want_type}, compression none (got {os_},{arch},{typ},{comp})")
    print(f"      name '{name}', load 0x{load:08x}, entry 0x{ep:08x}")
    return data, load, ep


def fdt_parse(blob):
    magic, total, off_struct, off_strings, _rsv, version = struct.unpack(">IIIIII", blob[:24])
    if magic != 0xD00DFEED:
        return None
    strings = blob[off_strings:]
    pos, depth, props, path = off_struct, 0, {}, []
    while True:
        tok = struct.unpack(">I", blob[pos:pos + 4])[0]
        pos += 4
        if tok == 1:
            end = blob.index(b"\0", pos)
            path.append(blob[pos:end].decode())
            pos = (end + 4) & ~3
            depth += 1
        elif tok == 2:
            path.pop()
            depth -= 1
        elif tok == 3:
            ln, nameoff = struct.unpack(">II", blob[pos:pos + 8])
            pos += 8
            pname = strings[nameoff:strings.index(b"\0", nameoff)].decode()
            props["/".join(path) + ":" + pname] = blob[pos:pos + ln]
            pos = (pos + ln + 3) & ~3
        elif tok == 4:
            continue
        elif tok == 9:
            break
        else:
            raise ValueError(f"bad FDT token {tok}")
    return total, version, depth, props


def main():
    if len(sys.argv) != 3:
        print(__doc__)
        return 2
    img = open(sys.argv[1], "rb")
    stock = open(sys.argv[2], "rb")

    print("== stock U-Boot and env")
    a = read(img, UBOOT_START, ENV_END - UBOOT_START)
    b = read(stock, UBOOT_START, ENV_END - UBOOT_START)
    check(a == b, "bytes 0x400..0xE0000 are identical to the stock dump")
    env = read(img, ENV_START, ENV_END - ENV_START)
    check(struct.unpack("<I", env[:4])[0] == zlib.crc32(env[4:]), "U-Boot env CRC is valid")
    check(read(img, 0x200, 0x200) == bytes(0x200), "bytes 0x200..0x400 are zero")
    check(read(img, ENV_END, 0x100000 - ENV_END) == bytes(0x100000 - ENV_END), "bytes 0xE0000..0x100000 are zero")
    ivt = struct.unpack("<I", read(img, 0x400, 4))[0]
    check(ivt & 0xFF == 0xD1, f"IVT header tag 0xD1 at 0x400 (0x{ivt:08x})")

    print("== partition table")
    mbr = read(img, 0, 512)
    check(mbr[510:512] == b"\x55\xaa", "MBR signature")
    check(struct.unpack("<I", mbr[440:444])[0] == DISK_ID, f"disk id 0x{DISK_ID:08x} (root=PARTUUID=7458a050-02)")
    parts = []
    for i in range(4):
        e = mbr[446 + 16 * i:462 + 16 * i]
        ptype, start, count = e[4], *struct.unpack("<II", e[8:16])
        if ptype:
            parts.append((i + 1, ptype, start, count))
            print(f"      p{i + 1}: type 0x{ptype:02x}, start {start}, sectors {count}, {count // 2048} MiB")
    check(len(parts) == 3, "three partitions")
    img.seek(0, 2)
    size = img.tell()
    prev_end = RAW_END // 512
    for n, ptype, start, count in parts:
        check(start >= prev_end, f"p{n} starts at or after sector {prev_end} (no overlap)")
        prev_end = start + count
    check(prev_end * 512 <= size, "the partitions end inside the image")
    check(size <= 3_900_000_000, f"image size {size} bytes fits a 4 GB card")
    check(len(parts) == 3 and parts[0][1] in (0x0B, 0x0C, 0x0E, 0x06) and parts[1][1] == 0x83 and parts[2][1] == 0x83,
          "p1 FAT, p2 and p3 Linux")

    print("== kernel slots")
    datas = []
    for slot, off in KERNEL_SLOTS.items():
        data, load, ep = uimage(read(img, off, KERNEL_READ), "kernel " + slot, 2, KERNEL_READ)
        check(load == LOADADDR and ep == LOADADDR, f"kernel {slot}: load and entry 0x{LOADADDR:08x}")
        datas.append(data)
    check(datas[0] == datas[1], "normal and golden kernel slots are identical")
    z = datas[0]
    zmagic, zstart, zend = struct.unpack("<III", z[0x24:0x30])
    check(zmagic == 0x016F2818, "zImage magic")
    dtb = z[zend - zstart:]
    print("== appended DTB")
    res = fdt_parse(dtb)
    if check(res is not None, "FDT magic after the zImage"):
        total, version, depth, props = res
        check(total == len(dtb), f"FDT total size {total} equals the appended bytes {len(dtb)}")
        check(depth == 0, f"FDT structure is balanced (version {version})")
        model = props.get(":model", b"").rstrip(b"\0").decode()
        compat = props.get(":compatible", b"").split(b"\0")
        print(f"      model '{model}', compatible {[c.decode() for c in compat if c]}")
        check(model == "Crestron TSS-752" and b"fsl,imx53" in compat, "model and compatible")
        check("/chosen:stdout-path" in props, "chosen node with stdout-path")
        mem = props.get("/memory@70000000:reg", b"")
        check(struct.unpack(">4I", mem) == (0x70000000, 0x20000000, 0xB0000000, 0x20000000) if len(mem) == 16 else False,
              "memory: 512 MiB at 0x70000000 and 512 MiB at 0xB0000000")
        check(any(k.startswith("/reserved-memory/ramoops@") for k in props), "ramoops reserved memory")
        dtc = shutil.which("dtc")
        if dtc:
            with tempfile.NamedTemporaryFile(suffix=".dtb") as t:
                t.write(dtb)
                t.flush()
                r = subprocess.run([dtc, "-q", "-I", "dtb", "-O", "dts", t.name], capture_output=True, text=True)
                check(r.returncode == 0 and "Crestron TSS-752" in r.stdout, "dtc decompiles the DTB")

    print("== ramdisk slots")
    rds = []
    for slot, off in INITRD_SLOTS.items():
        data, load, ep = uimage(read(img, off, INITRD_READ), "initrd " + slot, 3, INITRD_READ)
        rds.append(data)
    check(rds[0] == rds[1], "normal and golden ramdisk slots are identical")
    try:
        cpio = gzip.decompress(rds[0])
        check(cpio[:6] == b"070701" and b"tsx-initrd" in cpio and b"init\0" not in cpio,
              "the ramdisk is a newc cpio with /tsx-initrd and no /init")
    except OSError:
        check(False, "the ramdisk is gzip data")

    print("== file systems")
    p1, p2 = parts[0][2] * 512, parts[1][2] * 512
    bs = read(img, p1, 512)
    label = bs[0x2B:0x36] if bs[0x36:0x3B] == b"FAT16" or bs[0x36:0x3B] == b"FAT12" else bs[0x47:0x52]
    check(label.strip() == b"TSXLOG", f"p1 FAT label TSXLOG (got {label!r})")
    sb = read(img, p2 + 1024, 256)
    check(struct.unpack("<H", sb[56:58])[0] == 0xEF53, "p2 ext4 superblock magic")
    check(sb[120:136].rstrip(b"\0") == b"tsxroot", "p2 label tsxroot")
    if len(parts) == 3:
        sb = read(img, parts[2][2] * 512 + 1024, 256)
        check(struct.unpack("<H", sb[56:58])[0] == 0xEF53, "p3 ext4 superblock magic")
        check(sb[120:136].rstrip(b"\0") == b"tsxdata", "p3 label tsxdata")

    print("== result: " + ("ALL CHECKS PASS" if not failures else f"{len(failures)} CHECK(S) FAILED"))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
