# 刷机、备份与回滚（Xiaomi Redmi K50 / rubens）

本文件所有分区号都是在 K50 上实测的（`lsblk -o NAME,SIZE,FSTYPE,LABEL,PARTLABEL,MOUNTPOINT`）。
换机型请勿照抄。

---

## 一、分区表（实测）

| 设备节点 | 大小 | 文件系统 / 卷标 | 内容 |
| --- | --- | --- | --- |
| `/dev/sdc43` | 64 MiB | — | `boot_a`：Android 格式 boot 镜像（内核 + 厂商 ramdisk），**k50-boot 仓库的产物刷这里** |
| `/dev/sdc44` | — | — | `vendor_boot_a` |
| `/dev/sdc45` | — | — | `dtbo_a` |
| `/dev/sdc77` | 8.5 GiB | — | `super`（动态分区，Android 侧的东西） |
| `/dev/sdc83` | 2 GiB | erofs，`cust` | 厂商定制分区（原厂 MIUI 的残留） |
| `/dev/sdc84` | 128 MiB | ext4，`rescue` | 救援分区 |
| `/dev/sdc86` | 225.6 GiB | ext4，`LABEL=k50rootfs` | **userdata = 根文件系统（本仓库的镜像刷这里）** |

> 用 `findmnt -no SOURCE /` 可以在运行中的系统上确认自己的根分区到底是哪个。

## 二、刷 rootfs

镜像是 ext4 的**整盘镜像**（含分区内的文件系统，不是分区表），所以要写到 userdata 分区节点本身。

### 方式 A：fastboot（推荐，不用先有一个能跑的系统）

```bash
zstd -d k50-rootfs-trixie.img.zst -c > k50-rootfs-trixie.img

# 手机：关机 → 音量减 + 电源 进 fastboot，或 adb reboot bootloader
fastboot devices
fastboot flash userdata k50-rootfs-trixie.img
fastboot reboot
```

### 方式 B：从另一个已启动的系统 dd

```bash
# 压缩包直接在设备上解，省一次传输
zstd -d k50-rootfs-trixie.img.zst -c | dd of=/dev/sdc86 bs=4M oflag=direct status=progress
sync
```

> **不要**在根文件系统正挂载在 `/dev/sdc86` 上的时候往它写 —— 会当场把系统写坏。
> 要么走 fastboot，要么先启动到别的系统/救援环境里再 dd。

### 刷完第一次开机

```bash
sudo resize2fs /dev/sdc86     # 镜像被 resize2fs -M 收缩过，先扩满分区
passwd                        # 初始密码是公开的 k50，立刻改
```

## 三、刷内核（k50-boot 仓库的产物）

```bash
fastboot flash boot_a boot-<sha>.img
```

或者系统里直接写（boot 分区不在运行时挂载，可以热写）：

```bash
dd if=boot-<sha>.img of=/dev/sdc43 bs=1M status=progress
```

**内核和 rootfs 互相独立**：换内核不用重刷 rootfs；换 rootfs 不用重刷内核。
但 `/lib/modules/<内核版本>` 里的模块要跟着内核版本走（背光模块 `k50_bl.ko` 尤其要注意 vermagic 是否匹配）。

## 四、备份与回滚

**先备份，再动手。** 至少要备 boot 与 userdata：

```bash
# 在设备上（root）：备份到 PC
dd if=/dev/sdc43 bs=1M status=progress | ssh 用户@你的PC 'cat > boot_a.bak.img'

# userdata 体积大（225 G），建议只备关键目录：/etc、/home、/usr/local
tar -C / -cf - etc home/k50/.local usr/local | ssh 用户@你的PC 'cat > userdata-etc.tar'
```

回滚：

```bash
fastboot flash boot_a boot_a.bak.img
fastboot flash userdata userdata.bak.img
```

## 五、厂商固件（必须自己补）

镜像里**没有**任何厂商二进制固件（版权原因，也不随 Release 分发）。缺了它们表现为：
WiFi 起不来、蓝牙哑、触摸无反应、外放/振动异常。

完整清单很短（本机 `/lib/firmware` 一共才 3.1 MB），从你自己正在用的设备上拷：

```bash
# 在旧系统上打包（3.1 MB，直接整个 /lib/firmware 拿走最省事）
tar -C /lib/firmware -czf - . | ssh 用户@你的PC 'cat > fw.tar.gz'

# 在新系统上解包
sudo tar -C /lib/firmware -xzf fw.tar.gz
```

关键文件（本机实测存在）：

| 文件 | 用途 |
| --- | --- |
| `WIFI_RAM_CODE_soc7_0_1b_t_1.bin` | WiFi 固件主体 |
| `soc7_0_ram_bt_1b_t_1_hdr.bin` | 蓝牙固件 |
| `soc7_0_ram_wmmcu_1b_t_1_hdr.bin` / `soc7_0_ram_mcu_1b_t_1_hdr.bin` | 连接子系统 / MCU 固件 |
| `BT_FW.cfg` / `wifi.cfg` / `conninfra.cfg` | 蓝牙 / WiFi / 连接框架配置 |
| `st_fts_L11a.ftb` | 触摸（FTS）固件 |
| `novatek_nt36672e_l16_fw0{1,2}.bin` | 另一块屏（L16）的触摸固件，本机不用但放着无妨 |
| `tfa98xx.cnt` | 音频功放校准 |
| `arm/mali/arch10.8/mali_csffw.bin` | Mali GPU 固件 |
| `mediatek/` | MTK 其它固件（整目录拷走即可） |

拷完重启，`sudo dmesg | grep -iE "firmware|wlan|bt"` 确认没有 `Direct firmware load ... failed`。

> **开了镜像模式的话**：更推荐放到 `/data/firmware/`（镜像模式下 `pivot` 会把它叠在
> `/usr/lib/firmware` 之上，换镜像不会丢）；放 `/lib/firmware` 也行（会写进可写层，
> 上新镜像时旧副本会盖住新镜像里的同名文件，一般也正是你要的效果）。

## 六、常见问题

| 现象 | 原因 / 处理 |
| --- | --- |
| 开机 kernel panic，找不到根文件系统 | `image_label` 与 `overlay/etc/fstab` 的 `LABEL=` 不一致。`blkid /dev/sdc86` 看实际卷标；`config/config` 里改 `image_label` 重构建，或手改 fstab |
| 系统起来但屏幕全黑 | 内核缺少面板的两个补丁（见 k50-boot 的 `patches/0001`、`0002`），或 boot.img 刷错分区 |
| `apt` 报 `certificate verify failed` | 时间不对（K50 无 RTC）。`sudo systemctl restart systemd-timesyncd; sleep 5` 再试 |
| WiFi 扫不到 AP | 厂商固件没拷 / `wireless-regdb` 没装 |
| 蓝牙能开但连不上 | 厂商固件没拷（`soc7_0_ram_bt_*_hdr.bin`、`BT_FW.cfg`）；再看 `systemctl status k50-bt-agent` |
| GNOME 里没有亮度滑块 | `k50_bl.ko` 没装：从 k50-boot 的 Release 取模块放到 `/usr/local/lib/k50/`，`systemctl start k50-backlight` |
| 触摸没反应 | 缺 `st_fts_L11a.ftb`，或内核里 FTS 触摸驱动没编进去（k50-rubens_defconfig 已含） |
| 屏幕熄灭后点不亮 | 内核面板补丁不全（`patches/0002` 是「熄屏只发显示命令、不断电源」） |
