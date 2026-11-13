# Sunlight functionality dependency and wiring audit

Source audit: original Sunlight v0.2.4, `cf7aa16fa0035fa867529787dce02bd3d3ca5e60`,
compared with our fork at `8da1b72`. This is the upstream version actually in this
checkout; v0.2.5 has not been merged or audited here. No runtime changes, app
restarts, window moves, input tests, or SIP changes were performed for this audit.

## Plain-language result

Most Sunlight behavior is already implemented in Sunlight. ScreenCaptureKit
provides images and capture metadata; the injected Dock add-on provides privileged
native-window presentation and Spaces operations. Those are supporting mechanisms
for behavior computed by the application. They are not three independent slices
of the product: one feature, such as PiP, can use all these layers in different modes.

My working estimate is **roughly 40% straightforward reuse/reconnection, 40%
existing behavior requiring backend adaptation, and 20% substantial replacement
engineering**. The explicit inventory below contains 24 equally weighted groups:
10, 10 and 4 respectively. Exact fractions are 10/24, 10/24 and 4/24; the headline
rounds to tens of percent. These are engineering classifications, not measured
completion, code-volume percentages, an effort/time estimate, or guarantees of
compatibility. Small UI groups and difficult integration groups have equal weight.
Some reusable groups are already connected. This is a share of the full inventory,
not a claim that 40% of the remaining work can be enabled immediately. The common
geometry/presentation boundary must be corrected for the dependent features.

## What ScreenCaptureKit actually supplied

- [WindowCapture.start and configuration](../Sources/Canvas/WindowCapture.swift#L93)
  create per-window filters, produce pixel buffers, and select resolution, cadence
  and shadow handling. That stream follows the identified window rather than a
  manually remembered rectangle in a shared desktop.
- [OneShotCapture](../Sources/Canvas/WindowCapture.swift#L343) uses
  SCScreenshotManager for snapshots, including transition images. It also has a
  SkyLight path, so not every capture in Sunlight is ScreenCaptureKit.
- [CanvasController.sync](../Sources/Canvas/CanvasController.swift#L2528) uses
  SCShareableContent to discover windows and obtain SCWindow capture handles.
- ScreenCaptureKit does not implement Sunlight's camera, snapping, layout rules,
  focus policy, keyboard routing, actual window resize, or application switching.
  Accessibility, native events and Sunlight's own code supply those behaviors.
- Finder's desktop floor explicitly uses a SkyLight one-shot and Accessibility,
  rather than ScreenCaptureKit: [DesktopFloor](../Sources/Canvas/DesktopFloor.swift#L11).
- The eight-stream cap and 30/15/10 fps levels are Sunlight policy in
  [CanvasController](../Sources/Canvas/CanvasController.swift#L5793), not an
  inherent ScreenCaptureKit or SIP limit. Removing the policy alone does not
  establish sustained throughput.

The original full live-window mode renders WindowServer surfaces through the
Dock add-on without running these capture streams; see
[the renderer description](../LiveWindows/README.md#live-windows).

## What the SIP-weakening path supplied

The installation described in [LiveWindows](../LiveWindows/README.md#installation-boundary)
loads code into the Dock. That path requires the SIP exceptions and boot setting
listed there. The application then uses
[RealWindowDriver](../Sources/Canvas/RealWindows/RealWindowDriver.swift) and
[LiveWindowsConnection](../Sources/Canvas/RealWindows/LiveWindowsConnection.swift)
to request low-level operations from [sunbeam.h](../LiveWindows/osax/sunbeam.h):

| Low-level service | Product behavior that uses it |
| --- | --- |
| Transform other apps' real window surfaces | Scaling/panning live windows without a captured picture |
| Control window levels and stacking | Arrange surfaces between backdrop and input overlay; prevent newly raised windows flashing over the canvas |
| Combine moves, transforms and ordering in transactions | Smooth native-window handoff and return without misaligned duplicate presentations |
| Change native alpha, shadow looks and corner shape | Window effects, native appearance continuity and shaped PiP tiles |
| Keep selected native windows pinned across handoffs | PiP remaining above the app being used |
| Re-anchor native frames while a transform remains active | Input in scaled windows, including apps that read the global pointer |
| Move windows between Spaces and remove empty Desktops | Desktop consolidation during takeover |

The Dock add-on executes these operations; Sunlight still computes which windows,
rectangles, animation frames and policies to send. Ordinary Dock autohide,
foreground notifications, keyboard taps, Accessibility window actions and login
integration do not inherently require this injected add-on. Private API usage
alone is also not evidence that SIP must be weakened.

## What already exists but our launch did not fully reconnect

[App.startCanvas](../Sources/Canvas/App.swift#L168) returns early for the SIP
profile. The ordinary path below it installs menus/settings callbacks, hotkeys,
global trackpad handling and TakeoverMode. Our
[finishSIPCanvas](../Sources/Canvas/App.swift#L296) instead installs the small lab menu.
This bypass was our change, visible in `git diff cf7aa16..8da1b72 -- Sources/Canvas/App.swift`.

[TakeoverMode.init](../Sources/Canvas/Takeover/TakeoverMode.swift#L51) already wires
ForegroundWatcher to Dock clicks, external app activation, focus changes and AX
window lifecycle events. The original code even has a light startup path for
watchers/keys without preference changes. Our profile never creates that mode.
[CanvasController.foreignActivation](../Sources/Canvas/CanvasController.swift#L6619)
requires a running takeover environment, so its existing logic is not a complete
active integration in our profile. This supports the observed Dock/T3 divergence.

The camera, motion, magnetism, tiling, Tidy, strip, minimap, foreground watcher,
key tap and PiP geometry files inspected here are unchanged from the original
base. Layout persistence differs only in its separate development data folder.
They are reusable code, but connecting their consumers still matters.

Enabling full takeover unchanged is not a complete fix: it also includes the
privileged Spaces path. Its activation logic must also distinguish our deliberate
captured-window focus from an external request to enter a native window.

## What the virtual-display proof establishes

The current implementation demonstrates reusable, SIP-enabled display identities,
live shared display frames at useful rates, retained IOSurface buffers and basic
cropped-window interaction. It supplies a viable image-delivery component on this
Mac. The preferred frame backend is actually
[Core Graphics CGDisplayStream](../Sources/SourceDisplay/SLDisplayStream.m#L37).
[SourceBankCapture](../Sources/Canvas/SourceBankCapture.swift#L32) retains
ScreenCaptureKit as startup fallback; SourceBank still uses SCShareableContent
for discovery. We have not removed all ScreenCaptureKit dependencies.

It does not establish individual-window alpha, arbitrary app input compatibility,
window-family behavior, or all original native-window transactions. In particular:

1. [SourceBank.observe](../Sources/Canvas/SourceBank.swift#L65) handles vanished
   windows, not ongoing move/resize reconciliation. Crops still use recorded
   [BankRecord.native rectangles](../Sources/Canvas/SourceBank.swift#L288).
2. The original [resize pump](../Sources/Canvas/CanvasController.swift#L4571)
   changes the app through AX, outside a bank-aware resize operation.
   [WindowProxy.noteResize](../Sources/Canvas/WindowProxy.swift#L770) updates the
   old per-window capture object; the bank stream does not receive that update.
3. [SourceBankHost.receive](../Sources/Canvas/SourceBankHost.swift#L125) has park,
   release and stop operations, with no integrated resize/repack operation.
4. The shared feed is the composed desktop. Wallpaper and other surfaces can be
   baked into a rectangular crop. Standard rounded clipping can fix ordinary
   corners; complete alpha/shape/family behavior needs an appropriate capture or
   composition path. A rounded mask alone does not recover general transparency.

## Explicit inventory behind the estimate

A means primarily existing behavior and ordinary wiring, conditional on the
shared backend being corrected. B means existing product logic plus real bank,
presentation or lifecycle adaptation. C means significant replacement work or
compatibility uncertainty remains. The classifications are judgments from source;
none is a claim that the feature has passed native acceptance.

| # | Class | Feature group | Existing code and connection needed |
| --- | --- | --- | --- |
| 1 | A | Canvas camera, pan, zoom and inertia | [Camera.swift](../Sources/Canvas/Camera.swift), [Motion.swift](../Sources/Canvas/Motion.swift), [CanvasView.swift](../Sources/Canvas/CanvasView.swift). Existing camera/math are retained; route gestures into the same handlers. |
| 2 | A | Global trackpad gesture dispatch | [TrackpadPan.swift](../Sources/Canvas/TrackpadPan.swift), [Desk.swift](../Sources/Canvas/Desk.swift), [App.swift](../Sources/Canvas/App.swift). Original startup installs TrackpadPan; SIP startup bypasses that installation. |
| 3 | A | Snapping, guides, pushing and group calculations | [Magnetism.swift](../Sources/Canvas/Magnetism.swift), [CanvasView.swift](../Sources/Canvas/CanvasView.swift). Reuse the world-space algorithms; native execution is accounted for under move/resize. |
| 4 | A | Minimap, fit and viewport highlighting | [Minimap.swift](../Sources/Canvas/Minimap.swift), [CanvasView.swift](../Sources/Canvas/CanvasView.swift). Consumes the existing logical window rectangles and camera. |
| 5 | A | Wallpaper, pictures, gradients and background settings | [Background/BackgroundRenderer.swift](../Sources/Canvas/Background/BackgroundRenderer.swift), [Background/BackgroundModel.swift](../Sources/Canvas/Background/BackgroundModel.swift). Existing source selection and rendering; wallpaper was restored through its original menu. |
| 6 | A | Settings, application menus, instructions and preferences | [App.swift](../Sources/Canvas/App.swift), [Settings.swift](../Sources/Canvas/Settings.swift), [MenuBarItem.swift](../Sources/Canvas/MenuBarItem.swift). Restore the original application UI bindings, excluding the privileged setup/loader controls. |
| 7 | A | Saving layouts and remembered canvas geometry | [Layouts.swift](../Sources/Canvas/Layouts.swift), [Desk.swift](../Sources/Canvas/Desk.swift). Layout.Entry uses worldRect; preserve logical geometry rather than bank coordinates. |
| 8 | A | Ordinary desktop preferences and login integration | [Takeover/SystemPrefs.swift](../Sources/Canvas/Takeover/SystemPrefs.swift), [Takeover/StageManager.swift](../Sources/Canvas/Takeover/StageManager.swift), [Takeover/LoginItem.swift](../Sources/Canvas/Takeover/LoginItem.swift). Existing user preference snapshot/restore and login code; separate these from Spaces and add-on startup. |
| 9 | A | Finder desktop file listing, opening and renaming | [DesktopFloor.swift](../Sources/Canvas/DesktopFloor.swift), [CanvasController.swift](../Sources/Canvas/CanvasController.swift). Existing Finder/AX/file behavior and SkyLight one-shot floor capture; cross-app dragging is counted separately. |
| 10 | A | Widget discovery, naming and canvas placement | [Widgets.swift](../Sources/Canvas/Widgets.swift), [DesktopPlacement.swift](../Sources/Canvas/DesktopPlacement.swift), [CanvasController.swift](../Sources/Canvas/CanvasController.swift). Existing metadata, AX actions and placement logic; no new widget engine is needed. |
| 11 | B | Live-window discovery and frame delivery | [WindowCapture.swift](../Sources/Canvas/WindowCapture.swift), [SourceBank.swift](../Sources/Canvas/SourceBank.swift), [SourceBankCapture.swift](../Sources/Canvas/SourceBankCapture.swift). Existing model plus proven bank feeds; complete the mapping from live source geometry to each displayed texture. |
| 12 | B | Window move, title drag and accurate resize | [CanvasView.swift](../Sources/Canvas/CanvasView.swift), [CanvasController.swift](../Sources/Canvas/CanvasController.swift), [SourceBankHost.swift](../Sources/Canvas/SourceBankHost.swift). Preserve original controls/resize anchors, but route banked native changes through the bank owner and update crops. |
| 13 | B | Focus, Dock/app switching, native handoff and return | [Takeover/ForegroundWatcher.swift](../Sources/Canvas/Takeover/ForegroundWatcher.swift), [CanvasController.swift](../Sources/Canvas/CanvasController.swift), [Desk.swift](../Sources/Canvas/Desk.swift). Original activation and navigation logic exists; distinguish captured focus from native entry and coordinate bank release/reacquisition. |
| 14 | B | Ordinary captured clicks, typing, selection and scrolling | [CapturedWindowInput.swift](../Sources/Canvas/CapturedWindowInput.swift), [CapturedInputEvents.swift](../Sources/Canvas/CapturedInputEvents.swift), [WindowProxy.swift](../Sources/Canvas/WindowProxy.swift). The bridge exists, but hit testing, pixels and actual source geometry need one consistent mapping and broader compatibility. |
| 15 | B | Restoring layouts and reopening apps/documents | [Layouts.swift](../Sources/Canvas/Layouts.swift), [CanvasController.swift](../Sources/Canvas/CanvasController.swift). Reuse matching, launching and saved placements; resize and admission must go through the corrected backend. |
| 16 | B | Close, minimize, hide and window lifecycle | [CanvasController.swift](../Sources/Canvas/CanvasController.swift), [AX.swift](../Sources/Canvas/AX.swift), [SourceBank.swift](../Sources/Canvas/SourceBank.swift). Keep original app actions/away states; synchronize bank membership, capture eligibility and restoration records. |
| 17 | B | Multiple physical displays and window ownership | [Desk.swift](../Sources/Canvas/Desk.swift), [Display.swift](../Sources/Canvas/Display.swift), [CanvasController.swift](../Sources/Canvas/CanvasController.swift). Reuse routing; bank positions must never become physical-display ownership or canvas placement. |
| 18 | B | Picture in Picture, pinning, tucking and return | [Positioning/PictureInPicture.swift](../Sources/Canvas/Positioning/PictureInPicture.swift), [PipChrome.swift](../Sources/Canvas/PipChrome.swift), [CanvasController.swift](../Sources/Canvas/CanvasController.swift). Geometry and interaction policy exist; shared frames, overlay lifetime and native handoff require adaptation. |
| 19 | B | Arrange, Tidy, tiling and strip mode end to end | [Tidy.swift](../Sources/Canvas/Tidy.swift), [Tiling.swift](../Sources/Canvas/Tiling.swift), [Strip.swift](../Sources/Canvas/Strip.swift), [CanvasController.swift](../Sources/Canvas/CanvasController.swift). Layout algorithms are reusable; their resulting resizes and placements must use the bank-aware execution path. |
| 20 | B | Quit, crash, sleep and monitor-change restoration | [SourceBankHost.swift](../Sources/Canvas/SourceBankHost.swift), [SourceBank.swift](../Sources/Canvas/SourceBank.swift), [Positioning/WindowSync.swift](../Sources/Canvas/Positioning/WindowSync.swift). Retain durable identities and the fixed display pool; finish ongoing geometry/visibility reconciliation and restoration edge cases. |
| 21 | C | Accurate window shapes, alpha and independent composition | [WindowProxy.swift](../Sources/Canvas/WindowProxy.swift), [SourceBankCapture.swift](../Sources/Canvas/SourceBankCapture.swift), [RealWindows/RealWindowDriver.swift](../Sources/Canvas/RealWindows/RealWindowDriver.swift). A composed display has flattened background/occlusion. Standard corner clipping is feasible; general alpha needs a suitable capture/composition path. |
| 22 | C | Native menus, popovers, sheets and child-window presentation | [CanvasController.swift](../Sources/Canvas/CanvasController.swift), [WindowCapture.swift](../Sources/Canvas/WindowCapture.swift), [SourceBank.swift](../Sources/Canvas/SourceBank.swift). Attachment logic exists, but the bank currently excludes attached children and full-display capture can bake them into parent pixels. A coherent family capture/input policy is missing. |
| 23 | C | Native cross-app drag/drop and global-pointer-dependent apps | [CanvasController.swift](../Sources/Canvas/CanvasController.swift), [CapturedWindowInput.swift](../Sources/Canvas/CapturedWindowInput.swift), [DesktopFloor.swift](../Sources/Canvas/DesktopFloor.swift). Posting addressed events does not reproduce all native drag sessions or the global pointer state some apps read. Dedicated bridging or native handoff is still needed. |
| 24 | C | Desktop/Spaces consolidation | [Spaces.swift](../Sources/Canvas/Spaces.swift), [Takeover/TakeoverMode.swift](../Sources/Canvas/Takeover/TakeoverMode.swift), [RealWindows/LiveWindowsConnection.swift](../Sources/Canvas/RealWindows/LiveWindowsConnection.swift). Original DockSpaces uses privileged move-to-Space/destroy-Desktop operations. The agreed Mission Control/AX route and covering animation are not implemented. |

## How the reusable code should connect

Keep Sunlight's controls, command dispatch, camera, world model and layout rules.
Put native execution behind one bank-aware operation boundary. Canvas position
belongs to the world model; native source placement belongs to the bank owner.
They are different rectangles. A resize must publish the app-accepted native size,
source placement and crop together; rendering and input must use the corresponding
mapping. Moving a tile or camera must never drag its source out of its bank.

Reconnect foreground/key/gesture services to that same presentation state. Focus
for editing a captured tile must remain distinct from entering its native window.
Reconcile external Dock/Spotlight/app-switch activation through the existing
handoff and return policy. Settings, layouts, PiP and lifecycle commands then
consume the same corrected backend instead of each acquiring a separate patch.

This preserves the original application while replacing its privileged execution
mechanism. The difficult common boundary explains why a high reuse percentage
can coexist with many user-visible failures in the current integration.
