// draghold x1 y1 x2 y2 holdms: press, drag over 0.6 s, hold (still dragging) holdms, release.
import AppKit
let a = CommandLine.arguments.dropFirst().map { Double($0)! }
let p1 = CGPoint(x: a[0], y: a[1]), p2 = CGPoint(x: a[2], y: a[3]), hold = a[4]
func post(_ t: CGEventType, _ p: CGPoint) { CGEvent(mouseEventSource: nil, mouseType: t, mouseCursorPosition: p, mouseButton: .left)!.post(tap: .cghidEventTap) }
post(.mouseMoved, p1); usleep(150_000)
post(.leftMouseDown, p1); usleep(120_000)
for i in 1...30 { let f = Double(i) / 30; post(.leftMouseDragged, CGPoint(x: p1.x + (p2.x - p1.x) * f, y: p1.y + (p2.y - p1.y) * f)); usleep(20_000) }
let until = Date().addingTimeInterval(hold / 1000)
var k = 0.0
while Date() < until { k += 1; post(.leftMouseDragged, CGPoint(x: p2.x + (k.truncatingRemainder(dividingBy: 2)), y: p2.y)); usleep(50_000) }
post(.leftMouseUp, p2)
