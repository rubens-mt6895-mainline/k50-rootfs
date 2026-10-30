#!/usr/bin/env python3
"""K50 屏幕背光 LED 使能脚（pio 215 / LEDEN）用户态开关。
用法: k50-led.py on|off|get    （on = 背光亮，off = 背光灭）"""
import ctypes, os, struct, sys

CHIP = "/dev/gpiochip0"
LINE = 215

GET_LINE   = 0xC250B407   # _IOWR(0xB4, 0x07, struct gpio_v2_line_request) 588+4
SET_VALUES = 0xC010B40F
GET_VALUES = 0xC010B40E
FLAG_OUTPUT = 8   # GPIO_V2_LINE_FLAG_OUTPUT = _BITULL(3)
FLAG_INPUT  = 4   # GPIO_V2_LINE_FLAG_INPUT  = _BITULL(2)

_libc = ctypes.CDLL("libc.so.6", use_errno=True)
_libc.ioctl.restype = ctypes.c_int
_libc.ioctl.argtypes = [ctypes.c_int, ctypes.c_ulong, ctypes.c_void_p]


def _ioctl(fd, cmd, buf):
    ret = _libc.ioctl(fd, cmd, ctypes.byref(buf))
    if ret < 0:
        e = ctypes.get_errno()
        raise OSError(e, os.strerror(e))
    return ret


def _request(output=True):
    offsets = [0] * 64
    offsets[0] = LINE
    consumer = b"k50-leden".ljust(32, b"\0")
    flags = FLAG_OUTPUT if output else FLAG_INPUT
    config = struct.pack("<QI5I", flags, 0, 0, 0, 0, 0, 0) + b"\0" * 240
    req = struct.pack("<64I", *offsets) + consumer + config + struct.pack("<II5I", 1, 0, 0, 0, 0, 0, 0) + b"\0" * 4
    assert len(req) == 592, len(req)
    buf = ctypes.create_string_buffer(req, 592)
    fd = os.open(CHIP, os.O_RDWR)
    try:
        _ioctl(fd, GET_LINE, buf)
    finally:
        os.close(fd)
    lfd = struct.unpack("<i", buf.raw[588:592])[0]
    if lfd < 0:
        raise OSError(-lfd, os.strerror(-lfd))
    return lfd


def set_value(value):
    lfd = _request(output=True)
    try:
        v = ctypes.create_string_buffer(struct.pack("<QQ", 1 if value else 0, 1), 16)
        _ioctl(lfd, SET_VALUES, v)
    finally:
        os.close(lfd)


def get_value():
    lfd = _request(output=False)
    try:
        v = ctypes.create_string_buffer(struct.pack("<QQ", 0, 1), 16)
        _ioctl(lfd, GET_VALUES, v)
        bits, mask = struct.unpack("<QQ", v.raw)
        return (bits & 1) == 1
    finally:
        os.close(lfd)


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else ""
    try:
        if cmd == "on":
            set_value(True); print("LEDEN -> on")
        elif cmd == "off":
            set_value(False); print("LEDEN -> off")
        elif cmd == "get":
            print("LEDEN =", "on" if get_value() else "off")
        else:
            print("用法: k50-led.py on|off|get"); sys.exit(2)
    except Exception as e:
        print("失败:", type(e).__name__, e); sys.exit(1)
