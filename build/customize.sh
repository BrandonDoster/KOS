#!/bin/bash
# Runs chrooted inside the fresh rootfs (mmdebstrap customize hook). $1 = board. Board-specific part is
# /tmp/board/customize.sh, sourced at the end. Everything here is arm64-neutral Debian.
set -euxo pipefail
export DEBIAN_FRONTEND=noninteractive LANG=C.UTF-8
BOARD=$1
. /tmp/board/board.sh
. /tmp/pins.env   # build/pins.env: upstream revisions and checksums; in-container.sh checked its shape

# --- user ---
id klipper >/dev/null 2>&1 || useradd -m -u 1000 -U -s /bin/bash -G sudo,dialout,tty,video,plugdev klipper   # user first so gid 1000 = klipper
chmod 0711 /home/klipper   # trixie HOME_MODE is 0700; nginx (www-data) must traverse to ~/mainsail
groupadd -f moonraker-admin && usermod -aG moonraker-admin klipper
passwd -l root
usermod -p '*' klipper   # locked until kos.conf sets password=; tty1 autologin and SSH keys still work, su/serial login do not
chmod 0440 /etc/sudoers.d/klipper
: > /etc/machine-id
echo kos > /etc/hostname   # else the build container's id leaks in until kos-config runs

# --- board (first: fails fast, before the slow venv step) ---
. /tmp/board/customize.sh

# --- klipper / moonraker / mainsail as real git checkouts (PLAN §12) ---
# At the pinned commits, but still on their branch (reset, not checkout), so Moonraker's update manager updates them.
H=/home/klipper
sudo -u klipper -H bash -eux <<EOF
cd $H
git clone --single-branch https://github.com/Klipper3d/klipper.git && git -C klipper reset --hard $KLIPPER_COMMIT
git clone --single-branch https://github.com/Arksine/moonraker.git && git -C moonraker reset --hard $MOONRAKER_COMMIT
python3 -m venv --system-site-packages klippy-env
klippy-env/bin/pip install --no-cache-dir --prefer-binary -r klipper/scripts/klippy-requirements.txt
python3 -m venv --system-site-packages moonraker-env
moonraker-env/bin/pip install --no-cache-dir --prefer-binary -r moonraker/scripts/moonraker-requirements.txt
mkdir -p mainsail && curl -fsSL https://github.com/mainsail-crew/mainsail/releases/download/$MAINSAIL_VERSION/mainsail.zip -o /tmp/mainsail.zip
echo "$MAINSAIL_ZIP_SHA256  /tmp/mainsail.zip" | sha256sum -c -
unzip -q /tmp/mainsail.zip -d mainsail
git clone --single-branch https://github.com/mainsail-crew/mainsail-config.git && git -C mainsail-config reset --hard $MAINSAIL_CONFIG_COMMIT
mkdir -p printer_data
EOF
# Klipper compiles chelper on first start; do it now so first boot is faster and gcc is proven to work.
sudo -u klipper -H $H/klippy-env/bin/python -c "import sys; sys.path.insert(0, '$H/klipper/klippy'); import chelper; chelper.get_ffi()" || true
# Klipper's Linux host MCU for [mcu host] (PLAN §15). ~5 s native on CM5; kos-config starts it only when a config uses it.
sudo -u klipper -H bash -eux <<EOF
cd $H/klipper && printf 'CONFIG_MACH_LINUX=y\n' > /tmp/linux-mcu.config
make KCONFIG_CONFIG=/tmp/linux-mcu.config OUT=/tmp/linux-mcu/ olddefconfig
make -j\$(nproc) KCONFIG_CONFIG=/tmp/linux-mcu.config OUT=/tmp/linux-mcu/
EOF
install -m 0755 /tmp/linux-mcu/klipper.elf /usr/local/bin/klipper_mcu
install -m 0644 $H/klipper/scripts/klipper-mcu.service /etc/systemd/system/klipper-mcu.service
# Moonraker's speedups / component deps that need a local build (optional, best effort)
sudo -u klipper -H $H/moonraker-env/bin/pip install --no-cache-dir --prefer-binary "msgspec==$PIP_MSGSPEC_VERSION" "uvloop==$PIP_UVLOOP_VERSION" || true

# --- services ---
rm -f /etc/nginx/sites-enabled/default   # Debian's site is also default_server on :80
ln -sf /etc/nginx/sites-available/mainsail /etc/nginx/sites-enabled/mainsail
ln -sf /usr/lib/kos/kos-mcu-discover /usr/local/bin/kos-mcu-discover
ln -sf /usr/lib/kos/kos-archive /usr/local/bin/kos-archive
ln -sf /usr/lib/kos/kos-ssh-key /usr/local/bin/kos-ssh-key
mkdir -p /config /var/lib/kos
systemctl enable systemd-networkd kos-config kos-tune kos-mcu-discover klipper moonraker nginx avahi-daemon ssh NetworkManager zramswap kos-trash-purge.timer kos-tune.timer kos-security-updates.timer
# PLAN §16.8: appliance, not a workstation
systemctl mask apt-daily.timer apt-daily-upgrade.timer e2scrub_all.timer man-db.timer fstrim.timer systemd-networkd-wait-online.service
# NetworkManager owns everything except CAN, which systemd-networkd owns (PLAN §9)
cat > /etc/NetworkManager/conf.d/unmanaged-can.conf <<EOF
[keyfile]
unmanaged-devices=interface-name:can*
EOF
echo "LANG=C.UTF-8" > /etc/default/locale
# IPv6 is off (ipv6.disable=1 on both boards' kernel command line, docs/plan.md §11): nothing should try to use it.
sed -i 's/^use-ipv6=yes$/use-ipv6=no/' /etc/avahi/avahi-daemon.conf && grep -qx 'use-ipv6=no' /etc/avahi/avahi-daemon.conf
chmod 0600 /etc/NetworkManager/system-connections/kos-ethernet.nmconnection   # NetworkManager ignores keyfiles others can read
# No resolv.conf in the image (in-container.sh drops the build host's): NetworkManager writes it when it is missing.

# --- trim (PLAN §4): docs, man pages, apt lists, pip caches; SSH host keys (every printer makes its own, ssh.service.d) ---
find /usr/share/doc /usr/share/man /usr/share/info -mindepth 1 -delete 2>/dev/null || true
apt-get clean
find /var/lib/apt/lists -type f -delete
find /home/klipper -name '__pycache__' -type d -prune -exec sh -c 'find "$1" -delete' _ {} \; 2>/dev/null || true
rm -rf /home/klipper/.cache
rm -f /etc/ssh/ssh_host_*
du -sx / 2>/dev/null || true
