# SIP-enabled capture performance

## Accepted milestone

On 2026-11-13, the project owner accepted build 8's observed near-100 fps result
for the current performance milestone. Further optimization can follow the
remaining product work. Sustained 100 fps remains the engineering target.

The final installed Debug artifact delivered 93.01 complete capture frames/s and
93.09 tile applications/s in a twelve-second observation on a 100 Hz display.
The small counter difference comes from sampling at the interval boundaries.
Earlier installed observations reached 93.50 and 94.42 frames/s. All ten windows
were banked, with one continuously animated Safari window and full 2× Retina
output. SIP remained fully enabled. These observations establish the accepted
local milestone; they do not establish sustained 100 fps, physical presentation
of every frame, or an all-windows-animated workload. Full product parity and
Release-build input remain separate unfinished work.

Measured implementation: commit `3b7ab3aee4a61099cc60c29b5cfa70884c563840`.
See the [build 8 findings](../experiments/virtual-display-canvas/LOCAL_FINDINGS.md#capture-performance-build-8)
for artifact identity, measurements, failed candidates and recovery evidence.

## Build 12 measurement (2026-11-13)

All of the owner's windows banked plus three fixture windows animating at 100 Hz: the bank feed
holding the animated windows delivered **100.0 frames/s at 6144 × 4096 px** in three consecutive
5 s samples, on a 100 Hz display, with WindowServer about 50% CPU. Windows outside the bank now keep
Sunlight's own capture policy (eight streams, 30/15/10 fps); uncapped, they had held the bank to
about 23 frames/s with WindowServer saturated. Details and the breakdown are in
[sip-backend-map.md](sip-backend-map.md#throughput-breakdown).

## Where to optimize later

Search the source for `SIP PERFORMANCE` to find the matching comments. These are
entry points for future profiling, not a claim that each location is a bottleneck.

| Area | Code entry point | What to investigate |
|---|---|---|
| Requested cadence | [SIPRedesign.swift](../Sources/Canvas/SIPRedesign.swift), `frameRate(displayID:)` | Display-derived request rate. Raising this number does not establish higher delivered fps. |
| Bank capacity and packing | [SourceBankHost.swift](../Sources/Canvas/SourceBankHost.swift), `createDisplay()`; [SourceBankGeometry.swift](../Sources/Canvas/SourceBankGeometry.swift), `slot(size:display:occupied:)` | Two fixed Retina displays; packing density, unused captured area and overflow streams. Stream contention caused the earlier limit. |
| Capture regions and reconfiguration | [SourceBank.swift](../Sources/Canvas/SourceBank.swift), `rebuildCapture()` | Per-bank ROI, cropped tile delivery and rebuilding only changed feeds if membership changes cause measured hitches. |
| Native acquisition and surface lifetime | [SLDisplayStream.m](../Sources/SourceDisplay/SLDisplayStream.m), `initWithDisplayID:sourceRect:pixelSize:queue:` and `SLRetainDisplayFrame` | Queue depth, source ROI, callback/display timestamps and actual complete-frame delivery. Preserve the IOSurface pool lease. |
| Fallback and main-thread delivery | [SourceBankCapture.swift](../Sources/Canvas/SourceBankCapture.swift), initializer, `enqueue(_:)`, `present()` | ScreenCaptureKit configuration, callback-to-main delay and newest-frame coalescing. A running feed failure restores the bank; it does not start fallback capture on a disappearing display. |
| Tile application | [WindowProxy.swift](../Sources/Canvas/WindowProxy.swift), `applyBankFrame(_:crop:)` | Layer updates, crop changes, main-thread cost and retained buffer lifetime. |
| Camera and input animation | [CanvasView.swift](../Sources/Canvas/CanvasView.swift), `tick(_:)` | Display-linked animation pacing and existing `perf.tick` observations. Camera cadence and source capture cadence are independent. |

## How to interpret the existing measurements

`SourceBank.status` publishes `bank.feeds[]`, one entry per display, in
`~/Library/Application Support/Sunlight SIP Redesign/redesign-session.json`.

- `frames_received` counts complete source frames accepted by the receiver.
- `frames_presented` counts applications to the tile layers. Its historical name
  does not mean measured physical screen presentation.
- `capture_seconds` supplies the elapsed interval for counter deltas;
  `pixel_width` and `pixel_height` report actual output resolution.

Compare counter deltas over an interval on the same live feed. Reconfiguration
creates a new feed and resets its counters. Record the backend, bank membership,
animated workload and resolution alongside the rate. Static banks can emit few
frames; do not add independent bank rates together.

Start future profiling by locating loss between source production, acquisition,
main-thread delivery and physical presentation. Preserve full resolution,
freshest-frame delivery, buffer leases, SIP protections and restoration behavior.
The current Core Graphics backend is obsolete in the SDK, so compatibility work
must retain the ScreenCaptureKit startup fallback. Optimizing the Release build
also requires resolving its observed input failure before accepting that build.
