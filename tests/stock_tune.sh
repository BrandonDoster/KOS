#!/bin/bash
# Apply KOS's realtime tuning to a stock install that stock_prep.sh already set up, for the "stock-tuned" benchmark run.
# Copied from KOS, nothing else: the kernel args KOS boots with, Klippy pinned to the isolated core at the priority KOS
# gives it, and peripheral IRQs steered off that core (overlay/usr/lib/kos/kos-tune, passed as $1).
# Not copied, on purpose: logs in RAM, zram, the trimmed service set, masked timers, DRM blacklist. Those are the base
# image, which is what "KOS" vs "stock-tuned" measures.
#   bash stock_tune.sh ./kos-tune     then cold-boot (pull power) before benchmarking.
set -eu
TUNE=${1:?usage: stock_tune.sh <path to kos-tune>}
ARGS="isolcpus=3 cpufreq.default_governor=performance video=HDMI-A-1:d"   # build/boards/*/: same args on CM5 and CB1

if [ -f /boot/firmware/cmdline.txt ]; then            # Raspberry Pi OS
    f=/boot/firmware/cmdline.txt
    grep -q isolcpus= "$f" || sudo sed -i "1 s|\$| $ARGS|" "$f"
elif [ -f /boot/armbianEnv.txt ]; then                 # Armbian (CB1)
    f=/boot/armbianEnv.txt
    if grep -q '^extraargs=' "$f"; then
        grep -q isolcpus= "$f" || sudo sed -i "s|^extraargs=.*|& $ARGS|" "$f"
    else
        echo "extraargs=$ARGS" | sudo tee -a "$f" >/dev/null
    fi
else
    echo "no cmdline.txt or armbianEnv.txt found" >&2; exit 1
fi
echo "kernel args: $(grep -h -o 'isolcpus=.*' "$f")"
# Raspberry Pi OS: raspberrypi-sys-mods' udev rule sets every core to ondemand after boot, overriding
# cpufreq.default_governor. A same-named rule in /etc masks it. (KOS does not install raspberrypi-sys-mods.)
if [ -f /usr/lib/udev/rules.d/60-ondemand-governor.rules ]; then
    echo 'KERNEL=="cpu*", SUBSYSTEM=="cpu", ATTR{cpufreq/scaling_governor}="performance"' |
        sudo tee /etc/udev/rules.d/60-ondemand-governor.rules >/dev/null
    echo "masked raspberrypi-sys-mods' ondemand governor rule"
fi
# Armbian / BTT CB1: cpufrequtils applies GOVERNOR= from this file at boot, overriding the kernel arg the same way.
if [ -f /etc/default/cpufrequtils ] && grep -q '^GOVERNOR=' /etc/default/cpufrequtils; then
    sudo sed -i 's|^GOVERNOR=.*|GOVERNOR=performance|' /etc/default/cpufrequtils
    echo "cpufrequtils: GOVERNOR=performance"
fi

# klipper.service as KOS ships it (overlay/etc/systemd/system/klipper.service)
sudo mkdir -p /etc/systemd/system/klipper.service.d
printf '[Service]\nCPUAffinity=3\nNice=-18\nIOSchedulingPriority=2\n' | sudo tee /etc/systemd/system/klipper.service.d/kos-tune.conf >/dev/null

sudo install -m 0755 "$TUNE" /usr/local/sbin/kos-tune
printf '[Unit]\nDescription=KOS tuning: IRQ affinity\nAfter=systemd-udev-settle.service\nBefore=klipper.service\n\n[Service]\nType=oneshot\nExecStart=/usr/local/sbin/kos-tune\n\n[Install]\nWantedBy=multi-user.target\n' |
    sudo tee /etc/systemd/system/kos-tune.service >/dev/null
# Armbian's armbian-hardware-optimize forks prepare_board, which puts sunxi-mmc and eth on cpu3 (echo 8) after
# kos-tune may already have run. A second pass 30 s after boot wins that race without delaying klipper.service.
if [ -x /usr/lib/armbian/armbian-hardware-optimization ]; then
    printf '[Unit]\nDescription=KOS tuning: IRQ affinity again after armbian-hardware-optimize\n\n[Timer]\nOnBootSec=30s\nUnit=kos-tune.service\n\n[Install]\nWantedBy=timers.target\n' |
        sudo tee /etc/systemd/system/kos-tune.timer >/dev/null
fi
sudo systemctl daemon-reload && sudo systemctl enable kos-tune
[ -f /etc/systemd/system/kos-tune.timer ] && sudo systemctl enable kos-tune.timer
echo "done; cold-boot before benchmarking"
