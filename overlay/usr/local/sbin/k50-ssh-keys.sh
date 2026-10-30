#!/bin/sh
# ==============================================================================
#  K50：每次启动把 SSH 密钥理顺（镜像模式下换系统后不丢 SSH）
#
#  为什么需要它：
#    * 构建出来的镜像里**没有** /etc/ssh/ssh_host_*（构建脚本故意删掉，避免把
#      构建机的身份打进镜像），而 sshd 缺主机密钥会直接退出 ——
#      journal 里是 "sshd: no hostkeys available -- exiting"，表现就是
#      SSH 端口能连上但立刻断开、读不到 banner。
#    * /home/<user>/.ssh/authorized_keys 属于私有数据，同样不会进镜像。
#
#  做法（幂等，反复跑没关系）：
#    1. 用 /data/persist/etc-ssh 里存下的主机私钥恢复 /etc/ssh/ssh_host_*
#    2. 还缺就 ssh-keygen -A 生成，并持久化回 /data/persist/etc-ssh
#    3. /data/persist/authorized_keys 存在就装回用户家目录（600，属主为用户）
# ==============================================================================

set -u

PERSIST=/data/persist
KEYDIR="$PERSIST/etc-ssh"

log() { printf 'k50-ssh-keys: %s\n' "$*"; }

# /data 只在镜像模式里被 pivot bind 进新根；普通启动（引导层）时它不存在。
# 判断方式用「目录是否存在」而不是 mountpoint：mountpoint 依赖 /proc/self/mountinfo，
# 在 chroot/早期启动阶段可能还没挂 /proc，会把镜像模式误判成普通启动（本地实测踩过）。
IS_IMAGE=0
if [ -d /data ] || mountpoint -q /data 2>/dev/null; then IS_IMAGE=1; fi

# 目标用户：优先 uid 1000，其次 root
USER_NAME="$(getent passwd 1000 2>/dev/null | cut -d: -f1 || true)"
[ -n "${USER_NAME:-}" ] || USER_NAME=root
USER_HOME="$(getent passwd "$USER_NAME" 2>/dev/null | cut -d: -f6 || true)"
[ -n "${USER_HOME:-}" ] || USER_HOME=/root

mkdir -p /etc/ssh 2>/dev/null || true
# 注意：/data 只在镜像模式里被 pivot bind 进新根。普通启动（引导层）时它不存在，
# 这时**不能**去 mkdir —— 否则会在根文件系统上凭空造出一个 /data/persist，
# 密钥被写进那层"假存档"（下次进镜像模式时真 /data 覆盖上来，看起来像丢了）。
# 实测过：无脑 mkdir -p /data/persist/etc-ssh 会在非镜像启动的 rootfs 里造出 /data。
if [ "$IS_IMAGE" = 1 ] || [ -d "$PERSIST" ]; then
	mkdir -p "$KEYDIR" 2>/dev/null || true
fi

# 1) 恢复持久化的主机私钥
if [ -d "$KEYDIR" ]; then
	for k in "$KEYDIR"/ssh_host_*; do
		[ -e "$k" ] || continue
		case "$k" in *.pub) continue ;; esac
		if cp -f "$k" "/etc/ssh/$(basename "$k")" 2>/dev/null; then
			chmod 600 "/etc/ssh/$(basename "$k")" 2>/dev/null || true
			log "恢复主机密钥 $(basename "$k")"
		fi
	done
fi

# 2) 还缺就生成
if [ ! -e /etc/ssh/ssh_host_ed25519_key ]; then
	if command -v ssh-keygen >/dev/null 2>&1; then
		ssh-keygen -A && log "已生成主机密钥"
	else
		log "警告：没有 ssh-keygen，sshd 会因缺主机密钥起不来"
	fi
fi

# 3) 把当前主机私钥持久化（只在还没有的时候写，避免覆盖已存的那份）
if [ "$IS_IMAGE" = 1 ]; then
	for k in /etc/ssh/ssh_host_*; do
		[ -e "$k" ] || continue
		case "$k" in *.pub) continue ;; esac
		if [ ! -e "$KEYDIR/$(basename "$k")" ]; then
			cp -f "$k" "$KEYDIR/" 2>/dev/null || true
		fi
	done
fi

# 4) authorized_keys 恢复 / 备份
if [ -f "$PERSIST/authorized_keys" ]; then
	mkdir -p "$USER_HOME/.ssh" 2>/dev/null || true
	if install -m 600 -o "$USER_NAME" -g "$USER_NAME" \
		"$PERSIST/authorized_keys" "$USER_HOME/.ssh/authorized_keys" 2>/dev/null ||
		cp -f "$PERSIST/authorized_keys" "$USER_HOME/.ssh/authorized_keys" 2>/dev/null; then
		log "已为 $USER_NAME 恢复 authorized_keys"
	fi
elif [ "$IS_IMAGE" = 1 ] && [ -f "$USER_HOME/.ssh/authorized_keys" ]; then
	mkdir -p "$PERSIST" 2>/dev/null || true
	cp -f "$USER_HOME/.ssh/authorized_keys" "$PERSIST/authorized_keys" 2>/dev/null &&
		log "已备份 $USER_NAME 的 authorized_keys"
fi

log "完成（用户 $USER_NAME，持久化目录 $KEYDIR）"
exit 0
