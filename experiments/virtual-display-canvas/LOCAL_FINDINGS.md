# Local findings — 12 November 2026

Source base: Sunlight `cf7aa16fa0035fa867529787dce02bd3d3ca5e60`.
Machine: macOS 26.4.1 (25E253), Apple silicon, 64 GiB. SIP is fully enabled.

## Installed application outcome

The development-signed app at `~/Applications/Sunlight Canvas Lab.app`, build 3,
launched through normal macOS LaunchServices and displayed all three real
fixture windows from a separate process through one public ScreenCaptureKit
stream. The launch receipt records the installed path, parent PID 1 and Screen
Recording access. This verification uses the installed artifact's own permission.

The finite normal-launch run ends in
`sunlight-virtual-canvas-96AB0B12-EAE0-4D3F-B079-072678F609F2`:

- 205 complete frames and 188 distinct decoded sequences from each of the three
  windows; these counts are not a throughput or latency measurement.
- Both viewer screenshots were inspected. All three tiles advanced from sequence
  32 to 109; their dots moved and the camera scale/position changed.
- One capture stream, three foreign-process windows, no capture failure.
- Source process exited and the temporary monitor disappeared. The pre-existing
  displays retained their bounds.

Evidence is `build/virtual-display-canvas/verified-trial.json`,
`verified-trial-context.json`, `verified-viewer-1.png` and
`verified-viewer-2.png`. The run directory retains the source manifest, display
and capture-enumeration records, startup phases, camera change and captured-bank
PNG. The helper captures only the viewer window ID in this app's launch receipt.

A preceding interactive normal launch, run ending
`AE15ACEB-4F7A-4253-BA12-F8F1BE49C815`, also displayed all three windows. Its real
**Stop and remove monitor** button was activated through Accessibility. It
received 889 complete frames, decoded 854 distinct sequences per source and
completed all cleanup checks. Evidence is `installed-live-before.png`,
`installed-live-context.json` and `installed-interactive-stop.json` in the same
build directory.

A final normal relaunch, run ending `16295A3A-EFA5-4519-80C0-477885687759`,
started automatically with its permission intact. A real mouse drag moved the
canvas 75 points right and 30 points down while all three sources continued
updating; `final-before-drag.png` and `final-after-drag.png` retain that result.
**Fit** restored the layout. This copy was left running for the user.

The installed signed executable's SHA-256 is
`a8c7cf1d762e2529a8d0b16e471b2c014393a7b70ba868c3dc4843f2648ee81e`.
Its strict code-signature verification passed. The native build passed with
warnings treated as errors; shell/Python syntax and Git whitespace checks passed.

This proves launch, acquisition, visible rendering, local camera changes and
cleanup on this Mac. Native input through scaled tiles, arbitrary third-party
apps, menus, Retina quality, sustained load performance and full Sunlight parity
remain unimplemented or unqualified.

## Delivery failures that had hidden the working renderer

Earlier verification executed the binary directly from the coding agent. Those
runs inherited capture access available to that launch route and did not prove
normal application launch. The old helper and the resulting delivery claim were
insufficient. The helper now uses LaunchServices and defaults to the installed
app.

The old app explicitly repositioned the virtual monitor after macOS created it.
Normal launches failed at that unnecessary display-configuration transaction.
The transaction is removed; both source and viewer use the OS-assigned bounds.

Direct screen inspection confirmed the user's report: the old **Virtual Display
Canvas** entry was enabled while the replacement signed app's capture preflight
returned false. Signing the current app alone did not repair that old entry.
Adding the exact installed bundle changed the visible entry, but the initial
Quit & Reopen launched an older ad-hoc staging copy with the same bundle ID.
Its launch receipt identifies the wrong path. Multiple launchable candidates
were therefore a concrete delivery defect.

All four owned staging bundles with that ID were unregistered where registered
and quarantined with `.app.disabled` suffixes. One never-registered signed staging
bundle returned LaunchServices error -10814 when unregistering; it was also
quarantined. Through the normal System Settings UI, only this experiment's stale
permission entry was removed and the exact signed installed bundle was added.
The following normal launch had access and rendered live windows. Other apps'
grants were untouched. No TCC database was modified and no global privacy reset
was run. A read-only attempt to inspect the targeted TCC record was denied, so
this report does not claim to have inspected its internal code requirement.

The build now requires an explicit signing selection. The canonical installation
uses the existing Apple Development key; it does not create or export keys.
The user approved macOS's Keychain dialogs. Its designated requirement is tied
to the bundle identifier, Apple certificate chain and development identity,
replacing the previous ad-hoc hash-only requirement.

## Earlier renderer corrections

Initial source trials could not resolve all windows on the virtual monitor.
The fixture now constructs each window with the explicit target NSScreen.
Initial capture-only runs decoded sequences while the viewer showed blank
crops. The vertical crop conversion and displayed CVPixelBuffer lifetime were
corrected; those earlier capture-only passes do not establish visible output.
A screenshot helper initially selected menu windows; the viewer now publishes
its exact main window ID. An initial compiler call used a nonexistent Core Media
copy function and was corrected to the SDK's borrowed attachments API.

The earlier command-line run ending
`1F3D2C22-97A5-4C5D-80A0-49E6CDC88C79` received 193 frames and decoded 180 distinct
sequences per source, with inspected viewer snapshots advancing 36 to 112 and
passing cleanup. That remains command-line evidence, separate from the installed
normal-launch result above. The failed native-mirror experiment is retained under
`experiments/native-mirrors`; foreign-process CAPluginLayer mirroring did not
work on this Mac.

## Redesign implementation after the renderer proof

The redesign now starts in Sunlight's original Swift canvas, rather than adding
input to the synthetic Objective-C fixture. The full product requirements and
replacement directions are in the root README. The new launch profile bypasses
legacy setup, migration, injection, takeover and updating. Its bundle omits the
privileged loader and launch daemon. Development data is isolated from Sunlight.

The initial bridge maps a scaled tile's pointer back to its real window, obtains
focus with Accessibility and app activation, and posts addressed input to that
app. It uses private `CGEventSetWindowLocation` and the AppKit window-number
field, informed by the primary [TouchBridge implementation](https://github.com/theofanisv/touch-bridge/blob/main/Sources/TouchPlatform/DirectTarget.swift).
This is an OS-compatibility dependency, not a SIP exception. A nonactivating
canvas panel remains above the source, and the canvas forwards each press's
matching drag and release. Native global-pointer polling and
other input families are not established by this implementation.

Development-route checks used a disposable TextEdit document at about 80% zoom.
Different content clicks changed the native selection range, typing inserted at
the clicked location, a horizontal drag selected 16 characters, and scrolling
changed the real scrollbar while the canvas camera stayed fixed. These were
observed through TextEdit's Accessibility state, rather than inferred from
posted-event counts. The build and 19 focused coordinate, camera and handoff
checks passed. No throughput or input-latency measurement is claimed.

During development, named window-under-pointer fields alone failed to address
AppKit mouse input. The bridge now supplies the window number and relative
location. The nonactivating panel also needs to release key focus, and the
existing capture view rejected first clicks while another app was active;
the redesign now accepts them. A preparation helper initially omitted a move
before its generated drag, invalidating early comparisons. A native baseline
exposed that helper defect. An unchanged nonempty selection was also insufficient
evidence of a delivered click; subsequent checks deliberately changed the
caret location and verified insertion there.

## Installed redesign build 6

The Swift redesign at `~/Applications/Sunlight Canvas Lab.app` now passes its
separate normal-launch check. The first accepted process was PID 48349, parent
PID 1, with the exact installed bundle path and both Screen Recording and
Accessibility access. SIP remained fully enabled. The earlier Screen Recording
grant survived the update. Through normal system UI, the app's disabled
Accessibility entry was enabled and its Desktop-folder prompt was allowed.
The user approved the existing signing key in macOS's native Keychain dialog.

Using the real canvas at zoom `0.8034155081305423`:

- Two content clicks placed TextEdit's native caret at offsets 395 and 867.
  Six individual virtual-key letters inserted at each location; the caret and
  document length each advanced by six, to offsets 401 and 873 respectively.
- A horizontal drag selected 16 characters at offset 395. The real vertical
  scrollbar then advanced from `0.06877729257641921` to `0.07860262008733625`.
- The camera's position and zoom stayed exactly fixed. Both screenshots of
  this owned document's captured tile were inspected: the edits and selection
  appeared in the viewer, not just the source's Accessibility state.
- Nine window streams reported active with frames, exceeding the old
  eight-stream policy. The requested cadence was 100 fps. This is not a
  delivered-frame-rate, latency or sustained-load measurement.

Evidence is under `build/sip-redesign`: `installed-input-evidence.json`,
`installed-typed.png`, `installed-selected.png` and the individual native-state
observations. The GUI check uses synthetic pointer and individual key events
against an owned TextEdit document. It establishes this bounded functional
path; it is not physical human-input or broad application-compatibility testing.

The first process exited cleanly. A second normal launch, PID 53779 with parent
PID 1, retained both permissions. It was then quit and its exit confirmed. The
owned test document was closed. These results are retained in
`installed-cleanup.json`, `installed-relaunch.json` and
`installed-final-cleanup.json`. The installed app is left closed.

Strict deep signature verification, the debug build, 19 focused checks, shell
syntax and Git whitespace checks passed. The installed executable SHA-256 is
`237e76f18b979204ac3ad0428f6b3f08df2cea44b1cd1955492f5f6287ecf544`.

Earlier installed candidates exposed a stuck TextEdit mouse-tracking loop and
intermittent selection. Those failures were not accepted. The final bridge
constructs fresh destination mouse events, preserving modifiers and click count
without carrying over the canvas's timestamp, event number or pressure metadata.
It primes the destination with a mouse move, and latches the canvas press only
after target preparation has cleared the previous gesture. The extra global
mouse interception was removed. The final normal-launch check above passed
without that layer.

Virtual-display integration, covered Spaces consolidation, complete menus and
window families, native drag and drop, IME, global-pointer-dependent apps,
multi-display behavior and sustained performance still require implementation
or qualification before the full redesign can be called complete.

## Installed window bank build 7

2026-11-13: the bank is integrated into the original Swift Sunlight target, not
just the earlier Objective-C renderer experiment. The installed identity remains
`com.kasselvania.sunlight.virtualcanvas`, at
`~/Applications/Sunlight Canvas Lab.app`. Normal LaunchServices launches retained
Screen Recording and Accessibility access. SIP remained fully enabled; no boot
arguments, injected add-on, privileged service or privacy-database modification
was used.

`SourceBankHost` owns the temporary display and exact Accessibility window
handles. It journals the original AX/Quartz geometry, window number, owning
process birth and document URI when available before each placement. The canvas
owns world layout and input; the host's native source positions never replace
canvas coordinates. `SourceBankCapture` supplies one ScreenCaptureKit display
feed, with immutable geometry per stream and cropped, retained pixel buffers for
each tile. A private pipe's EOF restores the originals after a main-process
crash. A helper crash triggers a recovery-only child. Interrupted disk recovery
runs before `Desk` discovers windows. Failed restoration retains the journal;
clean quit requires its retirement, including when no host process remains.

The actual virtual display settled at `{-3072, 0, 3072, 2048}`, backing scale 2.
Its placement comes from macOS; no physical display configuration was rewritten.
The owned Safari window occupied `{-3048, 64, 1100, 850}` and TextEdit
`{-1932, 64, 673, 439}`. Together their capture ROI was 1789 × 850 logical points,
3578 × 1700 backing pixels. Unsupported or oversized windows fall back to the
existing per-window path. This finite bank does not establish unlimited capacity.

Earlier mode probes found that 4096 × 3072 and 4096 × 2048 logical modes could
return a display ID without becoming an online display. Those candidates were
rejected. The implementation now waits for actual active-display membership,
separate bounds and Retina backing before parking anything. Display removal is
checked with a fresh `CGGetActiveDisplayList`; the creating process's
`CGDisplayIsActive` observation could remain stale after teardown.

The delivered interaction fix uses a private mouse-event source and a shared,
increasing event number for each down/drag/up sequence. `needsPanelToBecomeKey`
keeps captured content from stealing native editing focus. Focus preparation
uses the exact AX window number, with no nearest-frame substitution. Three
repeated development focus/edit/selection cycles passed after this correction.
Earlier covered-tile preparation was invalid; subsequent native-control checks
used the real Windows on Canvas menu and refused pointer/key input unless the
owned TextEdit tile was the intended target.

The final signed installed app was checked with two owned windows, a real Safari
process displaying a local animation and a disposable TextEdit document:

- Both originals were parked off the physical display and shown through one
  shared Retina feed. Browser screenshots show changing frame numbers and a
  moving dot. TextEdit's captured tile visibly showed the inserted text and
  selection.
- Native AX observations verified a clicked caret, insertion of six individual
  virtual-key letters, a 17-character drag selection and an increased vertical
  scrollbar value. Editing/scrolling left the camera fixed.
- Plain scrolling over empty canvas panned it; modifier scrolling with the
  canvas reactivated changed zoom. Native source positions stayed fixed.
- Double-clicking the TextEdit tile's title released it from the bank and entered
  the existing native handoff at zoom 1. Returning through Windows on Canvas
  parked it again; the shared feed settled back to the two-window ROI.
- Clean quit restored both original positions, exited the child, removed the
  owned display and cleared the journal.
- Killing only the main app exercised real pipe EOF: the surviving host restored
  both sources and removed its display and journal.
- `SIGUSR1` to the positively identified host released its actual virtual display.
  The display-disconnect path restored both windows while the canvas remained
  available through ordinary capture.
- Killing only the host exercised automatic journal recovery while the main app
  remained open. The originals returned and the bank stopped without retaining
  a display or journal.
- Stopping the host, killing the main app, then killing that host left a genuine
  interrupted journal. A normal relaunch with parking scoped to an empty set
  recovered both sources before canvas discovery. Final quit removed the new
  empty display. Fresh active-display enumeration returned only physical ID 2.

Evidence is under ignored `build/sip-redesign/bank-check`: `installed-start.json`,
`installed-functional.json`, `installed-text.png`, `installed-browser-0.png`,
`installed-browser-1.png`, `installed-frame-observation.json`,
`installed-parent-crash.json`, `installed-display-disconnect.json`,
`installed-host-crash.json`, `installed-both-crash-relaunch.json`,
`installed-final-cleanup.json`, `installed-artifact.json` and
`final-verification.log`. `verify-final.py` runs the bounded installed workflow;
it scopes parking to the two owned window IDs and pins main/host identity before
sending failure signals. These are synthetic native-UI checks, not physical
human-input or broad application acceptance.

The final eight-second observation delivered 23.75 complete frames/s in the
observed mixed workload while requesting 100. This remains a performance gap, not a 100 Hz
success. Modifier-scroll zoom after captured editing currently needs canvas
reactivation; the uninterrupted source-focused path did not pass. Some inherited
tile labels also overlap other content. Window families and menus, source
resizing, bank capacity, IME, native drag and drop, global-pointer polling,
unresponsive applications and physical-monitor removal remain unqualified.
The source-display disconnect check does not substitute for monitor unplug.
Covered Spaces consolidation remains unimplemented. No full-product-parity or
input-latency result is claimed.

The final control script also rejected an earlier navigation preparation: its
fixed "empty canvas" coordinate was covered when the camera returned home. The
helper now derives an empty point from all current tile rectangles and refuses
to post the pan/zoom unless that point is clear. The rejected run is retained as
`final-preparation.log`; it was not used as a successful navigation observation.
The final successful native caret/typing/selection offsets were 660, 666 and
`{660, 17}`. The inspected Safari frames advanced from 415385 to 415550 with the
dot visibly moving. Twenty-three focused coordinate, camera, handoff and bank
geometry checks passed. Build, shell syntax, strict deep signature and Git
whitespace checks passed.

The final installed executable SHA-256 is
`2ac5f2711bd07cd2b4d5d64cb420ac86ef889fc6656ef6e26a17f366808f1e83`.
The app is left closed after restoration; only the two owned fixture windows
were closed during cleanup.

## Capture performance build 8

2026-11-13: the original Swift app now supplies two fixed 3072 × 2048 logical,
2× Retina source displays. First-fit placement spans both displays while keeping
their native rectangles independent of canvas layout. Each journal record names
its display; the reader still accepts build 7's singular-display journal. The
signed, unprivileged restoration process has its own executable and signing
identifier inside the canonical app, rather than starting another main-app GUI
instance. No SIP exception or injected component was added.

The measurements isolated contention between capture streams. With the original
two-window bank and eight ordinary window streams on the same ten-window desktop,
the animated bank delivered 23.50 complete frames/s. Changing queue depth or
reducing output scale while keeping that contention did not remove the limit.
A no-op frame receiver also saw the limit, so a slow canvas draw was not its cause.
An isolated display feed was much faster. This motivated enough bank capacity
to replace the overflow streams, rather than reducing image quality.

Two-bank ScreenCaptureKit trials delivered 61.63 frames/s with selected windows,
and 68.51 with the composed display. A composed Core Graphics display stream
delivered 86.99 received and applied frames/s in development. The preferred
backend wraps its IOSurfaces in pixel buffers without copying their pixels.
Retaining a surface alone is insufficient: each buffer also carries an explicit
IOSurface pool use-count lease, released only after its final reader. The current
ScreenCaptureKit composed-display feed remains the startup fallback when the
optional Core Graphics symbols are missing or start is rejected. The latter API
is obsolete in the SDK; its working runtime on macOS 26.4.1 is a compatibility
dependency, not a supported-forever guarantee.

The first two normal installed Debug launches delivered 94.42 and 93.50 complete
and applied frames/s in twelve-second observations of the animated bank. All ten
windows were banked with no overflow capture. The two ROIs were 5418 × 3696 and
5770 × 3112 pixels, exactly 2× their logical bounds. Only Safari was continuously
animated. The other bank emitted very few new frames, correctly reflecting its
mostly static content. Rates are per bank and must not be summed. Source frame
counts, received frames, applied frames and requested display rate are distinct;
this does not establish physical presentation of every frame or input latency.

The installed app accepted a click at caret 315, six individual virtual-key
letters advancing the caret to 321, and a 17-character drag selection. Browser
screenshots advanced from frame 251538 to 251675 with a moving dot. Native
handoff released TextEdit, and Show Canvas parked it again with the other nine
windows. These native-UI checks remain distinct from physical human input.

Focusing a source while its canvas press was held also delivered an untagged
canvas drag/release to the source PID. A per-destination PID event tap corrects
only those foreign-window events, using the same camera/native-coordinate map
and gesture number as the existing bridge. It passes other events unchanged.
The tap subscribes to the complete PID stream because a restricted mouse mask
starved AppKit keyboard delivery during tracking. There is no global HID tap.

Optimized Release candidates failed typing and are not qualified. The delivered
development script retains its original Debug configuration, where installed
typing and selection passed. Earlier measurements obscured by stacked capture
consent dialogs were rejected. Native UI approval cleared requests belonging
only to the authorized Sunlight/T3 capture trials. Input Monitoring was enabled
during investigation; these observations do not establish independence from
that grant. Cleanup controls inadvertently toggled Canvas Lab's Accessibility
grant off; it was restored through System Settings before the accepted relaunch.
No privacy database was edited or reset.

The first four two-bank failure exercises restored their three owned windows:
main crash, one actual source-display removal, host crash with automatic journal
recovery, and both processes dying followed by normal relaunch. They also exposed
three additional capture-consent requests. The stopped native feed was attempting
ScreenCaptureKit fallback on a disappearing display. Runtime feed failure now
stops and restores the bank; fallback is selected at startup only. The final
artifact repeats the affected installed and recovery checks below.

An earlier recovery fixture was 1700 points tall on a 1447-point physical display.
macOS repositioned it after virtual-display removal, so that observation failed
exact-frame restoration. The retained `recovery-oversized-fixture.log` is not a
pass. A 3000 × 1300 owned window forces placement across both banks while fitting
the physical screen. Oversized-window recovery remains a separate gap.

Evidence is under ignored `build/sip-redesign/performance`: `baseline.json`,
`multi-development.json`, `multi-native.json`, `multi-sck-composed.json`,
`installed-before-stop-fix.json`, the installed screenshots, and
`recovery-before-stop-fix.log`. Final artifact evidence is recorded separately.
The retained gaps from build 7 still apply, including overlapping title labels,
source-focused modifier navigation, window families, menus, native drag and drop,
IME, global-pointer polling, physical-monitor unplug, capacity beyond two banks,
covered Spaces consolidation and full product parity. Sustained 100 Hz and
all-windows-animated workloads remain unqualified.

Final installed artifact: the twelve-second animated-bank observation delivered
93.01 complete and 93.09 applied frames/s, at the same full 2× output sizes with
all ten windows banked and no refusals. The one-frame boundary difference between
the counters is sampling granularity, not a second source of frames. Caret,
six-letter insertion and 17-character selection passed again. The final four
failure exercises each restored all three owned windows to their recorded
frames, removed both displays and retired the journal. Each case checked for
new Sunlight capture-consent dialogs through native Accessibility; all four
counts were zero. Ordinary capture consent remains required by macOS.

`installed-build8-final.log`, `installed-verification.json`, `installed-rate.json`,
`recovery-build8-final.log`, `parent-crash.json`, `single-bank-disconnect.json`,
`host-crash.json`, `both-crash-relaunch.json`, `interrupted-journal.json` and
`installed-artifact.json` bind these final observations. The build, 33 focused
tests (including real IOSurface lease lifetime and legacy journal decoding),
strict deep signature, shell syntax and whitespace checks passed. The installed
executable SHA-256 is
`c0ef72d3c8f45c9a082b407c3903ad33010e2160ec35efbcccd2e30b3e46ec96`.
Final cleanup closes only the three owned fixture windows. The app remains
closed, the journal is absent, and only physical display ID 2 remains active.
Native cleanup found none of the owned IDs in the apps' AX windows or the
on-screen list. Quartz retained one unmapped Safari metadata entry after close;
that entry was not counted as an active window. The user's source apps were not
force-quit.

### Performance milestone acceptance

2026-11-13: the project owner accepted the observed near-100 fps result for this
stage and authorized moving on with optimization locations clearly marked.
Sustained 100 fps remains a later optimization target. This acceptance does not
change the measured values above or close the remaining product gaps. The
[performance map](../../docs/sip-redesign-performance.md) lists the exact code
entry points, measurement meanings and constraints to preserve. Matching source
comments are searchable as `SIP PERFORMANCE`.
