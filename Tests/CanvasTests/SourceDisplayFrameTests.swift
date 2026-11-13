import XCTest
import CoreVideo
import IOSurface
import SourceDisplay
@testable import Canvas

final class SourceDisplayFrameTests: XCTestCase {
    func testDisplayPoolLeaseLastsAsLongAsThePixelBuffer() throws {
        let properties: [String: Any] = [kIOSurfaceWidth as String: 16, kIOSurfaceHeight as String: 16,
            kIOSurfaceBytesPerElement as String: 4, kIOSurfaceBytesPerRow as String: 64,
            kIOSurfacePixelFormat as String: kCVPixelFormatType_32BGRA]
        let surface = try XCTUnwrap(IOSurfaceCreate(properties as CFDictionary))
        let before = IOSurfaceGetUseCount(surface)
        try autoreleasepool {
            let buffer = try XCTUnwrap(SLRetainDisplayFrame(surface))
            XCTAssertEqual(CVPixelBufferGetWidth(buffer), 16)
            XCTAssertGreaterThan(IOSurfaceGetUseCount(surface), before)
            withExtendedLifetime(buffer) { XCTAssertGreaterThan(IOSurfaceGetUseCount(surface), before) }
        }
        XCTAssertEqual(IOSurfaceGetUseCount(surface), before)
    }

    func testBuildSevenJournalRemainsRecoverableWithoutMultipleDisplayFields() throws {
        let original = #"{"token":"old","host":{"pid":123,"birth":456},"displayID":42,"records":[]}"#
        let journal = try JSONDecoder().decode(BankJournal.self, from: Data(original.utf8))
        XCTAssertEqual(journal.displayID, 42)
        XCTAssertNil(journal.displayIDs)
    }
}
