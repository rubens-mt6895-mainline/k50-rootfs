#!/usr/bin/env python3
"""Keep K50's Bluetooth HID peripherals connected.

Runs from k50-bt-reconnect.timer.  For every bonded device whose name matches
one of TARGET_NAMES it makes sure the link is up: pair (if somehow unpaired),
trust, connect.  Pairing needs k50-bt-agent.service, which supplies the
NoInputNoOutput agent that bluetoothctl cannot provide non-interactively.

Exit codes: 0 = all good, 1 = something failed (journal gets the detail).
"""
import subprocess
import sys
import time
import dbus

ADAPTER = "/org/bluez/hci0"
# Match by name because the Pebble uses a random address that rotates.
TARGET_NAMES = ("Logitech Pebble", "Logi K580", "K580")


def log(msg):
    print(msg, flush=True)


def managed_devices(bus):
    om = dbus.Interface(bus.get_object("org.bluez", "/"),
                        "org.freedesktop.DBus.ObjectManager")
    out = {}
    for path, ifaces in om.GetManagedObjects().items():
        dev = ifaces.get("org.bluez.Device1")
        if dev:
            out[path] = dev
    return out


def matches(dev):
    name = str(dev.get("Name") or dev.get("Alias") or "")
    return any(t.lower() in name.lower() for t in TARGET_NAMES)


def scan(bus, seconds):
    adapter = dbus.Interface(bus.get_object("org.bluez", ADAPTER),
                             "org.bluez.Adapter1")
    try:
        adapter.SetDiscoveryFilter(dbus.Dictionary(
            {"Transport": dbus.String("le"), "DuplicateData": dbus.Boolean(True)},
            signature="sv"))
    except dbus.DBusException as exc:
        log("SetDiscoveryFilter: %s" % exc.get_dbus_name())
    try:
        adapter.StopDiscovery()
    except dbus.DBusException:
        pass
    for attempt in (1, 2):
        try:
            adapter.StartDiscovery()
            log("扫描开始（%ds，第 %d 次）" % (seconds, attempt))
            break
        except dbus.DBusException as exc:
            log("StartDiscovery 失败: %s" % exc.get_dbus_name())
            try:
                adapter.StopDiscovery()
            except dbus.DBusException:
                pass
            time.sleep(2)
    else:
        return False
    time.sleep(seconds)
    try:
        adapter.StopDiscovery()
    except dbus.DBusException:
        pass
    return True


def run(cmd, timeout=30):
    # btmgmt must NOT inherit /dev/null on stdin: BlueZ's shell layer does
    # epoll_ctl(EPOLL_CTL_ADD, 0), which fails with EPERM on /dev/null; the
    # error is ignored and btmgmt blocks forever without sending its command.
    # input="" supplies a pipe and closes it immediately (EOF), matching the
    # working interactive condition.  Verified on K50, 2026-10-27.
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout,
                           input="")
        return (r.stdout or "") + (r.stderr or "")
    except Exception as exc:
        return "ERR %s" % exc


def le_enabled():
    # bluetoothd 忙时 btmgmt 会阻塞；超时不是“LE 已关闭”。
    out = run(["btmgmt", "--index", "0", "info"], timeout=5)
    if out.startswith("ERR"):
        return None
    for line in out.splitlines():
        if "current settings" in line:
            return " le" in line + " "
    return None


def adapter_recover():
    """只重启 bluetoothd，让它按当前 HCI 能力重建适配器。

    注意（2026-10-26 实测）：**不要**用 hciconfig hci0 down/up 复位！btmtk 芯片下拉后
    再 init 会返回 Input/output error (5)，HCI 从此 DOWN、power on 也失败，只能重启系统。
    所以这里一律只重启 bluetoothd。"""
    log("重启 bluetoothd 以重建适配器")
    run(["systemctl", "restart", "bluetooth"], timeout=90)
    time.sleep(4)


def ensure_le():
    state = le_enabled()
    if state is not False:
        log("LE 预检：%s" % ("正常" if state else "读取超时，跳过本轮"))
        return state
    log("检测到 BlueZ LE 未开启，修复一次")
    run(["systemctl", "stop", "bluetooth"], timeout=20)
    run(["btmgmt", "--index", "0", "le", "on"], timeout=8)
    adapter_recover()
    state = le_enabled()
    log("LE 修复后：%s" % state)
    return state


RESTART_GUARD_S = 900

# BlueZ cold-boot 缺陷（5.66 定案、2026-10-28 在 5.82 复现，见
# docs/project_memory.md §7）：冷启动后 LE 设备的 bond 存储（LTK/IRK）完好，
# 但运行时对象不标 Paired/Bonded；手动 restart 一次 bluetoothd 后 Paired 立
# 即恢复。检测依据：Trusted=yes 且 Paired=no 的目标设备存在、且最近一轮运行
# 中没有人重启过 bluetoothd（用 /run/k50-bt-lastrestart 闸门判定）。
def restart_bluetoothd(reason):
    import os
    stamp = "/run/k50-bt-lastrestart"
    now = time.time()
    try:
        last = os.path.getmtime(stamp)
    except OSError:
        last = 0.0
    if now - last < RESTART_GUARD_S:
        log("仍在闸门内（%.0fs 前刚重启过 bluetoothd），本轮不再重启（%s）"
            % (now - last, reason))
        return False
    open(stamp, "w").close()
    log("重启 bluetoothd（%s）" % reason)
    run(["systemctl", "restart", "bluetooth"], timeout=90)
    time.sleep(5)
    return True


def main():
    # LE 先查先修：LE 没开时 bluez 连配对状态都读不出来（Paired 会显示 no），
    # 所以不能等"发现有设备连不上"再修，必须一进来就查。
    if ensure_le() is None:
        log("蓝牙状态查询超时，本轮不做连接，避免互相干扰")
        return 0
    bus = dbus.SystemBus()
    devs = managed_devices(bus)

    # 冷启动 bond 不标记：Trusted 的目标设备 Paired=no → 先重启 bluetoothd
    # 恢复 bond 标记（设备侧已实测：重启后立即 Paired=yes），本轮再等 timer。
    unmarked = [d for d in devs.values()
                if matches(d) and d.get("Trusted") and not d.get("Paired")]
    if unmarked:
        restart_bluetoothd("冷启动 bond 未标记：%s" % ", ".join(
            str(d.get("Name") or "?") for d in unmarked))
        return 0

    bonded = {p: d for p, d in devs.items() if d.get("Paired")}
    need = {p: d for p, d in bonded.items()
            if matches(d) and not d.get("Connected")}
    if not need:
        log("全部已连接，无需动作（已配对 %d 个）" % len(bonded))
        return 0

    log("待处理: %s" % ", ".join(str(d.get("Name")) for d in need.values()))
    if not scan(bus, 15):
        log("扫描失败（InProgress 卡死），复位适配器后再试一次")
        adapter_recover()
        if not scan(bus, 12):
            log("复位后仍然扫不动，放弃本轮")
            return 0


    failed = 0
    for rnd in (1, 2, 3):
        pending = [(p, d) for p, d in managed_devices(bus).items()
                   if matches(d) and not d.get("Connected")]
        if not pending:
            break
        for path, info in pending:
            name = str(info.get("Name") or info.get("Alias") or "?")
            dev_iface = dbus.Interface(bus.get_object("org.bluez", path),
                                       "org.bluez.Device1")
            props = dbus.Interface(bus.get_object("org.bluez", path),
                                   "org.freedesktop.DBus.Properties")
            try:
                if not info.get("Paired"):
                    dev_iface.Pair(timeout=45)
                    log("%s 配对成功" % name)
                props.Set("org.bluez.Device1", "Trusted", dbus.Boolean(True))
                dev_iface.Connect(timeout=45)
                log("%s 已连接（第 %d 轮）" % (name, rnd))
            except dbus.DBusException as exc:
                failed += 1
                log("%s 连接失败（第 %d 轮）: %s" % (name, rnd, exc.get_dbus_name()))
        if rnd < 3:
            scan(bus, 10)
    # 兜底：三轮都失败且确实还有未连上的目标 → 重启一次 bluetoothd 再试。
    # 前提：当前没有任何目标设备处于 Connected（重启会断开正在使用的键鼠）。
    # 带闸门：RESTART_GUARD_S 内只允许一次，避免 timer 每分钟重启把芯片搞崩。
    still = [(pth, d) for pth, d in managed_devices(bus).items()
             if matches(d) and not d.get("Connected")]
    connected_now = any(matches(d) and d.get("Connected")
                        for d in managed_devices(bus).values())
    if failed and still and not connected_now:
        if not restart_bluetoothd("仍有 %d 个没连上，兜底重试" % len(still)):
            return 0
        bus = dbus.SystemBus()
        scan(bus, 12)
        for path, info in managed_devices(bus).items():
            if not (matches(info) and not info.get("Connected")):
                continue
            name = str(info.get("Name") or info.get("Alias") or "?")
            try:
                dbus.Interface(bus.get_object("org.bluez", path),
                               "org.bluez.Device1").Connect(timeout=45)
                log("%s 兜底重试连接成功" % name)
            except dbus.DBusException as exc:
                log("%s 兜底重试仍失败: %s" % (name, exc.get_dbus_name()))

    # 单个设备连不上是常态（它在省电/被别的主机占用），不要让 timer 单元变成 failed
    return 0


if __name__ == "__main__":
    sys.exit(main())
