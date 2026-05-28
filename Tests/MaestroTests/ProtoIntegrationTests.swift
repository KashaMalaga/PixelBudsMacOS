import XCTest
import SwiftProtobuf
@testable import Maestro

/// Verifies that swift-protobuf successfully generated working Swift types
/// from our .proto files, and that we can parse a real RpcPacket from a
/// captured HDLC frame.
final class ProtoIntegrationTests: XCTestCase {
    func testParseCapturedFrameAsRpcPacket() throws {
        // Frame 1 from 2026-05-21 capture: SoftwareInfo response with firmware string.
        let raw: [UInt8] = [
            0x7e, 0x80, 0xa3, 0x03, 0x2a, 0x4c, 0x10, 0xef, 0x88, 0x98, 0xd4, 0xe4, 0x33, 0x22, 0x38, 0x12,
            0x1a, 0x0a, 0x03, 0x35, 0x37, 0x35, 0x12, 0x13, 0x72, 0x65, 0x6c, 0x65, 0x61, 0x73, 0x65, 0x5f,
            0x35, 0x2e, 0x31, 0x31, 0x5f, 0x73, 0x69, 0x67, 0x6e, 0x65, 0x64, 0x1a, 0x1a, 0x0a, 0x03, 0x35,
            0x37, 0x35, 0x12, 0x13, 0x72, 0x65, 0x6c, 0x65, 0x61, 0x73, 0x65, 0x5f, 0x35, 0x2e, 0x31, 0x31,
            0x5f, 0x73, 0x69, 0x67, 0x6e, 0x65, 0x64, 0x29, 0x28, 0x4b, 0x58, 0xf5, 0x03, 0x63, 0x52, 0x0e,
            0x30, 0x00, 0x08, 0x01, 0x10, 0x13, 0x1d, 0xea, 0x71, 0xde, 0x7d, 0x5e, 0x25, 0x44, 0xfa, 0x99,
            0x71, 0x38, 0xff, 0xff, 0xff, 0xff, 0x0f, 0x42, 0xc5, 0x69, 0x4e, 0x7e,
        ]

        let decoder = HDLCDecoder()
        var frames: [HDLCFrame] = []
        decoder.process(Data(raw), onFrame: { frames.append($0) }, onError: { _ in })
        let hdlc = try XCTUnwrap(frames.first)

        let packet = try Pw_Rpc_Packet_RpcPacket(serializedBytes: hdlc.data)
        XCTAssertEqual(packet.type, .response, "Server-originated frame should be a RESPONSE packet")
        XCTAssertGreaterThan(packet.payload.count, 0, "Packet should have an inner payload")

        // The inner payload is the SoftwareInfo protobuf — should still contain firmware text.
        let firmware = Data("release_5.11_signed".utf8)
        XCTAssertNotNil(
            packet.payload.range(of: firmware),
            "Inner protobuf payload should still contain firmware string"
        )

        // The SoftwareInfo message also decodes cleanly.
        let info = try MaestroPw_SoftwareInfo(serializedBytes: packet.payload)
        XCTAssertEqual(info.firmware.right.versionString, "release_5.11_signed")
        XCTAssertEqual(info.firmware.left.versionString, "release_5.11_signed")
    }
}
