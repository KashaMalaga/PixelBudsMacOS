import XCTest
@testable import Maestro

final class VarintTests: XCTestCase {
    func testDecodeMatchesRustVectors() throws {
        // Vectors lifted verbatim from libmaestro/src/hdlc/varint.rs test_decode.
        try assertDecode([0x01], 0x00, 1)
        try assertDecode([0x00, 0x00, 0x00, 0x01], 0x00, 4)
        try assertDecode([0x11, 0x00], 0x0008, 1)
        try assertDecode([0x10, 0x21], 0x0808, 2)

        try assertDecode([0x03], 0x01, 1)
        try assertDecode([0xff], 0x7f, 1)
        try assertDecode([0x00, 0x03], 0x80, 2)

        try assertDecode([0xfe, 0xff], 0x3fff, 2)
        try assertDecode([0x00, 0x00, 0x03], 0x4000, 3)

        try assertDecode([0xfe, 0xfe, 0xff], 0x1fffff, 3)
        try assertDecode([0x00, 0x00, 0x00, 0x03], 0x200000, 4)

        try assertDecode([0xfe, 0xfe, 0xfe, 0xff], 0x0fffffff, 4)
        try assertDecode([0x00, 0x00, 0x00, 0x00, 0x03], 0x10000000, 5)

        try assertDecode([0xfe, 0xfe, 0xfe, 0xfe, 0x1f], UInt32.max, 5)
    }

    func testDecodeIncomplete() {
        XCTAssertThrowsError(try Varint.decode([0xFE] as [UInt8])) { err in
            XCTAssertEqual(err as? Varint.DecodeError, .incomplete)
        }
    }

    func testDecodeOverflow() {
        XCTAssertThrowsError(try Varint.decode([0xFE, 0xFE, 0xFE, 0xFE, 0xFF] as [UInt8])) { err in
            XCTAssertEqual(err as? Varint.DecodeError, .overflow)
        }
    }

    func testEncodeMatchesRustVectors() {
        XCTAssertEqual(Varint.encode(0x01234), [0x68, 0x49])
        XCTAssertEqual(Varint.encode(0x87654), [0xa8, 0xd8, 0x43])
        XCTAssertEqual(Varint.encode(0x00), [0x01])
        XCTAssertEqual(Varint.encode(0x01), [0x03])
        XCTAssertEqual(Varint.encode(0x7f), [0xff])
        XCTAssertEqual(Varint.encode(0x80), [0x00, 0x03])
        XCTAssertEqual(Varint.encode(0x3fff), [0xfe, 0xff])
        XCTAssertEqual(Varint.encode(0x4000), [0x00, 0x00, 0x03])
        XCTAssertEqual(Varint.encode(UInt32.max), [0xfe, 0xfe, 0xfe, 0xfe, 0x1f])
    }

    func testNumBytes() {
        XCTAssertEqual(Varint.numBytes(0x00), 1)
        XCTAssertEqual(Varint.numBytes(0x7f), 1)
        XCTAssertEqual(Varint.numBytes(0x80), 2)
        XCTAssertEqual(Varint.numBytes(0x3fff), 2)
        XCTAssertEqual(Varint.numBytes(0x4000), 3)
        XCTAssertEqual(Varint.numBytes(UInt32.max), 5)
    }

    private func assertDecode(
        _ bytes: [UInt8],
        _ expectedValue: UInt32,
        _ expectedConsumed: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let (v, n) = try Varint.decode(bytes)
        XCTAssertEqual(v, expectedValue, "value", file: file, line: line)
        XCTAssertEqual(n, expectedConsumed, "consumed", file: file, line: line)
    }
}
