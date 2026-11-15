import XCTest
@testable import Canvas

/// The steps ⌃← / ⌃→ take between Desktops, full-screen apps' Spaces counted in the walk.
final class SpacesCarryTests: XCTestCase {
    func testStepsCountEveryDesktopOnTheWay() {
        XCTAssertEqual(SpacesCarry.steps(from: 1, to: 3, order: [1, 2, 3], fullScreen: []), 2)
        XCTAssertEqual(SpacesCarry.steps(from: 3, to: 1, order: [1, 2, 3], fullScreen: []), -2)
    }

    func testAFullScreenAppAfterTheDesktopDoesNotCount() {
        XCTAssertEqual(SpacesCarry.steps(from: 1, to: 2, order: [1, 2, 9], fullScreen: [9]), 1)
    }

    func testAFullScreenAppOnTheWayLeavesTheWindowWhereItIs() {
        XCTAssertNil(SpacesCarry.steps(from: 1, to: 2, order: [1, 9, 2], fullScreen: [9]))
        XCTAssertNil(SpacesCarry.steps(from: 2, to: 1, order: [1, 9, 2], fullScreen: [9]))
    }

    func testNoStepsToAFullScreenSpaceOrAMissingDesktop() {
        XCTAssertNil(SpacesCarry.steps(from: 1, to: 9, order: [1, 9], fullScreen: [9]))
        XCTAssertNil(SpacesCarry.steps(from: 1, to: 5, order: [1, 2], fullScreen: []))
        XCTAssertNil(SpacesCarry.steps(from: 1, to: 1, order: [1, 2], fullScreen: []))
    }
}
