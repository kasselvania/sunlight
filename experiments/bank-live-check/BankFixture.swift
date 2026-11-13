// Throwaway test windows for the build-12 live check. Three windows with a
// 64 pt strip that starts its own window drag (like Zen) and an animating counter.
// Writes their window numbers to the path given as argv[1], then runs until killed.
import AppKit

final class Pulse: NSView {
    var label = ""
    var tick = 0
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    var drags = 0
    // Like a Firefox/Chromium tab strip: the app starts the window drag itself.
    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        FileHandle.standardError.write("down \(label) y=\(p.y) win=\(window?.windowNumber ?? 0) at \(NSStringFromPoint(event.locationInWindow))\n".data(using: .utf8)!)
        if p.y < 64 { drags += 1; window?.performDrag(with: event) }
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedHue: CGFloat(label.unicodeScalars.first!.value % 7) / 7, saturation: 0.35, brightness: 0.95, alpha: 1).setFill()
        bounds.fill()
        let text = "\(label)  \(tick)" as NSString
        text.draw(at: NSPoint(x: 24, y: 80), withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 54, weight: .bold)])
        let x = 24 + CGFloat(tick % 240) / 240 * (bounds.width - 72)
        NSColor(white: 0, alpha: 0.12).setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 64).fill()
        NSColor.black.setFill()
        NSBezierPath(ovalIn: NSRect(x: x, y: bounds.height - 70, width: 40, height: 40)).fill()
    }
}

final class Delegate: NSObject, NSApplicationDelegate, NSToolbarDelegate {
    var windows: [NSWindow] = []
    var views: [Pulse] = []
    let out: String
    init(out: String) { self.out = out }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [.flexibleSpace] }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [.flexibleSpace] }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? { nil }

    func applicationDidFinishLaunching(_ note: Notification) {
        let screen = NSScreen.main!.visibleFrame
        for (i, name) in ["A", "B", "C"].enumerated() {
            let w = NSWindow(contentRect: NSRect(x: screen.minX + 200 + CGFloat(i) * 760, y: screen.maxY - 600, width: 700, height: 450),
                             styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView], backing: .buffered, defer: false)
            w.title = "Bank Test \(name)"
            w.titlebarAppearsTransparent = true
            w.isReleasedWhenClosed = false
            let v = Pulse(frame: NSRect(origin: .zero, size: w.frame.size))
            v.label = name
            w.contentView = v
            w.makeKeyAndOrderFront(nil)
            windows.append(w); views.append(v)
        }
        Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            self?.views.forEach { $0.tick += 1; $0.needsDisplay = true }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in
            let ids = windows.map { $0.windowNumber }
            try? JSONSerialization.data(withJSONObject: ["pid": getpid(), "ids": ids]).write(to: URL(fileURLWithPath: out))
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = Delegate(out: CommandLine.arguments[1])
app.delegate = delegate
app.run()
