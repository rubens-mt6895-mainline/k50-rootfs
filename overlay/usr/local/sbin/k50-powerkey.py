#!/usr/bin/env python3
"""k50-powerkey — 电源键短按开关屏幕 / 长按弹 GNOME 退出对话框

熄屏（2026-10-30 第二轮定稿）：
  1) 发 org.gnome.ScreenSaver.SetActive(true)，请 GNOME 自己走 DPMS off →
     面板 unprepare 真正断电（内核已修好 lcm_unprepare，不再跳过）；
  2) 同时立刻写 mtkfb "backlight:0" 全黑 —— 因为 DPMS 要等合成器淡出 1~5 s，
     这段时间里任何输入都会取消这次熄屏，不给"立刻黑"就会出现"按键没反应"。

唤醒**不再**由本进程代劳：键盘/鼠标/触摸的输入 GNOME 自己会把面板点亮
（lcm_prepare → lcm_panel_init 重发全表 → 恢复亮度）。本进程代劳的旧做法会在
熄屏后 1~2 s 被蓝牙鼠标的连接/上报事件弹回来，表现为电源键按了没反应，故删除。
本进程只处理电源键：event2 被 EVIOCGRAB 独占，GNOME 收不到，只能由这里转发。

DPMS 的 sysfs（/sys/class/drm/card0-DSI-1/dpms）仍是 0444，userspace 写不了，
所以熄屏只能请 GNOME 代劳。"屏幕是开还是关"由本进程自己记账（off 变量）。
"""
import fcntl
import os
import select
import struct
import subprocess
import sys
import time

EV_KEY = 1
KEY_POWER = 116
LONG_MS = int(os.environ.get("K50_LONG_MS", "2000"))
DEV = "/dev/input/event2"
DPMS = "/sys/class/drm/card0-DSI-1/dpms"
MTKFB = "/sys/kernel/debug/mtkfb"
BL_MAX = int(os.environ.get("K50_BL_MAX", "2047"))
# 2026-10-30 起内核侧有标准背光设备（k50_bl.ko 外部模块注册）：
# GNOME 用这个 sysfs 控制亮度，所以"点亮屏幕"必须回到 GNOME 设定的值，
# 不能硬写 2047，否则每次唤醒都把用户调的亮度顶到最亮。
SYSFS_BL = "/sys/class/backlight/l11a/brightness"

ENV = {
    "XDG_RUNTIME_DIR": "/run/user/1000",
    "DBUS_SESSION_BUS_ADDRESS": "unix:path=/run/user/1000/bus",
    "DISPLAY": ":0",
    "PATH": "/usr/bin:/bin:/usr/local/bin",
}


def log(msg):
    print("[k50-powerkey] " + msg, flush=True)


class PanelBL:
    def __init__(self):
        self.level = None

    def set(self, level):
        if self.level == level:
            return True
        try:
            with open(MTKFB, "w") as f:
                f.write("backlight:%d\n" % level)
        except OSError as e:
            log("mtkfb write backlight:%d failed: %s" % (level, e))
            return False
        self.level = level
        log("panel backlight -> %d" % level)
        return True

    def off(self):
        return self.set(0)

    def gnome_level(self):
        """GNOME 当前设定的亮度（sysfs 背光设备不存在时退回 BL_MAX）。"""
        try:
            with open(SYSFS_BL) as f:
                v = int(f.read().strip())
            if 0 < v <= BL_MAX:
                return v
        except (OSError, ValueError):
            pass
        return BL_MAX

    def on(self):
        return self.set(self.gnome_level())


def screensaver_active():
    try:
        out = subprocess.run(
            ["gdbus", "call", "--session",
             "--dest", "org.gnome.ScreenSaver",
             "--object-path", "/org/gnome/ScreenSaver",
             "--method", "org.gnome.ScreenSaver.GetActive"],
            env=ENV, capture_output=True, text=True, timeout=5).stdout
        return "(true,)" in out
    except Exception as e:
        log("screensaver query failed: %s" % e)
        return False


def screensaver_set(active):
    try:
        subprocess.run(
            ["gdbus", "call", "--session",
             "--dest", "org.gnome.ScreenSaver",
             "--object-path", "/org/gnome/ScreenSaver",
             "--method", "org.gnome.ScreenSaver.SetActive",
             "true" if active else "false"],
            env=ENV, capture_output=True, text=True, timeout=5)
        return True
    except Exception as e:
        log("SetActive failed: %s" % e)
        return False


def dpms_on():
    try:
        with open(DPMS) as f:
            return f.read().strip().lower() == "on"
    except OSError:
        return True


def show_power_dialog():
    # 必须以 k50 身份在其 session bus 上调用；root 直接跑 gnome-session-quit
    # 会在 session bus 上拿不到会话（现象：日志有记录但屏幕无对话框）。
    cmd = ("XDG_RUNTIME_DIR=/run/user/1000 "
           "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus "
           "DISPLAY=:0 gnome-session-quit --power-off")
    try:
        r = subprocess.run(["su", "-", "k50", "-c", cmd],
                           stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                           text=True, timeout=10)
        log("power dialog requested rc=%d %s" % (r.returncode, (r.stdout or "").strip()[:200]))
    except Exception as e:
        log("power dialog failed: %s" % e)


def bt_reconnect():
    try:
        subprocess.Popen(["systemctl", "start", "--no-block",
                          "k50-bt-reconnect.service"],
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except Exception as e:
        log("bt-reconnect trigger failed: %s" % e)


def main():
    try:
        fd = open(DEV, "rb", buffering=0)
    except OSError as e:
        log("cannot open %s: %s" % (DEV, e))
        return 1

    if os.environ.get("K50_POWERKEY_GRAB") == "1":
        try:
            fcntl.ioctl(fd, 0x40044590, 1)
            log("grabbed " + DEV)
        except OSError as e:
            log("EVIOCGRAB failed (continuing): %s" % e)
    else:
        log("no grab (GNOME keeps input)")

    bl = PanelBL()
    off = not dpms_on()
    if off:
        bl.off()
    else:
        bl.on()

    press_t = None
    last_toggle = 0.0
    poll_t = 0.0

    def screen_off():
        nonlocal off, last_toggle
        screensaver_set(True)   # 请 GNOME 熄屏：DPMS off → 面板 unprepare 真断电
        bl.off()                # 立刻全黑，不等合成器淡出
        off = True
        last_toggle = time.time()
        log("screen -> OFF")

    def screen_on(why):
        nonlocal off, last_toggle
        screensaver_set(False)
        bl.on()
        off = False
        last_toggle = time.time()
        log("screen -> ON (%s)" % why)
        bt_reconnect()

    log("watching power key only, long threshold %d ms, off=%s" % (LONG_MS, off))

    while True:
        r, _, _ = select.select([fd], [], [], 0.2)
        now = time.time()

        # 长按判定
        if press_t is not None and press_t is not False:
            if (now - press_t) * 1000 >= LONG_MS:
                press_t = False
                show_power_dialog()

        # 看门狗：屏幕本该亮着却还是 0 亮度（面板重初始化等）→ 补回来
        if now - poll_t > 0.5:
            poll_t = now
            if (not off) and bl.level == 0 and now - last_toggle > 3.0:
                bl.on()
                log("watchdog: restore backlight (screen should be on)")

        for f in r:
            data = f.read(24 * 64)
            if not data:
                continue
            i = 0
            while i + 24 <= len(data):
                _, _, ev, code, val = struct.unpack_from("llHHi", data, i)
                i += 24
                if ev != EV_KEY or code != KEY_POWER:
                    continue
                if val == 1:
                    press_t = time.time()
                    log("key down")
                elif val == 0:
                    if press_t is False:
                        press_t = None
                    elif press_t is not None:
                        held = (time.time() - press_t) * 1000
                        press_t = None
                        if held < LONG_MS:
                            log("press held %.0fms -> SHORT" % held)
                            if off:
                                screen_on("power key")
                            else:
                                screen_off()

    return 0


if __name__ == "__main__":
    sys.exit(main())
