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
    var drawn = 0
    // Like a Firefox/Chromium tab strip: the app starts the window drag itself.
    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        FileHandle.standardError.write("down \(label) y=\(p.y) win=\(window?.windowNumber ?? 0) at \(NSStringFromPoint(event.locationInWindow))\n".data(using: .utf8)!)
        if p.y < 64 { drags += 1; window?.performDrag(with: event) }
    }
    override func draw(_ dirtyRect: NSRect) {
        drawn += 1
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
    var activity: NSObjectProtocol?
    var paused = false
    var ticks = 0
    let pauseSource = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
    init(out: String) { self.out = out }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [.flexibleSpace] }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [.flexibleSpace] }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? { nil }

    @objc func showSheet(_ sender: NSButton) {
        guard let window = sender.window else { return }
        let alert = NSAlert()
        alert.messageText = "Sheet on \(window.title)"
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { response in
            FileHandle.standardError.write("sheet \(response == .alertFirstButtonReturn ? "OK" : "Cancel")\n".data(using: .utf8)!)
        }
    }

    @objc func chose(_ sender: NSPopUpButton) {
        FileHandle.standardError.write("chose \(sender.titleOfSelectedItem ?? "?")\n".data(using: .utf8)!)
    }

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
            // A pop-up menu: where macOS opens it, and whether choosing works, for a banked window.
            let popup = NSPopUpButton(frame: NSRect(x: 24, y: 170, width: 220, height: 30), pullsDown: false)
            popup.addItems(withTitles: ["\(name) first", "\(name) second", "\(name) third"])
            popup.target = self
            popup.action = #selector(chose(_:))
            v.addSubview(popup)
            // A sheet: a window of the app's at the normal level, attached over this one.
            let sheet = NSButton(title: "Sheet…", target: self, action: #selector(showSheet(_:)))
            sheet.frame = NSRect(x: 260, y: 170, width: 100, height: 30)
            v.addSubview(sheet)
            w.makeKeyAndOrderFront(nil)
            windows.append(w); views.append(v)
        }
        // Not throttled as a background app (App Nap): the windows live on a display nobody looks at.
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical], reason: "bank live check")
        let t = Timer(timeInterval: 1.0 / 100, repeats: true) { [weak self] _ in
            guard let self, !paused else { return }
            ticks += 1
            views.forEach { $0.tick += 1; $0.needsDisplay = true }
        }
        RunLoop.main.add(t, forMode: .common)
        // SIGUSR1 pauses/resumes the animation, so a run can compare animated and static banks.
        signal(SIGUSR1, SIG_IGN)
        pauseSource.setEventHandler { [weak self] in self?.paused.toggle() }
        pauseSource.resume()
        // Once a second: timer ticks and actual draws per window, to <out>.stats as JSON lines.
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            let line: [String: Any] = ["t": Date().timeIntervalSince1970, "paused": paused, "ticks": ticks,
                                       "drawn": views.map(\.drawn)]
            ticks = 0; views.forEach { $0.drawn = 0 }
            let path = self.out + ".stats"
            if !FileManager.default.fileExists(atPath: path) { FileManager.default.createFile(atPath: path, contents: nil) }
            if let data = try? JSONSerialization.data(withJSONObject: line), let h = FileHandle(forWritingAtPath: path) {
                h.seekToEndOfFile(); h.write(data); h.write("\n".data(using: .utf8)!); try? h.close()
            }
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
