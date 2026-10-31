# k50-rootfs — 小米 Redmi K50（rubens）用的 Debian rootfs

给 **Xiaomi Redmi K50** 跑 mainline/上游 Linux 用的 Debian 根文件系统，**从零构建**（不是从别人镜像改的），
构建全部由 GitHub Actions 完成，产物以 Release 形式发布。

> 这个仓库**只管 rootfs**。内核、boot.img、面板/蓝牙补丁、`k50_bl.ko` 背光模块在另一个仓库 **k50-boot**。

---

## 一、三种用法

### 1. 直接下载现成的（推荐，最省事）

到 [Releases](../../releases) 找最新的 `ci-*` 预发布，下载：

| 文件 | 说明 |
| --- | --- |
| `k50-rootfs-trixie.img.zst` | ext4 根文件系统镜像（已 `resize2fs -M` 收缩），**刷这个** |
| `k50-rootfs-trixie.tar.zst` | 同样内容的 tar 包，想自己解到别的分区用 |
| `packages.txt` | 镜像里装了哪些包、什么版本 |
| `BUILD.txt` | 构建时间、commit、烧写命令 |
| `SHA256SUMS.txt` | 校验和 |

烧写（**在设备上**，需要 root，用 USB 串口或 ssh 进去）：

```bash
zstd -d k50-rootfs-trixie.img.zst -c | dd of=/dev/sdc86 bs=4M oflag=direct status=progress
sync
```

重启进系统后，第一件事是把文件系统扩满分区（镜像为了减小体积被收缩过）：

```bash
sudo resize2fs /dev/sdc86
```

> `/dev/sdc86` 是 K50 的 userdata 分区。用 `findmnt -no SOURCE /` 确认你自己的根分区再刷。

### 2. 本地构建

需要一台 **arm64** Linux 主机（或 x86 + `qemu-user-static` + binfmt；会慢很多）：

```bash
sudo apt-get install -y mmdebstrap debian-archive-keyring e2fsprogs rsync zstd tar
sudo ./scripts/build-rootfs.sh
# 产物在 work/out/
```

可以临时改参数，不改仓库文件：

```bash
# 临时覆盖 config/config 里的值（不改文件）
sudo SUITE=bookworm IMAGE_SIZE_GIB=16 EXTRA_PACKAGES=vim,git ./scripts/build-rootfs.sh
```

**代理/内网环境**：apt 走代理要靠 `APT_OPTS` 注入（分号分隔，每段变成一个 `--aptopt=`）：

```bash
sudo APT_OPTS='Acquire::https::Proxy "http://127.0.0.1:7897"; Acquire::http::Proxy "http://127.0.0.1:7897";' ./scripts/build-rootfs.sh
```

**只想验证脚本本身**（x86 上原生跑，不需要 qemu；除架构外覆盖全部代码路径，几十分钟出结果）：

```bash
sudo TARGET_ARCH=amd64 IMAGE_SIZE_GIB=8 OUTPUTS=img,squash ./scripts/build-rootfs.sh
```

**实测参考**（Ubuntu 24.04 / amd64 / 8 核 / 代理带宽约 1 MB/s）：全流程约 40 分钟，装了 1408 个包；
rootfs 实际占用 3.5 GB，squashfs 1.3 GB（gzip），`img.zst` 874 MB。
`IMAGE_SIZE_GIB=4` 会被塞到只剩几十 MB，所以默认值是 **8**。

### 3. Fork 后用自己的 GitHub Actions 建

1. Fork 本仓库。
2. 改 `config/config`（镜像大小、密码、时区…）和 `config/packages.list`（要装什么）。
3. 把要带进镜像的自有文件放进 `overlay/`（路径与根目录一一对应）。
4. Actions → **build-rootfs** → Run workflow。

CI 默认跑在 **arm64 runner**（`ubuntu-24.04-arm`，原生构建，不需要 qemu）。
手动 Run 的时候有个 **`runner` 下拉框**：选 `ubuntu-24.04` 就走免费 x86 + qemu
（「装构建工具」那步会自动装 qemu/binfmt，脚本启动时会检查 `/proc/sys/fs/binfmt_misc/qemu-aarch64`）。

> `ubuntu-24.04-arm` 只对**公开仓库**免费；私有仓库把 `runner` 选成 `ubuntu-24.04` 即可
> （定时任务和 push 触发没有输入框，所以它们固定用 arm64 —— 私有仓想让定时任务也能跑，
> 就把 `build-rootfs.yml` 里 `runs-on` 的默认值直接改成 `ubuntu-24.04`）。
> 首跑最容易踩的坑：宿主必须装 `debian-archive-keyring`（mmdebstrap 要用它校验 Debian Release 签名），
> 否则报 `NO_PUBKEY 6ED0E7B82643E131` —— workflow 的「装构建工具」里已经加了。

---

## 二、仓库结构

```
config/config            构建参数（版本、镜像大小、密码、时区、镜像卷标…）
config/packages.list     要装的包，一行一个，可注释
overlay/                 原样覆盖到 rootfs 根目录的文件（K50 专属配置、脚本、systemd 单元）
image-mode/              镜像模式：pivot（占 /sbin/init）+ k50-image（管理工具）
scripts/build-rootfs.sh  构建脚本（mmdebstrap → chroot 配置 → 造 ext4/squashfs → 压缩）
scripts/enable-image-mode.sh  在设备上一次性启用镜像模式（含 --dry-run / --revert）
.github/workflows/       定时/手动构建 + 发布 Release
docs/FLASH.md            刷机、回滚、厂商固件说明
docs/UPDATE.md           镜像模式（换系统不丢数据）的原理与用法
```

构建流程：`mmdebstrap` 装出最小系统 → chroot 里配主机名/用户/时区/locale/服务 → 复制 `overlay/`
→ `mkfs.ext4` + `rsync` 装进镜像 → `e2fsck` + `resize2fs -M` 收缩 → `zstd -19` 压缩
→ 另打一份 `squashfs`（镜像模式的系统层）→ 发 Release。

## 三、`config/config` 参数

| 键 | 默认 | 说明 |
| --- | --- | --- |
| `suite` | `trixie` | Debian 版本（trixie = 13） |
| `mirror` | 阿里云 | 主仓库镜像，构建时用 |
| `security_mirror` | `security.debian.org/debian-security` | 安全更新仓库 |
| `components` | `main contrib non-free non-free-firmware` | 组件 |
| `image_size_gib` | `8` | 镜像初始大小，构建后自动收缩到实际占用。实测系统占 3.5 GB，**别低于 8** |
| `image_label` | `k50rootfs` | ext4 卷标，**必须和 `overlay/etc/fstab` 里的 `LABEL=` 一致**（脚本会自动改写 fstab） |
| `hostname` | `k50-linux` | 主机名 |
| `username` / `password` | `k50` / `k50` | 普通用户（uid 1000）与初始密码，**第一次登录就改掉** |
| `timezone` | `Asia/Shanghai` | 时区 |
| `extra_packages` | 空 | 额外要装的包，逗号分隔 |
| `keep_releases` | `8` | 保留多少个 `ci-*` 旧 Release，多的自动删 |
| `squashfs_comp` | `gzip` | 镜像模式 squashfs 的压缩算法，**必须和内核里的 `CONFIG_SQUASHFS_*` 对上**（K50 当前内核只编了 gzip） |

## 四、第一次开机要做的几件事

1. **改密码**：`passwd`（镜像里的初始密码是公开的 `k50`）。
2. **扩分区**：`sudo resize2fs /dev/sdc86`。
3. **连 WiFi**：`nmtui` 或 GNOME 设置里连（NetworkManager 已装并开机自启）。
4. **对时间**：K50 **没有 RTC**，开机时间可能不准，会让 HTTPS/apt 报证书错误。
   镜像里装了 `systemd-timesyncd` + `fake-hwclock`，联网后几秒内自动同步；如果 apt 报
   `certificate verify failed`，先 `sudo systemctl restart systemd-timesyncd && sleep 5` 再试。
5. **装厂商固件**：WiFi/蓝牙/触摸/音频的固件是厂商二进制，**不在本仓库**（版权），
   从你自己的设备上拷（见 [docs/FLASH.md](docs/FLASH.md) 的「厂商固件」一节）。不装的话
   WiFi 起不来、蓝牙哑、触摸无反应。
6. **装背光模块**：`k50_bl.ko` 由 **k50-boot** 仓库的 Release 提供（就在 release 附件里），
   放到 `/usr/local/lib/k50/k50_bl.ko` 后 `sudo systemctl start k50-backlight`，
   之后 GNOME 的亮度滑块就能用（`/sys/class/backlight/l11a`）。
   `k50-backlight.service` 带 `ConditionPathExists=/usr/local/lib/k50/k50_bl.ko`，没放模块时会被干净跳过，
   不会反复失败；镜像模式下 `/usr/local` 属于只读层，拷进去就落在可写层（`/data/upper`），换镜像后仍保留。
7. 相机/指纹/基带不在本仓库（各自独立项目），KD50 上它们是分开的内核模块。

## 五、更新系统而不丢数据（镜像模式）

现在换系统要 `dd` 刷整个 userdata，数据会全丢。本仓库带一套**镜像模式**解决它：
系统放在只读 `squashfs` 里，所有改动落在 `/data` 上的可写 overlay 中，更新 = 换 squashfs + 重启；
起不来就 `k50-image rollback` 切回上一个，`/data` 一个字节不动。

```bash
sudo ./scripts/enable-image-mode.sh --dry-run   # 先干跑：打包 + 自检挂载，不打开关
sudo ./scripts/enable-image-mode.sh --yes       # 正式启用（把 /sbin/init 换成 pivot）
sudo reboot && sudo k50-image status

# 日常更新：从"自己这套系统"打快照，而不是换一套陌生系统（详见 docs/UPDATE.md §10）
sudo apt update && sudo apt full-upgrade
sudo k50-image snapshot                         # → /images/system-<UTC 时间戳>.squashfs
sudo k50-image activate system-<时间戳> && sudo reboot

scp k50-rootfs-trixie.squashfs k50:/tmp/        # 也可以从别处拿镜像
ssh k50 "sudo k50-image install /tmp/k50-rootfs-trixie.squashfs"
ssh k50 "sudo k50-image activate system-<时间戳> && sudo reboot"
ssh k50 "sudo k50-image rollback && sudo reboot"   # 起不来就切回去

sudo k50-image disable                              # 退回普通启动
sudo ./scripts/enable-image-mode.sh --revert        # 彻底撤掉（还原 /sbin/init）
```

原理、验证清单、风险兜底全在 **[docs/UPDATE.md](docs/UPDATE.md)**。一句话：
系统盘（ext4 根分区）和 `/data` 从不被改写，任何异常都退回普通启动，不会变砖。

### 真机验证结果（2026-10-31，Redmi K50）

| 动作 | 结果 |
|---|---|
| `enable-image-mode.sh --dry-run` | ✅ 打镜像 + 自检挂载全绿，不动 `/sbin/init` |
| `--yes` + 重启 | ✅ `/` 变成 overlay（`lowerdir=/var/lib/k50/ro`、`upperdir=/data/upper`），服务全正常 |
| 换镜像（`activate` 新镜像）+ 重启 | ✅ 新系统起来，**旧镜像里写的文件还在**（可写层跨镜像保留） |
| `rollback` + 重启 | ✅ 切回上一个镜像，两个镜像都还在 |
| 挂载失败时的兜底 | ✅ 真触发过一次：`pivot` 自动退回普通启动，数据无损 |
| `k50-image snapshot`（从当前系统打快照） | ✅ 1 分 30 秒出 1.8 GiB 镜像，镜像里自带 `/usr/local/sbin/k50-image` |
| `activate` 一个不带 `k50-image` 的镜像 | 🛡️ 被拒绝（`rc=1`，`system-current` 未变），提示手工切回的办法 |

**首次启用前踩过的坑（已在代码里修掉，别重复踩）**：

* overlay 换 lower 时必须带 `index=off`。不加会 `rc=32 / Stale file handle`，
  dmesg 是 `overlayfs: failed to verify upper root origin` —— 原因见 `image-mode/pivot` 里的注释。
* `pivot` 是被内核直接 `exec` 的，环境里**没有 `PATH`**，脚本开头必须自己 export。
* squashfs 压缩算法要和内核编进去的 `CONFIG_SQUASHFS_*` 对上（默认 `gzip`）。
* 打镜像时**必须把 `/var/log/journal` 排除或清空**：带着"源机器正在写的 journal"进镜像，
  开机后 journald 在只读层上 copy-up，overlayfs 会报 ESTALE（-116），用户日志从此写不进去；
  顺手也要把 `/etc/machine-id` 和 `/var/lib/dbus/machine-id` 一起换掉。
  `build-rootfs.sh` 与 `enable-image-mode.sh` 都已处理。
* 换镜像后 **SSH 会进不去**：镜像里没有 `/etc/ssh/ssh_host_*`（构建脚本故意删掉，
  免得把构建机的身份打进镜像），sshd 缺主机密钥会直接退出
  （`sshd: no hostkeys available -- exiting`），表现就是端口能连上但立刻断开、读不到 banner。
  现在由 `usr/local/sbin/k50-ssh-keys.sh`（`k50-ssh-keys.service`，排在 `ssh.service` 之前）
  负责恢复/生成，主机密钥和 `authorized_keys` 都持久化在 `/data/persist/`，
  由 `enable-image-mode.sh` 在启用时存一份、`pivot` 在开机时先恢复一遍。
  万一碰上没有这套机制的老镜像，进去以后手动跑：
  `sudo ssh-keygen -A && sudo systemctl restart ssh`。
* `k50-ssh-keys.sh` 判断"是不是镜像模式"**不能用 `mountpoint -q /data`**：它依赖
  `/proc/self/mountinfo`，在 chroot / 早期启动阶段可能还没有 `/proc`，会把镜像模式误判成
  普通启动（本地实测：密钥能生成，但一份都没落进 `/data/persist`）。改用"`/data` 目录存在"
  作为主判据。
* 同一个脚本里**别无条件 `mkdir -p /data/persist/etc-ssh`**：普通启动（引导层）时 `/data`
  根本不存在，无脑 mkdir 会在根文件系统上凭空造出一个假 `/data`，密钥写进那层"假存档"，
  下次进镜像模式真 `/data` 覆盖上来就像丢了。现在只在镜像模式下才建。

* **别把「另一套系统」当系统层换上去**（2026-10-31 真机事故）。换 lower 只是换"读的那一层"，
  可写层 `/data/upper` 一个字都不动；但如果新 lower 是**从零构建的干净系统**，旧系统里所有
  "从来没被改写过"的文件（整个 `/usr`、`/etc` 里的默认值、`/home` 骨架）都会被同名文件遮住，
  用户看到的就是"我的系统全被换掉了"。换之前先 `k50-image list` 看一眼包数/体积差异
  （1123 个包 vs 1395 个包这种差别很明显）。自救办法（连 CLI 都没了时怎么切回去）写在
  `docs/UPDATE.md` §9。
* **镜像里必须自带 `k50-image` 和 `pivot`**：否则把它换上之后，新系统里连"切回旧镜像"的
  命令都没有了，只能手工改 `/images/system-current` 符号链接。`build-rootfs.sh` 第 4b 步
  负责把这两个（外加启用脚本）装进镜像；`k50-image install` 会提示、`k50-image activate`
  会**直接拒绝**这种镜像（除非 `--force`）。

上面这套（生成 / 幂等 / 换镜像后从 `/data` 恢复同一把 / 存档也没了就重新生成 /
`authorized_keys` 恢复成 `600` 且属主正确 / 普通启动不建 `/data`）**已在真实构建出来的
rootfs 里 chroot 逐项跑过**（六种情形全绿），不是纸面推导。

`--revert`（彻底还原 `/sbin/init` + 清 `dpkg-divert`）已在**真实 rootfs 的 chroot 沙箱里
真跑过**（还原后 `/usr/sbin/init` 回到 `../lib/systemd/systemd`、divert 清空、`/images`
与 `/data` 里的数据保留）；**设备上还没跑过**，真要用请先 `--dry-run` 看它要动什么。

## 六、已知限制

* **没有 RTC**：靠 `fake-hwclock` 保存/恢复时间 + NTP 校正，冷启动头几秒时间可能不准。
* **没有厂商固件**：必须自己补 —— 放进 `/data/firmware/`（镜像模式下 `pivot` 会自动叠回 `/lib/firmware`），
  或省事直接放 `/lib/firmware`（普通启动时生效）。见 [docs/FLASH.md](docs/FLASH.md)。
* **不包含内核**：rootfs 与内核是两个仓库；换内核不影响 rootfs（`/lib/modules` 里的模块要跟着换）。
* **不含 Android 分区的东西**：只装 Debian 用户空间，不动 boot/vendor_boot/super 等分区。

## 七、许可

* 本仓库的脚本、配置、overlay 文件：**MIT**（见 [LICENSE](LICENSE)）。
* 装进镜像的 Debian 软件包：各自许可证，见 `packages.txt` 与各包的版权文件。
* 厂商固件、厂商内核模块：**不在本仓库**，也不随 Release 分发。
