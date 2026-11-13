#!/usr/bin/env python3
"""One measurement interval against a running Sunlight SIP profile (it launches nothing).

usage: sample.py <seconds> <label> [fixture stats file]
Prints per-feed received/presented frames/s, banked/skipped windows, per-window streams on the
canvas, the fixture's draws/s (if its stats file is given), and `top` CPU over the interval.
"""
import json, os, re, subprocess, sys, time

SECONDS, LABEL = int(sys.argv[1]), sys.argv[2]
STATS = sys.argv[3] if len(sys.argv) > 3 else None
ST = os.path.expanduser("~/Library/Application Support/Sunlight SIP Redesign/redesign-session.json")

def status():
    try: return json.load(open(ST))
    except Exception: return {}

def feeds(s):
    return {f["display_id"]: f for f in s.get("bank", {}).get("feeds", [])}

def top(seconds, names):
    out = subprocess.run(["top", "-l", "2", "-s", str(seconds), "-stats", "pid,command,cpu"], capture_output=True, text=True).stdout
    cpu = {}
    for line in out.split("PID")[-1].splitlines():
        m = re.match(r"\s*(\d+)\s+(.+?)\s+([\d.]+)\s*$", line)
        if not m: continue
        for n in names:
            if m.group(2).startswith(n): cpu[n] = round(cpu.get(n, 0) + float(m.group(3)), 1)
    return cpu

t0, s0 = time.time(), status()
cpu = top(SECONDS, ["WindowServer", "Sunlight", "SunlightBankHo", "BankFixture"])
s1 = status()
f0, f1 = feeds(s0), feeds(s1)
rates = []
for d, f in sorted(f1.items()):
    if d in f0 and f["capture_seconds"] > f0[d]["capture_seconds"]:
        dt = f["capture_seconds"] - f0[d]["capture_seconds"]
        rates.append("display %s %.1f recv / %.1f shown fps (%sx%s px)" % (
            d, (f["frames_received"] - f0[d]["frames_received"]) / dt,
            (f["frames_presented"] - f0[d]["frames_presented"]) / dt, f["pixel_width"], f["pixel_height"]))
b = s1.get("bank", {})
windows = [w for c in s1.get("canvases", []) for w in c.get("windows", [])]
banked = {w["id"] for w in b.get("windows", [])}
own_streams = [w["id"] for w in windows if w.get("streaming") and w["id"] not in banked]
draws = None
if STATS and os.path.exists(STATS):
    rows = [json.loads(l) for l in open(STATS)]
    rows = [r for r in rows if r["t"] >= t0 + 1]
    if rows: draws = [round(sum(r["drawn"][i] for r in rows) / len(rows), 1) for i in range(3)]
print(f"[{LABEL}] feeds: {'; '.join(rates) or 'none'}")
print(f"[{LABEL}] banked {len(banked)}, per-window streams {len(own_streams)}, skipped {b.get('skipped')}, refused {b.get('refused')}")
print(f"[{LABEL}] fixture draws/s: {draws}  CPU %: {cpu}")
