import XCTest
@testable import Canvas

final class CapturedWindowInputTests: XCTestCase {
    func testPointerKeepsItsWindowLocalPositionAcrossCameraChanges() {
        // The tile and its actual app window can occupy different displays.
        let tile = CGRect(x: 2400, y: -300, width: 800, height: 600)
        let native = CGRect(x: -1600, y: 120, width: 800, height: 600)
        let local = CGPoint(x: 137, y: 245)
        let world = CGPoint(x: tile.minX + local.x, y: tile.minY + local.y)
        for zoom: CGFloat in [0.25, 0.8, 1, 2] {
            let camera = Camera(origin: CGPoint(x: 1900, y: -500), zoom: zoom)
            let received = CapturedWindowInput.nativePoint(world: camera.toWorld(camera.toScreen(world)),
                                                           tile: tile, native: native)
            XCTAssertEqual(received.x, native.minX + local.x, accuracy: 1e-8)
            XCTAssertEqual(received.y, native.minY + local.y, accuracy: 1e-8)
        }
    }

    func testSelectionMayContinueOutsideTheTileWithoutClamping() {
        let tile = CGRect(x: 100, y: 200, width: 400, height: 300)
        let native = CGRect(x: 900, y: 50, width: 400, height: 300)
        let received = CapturedWindowInput.nativePoint(world: CGPoint(x: 80, y: 550), tile: tile, native: native)
        XCTAssertEqual(received, CGPoint(x: 880, y: 400))
    }
}
