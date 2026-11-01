# k50-rootfs

[![build-rootfs](https://github.com/rubens-mt6895-mainline/k50-rootfs/actions/workflows/build-rootfs.yml/badge.svg)](https://github.com/rubens-mt6895-mainline/k50-rootfs/actions/workflows/build-rootfs.yml)
[![release](https://img.shields.io/github/v/release/rubens-mt6895-mainline/k50-rootfs?include_prereleases)](https://github.com/rubens-mt6895-mainline/k50-rootfs/releases)
[![downloads](https://img.shields.io/github/downloads/rubens-mt6895-mainline/k50-rootfs/total)](https://github.com/rubens-mt6895-mainline/k50-rootfs/releases)

小米 Redmi K50（rubens / MT6895）跑 mainline Linux 用的 Debian rootfs。
从 Debian 官方包**从零构建**，构建全部由 GitHub Actions 完成，产物以 Release 发布；
触摸 / WiFi / 蓝牙的厂商固件已预置进镜像（原样取自
[k50-firmware](https://github.com/rubens-mt6895-mainline/k50-firmware)）。内核不在本仓库，
内核与 boot 镜像在 [k50-boot](https://github.com/rubens-mt6895-mainline/k50-boot)。

## 下载

到 [Releases](https://github.com/rubens-mt6895-mainline/k50-rootfs/releases) 下载最新的 `ci-*`：

| 文件 | 说明 |
|---|---|
| `k50-rootfs-trixie.img.zst` | ext4 根文件系统镜像（已收缩），**新安装刷这一个** |
| `k50-rootfs-trixie.tar.zst` | 同内容的 tar 包 |
| `k50-rootfs-trixie.squashfs` | 镜像模式的系统层（更新包，用法见下方「镜像模式」） |
| `packages.txt` | 系统已安装的软件包 |
| `BUILD.txt` | 构建参数与烧写命令 |
| `SHA256SUMS.txt` | 校验和 |
| `firstlogin.txt` | 默认密码（务必记得修改） |

烧写（设备上，root；`/dev/sdc86` 是 userdata，为保证安全，请用 `findmnt -no SOURCE /` 确认）：

```bash
zstd -d k50-rootfs-trixie.img.zst -c | dd of=/dev/sdc86 bs=4M oflag=direct status=progress
sync
```

镜像已经**预置好镜像模式**：第一次开机就以引导层为只读下层跑在 overlay 上，之后所有改动
都写进 `/data/upper`（可写层）；分区也会被自动扩满（`k50-growfs.service`）。所以既不需要
手工 `resize2fs`，也不需要先"启用镜像模式"。

## 首次登陆

| | |
|---|---|
| Hostname | `k50-linux` |
| Username | `k50` |
| Password | **构建时随机生成**（16 位，写在 Release 附件的 `firstlogin.txt` 里，登录后立刻 `passwd` 改掉） |

桌面通过 GDM **自动登录**：开机直接进桌面，不需要密码。
本地构建可以用 `PASSWORD=xxx sudo -E ./scripts/build-rootfs.sh` 指定。

## 构建参数

改 `config/config` 后 push 到自己的 fork，Actions 会重新构建（也支持手动
`workflow_dispatch`，可临时改 `suite` / `image_size_gib` / `extra_packages`）。
本地构建（arm64 主机直接跑；x86_64 需要装 `qemu-user-static` + `binfmt-support` 跨架构，速度慢很多）：

```bash
# 依赖：mmdebstrap e2fsprogs rsync zstd tar（要 squashfs 再加 squashfs-tools；
#       非 Debian 宿主还要 debian-archive-keyring）
sudo ./scripts/build-rootfs.sh            # 产物在 work/out/
sudo SUITE=bookworm IMAGE_SIZE_GIB=16 EXTRA_PACKAGES=vim,git ./scripts/build-rootfs.sh
sudo OUTPUTS=img,tar ./scripts/build-rootfs.sh   # 只出部分产物（默认 img,tar,squash）
```

| 参数 | 默认 | 说明 |
|---|---|---|
| `suite` | `trixie` | Debian 13；`bookworm` = 12 |
| `image_size_gib` | `8` | 构建后自动收缩到实际大小；刷完首开由 `k50-growfs.service` 自动扩满 |
| `image_label` | `k50rootfs` | 必须与 overlay 里 `/etc/fstab` 的 `LABEL=` 一致 |
| `hostname` / `username` | `k50-linux` / `k50` | |
| `password` | 空 = 随机 | 见上节 |
| `timezone` | `Asia/Shanghai` | |
| `extra_packages` | 空 | 逗号分隔，追加在 `config/packages.list` 之后 |
| `firmware_tarball` | k50-firmware 归档 | 镜像里的厂商固件来源；留空 = 不带 |
| `squashfs_comp` | `gzip` | 镜像模式的系统层压缩；必须与内核 `CONFIG_SQUASHFS_*` 一致 |
| `keep_releases` | `8` | 旧的 `ci-*` Release 自动清理 |

CI 用 `ubuntu-24.04-arm`（公开仓库免费）。参数含义的完整注释在 `config/config`，
烧写与固件细节见 [docs/FLASH.md](docs/FLASH.md)。

## 系统升级（镜像模式）

镜像**出厂就已经在镜像模式里**：`/` 是 overlay，只读下层先是引导层本身、装上第一个
系统镜像后是那个 squashfs，所有改动都在 `/data/upper`。因此更新系统 = 放一个新 squashfs
进 `/images` 再 `activate` + 重启，`/data` 原样不动；新系统起不来就 `rollback`：

```bash
sudo k50-image install /tmp/k50-rootfs-trixie.squashfs   # 也可以直接给 URL
sudo k50-image activate system-<时间戳> && sudo reboot
# 起不来：开机进得去就 sudo k50-image rollback && sudo reboot
```

`scripts/enable-image-mode.sh` 是给**已经装好的普通系统**补上镜像模式用的（先把当前系统
打成第一个 squashfs 当 lower），全新刷入的 img 不需要它。

## 首次开机

1. 桌面已经自动登录。想用密码登录（tty/ssh）时用 `firstlogin.txt` 里的口令，首次登录会被
   强制改密（`chage -d 0`）；改密后一切照旧（GDM 自动登录不受影响）。
2. WiFi：`nmtui`（镜像里不预置任何 WiFi 口令）。
3. 分区扩容自动做（`k50-growfs.service`），`df -h /` 应看到接近 225 G 的容量。
4. 触摸 / WiFi / 蓝牙固件已在镜像里（来自 k50-firmware），开箱可用；想换成自己 dump 的一份见 [docs/FLASH.md](docs/FLASH.md)。
5. 背光：安装 [k50-boot](https://github.com/rubens-mt6895-mainline/k50-boot) 里的 `k50_bl.ko`（放 `/usr/local/lib/k50/`），`sudo systemctl start k50-backlight`。
6. K50 没有 RTC：联网后 systemd-timesyncd + fake-hwclock 几秒内对时；apt 报证书错误通常是时间不对，重启 timesyncd 即可。

## 已知限制

- 没有 RTC（fake-hwclock + NTP 对时）。
- 厂商固件（触摸/WiFi/蓝牙）在 [k50-firmware](https://github.com/rubens-mt6895-mainline/k50-firmware)：原样转载，无源码、无授权；介意就别用，自己 dump 一份（见 docs/FLASH.md）。
- 内核与 `boot.img` 在 [k50-boot](https://github.com/rubens-mt6895-mainline/k50-boot)，两个仓库配合使用。

## 许可

本仓库的脚本、配置与 overlay：MIT（见 [LICENSE](LICENSE)）；
Debian 包各自的许可证不变（清单见 `packages.txt`）。
装进镜像的厂商固件来自 [k50-firmware](https://github.com/rubens-mt6895-mainline/k50-firmware)，那批文件没有许可，细节见 [NOTICE.md](NOTICE.md)。

## Related links

- [k50-boot](https://github.com/rubens-mt6895-mainline/k50-boot) — mainline 内核与 boot 镜像
- [rubens-mt6895-mainline/linux](https://github.com/rubens-mt6895-mainline/linux) — 内核分支 `7.2-mt6895-xiaomi-rubens`
- [k50-camera](https://github.com/rubens-mt6895-mainline/k50-camera) / [goodix-ta](https://github.com/rubens-mt6895-mainline/goodix-ta) — 相机 / 指纹（不工作）移植
