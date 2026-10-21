#!/bin/sh
# The shipped nginx site against foreign Host and Origin headers, with a stub Moonraker, in a throwaway container.
# Needs Docker.
set -eu
cd "$(dirname "$0")/.."
IMG=$(sed -n 's/^DEBIAN_IMAGE=//p' build/pins.env)   # the build container, by digest
docker run --rm -i --platform linux/amd64 -v "$PWD/overlay:/ov:ro" "$IMG" bash -eu <<'EOF'
apt-get update -qq >/dev/null; apt-get install -y -qq nginx-light curl python3 >/dev/null 2>&1
cd /etc/nginx && rm -f sites-enabled/default
cp /ov/etc/nginx/conf.d/* conf.d/ && cp /ov/etc/nginx/sites-available/mainsail sites-enabled/
mkdir -p /etc/kos /home/klipper/mainsail /var/log/nginx && echo mainsail > /home/klipper/mainsail/index.html
# what kos-config writes for a 63-character hostname and allowed_hosts= with a 253-character name, keywords, localhost
. /ov/usr/lib/kos/lib.sh
H63=$(printf 'h%.0s' $(seq 63)); L=$(printf 'a%.0s' $(seq 63)); F253=$L.$L.$L.$(printf 'b%.0s' $(seq 61))
valid_label "$H63" && valid_dnsname "$F253" && [ ${#F253} -eq 253 ]
hosts_map kos kos.local voron.lan "$H63" "$H63.local" "$F253" default include hostnames volatile localhost > /etc/kos/nginx-hosts.map
nginx -t && nginx
python3 -I -c '
import http.server
class H(http.server.BaseHTTPRequestHandler):
    def log_message(s, *a): pass
    def go(s): s.send_response(200); s.end_headers(); s.wfile.write(b"moonraker\n")
    do_GET = do_POST = go
http.server.HTTPServer(("127.0.0.1", 7125), H).serve_forever()' &
sleep 1
fail=0
t() { want=$1; shift; got=$(curl -s -o /dev/null -w '%{http_code}' "$@" || true)
      [ "$got" = "$want" ] && echo "ok   $got $*" || { echo "FAIL $got (want $want) $*"; fail=1; }; }
U=http://127.0.0.1
t 200 -H 'Host: kos.local' $U/
t 200 -H 'Host: KOS.local:80' $U/server/info
t 200 -H 'Host: kos' $U/server/info
t 200 -H 'Host: voron.lan' $U/server/info
t 200 -H 'Host: 192.168.1.50' $U/server/info
t 200 -H "Host: $H63.local" $U/server/info
t 200 -H "Host: $F253" $U/server/info
t 200 -H 'Host: default' $U/server/info
t 200 -H 'Host: include' $U/server/info
t 200 -H 'Host: localhost' $U/server/info
t 200 -H "Host: $H63" -H "Origin: http://$F253" $U/websocket
t 421 -H 'Host: evil.example.com' $U/
t 421 -H 'Host: kos.local.evil.com' $U/server/info
t 421 -H 'Host: 192.168.1.50.nip.io' $U/
t 403 -H 'Host: kos.local' -H 'Origin: http://evil.example.com' -X POST "$U/printer/gcode/script?script=M112"
t 403 -H 'Host: kos.local' -H 'Origin: http://203.0.113.5' -X POST "$U/printer/gcode/script?script=M112"
t 403 -H 'Host: kos.local' -H 'Origin: null' -X POST "$U/server/files/upload"
t 403 -H 'Host: kos.local' -H 'Origin: http://1' -X POST "$U/server/files/upload"   # "include 1;" read as a keyword would list "1"
t 403 -H 'Host: kos.local' -H 'Origin: http://evil.example.com' -H 'Upgrade: websocket' -H 'Connection: Upgrade' $U/websocket
t 200 -H 'Host: kos.local' -H 'Origin: http://kos.local' -X POST "$U/printer/gcode/script?script=G28"
t 200 -H 'Host: 192.168.1.50' -H 'Origin: http://192.168.1.50' -X POST $U/server/files/upload
t 200 -H 'Host: 192.168.1.50' -H 'Origin: http://voron.lan' $U/websocket
# slicers (Orca, PrusaSlicer) send no Origin
t 200 -H 'Host: kos.local' -X POST -F file=@/etc/hostname $U/server/files/upload
t 200 -H 'Host: 192.168.1.50' -X POST $U/api/files/local
t 200 -H 'Host: kos.local' $U/access/info
t 200 -H 'Host: kos.local' $U/machine/system_info
exit $fail
EOF
