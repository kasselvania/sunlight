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

No GUI application has been launched for this experiment at this checkpoint.
Live same-process or cross-process pixels have not been accepted. Floating
mirrors, pan/zoom with live sources, source closure and interactive cleanup are
not qualified by the successful build.

The app records only an explicitly selected manual observation. It cannot
automatically infer pixel delivery from a layer commit or a changing source
counter. No capture latency, presentation rate, energy equivalence or full
product parity has been measured.

## First decision

Open the built viewer and start its synthetic sources. If foreign mirrors stay
live while the canvas moves, investigate source-window state support and native
input next. If only the same-app control works, or all mirrors fail, record that
result and move to the virtual-display design. Do not respond by optimizing the
demo's click-through gesture.
