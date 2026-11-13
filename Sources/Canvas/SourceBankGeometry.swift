import AppKit
import Darwin

struct BankProcess: Codable, Equatable, Sendable {
    let pid: pid_t
    let birth: UInt64

    init?(_ pid: pid_t) {
        var info = proc_bsdinfo()
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout.size(ofValue: info))) == MemoryLayout.size(ofValue: info) else { return nil }
        self.pid = pid
        birth = info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec
    }

    var isLive: Bool { BankProcess(pid) == self }
}

struct BankRecord: Codable, Sendable {
    let id: CGWindowID
    let process: BankProcess
    let originalAX: CGRect
    let originalCG: CGRect
    let document: String?
    var native: CGRect
    var displayID: CGDirectDisplayID?
}

struct BankJournal: Codable {
    let token: String
    let host: BankProcess
    var displayID: CGDirectDisplayID? // Recovery of build 7 journals.
    var displayIDs: [CGDirectDisplayID]?
    var records: [BankRecord]
}

enum SourceBankGeometry {
    static func activeDisplayIDs() -> Set<CGDirectDisplayID> {
        var ids = [CGDirectDisplayID](repeating: 0, count: 32), count: UInt32 = 0
        guard CGGetActiveDisplayList(32, &ids, &count) == .success else { return [] }
        return Set(ids.prefix(Int(count)))
    }
    /// First free native rectangle, never a canvas coordinate. Existing slots
    /// stay fixed as windows arrive, so camera changes require no source moves.
    // SIP PERFORMANCE: packing affects ROI size and overflow stream count.
    // See docs/sip-redesign-performance.md; native slots stay independent of camera motion.
    static func slot(size: CGSize, display: CGRect, occupied: [CGRect]) -> CGRect? {
        let usable = CGRect(x: display.minX + 24, y: display.minY + 64,
                            width: display.width - 48, height: display.height - 88)
        let xs = ([usable.minX] + occupied.map { $0.maxX + 16 }).sorted()
        let ys = ([usable.minY] + occupied.map { $0.maxY + 16 }).sorted()
        for y in ys {
            for x in xs {
                let rect = CGRect(origin: CGPoint(x: x, y: y), size: size)
                if usable.contains(rect), !occupied.contains(where: { $0.insetBy(dx: -8, dy: -8).intersects(rect) }) { return rect }
            }
        }
        return nil
    }

    /// What a banked window's live native frame asks of the bank. The bank's
    /// record must follow the window, never the other way round: the picture
    /// crop and the input mapping both read that one frame.
    enum Drift: Equatable {
        /// Where the record has it.
        case same
        /// Moved or resized, still inside its bank and clear of its neighbours:
        /// the record (and so the crop) takes the new frame.
        case follow(CGRect)
        /// Grown into a neighbour's slot or left the bank: it needs a new slot.
        case reslot(CGRect)
    }

    static func drift(live: CGRect, recorded: CGRect, bank: CGRect, neighbours: [CGRect]) -> Drift {
        let fits = bank.contains(live) && !neighbours.contains(where: { $0.intersects(live) })
        if !fits { return .reslot(live) }
        return live.isClose(to: recorded) ? .same : .follow(live)
    }

    /// The region a bank feed captures: its windows plus headroom, so ordinary
    /// moves and resizes stay inside the running feed instead of restarting it.
    /// `SIP_BANK_HEADROOM` (points) overrides it, for measuring its throughput cost.
    static let feedHeadroom: CGFloat = ProcessInfo.processInfo.environment["SIP_BANK_HEADROOM"]
        .flatMap { Double($0) }.map { CGFloat(max(0, $0)) } ?? 384

    static func feedSource(windows: [CGRect], display: CGRect) -> CGRect {
        let union = windows.reduce(CGRect.null) { $0.union($1) }
        guard !union.isNull else { return .null }
        return union.insetBy(dx: -feedHeadroom, dy: -feedHeadroom).intersection(display).integral
    }

    static func crop(window: CGRect, source: CGRect) -> CGRect {
        CGRect(x: (window.minX - source.minX) / source.width,
               y: 1 - (window.maxY - source.minY) / source.height,
               width: window.width / source.width, height: window.height / source.height)
    }

    /// The original position when reachable; otherwise leave the title bar on
    /// a surviving physical display. Window size is not silently reduced.
    static func restoration(_ original: CGRect, physical: [CGRect]) -> CGRect? {
        if physical.contains(where: { $0.insetBy(dx: -2, dy: -2).contains(CGPoint(x: original.midX, y: original.minY + 12)) }) { return original }
        guard let screen = physical.max(by: { a, b in
            let ia = a.intersection(original), ib = b.intersection(original)
            return (ia.isNull ? 0 : ia.width * ia.height) < (ib.isNull ? 0 : ib.width * ib.height)
        }) else { return nil }
        return CGRect(x: max(screen.minX, min(original.minX, screen.maxX - min(original.width, screen.width))),
                      y: max(screen.minY, min(original.minY, screen.maxY - 40)),
                      width: original.width, height: original.height)
    }
}
