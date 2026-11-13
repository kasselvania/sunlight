# SIP-enabled virtual-display canvas

This directory retains the earlier renderer proof. The current redesign starts from Sunlight's
original Swift canvas; use `scripts/build-sip-redesign.sh` from the repository root. See the
[redesign standards and current scope](../../README.md#sip-enabled-redesign-standards--this-branch).
The two builds share the canonical Canvas Lab identity, so rebuilding this older experiment into
`~/Applications` deliberately replaces the current redesign.

Sunlight Canvas Lab is a native macOS renderer prototype for preserving Sunlight's
canvas experience with SIP fully enabled. It puts three real windows from a
separate process on one temporary virtual monitor, then renders their contents
as independently positioned tiles using one ScreenCaptureKit display stream.

## Earlier renderer app (build 3)

The earlier verified installation used:

```text
~/Applications/Sunlight Canvas Lab.app
```

This experiment opens normally. With Screen Recording allowed, it starts automatically.
Three orange, green and purple tiles show advancing sequence numbers and moving
dots. Drag or scroll inside the canvas to pan; pinch to zoom. **Fit** restores
the layout. **Stop and remove monitor** ends capture, closes the separate source
process and releases the virtual monitor. Quit waits for the same cleanup.

If permission is missing, the app explains it in the canvas, requests the normal
macOS permission and opens the corresponding privacy settings. It creates no
monitor while waiting. **Reopen after allowing** handles a permission change
that requires a new process. Its signed identity must remain stable across
updates; an enabled entry for an older ad-hoc build does not establish access
for a replacement executable.

**Clicking and typing into the tiles is not implemented.** The sources are
synthetic fixture windows. Arbitrary-app control, menus and window families
remain further work toward the full product.

## Architecture

macOS arranges the new 1280×720 monitor. The app uses its actual bounds, without
running a global display-configuration transaction. A separate source process
creates its windows directly on that monitor. The viewer validates its run token,
PID, exact window IDs and containment in the virtual monitor before capture.
The public ScreenCaptureKit filter includes only those three source windows.

Each tile crops the same IOSurface; canvas motion leaves the actual source
windows and capture allocation fixed. The mailbox retains only the latest
pending frame. The canvas retains the displayed CVPixelBuffer so the capture
pool cannot reuse its pixels while the layers display them. Quartz window
coordinates are converted to this AppKit layer tree's bottom-origin crop space.

Monitor creation uses private `CGVirtualDisplay` declarations adapted with the
MIT notice from [orcv](https://github.com/jasonjmcghee/orcv). This private API
worked with full SIP on the local Mac. Future OS compatibility is unqualified.
No Dock injection, driver, privileged helper or Accessibility-based app control
is part of this prototype.

## Build and normal-launch verification

Use an existing development signing identity. Quit the installed app before
building into its canonical location:

```sh
SIGN='your existing development signing identity' \
VIRTUAL_CANVAS_BUILD_DIR="$HOME/Applications" \
experiments/virtual-display-canvas/build.sh
open "$HOME/Applications/Sunlight Canvas Lab.app"
```

The script creates no signing credentials. `SIGN` is required; `SIGN=-` is only
for isolated command-line checks. Without `VIRTUAL_CANVAS_BUILD_DIR`, output is
staged under `build/virtual-display-canvas`. Avoid registering multiple staged
copies with this same bundle ID: macOS's permission-driven Quit & Reopen can
otherwise select an old copy. Prior local candidates have been unregistered and
quarantined as `.app.disabled`; the installed signed app is the canonical copy.

```sh
python3 experiments/virtual-display-canvas/check_trial.py
```

The helper opens the installed app through LaunchServices, matching a fresh
launch receipt to its exact bundle path. It does not execute the binary directly
or inherit the coding agent's capture permission. An optional positional argument
selects another bundle deliberately.

The finite trial decodes source IDs and changing sequence bits from actual
captured pixels, changes the local camera, stops capture and removes the monitor.
It checks source exit and unchanged bounds of the pre-existing displays. The
helper also saves two screenshots of its own viewer window; inspect both to
verify visible crops and advancing contents. Captured frames alone do not
establish viewer output.

Evidence goes under `build/virtual-display-canvas`; private run-local JSON lives
in `sunlight-virtual-canvas-<UUID>` and launch receipts in
`sunlight-canvas-launch-<UUID>` in the user's temporary directory. Normal runs
save no screenshots. The finite trial saves one synthetic captured-bank PNG.
Counts are functional evidence, not measured fps, latency or physical display
timing. See [LOCAL_FINDINGS.md](LOCAL_FINDINGS.md) for the actual local outcome.
