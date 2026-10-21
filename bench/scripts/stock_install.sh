#!/bin/bash
# The "stock" baseline install for docs/benchmarks.md, scripted instead of clicked through KIAUH: what KIAUH runs underneath.
# Raspberry Pi OS Lite / Armbian minimal, fully updated, then Klipper (scripts/install-debian.sh), Moonraker
# (scripts/install-moonraker.sh), Mainsail + mainsail-config behind nginx the way Mainsail's docs set it up
# (access and error logs on, in /var/log/nginx). Pin to the KOS commits and import the config with stock_prep.sh after.
#   bash stock_install.sh        (as the printer user, passwordless sudo)
set -eux
export DEBIAN_FRONTEND=noninteractive   # apt waits for the lock: Moonraker's update manager runs apt right after it is installed
sudo apt-get -o DPkg::Lock::Timeout=600 update
sudo apt-get -o DPkg::Lock::Timeout=600 -y full-upgrade
sudo apt-get -o DPkg::Lock::Timeout=600 install -y git unzip curl

cd "$HOME"
[ -d klipper ] || git clone https://github.com/Klipper3d/klipper.git
# Klipper's own scripts/install-debian.sh is Python 2 (python-dev, gone in trixie) and install-ubuntu-22.04.sh writes a
# unit with no API socket, so like KIAUH: that script's Python 3 package list, a venv, and KIAUH's unit + env file.
sudo apt-get -o DPkg::Lock::Timeout=600 install -y virtualenv python3-dev libffi-dev build-essential libncurses-dev libusb-dev \
    avrdude gcc-avr binutils-avr avr-libc stm32flash dfu-util libnewlib-arm-none-eabi gcc-arm-none-eabi \
    binutils-arm-none-eabi libusb-1.0-0 pkg-config
[ -d klippy-env ] || virtualenv -p python3 klippy-env
klippy-env/bin/pip install -r klipper/scripts/klippy-requirements.txt
mkdir -p printer_data/{config,logs,comms,systemd,gcodes,database}
echo "KLIPPER_ARGS=\"$HOME/klipper/klippy/klippy.py $HOME/printer_data/config/printer.cfg -I $HOME/printer_data/comms/klippy.serial -l $HOME/printer_data/logs/klippy.log -a $HOME/printer_data/comms/klippy.sock\"" > printer_data/systemd/klipper.env
sudo tee /etc/systemd/system/klipper.service >/dev/null <<EOF
[Unit]
Description=Klipper 3D Printer Firmware SV1
Documentation=https://www.klipper3d.org/
After=network-online.target
Wants=udev.target

[Install]
WantedBy=multi-user.target

[Service]
Type=simple
User=$USER
RemainAfterExit=yes
WorkingDirectory=$HOME/klipper
EnvironmentFile=$HOME/printer_data/systemd/klipper.env
ExecStart=$HOME/klippy-env/bin/python \$KLIPPER_ARGS
Restart=always
RestartSec=10
EOF
sudo systemctl daemon-reload && sudo systemctl enable klipper

[ -d moonraker ] || git clone https://github.com/Arksine/moonraker.git
./moonraker/scripts/install-moonraker.sh

# Mainsail (docs.mainsail.xyz manual setup; KIAUH writes the same files)
sudo apt-get -o DPkg::Lock::Timeout=600 install -y nginx
T=$(mktemp -d)
mkdir -p mainsail && curl -fsSL https://github.com/mainsail-crew/mainsail/releases/latest/download/mainsail.zip -o "$T/mainsail.zip"
unzip -oq "$T/mainsail.zip" -d mainsail && rm -rf "$T"
[ -d mainsail-config ] || git clone https://github.com/mainsail-crew/mainsail-config.git
ln -sfn "$HOME/mainsail-config/mainsail.cfg" "$HOME/printer_data/config/mainsail.cfg"
chmod og+x "$HOME"   # what KIAUH does so nginx can reach ~/mainsail
printf 'upstream apiserver {\n    ip_hash;\n    server 127.0.0.1:7125;\n}\n' | sudo tee /etc/nginx/conf.d/upstreams.conf >/dev/null
printf 'map $http_upgrade $connection_upgrade {\n    default upgrade;\n    %s close;\n}\n' "''" | sudo tee /etc/nginx/conf.d/common_vars.conf >/dev/null
sudo tee /etc/nginx/sites-available/mainsail >/dev/null <<EOF
server {
    listen 80 default_server;
    access_log /var/log/nginx/mainsail-access.log;
    error_log /var/log/nginx/mainsail-error.log;
    gzip on;
    gzip_vary on;
    gzip_proxied any;
    gzip_proxied expired no-cache no-store private auth;
    gzip_comp_level 4;
    gzip_buffers 16 8k;
    gzip_http_version 1.1;
    gzip_types text/plain text/css text/xml text/javascript application/javascript application/x-javascript application/json application/xml;
    root $HOME/mainsail;
    index index.html;
    server_name _;
    client_max_body_size 0;
    proxy_request_buffering off;
    location / { try_files \$uri \$uri/ /index.html; }
    location = /index.html { add_header Cache-Control "no-store, no-cache, must-revalidate"; }
    location /websocket {
        proxy_pass http://apiserver/websocket;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_set_header Host \$http_host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_read_timeout 86400;
    }
    location ~ ^/(printer|api|access|machine|server)/ {
        proxy_pass http://apiserver\$request_uri;
        proxy_http_version 1.1;
        proxy_set_header Host \$http_host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Scheme \$scheme;
    }
}
EOF
sudo ln -sfn /etc/nginx/sites-available/mainsail /etc/nginx/sites-enabled/mainsail
sudo rm -f /etc/nginx/sites-enabled/default   # Debian's site is also default_server on :80
sudo nginx -t && sudo systemctl restart nginx
echo "stock install done"
