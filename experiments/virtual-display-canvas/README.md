# SIP-enabled virtual-display canvas

This experiment replaces the failed cross-process native-mirror candidate with
one virtual monitor, three real windows in a separate process, one public
ScreenCaptureKit display stream and three independently placed canvas tiles.
The goal remains Sunlight's full product experience with SIP fully enabled.

## Try the built app

```sh
experiments/virtual-display-canvas/build.sh
open "build/virtual-display-canvas/Virtual Display Canvas.app"
```

Use **Allow Screen Recording…** if this new app does not have its own grant.
If macOS requests a quit/reopen after granting, reopen this app before starting.
Then press **Start virtual canvas**. Three colored windows with changing numbers
and moving dots should appear inside its canvas. The original windows live on
the temporary virtual monitor, so they do not need to occupy the physical screen.

Drag or scroll in the canvas to pan; pinch to zoom. **Fit** brings the tiles back
into view. **Stop and remove monitor** stops capture, ends the source process
and releases the virtual monitor. Quit also waits for orderly cleanup.

This temporarily adds a 1280×720 monitor to the macOS display arrangement. The
code places only that new monitor to the right of the existing displays, using
a session-only configuration. It does not configure existing monitors, create
Spaces, install a driver/helper or change SIP. Both the app and its source
process are isolated from installed Sunlight. Source windows contain only
synthetic content; the capture filter includes only their three exact window
IDs after checking the owning process and display bounds. There is no desktop
crop or fallback to an unrelated source.

**Clicking and typing into the tiles is not implemented.** This is a working
renderer proof for the virtual-display architecture, not full Sunlight parity.
Native app interaction, menus, real third-party apps and their window families
remain the next work. No Accessibility permission or global input hook is used.

## Architecture

The source process creates its own windows directly on the virtual monitor.
The viewer validates its run token and PID, resolves those windows and the
new display through ScreenCaptureKit, then creates one display-scoped stream
including only the three source windows. Each tile displays a cropped region
of the same IOSurface. Canvas motion changes the tiles, leaving the source
windows and capture allocation fixed.

The mailbox holds only the latest pending frame. The canvas retains the
displayed CVPixelBuffer, since an IOSurface reference alone does not retain the
capture pool's buffer lease. Quartz's top-origin window coordinates are converted
to the bottom-origin contents rectangles used by this AppKit layer tree.

Virtual monitor creation uses private `CGVirtualDisplay` declarations, adapted
with the MIT notice from [orcv](https://github.com/jasonjmcghee/orcv). Capture uses
the public ScreenCaptureKit API. Private API use and SIP changes are distinct:
this specific private display API worked with full SIP on this Mac. Future OS
compatibility is unqualified.

The build runs a single compiler and ad-hoc signs the local bundle. No signing
credentials are created, exported or accessed by default. `SIGN` may explicitly
select an existing development identity later; ad-hoc rebuilds may require a
fresh normal privacy grant. The new bundle identity is
`com.kasselvania.sunlight.virtualcanvas`.

## Native proof and evidence

```sh
python3 experiments/virtual-display-canvas/check_trial.py
```

This creates the one virtual display, runs the three-window source in another
process, receives frames, changes the local camera and stops. It requests no
permission automatically. Each source draws a binary marker, source ID and
twelve sequence bits in its real window. The viewer decodes these from actual
captured pixels; a timer tick or configured layer does not count as delivery.

A passing capture/cleanup result requires advancing decoded sequences from all
three sources, source process exit, removal of the newly created display and
unchanged bounds for the pre-existing displays. The helper additionally saves
two screenshots of this viewer's exact window ID, before and after the internal
camera change. Inspect those images separately: captured frames alone do not
establish a correctly cropped viewer.

The finite trial saves one synthetic captured-bank PNG; normal interactive runs
do not save screenshots. Run-local JSON is under `sunlight-virtual-canvas-<UUID>`
in the user's temporary directory. The helper puts `verified-trial.json`, its
run context and `verified-viewer-1.png` / `verified-viewer-2.png` under
`build/virtual-display-canvas`. These local artifacts are ignored by Git.

The requested capture interval is 60 fps; the fixture updates at 30 Hz. The
reported frame and distinct-sequence counts are functional evidence, not
measured throughput, end-to-end latency or physical presentation timing.

See [LOCAL_FINDINGS.md](LOCAL_FINDINGS.md) for the actual results and the failed
preparation attempts retained alongside them.
