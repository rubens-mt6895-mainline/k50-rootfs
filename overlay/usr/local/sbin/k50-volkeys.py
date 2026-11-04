#!/usr/bin/python3
"""K50 音量键：把音量键接给 PipeWire。

真机事实（2026-11-01 在 CI 镜像上实测）：

  /proc/bus/input/devices 里音量键被拆在两颗"键盘"设备上：
    mtk-spmi-keys (kbd event2)  能力位含 KEY_VOLUMEUP(115) 与 KEY_POWER(116)
    mtk-kpd       (kbd event0)  能力位含 KEY_VOLUMEDOWN(114)

  而 GNOME 的两个音量键绑定是空的：
    org.gnome.settings-daemon.plugins.media-keys volume-up   = ['']
    org.gnome.settings-daemon.plugins.media-keys volume-down = ['']
  所以按键能上报、内核一直在打 TOPSTATUS，但没有东西处理它
  —— 表现就是"按音量上没反应"。

本程序只做一件事：监听所有输入设备，遇到音量上/下各调 2%（可被 K50_VOLUME_STEP 覆盖，并且 120ms 内只认一次），通过 wpctl 调
桌面用户的 PipeWire。不 grab（不抢 GNOME 的输入），失败只记日志，不阻塞开机。
"""
import glob
import os
import select
import struct
import subprocess
import sys
import time

KEY_VOLUMEDOWN = 114
KEY_VOLUMEUP = 115
STEP = os.environ.get("K50_VOLUME_STEP", "2%")
LAST = [0.0]      # 上次调音量的时刻，用来限速
UID = int(os.environ.get("K50_UID", "1000"))
RUNTIME = os.environ.get("K50_RUNTIME_DIR", "/run/user/1000")
PATH = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
EVENT = struct.Struct("qqHHi")
EV_KEY = 1
KEY_PRESS = 1


def log(msg):
    sys.stderr.write("%s k50-volkeys: %s\n" % (time.strftime("%Y-%m-%dT%H:%M:%S"), msg))
    sys.stderr.flush()


def device_name(path):
    try:
        with open("/sys/class/input/%s/device/name" % os.path.basename(path)) as f:
            return f.read().strip()
    except OSError:
        return "?"


def open_all():
    """打开所有输入设备（读失败就跳过）。返回 {fd: (路径, 名字)}。"""
    opened = {}
    for path in sorted(glob.glob("/dev/input/event*")):
        try:
            fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK)
        except OSError:
            continue
        opened[fd] = (path, device_name(path))
    if opened:
        log("监听 %d 个输入设备：%s" % (len(opened), ", ".join(
            "%s(%s)" % (v[1], os.path.basename(v[0])) for v in opened.values())))
    return opened


def set_volume(delta):
    """以桌面用户身份调一级音量。"""
    cmd = ["runuser", "-u", "#%d" % UID, "--",
           "wpctl", "set-volume", "@DEFAULT_AUDIO_SINK@", delta]
    env = dict(os.environ)
    env["XDG_RUNTIME_DIR"] = RUNTIME
    env["PATH"] = PATH
    try:
        rc = subprocess.call(cmd, env=env, stdout=subprocess.DEVNULL,
                             stderr=subprocess.DEVNULL, timeout=5)
    except Exception as exc:  # noqa: BLE001
        log("调音量失败（%s）：%s" % (delta, exc))
        return
    log("音量 %s（rc=%d）" % (delta, rc))


def main():
    log("启动：音量步长 %s，以 uid %d 调 wpctl" % (STEP, UID))
    devices = open_all()
    idle = 0
    while True:
        if not devices:
            time.sleep(5)
            devices = open_all()
            continue
        try:
            ready, _, _ = select.select(list(devices), [], [], 30.0)
        except OSError:
            for fd in devices:
                try:
                    os.close(fd)
                except OSError:
                    pass
            devices = {}
            continue
        if not ready:
            # 每 30 秒检查一次设备集合有没有变（拔插/重新枚举）
            idle += 1
            if idle % 4 == 0:
                current = set(glob.glob("/dev/input/event*"))
                known = set(v[0] for v in devices.values())
                if current != known:
                    for fd in devices:
                        try:
                            os.close(fd)
                        except OSError:
                            pass
                    devices = open_all()
            continue
        for fd in ready:
            try:
                data = os.read(fd, EVENT.size * 32)
            except OSError:
                try:
                    os.close(fd)
                except OSError:
                    pass
                devices.pop(fd, None)
                continue
            for off in range(0, len(data) - EVENT.size + 1, EVENT.size):
                _sec, _usec, typ, code, val = EVENT.unpack(data[off:off + EVENT.size])
                # 只处理按下；value=2 是长按重复，跳过（否则按住会飞音量）
                if typ != EV_KEY or val != KEY_PRESS:
                    continue
                now = time.time()
                if now - LAST[0] < 0.12:
                    continue          # 同一批事件里只认一次，避免一次按键吃好几次
                LAST[0] = now
                if code == KEY_VOLUMEUP:
                    set_volume(STEP + "+")
                elif code == KEY_VOLUMEDOWN:
                    set_volume(STEP + "-")


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        pass
