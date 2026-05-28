import XCTest
@testable import Maestro

final class PeerAddressTests: XCTestCase {
    /// Captured frame 1's varint-decoded address is 0x28C0:
    /// source = (0x28C0 >> 6) & 0xF = 0x3 = leftBtCore,
    /// target = (0x28C0 >> 10) & 0xF = 0xA = maestroA.
    /// Channel: maestroA ↔ leftBtCore = 19.
    func testDecodeFrame1Address() {
        let addr = MaestroAddress(value: 0x28C0)
        XCTAssertEqual(addr.source, .leftBtCore)
        XCTAssertEqual(addr.target, .maestroA)
        XCTAssertEqual(addr.channelID, 19)
    }

    /// Captured frames 2-6 have varint-decoded address 0x2900:
    /// source = (0x2900 >> 6) & 0xF = 0x4 = rightBtCore,
    /// target = (0x2900 >> 10) & 0xF = 0xA = maestroA.
    /// Channel: maestroA ↔ rightBtCore = 21.
    func testDecodeFrame2Address() {
        let addr = MaestroAddress(value: 0x2900)
        XCTAssertEqual(addr.source, .rightBtCore)
        XCTAssertEqual(addr.target, .maestroA)
        XCTAssertEqual(addr.channelID, 21)
    }

    func testChannelToAddressRoundtrip() {
        for ch in MaestroChannel.candidateIDs {
            guard let addr = MaestroChannel.address(for: ch) else {
                XCTFail("No address for channel \(ch)")
                continue
            }
            XCTAssertEqual(addr.channelID, ch, "channel \(ch) round-trip")
        }
    }

    func testOutboundFrameAddressForChannel19() {
        // Outbound from us (maestroA) to leftBtCore on channel 19.
        let addr = MaestroChannel.address(for: 19)
        XCTAssertEqual(addr?.source, .maestroA)
        XCTAssertEqual(addr?.target, .leftBtCore)
        // Bit layout: maestroA (10) << 6 | leftBtCore (3) << 10 = 0x0A80
        XCTAssertEqual(addr?.value, (10 << 6) | (3 << 10))
    }
}
