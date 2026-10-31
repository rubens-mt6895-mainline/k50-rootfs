# ============================================================
#  overlay/ —— 直接覆盖进 rootfs 根目录的文件树
#  构建脚本执行 `cp -a overlay/. $ROOT/`，所以这里的路径就是最终路径。
#
#  两条硬规矩（2026-10-31 真机/构建发现）：
#   1. 这里只放真正要进系统的文件。这份说明原来就放在 overlay/ 里，
#      结果被装成了镜像根目录的 /README.md —— 现已移到 docs/OVERLAY.md。
#   2. `cp -a dir/.` 会把 dir 自身（以及 overlay 里与系统同名的 usr/、home/、etc/）
#      的属主与权限一起盖到目标上；在 NTFS/drvfs 上就是 0777 + 构建用户，
#      等于让镜像的 `/` 世界可写。build-rootfs.sh 拷完会按 overlay 目录清单纠正。
# ============================================================

本目录下的内容会按原样复制到 rootfs 的 `/`：

```
etc/fstab                       LABEL=k50rootfs → / ，必须与 config/config 的 image_label 一致
etc/hostname                    k50-linux（config/config 的 hostname 会覆盖它）
etc/bluetooth/main.conf         配对/可发现/GATT 缓存等 K50 上的必要参数
etc/gdm3/daemon.conf            GDM 自动登录 k50（Wayland）
etc/dconf/…                     GNOME 系统级默认值（熄屏时间、软键盘等）
etc/modules-load.d/k50-backlight.conf   开机自动 modprobe k50_bl
etc/systemd/system/k50-*.service|timer  K50 专属单元（电源键、蓝牙、背光）
usr/local/sbin/k50-*.py|sh      K50 专属脚本（电源键守护、蓝牙回连、LE 初始化）
usr/local/sbin/bt_agent.py      蓝牙配对代理（NoInputNoOutput，自动接受）
usr/local/lib/k50/README.txt    /usr/local/lib/k50 用途说明（k50_bl.ko 会装在这里）
home/k50/.local/share/gnome-shell/extensions/…  两个自写 GNOME 扩展
```

## 不在这里的东西

* 内核与 `boot.img` → 见 k50-boot 仓库
* `k50_bl.ko` → 由 k50-boot 的 Release 提供，装到 `/usr/local/lib/k50/`
* 厂商固件（WiFi/蓝牙/触摸）→ 版权原因不能进 git，见 `docs/FLASH.md`
* 任何带隐私的东西（WiFi 密码、蓝牙 bond、SSH 私钥、machine-id）→ 从零构建天然没有

## 改动要点

* 加单元：放 `etc/systemd/system/x.service`，再到 `scripts/build-rootfs.sh` 的
  `enable` 列表里加一行。
* 加 dconf 默认值：`etc/dconf/db/local.d/00-k50` 加 key，然后
  `etc/dconf/db/local` 会在构建时被重新编译（`dconf update` 在 chroot 里跑）。
* 脚本权限：`usr/local/sbin/*.py|*.sh` 构建时会被 `chmod +x`。
* `/home/k50` 下的文件构建时会 `chown -R 1000:1000`。
