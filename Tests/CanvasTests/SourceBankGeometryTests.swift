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

    func testProcessIdentityDoesNotTreatAnAbsentProcessAsItsFormerOwner() {
        XCTAssertTrue(BankProcess(getpid())!.isLive)
        XCTAssertNil(BankProcess(Int32.max))
    }
}
