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
