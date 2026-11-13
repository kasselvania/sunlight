# SIP input and navigation candidate — build 11

Status on 2026-11-13: installed and running for the project owner. Automated
input verification is paused at the owner's request while they use the desktop.
This commit preserves the candidate; it does not establish full input parity.

## Implementation

- `CapturedInputEvents.swift` installs the event receiver before the canvas
  accepts clicks. Releases and keys arriving before AppKit resolves a tile are
  queued and delivered outside the event callback in order.
- `CapturedWindowInput.swift` resolves and focuses the exact source window,
  queues input during focus transfer, then posts window-addressed events.
  Replayed events receive posting-time timestamps so early hardware key times
  cannot sort ahead of the reconstructed mouse press. Hover scrolling has a
  separate receiver and leaves the selected typing window unchanged.
- `CapturedInputIsolation.swift` routes canvas-addressed gestures delivered to
  a focused source process back to the canvas. `PressTap.swift` shares the
  existing native pinch decoder with this route.
- `CanvasView.swift` continues latched presses across activation and uses the
  existing pan, pinch and camera behavior. `CanvasController.swift` keeps canvas
  presentation independent of the app selected for typing, and releases panel
  key focus after source focus is ready.

## Observations and limits

An earlier development candidate passed six immediate cross-app click/type
switches with the correct six characters in order and the other app unchanged.
The installed build 11 opened normally with existing Accessibility and Screen
Recording access. Seven source windows occupied the two stable banks, with two
Core Graphics feeds. The owner reported substantially smoother canvas behavior
and normal desktop use in the background after the display lifecycle fix.

The new installed input run stopped at its focus guard before sending test
keys, while the owner was using the computer. This is not a controlled pass or
a demonstrated routing regression. The owner then paused input work. Menus,
window families, native drag and drop, full IME behavior, and overlapping rapid
focus transfers remain unqualified. Release-build input also remains unqualified.

The Safari source uses [monitor.html](../experiments/captured-input/monitor.html),
copied to the existing local test-page URL. It includes Pause/Resume and source
`requestAnimationFrame` rate/interval observations. These describe Safari's
animation production, not Sunlight capture or physical monitor presentation.

The white canvas was the saved plain-colour background setting. Selecting
Background → Use the Mac's Wallpaper restored it immediately without a restart
or renderer changes. No default preference policy was changed.

A final passive twelve-second live-use observation of the Safari bank measured
72.67 received frames/s and 72.75 layer applications/s. The one-frame boundary
difference is sampling granularity. These are bounded observations during
uncontrolled desktop use, not sustained throughput or physical frame pacing.
All three ColorSync processes were idle and the Sunlight profile count stayed
at two. The app and Safari were left running for the owner.

Local evidence: `build/sip-redesign/input-navigation/build11-startup.json`,
`build11-fast-input.json`, `build11-fast-input.log`, `build11-passive.json`,
`build11-passive-rates.json`, `build11-install.log`, and `build11-artifact.json`.
The current candidate compiled and its installed signature verified. The paused
native cases have not been replaced with unit tests that mimic the router.
