#!/usr/bin/env python3
"""Frame-rate breakdown for the window bank, without touching anyone's real windows.

Phases: Sunlight off (fixture on the physical display), then Sunlight on with only
the fixture banked: animated, then paused (SIGUSR1). Each phase reports the
fixture's actual draws/s, the bank feed's received/presented frames/s, and
WindowServer / Sunlight / fixture CPU from `top` over the same interval.

usage: phases.py <fixture binary> <work dir> [--env K=V ...] [extra Sunlight args...]
"""
import json, os, re, signal, subprocess, sys, time

FIXTURE, WORK = sys.argv[1], sys.argv[2]
ENV, EXTRA, rest = [], [], sys.argv[3:]
while rest:
    if rest[0] == "--env": ENV += ["--env", rest[1]]; rest = rest[2:]
    else: EXTRA.append(rest.pop(0))
APP = os.path.expanduser("~/Applications/Sunlight Canvas Lab.app")
ST = os.path.expanduser("~/Library/Application Support/Sunlight SIP Redesign/redesign-session.json")
IDS, STATS = os.path.join(WORK, "ids.json"), os.path.join(WORK, "ids.json.stats")

def status():
    try: return json.load(open(ST))
    except Exception: return {}

def feeds():
    return {f["display_id"]: f for f in status().get("bank", {}).get("feeds", [])}

def top(seconds, names):
    out = subprocess.run(["top", "-l", "2", "-s", str(seconds), "-stats", "pid,command,cpu"], capture_output=True, text=True).stdout
    last = out.split("PID")[-1]   # second sample: CPU over the interval
    cpu = {}
    for line in last.splitlines():
        m = re.match(r"\s*(\d+)\s+(.+?)\s+([\d.]+)\s*$", line)
        if not m: continue
        for n in names:
            if m.group(2).startswith(n): cpu[n] = cpu.get(n, 0) + float(m.group(3))
    return cpu

def draws(since):
    rows = [json.loads(l) for l in open(STATS)] if os.path.exists(STATS) else []
    rows = [r for r in rows if r["t"] >= since]
    if not rows: return None
    return [round(sum(r["drawn"][i] for r in rows) / len(rows), 1) for i in range(3)], round(sum(r["ticks"] for r in rows) / len(rows), 1)

def phase(name, seconds=6):
    t0, f0 = time.time(), feeds()
    cpu = top(seconds, ["WindowServer", "Sunlight", "BankFixture"])
    t1, f1 = time.time(), feeds()
    rates = []
    for d, f in f1.items():
        if d in f0 and f["capture_seconds"] > f0[d]["capture_seconds"]:
            dt = f["capture_seconds"] - f0[d]["capture_seconds"]
            rates.append("display %s: %.1f received, %.1f presented frames/s (%sx%s px)" % (
                d, (f["frames_received"] - f0[d]["frames_received"]) / dt,
                (f["frames_presented"] - f0[d]["frames_presented"]) / dt, f["pixel_width"], f["pixel_height"]))
    print(f"[{name}] fixture draws/s per window, timer ticks/s: {draws(t0 + 1)}")
    print(f"[{name}] feeds: {'; '.join(rates) or 'none'}")
    print(f"[{name}] CPU %: {cpu}")
    sys.stdout.flush()

for p in (IDS, STATS):
    if os.path.exists(p): os.remove(p)
fixture = subprocess.Popen([FIXTURE, IDS], stdout=subprocess.DEVNULL, stderr=open(os.path.join(WORK, "fixture.log"), "w"))
for _ in range(40):
    if os.path.exists(IDS) and os.path.getsize(IDS): break
    time.sleep(0.25)
ids = ",".join(map(str, json.load(open(IDS))["ids"]))
time.sleep(2)
phase("sunlight off")

if os.path.exists(ST): os.remove(ST)
subprocess.run(["open"] + ENV + [APP, "--args", "--sip-bank-only", ids] + EXTRA)
print("launched with", ENV or "no overrides")
for _ in range(60):
    b = status().get("bank", {})
    if b.get("phase") == "running" and len(b.get("windows", [])) == 3 and b.get("capture_streams", 0) > 0: break
    time.sleep(0.5)
time.sleep(4)
c = status().get("canvases", [{}])[0]
print("canvas windows streaming:", sum(1 for w in c.get("windows", []) if w.get("streaming")), "of", len(c.get("windows", [])))
phase("banked, animated")
fixture.send_signal(signal.SIGUSR1)
time.sleep(1)
phase("banked, paused")
fixture.send_signal(signal.SIGUSR1)

subprocess.run(["osascript", "-e", 'tell application id "com.kasselvania.sunlight.virtualcanvas" to quit'], capture_output=True)
for _ in range(40):
    if subprocess.run(["pgrep", "-f", "Sunlight Canvas Lab.app/Contents/MacOS"], capture_output=True).returncode: break
    time.sleep(0.5)
running = subprocess.run(["pgrep", "-f", "Sunlight Canvas Lab.app/Contents"], capture_output=True).returncode == 0
print("Sunlight", "STILL RUNNING" if running else "quit ok")
fixture.terminate()
