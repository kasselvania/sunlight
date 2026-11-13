<div align="center">

<img src="docs/images/icon.png" width="128" height="128" alt="Sunlight's icon: a black sun on yellow">

# Sunlight

**The first camera-based inifinite canvas window manager for Mac**<br>
Free, open source and yours forever.

[![macOS 15+](https://img.shields.io/badge/macOS-15%2B-black?logo=apple)](#requirements)
[![Apple silicon](https://img.shields.io/badge/Apple%20silicon-only-black)](#requirements)
[![Beta](https://img.shields.io/badge/status-beta-f5c518)](#beta-heads-up)
[![MIT licence](https://img.shields.io/badge/licence-MIT-blue)](LICENSE)

[**Download for Mac**](https://github.com/spacefarm-digital/sunlight-releases/releases/latest/download/Sunlight.dmg)
&nbsp;·&nbsp; [Homebrew](#install)
&nbsp;·&nbsp; [sunlight.software](https://sunlight.software)
&nbsp;·&nbsp; [How it works](docs/how-it-works.md)

</div>

<p align="center">
  <img src="docs/images/hero.gif" width="800" alt="Sunlight in action: from inside Safari out to the canvas with five windows, zooming and panning, then back into Safari at full size">
</p>

---

## What is this?

Your Mac stacks windows on top of each other like a pile of pizza boxes. Sunlight lays them all out
on a canvas that goes on forever instead. Every window you have open stays on it, live, right where you
put it. Pinch out and your whole day is in front of you. Click one and it grows into the real window at
its real size, no seam, no "preview", and you just keep working.

Desktop widgets and the files on your desktop live on the canvas too, and ⌘Tab, Mission Control and Show
Desktop all land on it. So it's still your Mac. It just has room now.

<p align="center">
  <img src="docs/images/hero.png" width="800" alt="The canvas zoomed out to 23%: Safari, TextEdit, Calculator, Finder and Terminal laid out over the wallpaper, desktop files on the left and the minimap in the corner">
</p>

## Features

- 🗺️ **One infinite canvas.** Pan with two fingers, pinch to zoom, four-finger drag to pan from anywhere,
  even over a window.
- 🪟 **Real windows, not screenshots.** With live windows on, the canvas shows the actual windows, scaled
  in place by a small add-on in the Dock. At 1:1 you can click, type and scroll in them right there.
- 🎯 **Seamless handoff.** Click a window to step into it where it is; double-click to bring it to the
  middle. The Mission Control key (F3) or a four-finger tap takes you back out, and again takes you back in.
- 🧲 **Neat without trying.** Windows snap to guides and a grid as you drag, resize from their edges, and
  can shove each other out of the way if you want them to (Settings › Windows).
- ⌨️ **Move & Resize keys.** ⌃⌥ + arrows for halves, plus quarters, thirds, two-thirds, full screen and
  centre.
- 💾 **Layouts.** ⌘S saves where everything is, ⌘1 – ⌘9 brings it back, reopening apps and documents that
  were closed.
- 🖥️ **Your desktop comes along.** Finder's desktop files are the canvas floor (open, drag, rename, drag into
  a window), widgets sit beside your windows, and Show Desktop (F11 or the four-finger spread) flies there.
- 🖼️ **Picture in Picture, for any window.** Right-click a window › Picture in Picture (⌃⌥P) and it flies
  into a corner as a small live tile, like a video does, while you work in anything else: a call, a video,
  a timer. Drag it between corners, tuck it off the side; a click brings it back full size.
- 🫥 **Nothing gets lost.** Hidden and minimized windows keep their spot, shown dashed in the minimap.
- 🌄 **Backgrounds** from your wallpaper, Photos, files, colours or gradients, with blur and dim that follow
  the zoom.
- 🦸 **Takeover mode.** Hides the Dock and makes ⌘Tab, Mission Control and Show Desktop work on the canvas.
  Quit, and every setting it touched goes back how it was.
- 🧪 **Experimental**, off until you flip them in Settings › Experimental: Arrange and Tidy,
  strip mode (every app on one endless strip), and a canvas on every display.

## SIP-enabled redesign standards — this branch

The objective is the complete Sunlight experience with **every SIP protection enabled**.
Keep Sunlight's existing implementation wherever it supplies the required behavior. Replace the Dock
add-on's privileged operations with direct ports, equivalent behavior or equally usable engineering
alternatives. A working renderer experiment is evidence for one component, not product completion.

| Product area | Required standard | Implementation direction |
|---|---|---|
| Security and startup | No SIP changes, boot arguments, Dock injection or privileged loader. A stable signed app opens normally and keeps its privacy identity. | Explicit SIP-enabled launch profile; omit the injected helper from its bundle. |
| Canvas navigation | Preserve the existing camera, inertia, easing, snapping and gestures. Rendering follows the display cadence independently of source capture. | Reuse `CanvasView`, `Camera`, `Motion` and the display link. |
| Live windows | All visible app windows remain live and sharp at their displayed size. The demo's eight-stream and 30/15/10 fps limits are not the redesign's quality standard. | Shared virtual-display feed integrated with the existing canvas; ordinary window capture remains the fallback when a window cannot be parked. |
| App interaction | Click, type, select, scroll and drag through a window at its current canvas zoom. Input reaches the intended real app/window without changing the camera merely to make input possible. | Explicit coordinate/focus bridge; retain existing window controls and canvas gestures. |
| Focus and handoff | Preserve click/focus, zoom-to-window, return-to-canvas and native-window access. No flashes of unrelated windows. | Reuse existing navigation; replace privileged native transactions with covered transitions where needed. |
| Window management | Preserve move, resize, close, minimize, hide, stacking, groups, snapping, pushing, Arrange, Tidy and strip mode. | Existing model and Accessibility operations; compose visible order in Sunlight. |
| Layouts and recovery | Preserve saved layouts, app/document reopening and hidden/minimized window positions. Quit and recovery release owned resources and do not strand windows. | Reuse persistence and recovery; keep redesign development data separate from installed Sunlight. |
| Desktop integration | Preserve Finder files, widgets, Show Desktop, shortcuts and application switching. | Port existing behavior and replace only the privileged dependencies. |
| Picture in Picture and appearance | Preserve live pinned tiles, tucking, return, backgrounds, shadows, opacity and rounded corners. | Own captured tiles/panels and existing effects code. |
| Displays and Spaces | Preserve per-display canvas behavior and the final Desktop consolidation result, leaving full-screen app Spaces alone. | Normal Mission Control Accessibility actions underneath a covering animation. |
| Spaces transition concession | Desktop consolidation may take longer underneath a smooth, reactive cover. Completion follows real OS state. This concession applies at startup/reorganization, not to everyday interaction or frame rate. | A stationary covering window; no timer-only claim that OS work finished. |
| Performance | Match the connected display's cadence where content supports it. Build 8's observed near-100 fps performance is accepted for the current stage; sustained 100 fps remains an optimization target. | Reuse display-linked rendering and newest-frame delivery. See the [performance map](docs/sip-redesign-performance.md) for evidence and code entry points. |

The redesign now combines interaction through Sunlight's existing captured tiles with a shared
virtual-display window bank. Spaces automation and its cover, complete window-family handling,
native input compatibility and sustained performance remain required work until actually
demonstrated. Development launches do not consolidate the user's Desktops.

### First implementation slice

`scripts/build-sip-redesign.sh` builds the original Swift Sunlight target in a separate launch
profile. It forces captured windows, retains the existing camera and controls, removes the demo
stream-count and frame-rate policies, and adds window-addressed input through scaled tiles.
The source app receives focus while a nonactivating canvas panel stays above its native window.
The canvas retains each captured press through its matching release, and primes the destination's
pointer state before a click. Canvas chrome and modifier gestures continue through the existing handlers.

The bridge uses Accessibility, PID event posting, private event addressing (`CGEventSetWindowLocation`
and the window-number field), and no injected code. That private API is an OS-compatibility dependency;
its availability and a successful TextEdit interaction do not establish compatibility with every app.
Context menus, child windows, native drag and drop, IME and apps that poll the global pointer still
need implementation or qualification. Covered Spaces consolidation is not integrated. The rest
of Sunlight's application integration remains to be ported.

Build and install using the existing development identity so the app keeps its privacy identity:

```sh
SIGN='your existing development signing identity' scripts/build-sip-redesign.sh --install
open "$HOME/Applications/Sunlight Canvas Lab.app"
```

The canonical bundle ID is `com.kasselvania.sunlight.virtualcanvas`. Build staging uses `.bundle`
directories so macOS does not register competing launchable copies. This profile keeps its layouts,
backgrounds and logs separate from installed Sunlight. Its diagnostic session file is
`~/Library/Application Support/Sunlight SIP Redesign/redesign-session.json`; requested fps and posted
input counts in that file are not delivered-frame or successful-interaction measurements.

The installed build 6 has been verified through normal macOS launch on this Mac with SIP enabled.
TextEdit accepted clicks at two positions, keyboard input at each clicked caret, selection and scrolling
through an approximately 80% tile while the camera stayed fixed. The visible tile reflected those edits.
Quit and normal relaunch preserved access. See the [local findings](experiments/virtual-display-canvas/LOCAL_FINDINGS.md#installed-redesign-build-6)
for the bounded evidence and the earlier failures. Sustained performance and full product parity remain open.

### Window bank integration — build 7 baseline

The same Swift app now parks eligible real windows on one temporary Retina virtual display and
crops their live tiles from one ScreenCaptureKit display stream. Native source placement is separate
from canvas layout: pan, zoom and tile stacking do not rearrange the bank. Windows that cannot be
identified exactly through Accessibility, or cannot fit, stay on their original display and use the
existing capture path. The current bank is 3072 × 2048 logical points at 2× backing scale; it is a
bounded first implementation, not an unlimited-window solution.

An unprivileged child of the signed app owns the display and original-window placements. It writes
process birth, exact window identity and original geometry before moving anything. Normal quit and
parent-process death restore the originals before releasing the display. Helper failure triggers
journal recovery; a relaunch also recovers an interrupted journal before discovering canvas windows.
Failed restoration retains its record and does not report a clean quit. No injected helper or SIP
exception is involved. Virtual-display creation and addressed input use private macOS APIs, which
remain compatibility dependencies.

Open the installed app normally. **Windows on Canvas** brings a covered tile forward. Double-click
its title strip for native-window access; **Show Canvas** returns to the canvas. **Return Originals
and Stop Bank** restores the sources while leaving the ordinary capture canvas available; **Start
Window Bank** starts it again. Quit restores sources and removes the owned display.

The installed signed build was exercised with an owned TextEdit document and a real Safari window:
live browser motion, native caret placement, insertion, selection, scrolling, camera movement,
native handoff and return. Main-process crash, helper crash, actual source-display teardown, and
both-process crash followed by relaunch all restored the sources. These checks scoped parking to
the two owned windows; broad application and capacity compatibility remain open.

The shared stream delivered roughly **24 complete frames/s** in the observed mixed workload while
requesting 100; this does not meet the product's 100 Hz performance target. Modifier-scroll zoom
currently requires reactivating the canvas after captured editing. Window families, menus, IME,
native drag and drop, global-pointer-dependent apps, bank resizing/capacity and physical-monitor
unplug remain required work. See the [build 7 findings](experiments/virtual-display-canvas/LOCAL_FINDINGS.md#installed-window-bank-build-7).

### Capture performance — build 8

The signed development app now uses two 3072 × 2048 logical Retina source displays, with one
shared feed per occupied display. This held all ten windows on the observed desktop without
per-window overflow streams. Source geometry, canvas layout and native input remain separate.

The preferred feed wraps the composed display's IOSurfaces without copying their pixels. Each
pixel buffer keeps an explicit surface-pool lease until its last reader releases it. The existing
ScreenCaptureKit path remains the fallback when the optional Core Graphics display-stream API
is unavailable or rejects capture. That API is obsolete in the SDK and remains an OS compatibility
dependency; this result does not remove the need for normal macOS capture consent.

On this Mac's 100 Hz display, normal launches of installed build 8 delivered **93–94.4
complete and applied frames/s** from the animated Safari bank, at full 2× backing resolution.
The earlier mixed-stream baseline was 23.5 frames/s. These are bounded local observations with
one animated browser window and nine other windows, not a sustained or all-windows-animated
benchmark. A static bank emits few new frames; the two bank rates must not be added together.

Caret placement, typing and drag selection passed in the installed **Debug** development bundle,
as did native handoff and return. Optimized Release candidates failed input and are not qualified;
the build script retains its original Debug configuration. A per-destination event tap corrects
physical canvas drag/release events that macOS also delivers to the newly focused app.

This result is **accepted for the current performance milestone**. Sustained 100 fps is deferred
optimization work. The [performance map](docs/sip-redesign-performance.md) identifies the source
locations to revisit. Uninterrupted modifier navigation after editing, menus and window families,
drag and drop, IME, capacity beyond these two banks and full product parity remain open. See the
[build 8 findings](experiments/virtual-display-canvas/LOCAL_FINDINGS.md#capture-performance-build-8)
for measurements, recovery results and limitations.

The final installed artifact restored originals after parent failure, host failure, removal of
one source display, and both processes dying followed by relaunch. Both owned displays and the
journal were removed. Those four final exercises produced no new capture-consent requests;
a stopped running feed now restores the bank instead of attempting capture on a disappearing display.

## Getting around

<p align="center">
  <img src="docs/images/gestures.png" width="820" alt="Settings › How to use acting out two gestures: a click bringing a window forward, and the four-finger spread for Show Desktop">
</p>

| To | Trackpad | Keys |
|---|---|---|
| Zoom | pinch | ⌥ or ⌘ + scroll |
| Pan | two-finger scroll, or four-finger drag from anywhere | |
| Go into a window | click it (double-click to centre it), or pinch in over it | ⏎ over it |
| Use a window at 1:1 | just click, type and scroll, as on the desktop | |
| See everything, and back in | four-finger tap | Mission Control key (F3) |
| Show Desktop | four-finger spread (thumb and three fingers) | F11 |
| Move & Resize a window | | ⌃⌥ ← → ↑ ↓ halves, U I J K quarters, D F G thirds, ⏎ full, C centre |
| Picture in Picture | right-click a window › Picture in Picture | ⌃⌥P |
| Save / restore a layout | | ⌘S / ⌘1 – ⌘9 |
| Settings · How to use | | ⌘, · ⌘? |

Everything else lives in the **sun icon in the menu bar** (Sunlight has no Dock icon): the on/off switch,
the minimap, your layouts, and More for the rest. **Settings › How to use** (⌘?) is the whole manual: the basics,
every gesture acted out, placing windows and every key. The full list of controls is in
[docs/how-it-works.md](docs/how-it-works.md#controls).

## Two ways to run it

You can try Sunlight with nothing but two privacy permissions. The full version needs one bigger step.

| | Demo mode | Live windows |
|---|---|---|
| Windows on the canvas | live pictures from the screen recording API | the real windows, scaled |
| Streaming | the 8 largest at 30 fps, the rest once a second | every window, always, at full refresh rate |
| Energy while panning | about 20% more | normal |
| What it needs | Accessibility and Screen Recording | part of System Integrity Protection (SIP) off, and an admin password once |

Live windows work by loading a tiny add-on into the Dock, which macOS only allows with part of SIP turned
off. The **Set Up Sunlight** wizard walks you through it one screen at a time, Recovery restart included
(there's a QR code so you can follow along on your phone while your Mac reboots).
**Settings › General › Uninstall Sunlight…** walks all of it back. Read
[LiveWindows/README.md](LiveWindows/README.md) for exactly what the add-on does and why before you
flip anything.

## Install

**Download** the DMG and drag Sunlight to Applications:

<p>
  <a href="https://github.com/spacefarm-digital/sunlight-releases/releases/latest/download/Sunlight.dmg"><b>⬇️ Sunlight.dmg</b></a>
  &nbsp;(all releases on the <a href="https://github.com/spacefarm-digital/sunlight-releases/releases">releases page</a>)
</p>

**Or with Homebrew:**

```sh
brew install --cask spacefarm-digital/tap/sunlight
```

The first launch opens **Set Up Sunlight**, which grants the permissions and lands you on the canvas in
demo mode. From there the demo mode card leads to live windows whenever you're ready. Sunlight updates
itself (it asks first). [INSTALL.md](INSTALL.md) covers every step, checking the setup, and removing it.

### Requirements

- A Mac with **Apple silicon** (M1 or later)
- **macOS 15** Sequoia or later
- An administrator account, for live windows
- **Stage Manager off**. Setup turns it off for you, and Sunlight turns it back on when it quits
- One canvas on the **main display** by default; the others show where their windows are. A canvas on
  every display is experimental (Settings › Experimental › Multiple displays).

## Beta heads-up

Sunlight 0.1 is the first public release, and it's a beta. It moves windows around, talks to the Dock and
takes over a few system shortcuts, so expect the odd glitch. Live windows have had the most miles on
macOS 27. If something goes sideways, **Settings › Live Windows › Diagnose…** copies a plain-text report
(no window titles or pictures) you can paste into an
[issue](https://github.com/spacefarm-digital/sunlight/issues). Turning Sunlight off from the menu bar puts
every window back at 1:1 where it was.

## Privacy

No analytics, no crash reporting, no accounts. Sunlight's log and crash reports stay on your Mac
(~/Library/Logs/Sunlight); Diagnose sums them up without window titles, for you to paste where you choose. The only thing Sunlight sends over the network is the update
check (Sparkle fetching the release feed, `packaging/release.conf`). Window pictures, titles and layouts stay
on your Mac.

## Build from source

```sh
make run
```

Needs macOS 15 or later and Xcode 16 or later (the command-line tools are enough). `swift test` runs the
tests. The build signs with the first Developer ID Application or Apple Development identity in your
keychain, or ad-hoc with neither; [INSTALL.md](INSTALL.md#building-from-source) says what each one changes.
How the canvas is drawn, the handoff, the add-on and the known limits are all in
[docs/how-it-works.md](docs/how-it-works.md).

## Contributing

Bug reports, ideas and pull requests are welcome. Start with [CONTRIBUTING.md](CONTRIBUTING.md), and see
[SECURITY.md](SECURITY.md) for reporting anything security related privately. What changed in each version
is in [CHANGELOG.md](CHANGELOG.md).

## Credits and licence

Sunlight is MIT licensed, see [LICENSE](LICENSE). Made by spacefarm.

The Dock add-on and its loader in `LiveWindows/osax` are adapted from
[yabai](https://github.com/koekeishiya/yabai)'s scripting addition (MIT, © 2019 Åsmund Vikane), by way of
the macOS 27 fork at [LCS-Dev-Ergos/yabai](https://github.com/LCS-Dev-Ergos/yabai); see
`LiveWindows/osax/LICENSE-yabai.txt`. Huge thanks to everyone who figured out the Dock first.
