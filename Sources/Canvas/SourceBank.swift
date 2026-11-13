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
    private var sequence = 0
    private var requests: [Int: CheckedContinuation<[String: Any], Never>] = [:]
    private var stopping: [CheckedContinuation<Bool, Never>] = []
    private var ready: [CheckedContinuation<Void, Never>] = []
    private var entries: [CGWindowID: Entry] = [:]
    private var pending = Set<CGWindowID>()
    private var native = Set<CGWindowID>()
    private var releasing = Set<CGWindowID>()
    private var refused: [CGWindowID: String] = [:]
    private var capture: SourceBankCapture?
    private var captureRevision = 0
    private var captureWork: DispatchWorkItem?
    private var displayID: CGDirectDisplayID = 0
    private var bounds = CGRect.zero
    private var scale: CGFloat = 2
    private(set) var phase = "idle"
    private(set) var error: String?
    var onChange: (() -> Void)?
    var onFailure: ((String) -> Void)?

    private let scope: Set<CGWindowID>? = {
        guard let at = CommandLine.arguments.firstIndex(of: "--sip-bank-only") else { return nil }
        guard at + 1 < CommandLine.arguments.count else { return [] }
        return Set(CommandLine.arguments[at + 1].split(separator: ",").compactMap { CGWindowID($0) })
    }()

    var status: [String: Any] {
        ["phase": phase, "host_pid": process?.processIdentifier ?? 0,
         "display_id": displayID, "display_active": SourceBankGeometry.activeDisplayIDs().contains(displayID),
         "bounds": NSStringFromRect(bounds), "scale": scale,
         "capture_streams": capture?.running == true ? 1 : 0, "frames_received": capture?.received ?? 0,
         "frames_presented": capture?.presented ?? 0, "capture_seconds": capture?.elapsed ?? 0,
         "capture_rect": capture.map { NSStringFromRect($0.source) } ?? "",
         "windows": entries.values.map { ["id": $0.record.id, "pid": $0.record.process.pid,
                    "original": NSStringFromRect($0.record.originalCG), "native": NSStringFromRect($0.record.native)] },
         "pending": pending.sorted(), "refused": refused.map { ["id": $0.key, "reason": $0.value] },
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
        child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
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
        for p in proxies where p.kind == .window && p.attachedTo == nil && p.away == nil && !p.leaving
            && !protects(p.windowID) && !native.contains(p.windowID) && refused[p.windowID] == nil
            && (scope?.contains(p.windowID) ?? true) {
            guard let real = WindowList.onScreen(p.windowID), !bounds.intersects(real.bounds) else { continue }
            pending.insert(p.windowID)
            let id = p.windowID
            Task { [weak self, weak p] in
                guard let self else { return }
                guard let p else { self.pending.remove(id); return }
                let reply = await self.ask("park", values: ["id": p.windowID, "pid": p.pid])
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
    /// original on a physical display. The host's restoration record retires only
    /// after its original position has actually been observed.
    func release(_ p: WindowProxy) async -> Bool {
        guard contains(p.windowID) else { return true }
        guard !releasing.contains(p.windowID) else { return false }
        releasing.insert(p.windowID)
        defer { releasing.remove(p.windowID) }
        native.insert(p.windowID)
        let reply = await ask("release", values: ["id": p.windowID])
        if let text = reply["error"] as? String { native.remove(p.windowID); fail(text); return false }
        entries[p.windowID] = nil
        p.endBankCapture()
        if let frame = reply["restored"] as? String, !frame.isEmpty { p.placedNatively(at: NSRectFromString(frame)) }
        scheduleCapture(); onChange?()
        return true
    }

    func returnToCanvas() { native.removeAll() }

    func stop() async -> Bool {
        captureWork?.cancel(); captureWork = nil
        captureRevision += 1; capture?.stop(); capture = nil
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
            guard phase == "starting", let id = (value["display_id"] as? NSNumber)?.uint32Value,
                  let rect = value["bounds"] as? String else { return }
            displayID = id; bounds = NSRectFromString(rect); scale = (value["scale"] as? NSNumber)?.doubleValue ?? 2
            SIPRedesign.sourceDisplayID = id
            retireRestoredEntries()
            phase = "running"
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
            phase = "stopped"; captureRevision += 1; capture?.stop(); capture = nil
            retireRestoredEntries(); pending.removeAll(); SIPRedesign.sourceDisplayID = nil
            onChange?()
        case "failed": phase = "failed"; fail(value["error"] as? String ?? "Source-bank startup failed."); finishReadiness()
        default: break
        }
    }

    private func ended(session: String) {
        guard session == token else { return }
        process = nil; input = nil
        finishReadiness()
        for reply in requests.values { reply.resume(returning: ["error": "The source-bank host exited."]) }
        requests.removeAll()
        if phase != "stopped" && phase != "failed" {
            captureRevision += 1; capture?.stop(); capture = nil
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

    private func rebuildCapture() {
        captureWork = nil
        captureRevision += 1
        let revision = captureRevision
        guard phase == "running", !entries.isEmpty else { capture?.stop(); capture = nil; return }
        Task { [weak self] in
            guard let self else { return }
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
                guard self.captureRevision == revision, self.phase == "running",
                      let display = content.displays.first(where: { $0.displayID == self.displayID }) else { return }
                let records = self.entries.values.map(\.record)
                let windows = records.compactMap { record in content.windows.first { $0.windowID == record.id && $0.owningApplication?.processID == record.process.pid } }
                guard windows.count == records.count else { self.scheduleCapture(); return }
                let source = records.map(\.native).reduce(CGRect.null) { $0.union($1) }.integral
                guard display.frame.contains(source) else { self.captureFailed("A banked window moved outside the capture display."); return }
                let feed = SourceBankCapture(display: display, windows: windows, source: source, scale: self.scale,
                                             fps: SIPRedesign.frameRate(displayID: CGMainDisplayID()))
                feed.onFrame = { [weak self, weak feed] buffer, region in
                    guard let self, self.capture === feed else { return }
                    for entry in self.entries.values where region.contains(entry.record.native) {
                        entry.proxy?.applyBankFrame(buffer, crop: SourceBankGeometry.crop(window: entry.record.native, source: region))
                    }
                }
                feed.onError = { [weak self, weak feed] text in
                    guard let self, self.capture === feed else { return }
                    self.captureFailed("Window-bank capture: \(text)")
                }
                self.capture?.stop(); self.capture = feed; feed.start()
                self.onChange?()
            } catch {
                guard self.captureRevision == revision, self.phase == "running" else { return }
                self.captureFailed("Window-bank enumeration: \(error.localizedDescription)")
            }
        }
    }

    private func fail(_ text: String) { error = text; Log.note("Window bank: \(text)"); onFailure?(text) }
    private func captureFailed(_ text: String) {
        fail(text)
        Task { _ = await stop() }
    }
    private func finishReadiness() { let waiting = ready; ready.removeAll(); for waiter in waiting { waiter.resume() } }
}
