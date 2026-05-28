import XCTest
@testable import Maestro

final class HDLCRoundtripTests: XCTestCase {
    func testEncodeMatchesRustEmptyData() {
        let frame = HDLCFrame(address: 0x010203, control: 0x03, data: Data())
        let encoded = HDLCEncoder.encode(frame)
        // Vector from libmaestro/src/hdlc/encoder.rs test_encode.
        XCTAssertEqual(
            Array(encoded),
            [0x7e, 0x06, 0x08, 0x09, 0x03, 0x8b, 0x3b, 0xf7, 0x42, 0x7e]
        )
    }

    func testEncodeMatchesRustWithStuffing() {
        let frame = HDLCFrame(
            address: 0x010203,
            control: 0x03,
            data: Data([0x05, 0x06, 0x07, 0x7d, 0x7e, 0x7f, 0xff])
        )
        let encoded = HDLCEncoder.encode(frame)
        // Vector from libmaestro/src/hdlc/encoder.rs test_encode — note 0x7d → 0x7d 0x5d and 0x7e → 0x7d 0x5e.
        XCTAssertEqual(
            Array(encoded),
            [0x7e, 0x06, 0x08, 0x09, 0x03, 0x05, 0x06, 0x07, 0x7d, 0x5d,
             0x7d, 0x5e, 0x7f, 0xff, 0xe6, 0x2d, 0x17, 0xc6, 0x7e]
        )
    }

    func testRoundtripFromKnownFrame() {
        let frame = HDLCFrame(
            address: 0x010203,
            control: 0x03,
            data: Data([0x05, 0x06, 0x07, 0x7d, 0x7e, 0x7f, 0xff])
        )
        let encoded = HDLCEncoder.encode(frame)
        let decoder = HDLCDecoder()
        var frames: [HDLCFrame] = []
        var errors: [HDLCDecoder.DecodeError] = []
        decoder.process(encoded, onFrame: { frames.append($0) }, onError: { errors.append($0) })
        XCTAssertEqual(errors, [])
        XCTAssertEqual(frames, [frame])
    }

    func testDecodePartialThenComplete() {
        let frame = HDLCFrame(address: 0x42, control: 0x03, data: Data([0xde, 0xad, 0xbe, 0xef]))
        let encoded = HDLCEncoder.encode(frame)
        let decoder = HDLCDecoder()
        let halfway = encoded.count / 2
        var frames: [HDLCFrame] = []
        var errors: [HDLCDecoder.DecodeError] = []

        decoder.process(encoded.prefix(halfway), onFrame: { frames.append($0) }, onError: { errors.append($0) })
        XCTAssertEqual(frames, [])
        XCTAssertEqual(errors, [])

        decoder.process(encoded.suffix(from: halfway), onFrame: { frames.append($0) }, onError: { errors.append($0) })
        XCTAssertEqual(frames, [frame])
        XCTAssertEqual(errors, [])
    }

    func testCorruptChecksumReported() {
        let frame = HDLCFrame(address: 0x42, control: 0x03, data: Data([0x01, 0x02, 0x03]))
        var encoded = HDLCEncoder.encode(frame)
        // Flip a byte in the CRC region (4 bytes before closing flag).
        encoded[encoded.count - 3] ^= 0xFF
        let decoder = HDLCDecoder()
        var frames: [HDLCFrame] = []
        var errors: [HDLCDecoder.DecodeError] = []
        decoder.process(encoded, onFrame: { frames.append($0) }, onError: { errors.append($0) })
        XCTAssertEqual(frames, [])
        XCTAssertEqual(errors, [.invalidChecksum])
    }
}
