import AppKit

/// Installed before the canvas accepts clicks. A canvas press owns subsequent
/// releases and keys even before AppKit resolves which captured tile was hit.
/// Delivery happens outside the event-tap callback, in the original event order.
@MainActor
final class CapturedInputEvents {
    static let canvasReplayMark: Int64 = 0x53554e43
    private var port: CFMachPort?
    private var source: CFRunLoopSource?
    private var canvas: CGWindowID = 0
    private var presented: (() -> Bool)?
    private var cancelled: (() -> Void)?
    private var active = false
    private var resolved = false
    private var pid: pid_t = 0
    private var nativeRoutingSince: CGEventTimestamp?
    private var pressed = false
    private var queue: [CGEvent] = []
    private var scheduled = false
    private var receive: ((CGEvent) -> Void)?
    private var pointer: ((CGEvent) -> Void)?

    deinit {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let port { CFMachPortInvalidate(port) }
    }

    func install(canvas: CGWindowID, presented: @escaping () -> Bool, cancelled: @escaping () -> Void) -> Bool {
        self.canvas = canvas; self.presented = presented; self.cancelled = cancelled
        guard port == nil else { return true }
        let types: [CGEventType] = [.keyDown, .keyUp, .flagsChanged, .leftMouseDown, .leftMouseDragged,
                                   .leftMouseUp, .rightMouseDown, .otherMouseDown]
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        let callback: CGEventTapCallBack = { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            return MainActor.assumeIsolated {
                Unmanaged<CapturedInputEvents>.fromOpaque(context).takeUnretainedValue().route(type, event)
            }
        }
        guard let port = CGEvent.tapCreate(tap: .cgAnnotatedSessionEventTap, place: .headInsertEventTap,
            options: .defaultTap, eventsOfInterest: mask, callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()),
              let source = CFMachPortCreateRunLoopSource(nil, port, 0) else { return false }
        self.port = port; self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        return true
    }

    func select(pid: pid_t, receive: @escaping (CGEvent) -> Void, pointer: @escaping (CGEvent) -> Void) -> Bool {
        guard let port, CFMachPortIsValid(port), CGEvent.tapIsEnabled(tap: port) else { return false }
        self.pid = pid; self.receive = receive; self.pointer = pointer
        active = true; resolved = true
        schedule()
        return true
    }

    func releaseToCanvas(replay: Bool = false) {
        if !queue.isEmpty, !replay { Log.note("Captured input: \(queue.count) held event(s) dropped (types \(queue.map(\.type.rawValue)))") }
        if replay && active && !resolved {
            let held = queue; queue.removeAll()
            DispatchQueue.main.async { [canvas] in
                for event in held {
                    event.setIntegerValueField(.eventSourceUserData, value: Self.canvasReplayMark)
                    event.setIntegerValueField(CGEventField(rawValue: 51)!, value: Int64(canvas))
                    event.setIntegerValueField(.eventTargetUnixProcessID, value: Int64(getpid()))
                    event.timestamp = 0
                    event.postToPid(getpid())
                }
            }
        }
        active = false; resolved = false; receive = nil; pointer = nil; queue.removeAll()
    }

    func shutdown() {
        active = false; resolved = false; queue.removeAll(); receive = nil; pointer = nil
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let port { CFMachPortInvalidate(port) }
        source = nil; port = nil
    }

    private func schedule() {
        guard resolved, !scheduled else { return }
        scheduled = true
        DispatchQueue.main.async { [weak self] in self?.drain() }
    }

    private func drain() {
        scheduled = false
        guard active, resolved else { return }
        let held = queue; queue.removeAll()
        for event in held {
            guard active, resolved else { return }
            if event.type == .leftMouseDragged || event.type == .leftMouseUp { pointer?(event) }
            else { receive?(event) }
        }
    }

    private func route(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            Log.note("Captured input: the event tap was disabled (\(type == .tapDisabledByTimeout ? "timeout" : "user input")), \(queue.count) held")
            releaseToCanvas()
            if let port { CGEvent.tapEnable(tap: port, enable: true) }
            let cancelled = cancelled
            DispatchQueue.main.async { cancelled?() }
            return Unmanaged.passUnretained(event)
        }
        let mark = event.getIntegerValueField(.eventSourceUserData)
        if mark == CanvasView.passedOnMark || mark == Self.canvasReplayMark { return Unmanaged.passUnretained(event) }
        if type == .leftMouseDown || type == .rightMouseDown || type == .otherMouseDown {
            let onCanvas = presented?() == true
                && event.getIntegerValueField(CGEventField(rawValue: 51)!) == Int64(canvas)
            if onCanvas, type == .leftMouseDown {
                active = true; resolved = false; pressed = type == .leftMouseDown
                nativeRoutingSince = nil; queue.removeAll()
            } else if active {
                releaseToCanvas()
                let cancelled = cancelled
                DispatchQueue.main.async { cancelled?() }
            }
            return Unmanaged.passUnretained(event)
        }
        guard active else { return Unmanaged.passUnretained(event) }
        if type == .leftMouseDragged || type == .leftMouseUp {
            guard pressed else { return Unmanaged.passUnretained(event) }
            if type == .leftMouseUp { pressed = false }
        } else if resolved {
            let destination = pid_t(event.getIntegerValueField(.eventTargetUnixProcessID))
            if type == .keyDown, destination == pid, nativeRoutingSince == nil { nativeRoutingSince = event.timestamp }
            if type == .keyDown, let since = nativeRoutingSince, event.timestamp >= since,
               destination > 0, destination != pid {
                releaseToCanvas()
                let cancelled = cancelled
                DispatchQueue.main.async { cancelled?() }
                return Unmanaged.passUnretained(event)
            }
        }
        if let copy = event.copy() {
            if type == .leftMouseDragged || type == .leftMouseUp {
                copy.setIntegerValueField(CGEventField(rawValue: 51)!, value: Int64(canvas))
            }
            queue.append(copy); schedule()
        }
        return nil
    }
}
