import json,sys,os
s=json.load(open(os.path.expanduser("~/Library/Application Support/Sunlight SIP Redesign/redesign-session.json"))); b=s["bank"]
want=set(int(x) for x in sys.argv[1].split(","))
print("bank phase", b["phase"], "err:", b["error"] or "-", "displays", [(d["id"], d["bounds"]) for d in b["displays"]])
for f in b["feeds"]: print("feed", f["display_id"], f["capture_rect"], "recv", f["frames_received"], "secs %.1f"%f["capture_seconds"])
for w in sorted(b["windows"], key=lambda w:w["id"]): print("bank", w["id"], w["display_id"], w["native"])
c=s["canvases"][0]; print("zoom %.4f"%c["camera"]["zoom"], "input_target", c["input_target"])
for w in c["windows"]:
    if w["id"] in want: print("tile", w["id"], "world", w["world"], "screen", w["screen"])
