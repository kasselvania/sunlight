import AppKit

/// Windows on other Desktops, brought to the main one while Sunlight runs and taken back at quit, without
/// SIP. Moving a window to a Space is the Dock's private business (the SIP build's add-on asked the Dock);
/// what anyone can do is what a person does: hold the window by its title bar and switch Desktop with
/// ⌃← / ⌃→. The window travels with the pointer. Behind the transition cover, nobody sees it happen.
///
/// The Desktop map is read through SkyLight (read-only calls, which SIP allows). Verified by hand on
/// 2026-11-13: a test window carried to Desktop 2 and back, the map agreeing each time.
@MainActor
enum SpacesCarry {
    /// A window brought from another Desktop: how many Desktops to the right of the main one it lives on
    /// (negative: to the left).
    struct Origin: Codable, Equatable {
        let id: CGWindowID
        let offset: Int
    }

    // MARK: The Desktop map (read-only SkyLight)

    private typealias MainConnection = @convention(c) () -> Int32
    private typealias CopySpaces = @convention(c) (Int32) -> Unmanaged<CFArray>?
    private typealias CopySpacesForWindows = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?
    private static let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
    private static func symbol<T>(_ name: String, as: T.Type) -> T? {
        guard let skyLight, let s = dlsym(skyLight, name) else { return nil }
        return unsafeBitCast(s, to: T.self)
    }

    /// The main display's Desktops in order (ordinary ones only) and the current one.
    private static func desktops() -> (ids: [Int], current: Int)? {
        guard let main = symbol("SLSMainConnectionID", as: MainConnection.self),
              let copy = symbol("SLSCopyManagedDisplaySpaces", as: CopySpaces.self),
              let displays = copy(main())?.takeRetainedValue() as? [[String: Any]],
              let uuid = CGDisplayCreateUUIDFromDisplayID(CGMainDisplayID())?.takeRetainedValue(),
              let mainID = CFUUIDCreateString(nil, uuid) as String? else { return nil }
        let display = displays.first { ($0["Display Identifier"] as? String) == mainID } ?? displays.first
        guard let display, let current = (display["Current Space"] as? [String: Any])?["ManagedSpaceID"] as? Int else { return nil }
        let ids = (display["Spaces"] as? [[String: Any]] ?? []).filter { ($0["type"] as? Int) == 0 }.compactMap { $0["ManagedSpaceID"] as? Int }
        return (ids, current)
    }

    private static func spaces(of id: CGWindowID) -> [Int] {
        guard let main = symbol("SLSMainConnectionID", as: MainConnection.self),
              let copy = symbol("SLSCopySpacesForWindows", as: CopySpacesForWindows.self),
              let list = copy(main(), 0x7, [NSNumber(value: id)] as CFArray)?.takeRetainedValue() as? [NSNumber] else { return [] }
        return list.map(\.intValue)
    }

    /// Ordinary windows of running, unhidden apps that live on another Desktop of the main display.
    static func windowsElsewhere() -> [(id: CGWindowID, pid: pid_t, frame: CGRect, offset: Int)] {
        guard let map = desktops(), let here = map.ids.firstIndex(of: map.current) else { return [] }
        let onScreen = Set(WindowList.onScreen().map(\.id))
        let all = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return all.compactMap { w in
            guard (w[kCGWindowLayer as String] as? Int) == 0, let id = w[kCGWindowNumber as String] as? CGWindowID,
                  !onScreen.contains(id), let pid = w[kCGWindowOwnerPID as String] as? pid_t, pid != getpid(),
                  let d = w[kCGWindowBounds as String] as! CFDictionary?, let frame = CGRect(dictionaryRepresentation: d),
                  frame.width >= 200, frame.height >= 150,
                  let app = NSRunningApplication(processIdentifier: pid), !app.isHidden, app.activationPolicy == .regular,
                  let space = spaces(of: id).first, space != map.current, let there = map.ids.firstIndex(of: space) else { return nil }
            return (id, pid, frame, there - here)
        }
    }

    // MARK: Carrying

    /// On the carry's own events, so the canvas's key tap (which keeps ⌃← ⌃→ during takeover) lets them be.
    nonisolated static let mark: Int64 = 0x5350_4143   // "SPAC"
    private static let source = CGEventSource(stateID: .hidSystemState)
    private static func mouse(_ type: CGEventType, _ p: CGPoint) {
        CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
    }
    private static func key(_ code: CGKeyCode, _ down: Bool, _ flags: CGEventFlags) {
        let e = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down)
        e?.flags = flags
        e?.setIntegerValueField(.eventSourceUserData, value: mark)
        e?.post(tap: .cghidEventTap)
    }
    private static func pause(_ seconds: Double) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }

    /// ⌃← / ⌃→ `abs(steps)` times, as a keyboard sends them (the arrow carries the Fn and keypad flags;
    /// without them the Desktop shortcut doesn't match). Each switch is waited for until the Desktop map
    /// says it landed, then a beat for the animation to end: a fixed wait once let the quit's Dock restart
    /// cut a switch short, and the screen stayed frozen mid-switch until another ⌃← (2026-11-13).
    private static func switchDesktop(_ steps: Int) async {
        guard steps != 0 else { return }
        let code: CGKeyCode = steps > 0 ? 124 : 123
        let arrow: CGEventFlags = [.maskControl, .maskSecondaryFn, .maskNumericPad]
        for _ in 0..<abs(steps) {
            let before = desktops()
            let expected: Int? = before.flatMap { map in
                map.ids.firstIndex(of: map.current).flatMap { i in
                    let j = i + (steps > 0 ? 1 : -1)
                    return map.ids.indices.contains(j) ? map.ids[j] : nil
                }
            }
            key(59, true, .maskControl); await pause(0.03)
            key(code, true, arrow); await pause(0.04); key(code, false, arrow); await pause(0.03)
            key(59, false, [])
            await settle(on: expected)
        }
    }

    /// Until the Desktop map's current Desktop is `id` (2 s at most), then the animation's last frames.
    private static func settle(on id: Int?) async {
        guard let id else { await pause(0.85); return }
        for _ in 0..<40 {
            if desktops()?.current == id { break }
            await pause(0.05)
        }
        await pause(0.45)
    }

    /// Back on `home`, however the switches went: one more try if the map disagrees.
    private static func returnHome(_ home: Int?) async {
        guard let home, let map = desktops(), map.current != home,
              let i = map.ids.firstIndex(of: map.current), let j = map.ids.firstIndex(of: home) else { return }
        Log.note("Spaces: not back on the main Desktop; switching \(j - i)")
        await switchDesktop(j - i)
    }

    /// A point on the window's title bar that moves the window when dragged: Accessibility says what's
    /// there, and a tab, button or field is never it (a dragged tab would leave its window).
    private static func grabPoint(pid: pid_t, frame: CGRect) -> CGPoint? {
        let system = AXUIElementCreateSystemWide()
        for y in [frame.minY + 10, frame.minY + 16, frame.minY + 6] {
            for fx in [0.5, 0.4, 0.6, 0.3, 0.7, 0.2, 0.8] {
                let p = CGPoint(x: frame.minX + frame.width * fx, y: y)
                var element: AXUIElement?
                guard AXUIElementCopyElementAtPosition(system, Float(p.x), Float(p.y), &element) == .success, let element else { continue }
                var owner: pid_t = 0
                AXUIElementGetPid(element, &owner)
                guard owner == pid else { continue }
                var role: CFTypeRef?
                AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
                let r = role as? String ?? ""
                var actions: CFArray?
                AXUIElementCopyActionNames(element, &actions)
                let pressable = (actions as? [String] ?? []).contains(kAXPressAction as String)
                if r == kAXWindowRole as String || r == kAXStaticTextRole as String { return p }
                if [kAXToolbarRole as String, kAXGroupRole as String, kAXUnknownRole as String].contains(r), !pressable { return p }
            }
        }
        return nil
    }

    /// Holds the window at `p` and switches `steps` Desktops, then lets go where it took hold.
    private static func carry(at p: CGPoint, steps: Int) async {
        mouse(.mouseMoved, p); await pause(0.12)
        mouse(.leftMouseDown, p); await pause(0.2)
        mouse(.leftMouseDragged, CGPoint(x: p.x + 3, y: p.y)); await pause(0.08)
        mouse(.leftMouseDragged, CGPoint(x: p.x + 6, y: p.y)); await pause(0.12)
        await switchDesktop(steps)
        mouse(.leftMouseDragged, CGPoint(x: p.x + 3, y: p.y)); await pause(0.05)
        mouse(.leftMouseDragged, p); await pause(0.08)
        mouse(.leftMouseUp, p); await pause(0.08)
        key(59, false, [])   // a window drag can swallow the first ⌃ release
    }

    /// The Desktop shortcuts are on (System Settings › Keyboard › Shortcuts › Mission Control).
    static var shortcutsOn: Bool {
        guard let hotkeys = UserDefaults(suiteName: "com.apple.symbolichotkeys")?.dictionary(forKey: "AppleSymbolicHotKeys") else { return true }
        func on(_ k: String) -> Bool { ((hotkeys[k] as? [String: Any])?["enabled"] as? Bool) ?? true }
        return on("79") && on("81")
    }

    /// Brings every window on another Desktop to this one; returns where each came from. The pointer
    /// goes back where it was.
    static func gather() async -> [Origin] {
        let elsewhere = windowsElsewhere()
        guard !elsewhere.isEmpty else { return [] }
        guard shortcutsOn else {
            Log.note("Spaces: \(elsewhere.count) window(s) on other Desktops stay there: the ⌃←/⌃→ Desktop shortcuts are off")
            return []
        }
        let pointer = CGEvent(source: nil)?.location
        let home = desktops()?.current
        var origins: [Origin] = []
        for w in elsewhere.sorted(by: { $0.offset < $1.offset }) {
            await switchDesktop(w.offset)
            NSRunningApplication(processIdentifier: w.pid)?.activate(options: [])
            await pause(0.25)
            let frame = WindowList.onScreen(w.id)?.bounds ?? w.frame
            guard let p = grabPoint(pid: w.pid, frame: frame) else {
                Log.note("Spaces: no title bar to hold on window \(w.id); it stays on its Desktop")
                await switchDesktop(-w.offset)
                continue
            }
            await carry(at: p, steps: -w.offset)
            let back = desktops()
            let arrived = back.map { spaces(of: w.id).contains($0.current) } ?? false
            Log.note("Spaces: window \(w.id) from \(w.offset > 0 ? "+" : "")\(w.offset) Desktop(s) \(arrived ? "brought here" : "did not come")")
            if arrived { origins.append(Origin(id: w.id, offset: w.offset)) }
            await returnHome(home)
        }
        await returnHome(home)
        if let pointer { CGWarpMouseCursorPosition(pointer) }
        return origins
    }

    /// Takes each gathered window back to its Desktop, and comes back to this one.
    static func scatter(_ origins: [Origin]) async {
        guard !origins.isEmpty, shortcutsOn else { return }
        let pointer = CGEvent(source: nil)?.location
        let home = desktops()?.current
        for o in origins {
            guard let w = WindowList.onScreen(o.id) else { continue }
            NSRunningApplication(processIdentifier: w.pid)?.activate(options: [])
            await pause(0.25)
            guard let p = grabPoint(pid: w.pid, frame: w.bounds) else {
                Log.note("Spaces: no title bar to hold on window \(o.id); it stays on this Desktop")
                continue
            }
            await carry(at: p, steps: o.offset)
            await switchDesktop(-o.offset)
            await returnHome(home)
            Log.note("Spaces: window \(o.id) taken back \(o.offset > 0 ? "+" : "")\(o.offset) Desktop(s)")
        }
        await returnHome(home)
        if let pointer { CGWarpMouseCursorPosition(pointer) }
    }
}
