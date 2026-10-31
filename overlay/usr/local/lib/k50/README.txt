k50_bl.ko —— 把 l11a 面板的 DCS 0x51 亮度包装成标准 /sys/class/backlight/l11a
源码: k50-boot 仓库的 kernel-modules/k50-bl/ 目录（Release 里附的 k50_bl.ko 由它编出）
重新编译: make -C <内核源码树> ARCH=arm64 LLVM=1 M=<k50-boot>/kernel-modules/k50-bl modules
        （内核树与其 .config 必须与当前运行内核对应，见 k50-boot 的 kernel_ref / defconfig）
回滚: systemctl disable --now k50-backlight; rm /etc/modules-load.d/k50-backlight.conf; rm /lib/modules/$(uname -r)/extra/k50_bl.ko; depmod -a; rmmod k50_bl
