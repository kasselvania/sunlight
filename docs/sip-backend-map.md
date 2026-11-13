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
| Throughput | 22–28 frames/s received, WindowServer about 100% CPU while running (11% after quit). Margin 0 vs 384 measured 24.1 vs 21.9 frames/s: the headroom is not the cause. Not comparable to build 8's 93 frames/s: here the unbanked windows each had their own ScreenCaptureKit stream, and the test windows redraw from a background-app timer. **Unresolved.** |
| Display identities | Two Sunlight profiles before and after; ColorSync idle. |

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
  window under that press (title bar or toolbar drag), the tile moves with it
  (`CanvasController.followCapturedDrag`), and the window is re-slotted once the press ends.
- Entering a banked window sends the handoff's destination to the host. The window goes straight
  from its slot to that spot at its current size. Quit, crash and fallback restoration put windows
  back at their original position but keep their **current** size. The host no longer calls
  `setSize` on release.

Known limits of step 1: re-slotting during a growing edge-drag can happen more than once, and each
re-slot restarts the feed; corner bleed from the composited capture remains (step 5).

## Not verified by this map

- Runtime behaviour of any row. This map comes from source reading only.
- PiP behaviour in the SIP profile, and window-level interaction with the `.floating` canvas.
- Whether `TakeoverMode`'s light path runs cleanly beside the bank without other changes.
- The exact corner radius macOS 26 uses per window type.
