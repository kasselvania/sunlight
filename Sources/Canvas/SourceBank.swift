import AppKit
import ScreenCaptureKit

/// The canvas-side owner of source placement and the shared display feed.
/// Native source rectangles never become canvas layout coordinates.
@MainActor
final class SourceBank {
    private struct Entry { weak var proxy: WindowProxy?; let record: BankRecord }
    private var process: Process?
    private var input: FileHandle?
    private var token = ""
    private var recovering = false
    private var hostIdentity = ""
    private var sequence = 0
    private var requests: [Int: CheckedContinuation<[String: Any], Never>] = [:]
    private var stopping: [CheckedContinuation<Bool, Never>] = []
    private var ready: [CheckedContinuation<Void, Never>] = []
    private var entries: [CGWindowID: Entry] = [:]
    private var pending = Set<CGWindowID>()
    private var native = Set<CGWindowID>()
    private var releasing = Set<CGWindowID>()
    private var refused: [CGWindowID: String] = [:]
    private var captures: [CGDirectDisplayID: SourceBankCapture] = [:]
    private var captureRevision = 0
    private var captureWork: DispatchWorkItem?
    private var banks: [CGDirectDisplayID: (bounds: CGRect, scale: CGFloat)] = [:]
    private var placing = Set<CGWindowID>()
    private var skipped: [CGWindowID: String] = [:]
    /// When each banked window last moved or resized natively: of two that overlap, the one that
    /// changed last is the one that ran into the other, and it alone is re-slotted.
    private var changedAt: [CGWindowID: CFTimeInterval] = [:]
    private var tracker: Timer?
    private(set) var phase = "idle"
    private(set) var error: String?
    var onChange: (() -> Void)?
    var onFailure: ((String) -> Void)?
    /// Whether the user is dragging this window through its tile right now (a
    /// captured press): its own title bar moving it moves its tile, as it would
    /// a real window on the desktop, and it isn't re-slotted under the pointer.
    var isDragging: ((CGWindowID) -> Bool)?
    /// A dragged window moved natively by this much: its tile follows.
    var onDragged: ((WindowProxy, CGVector) -> Void)?

    private let scope: Set<CGWindowID>? = {
        guard let at = CommandLine.arguments.firstIndex(of: "--sip-bank-only") else { return nil }
        guard at + 1 < CommandLine.arguments.count else { return [] }
        return Set(CommandLine.arguments[at + 1].split(separator: ",").compactMap { CGWindowID($0) })
    }()

    var status: [String: Any] {
        let feeds: [[String: Any]] = captures.sorted { $0.key < $1.key }.map { id, feed in
            ["display_id": id, "backend": feed.backend, "frames_received": feed.received, "frames_presented": feed.presented,
             "pixel_width": feed.pixelSize.width, "pixel_height": feed.pixelSize.height,
             "capture_seconds": feed.elapsed, "capture_rect": NSStringFromRect(feed.source), "running": feed.running]
        }
        return ["phase": phase, "host_pid": process?.processIdentifier ?? 0,
         "host_bundle_id": hostIdentity, "display_ids": banks.keys.sorted(), "displays": banks.map { ["id": $0.key, "bounds": NSStringFromRect($0.value.bounds), "scale": $0.value.scale] },
         "display_active": !banks.isEmpty && Set(banks.keys).isSubset(of: SourceBankGeometry.activeDisplayIDs()),
         "capture_streams": captures.values.filter(\.running).count, "feeds": feeds,
         "windows": entries.values.map { ["id": $0.record.id, "pid": $0.record.process.pid,
                    "display_id": $0.record.displayID ?? 0,
                    "original": NSStringFromRect($0.record.originalCG), "native": NSStringFromRect($0.record.native)] },
         "pending": pending.sorted(), "refused": refused.map { ["id": $0.key, "reason": $0.value] },
         "entered": native.sorted(), "placing": placing.sorted(), "scope": scope.map { $0.sorted() } ?? [],
         "skipped": skipped.map { ["id": $0.key, "reason": $0.value] },
         "error": error ?? ""]
    }

    func protects(_ id: CGWindowID) -> Bool { entries[id] != nil || pending.contains(id) }
    func contains(_ id: CGWindowID) -> Bool { entries[id] != nil }

    func startBeforeDiscovery() async {
        await withCheckedContinuation { continuation in
            ready.append(continuation)
            start()
        }
    }

    func observe(_ list: [WindowInfo]) {
        let listed = Set(list.map(\.id))
        for (id, entry) in entries where !listed.contains(id) && !WindowList.exists(id) && !releasing.contains(id) {
            releasing.insert(id)
            Task {
                _ = await ask("release", values: ["id": id])
                entries[id] = nil; releasing.remove(id)
                entry.proxy?.endBankCapture()
                scheduleCapture(); onChange?()
            }
        }
    }

    func start(recoverOnly: Bool = false) {
        guard process == nil else { return }
        recovering = recoverOnly
        token = UUID().uuidString
        phase = "starting"; error = nil; refused.removeAll(); native.removeAll()
        let child = Process(), stdin = Pipe(), stdout = Pipe()
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/SunlightBankHost")
        child.executableURL = FileManager.default.isExecutableFile(atPath: helper.path)
            ? helper : URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        child.arguments = ["--sip-redesign", "--sip-bank-host", token]
        if recoverOnly { child.arguments?.append("--sip-bank-recover") }
        child.standardInput = stdin; child.standardOutput = stdout; child.standardError = FileHandle.standardError
        do { try child.run() }
        catch { phase = "failed"; fail(error.localizedDescription); finishReadiness(); finishStopping(); return }
        process = child; input = stdin.fileHandleForWriting
        let session = token
        Task.detached { [weak self] in
            var buffer = Data()
            let file = stdout.fileHandleForReading
            while true {
                let data = file.availableData
                if data.isEmpty { break }
                buffer.append(data)
                while let end = buffer.firstIndex(of: 10) {
                    let line = buffer[..<end]; buffer.removeSubrange(...end)
                    if let value = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] {
                        await self?.receive(value, session: session)
                    }
                }
            }
            await self?.ended(session: session)
        }
    }

    func consider(_ proxies: [WindowProxy]) {
        guard phase == "running" else { return }
        // A banked window whose tile was made again (another display's canvas, a listing that dropped
        // and re-added it) is fed through its current tile, not the one it was parked with.
        for p in proxies where p.kind == .window {
            guard let entry = entries[p.windowID], entry.proxy !== p, p.pid == entry.record.process.pid else { continue }
            entries[p.windowID] = Entry(proxy: p, record: entry.record)
            p.owner = .canvas
            p.placedNatively(at: entry.record.native)
            p.beginBankCapture()
        }
        for p in proxies where p.kind == .window && !protects(p.windowID) && (scope?.contains(p.windowID) ?? true) {
            // Why a window stays out of the bank, for the status file.
            let reason = p.attachedTo != nil ? "attached" : p.away != nil ? "away" : p.leaving ? "leaving"
                : native.contains(p.windowID) ? "entered" : refused[p.windowID] != nil ? "refused" : nil
            if let reason { skipped[p.windowID] = reason; continue }
            guard let real = WindowList.onScreen(p.windowID) else { skipped[p.windowID] = "not on screen"; continue }
            skipped[p.windowID] = nil
            // Already on a source display but not banked: macOS puts a window back on the display it
            // was last on when that display returns, and the banks keep fixed identities across
            // launches. Adopted, with a restoration place on a physical display, rather than left there
            // untracked (streamed on its own, its crop and input unowned, lost when the bank closes).
            let adopt = banks.values.contains(where: { $0.bounds.intersects(real.bounds) })
            if adopt { Log.note("Window bank: \(p.appName) — \(p.title) is already on a source display at \(NSStringFromRect(real.bounds)); adopting it") }
            pending.insert(p.windowID)
            let id = p.windowID
            Task { [weak self, weak p] in
                guard let self else { return }
                guard let p else { self.pending.remove(id); return }
                let reply = await self.ask("park", values: ["id": p.windowID, "pid": p.pid, "adopt": adopt])
                if self.phase != "stopping" { self.pending.remove(p.windowID) }
                if let text = reply["error"] as? String {
                    self.refused[p.windowID] = text
                    self.fail("\(p.appName): \(text)")
                } else if self.phase == "running", let object = reply["record"], let data = try? JSONSerialization.data(withJSONObject: object),
                          let record = try? JSONDecoder().decode(BankRecord.self, from: data) {
                    self.entries[p.windowID] = Entry(proxy: p, record: record)
                    p.owner = .canvas
                    p.placedNatively(at: record.native)
                    p.beginBankCapture()
                    self.scheduleCapture()
                }
                self.onChange?()
            }
        }
    }

    /// Release through the host before existing native-handoff code places the
    /// original on a physical display. `to` (Accessibility's global top-left) is
    /// where the handoff will put it: the host takes it straight there from its
    /// slot, at its current size. Without it, the window goes back to where it
    /// was before parking. The record retires only once the move is observed.
    func release(_ p: WindowProxy, to: CGPoint? = nil) async -> Bool {
        guard contains(p.windowID) else { return true }
        guard !releasing.contains(p.windowID) else { return false }
        releasing.insert(p.windowID)
        defer { releasing.remove(p.windowID) }
        native.insert(p.windowID)
        var values: [String: Any] = ["id": p.windowID]
        if let to { values["x"] = Double(to.x); values["y"] = Double(to.y) }
        let reply = await ask("release", values: values)
        if let text = reply["error"] as? String { native.remove(p.windowID); fail(text); return false }
        entries[p.windowID] = nil
        changedAt[p.windowID] = nil
        p.endBankCapture()
        if let frame = reply["restored"] as? String, !frame.isEmpty { p.placedNatively(at: NSRectFromString(frame)) }
        scheduleCapture(); onChange?()
        return true
    }

    func returnToCanvas() { native.removeAll() }

    // MARK: Geometry ownership

    /// The bank's record of each window follows the real window, many times a
    /// second: the crop is cut from it, so the picture shows what input reaches.
    private func startTracking() {
        tracker?.invalidate()
        let t = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.track() }
        }
        RunLoop.main.add(t, forMode: .common)   // also while a drag or resize tracks the mouse
        tracker = t
    }

    private func stopTracking() { tracker?.invalidate(); tracker = nil }

    private func track() {
        guard phase == "running", !entries.isEmpty else { return }
        let ids = entries.keys.filter { !placing.contains($0) && !releasing.contains($0) && !native.contains($0) }
        let live = WindowList.onScreen(Array(ids))
        var refeed = false
        // Follow every window first, so the overlap test below sees where they all are now.
        for id in ids {
            // Minimized or hidden: the Dock's animation warps the frame on its way; nothing to follow.
            guard let entry = entries[id], entry.proxy?.away == nil, let info = live[id], info.pid == entry.record.process.pid,
                  let displayID = entry.record.displayID else { continue }
            let recorded = entry.record.native
            guard !info.bounds.isClose(to: recorded) else { continue }
            changedAt[id] = CACurrentMediaTime()
            follow(id, to: info.bounds, from: recorded, dragging: isDragging?(id) == true)
            if !(captures[displayID]?.source.contains(info.bounds) ?? false) { refeed = true }
        }
        if refeed { scheduleCapture() }
        guard placing.isEmpty else { return }
        var reslot: [CGWindowID] = []
        let now = CACurrentMediaTime()
        for id in ids {
            // Settled first: a window still growing under an edge drag, or still landing after a drag
            // or a restore from the Dock, would be moved again and again.
            guard let entry = entries[id], entry.proxy?.away == nil, live[id] != nil, let displayID = entry.record.displayID,
                  let bank = banks[displayID]?.bounds, isDragging?(id) != true,
                  now - (changedAt[id] ?? 0) >= SourceBank.settle else { continue }
            let frame = entry.record.native
            let others = entries.values.filter { $0.record.id != id && $0.record.displayID == displayID }
            guard case .reslot = SourceBankGeometry.drift(live: frame, recorded: frame, bank: bank,
                                                          neighbours: others.map(\.record.native)) else { continue }
            // Off its bank: it goes back. Overlapping: only if it changed after every window it overlaps.
            let mine = changedAt[id] ?? 0
            let offBank = !bank.contains(frame)
            if offBank || !others.contains(where: { $0.record.native.intersects(frame) && (changedAt[$0.record.id] ?? 0) > mine }) {
                reslot.append(id)
            }
        }
        // Not under the pointer: a window dragged off its bank goes back once it's let go.
        if !reslot.isEmpty { self.reslot(reslot) }
    }

    /// The record takes the window's live frame, so its crop is cut from where
    /// the window really is. A drag through the tile carries the tile along;
    /// otherwise the tile keeps its place and takes the window's new size.
    private func follow(_ id: CGWindowID, to frame: CGRect, from recorded: CGRect, dragging: Bool) {
        guard let entry = entries[id] else { return }
        var record = entry.record
        record.native = frame
        entries[id] = Entry(proxy: entry.proxy, record: record)
        guard let p = entry.proxy else { return }
        if dragging, frame.origin != recorded.origin {
            onDragged?(p, CGVector(dx: frame.minX - recorded.minX, dy: frame.minY - recorded.minY))
        }
        // A resize of the canvas's own is still settling: the canvas has the size.
        if !p.sizeHeld { p.placedNatively(at: frame) }
    }

    /// How long a window's frame must hold still before the bank moves it to a new slot.
    static let settle: CFTimeInterval = 0.3

    /// Before a resize of the canvas's own: the window goes where `size` fits on a bank, if it doesn't
    /// fit where it is. The resize itself is the caller's; the tracker follows it.
    func makeRoom(_ id: CGWindowID, for size: CGSize) async {
        guard let entry = entries[id], !placing.contains(id), let displayID = entry.record.displayID,
              let bank = banks[displayID]?.bounds else { return }
        let wanted = CGRect(origin: entry.record.native.origin, size: size)
        let others = entries.values.filter { $0.record.id != id && $0.record.displayID == displayID }.map(\.record.native)
        if bank.contains(wanted), !others.contains(where: { $0.intersects(wanted) }) { return }
        placing.insert(id)
        let reply = await ask("place", values: ["ids": [id], "width": Double(size.width), "height": Double(size.height)])
        placing.remove(id)
        // The tile already has the size asked for; only the record moves (`placedNatively` would put
        // the tile back to the window's present size).
        await applyPlacements(reply, updatingTiles: false)
    }

    /// Moves windows that outgrew their slots, or left their bank, to free slots: all of them in one
    /// host request (a Tidy or a layout resizes many windows at once). A window that fits nowhere
    /// leaves the bank for its original place, as one too large to park does.
    private func reslot(_ ids: [CGWindowID]) {
        placing.formUnion(ids)
        Task { [weak self] in
            guard let self else { return }
            let reply = await self.ask("place", values: ["ids": ids])
            self.placing.subtract(ids)
            await self.applyPlacements(reply, updatingTiles: true)
        }
    }

    private func applyPlacements(_ reply: [String: Any], updatingTiles: Bool) async {
        guard phase == "running" else { return }
        if let text = reply["error"] as? String { Log.note("Window bank: re-slot: \(text)"); return }
        var moved = false
        for item in reply["results"] as? [[String: Any]] ?? [] {
            guard let id = (item["id"] as? NSNumber)?.uint32Value, let entry = self.entries[id] else { continue }
            if let text = item["error"] as? String {
                Log.note("Window bank: re-slot \(id): \(text)")
                if text == SourceBankHost.noRoom, let p = entry.proxy {
                    self.refused[id] = text
                    _ = await self.release(p)
                    self.native.remove(id)
                }
                continue
            }
            guard let object = item["record"], let data = try? JSONSerialization.data(withJSONObject: object),
                  let record = try? JSONDecoder().decode(BankRecord.self, from: data) else { continue }
            self.entries[id] = Entry(proxy: entry.proxy, record: record)
            if updatingTiles { entry.proxy?.placedNatively(at: record.native) }
            Log.note("Window bank: \(id) re-slotted to \(NSStringFromRect(record.native))")
            moved = true
        }
        if moved { scheduleCapture() }
    }

    func stop() async -> Bool {
        stopTracking()
        captureWork?.cancel(); captureWork = nil
        captureRevision += 1; stopCaptures()
        guard process != nil else {
            return entries.isEmpty && !FileManager.default.fileExists(atPath: SourceBankHost.journalURL.path)
        }
        return await withCheckedContinuation { continuation in
            stopping.append(continuation)
            if phase != "stopping" {
                phase = "stopping"
                sequence += 1
                write(["operation": "stop", "request": sequence])
                try? input?.close(); input = nil
            }
        }
    }

    private func ask(_ operation: String, values: [String: Any]) async -> [String: Any] {
        guard process != nil, input != nil else { return ["error": "The source-bank host is unavailable."] }
        sequence += 1
        let request = sequence
        return await withCheckedContinuation { continuation in
            requests[request] = continuation
            var command = values; command["request"] = request; command["operation"] = operation
            write(command)
        }
    }

    private func write(_ value: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: value) else { return }
        data.append(10)
        do { try input?.write(contentsOf: data) }
        catch { fail("The source-bank pipe closed; restoration is required.") }
    }

    private func receive(_ value: [String: Any], session: String) {
        guard session == token, value["token"] as? String == session, let event = value["event"] as? String else { return }
        switch event {
        case "ready":
            guard phase == "starting", let displays = value["displays"] as? [[String: Any]], !displays.isEmpty else { return }
            hostIdentity = value["host_bundle_id"] as? String ?? ""
            banks.removeAll()
            for display in displays {
                guard let id = (display["id"] as? NSNumber)?.uint32Value, let rect = display["bounds"] as? String,
                      let scale = (display["scale"] as? NSNumber)?.doubleValue else { continue }
                banks[id] = (NSRectFromString(rect), CGFloat(scale))
            }
            SIPRedesign.sourceDisplayIDs = Set(banks.keys)
            retireRestoredEntries()
            phase = "running"
            startTracking()
            finishReadiness(); onChange?()
        case "reply":
            if let id = value["request"] as? Int { requests.removeValue(forKey: id)?.resume(returning: value) }
        case "restoring":
            phase = "stopping"
            for item in value["restored"] as? [[String: Any]] ?? [] {
                guard let id = (item["id"] as? NSNumber)?.uint32Value, let entry = entries.removeValue(forKey: id) else { continue }
                entry.proxy?.endBankCapture()
                if let frame = item["frame"] as? String, !frame.isEmpty { entry.proxy?.placedNatively(at: NSRectFromString(frame)) }
            }
            onChange?()
        case "restoration_pending": phase = "stopping"; fail(value["error"] as? String ?? "Waiting for original windows to restore.")
        case "stopped":
            phase = "stopped"; captureRevision += 1; stopCaptures()
            retireRestoredEntries(); pending.removeAll(); SIPRedesign.sourceDisplayIDs.removeAll()
            onChange?()
        case "failed": phase = "failed"; fail(value["error"] as? String ?? "Source-bank startup failed."); finishReadiness()
        default: break
        }
    }

    private func ended(session: String) {
        guard session == token else { return }
        stopTracking()
        process = nil; input = nil
        finishReadiness()
        for reply in requests.values { reply.resume(returning: ["error": "The source-bank host exited."]) }
        requests.removeAll()
        if phase != "stopped" && phase != "failed" {
            captureRevision += 1; stopCaptures()
            if !recovering {
                phase = "recovery needed"
                fail("The source-bank host exited. Restoring the originals from its journal.")
                start(recoverOnly: true)
                return
            }
            phase = "failed"
            fail("Window-bank recovery exited before confirming restoration. Its journal is retained.")
        }
        finishStopping(); onChange?()
    }

    private func retireRestoredEntries() {
        for entry in entries.values {
            entry.proxy?.endBankCapture()
            if entry.record.process.isLive, let w = WindowList.onScreen(entry.record.id), w.pid == entry.record.process.pid {
                entry.proxy?.placedNatively(at: w.bounds)
            }
        }
        entries.removeAll()
    }

    private func finishStopping() {
        for waiter in stopping { waiter.resume(returning: phase == "stopped") }
        stopping.removeAll()
    }

    private func scheduleCapture() {
        captureWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.rebuildCapture() }
        captureWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    // SIP PERFORMANCE: per-bank ROI and feed replacement entry point.
    // Keep crop geometry immutable per feed; see docs/sip-redesign-performance.md.
    private func rebuildCapture() {
        captureWork = nil
        captureRevision += 1
        let revision = captureRevision
        guard phase == "running", !entries.isEmpty else { stopCaptures(); return }
        Task { [weak self] in
            guard let self else { return }
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
                guard self.captureRevision == revision, self.phase == "running" else { return }
                var fresh: [CGDirectDisplayID: SourceBankCapture] = [:]
                for (id, bank) in self.banks {
                    let records = self.entries.values.map(\.record).filter { $0.displayID == id }
                    guard !records.isEmpty else { continue }
                    guard let display = content.displays.first(where: { $0.displayID == id }) else { self.captureFailed("A source display is unavailable."); return }
                    let windows = records.compactMap { record in content.windows.first { $0.windowID == record.id && $0.owningApplication?.processID == record.process.pid } }
                    guard windows.count == records.count else { self.scheduleCapture(); return }
                    // Headroom around the windows, so their moves and resizes stay inside this feed.
                    let source = SourceBankGeometry.feedSource(windows: records.map(\.native), display: display.frame)
                    guard !source.isEmpty else { continue }
                    let feed = SourceBankCapture(display: display, source: source, scale: bank.scale,
                                                 fps: SIPRedesign.frameRate(displayID: CGMainDisplayID()))
                    feed.onFrame = { [weak self, weak feed] buffer, region in
                        guard let self, self.captures[id] === feed else { return }
                        for entry in self.entries.values where entry.record.displayID == id && region.contains(entry.record.native) {
                            entry.proxy?.applyBankFrame(buffer, crop: SourceBankGeometry.crop(window: entry.record.native, source: region))
                        }
                    }
                    feed.onError = { [weak self, weak feed] text in
                        guard let self, self.captures[id] === feed else { return }
                        self.captureFailed("Window-bank capture: \(text)")
                    }
                    fresh[id] = feed
                }
                self.stopCaptures(); self.captures = fresh
                for feed in fresh.values { feed.start() }
                self.onChange?()
            } catch {
                guard self.captureRevision == revision, self.phase == "running" else { return }
                self.captureFailed("Window-bank enumeration: \(error.localizedDescription)")
            }
        }
    }

    private func stopCaptures() { for feed in captures.values { feed.stop() }; captures.removeAll() }

    private func fail(_ text: String) { error = text; Log.note("Window bank: \(text)"); onFailure?(text) }
    private func captureFailed(_ text: String) {
        fail(text)
        Task { _ = await stop() }
    }
    private func finishReadiness() { let waiting = ready; ready.removeAll(); for waiter in waiting { waiter.resume() } }
}
