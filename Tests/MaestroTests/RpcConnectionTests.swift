import XCTest
import SwiftProtobuf
@testable import Maestro

/// Integration test using an in-memory transport: drives a full unary
/// request/response cycle through HDLC encode → fake transport → HDLC decode
/// → RpcPacket parsing → continuation resumption.
final class RpcConnectionTests: XCTestCase {

    func testUnaryRoundTripThroughMockTransport() async throws {
        let mock = MockTransport()
        let conn = RpcConnection(transport: mock.transport)
        await conn.start()

        let path = RpcPath("maestro_pw.Maestro/GetSoftwareInfo")
        let channel: UInt32 = 19

        let unaryTask = Task<Data, Error> {
            try await conn.unary(channel: channel, path: path, request: Google_Protobuf_Empty())
        }

        // Wait for the request to be sent on the wire.
        let outboundBytes = try await mock.waitForOutbound()
        let outboundFrame = try decodeOneHDLCFrame(outboundBytes)
        let outboundPacket = try Pw_Rpc_Packet_RpcPacket(serializedBytes: outboundFrame.data)
        XCTAssertEqual(outboundPacket.type, .request)
        XCTAssertEqual(outboundPacket.channelID, channel)
        XCTAssertEqual(outboundPacket.serviceID, path.serviceHash)
        XCTAssertEqual(outboundPacket.methodID, path.methodHash)
        XCTAssertGreaterThan(outboundPacket.callID, 0)
        XCTAssertEqual(outboundFrame.address, MaestroChannel.address(for: channel)?.value)

        // Build a fake server RESPONSE referencing the same call_id.
        var fakeSoftwareInfo = MaestroPw_SoftwareInfo()
        var fwInfo = MaestroPw_FirmwareInfo()
        var fwVersion = MaestroPw_FirmwareVersion()
        fwVersion.versionString = "test_fw_1.0"
        fwInfo.left = fwVersion
        fwInfo.right = fwVersion
        fakeSoftwareInfo.firmware = fwInfo

        var response = Pw_Rpc_Packet_RpcPacket()
        response.type = .response
        response.channelID = channel
        response.serviceID = outboundPacket.serviceID
        response.methodID = outboundPacket.methodID
        response.callID = outboundPacket.callID
        response.status = 0
        response.payload = try fakeSoftwareInfo.serializedData()

        let responseFrame = HDLCFrame(
            address: MaestroChannel.address(for: channel)!.value,
            control: HDLCConsts.unnumberedControl,
            data: try response.serializedData()
        )
        mock.feedInbound(HDLCEncoder.encode(responseFrame))

        let payload = try await unaryTask.value
        let info = try MaestroPw_SoftwareInfo(serializedBytes: payload)
        XCTAssertEqual(info.firmware.left.versionString, "test_fw_1.0")
        await conn.stop()
    }

    func testServerStreamYieldsMultipleMessagesThenFinishes() async throws {
        let mock = MockTransport()
        let conn = RpcConnection(transport: mock.transport)
        await conn.start()

        let path = RpcPath("maestro_pw.Maestro/SubscribeRuntimeInfo")
        let channel: UInt32 = 21

        let stream = try await conn.serverStream(
            channel: channel,
            path: path,
            request: Google_Protobuf_Empty()
        )

        let outbound = try await mock.waitForOutbound()
        let outboundFrame = try decodeOneHDLCFrame(outbound)
        let outboundPacket = try Pw_Rpc_Packet_RpcPacket(serializedBytes: outboundFrame.data)

        // Feed three SERVER_STREAM packets.
        for level in [50, 60, 70] as [Int32] {
            var rt = MaestroPw_RuntimeInfo()
            var bi = MaestroPw_BatteryInfo()
            var lb = MaestroPw_DeviceBatteryInfo()
            lb.level = level
            bi.left = lb
            rt.batteryInfo = bi

            var pkt = Pw_Rpc_Packet_RpcPacket()
            pkt.type = .serverStream
            pkt.channelID = channel
            pkt.serviceID = outboundPacket.serviceID
            pkt.methodID = outboundPacket.methodID
            pkt.callID = outboundPacket.callID
            pkt.payload = try rt.serializedData()

            mock.feedInbound(HDLCEncoder.encode(HDLCFrame(
                address: MaestroChannel.address(for: channel)!.value,
                control: HDLCConsts.unnumberedControl,
                data: try pkt.serializedData()
            )))
        }

        // Final RESPONSE with status=0 closes the stream.
        var final = Pw_Rpc_Packet_RpcPacket()
        final.type = .response
        final.channelID = channel
        final.serviceID = outboundPacket.serviceID
        final.methodID = outboundPacket.methodID
        final.callID = outboundPacket.callID
        final.status = 0
        mock.feedInbound(HDLCEncoder.encode(HDLCFrame(
            address: MaestroChannel.address(for: channel)!.value,
            control: HDLCConsts.unnumberedControl,
            data: try final.serializedData()
        )))

        var received: [Int32] = []
        for try await chunk in stream {
            let rt = try MaestroPw_RuntimeInfo(serializedBytes: chunk)
            received.append(rt.batteryInfo.left.level)
        }
        XCTAssertEqual(received, [50, 60, 70])
        await conn.stop()
    }

    // MARK: - Helpers

    private func decodeOneHDLCFrame(_ data: Data) throws -> HDLCFrame {
        let decoder = HDLCDecoder()
        var frame: HDLCFrame?
        var error: HDLCDecoder.DecodeError?
        decoder.process(data, onFrame: { frame = $0 }, onError: { error = $0 })
        if let error { throw error }
        return try XCTUnwrap(frame)
    }
}

private final class MockTransport: @unchecked Sendable {
    let transport: MaestroTransport

    private let inboundContinuation: AsyncStream<Data>.Continuation
    private let outboundContinuation: AsyncStream<Data>.Continuation
    private let outboundStream: AsyncStream<Data>
    private var outboundIterator: AsyncStream<Data>.AsyncIterator

    init() {
        var inCont: AsyncStream<Data>.Continuation!
        let inStream = AsyncStream<Data> { c in inCont = c }
        self.inboundContinuation = inCont

        var outCont: AsyncStream<Data>.Continuation!
        self.outboundStream = AsyncStream<Data> { c in outCont = c }
        self.outboundContinuation = outCont
        self.outboundIterator = outboundStream.makeAsyncIterator()

        let sendCont = outboundContinuation
        self.transport = MaestroTransport(
            send: { data in sendCont.yield(data) },
            inbound: inStream
        )
    }

    func feedInbound(_ data: Data) {
        inboundContinuation.yield(data)
    }

    func waitForOutbound(timeout: TimeInterval = 2.0) async throws -> Data {
        try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask {
                if let next = await self.outboundIterator.next() {
                    return next
                }
                throw NSError(domain: "MockTransport", code: 1, userInfo: nil)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw NSError(domain: "MockTransport", code: 2, userInfo: [NSLocalizedDescriptionKey: "timeout waiting for outbound"])
            }
            defer { group.cancelAll() }
            let first = try await group.next()!
            return first
        }
    }
}
