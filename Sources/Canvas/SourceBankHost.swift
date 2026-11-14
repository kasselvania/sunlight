import AppKit
import SourceDisplay

/// The unprivileged child owns the display and every AX placement. The private
/// pipe's EOF restores its cached AX windows before releasing the display, even
/// when the canvas process is killed. No Dock code, daemon or root operation.
final class SourceBankHost: @unchecked Sendable {
    static var folder: URL { SIPRedesign.statusURL.deletingLastPathComponent().appendingPathComponent("Window Bank", isDirectory: true) }
    static var journalURL: URL { folder.appendingPathComponent("active.json") }
    /// Where released windows went: macOS may move a window back onto a bank display when that display
    /// returns (the next launch reuses its identity), and a window adopted from there would otherwise
    /// take its bank spot for its home and be restored, at quit, to that spot pulled onto the screen.
    static var returnedURL: URL { folder.appendingPathComponent("returned.json") }

    struct Returned: Codable {
        let process: BankProcess
        let ax: CGRect
        let cg: CGRect
    }

    private static func loadReturned() -> [String: Returned] {
        guard let data = try? Data(contentsOf: returnedURL),
              let all = try? JSONDecoder().decode([String: Returned].self, from: data) else { return [:] }
        return all.filter { $0.value.process.isLive }
    }

    /// A window just went back to a physical display at `ax` (`cg` in the window list's terms).
    private func noteReturned(_ record: BankRecord, ax: CGRect, cg: CGRect) {
        var all = Self.loadReturned()
        all[String(record.id)] = Returned(process: record.process, ax: ax, cg: cg)
        if let data = try? JSONEncoder().encode(all) { try? data.write(to: Self.returnedURL, options: .atomic) }
    }
    private let queue = DispatchQueue(label: "sunlight.bank.placement", qos: .userInitiated)
    private let token: String
    private var journal: BankJournal
    private var handles: [CGWindowID: AXWindow] = [:]
    private var displays: [SLSourceDisplay] = []
    private var banks: [CGDirectDisplayID: CGRect] = [:]
    private var physical: [CGRect] = []
    private var physicalIDs = Set<CGDirectDisplayID>()
    private var displayIDs: [CGDirectDisplayID] = []
    private var stopping = false
    private var health: Timer?
    private var disconnectSignal: DispatchSourceSignal?

    init(token: String) {
        self.token = token
        journal = BankJournal(token: token, host: BankProcess(getpid())!, records: [])
    }

    @MainActor static func run(token: String, recoverOnly: Bool) -> Never {
        signal(SIGPIPE, SIG_IGN)
        AXWindow.installGlobalTimeout(0.5)
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let host = SourceBankHost(token: token)
        guard AXIsProcessTrusted() else { host.send(["event": "failed", "error": "Window-bank restoration needs Accessibility access."]); exit(1) }
        host.queue.async {
            do {
                try host.recoverPrevious()
                if recoverOnly { host.send(["event": "stopped", "reason": "journal recovered", "remaining": 0]); exit(0) }
                DispatchQueue.main.async { host.createDisplay() }
            } catch { host.send(["event": "failed", "error": error.localizedDescription]); exit(1) }
        }
        withExtendedLifetime(host) { app.run() }
        exit(0)
    }

    // SIP PERFORMANCE: bank count, dimensions and scale control capacity and
    // overflow contention. See docs/sip-redesign-performance.md before tuning.
    @MainActor private func createDisplay() {
        let screens = Display.all
        physical = screens.map(\.visible)
        physicalIDs = Set(screens.map(\.id))
        let fps = SIPRedesign.frameRate(displayID: screens.first?.id ?? CGMainDisplayID())
        let size = SourceBankGeometry.bankSize(physical: screens.map(\.frame.size))
        // Create the bank set before the canvas discovers physical displays.
        // Shared feeds replace the expensive per-window overflow streams.
        for slot in 0..<SLSourceDisplayBankSlotCount {
            guard let display = autoreleasepool(invoking: { SLSourceDisplay(bankSlot: slot, width: UInt(size.width), height: UInt(size.height), scale: 2, refreshRate: Double(fps)) }),
                  !physicalIDs.contains(display.displayID), !displayIDs.contains(display.displayID) else {
                send(["event": "failed", "error": "The window-bank display slots are unavailable or still in use."]); exit(1)
            }
            displays.append(display); displayIDs.append(display.displayID)
        }
        journal.displayIDs = displayIDs
        SIPRedesign.sourceDisplayIDs = Set(displayIDs)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.displayReady() }
    }

    @MainActor private func displayReady(attempt: Int = 0) {
        let active = SourceBankGeometry.activeDisplayIDs()
        var descriptions: [[String: Any]] = []
        for id in displayIDs {
            let bounds = CGDisplayBounds(id)
            let screen = NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id }
            let scale = CGDisplayCopyDisplayMode(id).map { Double($0.pixelWidth) / max(1, bounds.width) } ?? screen?.backingScaleFactor ?? 0
            guard active.contains(id), bounds.width >= 1024, bounds.height >= 768, scale >= 1.9,
                  !physical.contains(where: { $0.intersects(bounds) }), CGDisplayMirrorsDisplay(id) == 0,
                  !banks.contains(where: { $0.key != id && $0.value.intersects(bounds) }) else {
                if attempt < 30 {
                    banks.removeAll()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.displayReady(attempt: attempt + 1) }
                    return
                }
                send(["event": "failed", "error": "The window-bank displays did not settle as separate Retina displays."]); exit(1)
            }
            banks[id] = bounds
            descriptions.append(["id": id, "bounds": NSStringFromRect(bounds), "scale": scale])
        }
        send(["event": "ready", "displays": descriptions, "host_pid": getpid(), "host_bundle_id": Bundle.main.bundleIdentifier ?? "",
              "host_path": Bundle.main.bundlePath, "physical_ids": physicalIDs.sorted()])
        DispatchQueue.global(qos: .userInitiated).async {
            while let line = readLine() { self.queue.sync { self.receive(line) } }
            self.queue.async { self.finish(reason: "canvas exited") }
        }
        health = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let screens = Display.all
                let ids = Set(screens.map(\.id))
                guard !ids.isEmpty else { return }  // display sleep is not removal
                let changed = ids != self.physicalIDs || !Set(self.displayIDs).isSubset(of: SourceBankGeometry.activeDisplayIDs())
                    || self.banks.contains(where: { CGDisplayBounds($0.key) != $0.value })
                if changed {
                    let physical = screens.map(\.visible)
                    self.queue.async { self.physical = physical; self.finish(reason: "display configuration changed") }
                }
            }
        }
        // A bounded disconnect exercise uses the actual display teardown path,
        // without changing any physical monitor's configuration.
        signal(SIGUSR1, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            if !self.displays.isEmpty { self.displays.removeLast() }
            self.queue.async { self.finish(reason: "source display disconnected") }
        }
        source.resume()
        disconnectSignal = source
    }

    private func receive(_ line: String) {
        guard let data = line.data(using: .utf8), let command = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let request = command["request"] as? Int, let operation = command["operation"] as? String else { return }
        do {
            guard !stopping else { throw failure("The window bank is restoring its originals.") }
            switch operation {
            case "park":
                let id = (command["id"] as? NSNumber)?.uint32Value ?? 0
                let pid = (command["pid"] as? NSNumber)?.int32Value ?? 0
                let record = try park(id, pid: pid, adopt: command["adopt"] as? Bool ?? false)
                send(["event": "reply", "request": request, "record": try object(record)])
            case "place":
                // In order: each slot is chosen against where the ones before it were just put.
                let ids = (command["ids"] as? [NSNumber])?.map(\.uint32Value) ?? []
                // Optional size to make room for (a resize about to happen), else the window's own.
                var room: CGSize?
                if let w = (command["width"] as? NSNumber)?.doubleValue, let h = (command["height"] as? NSNumber)?.doubleValue {
                    room = CGSize(width: w, height: h)
                }
                var results: [[String: Any]] = []
                for id in ids {
                    do { results.append(["id": id, "record": try object(try place(id, room: room))]) }
                    catch { results.append(["id": id, "error": error.localizedDescription]) }
                }
                send(["event": "reply", "request": request, "results": results])
            case "release":
                let id = (command["id"] as? NSNumber)?.uint32Value ?? 0
                var to: CGPoint?
                if let x = (command["x"] as? NSNumber)?.doubleValue, let y = (command["y"] as? NSNumber)?.doubleValue {
                    to = CGPoint(x: x, y: y)
                }
                let restored = try restore(id, to: to)
                send(["event": "reply", "request": request, "restored": restored.map { NSStringFromRect($0) } ?? ""])
            case "stop": finish(reason: "requested")
            default: throw failure("Unknown window-bank operation.")
            }
        } catch { send(["event": "reply", "request": request, "error": error.localizedDescription]) }
    }

    /// `adopt`: the window is already on a source display (macOS returned it there), so where it is
    /// isn't a place to restore it to; its restoration place is the nearest one on a physical display.
    private func park(_ id: CGWindowID, pid: pid_t, adopt: Bool = false) throws -> BankRecord {
        if let record = journal.records.first(where: { $0.id == id }) { return record }
        guard let listed = WindowList.onScreen(id), listed.pid == pid, listed.layer == 0,
              let process = BankProcess(pid),
              let ax = AXWindow.windowsByID(pid: pid)?[id], ax.windowID == id,
              !ax.isFullScreen, !ax.isMinimized, var original = ax.frame else {
            throw failure("This window cannot be parked with a restorable Accessibility identity.")
        }
        let actualAX = original   // where it is now: the AX/window-server offset below comes from this
        var originalCG = listed.bounds
        if adopt, let home = Self.loadReturned()[String(id)], home.process == process,
           SourceBankGeometry.restoration(home.ax, physical: physical) == home.ax {
            // Released last time to a spot still on screen: that is its home, not where macOS put it.
            Log.note("Window bank: \(id) was released to \(NSStringFromRect(home.ax)) last time; that stays its home")
            original = CGRect(origin: home.ax.origin, size: original.size)
            originalCG = CGRect(origin: home.cg.origin, size: listed.bounds.size)
        } else if adopt {
            guard let screen = physical.first else { throw failure("No physical display is available for an adopted window.") }
            let back = SourceBankGeometry.restoration(original, physical: physical)
                ?? CGRect(origin: CGPoint(x: screen.minX + 40, y: screen.minY + 40), size: original.size)
            let shift = CGPoint(x: back.minX - original.minX, y: back.minY - original.minY)
            original = back
            originalCG = listed.bounds.offsetBy(dx: shift.x, dy: shift.y)
        }
        guard let (bankID, slot) = freeSlot(size: listed.bounds.size, excluding: id), let bankBounds = banks[bankID] else {
            throw failure("This window does not fit in the source banks; it remains on its original display.")
        }
        var record = BankRecord(id: id, process: process, originalAX: original, originalCG: originalCG,
                                document: ax.document?.absoluteString, native: slot, displayID: bankID)
        // The journal is durable before the first placement. The host also keeps
        // the actual AX handle, so a reused window number cannot inherit it.
        journal.records.append(record)
        handles[id] = ax
        try save()
        let offset = CGPoint(x: actualAX.minX - listed.bounds.minX, y: actualAX.minY - listed.bounds.minY)
        let asked = CGPoint(x: slot.minX + offset.x, y: slot.minY + offset.y)
        do {
            guard ax.setPosition(asked), let actual = awaitFrame(id, pid: pid, matching: { bankBounds.contains($0) && abs($0.minX - slot.minX) < 3 && abs($0.minY - slot.minY) < 3 }) else {
                throw failure("The app refused its source-bank position.")
            }
            record.native = actual
            journal.records[journal.records.firstIndex(where: { $0.id == id })!] = record
            try save()
            return record
        } catch {
            let placementError = error
            do { _ = try restore(id) }
            catch { finish(reason: "parking rollback"); throw error }
            throw placementError
        }
    }

    /// Where each parked window really is now. The journal's frames are the
    /// last placement; an app or a resize on the canvas may have changed them.
    private func liveNative(_ record: BankRecord) -> CGRect {
        guard let listed = WindowList.onScreen(record.id), listed.pid == record.process.pid else { return record.native }
        return listed.bounds
    }

    /// The first free slot for `size`, its current bank first, never overlapping
    /// another parked window where it actually is.
    private func freeSlot(size: CGSize, excluding id: CGWindowID, prefer: CGDirectDisplayID? = nil) -> (CGDirectDisplayID, CGRect)? {
        let order = prefer.map { p in [p] + displayIDs.filter { $0 != p } } ?? displayIDs
        return order.compactMap { bankID -> (CGDirectDisplayID, CGRect)? in
            guard let bounds = banks[bankID] else { return nil }
            let occupied = journal.records.filter { $0.id != id && $0.displayID == bankID }.map(liveNative)
            return SourceBankGeometry.slot(size: size, display: bounds, occupied: occupied).map { (bankID, $0) }
        }.first
    }

    /// A parked window that grew into a neighbour or left its bank goes to a
    /// free slot at the size it has now. Its restoration record is unchanged.
    private func place(_ id: CGWindowID, room: CGSize? = nil) throws -> BankRecord {
        guard let index = journal.records.firstIndex(where: { $0.id == id }) else { throw failure("This window is not parked.") }
        var record = journal.records[index]
        guard record.process.isLive, let listed = WindowList.onScreen(id), listed.pid == record.process.pid else {
            throw failure("The parked window is not on screen.")
        }
        let ax = handles[id] ?? AXWindow.windowsByID(pid: record.process.pid)?[id]
        guard let ax, ax.windowID == id, !ax.isDestroyed, let frame = ax.frame else { throw failure("A parked window's Accessibility identity is unavailable.") }
        let need = CGSize(width: max(listed.bounds.width, room?.width ?? 0), height: max(listed.bounds.height, room?.height ?? 0))
        guard let (bankID, slot) = freeSlot(size: need, excluding: id, prefer: record.displayID),
              let bankBounds = banks[bankID] else {
            throw failure(SourceBankHost.noRoom)
        }
        let asked = CGPoint(x: slot.minX + frame.minX - listed.bounds.minX, y: slot.minY + frame.minY - listed.bounds.minY)
        guard ax.setPosition(asked), let actual = awaitFrame(id, pid: record.process.pid, matching: {
            bankBounds.contains($0) && abs($0.minX - slot.minX) < 3 && abs($0.minY - slot.minY) < 3
        }) else { throw failure("The app refused its new source-bank position.") }
        record.native = actual
        record.displayID = bankID
        journal.records[index] = record
        try save()
        return record
    }

    static let noRoom = "This window no longer fits in the source banks."

    /// A window's frame whether or not it is on screen (hidden, minimized, another Space). The whole
    /// list: asking for the one window (`optionIncludingWindow`) returns nothing for one on another
    /// Space (measured 2026-11-13, macOS 26.4.1).
    private static func anyFrame(_ id: CGWindowID) -> CGRect? {
        guard let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]],
              let d = list.first(where: { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == id }),
              let b = d[kCGWindowBounds as String] else { return nil }
        return CGRect(dictionaryRepresentation: b as! CFDictionary)
    }

    /// Takes a parked window out of the bank: to `to` (Accessibility's global
    /// top-left) when the canvas is entering it, else to its original place.
    /// Either way at the size it has now: a resize on the canvas is the user's.
    @discardableResult private func restore(_ id: CGWindowID, to: CGPoint? = nil) throws -> CGRect? {
        guard let record = journal.records.first(where: { $0.id == id }) else { return nil }
        guard record.process.isLive, WindowList.exists(id) else { try forget(id); return nil }
        guard let listed = WindowList.onScreen(id), listed.pid == record.process.pid else {
            // A minimized/hidden window can be absent from onScreen. Its exact
            // cached AX identity is still used, never a nearest-frame substitute.
            if WindowList.onScreen().contains(where: { $0.id == id && $0.pid != record.process.pid }) { try forget(id); return nil }
            return try restoreHandle(record, to: to)
        }
        _ = listed
        return try restoreHandle(record, to: to)
    }

    private func restoreHandle(_ record: BankRecord, to: CGPoint? = nil) throws -> CGRect? {
        let ax = handles[record.id] ?? AXWindow.windowsByID(pid: record.process.pid)?[record.id]
        guard let ax, ax.windowID == record.id, !ax.isDestroyed else {
            // Accessibility can't reach it (another Space, its app hidden), but it is already on a
            // physical display, not stranded on a bank: nothing left to restore. Without this, one such
            // stale record failed every later launch at recovery.
            if let frame = Self.anyFrame(record.id), physical.contains(where: { $0.intersects(frame) }) {
                Log.note("Window bank: \(record.id) is already on a physical display at \(NSStringFromRect(frame)); its record is retired")
                try forget(record.id)
                return frame
            }
            throw failure("A parked window's restoration identity is unavailable.")
        }
        if let document = record.document, ax.document?.absoluteString != document { throw failure("A parked document no longer matches its restoration record.") }
        let size = ax.frame?.size ?? record.originalAX.size
        let destination: CGRect
        if let to {
            destination = CGRect(origin: to, size: size)
        } else {
            guard let back = SourceBankGeometry.restoration(CGRect(origin: record.originalAX.origin, size: size), physical: physical) else {
                throw failure("No physical display is available for restoration.")
            }
            destination = back
        }
        // Moving a minimized window is supported by AX; verifying through AX
        // also covers a window not listed on the current Space.
        guard ax.setPosition(destination.origin) else { throw failure("The app refused restoration of its parked window.") }
        let until = Date().addingTimeInterval(1.5)
        var restored: CGRect?
        repeat {
            if let f = ax.frame, abs(f.minX - destination.minX) < 3, abs(f.minY - destination.minY) < 3 { restored = f; break }
            Thread.sleep(forTimeInterval: 0.02)
        } while Date() < until
        // Entering: macOS or the app may clamp the spot (the menu bar, its own limits). The handoff
        // reads back where it really went, as it always has; what matters here is that it left the bank.
        if restored == nil, to != nil, let f = ax.frame, !banks.values.contains(where: { $0.intersects(f) }) { restored = f }
        guard restored != nil else { throw failure("The app has not completed its original-window restoration.") }
        let actual = WindowList.onScreen(record.id)?.bounds ?? destination
        try forget(record.id)
        noteReturned(record, ax: ax.frame ?? destination, cg: actual)
        return actual
    }

    private func awaitFrame(_ id: CGWindowID, pid: pid_t, matching predicate: (CGRect) -> Bool) -> CGRect? {
        let until = Date().addingTimeInterval(1.5)
        repeat {
            if let w = WindowList.onScreen(id), w.pid == pid, predicate(w.bounds) { return w.bounds }
            Thread.sleep(forTimeInterval: 0.02)
        } while Date() < until
        return nil
    }

    private func forget(_ id: CGWindowID) throws {
        journal.records.removeAll { $0.id == id }
        handles[id] = nil
        try save()
    }

    private func finish(reason: String) {
        guard !stopping else { return }
        stopping = true
        restoreAndFinish(reason: reason)
    }

    private func restoreAndFinish(reason: String) {
        var failures: [String] = []
        var restored: [[String: Any]] = []
        for record in journal.records {
            do {
                let frame = try restore(record.id)
                restored.append(["id": record.id, "frame": frame.map { NSStringFromRect($0) } ?? ""])
            } catch { failures.append(error.localizedDescription) }
        }
        send(["event": "restoring", "restored": restored, "remaining": journal.records.count, "reason": reason])
        guard journal.records.isEmpty else {
            send(["event": "restoration_pending", "error": failures.first ?? "Waiting for an app to restore its window."])
            queue.asyncAfter(deadline: .now() + 1) { self.restoreAndFinish(reason: reason) }
            return
        }
        DispatchQueue.main.async {
            self.health?.invalidate(); self.health = nil
            self.disconnectSignal?.cancel(); self.disconnectSignal = nil
            self.displays.removeAll()
            self.waitForRemoval(reason: reason)
        }
    }

    @MainActor private func waitForRemoval(reason: String) {
        // An inactive display may still be online. Do not declare teardown
        // complete while WindowServer is still retiring either stable slot.
        var online = [CGDirectDisplayID](repeating: 0, count: 32), count: UInt32 = 0
        guard CGGetOnlineDisplayList(32, &online, &count) == .success,
              Set(displayIDs).isDisjoint(with: online.prefix(Int(count))) else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { self.waitForRemoval(reason: reason) }
            return
        }
        send(["event": "stopped", "reason": reason, "remaining": 0, "display_removed": true])
        exit(0)
    }

    private func recoverPrevious() throws {
        try FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard FileManager.default.fileExists(atPath: Self.journalURL.path) else { return }
        let previous = try JSONDecoder().decode(BankJournal.self, from: Data(contentsOf: Self.journalURL))
        guard !previous.records.isEmpty else { try FileManager.default.removeItem(at: Self.journalURL); return }
        guard !previous.host.isLive else { throw failure("The preceding window-bank host is still restoring its windows.") }
        // If both processes ended, macOS has removed the old display. Recover
        // only the recorded window number in the same process lifetime.
        physical = CGActivePhysicalFrames(excluding: Set(previous.displayIDs ?? [previous.displayID].compactMap { $0 }))
        journal.records = previous.records
        for record in previous.records { _ = try restore(record.id) }
    }

    private func save() throws {
        if journal.records.isEmpty {
            if FileManager.default.fileExists(atPath: Self.journalURL.path) { try FileManager.default.removeItem(at: Self.journalURL) }
            return
        }
        try JSONEncoder().encode(journal).write(to: Self.journalURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.journalURL.path)
        let file = try FileHandle(forWritingTo: Self.journalURL)
        try file.synchronize(); try file.close()
    }

    private func object<T: Encodable>(_ value: T) throws -> Any { try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) }
    private func failure(_ text: String) -> NSError { NSError(domain: "Sunlight.WindowBank", code: 1, userInfo: [NSLocalizedDescriptionKey: text]) }
    private func send(_ value: [String: Any]) {
        var value = value; value["token"] = token
        guard var data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { return }
        data.append(10)
        try? FileHandle.standardOutput.write(contentsOf: data)
    }
}

private func CGActivePhysicalFrames(excluding sources: Set<CGDirectDisplayID>) -> [CGRect] {
    var ids = [CGDirectDisplayID](repeating: 0, count: 32), count: UInt32 = 0
    guard CGGetActiveDisplayList(32, &ids, &count) == .success else { return [] }
    return ids.prefix(Int(count)).filter { !sources.contains($0) }.map { CGDisplayBounds($0) }
}
