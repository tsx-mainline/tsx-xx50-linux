#!/usr/bin/env python3
"""inject.py: write test events into an evdev node (the kernel passes them to
every reader of the node). For the LVGL demo only, never with real controls.
  inject.py key CODE [MS]       press and release a key (183 = KEY_F13), held MS ms (100)
  inject.py tap X Y             one touch tap at X,Y (screen pixels)
  inject.py hold X Y [MS]       one touch at X,Y held MS ms (default 800)
  inject.py mtap N X Y [MS]     a tap with N fingers (multi-touch slots 0..N-1, 60 px
                                apart from X,Y), all down for MS ms (150)
  inject.py drag X1 Y1 X2 Y2 [MS]  like swipe, with a hold of MS ms at the end
  inject.py swipe X1 Y1 X2 Y2   one touch drag from X1,Y1 to X2,Y2 in 0.3 s
  inject.py abs                 print the X/Y ranges of the node
DEV=/dev/input/event0 by default."""
import fcntl, os, struct, sys, time

DEV = os.environ.get("DEV", "/dev/input/event0")
EV_SYN, EV_KEY, EV_ABS = 0, 1, 3
BTN_TOUCH = 0x14a
ABS_X, ABS_Y = 0, 1
ABS_MT_SLOT, ABS_MT_X, ABS_MT_Y, ABS_MT_TID = 0x2f, 0x35, 0x36, 0x39


def absinfo(fd, code):
    buf = bytearray(24)
    fcntl.ioctl(fd, 0x80184540 + code, buf)  # EVIOCGABS(code)
    return struct.unpack("6i", buf)  # value min max fuzz flat res


def ev(fd, t, c, v):
    os.write(fd, struct.pack("IIHHi", 0, 0, t, c, v))


def syn(fd):
    ev(fd, EV_SYN, 0, 0)


fd = os.open(DEV, os.O_RDWR)
cmd = sys.argv[1]
if cmd == "abs":
    for name, code in (("x", ABS_X), ("y", ABS_Y), ("mt_x", ABS_MT_X), ("mt_y", ABS_MT_Y)):
        try:
            print(name, absinfo(fd, code))
        except OSError as e:
            print(name, e)
elif cmd == "key":
    code = int(sys.argv[2])
    ms = int(sys.argv[3]) if len(sys.argv) > 3 else 100
    ev(fd, EV_KEY, code, 1); syn(fd)
    time.sleep(ms / 1000)
    ev(fd, EV_KEY, code, 0); syn(fd)
elif cmd == "tap":
    x, y = int(sys.argv[2]), int(sys.argv[3])
    mx, my = absinfo(fd, ABS_MT_X)[2], absinfo(fd, ABS_MT_Y)[2]
    rx, ry = x * mx // 799, y * my // 479
    ev(fd, EV_ABS, ABS_MT_SLOT, 0); ev(fd, EV_ABS, ABS_MT_TID, 4242)
    ev(fd, EV_ABS, ABS_MT_X, rx); ev(fd, EV_ABS, ABS_MT_Y, ry)
    ev(fd, EV_KEY, BTN_TOUCH, 1); ev(fd, EV_ABS, ABS_X, rx); ev(fd, EV_ABS, ABS_Y, ry); syn(fd)
    time.sleep(0.12)
    ev(fd, EV_ABS, ABS_MT_TID, -1); ev(fd, EV_KEY, BTN_TOUCH, 0); syn(fd)
elif cmd in ("hold", "mtap"):
    if cmd == "hold":
        n, x, y = 1, int(sys.argv[2]), int(sys.argv[3])
        ms = int(sys.argv[4]) if len(sys.argv) > 4 else 800
    else:
        n, x, y = int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4])
        ms = int(sys.argv[5]) if len(sys.argv) > 5 else 150
    mx, my = absinfo(fd, ABS_MT_X)[2], absinfo(fd, ABS_MT_Y)[2]
    for i in range(n):
        rx = min(799, x + 60 * i) * mx // 799
        ry = y * my // 479
        ev(fd, EV_ABS, ABS_MT_SLOT, i); ev(fd, EV_ABS, ABS_MT_TID, 5000 + i)
        ev(fd, EV_ABS, ABS_MT_X, rx); ev(fd, EV_ABS, ABS_MT_Y, ry)
        if i == 0:
            ev(fd, EV_KEY, BTN_TOUCH, 1); ev(fd, EV_ABS, ABS_X, rx); ev(fd, EV_ABS, ABS_Y, ry)
        syn(fd)
        time.sleep(0.01)
    time.sleep(ms / 1000)
    for i in range(n):
        ev(fd, EV_ABS, ABS_MT_SLOT, i); ev(fd, EV_ABS, ABS_MT_TID, -1)
        if i == n - 1:
            ev(fd, EV_KEY, BTN_TOUCH, 0)
        syn(fd)
    ev(fd, EV_ABS, ABS_MT_SLOT, 0); syn(fd)
elif cmd == "swipe":
    x1, y1, x2, y2 = (int(a) for a in sys.argv[2:6])
    mx, my = absinfo(fd, ABS_MT_X)[2], absinfo(fd, ABS_MT_Y)[2]
    steps = 15
    ev(fd, EV_ABS, ABS_MT_SLOT, 0); ev(fd, EV_ABS, ABS_MT_TID, 4243)
    for i in range(steps + 1):
        x = (x1 + (x2 - x1) * i // steps) * mx // 799
        y = (y1 + (y2 - y1) * i // steps) * my // 479
        ev(fd, EV_ABS, ABS_MT_X, x); ev(fd, EV_ABS, ABS_MT_Y, y)
        if i == 0:
            ev(fd, EV_KEY, BTN_TOUCH, 1)
        ev(fd, EV_ABS, ABS_X, x); ev(fd, EV_ABS, ABS_Y, y); syn(fd)
        time.sleep(0.02)
    ev(fd, EV_ABS, ABS_MT_TID, -1); ev(fd, EV_KEY, BTN_TOUCH, 0); syn(fd)
os.close(fd)
