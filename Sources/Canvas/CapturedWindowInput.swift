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
    private var pointerTap: PressTap?
    private var pointerDown: CGEvent?
    private(set) var eventsPosted = 0
    var onFailure: ((String) -> Void)?
    var worldAtScreenPoint: ((CGPoint) -> CGPoint)?
    var onPointerReleased: (() -> Void)?

    var windowID: CGWindowID? { target?.windowID }

    init() {
        if SIPRedesign.enabled {
            let tap = PressTap { _ in }
            pointerTap = tap
            tap.start()
        }
    }

    func shutdown() { clear(); pointerTap?.stop() }

    func clear() {
        if let down = pointerDown, let target,
           WindowList.onScreen(target.windowID)?.pid == target.pid, let up = down.copy() {
            up.type = .leftMouseUp
            up.postToPid(target.pid)
        }
        pointerDown = nil
        pointerTap?.endCapturedDrag()
        onPointerReleased?()
        revision += 1
        target = nil
        preparing = false
        pending.removeAll()
    }

    /// Uses the same world coordinates as Sunlight's camera. Native window
    /// coordinates are read from WindowServer, rather than assumed to equal
    /// the freely arranged tile's world rectangle.
    nonisolated static func nativePoint(world: CGPoint, tile: CGRect, native: CGRect) -> CGPoint {
        CGPoint(x: native.minX + world.x - tile.minX,
                y: native.minY + world.y - tile.minY)
    }

    func pointer(_ event: NSEvent, to proxy: WindowProxy, world: CGPoint) {
        guard Self.setWindowLocation != nil else {
            clear()
            onFailure?("Window-addressed input is unavailable on this macOS version.")
            return
        }
        guard let source = event.cgEvent,
              let native = WindowList.onScreen(proxy.windowID), native.pid == proxy.pid else {
            clear()
            return
        }
        if target !== proxy { prepare(proxy, native: native.bounds) }
        if event.type == .leftMouseDown, !startPointerRouting() {
            clear()
            onFailure?("Accessibility permission is needed to route this drag safely.")
            return
        }
        let point = Self.nativePoint(world: world, tile: proxy.worldRect, native: native.bounds)
        let original: CGEvent
        if source.type == .leftMouseDown || source.type == .leftMouseUp || source.type == .leftMouseDragged {
            // Start a new window event rather than retaining AppKit's packed
            // addressing for the canvas that received the physical press.
            guard let mouse = CGEvent(mouseEventSource: nil, mouseType: source.type,
                                      mouseCursorPosition: point, mouseButton: .left) else { return }
            mouse.flags = source.flags
            mouse.timestamp = source.timestamp
            mouse.setIntegerValueField(.mouseEventClickState, value: source.getIntegerValueField(.mouseEventClickState))
            mouse.setIntegerValueField(.mouseEventNumber, value: source.getIntegerValueField(.mouseEventNumber))
            mouse.setDoubleValueField(.mouseEventPressure, value: source.getDoubleValueField(.mouseEventPressure))
            original = mouse
        } else {
            guard let copy = source.copy() else { return }
            copy.location = point
            original = copy
        }
        let local = CGPoint(x: world.x - proxy.worldRect.minX, y: world.y - proxy.worldRect.minY)
        address(original, to: proxy, local: local)
        if event.type == .scrollWheel,
           let move = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                              mouseCursorPosition: original.location, mouseButton: .left) {
            address(move, to: proxy, local: local)
            send(move)
        }
        send(original)
    }

    private func startPointerRouting() -> Bool {
        guard let pointerTap else { return false }
        let generation = revision
        return pointerTap.captureDrag { [weak self] type, event in
            DispatchQueue.main.async {
                guard let self, self.revision == generation else { return }
                self.routePointer(type, event: event)
            }
        }
    }

    private func routePointer(_ type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput { clear(); return }
        guard event.getIntegerValueField(.eventSourceUserData) != CanvasView.passedOnMark,
              let target, let worldAtScreenPoint, let converted = NSEvent(cgEvent: event) else {
            return
        }
        // AppKit drag tracking can take the physical stream after a PID-posted
        // down. Consume it once here and send only the translated window event.
        // The visible system cursor follows the person's physical pointer.
        pointer(converted, to: target, world: worldAtScreenPoint(event.location))
        if type == .leftMouseUp {
            onPointerReleased?()
        }
    }

    private func address(_ event: CGEvent, to proxy: WindowProxy, local: CGPoint) {
        event.setIntegerValueField(Self.windowNumberField, value: Int64(proxy.windowID))
        event.setIntegerValueField(.eventTargetUnixProcessID, value: Int64(proxy.pid))
        event.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(proxy.windowID))
        event.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(proxy.windowID))
        Self.setWindowLocation?(event, local)
    }

    func key(_ event: NSEvent) -> Bool {
        guard target != nil else { return false }
        // Escape gives the keyboard back to the canvas in this initial slice.
        if event.keyCode == 53 { clear(); return false }
        guard let copy = event.cgEvent?.copy() else { return false }
        send(copy)
        return true
    }

    private func prepare(_ proxy: WindowProxy, native: CGRect) {
        clear()
        target = proxy
        preparing = true
        let generation = revision
        let pid = proxy.pid, id = proxy.windowID
        AXQueue.interactive.async { [weak self, weak proxy] in
            let ax = AXWindow.find(windowID: id, pid: pid, approximateFrame: native)
            ax?.raise()
            DispatchQueue.main.async {
                guard let self, let proxy, self.revision == generation, self.target === proxy else { return }
                guard let ax, WindowList.onScreen(id)?.pid == pid else {
                    self.clear()
                    self.onFailure?("This app's window could not be reached for captured input.")
                    return
                }
                proxy.ax = ax
                if let app = NSRunningApplication(processIdentifier: pid), !app.activate(options: []) {
                    _ = forceAppFront(pid)
                }
                self.finishFocus(proxy, generation: generation, until: CACurrentMediaTime() + 0.75)
            }
        }
    }

    private func finishFocus(_ proxy: WindowProxy, generation: Int, until deadline: CFTimeInterval) {
        guard revision == generation, target === proxy else { return }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == proxy.pid else {
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
        guard WindowList.onScreen(target.windowID)?.pid == target.pid else { clear(); return }
        event.setIntegerValueField(.eventSourceUserData, value: CanvasView.passedOnMark)
        event.postToPid(target.pid)
        if event.type == .leftMouseDown || (event.type == .leftMouseDragged && pointerDown != nil) { pointerDown = event.copy() }
        if event.type == .leftMouseUp { pointerDown = nil }
        eventsPosted += 1
    }
}
