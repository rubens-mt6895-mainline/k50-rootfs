#!/bin/sh
# Keep this launcher free of synchronous unit operations. The transient
# service path is proven on K50; direct persistent ExecStart is not.
exec /bin/systemd-run --pipe --unit=k50-ble-worker --property=Type=oneshot --collect /usr/local/sbin/k50-bt-le-enable.sh
