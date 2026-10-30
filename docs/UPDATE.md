# 系统更新：镜像模式（换系统不丢数据）

> 结论：**能解决**。把系统做成「只读 squashfs 系统层 + `/data` 上的可写 overlay」，
> 更新 = 换一个 squashfs 文件 + 重启；起不来就切回上一个，`/data` 一个字节都没动。
> 一次性设置 + 首次重启验证即可启用，失败也不会变砖（任何异常都退回原来的普通启动）。

---

## 1. 为什么会有这个问题

现在换系统 = `zstd -d k50-rootfs-*.img.zst | dd of=/dev/sdc86`，也就是**整块 userdata 重写**：
系统文件、`/data`、`/images` 全都在这一个 ext4 分区里，刷镜像等于全丢。

实测盘面（2026-10-31 记录）：

| 项目 | 数值 |
|---|---|
| `/proc/partitions` | 91 个分区，**分区加总 ≈ 磁盘总容量**（只剩 64 KB 空隙） |
| 根分区 | `/dev/sdc86` ext4，225.6 G，`LABEL=k50rootfs`，已用 6.0 G |
| 系统占用 | `/usr` 2.9 G、`/var` 888 M、`/opt` 698 M、`/root` 1.5 G、`/home` 119 M |
| 内核能力 | `CONFIG_SQUASHFS=y`、`CONFIG_OVERLAY_FS=y`、`CONFIG_BLK_DEV_LOOP=y`，`losetup`/`pivot_root`/`dpkg-divert` 都在 |

所以「另分一个分区给更新用」= 得先离线缩容再建分区、还得重排分区表，**风险远大于收益**；
而且腾出来的空间本来就不够装第二份系统。

## 2. 三种方案对比

| 方案 | 做法 | 结论 |
|---|---|---|
| A. 独立分区 + A/B 双系统 | 缩容 `/dev/sdc86`、新建分区、grub 式切换 | **不选**：必须离线改分区表，分区号全变（fstab/脚本全要改），一次失败就丢数据 |
| B. 只读系统层 + overlay | squashfs 当系统层，改动落在 `/data` | **选它**：换系统只换一个文件，回滚 = 换回来，`/data` 不参与 |
| C. 就地 `apt upgrade` | 直接用 Debian 源升级 | 已有方案，和 B 不冲突；但改坏系统就只能进救援/重刷 |

## 3. 镜像模式怎么工作

```
内核 root=/dev/sdc86 (ext4) ─ 挂的是「引导层」
  └─ /sbin/init 被换成 /usr/local/lib/k50/pivot
       ├─ 读 /images/system-current.squashfs → 只读挂到 /var/lib/k50/ro
       ├─ /data/upper + /data/work → overlay 可写层
       ├─ 组装出完整系统到 /var/lib/k50/new
       └─ pivot_root 进新根 → exec 真正的 systemd
```

启动后的世界：

```
/                = overlay（下层 = 镜像里的文件，上层 = /data/upper）
/images          = 仍然是 /dev/sdc86 上的真目录（bind 进来）
/data            = 仍然是 /dev/sdc86 上的真目录（bind 进来）
/mnt/.oldroot    = 旧的引导层根（方便维护，systemd 之后会看到）
```

关键设计点：

* **用 `pivot_root` 而不是 `switch_root`**：`switch_root` 会删掉旧根里的文件，而
  `/images`、`/data` 就在旧根上 —— 用它会把镜像和数据一起删掉。
* **`/etc/fstab` 换成 `$DATA/fstab.image`**（去掉根分区那一行）：否则 systemd 会去挂
  `LABEL=k50rootfs`，和 overlay 抢 `/`。
* **只有 `/images/enabled` 存在才进镜像模式**：删掉这个文件就是普通启动。任何一步失败，
  pivot 会直接 `exec` 原来的 systemd —— 最坏情况只是「更新没生效」，不会变砖。
* **系统盘（ext4 根分区）与 `/data` 永远不被改写**：所以回滚、停用、维修都随时能做。

## 4. 一次性启用（在设备上跑）

```bash
# 1) 把镜像模式的脚本装进系统（从本仓库）
sudo install -m0755 image-mode/pivot        /usr/local/lib/k50/pivot
sudo install -m0755 image-mode/k50-image    /usr/local/sbin/k50-image

# 2) 先干跑一遍：打包第一个镜像 + 自检挂载，但不打开关
sudo ./scripts/enable-image-mode.sh --dry-run

# 3) 正式启用（会再自检一次，然后打上 /images/enabled）
sudo ./scripts/enable-image-mode.sh --yes

# 4) 重启并用 status 确认
sudo reboot
sudo k50-image status      # 应该显示「镜像模式（已 pivot …）」
```

`enable-image-mode.sh` 做的事：装 `pivot`/`k50-image` → 建 `/images`、`/data/{upper,work}` →
`mksquashfs` 把**当前正在跑的系统**打成第一个镜像（几分钟）→ 写 `$DATA/fstab.image` →
用 `dpkg-divert` 把 `/sbin/init` 换成 `pivot`（原文件存成 `/usr/sbin/init.systemd`）→
挂一次新镜像做自检 → 打上开关。

## 5. 日常更新

```bash
# 新镜像从 Release 下载后
scp k50-rootfs-trixie.squashfs k50:/tmp/
ssh k50 "sudo k50-image install /tmp/k50-rootfs-trixie.squashfs"
ssh k50 "sudo k50-image list"                     # 看时间戳、大小、哪个是「下次启动」
ssh k50 "sudo k50-image activate system-20261031-041500 && sudo reboot"

# 起不来（黑屏/卡 logo/反复重启）
ssh k50 "sudo k50-image rollback && sudo reboot"  # 旧系统原封不动
```

其它常用命令：

```bash
sudo k50-image status          # 当前是引导层还是镜像模式、下次用哪个、可写层多大、空间
sudo k50-image prune 3         # 只留 3 个镜像（被引用的那个永不删）
sudo k50-image diff 20         # 可写层改了哪些顶层目录、改了多少文件
sudo k50-image disable         # 停用（下次回普通启动；镜像和数据都还在）
sudo ./scripts/enable-image-mode.sh --revert   # 彻底撤回：还原 /sbin/init
sudo k50-image reset-upper     # 丢掉全部改动回到镜像原样（只能在引导层跑，会先备份）
```

## 6. 启用后建议立刻验证的四件事

1. `k50-image status` 显示「镜像模式」且只读层指向预期的镜像；
2. 改个文件 → 重启 → 改动还在（说明可写层生效）；
3. `k50-image disable && reboot` 能回到普通启动（说明退路通）；
4. `k50-image install` + `activate` + 重启能换系统，`rollback` 能切回。

## 6.5 实测记录（本机真实跑过的，含踩到的坑）

| 时间点 | 结果 |
| --- | --- |
| `--dry-run` | 通过：建 `/images` `/data`、搬 19 个厂商固件、打 1.94 GB 镜像、自检挂载全绿、不动 `/sbin/init` |
| 首次启用 + 重启 | 成功进镜像模式：`/` = overlay（lowerdir=`/var/lib/k50/ro`，upperdir=`/data/upper`），`/data`、`/images` 均可见 |
| 切到另一个镜像 + 重启 | **第一次失败** → 见下面的 index=off，修好后成功 |
| 回滚 + 重启 | 通过：切回上一个镜像，两个镜像都在，标记文件都还在 |

**另一个坑（已修）：镜像里不能带"源机器正在写的那份 journal"**

镜像模式跑起来后 `dmesg` 每隔半分钟刷一次：

```
overlayfs: failed to get inode (-116)
overlayfs: failed to look up (user-1000.journal) for ino (-116)      ← -116 = ESTALE
```

原因是系统镜像（squashfs）里带着构建时**正在写**的 `/var/log/journal/`
（`enable-image-mode.sh` 打的是"当前正在跑的系统"），开机后 journald 要往同名文件上做
copy-up，overlayfs 在只读层上解析这个文件就报 ESTALE，结果是**用户日志（user-1000.journal）
再也写不进去**。而且这份 journal 本来就是别人的历史日志，会一起打进镜像里发出去。

修法（两个脚本都已改）：

* `build-rootfs.sh` 清理段：`rm -rf /var/log/journal/*`、`/var/log/*.log*`、`wtmp/lastlog/btmp`；
  并且**同时换掉 `/etc/machine-id` 和 `/var/lib/dbus/machine-id`** —— 只清前者时 systemd 会沿用
  dbus 的那份 id，新系统仍然用旧 id，正好撞进镜像里那份旧 journal 目录。
* `enable-image-mode.sh` 与 `build-rootfs.sh` 的 `mksquashfs -e` 排除项都加上 `var/log/journal`
  等日志文件，双保险。

**踩到的坑：overlayfs 会校验「upper 根 origin = 当前 lower 根」**

第一次切镜像（lower 从镜像 A 换成镜像 B，`/data/upper` 保持不动）时挂载失败：

```
mount: /var/lib/k50/new: fsconfig() failed: Stale file handle.
overlayfs: "xino" feature enabled using 32 upper inode bits.
overlayfs: failed to verify upper root origin      ← 真正的原因
```

因为 overlayfs 默认（`index=on` 时）会把 upper 根的 `origin` xattr 和当前 lower 根比对，
我们故意换了 lower，比对失败就拒绝挂载。**修法：挂载时加 `index=off`**。
`image-mode/pivot` 里两处 overlay（系统层 + 固件层）都加了，实测换 lower 后 `rc=0` 正常挂载，
上层写的文件也还在（`/etc/k50-image-mode-test` 换镜像后仍可读）。

顺带验证了安全网真的有用：那次挂载失败后 `pivot` 自动 `exec` 了原 systemd，
设备照常起来（只是"更新没生效"），`/data` 和系统都没受损 —— 这就是"不会变砖"的实际样子。

## 6.6 换镜像后 SSH 进不去（主机密钥不跟着镜像走）

真机上换到「全新构建的镜像」后遇到过：SSH 端口能连上、但连接立刻被关闭、读不到 banner。
不是网络问题，是 **sshd 起不来**：

```
sshd: no hostkeys available -- exiting
```

原因有两层：

1. `build-rootfs.sh` 在清理阶段会删掉 `/etc/ssh/ssh_host_*`（**故意**的：不让镜像带上
   构建机/旧机器的身份，也是"可复现构建"的要求）；
2. 设备原有的主机密钥位于**旧镜像的只读层**里，换 lower 之后就"消失"了。

`authorized_keys` 同理：它在 `~k50/.ssh/` 里，属于私有数据，也不会进镜像。

现在的做法（**跟着数据走，不跟着镜像走**）：

| 位置 | 内容 | 谁维护 |
| --- | --- | --- |
| `/data/persist/etc-ssh/ssh_host_*` | 主机私钥（600） | `enable-image-mode.sh` 启用时存一份 |
| `/data/persist/authorized_keys` | 用户的授权公钥 | 同上；也可自己丢进去 |
| `usr/local/sbin/k50-ssh-keys.sh` | 恢复/生成/回写 | `k50-ssh-keys.service`（`Before=ssh.service`） |
| `image-mode/pivot` | 开机时先把密钥拷进新根 | 每次启动 |

因为 `/data` 在 ext4 引导层上、换镜像不动它，所以这之后**换多少次镜像 SSH 都不会再掉**。

老镜像（还没这套机制的）救急办法：在设备上跑

```sh
sudo ssh-keygen -A && sudo systemctl restart ssh
```

## 7. 注意与限制

* 内核/引导镜像（boot.img）不在镜像模式范围内 —— 换内核仍是刷 `/dev/sdc43`，见 `k50-boot` 仓库。
* 可写层会一直长大（apt 缓存、日志、你装的包都在里面）；`k50-image diff` 能看，`prune` 管的是镜像不是可写层。
* **厂商固件**（`/usr/lib/firmware` 下不属于任何 Debian 包的 `soc7_0_ram_*.bin`、
  `WIFI_RAM_CODE_*.bin`、`st_fts_L11a.ftb`、`mali_csffw.bin` 等）不会进这个仓库。
  启用镜像模式时 `enable-image-mode.sh` 会自动把它们复制到 `/data/firmware/`，
  开机时 `pivot` 把这一层叠在系统层**之上**（`/data/firmware` 优先、镜像里的 Debian 固件兜底），
  所以换镜像不会丢固件。以后加新固件直接放进 `/data/firmware/` 的对应路径即可。
* **squashfs 的压缩算法必须和内核匹配**。默认用 `gzip`（`config/config` 里的 `squashfs_comp`）：
  当前这台设备的内核只编进了 `CONFIG_SQUASHFS_ZLIB`，`xz`/`lzo`/`zstd` 全都没编，
  用 zstd 打出来的镜像挂载会直接失败：

  ```
  mount: /data/.selftest-ro: fsconfig() failed: Filesystem uses "zstd" compression. This is not supported.
  ```

  想要更小/更快的镜像，就在 `k50-boot` 仓的 `config/extra.config` 里打开
  `CONFIG_SQUASHFS_ZSTD=y`（工作流会自动 merge 进内核配置），重编内核刷进去之后
  再把这里的 `squashfs_comp` 改成 `zstd`。
  **实测对比**：同一份 rootfs，gzip 1.94 GB、zstd 1.80 GB，只差约 7%——所以不开也完全能用，
  别为了这点体积去冒险换内核配置。
  启用脚本的自检（第 6 步）会在真挂载时把这种不匹配挡下来，不会等到重启才发现。
* 首次启用前建议先备份：`dd if=/dev/sdc43 of=...`（boot_a）以及本仓库的 Release 镜像都能救命。

## 8. 和 k50-boot 的分工

| 仓库 | 管什么 | 更新方式 |
|---|---|---|
| `k50-rootfs`（本仓库） | 系统（Debian rootfs）、镜像模式 | 镜像模式下换 squashfs；或整块刷 `/dev/sdc86` |
| `k50-boot` | 内核、dtb、厂商 ramdisk（boot.img） | `dd of=/dev/sdc43` 或 fastboot |

两者互不影响：换系统不动内核，换内核不动系统 —— 所以出错时能明确定位是谁的问题。
