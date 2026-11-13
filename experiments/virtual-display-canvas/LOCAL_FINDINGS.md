# Local findings — 12 November 2026

Source base: Sunlight `cf7aa16fa0035fa867529787dce02bd3d3ca5e60`, with the local
native-probe changes through `cbe96fd82215417de9bd5621a17cf888ad03463d`.
Machine: macOS 26.4.1 (25E253), Apple silicon, 64 GiB. SIP was enabled.

## Outcome

The final virtual-display trial captured and displayed three real windows from
a separate process through one ScreenCaptureKit display stream. The virtual
display was 1280×720 and placed to the right of the pre-existing display. Only
the fixture's exact windows were included in capture.

The qualified final run is the temporary directory ending
`sunlight-virtual-canvas-1F3D2C22-97A5-4C5D-80A0-49E6CDC88C79`:

- 193 complete frames received; 180 distinct sequences decoded from each of
  the three source windows. Counts are not a rate or latency measurement.
- Capture stopped and the source process exited.
- The new virtual display was removed; pre-existing display bounds were
  unchanged.
- `verified-viewer-1.png` shows orange, green and purple tiles, all at sequence
  36. `verified-viewer-2.png` shows all three at sequence 112, at the changed
  camera scale and position, with changed marker positions. Both images were
  inspected locally.

The actual raw result is copied to
`build/virtual-display-canvas/verified-trial.json`; its run identity is in
`verified-trial-context.json`. The per-run `captured-bank.png`, `sources.json`,
`display.json`, `enumeration.json`, `camera.json` and `result.json` are retained
locally. The helper captures only the viewer window this invocation owns.

This establishes live source acquisition and a visibly updating canvas on this
Mac. It does not establish arbitrary-app support, native input through scaled
tiles, UI smoothness under load, Retina quality, resource equivalence with
Sunlight's native renderer or release acceptance.

## Preparation failures and corrections

- The first build used a nonexistent Core Media copy function. It was corrected
  to the SDK's borrowed `CMSampleBufferGetSampleAttachmentsArray` API before
  execution.
- Signing with an available development key waited for macOS authorization.
  That owned signing process was cancelled; the experiment now defaults to
  ad-hoc signing and does not access that key.
- The first virtual source trial timed out. Its windows were not all resolved
  within the intended virtual screen. The fixture now constructs them with
  the explicit target NSScreen and sets their frame there. The failed run
  ending `5F515CA0-09BE-46CD-ABB9-BB879213A2D5` retained its nonpass and confirmed
  cleanup with existing display bounds unchanged.
- An initial screenshot helper mistakenly included the viewer process's menu
  windows when selecting its main window. That helper failed before capture;
  no visual result was accepted. The viewer now publishes its exact own window
  ID, and the helper uses that ID.
- Initial capture-only runs decoded advancing sequences but the viewer's crops
  were blank. Those were not accepted as displayed rendering. The layer crop's
  vertical coordinates and the displayed pixel-buffer lease were corrected.
  The final images above establish the corrected result.

The narrow capture checks passed earlier with 182/182/182 and 187/187/187 distinct
source sequences; those alone did not establish viewer output. They remain
separate from the final combined capture, visual and cleanup evidence.

## Remaining work

The source app currently cooperates by creating its own windows on the virtual
display. Moving user-selected third-party windows there and operating them
through the canvas is not implemented or qualified. It is the next architectural
step toward the full product. No global input, native focus manipulation of
other apps, Dock injection, audio capture or SIP changes were performed.
