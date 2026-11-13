// Driver for the build-12 live check. Global top-left (Quartz) coordinates.
//   frames <id,...>            CG bounds of windows
//   axsize <pid> <id> <w> <h>  resize a window through Accessibility (as an app would)
//   axframe <pid> <id>         AX frame of a window
//   drag <x1> <y1> <x2> <y2>   left-button drag in 30 steps
//   dclick <x> <y>             double-click
//   mouse                      current pointer location
//   moveto <x> <y>             move pointer
//   menu <pid> <x> <y> <a>[/<b>]  right-click, then press menu item a (and b in its submenu) of process pid
//   axmin <pid> <id> <0|1>     minimize (1) or restore (0) a window
//   axsize2 <pid> <id> <w> <h> <id> <w> <h>   resize two windows back to back
import AppKit
import ApplicationServices

@_silgen_name("_AXUIElementGetWindow") func _AXUIElementGetWindow(_ e: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

func axWindow(pid: pid_t, id: CGWindowID) -> AXUIElement? {
    let app = AXUIElementCreateApplication(pid)
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success, let list = value as? [AXUIElement] else { return nil }
    return list.first { var w: CGWindowID = 0; return _AXUIElementGetWindow($0, &w) == .success && w == id }
}

func axFrame(_ w: AXUIElement) -> CGRect? {
    var p: CFTypeRef?, s: CFTypeRef?
    guard AXUIElementCopyAttributeValue(w, kAXPositionAttribute as CFString, &p) == .success,
          AXUIElementCopyAttributeValue(w, kAXSizeAttribute as CFString, &s) == .success else { return nil }
    var point = CGPoint.zero, size = CGSize.zero
    AXValueGetValue(p as! AXValue, .cgPoint, &point); AXValueGetValue(s as! AXValue, .cgSize, &size)
    return CGRect(origin: point, size: size)
}

func post(_ type: CGEventType, _ p: CGPoint, clicks: Int64 = 1) {
    let e = CGEvent(mouseEventSource: CGEventSource(stateID: .hidSystemState), mouseType: type, mouseCursorPosition: p, mouseButton: .left)!
    e.setIntegerValueField(.mouseEventClickState, value: clicks)
    e.post(tap: .cghidEventTap)
}

let a = CommandLine.arguments
func d(_ i: Int) -> CGFloat { CGFloat(Double(a[i])!) }
switch a[1] {
case "frames":
    let ids = a[2].split(separator: ",").map { UnsafeRawPointer(bitPattern: UInt($0)!) }
    var values = ids
    let list = CGWindowListCreateDescriptionFromArray(CFArrayCreate(nil, &values, values.count, nil)) as! [[String: Any]]
    for w in list {
        let b = CGRect(dictionaryRepresentation: w[kCGWindowBounds as String] as! CFDictionary)!
        print(w[kCGWindowNumber as String]!, NSStringFromRect(b), (w[kCGWindowIsOnscreen as String] as? Bool) == true ? "on" : "off")
    }
case "axsize":
    guard let w = axWindow(pid: pid_t(a[2])!, id: CGWindowID(a[3])!) else { print("no AX window"); exit(1) }
    var size = CGSize(width: d(4), height: d(5))
    let r = AXUIElementSetAttributeValue(w, kAXSizeAttribute as CFString, AXValueCreate(.cgSize, &size)!)
    usleep(300_000)
    print("set:", r.rawValue, "now:", axFrame(w).map { NSStringFromRect($0) } ?? "?")
case "axframe":
    guard let w = axWindow(pid: pid_t(a[2])!, id: CGWindowID(a[3])!) else { print("no AX window"); exit(1) }
    print(axFrame(w).map { NSStringFromRect($0) } ?? "?")
case "drag":
    let from = CGPoint(x: d(2), y: d(3)), to = CGPoint(x: d(4), y: d(5))
    post(.mouseMoved, from); usleep(150_000)
    post(.leftMouseDown, from); usleep(250_000)
    for i in 1...30 {
        let t = CGFloat(i) / 30
        post(.leftMouseDragged, CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t)); usleep(25_000)
    }
    usleep(200_000)
    post(.leftMouseUp, to)
case "dclick":
    let p = CGPoint(x: d(2), y: d(3))
    post(.mouseMoved, p); usleep(150_000)
    post(.leftMouseDown, p, clicks: 1); usleep(40_000); post(.leftMouseUp, p, clicks: 1); usleep(80_000)
    post(.leftMouseDown, p, clicks: 2); usleep(40_000); post(.leftMouseUp, p, clicks: 2)
case "mouse":
    let l = CGEvent(source: nil)!.location
    print(l.x, l.y)
case "moveto":
    post(.mouseMoved, CGPoint(x: d(2), y: d(3)))
case "menu":
    let pid = pid_t(a[2])!, p = CGPoint(x: d(3), y: d(4))
    post(.mouseMoved, p); usleep(150_000)
    for t in [CGEventType.rightMouseDown, .rightMouseUp] {
        let e = CGEvent(mouseEventSource: CGEventSource(stateID: .hidSystemState), mouseType: t, mouseCursorPosition: p, mouseButton: .right)!
        e.post(tap: .cghidEventTap); usleep(60_000)
    }
    usleep(500_000)
    let app = AXUIElementCreateApplication(pid)
    func find(_ e: AXUIElement, _ title: String, _ depth: Int) -> AXUIElement? {
        var role: CFTypeRef?, t: CFTypeRef?, kids: CFTypeRef?
        AXUIElementCopyAttributeValue(e, kAXRoleAttribute as CFString, &role)
        AXUIElementCopyAttributeValue(e, kAXTitleAttribute as CFString, &t)
        if (role as? String) == kAXMenuItemRole as String, (t as? String) == title { return e }
        guard depth > 0, AXUIElementCopyAttributeValue(e, kAXChildrenAttribute as CFString, &kids) == .success else { return nil }
        for k in (kids as? [AXUIElement]) ?? [] { if let f = find(k, title, depth - 1) { return f } }
        return nil
    }
    for (i, title) in a[5].split(separator: "/").map(String.init).enumerated() {
        guard let item = find(app, title, 8) else { print("no menu item:", title); exit(1) }
        print("press", title, AXUIElementPerformAction(item, kAXPressAction as CFString).rawValue)
        usleep(i == 0 ? 400_000 : 200_000)
    }
case "axmin":
    guard let w = axWindow(pid: pid_t(a[2])!, id: CGWindowID(a[3])!) else { print("no AX window"); exit(1) }
    print("set:", AXUIElementSetAttributeValue(w, kAXMinimizedAttribute as CFString, (a[4] == "1") as CFBoolean).rawValue)
case "axsize2":
    let pid = pid_t(a[2])!
    for k in [3, 6] {
        guard let w = axWindow(pid: pid, id: CGWindowID(a[k])!) else { print("no AX window", a[k]); exit(1) }
        var size = CGSize(width: d(k + 1), height: d(k + 2))
        print("set", a[k], AXUIElementSetAttributeValue(w, kAXSizeAttribute as CFString, AXValueCreate(.cgSize, &size)!).rawValue)
    }
default:
    print("unknown"); exit(2)
}
