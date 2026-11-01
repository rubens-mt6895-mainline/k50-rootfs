#!/bin/sh
# 把根分区扩满 —— 刷完 img 后第一次开机的必备步骤。
#
# 为什么需要：CI 打出来的 ext4 镜像是被 `resize2fs -M` 收缩过的（固定 ~3.9 GB），
# 刷进 userdata 分区（225 GB）之后如果不扩，文件系统仍然是 3.9 GB。实测后果：
# `/` 100% 满 → gdm 的 ExecStartPre 写不了 /var/lib/gdm3/greeter-dconf-defaults
# 反复失败（`No space left on device`）→ 进不了图形界面。
#
# 为什么不用 fstab 的 x-systemd.growfs：那种写法由 systemd-growfs@.service 实现，
# 它只在「/ 本身就是一个可写的块设备文件系统」时能工作；镜像模式下 / 是 overlay，
# 真正的根文件系统挂在 /mnt/.oldroot，于是那个服务会直接跳过。这里自己找设备。
#
# 幂等：已经是分区大小就直接退出。任何一步失败都只打日志、返回 0，
#      绝不能因为扩容失败卡住开机（最多回到"盘是满的"这个旧状态）。
set -u

# 找「真正的根文件系统」所在的块设备。
# 普通模式：/ 自己就是块设备；镜像模式：/ 是 overlay，真身在 /data（同一分区上的 bind
# 挂载，一定在）；再退一步是 /mnt/.oldroot（旧根还没被卸载时才在）。
# 坑：绝不能对 "overlay" 这种非路径值跑 readlink -f —— 会被解析成 /overlay，
# 于是报「/overlay 不是块设备，跳过」，扩容静默失效（实测踩过）。
find_root_dev() {
	for p in / /data /images /mnt/.oldroot; do
		[ -e "$p" ] || continue
		src="$(findmnt -no SOURCE --target "$p" 2>/dev/null || true)"
		src="${src%%\[*}"            # /dev/sda1[/subvol] → /dev/sda1
		case "$src" in
			/dev/*) ;;           # 只有路径形状的才可能是设备
			*) continue ;;       # overlay / tmpfs / none … 跳过
		esac
		src="$(readlink -f "$src" 2>/dev/null || echo "$src")"
		if [ -b "$src" ]; then
			printf '%s' "$src"
			return 0
		fi
	done
	return 1
}

DEV="$(find_root_dev)" || true
[ -n "${DEV:-}" ] || { echo "k50-growfs: 找不到根设备，跳过"; exit 0; }

if [ ! -b "$DEV" ]; then
	echo "k50-growfs: $DEV 不是块设备，跳过"
	exit 0
fi

# 分区表里这块分区的上限 = 内核看到的 size（512 字节扇区）
SYSFS="/sys/class/block/$(basename "$DEV")/size"
if [ ! -r "$SYSFS" ]; then
	echo "k50-growfs: 读不到 $SYSFS，跳过"
	exit 0
fi
LIMIT="$(( $(cat "$SYSFS") * 512 ))"

CUR="$(blockdev --getsize64 "$DEV" 2>/dev/null || echo 0)"
case "$CUR" in ''|*[!0-9]*) CUR=0 ;; esac
[ "$CUR" -gt 0 ] || { echo "k50-growfs: 读不出 $DEV 大小，跳过"; exit 0; }

if [ "$LIMIT" -le "$CUR" ]; then
	echo "k50-growfs: $DEV 已经占满（$((CUR / 1024 / 1024)) MiB），无需扩容"
	exit 0
fi

echo "k50-growfs: 扩容 $DEV $((CUR / 1024 / 1024)) MiB -> $((LIMIT / 1024 / 1024)) MiB"
if resize2fs "$DEV" "$((LIMIT / 512))s" >/dev/null 2>&1 || resize2fs "$DEV" >/dev/null 2>&1; then
	echo "k50-growfs: 完成，$(findmnt -no SOURCE,SIZE /mnt/.oldroot / 2>/dev/null | sed -n '1p')"
else
	echo "k50-growfs: resize2fs 失败（盘可能没问题，只是这次没扩成）"
fi

exit 0
