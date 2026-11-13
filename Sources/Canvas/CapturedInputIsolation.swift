import AppKit
import os

/// App activation can deliver canvas-addressed pointer/gesture events to the
/// focused app. The canvas owns those events. Other app events, including all
/// keyboard input, pass through unchanged.
final class CapturedInputIsolation {
    private final class Destination {
        let windows = OSAllocatedUnfairLock(initialState: Set<CGWindowID>())
        let mark: Int64
        let canvasEvent: (CGEvent) -> Bool
        var port: CFMachPort?
        var source: CFRunLoopSource?
        init(mark: Int64, canvasEvent: @escaping (CGEvent) -> Bool) {
            self.mark = mark; self.canvasEvent = canvasEvent
        }
        func stop() {
            if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
            if let port { CFMachPortInvalidate(port) }
            source = nil; port = nil
        }
        deinit { stop() }
    }
    private var destinations: [pid_t: Destination] = [:]

    func protect(pid: pid_t, canvas: CGWindowID, mark: Int64,
                 canvasEvent: @escaping (CGEvent) -> Bool) -> Bool {
        guard canvas != 0 else { return false }
        if let old = destinations[pid], let port = old.port, !CFMachPortIsValid(port) { destinations[pid] = nil }
        if let existing = destinations[pid] { existing.windows.withLock { _ = $0.insert(canvas) }; return true }
        let destination = Destination(mark: mark, canvasEvent: canvasEvent)
        destination.windows.withLock { _ = $0.insert(canvas) }
        // A restricted PID-tap mask starved AppKit keyboard delivery while
        // tracking a mouse gesture. Pass unrelated events without alteration.
        let mask = CGEventMask(UInt64.max)
        let callback: CGEventTapCallBack = { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            let d = Unmanaged<Destination>.fromOpaque(context).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let port = d.port { CGEvent.tapEnable(tap: port, enable: true) }
                return Unmanaged.passUnretained(event)
            }
            if event.getIntegerValueField(.eventSourceUserData) == d.mark { return Unmanaged.passUnretained(event) }
            let navigation = type == .scrollWheel || type.rawValue == UInt32(NSEvent.EventType.gesture.rawValue)
            guard navigation || type == .leftMouseDown || type == .leftMouseDragged || type == .leftMouseUp else { return Unmanaged.passUnretained(event) }
            let field = CGEventField(rawValue: 51)!
            let number = event.getIntegerValueField(field)
            var foreign = number > 0 && number <= Int64(UInt32.max) && d.windows.withLock { $0.contains(CGWindowID(number)) }
            // A press grabbed by the app's own open menu (or other raised window) on a source display:
            // addressed to that window, though the real pointer is over the canvas on the physical
            // display, nowhere near it. It is the canvas's: re-addressed, so the canvas's tile input
            // presses the menu item (`CapturedWindowInput`). Measured 2026-11-13: the first click on an
            // open menu went to the menu's tracking, unseen by the canvas, and nothing was chosen.
            if !foreign, type != .scrollWheel, number > 0, number <= Int64(UInt32.max),
               let grabbed = WindowList.onScreen(CGWindowID(number)), grabbed.layer > 0,
               !grabbed.bounds.contains(event.location), let canvas = d.windows.withLock({ $0.first }) {
                event.setIntegerValueField(field, value: Int64(canvas))
                foreign = true
            }
            if foreign, MainActor.assumeIsolated({ d.canvasEvent(event) }) { return nil }
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
