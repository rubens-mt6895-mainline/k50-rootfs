#!/bin/bash
# ==============================================================================
#  enable-image-mode.sh —— 一次性把设备设成「镜像模式」
#
#  做什么：
#    1. 检查 squashfs-tools / pivot_root 是否可用
#    2. 建 /images、/data/{upper,work}
#    3. 用 mksquashfs 把**当前正在跑的系统**打成第一个系统镜像
#    4. 写 /data/fstab.image（镜像模式下用的 fstab，去掉根分区那行）
#    5. 装 pivot 与 k50-image，用 dpkg-divert 把 /sbin/init 换成 pivot
#    6. 自检：把新镜像 + 临时 overlay 挂到 /var/lib/k50/new 里验证关键路径，然后卸掉
#    7. 打上开关 /images/enabled，提示重启
#
#  参数：
#    --dry-run   只做 1~6 和自检，不打开关（重启后还是老样子）
#    --revert    撤销：去掉开关 + 把 /sbin/init 还给 systemd（镜像和 /data 都留着）
#    --yes       不交互确认
#
#  安全兜底：
#    * 任何一步失败都不会打开关，系统仍是普通启动；
#    * 打开关后如果 pivot 失败，pivot 自己会 exec 真正的 systemd（见 image-mode/pivot）；
#    * 想彻底撤：enable-image-mode.sh --revert（也可以 k50-image disable）
# ==============================================================================
set -euo pipefail

IMAGES=/images
DATA=/data
MARKER="$IMAGES/enabled"
CURRENT="$IMAGES/system-current"
UPPER="$DATA/upper"
WORK="$DATA/work"
SCRATCH=/var/lib/k50/new
PIVOT_DST=/usr/local/lib/k50/pivot
CLI_DST=/usr/local/sbin/k50-image
REAL_INIT=/usr/sbin/init
DIVERTED=/usr/sbin/init.systemd

DRY_RUN=0
ASSUME_YES=0
REVERT=0

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

die() { printf '\033[31m错误：\033[0m%s\n' "$*" >&2; exit 1; }
info() { printf '\033[36m==>\033[0m %s\n' "$*"; }
ok() { printf '\033[32m  ✓\033[0m %s\n' "$*"; }
warn() { printf '\033[33m  ! \033[0m %s\n' "$*"; }
step() { printf '\n\033[1m[%s]\033[0m %s\n' "$1" "$2"; }

while [ $# -gt 0 ]; do
	case "$1" in
		--dry-run) DRY_RUN=1 ;;
		--yes | -y) ASSUME_YES=1 ;;
		--revert) REVERT=1 ;;
		-h | --help)
			sed -n '2,30p' "$0"
			exit 0
			;;
		*) die "未知参数：$1" ;;
	esac
	shift
done

[ "$(id -u)" = 0 ] || die "需要 root"

in_image_mode() { grep -q ' / overlay ' /proc/mounts; }

# ---------------------------------------------------------------- revert
if [ "$REVERT" = 1 ]; then
	step 1 "去掉开关"
	rm -f "$MARKER"
	ok "已删除 $MARKER（下次重启走普通启动）"

	step 2 "把 /sbin/init 还给 systemd"
	if [ -f "$DIVERTED" ] || [ -L "$DIVERTED" ]; then
		rm -f "$REAL_INIT"
		dpkg-divert --remove --rename "$REAL_INIT"
		ok "$REAL_INIT 已还原（dpkg-divert 撤掉）"
	elif dpkg-divert --list "$REAL_INIT" 2>/dev/null | grep -q .; then
		rm -f "$REAL_INIT"
		dpkg-divert --remove --rename "$REAL_INIT"
		ok "$REAL_INIT 已还原"
	else
		warn "没看到 divert 记录，也没看到 $DIVERTED —— 可能本来就是普通启动"
	fi

	step 3 "保留的东西"
	echo "  /images 里的镜像、/data 里的可写层都没有删。"
	echo "  想重新启用： sudo $0 --yes"
	exit 0
fi

# ---------------------------------------------------------------- 前置检查
step 1 "检查环境"
[ -d /proc ] && [ -d /sys ] || die "/proc /sys 不正常（不是正常启动的系统？）"
in_image_mode && die "当前已经在镜像模式里跑了 —— 这个脚本要在引导层（ext4 根分区）上执行。
  先 sudo k50-image disable && sudo reboot 回到引导层。"

for c in mksquashfs pivot_root losetup mount; do
	command -v "$c" >/dev/null 2>&1 || die "缺少命令：$c（apt install squashfs-tools util-linux）"
done
ok "mksquashfs / pivot_root 都在"

[ -x /usr/lib/systemd/systemd ] || die "找不到 /usr/lib/systemd/systemd"
ok "systemd 在"

if [ -n "$(sed -n 's|^overlay .*|x|p' /proc/mounts)" ]; then
	warn "/proc/mounts 里已经有 overlay —— 请确认不是嵌套镜像模式"
fi

ROOT_SRC="$(findmnt -no SOURCE / 2>/dev/null || echo '?')"
ROOT_FSTYPE="$(findmnt -no FSTYPE / 2>/dev/null || echo '?')"
echo "  当前根：$ROOT_SRC（$ROOT_FSTYPE）"
[ "$ROOT_FSTYPE" = ext4 ] || warn "根分区不是 ext4（$ROOT_FSTYPE），引导层最好保持 ext4"
df -h / "$IMAGES" 2>/dev/null | sed 's/^/  /' || true

# ---------------------------------------------------------------- 目录
step 2 "建目录 /images 与 $DATA/{upper,work}"
mkdir -p "$IMAGES" "$UPPER" "$WORK"
ok "$IMAGES、$UPPER、$WORK"

if [ ! -d "$DATA" ]; then
	die "$DATA 建不出来"
fi
if ! findmnt -no TARGET "$DATA" >/dev/null 2>&1; then
	ok "$DATA 在 ext4 根分区上（换镜像不动它，够用）"
fi

DATA_AVAIL="$(df -B1 --output=avail "$DATA" | tail -1)"
DATA_AVAIL_H="$(numfmt --to=iec-i --suffix=B "$DATA_AVAIL")"
echo "  /data 可用：$DATA_AVAIL_H"
if [ "$DATA_AVAIL" -lt $((8 * 1024 * 1024 * 1024)) ]; then
	warn "/data 可用不足 8 GiB，可写层可能不够用（建议先清理）"
fi

# ---------------------------------------------------------------- 厂商固件
step "2b" "把厂商固件复制到 $DATA/firmware"
# 镜像模式下根是 squashfs：引导层上手动放的固件（soc7_0_ram_*.bin、WIFI_RAM_CODE_*…）看不见。
# 这里把「不属于任何 Debian 包」的固件搬到 /data（跟着数据一起留着），
# 开机时由 pivot 把它叠在系统层之上 —— 这样换系统镜像不会把 WiFi/蓝牙/触摸固件弄丢。
FW_SRC=/usr/lib/firmware
FW_DST="$DATA/firmware"
mkdir -p "$FW_DST" "$DATA/fw-up" "$DATA/fw-wk"
if [ -d "$FW_SRC" ]; then
	FW_N=0
	while IFS= read -r f; do
		rel="${f#"$FW_SRC"/}"
		if dpkg -S "$f" >/dev/null 2>&1; then
			continue
		fi
		mkdir -p "$FW_DST/$(dirname "$rel")"
		if cp -a "$f" "$FW_DST/$rel" 2>/dev/null; then
			FW_N=$((FW_N + 1))
		else
			warn "拷不动 $rel"
		fi
	done < <(find "$FW_SRC" -type f 2>/dev/null)
	ok "复制 $FW_N 个厂商固件文件 → $FW_DST（共 $(du -sh "$FW_DST" 2>/dev/null | awk '{print $1}')）"
	if [ "$FW_N" = 0 ]; then
		warn "没发现非 Debian 包的固件；若 WiFi/蓝牙/触摸需要固件，请手动放到 $FW_DST 对应路径"
	fi
else
	warn "$FW_SRC 不存在，跳过"
fi

# ---------------------------------------------------------------- SSH 密钥
step "2c" "把 SSH 主机密钥与 authorized_keys 存到 $DATA/persist（换镜像不丢 SSH）"
# 新镜像里没有 /etc/ssh/ssh_host_*（构建时故意删掉，免得把构建机的身份打进镜像），
# 而 sshd 缺主机密钥会直接退出（journal 里是 "no hostkeys available -- exiting"），
# 于是「换个系统镜像 → SSH 进不去了」。这里把私钥存到 /data（跟着数据留着），
# 每次启动由 k50-ssh-keys.service 和 pivot 还原回去。
PERSIST="$DATA/persist"
mkdir -p "$PERSIST/etc-ssh"
KEY_N=0
for k in /etc/ssh/ssh_host_*; do
	[ -e "$k" ] || continue
	case "$k" in *.pub) continue ;; esac
	if cp -f "$k" "$PERSIST/etc-ssh/" 2>/dev/null; then KEY_N=$((KEY_N + 1)); fi
done
if [ "$KEY_N" = 0 ]; then
	ssh-keygen -A >/dev/null 2>&1 || true
	for k in /etc/ssh/ssh_host_*; do
		[ -e "$k" ] || continue
		case "$k" in *.pub) continue ;; esac
		if cp -f "$k" "$PERSIST/etc-ssh/" 2>/dev/null; then KEY_N=$((KEY_N + 1)); fi
	done
fi
chmod 600 "$PERSIST"/etc-ssh/ssh_host_* 2>/dev/null || true
ok "保存 $KEY_N 个主机密钥 → $PERSIST/etc-ssh（600）"

# 已经在用的 authorized_keys 也存一份，换镜像后自动装回 k50 家目录
TARGET_USER="$(getent passwd 1000 2>/dev/null | cut -d: -f1 || true)"
[ -n "${TARGET_USER:-}" ] || TARGET_USER=root
TARGET_HOME="$(getent passwd "$TARGET_USER" 2>/dev/null | cut -d: -f6 || true)"
[ -n "${TARGET_HOME:-}" ] || TARGET_HOME=/root
if [ -f "$TARGET_HOME/.ssh/authorized_keys" ]; then
	if cp -f "$TARGET_HOME/.ssh/authorized_keys" "$PERSIST/authorized_keys"; then
		ok "保存 $TARGET_HOME/.ssh/authorized_keys → $PERSIST/authorized_keys（用户 $TARGET_USER）"
	fi
else
	warn "$TARGET_HOME/.ssh/authorized_keys 不存在：换镜像后只能用密码登录（或先 ssh-copy-id）"
fi

# ---------------------------------------------------------------- 装文件（先装！）
# 必须在 mksquashfs **之前**：第一个镜像里如果缺 /usr/local/sbin/k50-image，
# 后面「自检」会判失败 → 开关永远打不开（本地 chroot 实测踩到：全新系统直接 --yes 必挂在这里）。
step "2c" "安装 pivot 与 k50-image（先装，再打镜像）"
[ -f "$REPO_DIR/image-mode/pivot" ] || die "找不到 $REPO_DIR/image-mode/pivot"
[ -f "$REPO_DIR/image-mode/k50-image" ] || die "找不到 $REPO_DIR/image-mode/k50-image"
mkdir -p "$(dirname "$PIVOT_DST")"
install -m 0755 "$REPO_DIR/image-mode/pivot" "$PIVOT_DST"
install -m 0755 "$REPO_DIR/image-mode/k50-image" "$CLI_DST"
dash -n "$PIVOT_DST" || die "pivot 语法不过"
ok "$PIVOT_DST、$CLI_DST（语法已校验）"

# ---------------------------------------------------------------- 第一个镜像
step 3 "把当前系统打成第一个镜像（mksquashfs，几分钟）"
IMG="$IMAGES/system-$(date -u '+%Y%m%d-%H%M%S').squashfs"
EXCLUDES=()
for p in /proc /sys /dev /run /tmp /mnt /images /data /var/tmp \
	/var/cache/apt /var/lib/apt/lists /var/lib/k50/ro /var/lib/k50/new \
	/var/log/journal /var/log/wtmp /var/log/lastlog /var/log/btmp \
	/swapfile /root/k50rf-work /root/k50rf-test; do
	[ -e "$p" ] && EXCLUDES+=("$p") || true
done
info "排除：${EXCLUDES[*]}"
echo "  输出：$IMG"

if [ "$DRY_RUN" = 1 ] && [ -e "$CURRENT" ]; then
	warn "--dry-run 且已有镜像：跳过重新打包，直接用现有 $(basename "$(readlink -f "$CURRENT")") 自检"
else
	if [ -e "$IMG" ]; then die "$IMG 已存在"; fi
	# 压缩算法必须和内核里的 CONFIG_SQUASHFS_* 对得上：
	#   当前这台的内核只有 gzip（SQUASHFS_ZLIB），xz/lzo/zstd 都没编进去，
	#   用 zstd 打出来的镜像会「mount: Filesystem uses "zstd" compression. This is not supported.」
	#   想更小更快：内核加 CONFIG_SQUASHFS_ZSTD=y 重编后，再用 SQUASHFS_COMP=zstd 跑。
	SQUASH_COMP="${SQUASHFS_COMP:-gzip}"
	info "压缩：$SQUASH_COMP"
	mksquashfs / "$IMG" -comp "$SQUASH_COMP" -noappend -no-progress -e "${EXCLUDES[@]}" ||
		die "mksquashfs 失败"
	ok "镜像大小：$(numfmt --to=iec-i --suffix=B "$(stat -c%s "$IMG")")"
	if [ ! -e "$CURRENT" ]; then
		ln -sfn "$(basename "$IMG")" "$CURRENT"
		ok "已设为下次启动的镜像：$(basename "$IMG")"
	else
		echo "  已有 system-current（$(basename "$(readlink -f "$CURRENT")")），新镜像没自动切"
		echo "  想切： sudo k50-image activate $(basename "$IMG")"
	fi
fi

# ---------------------------------------------------------------- fstab
step 4 "写镜像模式专用 fstab：$DATA/fstab.image"
{
	echo "# 镜像模式下的 /etc/fstab（由 enable-image-mode.sh 生成）"
	echo "# 根分区由 pivot 组装成 overlay，这里绝不能有 / 那一行，否则 systemd 会去挂 LABEL=k50rootfs"
	grep -vE '^[[:space:]]*[^#[:space:]]+[[:space:]]+/[[:space:]]' /etc/fstab || true
} >"$DATA/fstab.image"
ok "$(wc -l <"$DATA/fstab.image") 行（已去掉根分区）"
sed 's/^/    /' "$DATA/fstab.image"

# ---------------------------------------------------------------- 装文件
step 5 "把 /sbin/init 换成 pivot（这一步在自检之后）"
if [ "$DRY_RUN" = 1 ]; then
	# dry-run 绝不动 /sbin/init：pivot 的语法已经在 2b 校验过了
	ok "--dry-run：不装 divert，/sbin/init 保持原样"
elif [ -e "$DIVERTED" ] || dpkg-divert --list "$REAL_INIT" 2>/dev/null | grep -q .; then
	ok "$REAL_INIT 已经被 divert 过了（重装脚本，不重复 divert）"
elif [ -e "$REAL_INIT" ]; then
	cp -a "$REAL_INIT" "$REAL_INIT.k50-bak.$(date -u '+%Y%m%d-%H%M%S')" 2>/dev/null || true
	dpkg-divert --add --rename --divert "$DIVERTED" "$REAL_INIT"
	ln -sfn "$PIVOT_DST" "$REAL_INIT"
	ok "$REAL_INIT → $PIVOT_DST（dpkg-divert 原文件存到 $DIVERTED）"
else
	die "找不到 $REAL_INIT —— 系统结构异常，先别动"
fi

# ---------------------------------------------------------------- 自检
step 6 "自检：挂一次新镜像 + 临时 overlay，验证关键路径"
SCRATCH_UP="$DATA/.selftest-upper"
SCRATCH_WK="$DATA/.selftest-work"
cleanup_selftest() {
	umount "$SCRATCH" 2>/dev/null || true
	umount "$DATA/.selftest-ro" 2>/dev/null || true
	[ -n "${LOOP:-}" ] && losetup -d "$LOOP" 2>/dev/null || true
	rm -rf "$SCRATCH_UP" "$SCRATCH_WK" "$DATA/.selftest-ro"
}
trap cleanup_selftest EXIT

mkdir -p "$SCRATCH" "$SCRATCH_UP" "$SCRATCH_WK" "$DATA/.selftest-ro"
umount "$SCRATCH" 2>/dev/null || true
# 自检对象 = 刚打出来的那个镜像（它才是下次要启动的东西）；没有就退回 system-current。
# 别只测 system-current：老镜像可能本来就不含 k50-image，会把「新镜像没问题」误判成失败。
SELFTEST_IMG="$IMG"
[ -e "$SELFTEST_IMG" ] || SELFTEST_IMG="$(readlink -f "$CURRENT")"
info "自检对象：$(basename "$SELFTEST_IMG")"
LOOP="$(losetup -f --show -r "$SELFTEST_IMG")"
mount -t squashfs -o ro "$LOOP" "$DATA/.selftest-ro"
mount -t overlay overlay \
	-o "lowerdir=$DATA/.selftest-ro,upperdir=$SCRATCH_UP,workdir=$SCRATCH_WK" "$SCRATCH" ||
	die "overlay 自检挂载失败"
SELFTEST_FAIL=0
for f in /usr/lib/systemd/systemd /usr/bin/mount /etc/fstab /usr/bin/bash "$CLI_DST"; do
	if [ -e "$SCRATCH$f" ]; then
		ok "有 $f"
	else
		warn "镜像里缺 $f"
		SELFTEST_FAIL=1
	fi
done
if [ -f "$SCRATCH/etc/fstab" ] && grep -qE '^[[:space:]]*[^#[:space:]]+[[:space:]]+/[[:space:]]' "$SCRATCH/etc/fstab"; then
	warn "镜像里的 /etc/fstab 还有根分区那行（靠 $DATA/fstab.image 覆盖，没问题但最好也清掉）"
fi
cleanup_selftest
trap - EXIT
[ "$SELFTEST_FAIL" = 0 ] || die "自检没过，先别打开关"
ok "自检通过"

# ---------------------------------------------------------------- 打开关
if [ "$DRY_RUN" = 1 ]; then
	step 7 "--dry-run：不打开关"
	echo "  重启后仍是普通启动（ext4 根分区）。"
	echo "  确认没问题后执行： sudo $0 --yes"
	exit 0
fi

step 7 "打开关 $MARKER"
if [ "$ASSUME_YES" != 1 ]; then
	echo
	echo "即将启用镜像模式："
	echo "  下次启动：squashfs 只读系统层 + $UPPER 可写层"
	echo "  系统盘（ext4 根分区）与 /data 都不会被改，随时可以 --revert 或 k50-image disable 退回来"
	read -r -p "继续？输入 yes：" a
	[ "$a" = yes ] || die "已取消（什么都没改）"
fi
touch "$MARKER"
ok "已启用"
echo
echo "重启验证： sudo reboot"
echo "重启后检查： sudo k50-image status   （应该显示「镜像模式（已 pivot…）」）"
echo "退回去：     sudo k50-image disable && sudo reboot"
