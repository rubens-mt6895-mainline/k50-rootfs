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

> **新镜像不用做这一步。** CI 打出来的 `.img` 出厂就已经预置镜像模式（`/images/enabled`
> 在位、`/usr/sbin/init` → `pivot`、`/data/{upper,work,fstab.image}` 都建好了），第一次开机
> 直接进 **FIRSTBOOT 模式**：还没有任何系统镜像，pivot 把**引导层自己**绑定挂载成只读下层，
> `/data/upper` 照旧当可写层 —— 用户的改动从第一分钟起就落在可写层里，之后
> `k50-image activate` 换成真正的 squashfs 时一个字节都不会带走。
> 下面这一节适用于"已经装好的普通系统想补上镜像模式"的老机器。

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


## 6.5 常见问题

<details>
<summary><b>Q：开机后 dmesg 没完没了地刷 <code>overlayfs: failed to look up (user-1000.journal)</code>，用户日志再也写不进去？</b></summary>

镜像带了打包时**正在写**的 `/var/log/journal/`。journald 要在只读层上对同名文件做 copy-up，
overlayfs 解析它时报 ESTALE（-116），`user-1000.journal` 从此写不进去；别人的历史日志还会
一起打进镜像发出去。

修法：`build-rootfs.sh` 清理段删 `/var/log/journal/*`、`/var/log/*.log*`、`wtmp/lastlog/btmp`，
并且**同时换掉 `/etc/machine-id` 和 `/var/lib/dbus/machine-id`** —— 只换前者，systemd 会沿用
dbus 那份 id，正好又撞进镜像里那份旧 journal 目录。`mksquashfs -e` 的排除项再加
`var/log/journal`，双保险。

</details>

<details>
<summary><b>Q：换 lower 之后挂载失败，报 <code>Stale file handle</code> / <code>failed to verify upper root origin</code>？</b></summary>

overlayfs 默认会把 upper 根的 `origin` xattr 和当前 lower 根比对。我们故意换了 lower，
比对必然失败，于是拒绝挂载。

修法：挂载时加 `index=off`。`image-mode/pivot` 里两处 overlay（系统层和固件层）都加了。

这一步失败不影响开机：`pivot` 会直接 `exec` 原来的 systemd，设备照常起来，只是"更新没生效"，
`/data` 和系统都没受损 —— 这就是"不会变砖"的实际样子。

</details>

<details>
<summary><b>Q：跑 <code>enable-image-mode.sh --yes</code> 必定死在自检，报「镜像里缺 <code>/usr/local/sbin/k50-image</code>」？</b></summary>

脚本先 `mksquashfs` 打镜像、**之后**才 `install` 这两个文件，所以第一份镜像里永远没有它们。
设备上看不出来，是因为之前跑过、`/usr/local/sbin/` 已有残留，把这个顺序错误盖住了。

修法：把安装（含 `dash -n` 语法校验）提到打镜像之前（step 2c）。

</details>

<details>
<summary><b>Q：自检说镜像里缺文件，可新镜像明明有？</b></summary>

自检对象取的是 `system-current`，也就是**上一次**在用的老镜像。

修法：自检对象改成刚打出来的那个镜像，取不到才退回 `system-current`，并打印
「自检对象：<名字>」。

</details>

<details>
<summary><b>Q：出厂预置镜像模式下开机，<code>pivot</code> 自我重入、叠出好几层 overlay，GDM 和 <code>user@1000</code> 全起不来？</b></summary>

`pivot` 结尾原来是 `exec chroot . /sbin/init`，而预置镜像模式把 `/sbin/init` divert 成了
`pivot` 自己 —— 于是无限自我重入，内核报 `overlayfs: maximum fs stacking depth exceeded`。
老系统碰不到，因为那里的 `/sbin/init` 仍是 `../lib/systemd/systemd`。

修法：改成 `exec chroot . "$REAL_INIT"`（`REAL_INIT=/usr/lib/systemd/systemd`），并在代码里
注明**绝对不要**写回 `/sbin/init`。

</details>

<details>
<summary><b>Q："已经在我们自己的 overlay 里就直接交 systemd"的守卫从来没生效？</b></summary>

`/proc/mounts` 把全部挂载选项塞在 `$4` 一个字段里
（`rw,relatime,lowerdir=…,upperdir=/data/upper,workdir=…`），而守卫写的是
`for(i=4;i<=NF;i++) if (index($i,u)==1)`，要求"某个字段以 `upperdir=/data/upper,` 开头"，
永远匹配不上。

修法：按逗号 `split($0,a,",")` 切开、逐 token 精确比对，命中时打印「已经在镜像模式的根里…」。

</details>

<details>
<summary><b>Q：<code>k50-growfs.service</code> 是 active 的，什么都不做，日志只写「/overlay 不是块设备，跳过」？</b></summary>

镜像模式下 `findmnt -no SOURCE /` 返回的是 `overlay`，脚本又对它做了 `readlink -f`，
变成 `/overlay`，`[ -b ]` 判否，直接跳过。

修法：`find_root_dev()` 按 `/ → /data → /images → /mnt/.oldroot` 顺序试
`findmnt -no SOURCE --target`，只接受 `/dev/*` 形状再 `readlink -f` + `[ -b ]`，
找不到就打「找不到根设备，跳过」。

</details>

<details>
<summary><b>Q：设备已经卡在坏掉的 overlay 里，往 <code>/usr/local/lib/k50/</code> 写文件报 ENOENT/EEXIST，怎么改引导层本体？</b></summary>

写 overlay 上层失败是坏挂载的直接后果；而 `/data/..` 也救不了你 —— bind 挂载的 `..`
会解析回合并根，又被坏 overlay 拒绝。

唯一可靠的是 `findmnt` 里那个 device-backed 挂载点（本次是 `/mnt/.oldroot/mnt/.oldroot`，
源 `/dev/sdc86`），直接往那里 `cp` 才改得动本体。

</details>

<details>
<summary><b>Q：换镜像后 SSH 端口能连上、但立刻被关闭，读不到 banner？</b></summary>

不是网络问题，是 sshd 起不来：`sshd: no hostkeys available -- exiting`。
`build-rootfs.sh` 会故意删掉 `/etc/ssh/ssh_host_*`（不让镜像带上构建机/旧机器身份），
而设备原有的主机密钥在旧镜像的只读层里，换 lower 之后就"消失"了。

修法是让密钥跟着数据走，不跟着镜像走：

| 位置 | 内容 | 谁维护 |
| --- | --- | --- |
| `/data/persist/etc-ssh/ssh_host_*` | 主机私钥（600） | `enable-image-mode.sh` 启用时存一份 |
| `/data/persist/authorized_keys` | 用户的授权公钥 | 同上；也可自己丢进去 |
| `usr/local/sbin/k50-ssh-keys.sh` | 恢复/生成/回写 | `k50-ssh-keys.service`（`Before=ssh.service`） |
| `image-mode/pivot` | 开机时先把密钥拷进新根 | 每次启动 |

`/data` 在 ext4 引导层上、换镜像不动它，所以这之后换多少次镜像 SSH 都不会再掉。

老镜像（还没这套机制的）救急：

```sh
sudo ssh-keygen -A && sudo systemctl restart ssh
```

</details>

<details>
<summary><b>Q：换镜像后 Wi-Fi 列表空白，所有网络都要重新输密码？</b></summary>

`/etc/NetworkManager/system-connections/*.nmconnection` 原本只存在于引导层。换成 squashfs
当 lower 后，新根的 `/etc` 来自镜像，里面没有这些文件；而可写层里若存在 0 字节的同名文件，
它会把下层那份完好的 profile **盖住**，NM 读出空 psk，于是像新设备一样问密码。

别在 activate 阶段去"搬"这些 profile：合并视图里 `stat` 一个被 0 字节文件盖住的文件会返回
**错误的大小**（说有内容、`read` 出来 0 字节），照抄就把好文件清成 0 字节，越更新越坏。

现在的做法：`pivot` 在 `pivot_root` **之前**（此时 `/` 还是引导层真 ext4，读到的一定是原件）
把非空的 `*.nmconnection` 播种到 `/data/persist/nm`（只补缺、不覆盖、幂等），删掉其中的
0 字节垃圾，再把 `$DATA/persist/nm` bind 到新根的 `/etc/NetworkManager/system-connections`。
换任何 lower 都不影响，仓库里也不带任何口令。

</details>

<details>
<summary><b>Q：换镜像后 Wi-Fi/BT 起不来，日志 <code>Direct firmware load for soc7_0_ram_wmmcu_1b_t_1_hdr.bin failed with error -2</code>？</b></summary>

厂商 ramdisk 里的 `CINIT` 按**裸文件名**把 MTK 固件拷到 `/lib/firmware` 顶层
（`soc7_0_ram_wmmcu_1b_t_1_hdr.bin`、`WIFI_RAM_CODE_soc7_0_1b_t_1.bin`、`st_fts_L11a.ftb` 等），
设备自己生成的 `mediatek/mt6895/WIFI`（NVRAM）、`BT_Addr` 也只落在引导层。首开模式
（lower 就是引导层）看得到，换成 squashfs 之后就找不到了，Wi-Fi bring-up 死在这一步。

现在的做法：pivot 在挂固件叠加层之前，用 `cp -a -n /usr/lib/firmware/. $DATA/firmware/`
把当前根的整份固件预置到 `/data/firmware`（只补缺、不覆盖，一次即可、之后持久），
再照旧拿它当固件叠加层的第一 lower。

</details>

<details>
<summary><b>Q：换镜像后 <code>/root/.ssh/authorized_keys</code> 没了，公钥进不去？</b></summary>

镜像里本来就没有它（属于私有数据，不进仓库也不进镜像）。pivot 现在会在 `pivot_root` 之前
依次从 `$DATA/persist/authorized_keys`、可写层、引导层找现成的公钥补进新根
（只在新根里没有或为空时才补）。

</details>

<details>
<summary><b>Q：<code>k50-image activate</code> 拒绝切换，说镜像里没有 <code>k50-image</code>，可镜像明明带着？</b></summary>

假拒绝，`set -euo pipefail` 造成的。原来写的是：

```bash
unsquashfs -l "$1" 2>/dev/null | grep -qE '/usr/local/sbin/k50-image$' && return 0
```

`grep` 一命中就退出，`unsquashfs` 收到 SIGPIPE（rc=141），`pipefail` 把整条管道判成失败 ——
于是"有工具"被判成"没工具"。对任何镜像都拒，所以看起来像"这镜像不合格"。

统一改法（仓库内已全改）：

- `| grep -q X` → `| grep -c X >/dev/null`（读完再判）
- `| head -1` / `| head -n1` → `| sed -n '1p'`（读完再取）
- `| head -n N` → `| sed -n "1,${N}p"`
- 要「第一个匹配行」→ 用单个 `awk`（一个进程，没有管道）

修好之后的行为才是设计意图的：没有 `k50-image` 的镜像被拒绝，`system-current` 不动；
自拍快照正常切换。

</details>

## 6.6 外放没声音、GNOME 里没有亮度滑块

### 症状

* 声音设置里只有一个「内置音频 · 模拟耳机」，无论怎么调都没声（耳机也没插）。
* GNOME 里根本没有亮度滑块，`/sys/class/backlight/` 是空目录。

### 声音：这张卡有两个 PCM 播放设备，PipeWire 只认了第一个

`aplay -l` 会看到 `Playback_1`（device 0）和 `Playback_2`（device 2）。真机实测：

* device 0 = **耳机通路**
* device 2 = **扬声器通路**：DL2 → I2S3 → TFA9874 智能功放 → 喇叭
  （播放时 dmesg 出 `mt6895_fe_trigger(), DL2 cmd 1`、`tfa98xx_tfa_start() … return (0)`，
  功放 `speaker_amp 6-0034/6-0035` 是内核里的 `[goodix]` 版驱动，工作正常）

没有 UCM 定义时 PipeWire 只认 device 0，于是系统声音全被送到耳机，耳机没插 → 静音。
**修法**：仓库带两份 ALSA UCM2 文件（`overlay/usr/share/alsa/ucm2/…`），把 device 2
暴露成一个独立的「Speaker」输出；功放开关 `Ext_Speaker_Amp Switch` 在 UCM 的
`EnableSequence` 里打开。装上后 `wpctl status` 会同时列出
`内置音频 Headphones` 与 `内置音频 Speaker`，默认输出切到 Speaker 即可。

### 亮度：镜像里没带 `k50_bl.ko`

这块面板没有 `/sys/class/backlight`，亮度只能经 `mtkfb_set_backlight_level()` 下发。
`k50_bl.ko` 是 boot 仓编出来的**外部模块**，vermagic 必须与内核逐字一致，所以只能在
构建时从内核 CI 的 release 取（`scripts/build-rootfs.sh` 的「4d. 取 k50_bl.ko」，
可用 `K50_KO_URL` 覆盖 URL）。取不到只是没有亮度滑块，系统照常启动：
`k50-backlight.service` 有 `ConditionPathExists=/usr/local/lib/k50/k50_bl.ko`，会安静地跳过。

真机验证：把 `k50_bl.ko` 放进 `/usr/local/lib/k50/` 后重启该服务 → `/sys/class/backlight/l11a`
出现（`brightness` 2047 / `max_brightness` 2047），GNOME 亮度滑块可用。

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

## 9. 日常更新：从「自己这套系统」打快照（`k50-image snapshot`）

镜像模式的更新循环应该是**同一套系统往前走**，而不是换一套陌生系统：

```bash
# 1) 先在当前系统里把要做的事做完（apt upgrade、改配置、装东西……）
sudo apt update && sudo apt full-upgrade

# 2) 把"现在跑的这套系统"打成新镜像（排除挂载点/缓存/journal，不会把当前只读层套进来）
sudo k50-image snapshot                    # → /images/system-<UTC 时间戳>.squashfs
# 也可以指定名字： sudo k50-image snapshot before-升级.squashfs

# 3) 切过去 + 重启；起不来就 rollback
sudo k50-image activate system-<那个时间戳> && sudo reboot
```

为什么强调"自己这套"：换 lower 时，旧系统里**没被改过**的文件会新镜像同名文件被遮住。
如果新镜像是从零构建的另一套系统，用户看到的就是"我的系统被换掉了"。
`snapshot` 打出来的是当前系统的合并视图（只读层 + 可写层里被改过的文件），换上去视觉上
几乎无感 —— 这正是"更新"该有的样子。

几个细节：

* 压缩默认 `gzip`（这台内核只有 gzip 的 squashfs 解压支持）；想试 zstd 用
  `K50_SQUASH_COMP=zstd sudo k50-image snapshot`，但**内核没编 `CONFIG_SQUASHFS_ZSTD` 就会挂不上**。
* `/data`、`/images`、`/var/lib/k50/{ro,new}`、`/var/log/journal`、apt 缓存、
  `/root/k50rf-*` 都在排除列表里；镜像里不会出现"上一层的副本"。
* 快照会**保留** `/etc/ssh/ssh_host_*`（当前系统里有），所以换到快照镜像后 SSH 不会掉 ——
  `k50-ssh-keys` 那套机制是给"从零构建、不带主机密钥"的镜像兜底的。
* 快照体积 ≈ 系统实际占用再压一把（本机 3.5 GB `/usr` → 约 1.3 GB 镜像），
  `/images` 空间不够时先 `k50-image prune`。

## 6.9 音量上键按了没反应（2026-11-01 真机定位，两层）

现象：按音量上完全没反应；音量下能上报但系统里也没反应。

**第一层（用户态）：GNOME 没绑这两个键。** 镜像里
`org.gnome.settings-daemon.plugins.media-keys volume-up = ['']`、
`volume-down = ['']`（默认应该是 `['XF86AudioRaiseVolume']` / `['XF86AudioLowerVolume']`），
所以按键即便上报了也没人处理。新增 `k50-volkeys.service` +
`/usr/local/sbin/k50-volkeys.py`：监听所有输入设备，把
`KEY_VOLUMEUP`(115) / `KEY_VOLUMEDOWN`(114) 按下转成
`wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%±`（以 uid 1000 身份调用户的 PipeWire）。

**第二层（内核态）：音量上的物理键根本没上报。** 这颗 PMIC（MT6363）的
TOPSTATUS 寄存器里，两个键的电平极性是**相反的**：

| 键 | 位 | 空闲 | 按下 |
|---|---|---|---|
| PWRKEY（电源） | bit1 | 1 | 0（active-low） |
| HOMEKEY（音量上） | bit3 | 0 | 1（active-high） |

`drivers/input/misc/mtk-spmi-keys.c` 原来对两位都按 active-low 判定，
于是按住音量上时被判成"松开"，内核不上报 `KEY_VOLUMEUP`。真机抓包可证：
按住时内核日志在 `TOPSTATUS = 0x16` / `0x1e` 之间跳（bit3 在变），
但 evdev 上一个事件都没有。

修法在 boot 仓
`patches/0003-input-misc-mtk-spmi-keys-fix-home-key-polarity.patch`
（顺带补 400 ms 释放宽限：PMIC 在事件后约 185 ms 就清状态位，
30 ms 轮询会把"按住"上报成连点）。
