#!/bin/bash
# usage: fps-run.sh <headroom> <ids>
ST="$HOME/Library/Application Support/Sunlight SIP Redesign/redesign-session.json"
rm -f "$ST"
open --env SIP_BANK_HEADROOM=$1 "$HOME/Applications/Sunlight Canvas Lab.app" --args --sip-bank-only $2
for i in $(seq 1 40); do sleep 0.5; [ -f "$ST" ] || continue
  python3 -c "import json,sys;b=json.load(open('$ST'))['bank'];sys.exit(0 if b['phase']=='running' and len(b['windows'])==3 and b['capture_streams']>0 else 1)" && break; done
sleep 4
r() { python3 -c "import json;f=json.load(open('$ST'))['bank']['feeds'][0];print(f['frames_received'],f['frames_presented'],f['capture_seconds'],f['pixel_width'],f['pixel_height'],f['capture_rect'].replace(' ',''))"; }
a=$(r); ws=$(ps -Ao pcpu,comm | grep WindowServer | grep -v grep | awk '{print $1}'); sleep 8; b=$(r)
python3 -c "
a='$a'.split(); b='$b'.split(); dt=float(b[2])-float(a[2])
print('headroom $1: received %.1f fps, presented %.1f fps over %.1fs, %sx%s px, rect %s, WindowServer %s%%'%((int(b[0])-int(a[0]))/dt,(int(b[1])-int(a[1]))/dt,dt,b[3],b[4],b[5],'$ws'))"
osascript -e 'tell application id "com.kasselvania.sunlight.virtualcanvas" to quit' >/dev/null 2>&1
for i in $(seq 1 30); do pgrep -f "Sunlight Canvas Lab.app/Contents/MacOS" >/dev/null || break; sleep 0.5; done
pgrep -f "Sunlight Canvas Lab.app/Contents" >/dev/null && echo "STILL RUNNING" || echo "quit ok"
