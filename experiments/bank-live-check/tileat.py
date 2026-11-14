# tileat.py <window id> <x> <y>: exit 0 only if Sunlight is running and that window's tile covers the point (screen, top-left).
import json, os, sys, subprocess, re
wid, x, y = int(sys.argv[1]), float(sys.argv[2]), float(sys.argv[3])
if subprocess.run(["pgrep", "-f", "Sunlight Canvas Lab.app/Contents/MacOS"], capture_output=True).returncode: print("NO SUNLIGHT"); sys.exit(1)
try: s = json.load(open(os.path.expanduser("~/Library/Application Support/Sunlight SIP Redesign/redesign-session.json")))
except Exception: print("NO STATUS"); sys.exit(1)
if s.get("bank", {}).get("phase") != "running": print("BANK NOT RUNNING"); sys.exit(1)
for c in s.get("canvases", []):
    for w in c.get("windows", []):
        if w["id"] == wid:
            nums = list(map(float, re.findall(r"-?[\d.]+", w["screen"])))
            X, Y, W, H = nums
            if X + 10 <= x <= X + W - 10 and Y + 10 <= y <= Y + H - 10: print("ok"); sys.exit(0)
            print("POINT NOT ON TILE", w["screen"]); sys.exit(1)
print("NO TILE"); sys.exit(1)
