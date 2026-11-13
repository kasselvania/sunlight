# Native window mirrors with SIP enabled

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

The build does not open an application. In the viewer:

1. Click **Start sources**. Three ordinary source windows open in a separate app;
   a fourth source in the viewer's process is the same-app control. They contain
   only synthetic counters and moving dots.
2. Look at the four canvas tiles. Their numbers and dots should keep changing
   like their originals. Drag or scroll to pan; pinch or Option-scroll to zoom.
3. **Float a mirror** places one foreign source in this application's floating
   panel. Switch to another app yourself to see whether the mirror stays live.
4. **Record observation…** records what you saw. **Stop** closes the source windows
   and removes the mirrors. Closing the viewer also stops its sources.

Only the lab's own sources are eligible. It does not discover, mirror or move
your existing application windows. It does not request Accessibility or Screen
Recording, forward input, install a helper, change Spaces, or modify system
settings. The installed Sunlight app and its data are untouched.

The source windows initially remain visible. Covered-window behavior is a
separate question; avoid covering the originals during the first comparison.
The controls manipulate the canvas, not the content of a mirrored application.
Input at arbitrary zoom remains a requirement for the product, and is not
implemented by this experiment.

## What the outcomes mean

| Observation | Implication |
|---|---|
| All four mirrors stay live during canvas movement | The native mirror mechanism is a candidate for a SIP-enabled renderer. This does not establish interaction, cost, supported window states or full product parity. |
| Same-app control works, foreign mirrors fail | Foreign-window access is a real remaining boundary. Rendering one's own window is insufficient. |
| Everything is blank, frozen or wrong | Runtime class availability was insufficient. Preserve this result and pursue the virtual-display architecture. |

A changing sequence in the source is source telemetry, not measured capture or
presentation rate. Configuring a layer, committing it or obtaining a window ID
does not count as passing. A successful observation must come from the visible
mirrored pixels.

Build inspection is in `build/native-mirrors/inspection.json`. Each interactive
run gets a private `sunlight-mirrorlab-<UUID>` directory under the current user's
temporary directory. The UI gives its exact path. Reports contain numeric source
IDs and categorical observations; they contain no screenshots or typed content.
Run data and binaries are not committed.

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
