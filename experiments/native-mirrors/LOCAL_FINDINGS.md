# Local findings — 12 November 2026

## Purpose

Determine whether a WindowServer-hosted live mirror could replace Sunlight's
privileged native-surface renderer with SIP fully enabled. Preserve the full
product as the target, including interaction at arbitrary zoom. The current
experiment addresses the rendering mechanism; it does not implement that input.

## Source and machine

- Sunlight upstream `main`: `cf7aa16fa0035fa867529787dce02bd3d3ca5e60`, 0.2.4.
- macOS 26.4.1, build 25E253; arm64; MacBookPro18,2; 64 GiB memory.
- `csrutil status`: System Integrity Protection enabled.
- Apple Swift 6.3.1 and the installed macOS SDK are available.
- `memory_pressure -Q` reported 87% system-wide free percentage at inventory.
  This is an observation, not a reserved resource budget.

## Verified without opening a GUI

- `CAPluginLayer` is present, with `setPluginType:`, `setPluginId:`,
  `setPluginFlags:` and `setPluginGravity:`.
- `CGVirtualDisplay` and `CGVirtualDisplayDescriptor` are present. The former
  exposes `initWithDescriptor:`. No display was created.
- A command-line `CGPreflightScreenCaptureAccess` call returned true. This is
  specific to that execution identity and does not establish the viewer app's
  grant. No permission was requested or changed.
- The isolated viewer and fixture build with Clang, ARC, `-Wall -Wextra -Werror`,
  and a macOS 15 deployment target. The build uses one compiler process.
- Build output is ad-hoc signed under identities separate from Sunlight.
- Both bundle property lists pass `plutil -lint`; both signatures pass
  `codesign --verify --strict`. The build script passes `bash -n`, and the
  bundled viewer's `--inspect` command exits successfully without creating an
  application or a window.

Commands used for preparation include `sw_vers`, `uname -m`,
`sysctl -n hw.memsize`, `sysctl -n hw.model`, `csrutil status`,
`xcrun swift --version`, `xcrun --show-sdk-path`, `memory_pressure -Q`,
runtime class/selector inspection, and `experiments/native-mirrors/build.sh`.

## What is still unknown

At the initial build-only checkpoint, no GUI application had been launched.
Live same-process or cross-process pixels have not been accepted. Floating
mirrors, pan/zoom with live sources, source closure and interactive cleanup are
not qualified by the successful build.

The app records only an explicitly selected manual observation. It cannot
automatically infer pixel delivery from a layer commit or a changing source
counter. No capture latency, presentation rate, energy equivalence or full
product parity has been measured.

## First decision

Open the built viewer and start its synthetic sources. First require all four
sources to connect. If foreign copies then stay live while the canvas moves,
investigate source-window state support and native input next. Missing bindings
are a setup defect to resolve before assessing the compositor. If connected
foreign copies fail to render, retain that result when deciding whether to move
to virtual displays. Do not respond by optimizing the demo's click-through
gesture.

## First user trial and correction

The user launched the initial viewer and then clarified that the distinction
between originals and copies was unclear. The saved observation contained
`source_count: 1` and `foreign_source_count: 0`, despite the fixture manifest
publishing three separate-app windows. The viewer's Screen Recording preflight
was false in this GUI run. This does not establish the cause of the failed
lookups; those were not logged by the initial version.

**No live cross-app rendering result is accepted from that trial.** Even the
same-app animation was not unambiguously distinguished from its original.

Two preparation defects were identified in the code:

- A rejected ownership lookup was silently omitted and the unchanged source
  manifest prevented a later retry.
- The observation dialog allowed "all visible mirrors live" with only the
  same-app control connected. That was insufficient evidence for this question.

The correction keeps four labelled COPY A–D boxes visible, names the originals
to match, reports incomplete bindings, retries unresolved ownership checks,
logs their outcomes, and prevents an incomplete setup from recording cross-app
success. The normal macOS permission request is available only by explicit
user action. No permission is changed automatically.

The finite `--check-setup` regression check passed on this Mac: the first
injected lookup failure produced an `incomplete_setup` observation, the
unchanged manifest was retried, and the second binding attempt verified all
three foreign owners (`source_count: 4`). This command-line run reported Screen
Recording preflight true; it is not equivalent to the original GUI launch's
permission context. The check opened only the synthetic lab windows and closed
them after three seconds. The fixture exit record reports termination by the
viewer (SIGTERM).

Raw check records are under the local temporary run directory ending
`sunlight-mirrorlab-4CD09E1E-67FF-4B11-ACE4-09E379EACF2A`: `binding.json`,
`observation.json` and `fixture-exit.json`. The check explicitly reports
`rendering_result: unverified`. The clarified GUI still needs a visual result.

The final check also exercised a missing fixture bundle: it reported
`passed: false`, zero foreign sources and exit status 1. The successful retry
case returned exit status 0. Their raw outputs are retained in
`build/native-mirrors-clarified/setup-check.json` and
`build/native-mirrors-clarified/missing-fixture-check.json`. Both continue to
report rendering as unverified.
