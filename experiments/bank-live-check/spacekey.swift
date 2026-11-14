// spacekey <left|right>: ⌃← or ⌃→ as a real keyboard sends it.
import AppKit
let right = CommandLine.arguments[1] == "right"
let src = CGEventSource(stateID: .hidSystemState)
func key(_ code: CGKeyCode, _ down: Bool, _ flags: CGEventFlags) { let e = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: down)!; e.flags = flags; e.post(tap: .cghidEventTap) }
let arrow: CGEventFlags = [.maskControl, .maskSecondaryFn, .maskNumericPad]
key(59, true, .maskControl); usleep(30_000)
key(right ? 124 : 123, true, arrow); usleep(40_000); key(right ? 124 : 123, false, arrow); usleep(30_000)
key(59, false, []); usleep(50_000)
