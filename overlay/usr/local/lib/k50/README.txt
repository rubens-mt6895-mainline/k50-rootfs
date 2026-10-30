k50_bl.ko —— 把 l11a 面板的 DCS 0x51 亮度包装成标准 /sys/class/backlight/l11a
源码与构建: D:\K50-Debian\kernel-modules\k50-bl\ (外部模块, 用 /home/luis/work/k50-ccci 构建)
重新编译: wsl -d Ubuntu -u root -- bash -lc "cd /home/luis/work/k50-bl-src && make ARCH=arm64 LLVM=1 -j8"
回滚: systemctl disable --now k50-backlight; rm /etc/modules-load.d/k50-backlight.conf; rm /lib/modules/$(uname -r)/extra/k50_bl.ko; depmod -a; rmmod k50_bl
