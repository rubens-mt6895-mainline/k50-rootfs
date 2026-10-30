#!/bin/bash
# K50: re-enable BlueZ Low Energy after the btmtk controller comes up.
# No bluetoothd restart, no HCI connection teardown.
#
# ── Root cause of the historical "btmgmt 卡死" (measured 2026-10-27, strace) ──
# btmgmt unconditionally registers stdin in its epoll set through
# bt_shell_attach().  /dev/null (systemd's default StandardInput=null, and the
# previous `exec </dev/null` here) is NOT epollable - its fops has no ->poll, so
# the kernel returns EPERM.  bt_shell_attach() then returns early, BEFORE
# executing the requested command; tools/btmgmt.c ignores that return value and
# enters epoll_pwait(-1).  The mgmt request is therefore NEVER written to the
# HCI control socket (strace: no writev(4, "\r\0\0\0\1\0\1") at all), producing
# a true block with ~0 CPU.  The relevant io/mainloop layers do handle EPERM;
# the lost error is specifically bt_shell_attach()'s return value.
# A pipe *is* pollable, so `exec 0< <(:)` makes stdin valid for btmgmt.  EOF is
# not required; a still-open pipe works too (systemd-run --pipe).  Do NOT put
# stdin back to /dev/null.
set -u
exec 0< <(:) >/var/log/k50-bt-le-enable.log 2>&1

# bluetoothd may still be powering the controller up; SET_LE is only accepted
# on a powered adapter. Wait (bounded) instead of racing it.
for _ in $(seq 1 30); do
    btmgmt --index 0 info 2>/dev/null | grep -q 'current settings:.*powered' && break
    sleep 1
done

for i in 1 2 3 4 5; do
    if btmgmt --index 0 info 2>/dev/null | grep 'current settings' | grep -q ' le '; then
        logger -t k50-bt-le-enable "LE already enabled (attempt $i)"
        exit 0
    fi
    echo "attempt $i:"
    btmgmt --index 0 le on
    sleep 2
done

if btmgmt --index 0 info 2>/dev/null | grep 'current settings' | grep -q ' le '; then
    logger -t k50-bt-le-enable 'LE enabled'
    exit 0
fi
logger -t k50-bt-le-enable 'LE enable failed'
exit 1
