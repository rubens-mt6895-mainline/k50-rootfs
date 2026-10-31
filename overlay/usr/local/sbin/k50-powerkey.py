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
所以熄屏只能请 GNOME 代劳。

2026-10-31 修（v5，真机实测）：
  * 会话总线只有 uid 1000 能连，root 直接 gdbus/busctl 会失败（连接被关闭 /
    Transport endpoint is not connected），而旧代码不检查返回码 → SetActive
    一直被静默丢弃，表现是"熄屏正常、唤醒永远不亮"。现在一律 setpriv/runuser
    降权到 k50 再调 busctl，并检查 rc + 打日志。
  * "亮/灭"以 DPMS 实际状态为准，不再用自己的 off 变量记账：GNOME 按
    idle-delay 自己熄的屏本进程并不知道，旧逻辑会"越按越黑"。
  * 唤醒成功后 GNOME 会在 idle 阈值后再熄一次（唤醒不重置它的空闲计时），
    这是 GNOME 自身行为，不是本进程的 bug。

2026-11-01 修（v6）：加 GNOME 空闲熄屏兜底。用户报「屏幕没关，能看到老化的
绿线」——不是面板/内核的问题（本内核 dpms=Off ⟺ lcm_unprepare 已实测成立），
而是 GNOME 有时压根不激活屏保（boot -4 空闲 19 分钟零 unprepare，而 logind
空闲计时确实累到了 900 s）。现在每 5 s 读一次 logind 的 IdleHint，超过
idle-delay + K50_IDLE_GRACE(默认 30 s) 屏幕还亮着，就由本进程走与电源键
相同的熄屏路径（K50_IDLE_FALLBACK=0 可关）。
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
    # 必须带 /usr/sbin:/sbin：runuser 不在 /usr/bin（2026-11-01 实测
    # "gsettings failed: [Errno 2] No such file or directory: 'runuser'"）
    "PATH": "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
}

# 2026-10-31：本进程是 root，但**会话总线只认 uid 1000**——
# root 直接连 /run/user/1000/bus 会失败（实测 `gdbus: Error connecting: The connection
# is closed`、`busctl --user: Transport endpoint is not connected`），
# 于是 SetActive 一直被静默丢弃：熄屏看着"能用"（背光被写成 0），
# 唤醒却永远点不亮（DPMS 仍是 off），表现就是"息屏久了电源键失效、只有蓝牙有效"。
# 所以凡是要跟 org.gnome.* 说话的地方，都必须先降权到 k50。
USER_UID = int(os.environ.get("K50_USER_UID", "1000"))
PRIVDROP = [["setpriv", "--reuid=%d" % USER_UID, "--regid=%d" % USER_UID,
             "--init-groups"],
            ["runuser", "-u", "k50", "--"]]


def run_as_user(cmd, timeout=5):
    """以 k50 身份执行 cmd（优先 setpriv，退化到 runuser）。返回 CompletedProcess 或 None。"""
    last = None
    for wrap in PRIVDROP:
        try:
            last = subprocess.run(wrap + cmd, env=ENV, capture_output=True,
                                  text=True, timeout=timeout)
        except FileNotFoundError:
            continue
        except Exception as e:
            log("%s failed: %s" % (cmd[0], e))
            return None
        if last.returncode == 0:
            return last
    return last


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


def _screensaver_call(method, *args):
    """调用 org.gnome.ScreenSaver 的方法（降权后执行）。成功返回 stdout，失败返回 None。"""
    cmd = ["busctl", "--user", "call",
           "org.gnome.ScreenSaver", "/org/gnome/ScreenSaver",
           "org.gnome.ScreenSaver", method] + list(args)
    r = run_as_user(cmd)
    if r is None:
        return None
    if r.returncode != 0:
        log("%s 失败 rc=%d %s" % (method, r.returncode,
                                  (r.stderr or r.stdout or "").strip()[:160]))
        return None
    return (r.stdout or "").strip()


def screensaver_active():
    out = _screensaver_call("GetActive")
    return bool(out) and "true" in out


def screensaver_set(active):
    out = _screensaver_call("SetActive", "b", "true" if active else "false")
    return out is not None


def dpms_on():
    try:
        with open(DPMS) as f:
            return f.read().strip().lower() == "on"
    except OSError:
        return True


# ---- GNOME 空闲熄屏兜底（v6, 2026-11-01）----------------------------------
# 现象（用户 2026-11-01 00:00 报「屏幕没关，能看到老化的绿线」）：空闲到
# idle-delay 之后 GNOME 有时**完全不激活屏保**。boot -4（23:42:56→00:02:13，
# 19 分钟）里 lcm_unprepare 一次都没有，而同一 boot 的 logind 空闲计时确实
# 累到了 900 s（23:58:38 触发挂起尝试）—— 说明不是"空闲没累积"，而是
# mutter/gsd 的定时器那条链没跑。真机实测：logind 的 IdleHint 可靠，
# 所以本进程自己盯它，超时后走与电源键熄屏完全相同的路径。
IDLE_FALLBACK = os.environ.get("K50_IDLE_FALLBACK", "1") == "1"
IDLE_GRACE = float(os.environ.get("K50_IDLE_GRACE", "30"))
_session_id = None
_delay_cache = [0.0, 300]


def wayland_session_id():
    global _session_id
    if _session_id:
        return _session_id
    try:
        ids = subprocess.run(["loginctl", "list-sessions", "--no-legend"],
                             capture_output=True, text=True, timeout=5).stdout
    except Exception as e:
        log("loginctl list-sessions failed: %s" % e)
        return None
    for line in ids.splitlines():
        sid = line.split()[0]
        try:
            info = subprocess.run(["loginctl", "show-session", sid, "-p", "Type"],
                                  capture_output=True, text=True, timeout=5).stdout
        except Exception:
            continue
        if "Type=wayland" in info:
            _session_id = sid
            return sid
    return None


def idle_seconds():
    """logind 的空闲秒数（IdleHint=yes 时有效）。IdleSinceHintMonotonic 与
    /proc/uptime 同为 CLOCK_MONOTONIC，可直接相减。"""
    sid = wayland_session_id()
    if not sid:
        return None
    try:
        out = subprocess.run(["loginctl", "show-session", sid,
                              "-p", "IdleHint", "-p", "IdleSinceHintMonotonic"],
                             capture_output=True, text=True, timeout=5).stdout
    except Exception as e:
        log("idle query failed: %s" % e)
        return None
    if "IdleHint=yes" not in out:
        return None
    since = 0
    for ln in out.splitlines():
        if ln.startswith("IdleSinceHintMonotonic="):
            since = int(ln.split("=", 1)[1])
    if since <= 0:
        return None
    try:
        with open("/proc/uptime") as f:
            up_us = float(f.read().split()[0]) * 1e6
    except (OSError, ValueError, IndexError):
        return None
    return max(0.0, (up_us - since) / 1e6)


def as_k50(cmd, timeout=5):
    """**必须**用 runuser：它会设 HOME=/home/k50；setpriv 不会，于是 dconf
    会去读 /root/.config/dconf/user（不存在）→ 拿到 GNOME 默认值而看不出来。"""
    try:
        return subprocess.run(["runuser", "-u", "k50", "--"] + cmd, env=ENV,
                              capture_output=True, text=True, timeout=timeout)
    except Exception as e:
        log("%s failed: %s" % (cmd[0], e))
        return None


def idle_delay_seconds():
    """GNOME 的 idle-delay（秒），60 s 缓存一次。"""
    now = time.time()
    if now - _delay_cache[0] < 60:
        return _delay_cache[1]
    r = as_k50(["gsettings", "get", "org.gnome.desktop.session", "idle-delay"])
    if r is not None and r.returncode == 0:
        for tok in (r.stdout or "").split():
            if tok.isdigit():
                _delay_cache[0] = now
                _delay_cache[1] = int(tok)
                return _delay_cache[1]
    return _delay_cache[1]


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
    if not dpms_on():
        bl.off()
    else:
        bl.on()

    press_t = None
    last_toggle = 0.0
    poll_t = 0.0
    idle_poll = 0.0

    def screen_off():
        nonlocal last_toggle
        screensaver_set(True)   # 请 GNOME 熄屏：DPMS off → 面板 unprepare 真断电
        bl.off()                # 立刻全黑，不等合成器淡出
        last_toggle = time.time()
        log("screen -> OFF")

    def screen_on(why):
        nonlocal last_toggle
        screensaver_set(False)
        bl.on()
        last_toggle = time.time()
        log("screen -> ON (%s)" % why)
        bt_reconnect()

    def blank_fallback():
        """GNOME 没按 idle 熄屏时的兜底：屏保若已 active 但屏幕还亮着（GNOME
        卡在那个状态），先取消再重来 —— 否则 SetActive(true) 是空操作，
        屏幕永远不会真的灭。"""
        if screensaver_active():
            log("fallback: screensaver 已 active 但屏幕仍亮，先复位再熄")
            screensaver_set(False)
            time.sleep(0.5)
        screen_off()

    log("watching power key only, long threshold %d ms, dpms=%s, idle fallback=%s(%s+%ds)"
        % (LONG_MS, "on" if dpms_on() else "off",
           "on" if IDLE_FALLBACK else "off",
           "%ds" % idle_delay_seconds(), int(IDLE_GRACE)))

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
            if dpms_on() and bl.level == 0 and now - last_toggle > 3.0:
                bl.on()
                log("watchdog: restore backlight (screen should be on)")

        # GNOME 空闲熄屏兜底：GNOME 有时根本不激活屏保（屏幕一直亮），
        # 空闲超过 idle-delay + grace 还亮着就自己熄（路径与电源键一致）
        if IDLE_FALLBACK and now - idle_poll > 5.0:
            idle_poll = now
            if dpms_on():
                delay = idle_delay_seconds()
                idle = idle_seconds()
                if idle is not None and idle > delay + IDLE_GRACE:
                    log("GNOME 未按 idle 熄屏（空闲 %.0fs > %ds），由本进程兜底"
                        % (idle, delay))
                    blank_fallback()

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
                            # 用 DPMS 实际状态判断，不能用自己的记账变量：
                            # GNOME 自己按 idle-delay 熄的屏本进程并不知道，
                            # 若还按"我以为屏幕是亮的"去熄屏，就会变成
                            # "按一下反而更黑"，正是"息屏一段时间后电源键失效"。
                            lit = dpms_on()
                            log("press held %.0fms -> SHORT (dpms=%s)"
                                % (held, "on" if lit else "off"))
                            if lit:
                                screen_off()
                            else:
                                screen_on("power key")

    return 0


if __name__ == "__main__":
    sys.exit(main())
