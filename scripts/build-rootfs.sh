#!/usr/bin/env bash
# ==============================================================================
#  build-rootfs.sh —— 从零构建 K50（Xiaomi Redmi K50 / rubens）用的 Debian rootfs
#
#  产物（work/out/）：
#    k50-rootfs-<suite>.img.zst     ext4 镜像（resize2fs -M 收缩过）
#    k50-rootfs-<suite>.tar.zst     同内容 tar 包
#    packages.txt / BUILD.txt / SHA256SUMS.txt
#
#  用法：
#    sudo ./scripts/build-rootfs.sh
#    SUITE=bookworm IMAGE_SIZE_GIB=16 sudo -E ./scripts/build-rootfs.sh
#
#  依赖：mmdebstrap、e2fsprogs、rsync、zstd、tar、coreutils
#  在 x86_64 主机上构建 arm64 rootfs 需要 qemu-user-static + binfmt_misc
# ==============================================================================
set -euo pipefail

# ── 参数（环境变量覆盖 config/config）────────────────────────────────────────
TARGET_ARCH="${TARGET_ARCH:-arm64}"   # K50 是 arm64；改成 amd64 可在 x86 上做流程自测
SUITE="${SUITE:-trixie}"
MIRROR="${MIRROR:-https://mirrors.aliyun.com/debian}"
SECURITY_MIRROR="${SECURITY_MIRROR:-https://security.debian.org/debian-security}"
COMPONENTS="${COMPONENTS:-main contrib non-free non-free-firmware}"
IMAGE_SIZE_GIB="${IMAGE_SIZE_GIB:-8}"
IMG_LABEL="${IMG_LABEL:-k50rootfs}"
SYS_HOSTNAME="${SYS_HOSTNAME:-k50-linux}"
USERNAME="${USERNAME:-k50}"
PASSWORD="${PASSWORD:-k50}"
SYS_TZ="${SYS_TZ:-Asia/Shanghai}"
EXTRA_PACKAGES="${EXTRA_PACKAGES:-}"

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="${WORK:-$REPO/work}"
ROOT="$WORK/rootfs"
EXTRA_DIR="${EXTRA_DIR:-$WORK/extra}"     # 可选：从设备拷来的厂商固件等
OUT="$WORK/out"
IMG="$OUT/k50-rootfs-${SUITE}.img"
TARBALL="$OUT/k50-rootfs-${SUITE}.tar.zst"
SQUASH="$OUT/k50-rootfs-${SUITE}.squashfs"
JOBS="${JOBS:-$(nproc)}"
OUTPUTS="${OUTPUTS:-img,tar,squash}"       # img / tar / squash / none（阶段自测用）

log() { printf '\n\033[1m=== %s ===\033[0m\n' "$*"; }
die() { printf '\n[失败] %s\n' "$*" >&2; exit 1; }

# ── 0. 前置检查 ──────────────────────────────────────────────────────────────
[ "$(id -u)" = 0 ] || die "需要 root 运行（chroot + loop mount）"
for c in mmdebstrap mkfs.ext4 e2fsck resize2fs rsync zstd tar; do
	command -v "$c" >/dev/null || die "缺少命令：$c"
done
if [[ ",$OUTPUTS," == *",squash,"* ]]; then
	command -v mksquashfs >/dev/null ||
		die "缺少命令：mksquashfs（apt install squashfs-tools）——或者把 OUTPUTS 里的 squash 去掉"
fi

# mmdebstrap 用宿主机的 Debian 归档公钥校验 Release 签名。
# 在 Ubuntu 等非 Debian 宿主机上必须装这个包，否则 apt 会报 NO_PUBKEY / "not signed"。
if [ ! -e /usr/share/keyrings/debian-archive-keyring.gpg ] &&
	[ ! -e /usr/share/keyrings/debian-archive-keyring.pgp ]; then
	die "缺少 Debian 归档公钥（mmdebstrap 校验 Release 签名要用）：
    Debian 上：sudo apt-get install -y debian-archive-keyring
    Ubuntu 上：sudo apt-get install -y debian-archive-keyring
    报错长相：NO_PUBKEY 6ED0E7B82643E131 / 'The repository ... is not signed'"
fi

HOST_ARCH="$(uname -m)"
case "$HOST_ARCH" in
aarch64 | arm64) HOST_IS_AARCH64=1 ;;
*) HOST_IS_AARCH64=0 ;;
esac
if [ "$TARGET_ARCH" = arm64 ] && [ "$HOST_IS_AARCH64" = 0 ]; then
	[ -e /proc/sys/fs/binfmt_misc/qemu-aarch64 ] || die \
		"在 $HOST_ARCH 上构建 arm64 rootfs 需要 qemu-user-static + binfmt_misc：
    sudo apt-get install -y qemu-user-static binfmt-support
    sudo update-binfmts --enable qemu-aarch64
    然后确认 /proc/sys/fs/binfmt_misc/qemu-aarch64 存在"
	log "非 arm64 主机（$HOST_ARCH），通过 binfmt/qemu 跨架构构建（会慢很多）"
fi

log "构建参数"
cat <<EOF
  suite         = $SUITE
  mirror        = $MIRROR
  components    = $COMPONENTS
  image         = $IMG (${IMAGE_SIZE_GIB} GiB，构建后收缩)
  label         = $IMG_LABEL
  hostname/user = $SYS_HOSTNAME / $USERNAME
  timezone      = $SYS_TZ
  jobs          = $JOBS
EOF

rm -rf "$ROOT"
mkdir -p "$ROOT" "$OUT"

# ── 1. 引导第一阶段：mmdebstrap 生成最小系统并装包 ──────────────────────────
PKGS="$(grep -vE '^[[:space:]]*(#|$)' "$REPO/config/packages.list" | tr -d ' \r' | paste -sd, -)"
[ -n "$EXTRA_PACKAGES" ] && PKGS="$PKGS,$EXTRA_PACKAGES"
[ -n "$PKGS" ] || die "config/packages.list 是空的"

log "mmdebstrap $SUITE ($COMPONENTS) → $ROOT"
log "包清单：$PKGS"

# 额外 apt 选项（可选，用环境变量注入）。典型用处是内网/代理环境：
#   APT_OPTS='Acquire::https::Proxy "http://127.0.0.1:7897"; Acquire::http::Proxy "http://127.0.0.1:7897";'
# 用分号分隔，每段转成一个 --aptopt=。
APTOPT_ARGS=()
if [ -n "${APT_OPTS:-}" ]; then
	IFS=';' read -ra _aptopts <<< "$APT_OPTS"
	for o in "${_aptopts[@]}"; do
		o="${o#"${o%%[![:space:]]*}"}"
		o="${o%"${o##*[![:space:]]}"}"
		[ -n "$o" ] && APTOPT_ARGS+=("--aptopt=$o")
	done
	unset IFS
	log "额外 apt 选项：$APT_OPTS"
fi
if ! mmdebstrap \
	--mode=root \
	--arch="$TARGET_ARCH" \
	--variant=important \
	--components="$COMPONENTS" \
	--include="$PKGS" \
	--aptopt='APT::Install-Recommends "true";' \
	"${APTOPT_ARGS[@]}" \
	"$SUITE" "$ROOT" "$MIRROR"; then
	die "mmdebstrap 失败：若是包名写错，apt 的报错会点名是哪一个（改 config/packages.list）"
fi

chroot_run() {
	chroot "$ROOT" /usr/bin/env -i \
		HOME=/root TERM=dumb \
		PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
		DEBIAN_FRONTEND=noninteractive LANG=C.UTF-8 LC_ALL=C.UTF-8 \
		"$@"
}

# ── 2. apt 源 ────────────────────────────────────────────────────────────────
log "写入 apt 源"
cat >"$ROOT/etc/apt/sources.list" <<EOF
deb $MIRROR $SUITE $COMPONENTS
deb $MIRROR $SUITE-updates $COMPONENTS
deb $SECURITY_MIRROR $SUITE-security $COMPONENTS
EOF
rm -f "$ROOT"/etc/apt/sources.list.d/*.sources 2>/dev/null || true

# ── 3. 系统身份 / 用户 / 时区 / 服务 ─────────────────────────────────────────
log "系统配置（hostname / 用户 / 时区 / 单元）"
chroot_run /bin/bash -euc "
	set -x
	echo '$SYS_HOSTNAME' > /etc/hostname
	printf '127.0.0.1\tlocalhost\n127.0.1.1\t$SYS_HOSTNAME\n::1\t\tlocalhost ip6-localhost ip6-loopback\n' > /etc/hosts

	ln -sf /usr/share/zoneinfo/$SYS_TZ /etc/localtime
	echo '$SYS_TZ' > /etc/timezone

	sed -i 's/^#[[:space:]]*en_US.UTF-8/en_US.UTF-8/; s/^#[[:space:]]*zh_CN.UTF-8/zh_CN.UTF-8/' /etc/locale.gen || true
	locale-gen
	echo 'LANG=zh_CN.UTF-8' > /etc/default/locale

	id -u $USERNAME >/dev/null 2>&1 || useradd -m -u 1000 -s /bin/bash $USERNAME
	echo '$USERNAME:$PASSWORD' | chpasswd
	# 某些组可能还没被任何包创建；缺了就补，否则 usermod 会整体失败
	for g in sudo audio video plugdev input render netdev bluetooth; do
		getent group \$g >/dev/null || groupadd \$g
	done
	usermod -aG sudo,audio,video,plugdev,input,render,netdev,bluetooth $USERNAME
	set +x
" >/dev/null

# 默认目标 + display-manager + 各类单元
log "启用单元"
systemctl --root="$ROOT" set-default graphical.target
for u in bluetooth NetworkManager NetworkManager-wait-online ssh udisks2 gdm systemd-timesyncd; do
	systemctl --root="$ROOT" enable "$u" >/dev/null 2>&1 || echo "  （跳过 $u：本套件里没有这个单元）"
done
ln -sf /usr/lib/systemd/system/gdm.service "$ROOT/etc/systemd/system/display-manager.service" 2>/dev/null || true

# ── 4. overlay（K50 专属文件）────────────────────────────────────────────────
log "复制 overlay/"
cp -a "$REPO/overlay/." "$ROOT/"
# cp -a "dir/." 会把 dir 里每个目录（包括 dir 自身）的属主与权限一块盖到目标上 ——
# 在 NTFS/drvfs 上就是 777 + 构建用户，落到镜像里等于 / 与 /usr 世界可写。
# 这里按 overlay 的目录清单逐个纠正（/home/<user> 稍后单独改成 1000:1000）。
(cd "$REPO/overlay" && find . -type d -exec sh -c '
	for d in "$@"; do
		t="$0/${d#./}"
		if [ -d "$t" ]; then
			chown root:root "$t" 2>/dev/null || true
			chmod 0755 "$t" 2>/dev/null || true
		fi
	done' "$ROOT" {} + )

if [ -d "$EXTRA_DIR" ]; then
	log "合并 $EXTRA_DIR（厂商固件等本地产物，不进 git）"
	cp -a "$EXTRA_DIR/." "$ROOT/"
else
	log "没有 $EXTRA_DIR；跳过本地额外文件（见 docs/FLASH.md 的厂商固件一节）"
fi

# fstab 的卷标必须与真实 mkfs 的标签一致
sed -i "s|^LABEL=[^[:space:]]*|LABEL=$IMG_LABEL|" "$ROOT/etc/fstab"

# overlay 里的文件是 cp -a 拷进来的：如果仓库克隆在 NTFS/drvfs 上（Windows 侧），
# 每个文件都是 0777 且属主是构建用户 —— 直接 cp -a 会把 777、非 root 属主装进系统。
# 这里统一归一化：/etc 与 /usr/local 一律 root:root；先全设 0644，再把要执行的文件设回 0755。
chown -R root:root "$ROOT/etc" "$ROOT/usr/local" 2>/dev/null || true
find "$ROOT/etc" "$ROOT/usr/local" -type f -exec chmod 0644 {} + 2>/dev/null || true
find "$ROOT/etc" "$ROOT/usr/local" -type d -exec chmod 0755 {} + 2>/dev/null || true
chmod 0755 "$ROOT"/usr/local/sbin/*.sh "$ROOT"/usr/local/sbin/*.py 2>/dev/null || true
# 无扩展名的可执行文件单独点名（chmod 0644 那一轮会把它们清掉）
for f in "$ROOT/usr/local/sbin/k50-image" "$ROOT/usr/local/lib/k50/pivot"; do
	[ -f "$f" ] && chmod 0755 "$f"
done
[ -d "$ROOT/home/$USERNAME" ] && {
	chown -R 1000:1000 "$ROOT/home/$USERNAME"
	# 同理：overlay 里带来的用户文件在 drvfs 上也是 777
	find "$ROOT/home/$USERNAME" -type d -exec chmod 0755 {} + 2>/dev/null || true
	find "$ROOT/home/$USERNAME" -type f -exec chmod 0644 {} + 2>/dev/null || true
}

# ── 4b. image-mode 工具也要进镜像 ────────────────────────────────────────────
# 教训（2026-10-31 真机事故）：镜像里如果没有 k50-image/pivot，一旦把它当 lower 换上，
# 新系统里连"切回旧镜像"的命令都没有了，只能手工改 /images/system-current 符号链接。
log "安装 image-mode 工具（pivot / k50-image / 启用脚本）"
install -m 0755 "$REPO/image-mode/pivot" "$ROOT/usr/local/lib/k50/pivot"
install -m 0755 "$REPO/image-mode/k50-image" "$ROOT/usr/local/sbin/k50-image"
install -m 0755 "$REPO/scripts/enable-image-mode.sh" \
	"$ROOT/usr/local/sbin/k50-enable-image-mode.sh"
for f in "$ROOT/usr/local/lib/k50/pivot" "$ROOT/usr/local/sbin/k50-image"; do
	[ -f "$f" ] || die "image-mode 工具没进镜像：$f"
done
echo "  k50-image / pivot 已入镜像"

for u in k50-backlight.service k50-bt-agent.service k50-ble-launch.service k50-powerkey.service k50-ssh-keys.service; do
	[ -f "$ROOT/etc/systemd/system/$u" ] && systemctl --root="$ROOT" enable "$u" >/dev/null 2>&1 \
		&& echo "  enabled $u"
done
if [ -f "$ROOT/etc/systemd/system/k50-bt-reconnect.timer" ]; then
	systemctl --root="$ROOT" enable k50-bt-reconnect.timer >/dev/null 2>&1 && echo "  enabled k50-bt-reconnect.timer"
else
	systemctl --root="$ROOT" enable k50-bt-reconnect.service >/dev/null 2>&1 && echo "  enabled k50-bt-reconnect.service"
fi

# dconf 系统级默认值（改了 local.d 就必须重新编译 local）
if command -v dconf >/dev/null 2>&1 || [ -x "$ROOT/usr/bin/dconf" ]; then
	log "编译 dconf 系统默认值"
	chroot_run dconf update || echo "  dconf update 失败（不影响启动，只是默认值不生效）"
else
	log "警告：没有 dconf-cli，overlay 里的 dconf 默认值不会生效"
fi

# ── 5. 清理（隐私 + 体积）────────────────────────────────────────────────────
log "清理"
chroot_run /bin/bash -euc "
	apt-get -y autoremove --purge >/dev/null 2>&1 || true
	apt-get clean
	rm -rf /var/lib/apt/lists/* /var/cache/apt/* /tmp/* /var/tmp/*
	rm -f /etc/ssh/ssh_host_* /var/lib/systemd/random-seed
	# journal 必须清：镜像若带着「源机器正在写的那份 journal」，开机后 journald
	# 会在只读层上做 copy-up，实测 overlayfs 直接报 ESTALE（-116），
	# 'failed to look up (user-1000.journal) for ino (-116)'，用户日志从此写不进去。
	rm -rf /var/log/journal/* /var/log/*.log /var/log/*.log.*
	rm -f /var/log/wtmp /var/log/lastlog /var/log/btmp /var/log/faillog
	# machine-id 也必须一起换：只清 /etc/machine-id 时 systemd 会沿用
	# /var/lib/dbus/machine-id，于是新系统仍然用旧 id，撞上镜像里那份旧 journal 目录。
	: > /etc/machine-id
	rm -f /var/lib/dbus/machine-id
	rm -rf /root/.bash_history /home/$USERNAME/.bash_history
"

log "导出包清单"
chroot_run dpkg-query -W -f='${Package}\t${Version}\n' >"$OUT/packages.txt"
wc -l <"$OUT/packages.txt" | xargs -I{} echo "  已装 {} 个包"

# ── 6. 造 ext4 镜像 ─────────────────────────────────────────────────────────
RAW=0
ZS=0
SS=0
if [[ ",$OUTPUTS," == *",img,"* ]]; then
	log "创建 ext4 镜像 ${IMAGE_SIZE_GIB} GiB"
	rm -f "$IMG"
	truncate -s "${IMAGE_SIZE_GIB}G" "$IMG"
	mkfs.ext4 -q -F -L "$IMG_LABEL" -m 1 "$IMG"

	MNT="$WORK/mnt"
	mkdir -p "$MNT"
	mount -o loop "$IMG" "$MNT"
	log "rsync rootfs → 镜像"
	rsync -aHAX --numeric-ids "$ROOT/" "$MNT/"
	sync
	umount "$MNT"

	log "收缩镜像到最小"
	e2fsck -fy "$IMG" >/dev/null 2>&1 || true
	resize2fs -M "$IMG" >/dev/null
	RAW="$(stat -c%s "$IMG")"
	log "收缩后 $RAW 字节（$(numfmt --to=iec "$RAW")）"

	log "压缩镜像（zstd -19）"
	rm -f "$IMG.zst"
	zstd -19 --long=27 -T"$JOBS" -q -f "$IMG" -o "$IMG.zst"
	ZS="$(stat -c%s "$IMG.zst")"
	if [ "$ZS" -gt 1900000000 ]; then
		log "警告：$IMG.zst 有 $(numfmt --to=iec "$ZS")，超过 GitHub Release 单文件 2 GiB 上限"
	fi
fi

if [[ ",$OUTPUTS," == *",tar,"* ]]; then
	log "打 tar 包（zstd -19）"
	rm -f "$TARBALL"
	tar -C "$ROOT" --numeric-owner -I "zstd -19 -T$JOBS -q" -cf "$TARBALL" .
fi

# squashfs = 镜像模式的「只读系统层」（配合 image-mode/ 里的 pivot + k50-image 用）
if [[ ",$OUTPUTS," == *",squash,"* ]]; then
	SQUASH_COMP="${SQUASHFS_COMP:-gzip}"
	log "打 squashfs（镜像模式系统层，$SQUASH_COMP 压缩）"
	rm -f "$SQUASH"
	mksquashfs "$ROOT" "$SQUASH" -comp "$SQUASH_COMP" -noappend -no-progress \
		-e proc sys dev run tmp mnt var/tmp var/cache/apt var/lib/apt/lists \
		var/log/journal swapfile
	SS="$(stat -c%s "$SQUASH")"
	log "squashfs 大小 $(numfmt --to=iec "$SS")"
	if [ "$SS" -gt 1900000000 ]; then
		log "警告：$SQUASH 超过 GitHub Release 单文件 2 GiB 上限"
	fi
fi

# ── 7. 说明书 + 校验和 ──────────────────────────────────────────────────────
log "写 BUILD.txt / SHA256SUMS.txt"
{
	echo "k50-rootfs build"
	echo "date        : $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
	echo "suite       : $SUITE"
	echo "mirror      : $MIRROR"
	echo "components  : $COMPONENTS"
	echo "arch        : $TARGET_ARCH"
	echo "image_label : $IMG_LABEL"
	echo "raw_size    : $RAW ($(numfmt --to=iec "$RAW" 2>/dev/null || echo 0))"
	echo "img.zst     : $ZS ($(numfmt --to=iec "$ZS" 2>/dev/null || echo 0))"
	echo "squashfs    : $SS ($(numfmt --to=iec "$SS" 2>/dev/null || echo 0))"
	echo "packages    : $(wc -l <"$OUT/packages.txt")"
	echo "host        : $(uname -srm) / $(command -v mmdebstrap >/dev/null && mmdebstrap --version | head -1)"
	echo
	echo "刷机：把 .img.zst 解压后 dd 到 userdata（K50 上是 /dev/sdc86），"
	echo "     开机进系统后 resize2fs /dev/sdc86 扩满分区。详见 docs/FLASH.md"
	echo "更新：把 .squashfs 放进设备的 /images/，用 k50-image activate 切换，详见 docs/UPDATE.md"
} >"$OUT/BUILD.txt"

# 校验和：把这次真正产出的东西都列进去（squashfs 曾经漏掉过，别再用硬编码通配）
(
	cd "$OUT"
	{
		for f in BUILD.txt packages.txt k50-rootfs-*.img.zst k50-rootfs-*.tar.zst k50-rootfs-*.squashfs; do
			if [ -f "$f" ]; then sha256sum "$f"; fi
		done
	} >SHA256SUMS.txt
	cat SHA256SUMS.txt
)

log "完成"
ls -lh "$OUT"
