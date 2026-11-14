// carry <x> <y> <left|right> <count>: hold the window under (x, y) by the press there and switch Desktop
// with ⌃← / ⌃→ `count` times while holding, then let go. The window travels with the pointer.
import AppKit
let a = CommandLine.arguments
let p = CGPoint(x: Double(a[1])!, y: Double(a[2])!), right = a[3] == "right", count = Int(a[4])!
let src = CGEventSource(stateID: .hidSystemState)
func mouse(_ t: CGEventType, _ q: CGPoint) { CGEvent(mouseEventSource: src, mouseType: t, mouseCursorPosition: q, mouseButton: .left)!.post(tap: .cghidEventTap) }
func key(_ code: CGKeyCode, _ down: Bool, _ flags: CGEventFlags) { let e = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: down)!; e.flags = flags; e.post(tap: .cghidEventTap) }
mouse(.mouseMoved, p); usleep(150_000)
mouse(.leftMouseDown, p); usleep(200_000)
mouse(.leftMouseDragged, CGPoint(x: p.x + 3, y: p.y)); usleep(100_000)
mouse(.leftMouseDragged, CGPoint(x: p.x + 6, y: p.y)); usleep(150_000)
key(59, true, .maskControl)                       // ⌃ down
for _ in 0..<count {
  let arrow: CGEventFlags = [.maskControl, .maskSecondaryFn, .maskNumericPad]   // as a real arrow key carries them
  key(right ? 124 : 123, true, arrow); usleep(40_000); key(right ? 124 : 123, false, arrow)
  usleep(900_000)                                 // the switch animation
}
key(59, false, [])                                // ⌃ up
mouse(.leftMouseDragged, CGPoint(x: p.x + 3, y: p.y)); usleep(60_000)
mouse(.leftMouseDragged, p); usleep(100_000)   // back where the grab began: the window doesn't shift
mouse(.leftMouseUp, p); usleep(100_000)
key(59, false, [])                                // ⌃ up again: a window drag can swallow the first
