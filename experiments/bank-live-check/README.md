# Window-bank live check

Throwaway tools used to check step 1 (geometry ownership) on a real desktop on 2026-11-13.
Results are in [docs/sip-backend-map.md](../../docs/sip-backend-map.md#step-1-status-build-12-run-live-2026-11-13).

These move the real pointer and put a floating canvas over the screen. Run them only when the
person at the Mac has agreed to keep their hands off the mouse.

```sh
swiftc -O -o BankFixture BankFixture.swift   # three windows A–C, 700×450, Zen-like drag strip
swiftc -O -o drive Drive.swift               # frames, axsize(2), axframe, axmin, drag, dclick, menu, mouse, moveto
./BankFixture "$PWD/ids.json" &              # writes {"pid":…, "ids":[…]}
open "$HOME/Applications/Sunlight Canvas Lab.app" --args --sip-bank-only <id,id,id>
python3 st.py <id,id,id>                     # bank feeds, bank records, tile world/screen rects
./fps-run.sh <headroom> <id,id,id>           # launch, sample 8 s of feed counters, quit
python3 -I phases.py ./BankFixture "$PWD" [--env SIP_MAX_STREAMS=0]   # off / animated / paused breakdown
pkill -x BankFixture                         # by name: the binary is started as ./BankFixture
```

Before right-clicking or dragging, confirm in a screenshot that the target tile is in front at that
point: a context-menu action on the wrong tile resizes or moves that app's real window. Avoid Tidy
and Arrange in a scoped run: they lay out every tile, unbanked real windows included.

Notes from the run:

- The tiles' screen rects in `st.py` output are global top-left points, the coordinates `drive` uses.
- A tile's title strip is its top 28 world points. A press below it goes to the app. The fixture's
  strip (top 64 points) calls `performDrag(with:)`, as Firefox- and Chromium-based browsers do.
- `SIP_BANK_HEADROOM` (points) and `SIP_MAX_STREAMS` (per-window fallback streams), via `open --env`,
  override those settings for measurements.
- The fixture opts out of App Nap, redraws at 100 Hz, writes draws/s to `ids.json.stats`, and
  pauses or resumes on SIGUSR1.
