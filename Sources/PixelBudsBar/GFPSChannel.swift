import Foundation
import IOBluetooth
import MaestroIOBluetooth

/// SDP service UUID for Google Fast Pair's Message Stream RFCOMM service.
/// See https://developers.google.com/nearby/fast-pair/specifications/extensions/messagestream
public let gfpsUUIDBytes: [UInt8] = [
    0xdf, 0x21, 0xfe, 0x2c,
    0x25, 0x15,
    0x4f, 0xdb,
    0x88, 0x86,
    0xf1, 0x2c, 0x4d, 0x67, 0x92, 0x7c,
]

/// Wraps the RFCOMM channel that carries Google Fast Pair "Message Stream"
/// frames. Today we only care about sending the Ring command — battery and
/// ANC events come over Maestro already, so the inbound stream is drained
/// silently to keep the channel healthy.
///
/// Frame format:
///   | group (1B) | code (1B) | length (2B BE) | data (length B) |
final class GFPSChannel {
    /// Which earbud(s) should beep. The byte values are wire-format and
    /// must match the GFPS spec exactly.
    enum RingTarget: UInt8 {
        case stop  = 0x00
        case right = 0x01
        case left  = 0x02
        case both  = 0x03
    }

    enum GFPSError: Error, CustomStringConvertible {
        case transportClosed

        var description: String {
            switch self {
            case .transportClosed: return "GFPS channel is closed"
            }
        }
    }

    private let adapter: RFCOMMTransportAdapter
    private let drainTask: Task<Void, Never>

    private init(adapter: RFCOMMTransportAdapter) {
        self.adapter = adapter
        // We don't act on inbound frames (battery/ANC come over Maestro), but
        // we MUST drain the AsyncStream or the channel back-pressures and
        // eventually stalls. A detached task is fine — it ends when the
        // adapter closes (stream finishes), which doubles as our close signal.
        let inbound = adapter.transport.inbound
        self.drainTask = Task.detached {
            for await _ in inbound { /* discard */ }
        }
    }

    /// Suspends until the channel finishes (peer-initiated close, transport
    /// error, or our own `close()`). Use to drive UI updates when the buds
    /// drop the GFPS channel mid-session, e.g. on case re-seat.
    func whenClosed() async {
        _ = await drainTask.value
    }

    /// Best-effort opener. Returns `nil` if the device doesn't advertise the
    /// GFPS service or the channel can't be opened — the rest of the app
    /// should keep working in that case (Maestro covers everything else).
    static func open(on device: IOBluetoothDevice, timeout: TimeInterval = 5.0) async -> GFPSChannel? {
        let adapter = RFCOMMTransportAdapter()
        do {
            try await adapter.open(on: device, timeout: timeout, serviceUUID: gfpsUUIDBytes)
            return GFPSChannel(adapter: adapter)
        } catch {
            // Either no SDP record or the channel refused — that's fine,
            // Ring just won't be available.
            await adapter.close()
            return nil
        }
    }

    func close() async {
        drainTask.cancel()
        await adapter.close()
    }

    /// Send a Ring command. Group 0x04 (Device Action), Code 0x01 (Ring),
    /// 1-byte payload selecting the target.
    func ring(_ target: RingTarget) async throws {
        try await sendMessage(group: 0x04, code: 0x01, payload: Data([target.rawValue]))
    }

    private func sendMessage(group: UInt8, code: UInt8, payload: Data) async throws {
        var frame = Data(capacity: 4 + payload.count)
        frame.append(group)
        frame.append(code)
        // 2-byte big-endian length.
        let length = UInt16(payload.count)
        frame.append(UInt8((length >> 8) & 0xff))
        frame.append(UInt8(length & 0xff))
        frame.append(payload)
        try await adapter.transport.send(frame)
    }
}
