#!/bin/bash
# Phase 1 benchmark (docs/plan.md §16.1), no printer motion. Same script on every image under test:
#   KOS | stock Raspberry Pi OS Lite / Armbian minimal + KIAUH | the same stock install with KOS's cmdline.txt tuning.
# Run on the printer host as the Klipper user, right after a cold boot, with the printer config loaded. Never on the
# first boot after flashing or importing: that one grows the partition, makes host keys and imports the config.
#   bash bench_on_device.sh <label>          e.g. kos, stock, stock-tuned
# Prints one JSON object and saves it to ~/bench-<label>-<time>.json. Repeat over several cold boots; compare medians.
# It sends nothing to Klipper. It does load the CPUs for a minute (stress-ng): run it with heaters off and nothing printing.
# Env: BENCH_IDLE=600 (SD-write idle window, s)  BENCH_LAT=60 (each latency run, s)  BENCH_FILES=1234 (fixture size, 0 = skip)
set -eu
LABEL=${1:?usage: bench_on_device.sh <label>}
IDLE=${BENCH_IDLE:-600}; LAT=${BENCH_LAT:-60}; NFILES=${BENCH_FILES:-1234}
PD=${PD:-$(ls -d "$HOME"/printer_data 2>/dev/null || ls -d /home/*/printer_data | head -1)}
API=http://127.0.0.1:7125
R=$(mktemp -d)   # one file per metric; assembled into JSON at the end
put() { printf '%s' "$2" > "$R/$1"; }
log() { echo "bench: $*" >&2; }

# --- context ---
put label "$LABEL"
put os "$(. /etc/os-release; echo "$PRETTY_NAME")"
put kernel "$(uname -r)"
put cmdline "$(cat /proc/cmdline)"
put governor "$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo unknown)"
put isolated "$(cat /sys/devices/system/cpu/isolated 2>/dev/null)"
put hw_model "$(tr -d '\0' < /proc/device-tree/model 2>/dev/null || echo unknown)"
put hw_ram_mb "$(awk '/MemTotal/ {print int($2 / 1024)}' /proc/meminfo)"
put hw_cpu_max_mhz "$(awk '{print $1 / 1000}' /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq 2>/dev/null || echo unknown)"
disk=$(lsblk -no PKNAME "$(findmnt -no SOURCE /)")   # the card the OS runs from (mmcblk0 or mmcblk1 depending on board)
sd=/sys/block/$disk/device
put hw_sd "$( [ -f $sd/manfid ] && echo "$disk $(cat $sd/name) manfid=$(cat $sd/manfid) oemid=$(cat $sd/oemid) date=$(cat $sd/date) $(( $(cat /sys/block/$disk/size) / 2097152 )) GiB" || echo "$disk")"
put hw_note "${BENCH_HW_NOTE:-}"   # what Linux cannot see: carrier board, MCUs, e.g. "BTT Manta M5P; Nitehawk 36 USB"
put klipper "$(git -C "$(dirname "$PD")/klipper" describe --always --tags 2>/dev/null || echo unknown)"
put mainsail "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$(dirname "$PD")/mainsail/release_info.json" 2>/dev/null || echo unknown)"
put moonraker "$(git -C "$(dirname "$PD")/moonraker" describe --always --tags 2>/dev/null || echo unknown)"

# --- boot: kernel+userspace from systemd, Klippy ready from Moonraker's log, both in seconds since power-on ---
put boot_systemd "$(systemd-analyze 2>/dev/null | head -1)"
# Klipper starts its once-a-second Stats timer on klippy:ready, stamped with CLOCK_MONOTONIC (seconds since kernel
# start). Wall-clock log times are useless here: these boards have no RTC battery and boot with a stale clock until NTP.
put klippy_ready_s "$(awk '/^===== Config file =====/ {r = ""} /^Stats [0-9.]+:/ && r == "" {r = $2; sub(":", "", r)} END {print (r == "" ? "null" : r)}' "$PD/logs/klippy.log" 2>/dev/null || echo null)"
state=$(curl -s "$API/printer/info" | python3 -c 'import json,sys; print(json.load(sys.stdin)["result"]["state"])' 2>/dev/null || echo unreachable)
put klippy_state "$state"
[ "$state" = ready ] || log "warning: Klippy is '$state', not ready; boot and latency numbers are still recorded"
# ext4 zeroes inode tables in the background after a fresh/grown filesystem; it would swamp the SD-write numbers.
pgrep -x ext4lazyinit >/dev/null && { put ext4lazyinit_running true; log "warning: ext4lazyinit still running, SD write numbers are not idle numbers"; }

# --- idle footprint, before this script installs anything (a rerun on the same install counts its tools and apt lists) ---
command -v cyclictest >/dev/null && put footprint_clean false || put footprint_clean true
put mem_used_mb "$(free -m | awk '/^Mem:/ {print $3}')"
put mem_available_mb "$(free -m | awk '/^Mem:/ {print $7}')"
put processes "$(ps -e --no-headers | wc -l)"
put services_running "$(systemctl list-units --type=service --state=running --no-legend | wc -l)"
put packages "$(dpkg-query -f '.\n' -W | wc -l)"
put rootfs_used_mb "$(df -m --output=used / | tail -1 | tr -d ' ')"

# --- SD writes: average since boot, then an idle window ---
wsect() { awk -v d="$disk" '$3 == d {print $10}' /proc/diskstats; }
up=$(cut -d' ' -f1 /proc/uptime)
put sd_write_mb_per_h_since_boot "$(awk -v s="$(wsect)" -v u="$up" 'BEGIN {printf "%.1f", s * 512 / 1048576 / u * 3600}')"
if [ "$IDLE" -gt 0 ]; then
    log "idle ${IDLE}s for the SD write window"
    w0=$(wsect); sleep "$IDLE"; w1=$(wsect)
    put sd_write_mb_per_h_idle "$(awk -v d=$((w1 - w0)) -v t="$IDLE" 'BEGIN {printf "%.1f", d * 512 / 1048576 / t * 3600}')"
fi

# --- scheduling latency where Klippy runs: its own CPU affinity and policy (SCHED_OTHER), idle and under load ---
command -v cyclictest >/dev/null && command -v stress-ng >/dev/null ||
    { sudo apt-get update -qq >/dev/null && sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq rt-tests stress-ng >/dev/null; }   # KOS ships without apt lists
kpid=$(pgrep -f 'klippy/klippy.py' | head -1 || true)
cpus=$( [ -n "$kpid" ] && taskset -cp "$kpid" | awk -F': ' '{print $2}' || echo "0-$(($(nproc) - 1))")
put klippy_cpus "$cpus"
lat() {   # $1 = name; histogram in µs, summarised to p50/p99/p99.9/max
    # shellcheck disable=SC2024  # the user writes the results file; only cyclictest needs root
    sudo cyclictest -q -m --policy=other -p 0 -a "$cpus" -t 1 -i 1000 -D "$LAT" -h 20000 > "$R/$1.hist" 2>/dev/null
}
log "latency, idle (${LAT}s)"; lat lat_idle
log "latency, all cores loaded by stress-ng (${LAT}s)"
stress-ng --cpu "$(nproc)" --vm 1 --vm-bytes 256M --io 1 -t "$((LAT + 5))s" >/dev/null 2>&1 & spid=$!
sleep 2; lat lat_load; wait "$spid" || true

# --- Moonraker: directory listing on a realistic library, and event-loop blocks while it runs ---
if [ "$NFILES" -gt 0 ]; then
    F="$PD/gcodes/kos-bench"
    mkdir -p "$F"
    log "writing $NFILES-file gcode fixture to $F"
    python3 - "$F" "$NFILES" <<'PY'
import base64, os, struct, sys, zlib
d, n = sys.argv[1], int(sys.argv[2])
def png(w=48, h=48):   # small real PNG, like a slicer thumbnail
    raw = b"".join(b"\x00" + b"".join(bytes((x * 5 % 256, y * 5 % 256, 128)) for x in range(w)) for y in range(h))
    c = lambda t, b: struct.pack(">I", len(b)) + t + b + struct.pack(">I", zlib.crc32(t + b))
    return b"\x89PNG\r\n\x1a\n" + c(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)) + c(b"IDAT", zlib.compress(raw)) + c(b"IEND", b"")
t = base64.b64encode(png()).decode()
thumb = "; thumbnail begin 48x48 %d\n%s\n; thumbnail end\n" % (len(t), "\n".join("; " + t[i:i + 78] for i in range(0, len(t), 78)))
body = "".join("G1 X%d Y%d E%.3f F3000\n" % (i % 200, (i * 7) % 200, i * 0.01) for i in range(400))
for i in range(n):
    with open(os.path.join(d, "bench_%04d.gcode" % i), "w") as f:
        f.write("; generated by PrusaSlicer 2.8.1+linux-x64 on 2026-01-01 at 00:00:00 UTC\n" + thumb + "G28\n" + body +
                "; estimated printing time (normal mode) = 1h 2m 3s\n; filament used [mm] = 1234.56\n"
                "; layer_height = 0.2\n; first_layer_height = 0.2\n; filament_type = PLA\n")
PY
    log "waiting for Moonraker to index the fixture"
    for _ in $(seq 120); do
        c=$(curl -s "$API/server/files/directory?path=gcodes/kos-bench" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["result"]["files"]))' 2>/dev/null || echo 0)
        [ "$c" -ge "$NFILES" ] && break; sleep 1
    done
    # Metadata extraction runs one file at a time (~8/s on a CM5, slower on a CB1): wait until every file has it,
    # or the listing is timed against a half-empty database and deleting the fixture makes Moonraker log a traceback
    # for every file still queued.
    # Poll one file's metadata, not the folder: a full extended listing during extraction makes Moonraker misread
    # the extractor's output ("msgspec.DecodeError: Input data was truncated") and requeue that file.
    t0=$(date +%s)
    count() { curl -s "$API/server/files/directory?path=gcodes/kos-bench&extended=true" |
        python3 -c 'import json,sys; print(sum("estimated_time" in f for f in json.load(sys.stdin)["result"]["files"]))' 2>/dev/null || echo 0; }
    last=$(printf 'kos-bench/bench_%04d.gcode' $((NFILES - 1)))
    for _ in $(seq 900); do
        curl -s "$API/server/files/metadata?filename=$last" | grep -q estimated_time && break; sleep 2
    done
    for _ in $(seq 60); do m=$(count); [ "$m" -ge "$NFILES" ] && break; sleep 10; done   # stragglers that were requeued
    put moonraker_metadata_s "$(( $(date +%s) - t0 ))"
    put moonraker_metadata_files "$m"
    [ "$m" -ge "$NFILES" ] || log "warning: only $m of $NFILES files got metadata; listing times are not comparable"
    sleep 5
    b0=$(grep -ac 'EVENT LOOP BLOCKED' "$PD/logs/moonraker.log" || true)
    for i in 1 2 3 4 5; do
        curl -s -o /dev/null -w '%{time_total}\n' "$API/server/files/directory?path=gcodes/kos-bench&extended=true"
    done > "$R/dir_times"
    b1=$(grep -ac 'EVENT LOOP BLOCKED' "$PD/logs/moonraker.log" || true)
    put moonraker_loop_blocked "$((b1 - b0))"
    rm -rf -- "$F"   # only the fixture this run created
fi

# --- assemble ---
python3 - "$R" "$HOME/bench-$LABEL-$(date +%Y%m%d-%H%M%S).json" <<'PY'
import glob, json, os, statistics, sys
r, out = sys.argv[1], sys.argv[2]
res = {}
for p in sorted(glob.glob(r + "/*")):
    k = os.path.basename(p); v = open(p).read().strip()
    if k.endswith(".hist"):
        hist = {}; mx = None
        for ln in v.splitlines():
            if ln[:1].isdigit():
                us, c = ln.split()[:2]; hist[int(us)] = int(c)
            elif ln.startswith("# Max Latencies"):
                mx = int(ln.split(":")[1].split()[0])
        tot = sum(hist.values())
        def pct(q):
            acc = 0
            for us in sorted(hist):
                acc += hist[us]
                if acc >= q * tot:
                    return us
            return None
        res[k[:-5]] = {"samples": tot, "p50_us": pct(.5), "p99_us": pct(.99), "p999_us": pct(.999), "max_us": mx}
    elif k == "dir_times":
        t = [float(x) for x in v.split()]
        res["moonraker_get_directory_s"] = {"first": t[0], "median_warm": statistics.median(t[1:]), "all": t}
    else:
        try:
            res[k] = json.loads(v)
        except ValueError:
            res[k] = v
json.dump(res, open(out, "w"), indent=1)
print(json.dumps(res, indent=1))
print("saved " + out, file=sys.stderr)
PY
