#!/usr/bin/env python3
"""Phase 2 print summary from klippy.log (docs/benchmarks.md). Reads the last print, between 'Starting SD card print' and
'Exiting SD card print', and prints JSON: timer errors, shutdowns, stalls, sysload, Klippy CPU, buffer time, and per
MCU round-trip time, retransmits and load. Same parser for every install, so the numbers compare.

Usage: python3 print_stats.py ~/printer_data/logs/klippy.log      Self-test: python3 print_stats.py --test
"""
import json, re, statistics, sys


def field(line, mcu, key):
    seg = line
    if mcu:
        m = re.search(r"(?:^| )" + re.escape(mcu) + r": (.*?)(?= [\w]+: |$)", line)
        if not m:
            return None
        seg = m.group(1)
    m = re.search(r"\b" + key + r"=([-\d.e]+)", seg)
    return float(m.group(1)) if m else None


def summ(vals, scale=1.0):
    v = sorted(x * scale for x in vals if x is not None)
    if not v:
        return None
    return {"median": round(statistics.median(v), 4), "p99": round(v[int(len(v) * .99)], 4), "max": round(v[-1], 4)}


def delta(stats, mcu, key):
    v = [field(l, mcu, key) for l in stats]
    v = [x for x in v if x is not None]
    return v[-1] - v[0] if len(v) > 1 else None


def analyse(text):
    lines = text.split("\n")
    s = max(i for i, l in enumerate(lines) if l.startswith("Starting SD card print"))
    e = next(i for i in range(s, len(lines)) if lines[i].startswith("Exiting SD card print"))
    sec = lines[s:e + 1]
    stats = [l for l in sec if l.startswith("Stats ")]
    t = [float(l.split()[1].rstrip(":")) for l in stats]
    dur = t[-1] - t[0]
    mcus = sorted({m for l in stats for m in re.findall(r" (\w+): mcu_awake=", l)})
    out = {
        "print_section_lines": len(sec),
        "print_section_bytes": sum(len(l) + 1 for l in sec),
        "stats_samples": len(stats),
        "duration_s": round(dur, 1),
        "timer_too_close": sum("Timer too close" in l for l in sec),
        "mcu_shutdowns": sum(bool(re.search(r"MCU '?\w+'? shutdown|Lost communication with MCU", l)) for l in sec),
        "print_stall": delta(stats, None, "print_stall"),
        "sysload": summ(field(l, None, "sysload") for l in stats),
        "klippy_cputime_s": round(delta(stats, None, "cputime"), 1),
        "buffer_time_s": summ(field(l, None, "buffer_time") for l in stats),
        "memavail_kb": summ(field(l, None, "memavail") for l in stats),
        "soc_temp_max_c": max((float(x) for l in stats for x in re.findall(r"SoC: temp=([\d.]+)", l)), default=None),
        "mcus": {},
    }
    out["klippy_log_mb_per_h"] = round(out["print_section_bytes"] / 1e6 / (dur / 3600), 2)
    out["klippy_cpu_pct_of_one_core"] = round(100 * out["klippy_cputime_s"] / dur, 2)
    for m in mcus:
        out["mcus"][m] = {
            "srtt_ms": summ((field(l, m, "srtt") for l in stats), 1000),
            "rttvar_ms": summ((field(l, m, "rttvar") for l in stats), 1000),
            "bytes_written": delta(stats, m, "bytes_write"),
            "bytes_retransmit": delta(stats, m, "bytes_retransmit"),
            "mcu_awake": summ(field(l, m, "mcu_awake") for l in stats),
        }
    return out


def test():
    st = lambda t, load, cpu, br: (f"Stats {t}: gcodein=0 mcu: mcu_awake=0.2 bytes_write={int(t*100)} bytes_retransmit={br} "
                                  f"srtt=0.002 rttvar=0.001 nh: mcu_awake=0.01 bytes_write={int(t*10)} bytes_retransmit=0 "
                                  f"srtt=0.001 rttvar=0.000 SoC: temp=50.0 print_time=1 buffer_time=1.2 print_stall=0 "
                                  f"sysload={load} cputime={cpu} memavail=1000")
    log = "\n".join(["Starting SD card print (position 0)", st(10.0, 0.1, 1.0, 0), "echo: x", st(11.0, 0.5, 1.5, 3),
                     st(12.0, 0.2, 2.0, 3), "Exiting SD card print (position 9)"])
    r = analyse("Starting SD card print (position 0)\nExiting SD card print (position 1)\n" + log)   # last print wins
    assert r["stats_samples"] == 3 and r["duration_s"] == 2.0, r
    assert r["klippy_cputime_s"] == 1.0 and r["sysload"]["max"] == 0.5, r
    assert set(r["mcus"]) == {"mcu", "nh"} and r["mcus"]["mcu"]["bytes_retransmit"] == 3 and r["mcus"]["mcu"]["srtt_ms"]["median"] == 2.0, r
    assert r["timer_too_close"] == 0 and r["soc_temp_max_c"] == 50.0
    print("ok")


if __name__ == "__main__":
    if "--test" in sys.argv:
        test()
    else:
        print(json.dumps(analyse(open(sys.argv[1], errors="replace").read()), indent=1))
