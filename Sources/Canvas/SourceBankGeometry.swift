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
        let usable = usableArea(of: display)
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

    /// Where windows may sit on a bank: clear of its edges and of the menu-bar band at its top.
    static func usableArea(of display: CGRect) -> CGRect {
        CGRect(x: display.minX + 24, y: display.minY + 64, width: display.width - 48, height: display.height - 88)
    }

    /// A bank display's size in points: never smaller than 3072 × 2560, wide enough for a window as
    /// wide as the widest physical display, tall enough to let a window grow past the tallest one,
    /// within the virtual display's 8192-pixel limit at 2× (4096 points). A 3072-point bank couldn't
    /// hold a full-width window from a 3430-point ultrawide (measured 2026-11-13).
    static func bankSize(physical: [CGSize]) -> CGSize {
        let wide = physical.map(\.width).max() ?? 0, tall = physical.map(\.height).max() ?? 0
        return CGSize(width: min(4096, max(3072, (wide + 48).rounded(.up))),
                      height: min(4096, max(2560, (tall + 88).rounded(.up))))
    }

    /// The largest size a window can take in the bank: a resize past it is held to it, never answered
    /// by taking the window out of the bank (as one 2177 pt tall was on a 2048 pt bank, 2026-11-13).
    static func largestSlot(banks: [CGRect]) -> CGSize {
        let areas = banks.map(usableArea(of:))
        return CGSize(width: areas.map(\.width).max() ?? 0, height: areas.map(\.height).max() ?? 0)
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

    /// A window's corner radius, in pixels, from the alpha channel of a one-shot capture (row-major,
    /// one byte per pixel). A shared display feed has no alpha, so whatever sits behind a window on
    /// its bank shows in its corners; the tile is clipped to this radius instead. Measured from the
    /// corner of the opaque area, so a capture framed with a shadow margin measures the same: along
    /// the diagonal, a circular corner of radius r is first opaque at r·(1 − 1/√2) on each axis.
    /// The smaller of the top-left and bottom-left corners, so content is never clipped where one is
    /// square. Nil when the image has no opaque area.
    static func cornerRadius(alpha: [UInt8], width: Int, height: Int, opaque: UInt8 = 230) -> CGFloat? {
        corner(alpha: alpha, width: width, height: height, opaque: opaque)?.radius
    }

    /// The same, in points, for a window `points` wide: the capture's own scale (and any margin it
    /// was framed with) drops out against the opaque area's width.
    static func cornerRadius(alpha: [UInt8], width: Int, height: Int, windowWidth points: CGFloat) -> CGFloat? {
        guard let c = corner(alpha: alpha, width: width, height: height), c.opaqueWidth > 0 else { return nil }
        return c.radius * points / CGFloat(c.opaqueWidth)
    }

    private static func corner(alpha: [UInt8], width: Int, height: Int, opaque: UInt8 = 230) -> (radius: CGFloat, opaqueWidth: Int)? {
        guard width > 2, height > 2, alpha.count >= width * height else { return nil }
        // The opaque area's bounds: its middle row and column, where no corner reaches.
        let midY = height / 2, midX = width / 2
        guard let left = (0..<width).first(where: { alpha[midY * width + $0] >= opaque }),
              let right = (0..<width).last(where: { alpha[midY * width + $0] >= opaque }),
              let top = (0..<height).first(where: { alpha[$0 * width + midX] >= opaque }),
              let bottom = (0..<height).last(where: { alpha[$0 * width + midX] >= opaque }),
              right > left, bottom > top else { return nil }
        let reach = min(right - left, bottom - top) / 2
        func diagonal(_ x0: Int, _ y0: Int, _ dy: Int) -> Int? {
            (0..<reach).first { i in alpha[(y0 + dy * i) * width + x0 + i] >= opaque }
        }
        guard let topLeft = diagonal(left, top, 1), let bottomLeft = diagonal(left, bottom, -1) else { return nil }
        return (CGFloat(min(topLeft, bottomLeft)) / (1 - 1 / 2.0.squareRoot()), right - left + 1)
    }

    /// Which banked window a raised window (a menu, pop-up list, popover) of the same app belongs to:
    /// the one it overlaps most, else the nearest within `reach` points. Nil when none is close.
    static func raisedParent(_ raised: CGRect, among windows: [(id: CGWindowID, frame: CGRect)], reach: CGFloat = 240) -> CGWindowID? {
        func area(_ r: CGRect) -> CGFloat { r.isNull ? 0 : r.width * r.height }
        if let best = windows.max(by: { area($0.frame.intersection(raised)) < area($1.frame.intersection(raised)) }),
           area(best.frame.intersection(raised)) > 0 { return best.id }
        func gap(_ a: CGRect) -> CGFloat {
            let dx = max(0, max(a.minX - raised.maxX, raised.minX - a.maxX))
            let dy = max(0, max(a.minY - raised.maxY, raised.minY - a.maxY))
            return hypot(dx, dy)
        }
        guard let nearest = windows.min(by: { gap($0.frame) < gap($1.frame) }), gap(nearest.frame) <= reach else { return nil }
        return nearest.id
    }

    /// Where a raised window's overlay goes in its parent tile's layer: Core Animation's y-up space,
    /// origin at the tile's bottom-left, world units (points) at any zoom. Native frames are top-left.
    static func overlayFrame(raised: CGRect, parent: CGRect, tileHeight: CGFloat) -> CGRect {
        let dx = raised.minX - parent.minX, dy = raised.minY - parent.minY
        return CGRect(x: dx, y: tileHeight - dy - raised.height, width: raised.width, height: raised.height)
    }

    /// An image's alpha channel, one byte per pixel, row-major from the top.
    static func alpha(of image: CGImage) -> [UInt8]? {
        let w = image.width, h = image.height
        guard w > 0, h > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: w * h)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                          space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return drawn ? bytes : nil
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
