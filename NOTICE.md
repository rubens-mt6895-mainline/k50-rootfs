# 许可与第三方内容

`LICENSE` 里的 MIT 只覆盖这个仓库自己的文件：`scripts/`、`config/`、`overlay/`、`image-mode/`、`.github/`。

其他东西各有来历：

* **Debian 软件包**：装进镜像的每个包保留自己的许可证，镜像里在 `/usr/share/doc/<包>/copyright`。
* **厂商固件**（WiFi / 蓝牙 / 触摸 / GPU 的 `.bin`、`.cfg`）：不在本仓库，构建时按 `config/config` 的
  `firmware_tarball` 从 [k50-firmware](https://github.com/rubens-mt6895-mainline/k50-firmware) 取。
  那批文件取自手机原厂系统，没有源码、也没有再分发许可，那边只是原样转载、不做权利主张；介意就别用带固件的镜像。
* **内核、板级 DTS、背光模块**：在 [k50-boot](https://github.com/rubens-mt6895-mainline/k50-boot)，GPL-2.0。
