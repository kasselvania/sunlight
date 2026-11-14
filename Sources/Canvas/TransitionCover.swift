import AppKit
import ScreenCaptureKit

/// Smoke and mirrors for the two moments the SIP profile can't make seamless the way the Dock add-on
/// did: going into Sunlight and coming back out. A window above everything shows a picture of the
/// screen while the real work (virtual displays appearing, windows parking on them or coming back)
/// happens underneath, then each window's picture flies between where it is on the desktop and where
/// its tile is on the canvas. Recorded before this (2026-11-13): at launch the windows visibly
/// reshuffled as the bank displays appeared, then 1.5 s of grey empty tiles; at quit the canvas
/// vanished and the windows flashed up in another order before settling.
@MainActor
final class TransitionCover {
    /// One window as it stands on the desktop: its picture, frame (global, top-left points), front first.
    struct Piece {
        let id: CGWindowID
        let frame: CGRect
        let image: CGImage?
    }

    private let window: NSWindow
    private let host = CALayer()
    /// Everything drawn: a sublayer, since a view's own layer doesn't keep a flipped geometry.
    private let root = CALayer()
    private let backdrop = CALayer()
    private var fliers: [CGWindowID: CALayer] = [:]
    static let flightDuration: CFTimeInterval = 0.55

    private init(screen: NSScreen) {
        window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        window.isReleasedWhenClosed = false
        let view = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.wantsLayer = true
        view.layer = host
        host.frame = view.bounds
        root.isGeometryFlipped = true   // frames in global top-left points, as the window list has them
        root.frame = view.bounds
        host.addSublayer(root)
        backdrop.frame = root.bounds
        backdrop.contentsGravity = .resize
        root.addSublayer(backdrop)
        window.contentView = view
        self.screen = screen
    }

    private let screen: NSScreen
    /// The main display in global top-left points (its origin is the global origin).
    private var screenRect: CGRect { CGRect(origin: .zero, size: screen.frame.size) }

    private static func layer(for image: CGImage?, frame: CGRect, scale: CGFloat) -> CALayer {
        let l = CALayer()
        l.frame = frame
        l.contents = image
        l.contentsGravity = .resize
        l.contentsScale = scale
        l.shadowColor = NSColor.black.cgColor
        l.shadowOpacity = 0.35
        l.shadowRadius = 18
        l.shadowOffset = CGSize(width: 0, height: 10)   // flipped: down
        return l
    }

    // MARK: Going in

    /// Puts a picture of the main display up at once, before anything moves; then, the windows captured
    /// one by one, the same picture as a wallpaper with the windows on it, ready to fly. Nil when the
    /// screen can't be captured: no cover, nothing else changes.
    /// Gives up after `seconds` (nil: no cover), so a capture that never answers can't hold the launch.
    static func coverDesktop(within seconds: TimeInterval) async -> (cover: TransitionCover, pieces: [Piece])? {
        let box = CoverBox()
        let work = Task { @MainActor in
            let result = await coverDesktop()
            if !box.settle(result != nil) { result?.cover.close() } else { box.result = result }
            return result
        }
        let deadline = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            if box.settle(false) { Log.note("Transition: the screen couldn't be captured within \(seconds) s; starting uncovered") }
        }
        await box.wait()
        work.cancel(); deadline.cancel()
        return box.result
    }

    /// The first of the capture and the deadline to finish decides.
    @MainActor private final class CoverBox {
        var result: (cover: TransitionCover, pieces: [Piece])?
        private var settled = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        /// True when this call decided (it came first).
        func settle(_ ok: Bool) -> Bool {
            guard !settled else { return false }
            settled = true
            DispatchQueue.main.async { let w = self.waiters; self.waiters = []; w.forEach { $0.resume() } }
            return true
        }
        func wait() async {
            if settled { return }
            await withCheckedContinuation { waiters.append($0) }
        }
    }

    static func coverDesktop() async -> (cover: TransitionCover, pieces: [Piece])? {
        guard let screen = NSScreen.main, CGPreflightScreenCaptureAccess(),
              let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
              let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) else { return nil }
        let scale = screen.backingScaleFactor
        func config(_ size: CGSize) -> SCStreamConfiguration {
            let c = SCStreamConfiguration()
            c.width = max(2, Int(size.width * scale)); c.height = max(2, Int(size.height * scale))
            c.showsCursor = false
            c.pixelFormat = kCVPixelFormatType_32BGRA
            return c
        }
        guard let whole = try? await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(display: display, excludingWindows: []),
                                                                     configuration: config(display.frame.size)) else { return nil }
        let cover = TransitionCover(screen: screen)
        cover.backdrop.contents = whole
        cover.window.orderFrontRegardless()

        // The desktop's own windows (wallpaper, files) under everything; ordinary windows front to back.
        let order = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? [])
            .compactMap { info -> (CGWindowID, CGRect)? in
                guard (info[kCGWindowLayer as String] as? Int) == 0,
                      let id = info[kCGWindowNumber as String] as? CGWindowID,
                      let d = info[kCGWindowBounds as String] as! CFDictionary?, let b = CGRect(dictionaryRepresentation: d),
                      b.width > 60, b.height > 60, b.intersects(display.frame) else { return nil }
                return (id, b)
            }
        let floor = content.windows.filter { $0.windowLayer < 0 }
        let wallpaper = try? await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(display: display, including: floor),
                                                                    configuration: config(display.frame.size))
        var pieces: [Piece] = []
        await withTaskGroup(of: Piece.self) { group in
            for (id, frame) in order {
                guard let w = content.windows.first(where: { $0.windowID == id }) else { continue }
                group.addTask {
                    let image = try? await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: w),
                                                                            configuration: config(frame.size))
                    return Piece(id: id, frame: frame, image: image)
                }
            }
            for await p in group { pieces.append(p) }
        }
        let rank = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1.0, $0) })
        pieces.sort { (rank[$0.id] ?? 0) < (rank[$1.id] ?? 0) }
        // Same look, now in pieces: the wallpaper, and every window drawn over it, back to front.
        if let wallpaper, pieces.allSatisfy({ $0.image != nil }) {
            CATransaction.begin(); CATransaction.setDisableActions(true)
            for p in pieces.reversed() {
                let l = layer(for: p.image, frame: p.frame, scale: scale)
                cover.root.addSublayer(l)
                cover.fliers[p.id] = l
            }
            cover.backdrop.contents = wallpaper
            CATransaction.commit()
        }
        return (cover, pieces)
    }

    /// The canvas is ready behind the cover: each window flies from the desktop to its tile (`targets`,
    /// global top-left points; a window without one fades where it is) while the wallpaper fades into
    /// the canvas. `then` runs once they've landed, with the cover gone.
    func flyIn(to targets: [CGWindowID: CGRect], then: @escaping () -> Void) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(Self.flightDuration)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(controlPoints: 0.3, 0.0, 0.2, 1.0))
        CATransaction.setCompletionBlock { [weak self] in
            MainActor.assumeIsolated {
                then()
                self?.close()
            }
        }
        Self.animate(backdrop, opacity: 0)
        for (id, l) in fliers {
            // A tile off screen (the camera left zoomed in): the window heads its way and fades as it goes.
            if let to = targets[id] {
                let seen = to.intersection(screenRect)
                let mostlyOff = seen.isNull || seen.width * seen.height < 0.25 * to.width * to.height
                Self.animate(l, to: to, opacity: mostlyOff ? 0 : nil, shadow: 0)
            } else { Self.animate(l, opacity: 0) }
        }
        CATransaction.commit()
    }

    private static let easing = CAMediaTimingFunction(controlPoints: 0.3, 0.0, 0.2, 1.0)

    /// Explicit animations, from where the layer is drawn now to the new values, which are also set:
    /// implicit ones didn't run in this window (the cover cut straight to the canvas, 2026-11-13).
    private static func animate(_ l: CALayer, to frame: CGRect? = nil, opacity: Float? = nil, shadow: Float? = nil) {
        func add(_ key: String, _ from: Any?, _ to: Any) {
            let a = CABasicAnimation(keyPath: key)
            a.fromValue = from
            a.toValue = to
            a.duration = flightDuration
            a.timingFunction = easing
            l.add(a, forKey: "cover.\(key)")
        }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        if let frame {
            let position = CGPoint(x: frame.midX, y: frame.midY), bounds = CGRect(origin: .zero, size: frame.size)
            add("position", NSValue(point: l.position), NSValue(point: position))
            add("bounds", NSValue(rect: l.bounds), NSValue(rect: bounds))
            l.position = position; l.bounds = bounds
        }
        if let opacity { add("opacity", l.opacity, opacity); l.opacity = opacity }
        if let shadow { add("shadowOpacity", l.shadowOpacity, shadow); l.shadowOpacity = shadow }
        CATransaction.commit()
    }

    // MARK: Coming out

    /// The tiles as they are on screen (`pieces`: contents, contents rect, corner radius, global frame),
    /// over the canvas, identical to it; then they fly to the windows' places on the desktop (`homes`)
    /// while the canvas fades away (`fadeCanvas`), the windows still parked. `then` runs on landing:
    /// the windows are put back under their pictures, and the cover goes with the process.
    static func coverCanvasAndFlyOut(pieces: [(id: CGWindowID, contents: Any, rect: CGRect, radius: CGFloat, frame: CGRect)],
                                     homes: [CGWindowID: CGRect], fadeCanvas: (CFTimeInterval) -> Void,
                                     then: @escaping () -> Void) -> TransitionCover? {
        guard let screen = NSScreen.main, !pieces.isEmpty else { return nil }
        let cover = TransitionCover(screen: screen)
        cover.backdrop.isHidden = true
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for p in pieces.reversed() {
            let l = CALayer()
            l.frame = p.frame
            l.contents = p.contents
            l.contentsRect = p.rect
            l.contentsGravity = .resize
            l.cornerRadius = p.radius
            l.cornerCurve = .continuous
            l.masksToBounds = true
            cover.root.addSublayer(l)
            cover.fliers[p.id] = l
        }
        CATransaction.commit()
        cover.window.orderFrontRegardless()
        fadeCanvas(flightDuration * 0.8)
        CATransaction.begin()
        CATransaction.setAnimationDuration(flightDuration)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(controlPoints: 0.3, 0.0, 0.2, 1.0))
        CATransaction.setCompletionBlock { MainActor.assumeIsolated { then() } }
        for (id, l) in cover.fliers {
            if let home = homes[id] { animate(l, to: home) } else { animate(l, opacity: 0) }
        }
        CATransaction.commit()
        return cover
    }

    func close() {
        window.orderOut(nil)
        fliers.removeAll()
    }

    var ids: Set<CGWindowID> { Set(fliers.keys) }
}
