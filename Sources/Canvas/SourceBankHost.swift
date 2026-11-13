import AppKit
import SourceDisplay

/// The unprivileged child owns the display and every AX placement. The private
/// pipe's EOF restores its cached AX windows before releasing the display, even
/// when the canvas process is killed. No Dock code, daemon or root operation.
final class SourceBankHost: @unchecked Sendable {
    static var folder: URL { SIPRedesign.statusURL.deletingLastPathComponent().appendingPathComponent("Window Bank", isDirectory: true) }
    static var journalURL: URL { folder.appendingPathComponent("active.json") }
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

    @MainActor private func createDisplay() {
        let screens = Display.all
        physical = screens.map(\.visible)
        physicalIDs = Set(screens.map(\.id))
        let fps = SIPRedesign.frameRate(displayID: screens.first?.id ?? CGMainDisplayID())
        // Create the bank set before the canvas discovers physical displays.
        // Shared feeds replace the expensive per-window overflow streams.
        for _ in 0..<2 {
            guard let display = autoreleasepool(invoking: { SLSourceDisplay(width: 3072, height: 2048, scale: 2, refreshRate: Double(fps)) }),
                  !physicalIDs.contains(display.displayID), !displayIDs.contains(display.displayID) else {
                send(["event": "failed", "error": "Could not create the temporary window-bank displays."]); exit(1)
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
                let record = try park(id, pid: pid)
                send(["event": "reply", "request": request, "record": try object(record)])
            case "release":
                let id = (command["id"] as? NSNumber)?.uint32Value ?? 0
                let restored = try restore(id)
                send(["event": "reply", "request": request, "restored": restored.map { NSStringFromRect($0) } ?? ""])
            case "stop": finish(reason: "requested")
            default: throw failure("Unknown window-bank operation.")
            }
        } catch { send(["event": "reply", "request": request, "error": error.localizedDescription]) }
    }

    private func park(_ id: CGWindowID, pid: pid_t) throws -> BankRecord {
        if let record = journal.records.first(where: { $0.id == id }) { return record }
        guard let listed = WindowList.onScreen(id), listed.pid == pid, listed.layer == 0,
              let process = BankProcess(pid),
              let ax = AXWindow.windowsByID(pid: pid)?[id], ax.windowID == id,
              !ax.isFullScreen, !ax.isMinimized, let original = ax.frame else {
            throw failure("This window cannot be parked with a restorable Accessibility identity.")
        }
        let placement = displayIDs.compactMap { id -> (CGDirectDisplayID, CGRect)? in
            guard let bounds = banks[id], let slot = SourceBankGeometry.slot(size: listed.bounds.size, display: bounds,
                occupied: journal.records.filter { $0.displayID == id }.map(\.native)) else { return nil }
            return (id, slot)
        }.first
        guard let (bankID, slot) = placement, let bankBounds = banks[bankID] else {
            throw failure("This window does not fit in the source banks; it remains on its original display.")
        }
        var record = BankRecord(id: id, process: process, originalAX: original, originalCG: listed.bounds,
                                document: ax.document?.absoluteString, native: slot, displayID: bankID)
        // The journal is durable before the first placement. The host also keeps
        // the actual AX handle, so a reused window number cannot inherit it.
        journal.records.append(record)
        handles[id] = ax
        try save()
        let offset = CGPoint(x: original.minX - listed.bounds.minX, y: original.minY - listed.bounds.minY)
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

    @discardableResult private func restore(_ id: CGWindowID) throws -> CGRect? {
        guard let record = journal.records.first(where: { $0.id == id }) else { return nil }
        guard record.process.isLive, WindowList.exists(id) else { try forget(id); return nil }
        guard let listed = WindowList.onScreen(id), listed.pid == record.process.pid else {
            // A minimized/hidden window can be absent from onScreen. Its exact
            // cached AX identity is still used, never a nearest-frame substitute.
            if WindowList.onScreen().contains(where: { $0.id == id && $0.pid != record.process.pid }) { try forget(id); return nil }
            return try restoreHandle(record)
        }
        _ = listed
        return try restoreHandle(record)
    }

    private func restoreHandle(_ record: BankRecord) throws -> CGRect? {
        let ax = handles[record.id] ?? AXWindow.windowsByID(pid: record.process.pid)?[record.id]
        guard let ax, ax.windowID == record.id, !ax.isDestroyed else { throw failure("A parked window's restoration identity is unavailable.") }
        if let document = record.document, ax.document?.absoluteString != document { throw failure("A parked document no longer matches its restoration record.") }
        guard let destination = SourceBankGeometry.restoration(record.originalAX, physical: physical) else { throw failure("No physical display is available for restoration.") }
        // Moving a minimized window is supported by AX; verifying through AX
        // also covers a window not listed on the current Space.
        _ = ax.setSize(destination.size)
        guard ax.setPosition(destination.origin) else { throw failure("The app refused restoration of its parked window.") }
        let until = Date().addingTimeInterval(1.5)
        var restored: CGRect?
        repeat {
            if let f = ax.frame, abs(f.minX - destination.minX) < 3, abs(f.minY - destination.minY) < 3,
               abs(f.width - destination.width) < 3, abs(f.height - destination.height) < 3 { restored = f; break }
            Thread.sleep(forTimeInterval: 0.02)
        } while Date() < until
        guard restored != nil else { throw failure("The app has not completed its original-window restoration.") }
        let actual = WindowList.onScreen(record.id)?.bounds ?? destination
        try forget(record.id)
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
        guard Set(displayIDs).isDisjoint(with: SourceBankGeometry.activeDisplayIDs()) else {
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
