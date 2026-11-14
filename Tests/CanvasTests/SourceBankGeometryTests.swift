import XCTest
@testable import Canvas

final class SourceBankGeometryTests: XCTestCase {
    func testParkingUsesTheActualDisplayOriginAndNeverOverlapsEarlierWindows() {
        let display = CGRect(x: 3430, y: -500, width: 2048, height: 1536)
        var occupied: [CGRect] = []
        for size in [CGSize(width: 673, height: 439), CGSize(width: 1000, height: 800), CGSize(width: 700, height: 300)] {
            let slot = SourceBankGeometry.slot(size: size, display: display, occupied: occupied)!
            XCTAssertTrue(display.contains(slot))
            XCTAssertTrue(occupied.allSatisfy { !$0.intersects(slot) })
            occupied.append(slot)
        }
        XCTAssertNil(SourceBankGeometry.slot(size: CGSize(width: 2200, height: 800), display: display, occupied: occupied))
    }

    func testCropConvertsQuartzTopOriginToLayerBottomOrigin() {
        let source = CGRect(x: 3430, y: 64, width: 2000, height: 1000)
        let window = CGRect(x: 3530, y: 164, width: 800, height: 300)
        let crop = SourceBankGeometry.crop(window: window, source: source)
        XCTAssertEqual(crop.minX, 0.05, accuracy: 1e-9)
        XCTAssertEqual(crop.minY, 0.6, accuracy: 1e-9)
        XCTAssertEqual(crop.width, 0.4, accuracy: 1e-9)
        XCTAssertEqual(crop.height, 0.3, accuracy: 1e-9)
    }

    func testRestorationKeepsOriginalGeometryOrMakesTheTitleReachableAfterUnplug() {
        let original = CGRect(x: 2600, y: 80, width: 800, height: 600)
        XCTAssertEqual(SourceBankGeometry.restoration(original, physical: [CGRect(x: 2000, y: 34, width: 1440, height: 866)]), original)
        let remaining = CGRect(x: 0, y: 34, width: 1440, height: 866)
        let restored = SourceBankGeometry.restoration(original, physical: [remaining])!
        XCTAssertEqual(restored.size, original.size)
        XCTAssertTrue(remaining.contains(CGPoint(x: restored.midX, y: restored.minY + 12)))
        XCTAssertNil(SourceBankGeometry.restoration(original, physical: []))
    }

    func testDriftFollowsMovesAndResizesThatStayInsideTheBank() {
        let bank = CGRect(x: 3430, y: 0, width: 3072, height: 2048)
        let recorded = CGRect(x: 3500, y: 100, width: 800, height: 600)
        let neighbour = CGRect(x: 4400, y: 100, width: 600, height: 400)
        XCTAssertEqual(SourceBankGeometry.drift(live: recorded.offsetBy(dx: 0.2, dy: 0), recorded: recorded, bank: bank, neighbours: [neighbour]), .same)
        let moved = recorded.offsetBy(dx: 40, dy: 300)
        XCTAssertEqual(SourceBankGeometry.drift(live: moved, recorded: recorded, bank: bank, neighbours: [neighbour]), .follow(moved))
        let grown = CGRect(origin: recorded.origin, size: CGSize(width: 880, height: 700))
        XCTAssertEqual(SourceBankGeometry.drift(live: grown, recorded: recorded, bank: bank, neighbours: [neighbour]), .follow(grown))
    }

    func testDriftReslotsAWindowThatGrewIntoANeighbourOrLeftItsBank() {
        let bank = CGRect(x: 3430, y: 0, width: 3072, height: 2048)
        let recorded = CGRect(x: 3500, y: 100, width: 800, height: 600)
        let neighbour = CGRect(x: 4400, y: 100, width: 600, height: 400)
        let intoNeighbour = CGRect(origin: recorded.origin, size: CGSize(width: 1000, height: 600))
        XCTAssertEqual(SourceBankGeometry.drift(live: intoNeighbour, recorded: recorded, bank: bank, neighbours: [neighbour]), .reslot(intoNeighbour))
        // Dragged by its title bar onto the physical display to the left.
        let escaped = recorded.offsetBy(dx: -500, dy: 0)
        XCTAssertEqual(SourceBankGeometry.drift(live: escaped, recorded: recorded, bank: bank, neighbours: [neighbour]), .reslot(escaped))
        // Unchanged but still misplaced (the drag ended): still a reslot, not `same`.
        XCTAssertEqual(SourceBankGeometry.drift(live: escaped, recorded: escaped, bank: bank, neighbours: [neighbour]), .reslot(escaped))
    }

    func testFeedSourceLeavesHeadroomInsideTheDisplay() {
        let display = CGRect(x: 3430, y: 0, width: 3072, height: 2048)
        let windows = [CGRect(x: 3454, y: 64, width: 800, height: 600), CGRect(x: 4300, y: 64, width: 600, height: 400)]
        let source = SourceBankGeometry.feedSource(windows: windows, display: display)
        XCTAssertTrue(display.contains(source))
        XCTAssertEqual(source.minX, display.minX)   // clamped on the near edges
        XCTAssertEqual(source.minY, display.minY)
        XCTAssertEqual(source.maxX, 4900 + SourceBankGeometry.feedHeadroom)
        XCTAssertEqual(source.maxY, 664 + SourceBankGeometry.feedHeadroom)
        XCTAssertTrue(SourceBankGeometry.feedSource(windows: [], display: display).isNull)
    }

    /// A rounded rectangle's alpha, `margin` transparent pixels round it (a shadow margin).
    private func roundedAlpha(width: Int, height: Int, radius: Double, margin: Int) -> [UInt8] {
        var a = [UInt8](repeating: 0, count: width * height)
        let x0 = Double(margin), y0 = Double(margin), x1 = Double(width - margin), y1 = Double(height - margin)
        for y in 0..<height {
            for x in 0..<width {
                let px = Double(x) + 0.5, py = Double(y) + 0.5
                guard px >= x0, px <= x1, py >= y0, py <= y1 else { continue }
                let cx = min(max(px, x0 + radius), x1 - radius), cy = min(max(py, y0 + radius), y1 - radius)
                if (px - cx) * (px - cx) + (py - cy) * (py - cy) <= radius * radius { a[y * width + x] = 255 }
            }
        }
        return a
    }

    func testCornerRadiusIsMeasuredFromTheOpaqueAreaWhateverTheMargin() {
        for (radius, margin) in [(32.0, 0), (32.0, 40), (52.0, 12)] {
            let a = roundedAlpha(width: 400, height: 300, radius: radius, margin: margin)
            let measured = SourceBankGeometry.cornerRadius(alpha: a, width: 400, height: 300)!
            XCTAssertEqual(Double(measured), radius, accuracy: 3.5, "radius \(radius), margin \(margin)")
        }
    }

    func testSquareCornersMeasureNearZeroAndAnEmptyImageNothing() {
        let a = roundedAlpha(width: 200, height: 100, radius: 0, margin: 5)
        XCTAssertLessThan(SourceBankGeometry.cornerRadius(alpha: a, width: 200, height: 100)!, 1.5)
        XCTAssertNil(SourceBankGeometry.cornerRadius(alpha: [UInt8](repeating: 0, count: 200 * 100), width: 200, height: 100))
    }

    func testARaisedWindowBelongsToTheWindowItOverlapsMostOrTheNearestOne() {
        let a = CGRect(x: 0, y: 0, width: 700, height: 450), b = CGRect(x: 716, y: 0, width: 700, height: 450)
        let windows: [(id: CGWindowID, frame: CGRect)] = [(1, a), (2, b)]
        // A menu hanging off A's bottom edge, mostly outside it.
        XCTAssertEqual(SourceBankGeometry.raisedParent(CGRect(x: 40, y: 420, width: 220, height: 200), among: windows), 1)
        // A popover straddling both, more of it over B.
        XCTAssertEqual(SourceBankGeometry.raisedParent(CGRect(x: 650, y: 100, width: 300, height: 100), among: windows), 2)
        // Just below A, touching nothing: the nearest; far away: none.
        XCTAssertEqual(SourceBankGeometry.raisedParent(CGRect(x: 40, y: 470, width: 200, height: 100), among: windows), 1)
        XCTAssertNil(SourceBankGeometry.raisedParent(CGRect(x: 40, y: 1400, width: 200, height: 100), among: windows))
    }

    func testOverlayFrameIsTheRaisedWindowsOffsetInTheTilesYUpSpace() {
        let parent = CGRect(x: -5404, y: 64, width: 700, height: 450)
        // A menu 165 pt below the parent's top, overhanging its bottom by 50 pt.
        let menu = CGRect(x: -5392, y: 229, width: 220, height: 335)
        let f = SourceBankGeometry.overlayFrame(raised: menu, parent: parent, tileHeight: 450)
        XCTAssertEqual(f, CGRect(x: 12, y: 450 - 165 - 335, width: 220, height: 335))
        XCTAssertLessThan(f.minY, 0)   // below the tile's bottom edge: drawn past it
    }

    func testBanksAreSizedForTheWidestDisplayAndRoomToGrowTaller() {
        // The owner's ultrawide: wide enough for a full-width window, 2560 tall.
        XCTAssertEqual(SourceBankGeometry.bankSize(physical: [CGSize(width: 3430, height: 1447)]), CGSize(width: 3478, height: 2560))
        // A laptop alone: the 3072 × 2560 floor.
        XCTAssertEqual(SourceBankGeometry.bankSize(physical: [CGSize(width: 1512, height: 982)]), CGSize(width: 3072, height: 2560))
        // A 6K display: held to the 4096-point (8192-pixel) limit.
        XCTAssertEqual(SourceBankGeometry.bankSize(physical: [CGSize(width: 6016, height: 3384)]), CGSize(width: 4096, height: 3472))
    }

    func testTheLargestSlotIsABanksUsableArea() {
        let banks = [CGRect(x: -6956, y: 0, width: 3478, height: 2560), CGRect(x: -3478, y: 0, width: 3478, height: 2560)]
        XCTAssertEqual(SourceBankGeometry.largestSlot(banks: banks), CGSize(width: 3430, height: 2472))
        // Zen asked for 2177 pt on the old 2048 pt bank; on these banks it fits.
        XCTAssertNotNil(SourceBankGeometry.slot(size: CGSize(width: 1304, height: 2177), display: banks[0], occupied: []))
        XCTAssertNotNil(SourceBankGeometry.slot(size: CGSize(width: 3430, height: 900), display: banks[0], occupied: []))
    }

    func testAFeedCapturesOnlyTheWindowsInSightAtTheirLevelOfDetail() {
        let bank = CGRect(x: -6956, y: 0, width: 3478, height: 2560)
        let a = CGRect(x: -6900, y: 64, width: 800, height: 600), b = CGRect(x: -4200, y: 1800, width: 600, height: 400)
        // Both in sight at half detail: both inside, at 1 pixel per point instead of 2.
        let both = SourceBankGeometry.feedPlan(windows: [(a, 0.5), (b, 0.5)], raised: [], display: bank, fullScale: 2)!
        XCTAssertTrue(both.source.contains(a) && both.source.contains(b))
        XCTAssertEqual(both.scale, 1)
        // Only A in sight: B's corner of the bank isn't captured.
        let one = SourceBankGeometry.feedPlan(windows: [(a, 1)], raised: [], display: bank, fullScale: 2)!
        XCTAssertFalse(one.source.intersects(b))
        XCTAssertEqual(one.scale, 2)
        XCTAssertEqual(one.needed, a)
        // A window with no picture yet (factor 0) is inside without raising the detail; a far zoom
        // is held to the floor; nothing in sight is no feed.
        let fresh = SourceBankGeometry.feedPlan(windows: [(a, 0.25), (b, 0)], raised: [], display: bank, fullScale: 2)!
        XCTAssertTrue(fresh.source.contains(b))
        XCTAssertEqual(fresh.scale, 0.5)
        XCTAssertEqual(SourceBankGeometry.feedPlan(windows: [(a, 0.01)], raised: [], display: bank, fullScale: 2)!.scale, SourceBankGeometry.minFeedScale)
        XCTAssertNil(SourceBankGeometry.feedPlan(windows: [], raised: [], display: bank, fullScale: 2))
        // A menu hanging off A is part of what's needed.
        let menu = CGRect(x: -6880, y: 600, width: 220, height: 300)
        XCTAssertTrue(SourceBankGeometry.feedPlan(windows: [(a, 1)], raised: [menu], display: bank, fullScale: 2)!.needed.contains(menu))
    }

    func testAFeedIsRebuiltOnlyWhenItMissesWhatsWantedChangesDetailOrIsFarTooLarge() {
        let bank = CGRect(x: -6956, y: 0, width: 3478, height: 2560)
        let a = CGRect(x: -6900, y: 64, width: 800, height: 600), b = CGRect(x: -4200, y: 1800, width: 600, height: 400)
        let plan = SourceBankGeometry.feedPlan(windows: [(a, 1)], raised: [], display: bank, fullScale: 2)!
        XCTAssertTrue(SourceBankGeometry.feedNeedsRebuild(running: nil, plan: plan))
        XCTAssertFalse(SourceBankGeometry.feedNeedsRebuild(running: nil, plan: nil))
        XCTAssertTrue(SourceBankGeometry.feedNeedsRebuild(running: (plan.source, 2), plan: nil))
        XCTAssertFalse(SourceBankGeometry.feedNeedsRebuild(running: (plan.source, 2), plan: plan))
        // A moved a little, inside the headroom: the feed runs on.
        let nudged = SourceBankGeometry.feedPlan(windows: [(a.offsetBy(dx: 100, dy: 40), 1)], raised: [], display: bank, fullScale: 2)!
        XCTAssertFalse(SourceBankGeometry.feedNeedsRebuild(running: (plan.source, 2), plan: nudged))
        // Zoomed out a level: new detail.
        XCTAssertTrue(SourceBankGeometry.feedNeedsRebuild(running: (plan.source, 2), plan: SourceBankGeometry.feedPlan(windows: [(a, 0.707)], raised: [], display: bank, fullScale: 2)))
        // B came into sight: outside the feed.
        let withB = SourceBankGeometry.feedPlan(windows: [(a, 1), (b, 1)], raised: [], display: bank, fullScale: 2)!
        XCTAssertTrue(SourceBankGeometry.feedNeedsRebuild(running: (plan.source, 2), plan: withB))
        // B left again: the whole-bank feed is over twice what A needs.
        XCTAssertTrue(SourceBankGeometry.feedNeedsRebuild(running: (withB.source, 2), plan: plan))
    }

    func testProcessIdentityDoesNotTreatAnAbsentProcessAsItsFormerOwner() {
        XCTAssertTrue(BankProcess(getpid())!.isLive)
        XCTAssertNil(BankProcess(Int32.max))
    }
}
