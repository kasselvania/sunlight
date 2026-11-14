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
    private var captures: [CGDirectDisplayID: [SourceBankCapture]] = [:]
    private var captureRevision = 0
    private var captureWork: DispatchWorkItem?
    private var banks: [CGDirectDisplayID: (bounds: CGRect, scale: CGFloat)] = [:]
    private var placing = Set<CGWindowID>()
    private var skipped: [CGWindowID: String] = [:]
    /// The raised windows (menus, pop-up lists, popovers) of the banked app in front, by the banked
    /// window each belongs to (`SourceBankGeometry.raisedParent`). Drawn over that window's tile.
    private var raisedByParent: [CGWindowID: [WindowInfo]] = [:]
    /// When each tile's size first differed from its window's, with no resize of the canvas's registered.
    private var sizeMismatchSince: [CGWindowID: CFTimeInterval] = [:]
    /// The size each window's corners were last measured at (`measureCorners`).
    private var cornersMeasured: [CGWindowID: CGSize] = [:]
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
    /// The bank changed a tile's size (it follows its window natively): canvas chrome that draws the
    /// tiles (the minimap) is told once per turn of the run loop, however many changed.
    var onTilesChanged: (() -> Void)?
    private var tilesChangedPending = false

    /// What each canvas needs of the banked windows it shows: the level-of-detail factor of each one
    /// near its viewport (`setDemand`). Before any canvas has said, every window at full detail.
    private var demandBySource: [ObjectIdentifier: [CGWindowID: CGFloat]] = [:]
    /// A rebuild is under way (enumerating shareable content): the feeds it replaces are not checked.
    private var rebuilding = false

    /// A canvas's capture pass: the banked windows near its viewport, each with the factor its tile is
    /// drawn at. The feeds follow within a tick or two (`checkFeeds`).
    func setDemand(_ demand: [CGWindowID: CGFloat], from canvas: AnyObject) {
        demandBySource[ObjectIdentifier(canvas)] = demand
    }

    /// Each bank's feed as the canvases want it now.
    private func feedPlans() -> [CGDirectDisplayID: SourceBankGeometry.FeedPlan] {
        var merged: [CGWindowID: CGFloat]?
        if !demandBySource.isEmpty {
            var m: [CGWindowID: CGFloat] = [:]
            for d in demandBySource.values { m.merge(d) { max($0, $1) } }
            merged = m
        }
        var plans: [CGDirectDisplayID: SourceBankGeometry.FeedPlan] = [:]
        for (id, bank) in banks {
            var windows: [SourceBankGeometry.FeedWindow] = []
            for entry in entries.values where entry.record.displayID == id {
                // A window out of sight keeps the picture it has; one without a picture yet is fed
                // once, at whatever detail the rest want, so it has one when it comes into view.
                let factor = merged.map { $0[entry.record.id] ?? (entry.proxy?.hasBankFrame == false ? 0 : nil) } ?? 1
                guard let factor else { continue }
                windows.append(.init(id: entry.record.id, frame: entry.record.native,
                                     raised: (raisedByParent[entry.record.id] ?? []).map(\.bounds), factor: factor))
            }
            if let plan = SourceBankGeometry.feedPlan(windows: windows, display: bank.bounds, fullScale: bank.scale) {
                plans[id] = plan
            }
        }
        return plans
    }

    private func running(_ display: CGDirectDisplayID) -> [SourceBankGeometry.RunningFeed] {
        (captures[display] ?? []).map { .init(ids: $0.ids, source: $0.source, scale: $0.scale) }
    }

    /// Rebuilds the feeds when what the canvases want has moved past what they capture. Once per
    /// tracker tick; a rebuild already on its way is let finish.
    private func checkFeeds() {
        guard phase == "running", captureWork == nil, !rebuilding else { return }
        let plans = feedPlans()
        let stale = Set(banks.keys).contains { id in
            SourceBankGeometry.feedNeedsRebuild(running: running(id), plan: plans[id])
        }
        if stale { scheduleCapture() }
    }

    /// A tile takes its window's native frame; a size that changed is reported (`onTilesChanged`).
    private func retile(_ p: WindowProxy, at native: CGRect) {
        let before = p.worldRect
        p.placedNatively(at: native)
        guard p.worldRect != before, !tilesChangedPending else { return }
        tilesChangedPending = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.tilesChangedPending = false
                self.onTilesChanged?()
            }
        }
    }

    private let scope: Set<CGWindowID>? = {
        guard let at = CommandLine.arguments.firstIndex(of: "--sip-bank-only") else { return nil }
        guard at + 1 < CommandLine.arguments.count else { return [] }
        return Set(CommandLine.arguments[at + 1].split(separator: ",").compactMap { CGWindowID($0) })
    }()

    var status: [String: Any] {
        let feeds: [[String: Any]] = captures.sorted { $0.key < $1.key }.flatMap { id, feeds in feeds.map { feed in
            ["display_id": id, "windows": feed.ids.sorted(), "backend": feed.backend, "frames_received": feed.received, "frames_presented": feed.presented,
             "pixel_width": feed.pixelSize.width, "pixel_height": feed.pixelSize.height,
             "capture_seconds": feed.elapsed, "capture_rect": NSStringFromRect(feed.source), "running": feed.running,
             "scale": feed.scale] as [String: Any]
        } }
        return ["phase": phase, "host_pid": process?.processIdentifier ?? 0,
         "host_bundle_id": hostIdentity, "display_ids": banks.keys.sorted(), "displays": banks.map { ["id": $0.key, "bounds": NSStringFromRect($0.value.bounds), "scale": $0.value.scale] },
         "display_active": !banks.isEmpty && Set(banks.keys).isSubset(of: SourceBankGeometry.activeDisplayIDs()),
         "capture_streams": captures.values.joined().filter(\.running).count, "feeds": feeds,
         "windows": entries.values.map { ["id": $0.record.id, "pid": $0.record.process.pid,
                    "display_id": $0.record.displayID ?? 0,
                    "original": NSStringFromRect($0.record.originalCG), "native": NSStringFromRect($0.record.native)] },
         "pending": pending.sorted(), "refused": refused.map { ["id": $0.key, "reason": $0.value] },
         "entered": native.sorted(), "placing": placing.sorted(), "scope": scope.map { $0.sorted() } ?? [],
         "skipped": skipped.map { ["id": $0.key, "reason": $0.value] },
         "demand": demandBySource.values.flatMap { $0.map { ["id": $0.key, "factor": $0.value] } },
         "error": error ?? ""]
    }

    /// Where each banked window goes back to on the desktop, at its present size (`TransitionCover`).
    var homes: [CGWindowID: CGRect] {
        Dictionary(uniqueKeysWithValues: entries.values.map { e in
            (e.record.id, CGRect(origin: e.record.originalCG.origin, size: e.record.native.size))
        })
    }

    /// Every banked window has a picture from a feed, and none is being placed: the canvas is ready to
    /// be seen.
    var allPictured: Bool {
        phase == "running" && !entries.isEmpty && placing.isEmpty && entries.values.allSatisfy { $0.proxy?.hasBankFrame == true }
    }

    var bankedIDs: Set<CGWindowID> { Set(entries.keys) }

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
            retile(p, at: entry.record.native)
            p.beginBankCapture()
            cornersMeasured[p.windowID] = nil   // a new tile: measured for it
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
                    retile(p, at: record.native)
                    p.beginBankCapture()
                    self.measureCorners(p.windowID)
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
        cornersMeasured[p.windowID] = nil
        p.endBankCapture()
        if let frame = reply["restored"] as? String, !frame.isEmpty { retile(p, at: NSRectFromString(frame)) }
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
        // Follow every window first, so the overlap test below sees where they all are now.
        for id in ids {
            // Minimized or hidden: the Dock's animation warps the frame on its way; nothing to follow.
            guard let entry = entries[id], entry.proxy?.away == nil, let info = live[id], info.pid == entry.record.process.pid,
                  entry.record.displayID != nil else { continue }
            let recorded = entry.record.native
            guard !info.bounds.isClose(to: recorded) else { continue }
            changedAt[id] = CACurrentMediaTime()
            follow(id, to: info.bounds, from: recorded, dragging: isDragging?(id) == true)
        }
        // The banked app in front: its raised windows, and room for them in the feed.
        var raised: [CGWindowID: [WindowInfo]] = [:]
        if let front = NSWorkspace.shared.frontmostApplication?.processIdentifier,
           entries.values.contains(where: { $0.record.process.pid == front }) {
            let mine = entries.values.filter { $0.record.process.pid == front }
            let candidates = mine.map { (id: $0.record.id, frame: $0.record.native) }
            for w in WindowList.onScreen() where w.pid == front && w.layer > 0 && w.layer < 1000
                && banks.values.contains(where: { $0.bounds.intersects(w.bounds) }) {
                guard let parent = SourceBankGeometry.raisedParent(w.bounds, among: candidates) else { continue }
                raised[parent, default: []].append(w)
            }
        }
        raisedByParent = raised
        checkFeeds()
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
        // A settled new size: its corners again (an app may change its window style with its size).
        for id in ids where now - (changedAt[id] ?? 0) >= SourceBank.settle {
            if let size = entries[id]?.record.native.size, cornersMeasured[id] != size { measureCorners(id) }
            // The tile takes the window's real size once it has settled and no resize of the canvas's
            // is pending: a drag whose release never reached the canvas left the tile at the size the
            // pointer asked for (2826 pt over a window the banks held to 2472, 2026-11-13), stretching
            // the picture. Top-left anchored, as the listing's own size updates are.
            // Only a mismatch that has lasted with no resize of the canvas's registered: at a drag's start
            // the tile has moved on before the first resize registers (`sizeHeld`), and snapping then
            // fought the pointer.
            guard let entry = entries[id], let p = entry.proxy, entry.proxy?.away == nil else { continue }
            let differs = abs(p.worldRect.width - entry.record.native.width) > 1 || abs(p.worldRect.height - entry.record.native.height) > 1
            if !differs || p.sizeHeld { sizeMismatchSince[id] = nil; continue }
            let since = sizeMismatchSince[id] ?? now
            sizeMismatchSince[id] = since
            if now - since >= 0.6 {
                sizeMismatchSince[id] = nil
                Log.note("Window bank: \(p.appName) — \(p.title) tile \(Int(p.worldRect.width))×\(Int(p.worldRect.height)) takes the window's \(Int(entry.record.native.width))×\(Int(entry.record.native.height))")
                retile(p, at: entry.record.native)
            }
        }
    }

    /// The window's corner radius from one ScreenCaptureKit screenshot's alpha, for its tile's clip and
    /// shadow. Once per size; a window whose capture fails keeps the canvas's standard radius.
    /// ScreenCaptureKit, not SkyLight's capture: macOS asked the owner to allow "bypassing the system
    /// private window picker" (a legacy-capture consent prompt) on the launches that measured through
    /// SkyLight (2026-11-13).
    private func measureCorners(_ id: CGWindowID) {
        guard let entry = entries[id], let p = entry.proxy, let window = p.window else { return }
        let size = entry.record.native.size
        cornersMeasured[id] = size
        OneShotCapture.capture(window, seam: true) { [weak self, weak p] image in
            guard let self, let p, let image, self.entries[id]?.proxy === p,
                  let alpha = SourceBankGeometry.alpha(of: image),
                  let radius = SourceBankGeometry.cornerRadius(alpha: alpha, width: image.width, height: image.height,
                                                               windowWidth: size.width) else { return }
            Log.note("Window bank: \(p.appName) — \(p.title) corners \(String(format: "%.1f", radius)) pt")
            p.setMeasuredCornerRadius(min(radius, min(size.width, size.height) / 2))
        }
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
        if !p.sizeHeld { retile(p, at: frame) }
    }

    /// How long a window's frame must hold still before the bank moves it to a new slot.
    static let settle: CFTimeInterval = 0.3

    /// Before a resize of the canvas's own: the window goes where `size` fits on a bank, if it doesn't
    /// fit where it is. Returns the size to ask the app for: `size`, held to the largest the bank can
    /// take. The resize itself is the caller's; the tracker follows it.
    func makeRoom(_ id: CGWindowID, for requested: CGSize) async -> CGSize {
        let largest = SourceBankGeometry.largestSlot(banks: banks.values.map(\.bounds))
        let size = largest.width > 0 ? CGSize(width: min(requested.width, largest.width), height: min(requested.height, largest.height)) : requested
        if size != requested {
            Log.note("Window bank: \(id) asked for \(Int(requested.width))×\(Int(requested.height)); the banks take at most \(Int(largest.width))×\(Int(largest.height))")
        }
        guard let entry = entries[id], !placing.contains(id), let displayID = entry.record.displayID,
              let bank = banks[displayID]?.bounds else { return size }
        let wanted = CGRect(origin: entry.record.native.origin, size: size)
        let others = entries.values.filter { $0.record.id != id && $0.record.displayID == displayID }.map(\.record.native)
        if bank.contains(wanted), !others.contains(where: { $0.intersects(wanted) }) { return size }
        placing.insert(id)
        let reply = await ask("place", values: ["ids": [id], "width": Double(size.width), "height": Double(size.height)])
        placing.remove(id)
        // The tile already has the size asked for; only the record moves (`placedNatively` would put
        // the tile back to the window's present size).
        await applyPlacements(reply, updatingTiles: false)
        return size
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
                // No free slot: a window still on its bank stays where it is, overlapping a neighbour,
                // rather than leaving the bank (a resize took Zen out of it, 2026-11-13). Only one
                // that has left its bank altogether goes back to its original place.
                let onBank = self.banks.values.contains { $0.bounds.contains(entry.record.native) }
                if text == SourceBankHost.noRoom, !onBank, let p = entry.proxy {
                    self.refused[id] = text
                    _ = await self.release(p)
                    self.native.remove(id)
                }
                continue
            }
            guard let object = item["record"], let data = try? JSONSerialization.data(withJSONObject: object),
                  let record = try? JSONDecoder().decode(BankRecord.self, from: data) else { continue }
            self.entries[id] = Entry(proxy: entry.proxy, record: record)
            if updatingTiles, let tile = entry.proxy { retile(tile, at: record.native) }
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
                if let frame = item["frame"] as? String, !frame.isEmpty, let tile = entry.proxy { retile(tile, at: NSRectFromString(frame)) }
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
                if let tile = entry.proxy { retile(tile, at: w.bounds) }
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
        rebuilding = true
        Task { [weak self] in
            guard let self else { return }
            defer { if self.captureRevision == revision { self.rebuilding = false } }
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
                guard self.captureRevision == revision, self.phase == "running" else { return }
                // Planned now, after the wait: only the windows the canvases show, at the detail they're drawn.
                let plans = self.feedPlans()
                var fresh: [CGDirectDisplayID: [SourceBankCapture]] = [:]
                var started: [SourceBankCapture] = []
                let fps = SIPRedesign.frameRate(displayID: CGMainDisplayID())
                for id in self.banks.keys {
                    // Unchanged plan, running streams: they keep running (a restart is a visible stall).
                    if let running = self.captures[id], running.allSatisfy(\.running),
                       !SourceBankGeometry.feedNeedsRebuild(running: self.running(id), plan: plans[id]) {
                        fresh[id] = running
                        continue
                    }
                    guard let plan = plans[id] else { continue }
                    guard let display = content.displays.first(where: { $0.displayID == id }) else { self.captureFailed("A source display is unavailable."); return }
                    let records = self.entries.values.map(\.record).filter { plan.needs[$0.id] != nil }
                    let windows = records.compactMap { record in content.windows.first { $0.windowID == record.id && $0.owningApplication?.processID == record.process.pid } }
                    guard windows.count == records.count else { self.scheduleCapture(); return }
                    var feeds: [SourceBankCapture] = []
                    var spare = (self.captures[id] ?? []).filter(\.running)
                    for group in plan.groups {
                        // A stream reading exactly this rectangle at this density carries on, now
                        // feeding this group's windows.
                        if let at = spare.firstIndex(where: { $0.source == group.source && abs($0.scale - plan.scale) < 0.001 }) {
                            let kept = spare.remove(at: at)
                            kept.ids = group.ids
                            feeds.append(kept)
                            continue
                        }
                        let feed = SourceBankCapture(display: display, source: group.source, scale: plan.scale, fps: fps)
                        feed.ids = group.ids
                        feed.onFrame = { [weak self, weak feed] buffer, region in
                            guard let self, let feed, self.captures[id]?.contains(where: { $0 === feed }) == true else { return }
                            for wid in feed.ids {
                                guard let entry = self.entries[wid], entry.record.displayID == id, region.contains(entry.record.native) else { continue }
                                let native = entry.record.native
                                let tile = entry.proxy?.worldRect.size ?? native.size
                                let sx = tile.width / max(1, native.width), sy = tile.height / max(1, native.height)
                                let raised = (self.raisedByParent[wid] ?? []).filter { region.contains($0.bounds) }.map { w in
                                    let o = SourceBankGeometry.overlayFrame(raised: w.bounds, parent: native, tileHeight: native.height)
                                    return (id: w.id, crop: SourceBankGeometry.crop(window: w.bounds, source: region),
                                            frame: CGRect(x: o.minX * sx, y: o.minY * sy, width: o.width * sx, height: o.height * sy))
                                }
                                entry.proxy?.applyBankFrame(buffer, crop: SourceBankGeometry.crop(window: native, source: region), raised: raised)
                            }
                        }
                        feed.onError = { [weak self, weak feed] text in
                            guard let self, let feed, self.captures[id]?.contains(where: { $0 === feed }) == true else { return }
                            self.captureFailed("Window-bank capture: \(text)")
                        }
                        feeds.append(feed)
                        started.append(feed)
                    }
                    fresh[id] = feeds
                }
                let kept = Set(fresh.values.joined().map(ObjectIdentifier.init))
                for feed in self.captures.values.joined() where !kept.contains(ObjectIdentifier(feed)) { feed.stop() }
                self.captures = fresh
                for feed in started { feed.start() }
                if !started.isEmpty {
                    Log.note("Window bank: feeds " + fresh.sorted { $0.key < $1.key }.map { id, feeds in
                        "\(id): " + feeds.map { "\($0.ids.count)w \(Int($0.source.width))×\(Int($0.source.height)) pt" }.joined(separator: " + ") + " at \(feeds.first?.scale ?? 0)×"
                    }.joined(separator: "; "))
                }
                self.onChange?()
            } catch {
                guard self.captureRevision == revision, self.phase == "running" else { return }
                self.captureFailed("Window-bank enumeration: \(error.localizedDescription)")
            }
        }
    }

    private func stopCaptures() { for feed in captures.values.joined() { feed.stop() }; captures.removeAll() }

    private func fail(_ text: String) { error = text; Log.note("Window bank: \(text)"); onFailure?(text) }
    private func captureFailed(_ text: String) {
        fail(text)
        Task { _ = await stop() }
    }
    private func finishReadiness() { let waiting = ready; ready.removeAll(); for waiter in waiting { waiter.resume() } }
}
