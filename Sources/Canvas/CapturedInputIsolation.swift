import AppKit
import os

/// App activation can also deliver the canvas's physical drag/release to the
/// source PID. Correct that foreign window address before AppKit consumes it.
/// Keep the real event in the delivery path so WindowServer completes the gesture.
final class CapturedInputIsolation {
    private final class Destination {
        let windows = OSAllocatedUnfairLock(initialState: Set<CGWindowID>())
        let mark: Int64
        let rewrite: (CGEvent) -> CGEvent?
        var port: CFMachPort?
        var source: CFRunLoopSource?
        init(mark: Int64, rewrite: @escaping (CGEvent) -> CGEvent?) { self.mark = mark; self.rewrite = rewrite }
        func stop() {
            if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
            if let port { CFMachPortInvalidate(port) }
            source = nil; port = nil
        }
        deinit { stop() }
    }
    private var destinations: [pid_t: Destination] = [:]

    func protect(pid: pid_t, canvas: CGWindowID, mark: Int64, rewrite: @escaping (CGEvent) -> CGEvent?) -> Bool {
        guard canvas != 0 else { return false }
        if let old = destinations[pid], let port = old.port, !CFMachPortIsValid(port) { destinations[pid] = nil }
        if let existing = destinations[pid] { existing.windows.withLock { _ = $0.insert(canvas) }; return true }
        let destination = Destination(mark: mark, rewrite: rewrite)
        destination.windows.withLock { _ = $0.insert(canvas) }
        // A restricted PID-tap mask starved AppKit keyboard delivery while
        // tracking a mouse gesture. Preserve the full stream and change only
        // the foreign canvas drag/release events below.
        let mask = CGEventMask(UInt64.max)
        let callback: CGEventTapCallBack = { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            let d = Unmanaged<Destination>.fromOpaque(context).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let port = d.port { CGEvent.tapEnable(tap: port, enable: true) }
                return Unmanaged.passUnretained(event)
            }
            guard type == .leftMouseDragged || type == .leftMouseUp else { return Unmanaged.passUnretained(event) }
            if event.getIntegerValueField(.eventSourceUserData) == d.mark { return Unmanaged.passUnretained(event) }
            let number = event.getIntegerValueField(CGEventField(rawValue: 51)!)
            let foreign = number > 0 && number <= Int64(UInt32.max) && d.windows.withLock { $0.contains(CGWindowID(number)) }
            if foreign, let corrected = MainActor.assumeIsolated({ d.rewrite(event) }) { return Unmanaged.passRetained(corrected) }
            return Unmanaged.passUnretained(event)
        }
        guard let port = CGEvent.tapCreateForPid(pid: pid, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask, callback: callback, userInfo: Unmanaged.passUnretained(destination).toOpaque()),
              let source = CFMachPortCreateRunLoopSource(nil, port, 0) else { return false }
        destination.port = port; destination.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        destinations[pid] = destination
        return true
    }

    func shutdown() { for destination in destinations.values { destination.stop() }; destinations.removeAll() }
}
