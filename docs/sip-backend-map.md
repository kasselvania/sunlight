# SIP-enabled window backend: operation map

Status 2026-11-13. Read-only source map of fork `8a05c19` (Sunlight v0.2.4 base). Nothing here has
been run; every claim below is from reading code, and each one links to the code it is based on.
This is the step below [sip-functionality-audit.md](sip-functionality-audit.md). That audit
classifies product features. This document follows each **native window operation** from the
Sunlight code that issues it to whichever backend executes it, and records where the window bank
breaks the chain.

## Why the bank needs its own map

Sunlight was written for two window realities:

| | Capture mode (demo) | Real-windows mode (SIP off) | Window bank (ours) |
|---|---|---|---|
| Where the real window lives | User's desktop, hidden behind the canvas | User's desktop, transformed in place | A hidden virtual display |
| What the tile shows | Per-window ScreenCaptureKit stream of that window (follows it, keeps alpha) | The real window's own surface | A crop of the bank's composited display feed |
| How many geometries exist | Two: tile `worldRect` and native frame, reconciled by the listing | **One**: the tile *is* the window | **Three**: `worldRect`, the live native frame, and the bank's recorded crop rect |
| How input reaches the app | Only after entering (native window at 1:1) | WindowServer maps it through the transform | Synthesized events at the live native frame ([CapturedWindowInput.swift:62](../Sources/Canvas/CapturedWindowInput.swift#L62)) |
| Entering a window | AX move to the tile's spot, raise, activate | Dock add-on `handoff` transaction | Host `release`, then capture-mode entry ([CanvasController.swift:4767](../Sources/Canvas/CanvasController.swift#L4767)) |

The SIP profile runs as capture mode ([Settings.swift:14](../Sources/Canvas/Settings.swift#L14))
with the bank bolted on beside it. Capture mode's assumptions ("the real window is on the user's
desktop", "the stream follows the window") no longer hold, and nothing replaces them.

## Operation by operation

Status key: **OK** works as designed · **STALE** works once, then stops tracking reality ·
**BYPASS** the operation runs, but around the bank · **MISSING** not connected.

### Geometry

| Operation | Issued from | What happens with a banked window | Status |
|---|---|---|---|
| Admit (park) a window | `consider` ← capture pass ([CanvasController.swift:5843](../Sources/Canvas/CanvasController.swift#L5843)) → [SourceBank.consider](../Sources/Canvas/SourceBank.swift#L112) → host [park](../Sources/Canvas/SourceBankHost.swift#L141) | First-fit slot sized to the window **at park time** ([SourceBankGeometry.slot](../Sources/Canvas/SourceBankGeometry.swift#L46)); `BankRecord.native` is written once and never updated after that. | OK, but it is the source of every **STALE** row below |
| Tile picture | [rebuildCapture](../Sources/Canvas/SourceBank.swift#L276) → `applyBankFrame(crop:)` | Crop computed from `record.native`. The feed's source rect is the union of those frozen rects. | **STALE** |
| Listing reconciliation | [sync verdict](../Sources/Canvas/CanvasController.swift#L2382), [WindowSync.verdict](../Sources/Canvas/Positioning/WindowSync.swift#L57) | Banked = `.canvas` owner, so verdict `.size`: the proxy's `lastRealFrame` takes the new native frame. The bank is never told. | **STALE** (proxy and bank disagree) |
| Input mapping | [CapturedWindowInput.swift:75-79](../Sources/Canvas/CapturedWindowInput.swift#L75) | Uses the **live** window-list frame. The picture uses the **frozen** one. After any native move or resize, clicks land on content that is not where the tile shows it. | **STALE** (picture ≠ input) |
| Resize by dragging a tile edge | [canvasResized → pumpResize](../Sources/Canvas/CanvasController.swift#L4564) → `ax.setSize` | The banked window resizes on the bank. Its crop stays the old size; a growing window spills into neighbouring slots, which also get cropped into its tile. | **BYPASS** |
| Layout, Tidy, tiling resize | [resize(_:to:)](../Sources/Canvas/CanvasController.swift#L3774) via [placement](../Sources/Canvas/CanvasController.swift#L4512) | Same as above, for many windows at once. | **BYPASS** |
| Moving a tile on the canvas | CanvasView drag → `worldRect` only | World-space only; no native move. Correct by design: canvas place and bank slot are separate. | OK |
| Native move by the app or by a forwarded title-bar drag | App / forwarded mouse events | Real window moves on (or off) the bank. Nothing clamps it, re-parks it or re-cuts the crop. This is how Zen escaped. | **MISSING** |
| Move a window to another physical display | [move(_:to:)](../Sources/Canvas/CanvasController.swift#L8005) → `ax.setPosition` | Pulls a parked window off the bank behind the bank's back; the host journal still lists it as parked. | **BYPASS** |

### Focus and presentation

| Operation | Issued from | What happens with a banked window | Status |
|---|---|---|---|
| Type/click in a tile without entering | [CapturedWindowInput](../Sources/Canvas/CapturedWindowInput.swift), [CapturedInputEvents](../Sources/Canvas/CapturedInputEvents.swift) | Focuses the source app and posts window-addressed events. Works for ordinary text views (earlier six-switch check); menus, drag sessions and IME are untested. | Partly OK |
| Enter a window (click-through, ⏎, switcher) | [handoff](../Sources/Canvas/CanvasController.swift#L4765) → [SourceBank.release](../Sources/Canvas/SourceBank.swift#L144) → host [restoreHandle](../Sources/Canvas/SourceBankHost.swift#L195) | Host puts the window back at its **pre-park frame, including the pre-park size** (`setSize(original)`), then capture-mode entry moves it again with AX. Any resize done on the canvas is lost on entry. Two native moves and an IPC round trip per entry. | **BYPASS** |
| Return to the canvas | [CanvasController.swift:1399-1400](../Sources/Canvas/CanvasController.swift#L1399) `returnToCanvas` | Clears the "native" set. The next capture pass re-parks the window into the first free slot (possibly a different one). The size it was used at is kept only by luck of slot fit. | STALE-prone |
| Dock click / ⌘Tab / Spotlight activating an app | [TakeoverMode](../Sources/Canvas/Takeover/TakeoverMode.swift#L51) → ForegroundWatcher → [foreignActivation](../Sources/Canvas/CanvasController.swift#L6605) | The SIP startup [returns early](../Sources/Canvas/App.swift#L170) and never creates `TakeoverMode`, so no watcher and no key tap. The app's native window comes forward on its own, unconnected to its tile. This is the T3 duplicate. | **MISSING** |
| Stacking, levels, PiP above the active app | Dock add-on `snapshot` / `pins` ([RealWindowDriver](../Sources/Canvas/RealWindows/RealWindowDriver.swift)) | The canvas window is `.floating` in SIP mode ([CanvasController.swift:368](../Sources/Canvas/CanvasController.swift#L368)). How PiP tiles behave while an entered window is in front has **not been examined**. | Unknown |
| Window shape, corners, shadow | Add-on `shape` / `shadow`; capture mode used per-window alpha | Rectangular crop of a composited display: whatever is behind the window on the bank shows in its rounded corners. | **MISSING** |
| Sheets, popovers, child windows | `parentOf` / attachments | The bank skips attached windows ([SourceBank.swift:114](../Sources/Canvas/SourceBank.swift#L114)). The display feed bakes children into the parent's pixels only when they fall inside its rect. | **MISSING** |

### Lifecycle

| Operation | Status |
|---|---|
| Window closes or its app quits: [SourceBank.observe](../Sources/Canvas/SourceBank.swift#L65) releases it | OK |
| Close / minimize from the tile ([CanvasController.swift:3055](../Sources/Canvas/CanvasController.swift#L3055), [3095](../Sources/Canvas/CanvasController.swift#L3095)) | AX actions work anywhere; bank membership while minimized is not reconciled |
| Quit / crash: host journal restores the originals ([restoreAndFinish](../Sources/Canvas/SourceBankHost.swift#L238)) | OK, but restores the **pre-park** size |
| Display add/remove: host tears the bank down on configuration change | OK (and identity-bounded since `1a7647b`) |
| Desktop/Spaces consolidation | Not started (agreed plan: Mission Control actions under a covering animation) |

## Root causes

Every broken row above traces to one of four causes:

1. **No single owner of native geometry.** `BankRecord.native` (picture), the window list (input)
   and `WindowProxy.lastRealFrame` (canvas) each hold a different copy of the window's frame. Only
   the latter two get updated.
2. **Native operations go around the bank.** Resize, layout, display moves and entry each call AX
   directly, written for capture mode, where the window lived on the user's desktop.
3. **The SIP startup skips Sunlight's wiring.** No `TakeoverMode` (foreground watcher, key tap), no
   normal menus or hotkeys, no `TrackpadPan` ([App.startCanvas](../Sources/Canvas/App.swift#L169) vs
   [finishSIPCanvas](../Sources/Canvas/App.swift#L296)). `TakeoverMode` already has a light path
   ([TakeoverMode.swift:47](../Sources/Canvas/Takeover/TakeoverMode.swift#L47): "keys and absorb
   only, nothing changed on the system"). That path is the obvious starting point.
4. **Composited capture loses per-window shape.** A crop of a display cannot separate a window
   from what is behind it.

## The connection to build

The window bank should become **the backend for native operations on banked windows**, the way
`RealWindowDriver` is for the add-on. `CanvasController` should stop calling AX on a banked window
directly. Roughly:

```swift
/// Owns the native frame of every banked window. The one source of truth for picture and input.
protocol BankedWindowBackend {
    func frame(of id: CGWindowID) -> CGRect?                 // live native frame, used for crop AND input
    func resize(_ id: CGWindowID, to size: CGSize) async -> CGRect?   // re-slots if needed, re-cuts crop
    func enter(_ id: CGWindowID, at origin: CGPoint, size: CGSize) async -> CGRect?  // bank → screen, one move, keeps canvas size
    func returnToBank(_ id: CGWindowID) async                 // screen → its slot, keeps its size
    func reconcile(_ listing: [WindowInfo])                   // follow app-initiated moves/resizes; clamp or re-park escapees
}
```

- `reconcile` runs from the same listing that drives `WindowSync`, so all three geometries update
  in one place. A window found outside its bank is re-parked, not left there.
- `enter` replaces "restore original, then AX-move". The window goes straight from its slot to
  the tile's on-screen position at the tile's size. The pre-park frame is kept only for quit/crash
  restoration.
- Resize, layout, Tidy and display moves check for banked windows (as `handoff` already does at
  [line 4767](../Sources/Canvas/CanvasController.swift#L4767)) and call the backend instead of AX.

## Order of work

Each step names the problems you reported that it should fix. None of them is fixed yet.

1. **Geometry owner + reconciliation** (causes 1 and 2 for resize): live crop from the reconciled
   frame, slot re-packing when a window grows, re-park on escape, entry keeps the canvas size.
   *Should fix:* inaccurate resize, Zen escaping, picture/input disagreement, part of the corner
   bleed (a tile cropped to the wrong rect also shows the bank's background).
2. **Route remaining native ops through the backend**: layout/Tidy/tiling, display moves,
   minimize while banked.
3. **Light takeover in the SIP profile**: foreground watcher and key tap, with captured-tile focus
   kept distinct from entering. *Should fix:* the T3 duplicate from Dock/⌘Tab/Spotlight.
4. **Restore Sunlight's normal UI wiring**: menus, settings, hotkeys, `TrackpadPan`, minus the
   privileged setup and loader.
5. **Shape**: standard corner mask per tile first. Child windows and true alpha need a policy
   decision: per-window ScreenCaptureKit streams of banked windows would supply alpha and follow
   the window automatically, at the stream-count cost that caused the earlier switch to shared feeds.
6. Later: Spaces consolidation under a covering animation; cross-app drag and drop.

## Step 1 status (build 12, run live 2026-11-13)

Implemented, compiled, signed; 594 unit tests pass (`WindowListTests` skipped: it opens a window).
Run live on the owner's Mac (macOS 26.4.1, one 3430 × 1447 display at 100 Hz, SIP enabled) with
[experiments/bank-live-check](../experiments/bank-live-check/README.md): three throwaway windows
banked through `--sip-bank-only`, driven with posted HID events, observed through the status file,
the window list and screenshots.

| Check | Result |
|---|---|
| Drag by an app-started window drag (Zen-like strip calling `performDrag`) | **Pass.** The window server put the real window at the real pointer's screen position, on the physical display: the Zen escape, reproduced. The tile followed the pointer exactly (+300, +150 screen points at zoom 0.69). After release the window was re-slotted to `{-4688, 64}` in about 1.6 s; the first `place` timed out while the window was still settling, and the next tick's retry succeeded. The tile stayed live where it was dropped, cropped to its window only. |
| Resize by a tile edge, room to grow | **Pass.** 700 → 1006 pt; tile and crop matched, picture not stretched, no neighbour pixels. |
| Resize into a neighbour's slot | **Pass.** B grew to 1320 pt, overlapped C, and was re-slotted to the second row at `{-6120, 530}`. Tile live and correctly cropped. |
| Enter a resized window (double-click on the title strip) | **Pass.** B came out at `{1055, 514}` at **1320 × 450**, its canvas size, camera at 1:1, its app in front. Back on the canvas, B was re-parked at the same size. |
| Quit | **Pass.** Windows back at their original positions at their **current** sizes; journal removed. |
| Throughput | 22–28 frames/s at first, WindowServer about 100%. Margin 0 vs 384 measured 24.1 vs 21.9 frames/s: the headroom is not the cause. **Resolved, see below.** |
| Display identities | Two Sunlight profiles before and after; ColorSync idle. |

### Throughput breakdown

[phases.py](../experiments/bank-live-check/phases.py) measures, in one run, the fixture's actual
draws/s (App Nap off, 100 Hz timer), the bank feed's frames/s, and `top` CPU for WindowServer,
Sunlight and the fixture: with Sunlight off, then with the three fixture windows banked and
animated, then paused. The owner's other 5–8 windows stayed unbanked (`--sip-bank-only`).

| Configuration | Fixture draws/s | Bank feed frames/s | WindowServer, animated / paused |
|---|---|---|---|
| Sunlight off | 100 | – | 37–41% |
| Unbanked windows streamed at 100 fps, uncapped (build 12 as first run) | 41–48 | 20.5–23.5 | 95–104% / 85–88% |
| Unbanked windows not streamed (`SIP_MAX_STREAMS=0`) | 100 | **99.7** | 44% / 12% |
| Unbanked windows at Sunlight's own policy (8 streams, 30/15/10 fps), **now the default** | 91 | 50.8 | 89% / 78% |

The bank delivers the display's full 100 Hz at full Retina resolution, headroom included. The cost
was the per-window ScreenCaptureKit streams of windows outside the bank: the SIP profile had
removed Sunlight's cap and ran each at the display rate. That saturated WindowServer, which then
throttled the source apps' own drawing (the fixture's timer fell from 100 to 41 ticks/s). Per-window
streams are now only a fallback for windows the bank can't hold, and they keep Sunlight's original
policy (`CanvasController.maxStreams`, `fps(forLevel:)`). Banked windows no longer count against the
cap. In normal use, where every window that fits is banked, there are few or no such streams; the
`SIP_MAX_STREAMS=0` row is the closest measurement to that, and build 8 measured 93 frames/s with
all windows banked. Banking the owner's real windows was not re-measured in this run.

**Real-world check, everything banked (2026-11-13, owner away).** With no `--sip-bank-only`, all
eight windows were banked (the owner's T3, Zen, Messages, Mail and Claude, plus the three fixture
windows), with nothing skipped, refused or streamed per window. [sample.py](../experiments/bank-live-check/sample.py), three 5 s samples:

| Bank feed | Frames/s | Notes |
|---|---|---|
| Display holding the animated fixture windows (and Claude, Mail, Messages) | **100.0, 99.8, 100.0** at 6144 × 4096 px | the display's full refresh rate; fixture drew 100/s |
| Display holding T3 and Zen | 16–29 | follows those apps' own updates (T3 redraws as replies stream); same with the fixture paused |

WindowServer about 50% and Sunlight about 17% CPU while animating; about 20% and 5% with the
fixture paused. After quit, all five of the owner's windows were back at their exact original
frames; the journal was removed, two display profiles, ColorSync idle.

Found and fixed during the run: a build-11 journal record for a window on another Space blocked
every launch ("restoration identity is unavailable"), because Accessibility can't reach such a
window. A record whose window is already on a physical display is now retired with a log line.
`CGWindowListCopyWindowInfo(.optionIncludingWindow)` returns nothing for a window on another Space,
so that check scans the whole list.

Found, not fixed: a press queued during the focus handover reaches the app after the real button
is up. An app that starts its own drag then leaves a dangling window-server drag, which completed on
the next click and moved the window ("Window move completed without beginning"). This belongs to the
input path (step 3 or a follow-up), not geometry.

- [SourceBank.track](../Sources/Canvas/SourceBank.swift) polls the banked windows at 30 Hz in one
  window-server call (`WindowList.onScreen(_ ids:)`). The record, and so the crop, follows each
  window's live frame. A size change the canvas didn't ask for reaches the tile (`placedNatively`);
  one it did ask for (`sizeHeld`) leaves the size to the resize code, as before.
- [SourceBankGeometry.drift](../Sources/Canvas/SourceBankGeometry.swift) decides follow or re-slot.
  A window that overlaps a neighbour or leaves its bank goes through the new host `place` operation
  to a free slot at its current size. A window that fits nowhere leaves the bank for its original
  place (same rule as one too large to park).
- Feeds capture the windows plus 384 pt of headroom, clamped to the display
  (`SourceBankGeometry.feedSource`). Moves and resizes inside that area need no feed restart; one
  that leaves it restarts that bank's feed once things settle (0.15 s debounce). The tile holds its
  last frame meanwhile. The capture area is larger than before, so the throughput measured for
  build 8 needs re-checking.
- A press through a tile freezes its native/tile offset for the whole press
  ([CapturedWindowInput](../Sources/Canvas/CapturedWindowInput.swift)). When the app moves its
  window under that press (title bar, toolbar or tab strip drag), the tile follows the pointer
  (`CanvasController.followCapturedDrag`; not the native delta, which is in screen points for an
  app-started drag), and the window is re-slotted once the press ends.
- Entering a banked window sends the handoff's destination to the host. The window goes straight
  from its slot to that spot at its current size. Quit, crash and fallback restoration put windows
  back at their original position but keep their **current** size. The host no longer calls
  `setSize` on release.

Known limits of step 1: re-slotting during a growing edge-drag could happen more than once, and each
re-slot restarts the feed (addressed in step 2); corner bleed from the composited capture remains
(step 5).

## Step 2 status (run live 2026-11-13)

Every native-moving helper in `CanvasController` (`moveNativelyNow`, `alignSiblings`,
`alignNatively`, `unpark`, `closeForApp`) is limited to the real-windows renderer and never runs in
the SIP profile. Step 1's tracking already reconciles any native resize, so step 2 covers what
reconciliation alone could not.

- **Resizes make room first.** `CanvasController.resize(_:to:)` (layouts, Tidy, Arrange, tiling
  presets, layout restore) and `pumpResize` (edge drags) call `withBankRoom` → `SourceBank.makeRoom`
  for a banked window. If the new size doesn't fit where the window is, the host's `place` operation
  (now with an optional size) moves it to a slot that does, before the resize. macOS keeps a window
  from growing past the edge of its display, so a slot near the edge had clamped Left Half to 1616 pt.
- **Re-slots are batched and settled.** One `place` request carries every window that needs a new
  slot. Of two overlapping windows, only the one that changed last moves. A window must hold still
  for 0.3 s (`SourceBank.settle`) before it is re-slotted, and minimized or hidden windows are skipped,
  so the Dock's minimize and restore animations are not chased.
- **Tiles are re-attached.** `SourceBank.consider` feeds a banked window through its current tile when
  the tile object was made again.
- **Moving to another display keeps the bank slot.** `move(_:to:)` hands a banked window's tile to the
  other canvas (`Desk.expectArrival`, consumed in `makeProxy`) at the spot the real window would have
  gone; the real window stays parked.

| Check (three fixture windows banked, `--sip-bank-only`) | Result |
|---|---|
| Two windows resized at once, each into its neighbour | **Pass.** Both re-slotted to free slots within 0.16 s; the unchanged third window stayed. Tiles took the new size in place. |
| Move & Resize → Left Half on a banked window | Before: clamped to 1616 × 1402. After: the window was moved to a slot with room within 0.1 s, then resized to the full **1703 × 1402**. Picture correct, live. |
| Move & Resize → Right Half (same size) | **Pass.** Tile moved; no native move. |
| Edge drag growing a window into its neighbour's slot | **Pass.** Exactly one re-slot (room made as soon as the requested size stopped fitting); growth continued there. |
| Minimize, then restore from the Dock | **Pass.** No re-slot attempts during either animation (the previous build tried and was refused twice); window and tile back as they were. |
| Quit | **Pass.** Original positions at current sizes; journal removed. A window taller than the space below its original spot was raised by macOS. |
| Moving a banked window to another display | **Not run**: one display on this Mac. Compiles; untested. |

An incident during the run: a right-click meant for a fixture tile landed on the owner's Claude tile,
which was in front at that point, and Left Half resized the real Claude window behind the canvas.
It was restored to its exact frame through Accessibility within a minute. Since then the live check
confirms the target tile with a screenshot first, and it avoids Tidy and Arrange, which lay out every
tile on the canvas and so resize unbanked real windows too.

## Step 3 status (run live 2026-11-13)

- **Foreground watcher in the SIP profile.** `App.finishSIPCanvas` creates `TakeoverMode` and calls
  `startWatcherOnly()`: `ForegroundWatcher` only (app activations, Dock clicks on the front app, the
  entered app's window events). No key tap (Sunlight's ⌘Tab switcher and hotkeys belong with step 4),
  no Spaces watcher, no consent, no preference changes. It stops at quit.
- **Banked windows are entered from their tile.** `absorbKnown` used to take the window's native
  frame as where it lives. For a banked window that frame is on a source display, and the camera
  went there, into empty canvas. A banked window now goes across the canvas to its tile and is
  entered there (`handoff(... spatial: true)`), the bank releasing it to that spot.
- **Typing through a tile stays on the canvas.** `CapturedWindowInput.onWillFocus` marks the app
  (`scaledFocusAsked`, `usedScaledPIDs`) before it is brought forward, so the activation that follows
  is Sunlight's existing "scaled use" case: the canvas stays.
- **Windows macOS returns to a source display are adopted.** macOS puts a window back on the display
  it was last on when that display returns, and the banks keep fixed identities (since `1a7647b`).
  At launch, windows from an earlier session reappeared on a bank display, untracked: `consider`
  skipped them as "already on a source display", so they fell back to per-window streams with none
  of the bank's geometry ownership. They are now parked with `adopt`, journaled, and given a
  restoration place on a physical display (`SourceBankGeometry.restoration` of their frame). Several
  adopted windows can share that fallback place; their real original positions are unknown.
- **Diagnostics.** The status file reports, per canvas window, `attached_to`, `leaving` and
  `in_front`; for the bank, `entered`, `placing`, `scope` and `skipped` with a reason per window.

| Check | Result |
|---|---|
| Activating the fixture app from outside (as ⌘Tab or Spotlight do) | First run: the camera went to the bank coordinates (empty canvas). After the fix: **pass.** "in the window bank — over to its tile and in"; the real window came out exactly at its tile's screen position; one window, no duplicate. |
| Clicking the fixture's Dock icon from the canvas | **Pass.** Same step-in to the tile. |
| Clicking into a tile to type | **Pass** with the Dock hidden: "came forward from its window on the canvas — the canvas stays"; the window stayed banked and took input. One earlier try stepped into the window instead: the Dock had just been revealed, and Sunlight's existing rule treats a press while the pointer is over a Dock window as a Dock click. A Dock that is showing can make that true well away from the icons. Unchanged Sunlight behaviour; it applies only within the Dock's hide delay. |
| Dock click on the front app while typing through its tile | **Not testable with the fixture.** Sunlight matches Dock icons to apps by bundle path, and the fixture is a bare executable. The rest of that path is the one checked above. |
| Adoption at launch | **Pass.** All three windows were found on the second bank at launch and adopted into slots. |

## Step 4 status (run live 2026-11-13)

`App.finishSIPCanvas` now builds Sunlight's own shell, as `startCanvas` does: the main menu, the menu
bar icon and its panel, the ⌃⌥ hotkeys, four-finger pan (`TrackpadPan`), the experimental-feature
observer, signal handlers that go through the quit path, and `TakeoverMode.startSIPProfile()` (the key
tap and the foreground watcher). The development lab menu and its extra status item are gone.

Left out of the SIP profile, and guarded so nothing can reach them: setup (`showSetup`), the
updater, the Dock add-on (`loadLiveWindows`, `reloadLiveWindows`), takeover's consent and system
preferences (`takeOverTheMac`, `releaseTheMac`), uninstall, and the Spaces watcher, whose Desktop
merge needs the add-on (also kept off when input resumes). The panel hides Set Up, Check for Updates,
Reload Live Windows and Take Over / Release (`MenuBarPanelModel.sipProfile`) and says "On · window
bank, SIP on". Settings has no Live Windows pane, no takeover switch and no Uninstall. The app menu
and the icon's right-click menu carry Start Window Bank and Return Windows and Stop Window Bank.

| Check | Result |
|---|---|
| Launch | **Pass.** Sunlight's menus (app, Edit, Layouts, Window), sun icon, minimap; log: key tap installed, four-finger pan following one multitouch device, takeover SIP profile. |
| ⌃⌥← with the pointer over a banked tile | **Pass.** "Tile: … → Left Half"; the bank made room, then the window took 1703 × 1401. |
| ⌘Tab | **Pass.** Sunlight's switcher opened (6 apps, 8 windows) with the canvas previewing the highlighted app; Escape cancelled it; nothing switched. |
| Mission Control key | Routed (`Key: missionControl`). A tap on the canvas goes back into the last window (none here), as Sunlight intends. The hold, which picks the window under the pointer, was not exercised: it could have entered one of the owner's real windows. |
| Settings (⌘,) | **Pass.** Tabs: General, Canvas, Background, Windows, Motion, How to use, Experimental. General shows the SIP-profile note, no takeover switch, no Uninstall. |
| Menu bar panel | **Pass.** "On · window bank, SIP on"; More lists only Settings… and Quit Sunlight. |
| Quit | **Pass.** Windows returned, journal removed, two display profiles, ColorSync idle. |
| Four-finger pan | Started (log above); not exercised: synthetic events can't drive the multitouch framework. Needs a real trackpad. |

Unchanged from the earlier SIP builds: the app keeps a Dock icon (`.regular` activation policy),
where Sunlight proper has none.

## Step 5a status: corners (run live 2026-11-13)

A shared display feed has no alpha, so a rectangular crop showed the bank's wallpaper in each
window's rounded corners. Bank frames now go to their own clipped layer in `WindowProxy`
(`bankContent`; the proxy's own layer can't clip without clipping its shadow), with the window's
real corner radius. `SourceBank.measureCorners` takes one SkyLight capture of the window, reads its
alpha (`SourceBankGeometry.alpha(of:)`), and measures the radius from the opaque area's corner along
the diagonal (`cornerRadius(alpha:width:height:windowWidth:)`, unit-tested with and without a
shadow margin). It measures when a window is parked, when its tile is made again, and when a new
size settles. The tile's shadow and hover border take the same radius; Picture in Picture keeps its
own corner shape and the bank layer follows it. The last bank frame stays up until another source's
first frame replaces it, so a handoff's flight never shows an empty tile.

Live, all eight windows banked: standard windows measured **17.1 pt**, toolbar windows (Mail,
Messages) **27.3 pt**, as macOS 26 draws them. Screenshots of tile corners show the window's own
corner with no bank wallpaper. The measurement's step is about 1.7 pt (one pixel on the diagonal at
2×). True per-pixel alpha (translucent windows, irregular shapes) is still not recovered.

## Step 5b status: menus and sheets in tiles (run live 2026-11-13, partly)

What happens with a banked window's pop-up menu or sheet, from a fixture with an `NSPopUpButton` and
an `NSAlert` sheet:

- **Seen.** A menu opens as a layer-101 window, and a sheet as a layer-0 window, on the bank over
  their parent. Inside the parent's frame both are in the parent's crop and show on its tile. A menu
  or popover that extends past the parent's frame is cut at the tile's edge (not yet drawn as an
  overlay). Sunlight's own attached tile for a sheet drew a wrong picture (a shrunken parent) over
  the tile; attached tiles over a banked parent are now neither streamed nor drawn, and presses on
  them go to the parent as before.
- **Sheets: clicks work.** `CapturedWindowInput.windowInFront` finds the app's window in front of the
  tile's at the press, and the press is addressed to it. OK and Cancel each worked through the tile.
- **Menus: keyboard worked from the start** (Down, Return reach the frontmost app). **Clicks did
  not**: a posted click addressed to the menu closed it unchosen, because menu tracking follows the
  real pointer, which is on the physical display. A press over a raised window of the app is now not
  posted; on release, the item under it is pressed through Accessibility
  (`AXUIElementCopyElementAtPosition` at the native point, then `AXPress` for menu items, buttons,
  checkboxes, radio buttons). Live: correct item chosen every time the click reached Sunlight.
- **The first click on an open menu was often lost**: the app's menu tracking grabbed it, so the canvas
  never saw it. `CapturedInputIsolation` now also takes presses addressed to one of the app's raised
  windows while the real pointer is nowhere near that window, re-addresses them to the canvas, and the
  canvas handles them as its own press. Live after this change: two of three single clicks chose the
  item; the third needed a second click (the lost press left no trace; not yet diagnosed).
- Hover highlighting inside a menu does not follow the pointer (menus track the real pointer).
  Right-click over a tile shows Sunlight's own menu, as in Sunlight proper.

**Finished menus (run live 2026-11-13, owner hands-off).**

- Menus and popovers that extend past their window's frame are drawn in full: while a banked app is
  in front, `SourceBank.track` lists its raised windows, assigns each to the window it belongs to
  (`SourceBankGeometry.raisedParent`), keeps them inside the feed (`feedSource` includes them), and
  hands them to the tile with each frame. `WindowProxy` draws each as an overlay layer above the bank
  content (`overlayFrame`, corners clipped at 10 pt), free to overhang the tile; `raisedWorldRects`
  makes a press there the tile's input (`CanvasView.capturedInputTarget`).
- A press on an open menu now chooses on the press, not the release: with a menu open, the release
  often never came back to the canvas. Each press arrives twice (the panel's hook and the view);
  the repeat is ignored, and the menu must still be open when the press lands
  (`pressRaised`), so the second never reaches a control in the window underneath.
- Live, a ten-item menu overhanging its tile by about 160 pt: drawn in full; **10 of 10 items chosen
  with a single first click**, top, middle and bottom, plus 3 of 3 on the final build. Ten duplicate
  presses ignored; no stray actions in the window underneath.

**Found: ordinary button clicks through a tile are unreliable.** Eight open-and-close cycles of a
sheet from its "Sheet…" button: the sheet opened 5–6 times of 8, and its OK/Cancel click closed it
3–5 times. It made no difference whether grabbed presses were returned (an A/B switch), whether
menus had been used, or whether the synthetic click was held 60 or 150 ms. In the failures the
press reached the window and its release never did, so the button stayed held. This is in the
existing input path (`CapturedInputEvents`, `CapturedWindowInput`), not in the menu work, and is the
next thing to fix. It was measured with synthetic HID clicks; real trackpad clicks are unmeasured.

**Consent prompts.** During these runs macOS showed "Sunlight Canvas Lab is requesting to bypass the
system private window picker and directly access your screen and audio" six times, never answered
(the owner was away). The first came on the run that first measured corners through SkyLight
captures of banked windows; one-shots now use ScreenCaptureKit in the SIP profile
(`Settings.captureMethod`), and the next launch added none, but later launches still did. The bank
feed's Core Graphics display stream is the remaining legacy-capture API. Options: answer Allow (macOS
remembers it for a while), or move the feed to ScreenCaptureKit's display stream and re-measure
throughput, which the Core Graphics path was chosen for in build 8.

## Owner's first trial and fixes (2026-11-13)

From the owner's session log and report:

- **A resize took Zen out of the bank.** Dragged to 2177 pt tall on a 2048 pt bank, it found no slot,
  and "no room" released it to its original place; macOS then held it to the screen's height and the
  restoration timed out (the toast the owner saw). Out of the bank it was streamed per window at
  Sunlight's capture policy, so it looked slow. A Finder window as wide as the 3430 pt ultrawide could
  not be banked at all (banks were 3072 pt).
- **Fixed.** Banks are sized from the physical displays (`SourceBankGeometry.bankSize`: at least
  3072 × 2560, as wide as the widest display plus margins, within 4096 pt; 3478 × 2560 here). A resize
  of the canvas's is held to the largest slot (`largestSlot`, via `makeRoom`), and "no room" never
  takes a window that is still on its bank out of it; only one dragged off its bank goes back. A tile
  whose size still differs from its settled window 0.6 s after any resize of the canvas's takes the
  window's size (a drag whose release was lost had left the tile at the pointer's size).
- **Dock and menu bar.** Neither needs SIP. Takeover's preferences (Dock auto-hide; Mission Control
  gestures, App Exposé and hot corners off) are now applied by `TakeoverMode.startSIPProfile()`,
  snapshotted first and reverted at quit (`revertForTermination`). Running as an accessory app (no
  Dock icon or app menu) was tried and reverted: the SIP canvas is a non-activating panel, so Sunlight
  never became active and the canvas ignored scrolls; it stays a regular app.

Live (owner away): over-tall drags held to 2472 pt, still banked, tile matching the window; no
snap-back during drags. Everything banked (8 windows): feed with animated windows 87–91 frames/s over
the whole larger bank (6956 × 5120 px). After quit, every window at its original frame, Dock and
widget preferences byte-identical to before, two display profiles, ColorSync idle.

## Not verified by this map

- Runtime behaviour of any row. This map comes from source reading only.
- PiP behaviour in the SIP profile, and window-level interaction with the `.floating` canvas.
- Whether `TakeoverMode`'s light path runs cleanly beside the bank without other changes.
- The exact corner radius macOS 26 uses per window type.

## Build 13: feeds sized to what the canvas shows; minimap (2026-11-13)

**Feed demand.** Each bank feed used to capture every banked window on its bank plus headroom at full
2× density, whatever the camera showed: 6956 × 5120 px on the owner's banks, 87–91 frames/s, about
55% WindowServer. The capture pass now reports, per banked window, whether its tile is near the
viewport (the same enter/leave margins and hysteresis as Sunlight's own streams) and the canvas's
level of detail (`factor(forLevel: lod.applied)`). `SourceBankGeometry.feedPlan` sizes each feed to
the windows in sight (plus their menus and headroom) at `2 × factor` pixels per point (floor 0.125);
a bank with nothing in sight runs no feed. A tile out of sight keeps its last picture; one with no
picture yet is fed once without raising the detail. `feedNeedsRebuild` restarts a feed only when a
wanted window is outside it, the detail level changed, or it is over twice the area wanted; an
unchanged feed keeps running through membership changes (they used to restart every feed). Checked
on each 30 Hz tracker tick. Status: `bank.feeds[].scale`, `bank.demand`. Measured below (builds 13–18).

**Minimap.** It showed only while Sunlight was the active app, but the SIP canvas floats in front
whichever app has the keyboard, so it came and went with every click into a tile. It now follows
the canvas being presented (`capturedCanvasPresented`). The bank's own tile resizes (following a
window natively, re-slots, reconcile) now redraw it (`SourceBank.onTilesChanged`); before, its marks
kept old sizes until something else redrew it.

## Builds 13–18 measured live (2026-11-13, owner away)

All the owner's windows banked (Mail, Messages, Zen, Macky, T3 Code) plus three fixture windows
redrawing at 100 Hz, 100 Hz display. `sample.py` over 6–8 s; WindowServer % from `top`.

| Build, view | Bank feed (animated bank) | Feed fps | WindowServer |
|---|---|---|---|
| 13, overview 31% | whole bank, 1× out | 67.5 | 63% |
| 13, 1:1 | whole bank, 2× | 64 | 61–63% |
| 13, 1:1 panned (2 windows wanted) | 1308×1594 pt, 2× | 99.7 | 50% |
| 14, fit 53% (one stream) | 3346×2428 pt, 1.41× | 98.4–99.4 | 68–72% |
| 14, 1:1 | same, 2× | 93.7 | 80% |
| 15, fit (5 streams on the bank) | ~12% less area, 1.41× | 78.7–97.1 | 59–62% |
| 15, 1:1 (5 streams) | 2× | 56–68 | 54–56% |
| 16, 1:1 (one stream again) | whole bank, 2× | 98.9–99.1 | 65% |
| 16, fit | whole bank, 1.41× | 98.9–99.6 | 59–63% |
| 17, fit, animated windows on both banks | one stream each | 71 / 57 | 64% |

Findings:
- Several display streams busy at once each deliver fewer frames, whether split on one bank (build
  15) or one per bank with animation on both (build 17), though WindowServer CPU is lower. So the
  default is one stream per bank (`maxFeedsPerBank`, `SIP_BANK_STREAMS` to measure more); grouping
  code stays for that measurement.
- Build 13's 64–67 at the whole bank didn't reproduce in builds 14 and 16 (93–99 for the same
  rectangle), so it was run conditions (four consent dialogs had just appeared over the canvas)
  as much as area. Reading less (demand) and a lower scale both helped in the same run.
- Scale by level of detail halves-to-quarters the frame pool (whole bank at 2×: eight 142 MB frames).
- Remaining limit: animation on both banks at once (57–71 frames/s). Candidates: keep windows that
  redraw often on one bank (the stream's dirty rectangles say which), or one stream reading both.

**Minimap**, verified: a click passed through to a banked window (its app frontmost, nothing entered)
and the card stayed up; a native resize of a banked window redrew its mark at once.

**Adopted windows keep their homes.** macOS moves some windows back onto a bank display when its
identity returns at the next launch (Zen, Macky, Mail, T3 Code on different launches). Adopted, their
bank spot became their home and quit put them there, pulled onto the screen. The host now writes
where it released each window (`Window Bank/returned.json`, by window id and process identity) and
an adopted window whose last release spot is still on screen keeps it. Verified: Zen adopted at
launch, restored to its exact original frame at quit.

**Seen during the run, not fixed:**
- The left ⌘ key was stuck down at the HID level (`CGEventSource.keyState`), so test clicks arrived
  as ⌘-clicks and entered windows. No Sunlight code posts ⌘ and the ⌘-scroll tool didn't reproduce
  it; released with a ⌘ key-up. Watch for it.
- The consent prompt stacked to six over four launches of new builds; rebuilding feeds within a run
  added none.

## Build 19: banked windows are used, not entered; drags from other apps (2026-11-13)

Owner's trial of build 18: a click into Zen pulled the real window out of the bank into the middle of
the screen, in front of the canvas, with its tile still drawn where it was and the window not movable
until a click on the canvas; ⌘Tab did the same, and the minimap stayed hidden throughout (it hides
while a window is entered). The log showed `Handoff: → Zen` with the camera at exactly 1:1 and no
input through the tile before it: a click at 1:1 (`isOneToOne` passes the press on and enters) or a
pinch ending all the way in. `focusInPlace`, Sunlight's "use it where it's drawn", needs the live
windows renderer, so under SIP it fell back to entering, as every way in did.

Now, for a banked window, every way in (click at 1:1, pinch, double-click, ⏎, ⌘Tab, Dock) flies the
camera as before and then uses the window where it's drawn (`useBanked`: raise, app forward, input
through the tile); the window stays on its bank. A title-strip click focuses in place without a zoom,
as with "use windows at any zoom". At 1:1, a press the tile's input doesn't take is the canvas's.

Drags from other apps: the canvas registers for the usual drag types and, held `springDelay` over a
banked window's tile, springs that window open (off its bank at 1:1 under the pointer, the canvas
stepping aside, as for dragged desktop files), so the drop is the app's own. When the button comes up
the canvas comes back and the window returns to its bank. Let go over a tile before it springs: the
drop is refused (it used to offer a picture as the canvas background). Not yet run live.

### Build 19 run live (2026-11-13)

- Used, not entered: verified. A click inside a banked window's tile at 1:1 went to the app (its
  press arrived; `entered` empty); a double-click on a title strip focused the window in place, then
  flew the camera to it at 1:1 ("used where it's drawn, camera to it"), still banked, its app in
  front, minimap up at 100%.
- Drag and drop between banked windows: NOT working. With a two-process fixture (one app drags text
  and a PNG, the other logs drops; a native drag between them works), a press through the source's
  tile started a real drag session, but its image stayed where the drag began, on the bank: after
  `beginDraggingSession` the system moves the drag with the real pointer, and window-addressed
  events posted to the app don't move it. So the canvas never saw the drag (no spring), and
  forwarding positions through the tile under the pointer (tried as build 20, removed) changed
  nothing. Escape cancelled it. Next to try: once the drag pasteboard changes during a press, end the
  forwarded press and let the canvas carry the drag itself (read the drag pasteboard, start a drag
  from the canvas at the real pointer with the same items, so the spring into the target works), or
  move the source window under the pointer for the drag's start.
- Consent prompts came back with the new builds (five on screen afterwards).

## Build 23: drags between apps, carried by the canvas (2026-11-13, run live)

How screen-to-screen tools (Universal Control, Synergy, Barrier) move a dragged thing: no drag crosses
the boundary. They see a drag start (on macOS, the drag pasteboard changes under a held button), read
its contents, end it, and start a new drag where the pointer is with the same contents. Sunlight now
does the same between the bank and the canvas.

Why it was needed: a press through a tile reaches the app, which starts a real drag session; macOS
then sends the pointer's events to that app, `CapturedInputIsolation` returns them to the canvas
(marked as passed on), and they come back to the app as window-addressed events the session ignores.
The drag stayed where it began, on the bank.

Now: while a captured press is down, a change of the drag pasteboard's count (seen in
`CanvasView.externalCapturedPointer`, the path those returned drags take, and in `mouseDragged`)
calls `CanvasController.carryAppDrag`: it copies every type of every item on the drag pasteboard,
cancels the app's drag (Escape posted to it) and drops the press without a release; the canvas
starts its own drag from the real pointer with those items (`beginCarriedDrag`, a thumbnail of
PNG/TIFF/JPEG data or a generic icon). Over a banked window's tile for `springDelay`, the existing
spring opens that window at 1:1 under the pointer and the canvas steps aside; the drop is the app's.
When the drag ends, the canvas comes back and the window returns to its bank.

Measured with `experiments/bank-live-check/DragFixture.swift` (two processes: `source` drags text and
a PNG, `target` logs drops) and `draghold.swift` (press, drag, hold, release): the target logged the
drop with the same types and string as a native drag between them; the canvas came back, both windows
banked, nothing entered. Let go over empty canvas: "nothing took them", no stuck drag.

Limits: a file the app only promises (browsers often promise the image file and also put its URL,
HTML and sometimes TIFF on the pasteboard) isn't carried, only what's on the pasteboard at the start;
not yet tried with a real browser image. Drops onto Finder's desktop from a banked app are untested.

### Build 23 with a real browser (2026-11-13)

Dragging a photo out of Zen's tile (X, at 1:1) onto the drop-target fixture's tile: carried, sprang
open, dropped. The fixture received `public.png`, `public.tiff`, `public.url`, `public.html`,
`public.file-url`, file-promise types and the photo's URL as text: the picture itself came across.
Gotcha met on the way: with text selected in the page, Firefox-based browsers drag the selection even
from an image inside it (two attempts carried HTML/text of the selection). The canvas came back, the
window returned to its bank, nothing entered.

The stuck ⌘ seen in earlier runs was the test tool: `Drive.swift key` sent ⌘ as a flag on the key
event only, which leaves the HID state with ⌘ held (reproduced with Sunlight not running). It now
presses and releases the modifier keys themselves.
