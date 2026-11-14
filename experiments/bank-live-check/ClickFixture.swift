// ClickFixture <log>: one window, one big button; every completed click (down and up inside) is a line.
import AppKit
let logPath = CommandLine.arguments[1]
func log(_ o: [String: Any]) {
    var o = o; o["t"] = Date().timeIntervalSince1970
    let line = String(data: try! JSONSerialization.data(withJSONObject: o), encoding: .utf8)! + "\n"
    if let h = FileHandle(forWritingAtPath: logPath) { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); h.closeFile() }
    else { FileManager.default.createFile(atPath: logPath, contents: line.data(using: .utf8)) }
}
final class Target: NSObject { var n = 0; @objc func hit(_ b: NSButton) { n += 1; b.title = "Clicked \(n)"; log(["event": "click", "n": n]) } }
final class Watch: NSView {
    var downs = 0
    override func mouseDown(with e: NSEvent) { downs += 1; log(["event": "down", "n": downs, "num": e.eventNumber]) }
    override func mouseUp(with e: NSEvent) { log(["event": "up", "n": downs, "num": e.eventNumber]) }
    override func acceptsFirstMouse(for e: NSEvent?) -> Bool { true }
}
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let w = NSWindow(contentRect: NSRect(x: 400, y: 300, width: 600, height: 400), styleMask: [.titled, .closable], backing: .buffered, defer: false)
w.title = "Click Test"
let root = Watch(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
let target = Target()
let b = NSButton(title: "Click me", target: target, action: #selector(Target.hit(_:)))
b.bezelStyle = .regularSquare
b.frame = NSRect(x: 20, y: 20, width: 120, height: 40)
b.font = .boldSystemFont(ofSize: 30)
root.addSubview(b)
w.contentView = root
w.makeKeyAndOrderFront(nil)
log(["event": "ready", "pid": getpid(), "window": w.windowNumber])
NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { e in
    log(["event": e.type == .leftMouseDown ? "mon-down" : "mon-up", "num": e.eventNumber, "win": e.windowNumber, "clicks": e.clickCount,
         "loc": NSStringFromPoint(e.locationInWindow), "ts": e.timestamp])
    return e
}
app.activate(ignoringOtherApps: true)
app.run()
