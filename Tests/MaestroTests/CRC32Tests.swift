import XCTest
@testable import Maestro

final class CRC32Tests: XCTestCase {
    func testKnownVectorsFromRustImpl() {
        XCTAssertEqual(CRC32.compute(Array("test test test".utf8)), 0x235b6a02)
        XCTAssertEqual(CRC32.compute(Array("1234321".utf8)), 0xd981751c)
    }

    func testEmptyInput() {
        XCTAssertEqual(CRC32.compute([]), 0)
    }
}
