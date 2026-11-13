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
