# Native window mirrors with SIP enabled

**Result on macOS 26.4.1: this implementation did not render separate-app
windows, including with Screen Recording granted.** The originals contained
pixels and all three foreign owners were verified; only the same-app control
rendered. Retain this directory as a reproduction of that negative result.
The current experiment is [the virtual-display canvas](../virtual-display-canvas/README.md).

This is a renderer feasibility experiment for preserving Sunlight's full experience
without disabling SIP. It investigates an alternative to both Dock injection and
one capture stream per window. It does not run Sunlight's normal application.

The candidate mechanism is `CAPluginLayer` with plugin type
`com.apple.WindowServer.CGSWindow`. The window server historically drew a live
window inside this layer. Class availability on a current OS does not establish
that mirroring is allowed or working.

## Try it

From the repository root:

```sh
experiments/native-mirrors/build.sh
open "build/native-mirrors/Native Mirror Viewer.app"
```

The build does not open an application. Quit an older lab viewer before opening
the rebuilt one. In the viewer:

1. Click **Start sources**. Four separate windows titled **ORIGINAL A** through
   **ORIGINAL D** open. A is a same-app control; B–D belong to the separate fixture.
   They contain only synthetic counters and moving dots.
2. Look **inside the dark canvas**, at boxes **COPY A**, **COPY B**, **COPY C** and
   **COPY D**. Each must show its original's changing number and moving dot.
   Seeing the separate originals animate does not establish that copying works.
   A box saying **No copy connected** is an incomplete setup, not a live mirror.
3. If setup is incomplete, the status gives the connected count. The viewer
   retries failed lookups. **Allow window access…** offers a normal macOS Screen
   Recording request when access has not been granted to this viewer. Request it
   only through that explicit action; if macOS requires a relaunch, quit/reopen
   the viewer, then start the sources again. SIP remains enabled.
4. With all four copies connected, drag or scroll inside the canvas to pan;
   pinch or Option-scroll to zoom. The four copies must keep changing.
5. **Float COPY B** places that foreign source in this application's floating
   panel. Switch to another app yourself to see whether the mirror stays live.
6. **Record what I see…** records what happened inside the canvas. An incomplete
   setup is always recorded as incomplete; it cannot claim cross-app success.
   **Not sure** records an inconclusive observation.
   **Stop** closes the source windows
   and removes the mirrors. Closing the viewer also stops its sources.

Only the lab's own sources are eligible. It does not discover, mirror or move
your existing application windows. It does not request Accessibility. Only the
explicit **Allow window access…** action can request Screen Recording through
normal macOS UI. It does not forward input, install a helper, change Spaces or
modify system settings. The installed Sunlight app and its data are untouched.

The source windows initially remain visible. Covered-window behavior is a
separate question; avoid covering the originals during the first comparison.
The controls manipulate the canvas, not the content of a mirrored application.
Input at arbitrary zoom remains a requirement for the product, and is not
implemented by this experiment.

## What the outcomes mean

| Observation | Implication |
|---|---|
| All four connected copies stay live during canvas movement | The native mirror mechanism is a candidate for a SIP-enabled renderer. This does not establish interaction, cost, supported window states or full product parity. |
| Fewer than three separate-app copies connect | Setup is incomplete. Check `binding.json`; this does not establish whether the compositor could draw the missing windows. |
| All four connect, but only COPY A animates | Foreign-window rendering remains a boundary. Rendering one's own window is insufficient. |
| All four connect, but the copies are blank, frozen or wrong | Runtime class availability was insufficient to establish live rendering. Preserve this result before deciding whether to pursue the virtual-display architecture. |

A changing sequence in the source is source telemetry, not measured capture or
presentation rate. Configuring a layer, committing it or obtaining a window ID
does not count as passing. A successful observation must come from the visible
mirrored pixels.

Build inspection is in `build/native-mirrors/inspection.json`. Each interactive
run gets a private `sunlight-mirrorlab-<UUID>` directory under the current user's
temporary directory. The UI gives its exact path. Reports contain numeric source
IDs and categorical observations; they contain no screenshots or typed content.
Run data and binaries are not committed.

`binding.json` records each foreign-window lookup and the number connected.
`fixture-exit.json` records the source process's exit. Unchanged manifests with
unresolved windows retry once a second; a failed initial lookup is not cached
as a permanent absence.

## Setup regression check

```sh
"build/native-mirrors/Native Mirror Viewer.app/Contents/MacOS/NativeMirrorLab" --check-setup
```

This opens only the lab's windows for three seconds. It makes the first lookup
unavailable, verifies that recording produces an incomplete result, then retries
against the real window server with the unchanged manifest. Success requires
all three foreign owners to be verified. It does not inspect the pixels or
declare live rendering successful. It never requests a permission.

Set `MIRROR_LAB_BUILD_DIR` to a different absolute directory when building while
an earlier viewer is still running, so its signed executable is not replaced.

If the viewer is force-quit, its fixture notices that its parent process has
ended and quits. No source process is deliberately left running.

## Implementation and ownership

The viewer starts its own fixture executable and checks its process ID and run
token. Before binding a foreign window it checks the window's current owner.
When the fixture ends or a source closes, the corresponding mirrors are removed;
there is no substitution with a different app or a screen crop. A floating panel
holds an additional mirror and never changes the source window's native level.

The private mirror API accepts a numeric window ID. The owner check is not an
atomic WindowServer lease on that ID; it does not establish safe binding to
arbitrary third-party windows across destruction and ID reuse. This experiment
is restricted to its own controlled source processes. A product backend would
have to resolve that lifetime boundary rather than treating the check as a
general authority guarantee.

Two bundles have stable identities separate from Sunlight:

- `com.kasselvania.sunlight.mirrorlab.viewer`
- `com.kasselvania.sunlight.mirrorlab.fixture`

The bundles are ad-hoc signed and need no exported credentials. The build uses
one compiler process and does not invoke the root Makefile, package scripts,
Sparkle, Dock add-on or normal app bootstrap.

## Research basis

- Sunlight baseline: `cf7aa16fa0035fa867529787dce02bd3d3ca5e60` (0.2.4).
- [Diorama](https://github.com/avaidyam/Diorama) demonstrates the historical
  `CAPluginLayer` window-mirroring mechanism.
- [localscreenshare](https://github.com/derpmacos/localscreenshare) documents
  viewing-only support for macOS 10.9–10.14.
- [Original API investigation, 2018](https://aditya.vaidyam.me/blog/2018/02/17/).
- [orcv](https://github.com/jasonjmcghee/orcv) and
  [DeskPad](https://github.com/Stengo/DeskPad) are references for the alternative
  virtual-display architecture.

The implementation here is new code. The historical projects provide API
research, not evidence that this mechanism works on the current Mac. Their
Space-creation code and other private window-management operations are not used.
