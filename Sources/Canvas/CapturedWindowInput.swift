import AppKit

/// Input to a real app through its captured tile. The canvas remains in front;
/// this object never invokes the Dock add-on or moves the camera/window.
@MainActor
final class CapturedWindowInput {
    // Direct PID posting bypasses WindowServer's addressing pass. AppKit needs
    // both the window-number field and its top-left-relative location. The
    // public window-under-pointer fields alone do not provide that addressing.
    // Reference: theofanisv/touch-bridge, Sources/TouchPlatform/DirectTarget.swift.
    private typealias SetWindowLocation = @convention(c) (CGEvent, CGPoint) -> Void
    private static let setWindowLocation: SetWindowLocation? =
        dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGEventSetWindowLocation").map {
            unsafeBitCast($0, to: SetWindowLocation.self)
        }
    private static let windowNumberField = CGEventField(rawValue: 51)!
    private weak var target: WindowProxy?
    private var preparing = false
    private var pending: [CGEvent] = []
    private var revision = 0
    private var keyboardOrigin: pid_t?
    private var pointerDown: CGEvent?
    /// Native minus tile origin, fixed at the press: a drag is the pointer's
    /// own motion, however the window and its tile move during it.
    private var pressOffset: CGVector?
    /// Where the press landed (world) and where its tile was then.
    private var pressGrab: (world: CGPoint, tile: CGPoint)?
    /// The last press handled over a raised window, to drop its duplicate.
    private var lastRaisedPress: (time: CFTimeInterval, point: CGPoint)?
    private let isolation = CapturedInputIsolation()
    private let inputEvents = CapturedInputEvents()
    private let postedSource = CGEventSource(stateID: .privateState)
    private var mouseSequence: Int64 = 0
    private(set) var eventsPosted = 0
    var onFailure: ((String) -> Void)?
    var onPointerReleased: (() -> Void)?
    var onCanvasEvent: ((CGEvent) -> Bool)?
    var onFocused: (() -> Void)?
    /// About to bring this app forward for input through its tile: that activation is use where the
    /// window is drawn, not the user going over to the app.
    var onWillFocus: ((pid_t) -> Void)?

    var windowID: CGWindowID? { target?.windowID }

    /// A press on this window's tile is down (the app may be dragging the window by it).
    func isDragging(_ id: CGWindowID) -> Bool { pressOffset != nil && target?.windowID == id }

    /// The press on this window's tile: where it landed and where the tile was then.
    func grab(_ id: CGWindowID) -> (world: CGPoint, tile: CGPoint)? { target?.windowID == id ? pressGrab : nil }

    func install(canvas: CGWindowID, presented: @escaping () -> Bool) {
        if !inputEvents.install(canvas: canvas, presented: presented, cancelled: { [weak self] in self?.clear() }) {
            onFailure?("Could not start captured input routing.")
        }
    }

    func shutdown() { clear(); inputEvents.shutdown(); isolation.shutdown() }

    func clear(preserveClick: Bool = false, replayCanvas: Bool = false) {
        if let down = pointerDown, let target,
           WindowList.onScreen(target.windowID)?.pid == target.pid, let up = down.copy() {
            up.type = .leftMouseUp
            up.setDoubleValueField(.mouseEventPressure, value: 0)
            up.postToPid(target.pid)
        }
        if !preserveClick { inputEvents.releaseToCanvas(replay: replayCanvas) }
        pointerDown = nil; pressOffset = nil; pressGrab = nil; keyboardOrigin = nil
        onPointerReleased?()
        revision += 1
        target = nil
        preparing = false
        pending.removeAll()
    }

    /// The app under the press started a drag that the canvas now carries: its drag is cancelled
    /// (Escape, as a user would) and the press is dropped without a release, which would land as a
    /// click where the drag began.
    func abandonPressForDrag() {
        if let target { Self.postKey(53, to: target.pid) }
        pointerDown = nil
        clear()
    }

    nonisolated static func postKey(_ code: CGKeyCode, to pid: pid_t) {
        for down in [true, false] {
            CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)?.postToPid(pid)
        }
    }

    /// Uses the same world coordinates as Sunlight's camera. Native window
    /// coordinates are read from WindowServer, rather than assumed to equal
    /// the freely arranged tile's world rectangle.
    nonisolated static func nativePoint(world: CGPoint, tile: CGRect, native: CGRect) -> CGPoint {
        CGPoint(x: native.minX + world.x - tile.minX,
                y: native.minY + world.y - tile.minY)
    }

    @discardableResult
    func pointer(_ event: NSEvent, to proxy: WindowProxy, world: CGPoint) -> Bool {
        guard Self.setWindowLocation != nil else {
            clear()
            onFailure?("Window-addressed input is unavailable on this macOS version.")
            return false
        }
        guard let source = event.cgEvent,
              let native = WindowList.onScreen(proxy.windowID), native.pid == proxy.pid else {
            if event.type != .scrollWheel { clear() }
            return false
        }
        var point = Self.nativePoint(world: world, tile: proxy.worldRect, native: native.bounds)
        if event.type == .leftMouseDragged || event.type == .leftMouseUp, let pressOffset {
            point = CGPoint(x: world.x + pressOffset.dx, y: world.y + pressOffset.dy)
        }
        if event.type == .leftMouseUp { pressOffset = nil; pressGrab = nil }
        // A menu, pop-up list or other window of the app's above the normal level under the point (on the
        // bank its pixels fall inside the tile's crop): the event is that window's. Addressed to the
        // tile's own window, a click on an open menu read as a click outside it and closed it unchosen.
        let over = Self.windowInFront(of: proxy.windowID, pid: proxy.pid, at: point)
        let windowID = over?.id ?? proxy.windowID
        // Window-relative, against where the window is now (equal to the tile's when nothing moved).
        let origin = over?.bounds.origin ?? native.bounds.origin
        let local = CGPoint(x: point.x - origin.x, y: point.y - origin.y)
        if event.type == .scrollWheel {
            // Hover scrolling has its own receiver. It never changes the app
            // or window selected for typing, including across app boundaries.
            guard let scroll = source.copy() else { return false }
            scroll.location = point
            address(scroll, to: proxy, window: windowID, local: local)
            if let move = CGEvent(mouseEventSource: postedSource, mouseType: .mouseMoved,
                                  mouseCursorPosition: point, mouseButton: .left) {
                move.flags = source.flags
                address(move, to: proxy, window: windowID, local: local)
                _ = post(move, to: proxy)
            }
            return post(scroll, to: proxy)
        }
        if event.type == .leftMouseDown {
            guard let canvasID = CGWindowID(exactly: event.windowNumber) else { return false }
            let pids = Set([proxy.pid, NSWorkspace.shared.frontmostApplication?.processIdentifier].compactMap { $0 })
            for pid in pids where pid != getpid() {
                guard isolation.protect(pid: pid, canvas: canvasID, mark: CanvasView.passedOnMark,
                    canvasEvent: { [weak self] in self?.onCanvasEvent?($0) ?? false }) else {
                    clear(); onFailure?("Could not route input to the chosen app window."); return false
                }
            }
            mouseSequence &+= 1
            if target !== proxy || NSWorkspace.shared.frontmostApplication?.processIdentifier != proxy.pid {
                prepare(proxy)
            } else if !routeEvents(to: proxy) {
                clear(); onFailure?("Could not route keyboard input to the chosen window."); return false
            }
        }
        guard target === proxy else { return false }
        // An open menu (or other raised window) of the app's under the press: menus track the real
        // pointer, which is over the canvas on the physical display, not over the menu on the bank, so
        // a posted click read as one outside it and closed it unchosen (measured 2026-11-13). The item
        // under the press is pressed through Accessibility, and nothing is posted. On the press, not the
        // release: with a menu open the release often never came back to the canvas (2 of 5 lost).
        // A press arrives twice (the panel's hook and the view); the second is ignored.
        if let over, over.layer > 0,
           [.leftMouseDown, .leftMouseDragged, .leftMouseUp].contains(event.type) {
            if event.type == .leftMouseDown {
                let now = CACurrentMediaTime()
                let repeated = lastRaisedPress.map { now - $0.time < 0.3 && hypot($0.point.x - point.x, $0.point.y - point.y) < 4 } ?? false
                lastRaisedPress = (now, point)
                Log.note("Captured input: press over raised window \(over.id) (layer \(over.layer)) at \(NSStringFromPoint(point))\(repeated ? ", repeat ignored" : "")")
                if !repeated { Self.pressRaised(pid: proxy.pid, at: point) }
            }
            return true
        }
        if event.type == .leftMouseDown {   // after `prepare`, which clears the previous press
            pressOffset = CGVector(dx: native.bounds.minX - proxy.worldRect.minX, dy: native.bounds.minY - proxy.worldRect.minY)
            pressGrab = (world, proxy.worldRect.origin)
        }
        let original: CGEvent
        if source.type == .leftMouseDown || source.type == .leftMouseUp || source.type == .leftMouseDragged {
            // Start a new window event rather than retaining AppKit's packed
            // addressing for the canvas that received the physical press.
            guard let mouse = CGEvent(mouseEventSource: postedSource, mouseType: source.type,
                                      mouseCursorPosition: point, mouseButton: .left) else { return false }
            mouse.flags = source.flags
            mouse.setIntegerValueField(.mouseEventClickState, value: source.getIntegerValueField(.mouseEventClickState))
            mouse.setIntegerValueField(.mouseEventNumber, value: mouseSequence)
            original = mouse
        } else {
            guard let copy = source.copy() else { return false }
            copy.location = point
            original = copy
        }
        address(original, to: proxy, window: windowID, local: local)
        if event.type == .leftMouseDown,
           let move = CGEvent(mouseEventSource: postedSource, mouseType: .mouseMoved,
                              mouseCursorPosition: original.location, mouseButton: .left) {
            move.flags = source.flags
            address(move, to: proxy, window: windowID, local: local)
            send(move)
        }
        send(original)
        return target === proxy
    }

    private func address(_ event: CGEvent, to proxy: WindowProxy, window: CGWindowID, local: CGPoint) {
        event.setIntegerValueField(Self.windowNumberField, value: Int64(window))
        event.setIntegerValueField(.eventTargetUnixProcessID, value: Int64(proxy.pid))
        event.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(window))
        event.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(window))
        Self.setWindowLocation?(event, local)
    }

    /// Presses what Accessibility finds at a native point in `pid`'s windows: a menu item, or a button,
    /// checkbox or radio button in a raised window. Off the main thread; anything else is left alone.
    nonisolated static func pressRaised(pid: pid_t, at point: CGPoint) {
        AXQueue.interactive.async {
            // Still open: once it closes, the same point can be a control in the window under it.
            guard WindowList.onScreen().contains(where: { $0.pid == pid && $0.layer > 0 && $0.bounds.contains(point) }) else {
                Log.note("Captured input: the raised window at \(NSStringFromPoint(point)) has closed; nothing pressed")
                return
            }
            let app = AXUIElementCreateApplication(pid)
            var element: AXUIElement?
            let hit = AXUIElementCopyElementAtPosition(app, Float(point.x), Float(point.y), &element)
            guard hit == .success, let element else {
                Log.note("Captured input: nothing at \(NSStringFromPoint(point)) in pid \(pid) for Accessibility (\(hit.rawValue))")
                return
            }
            var role: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
            let pressable: Set<String> = [kAXMenuItemRole, kAXButtonRole, kAXCheckBoxRole, kAXRadioButtonRole,
                                          kAXPopUpButtonRole, kAXMenuButtonRole]
            guard let r = role as? String, pressable.contains(r) else {
                Log.note("Captured input: \(role as? String ?? "?") at \(NSStringFromPoint(point)) isn't pressable; left alone")
                return
            }
            let result = AXUIElementPerformAction(element, kAXPressAction as CFString)
            Log.note("Captured input: pressed \(r) in a raised window of pid \(pid) (\(result.rawValue))")
        }
    }

    /// Another window of `pid` in front of the tile's own at a native point: a menu, pop-up list or
    /// popover above the normal level, or a sheet, alert or panel at it. On the bank its pixels fall in
    /// the tile's crop, so a press there is meant for it. Nil once the listing (front to back) reaches
    /// the tile's window.
    nonisolated static func windowInFront(of parent: CGWindowID, pid: pid_t, at point: CGPoint) -> WindowInfo? {
        for w in WindowList.onScreen() {
            if w.id == parent { return nil }
            if w.pid == pid, w.bounds.contains(point) { return w }
        }
        return nil
    }

    func key(_ event: NSEvent) -> Bool {
        guard target != nil else { return false }
        guard let copy = event.cgEvent?.copy() else { return false }
        send(copy)
        return true
    }

    private func routeEvents(to proxy: WindowProxy) -> Bool {
        inputEvents.select(pid: proxy.pid,
            receive: { [weak self] event in if let copy = event.copy() { self?.send(copy) } },
            pointer: { [weak self] event in _ = self?.onCanvasEvent?(event) })
    }

    private func prepare(_ proxy: WindowProxy) {
        clear(preserveClick: true)
        target = proxy
        keyboardOrigin = NSWorkspace.shared.frontmostApplication?.processIdentifier
        preparing = true
        guard routeEvents(to: proxy) else {
            clear(); onFailure?("Could not transfer keyboard input to the chosen window."); return
        }
        let generation = revision
        let pid = proxy.pid, id = proxy.windowID
        onWillFocus?(pid)
        AXQueue.interactive.async { [weak self, weak proxy] in
            let ax = AXWindow.windowsByID(pid: pid)?[id]
            ax?.raise()
            DispatchQueue.main.async {
                guard let self, let proxy, self.revision == generation, self.target === proxy else { return }
                guard let ax, WindowList.onScreen(id)?.pid == pid else {
                    self.clear()
                    self.onFailure?("This app's window could not be reached for captured input.")
                    return
                }
                proxy.ax = ax
                if let front = NSWorkspace.shared.frontmostApplication?.processIdentifier,
                   front != pid, front != self.keyboardOrigin, front != getpid() {
                    self.clear() // The user chose another app while AX was preparing this one.
                    return
                }
                if let app = NSRunningApplication(processIdentifier: pid) {
                    if !app.activate(from: .current, options: []), !app.activate(options: []) { _ = forceAppFront(pid) }
                }
                self.finishFocus(proxy, generation: generation, until: CACurrentMediaTime() + 0.75)
            }
        }
    }

    private func finishFocus(_ proxy: WindowProxy, generation: Int, until deadline: CFTimeInterval) {
        guard revision == generation, target === proxy else { return }
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        guard front == proxy.pid else {
            if let front, front != keyboardOrigin, front != getpid() { clear(); return }
            if CACurrentMediaTime() < deadline {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { [weak self, weak proxy] in
                    if let self, let proxy { self.finishFocus(proxy, generation: generation, until: deadline) }
                }
            } else {
                clear()
                onFailure?("The app did not accept focus. Its input was not sent.")
            }
            return
        }
        // The nonactivating panel can retain key focus while the app is already
        // frontmost. Release it only now; keys during preparation were queued.
        onFocused?()
        preparing = false
        let events = pending
        pending.removeAll()
        for event in events { send(event) }
    }

    private func send(_ event: CGEvent) {

        guard let target else { return }
        if preparing {
            guard pending.count < 256 else {
                clear()
                onFailure?("The app did not become ready for input. Click its tile to try again.")
                return
            }
            pending.append(event)
            return
        }
        guard post(event, to: target) else { clear(); return }
        if event.type == .leftMouseDown || (event.type == .leftMouseDragged && pointerDown != nil) { pointerDown = event.copy() }
        if event.type == .leftMouseUp { pointerDown = nil }
    }

    @discardableResult private func post(_ event: CGEvent, to proxy: WindowProxy) -> Bool {
        guard WindowList.onScreen(proxy.windowID)?.pid == proxy.pid else { return false }
        event.setIntegerValueField(.eventSourceUserData, value: CanvasView.passedOnMark)
        event.setIntegerValueField(.eventTargetUnixProcessID, value: Int64(proxy.pid))
        // Replayed input follows the posted press, not its earlier hardware time.
        event.timestamp = 0
        event.postToPid(proxy.pid)
        eventsPosted += 1
        return true
    }
}
