// DragFixture source|target <log>: one window. "source" drags a string + PNG out of its middle;
// "target" logs every drop it takes (types and string) to <log>, one JSON line each.
import AppKit
let role = CommandLine.arguments[1], logPath = CommandLine.arguments[2]
func log(_ o: [String: Any]) {
    var o = o; o["t"] = Date().timeIntervalSince1970; o["role"] = role
    let line = String(data: try! JSONSerialization.data(withJSONObject: o), encoding: .utf8)! + "\n"
    if let h = FileHandle(forWritingAtPath: logPath) { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); h.closeFile() }
    else { FileManager.default.createFile(atPath: logPath, contents: line.data(using: .utf8)) }
}
final class SourceView: NSView, NSDraggingSource {
    var down: NSEvent?
    override func acceptsFirstMouse(for e: NSEvent?) -> Bool { true }
    override func draw(_ r: NSRect) { NSColor.systemOrange.setFill(); bounds.fill()
        ("DRAG ME" as NSString).draw(at: NSPoint(x: 20, y: bounds.midY), withAttributes: [.font: NSFont.boldSystemFont(ofSize: 40)]) }
    override func mouseDown(with e: NSEvent) { down = e; log(["event": "down", "at": NSStringFromPoint(e.locationInWindow)]) }
    override func mouseDragged(with e: NSEvent) {
        guard let d = down else { return }; down = nil
        let item = NSPasteboardItem()
        item.setString("dragged-from-source", forType: .string)
        let img = NSImage(size: NSSize(width: 64, height: 64)); img.lockFocus(); NSColor.systemOrange.setFill(); NSRect(x: 0, y: 0, width: 64, height: 64).fill(); img.unlockFocus()
        item.setData(NSBitmapImageRep(data: img.tiffRepresentation!)!.representation(using: .png, properties: [:])!, forType: .png)
        let di = NSDraggingItem(pasteboardWriter: item)
        di.setDraggingFrame(NSRect(origin: convert(d.locationInWindow, from: nil), size: NSSize(width: 64, height: 64)), contents: img)
        beginDraggingSession(with: [di], event: d, source: self)
        log(["event": "began"])
    }
    func draggingSession(_ s: NSDraggingSession, sourceOperationMaskFor c: NSDraggingContext) -> NSDragOperation { .copy }
    func draggingSession(_ s: NSDraggingSession, endedAt p: NSPoint, operation: NSDragOperation) { log(["event": "ended", "at": NSStringFromPoint(p), "op": operation.rawValue]) }
}
final class TargetView: NSView {
    var hot = false { didSet { needsDisplay = true } }
    override func draw(_ r: NSRect) { (hot ? NSColor.systemGreen : NSColor.systemTeal).setFill(); bounds.fill()
        ("DROP HERE" as NSString).draw(at: NSPoint(x: 20, y: bounds.midY), withAttributes: [.font: NSFont.boldSystemFont(ofSize: 40)]) }
    override func draggingEntered(_ s: NSDraggingInfo) -> NSDragOperation { hot = true; log(["event": "entered"]); return .copy }
    override func draggingExited(_ s: NSDraggingInfo?) { hot = false }
    override func performDragOperation(_ s: NSDraggingInfo) -> Bool {
        hot = false
        log(["event": "drop", "types": (s.draggingPasteboard.types ?? []).map(\.rawValue), "string": s.draggingPasteboard.string(forType: .string) ?? ""])
        return true
    }
}
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let w = NSWindow(contentRect: NSRect(x: role == "source" ? 300 : 1100, y: 300, width: 600, height: 400), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
w.title = role == "source" ? "Drag Source" : "Drop Target"
if role == "source" { w.contentView = SourceView() } else { let v = TargetView(); v.registerForDraggedTypes([.string, .png]); w.contentView = v }
w.makeKeyAndOrderFront(nil)
log(["event": "ready", "pid": getpid(), "window": w.windowNumber])
app.activate(ignoringOtherApps: true)
app.run()
