import Foundation
import OSLog
// IOBluetooth's Objective-C types are not annotated as `Sendable`. The
// channel we hand to a background queue is safe in practice (we never touch
// it from outside the writer/delegate), so we silence the Sendable warning
// at the import boundary rather than littering the code with @unchecked.
@preconcurrency import IOBluetooth
@_exported import Maestro

private let log = Logger(subsystem: "com.kshmlg.PixelBudsBar", category: "rfcomm")

public let maestroUUIDBytes: [UInt8] = [
    0x25, 0xe9, 0x7f, 0xf7,
    0x24, 0xce,
    0x4c, 0x4c,
    0x89, 0x51,
    0xf7, 0x64, 0xa7, 0x08, 0xf7, 0xb5,
]

public enum RFCOMMOpenError: Error, CustomStringConvertible {
    case noServiceRecord
    case noRFCOMMChannelID(IOReturn)
    case openCallFailed(IOReturn)
    case openCompleteFailed(IOReturn)
    case channelLost

    public var description: String {
        switch self {
        case .noServiceRecord: return "Maestro SDP service record not found on device"
        case .noRFCOMMChannelID(let r): return "getRFCOMMChannelID returned \(ioReturnString(r))"
        case .openCallFailed(let r): return "openRFCOMMChannelAsync returned \(ioReturnString(r))"
        case .openCompleteFailed(let r): return "rfcommChannelOpenComplete reported \(ioReturnString(r))"
        case .channelLost: return "channel pointer was not populated"
        }
    }
}

public func ioReturnString(_ r: IOReturn) -> String {
    String(format: "0x%08X", UInt32(bitPattern: r))
}

/// Bridges IOBluetoothRFCOMMChannel into a MaestroTransport.
/// Acts as the channel's delegate from the moment of opening so we get
/// openComplete + data callbacks immediately. Construct via `open(on:)`.
public final class RFCOMMTransportAdapter: NSObject, IOBluetoothRFCOMMChannelDelegate, @unchecked Sendable {
    private var channel: IOBluetoothRFCOMMChannel?
    private let inboundContinuation: AsyncStream<Data>.Continuation
    private let inboundStream: AsyncStream<Data>
    private var openContinuation: CheckedContinuation<Void, Error>?
    private var closeContinuation: CheckedContinuation<Void, Never>?
    /// Dedicated serial queue so concurrent send() invocations from the actor
    /// don't race writeSync (IOBluetoothRFCOMMChannel is not thread-safe).
    private let writeQueue = DispatchQueue(label: "RFCOMMTransport.write", qos: .userInitiated)

    public override init() {
        var cont: AsyncStream<Data>.Continuation!
        self.inboundStream = AsyncStream<Data>(bufferingPolicy: .unbounded) { c in cont = c }
        self.inboundContinuation = cont
        super.init()
    }

    /// Opens an RFCOMM channel on the given device with self as the delegate.
    /// `serviceUUID` defaults to Maestro; callers wanting GFPS (or another
    /// service) pass that UUID's 16 bytes instead — the adapter itself is
    /// service-agnostic, only the framing layered on top differs.
    /// Returns once `rfcommChannelOpenComplete` fires successfully, or throws on timeout.
    public func open(
        on device: IOBluetoothDevice,
        timeout seconds: TimeInterval = 10.0,
        serviceUUID: [UInt8] = maestroUUIDBytes
    ) async throws {
        let sdpUUID = serviceUUID.withUnsafeBufferPointer { ptr in
            IOBluetoothSDPUUID(bytes: ptr.baseAddress!, length: ptr.count)
        }
        guard let record = device.getServiceRecord(for: sdpUUID) else {
            log.error("open: no SDP record for service UUID")
            throw RFCOMMOpenError.noServiceRecord
        }

        var channelID: BluetoothRFCOMMChannelID = 0
        let chResult = record.getRFCOMMChannelID(&channelID)
        guard chResult == kIOReturnSuccess else {
            log.error("open: getRFCOMMChannelID \(ioReturnString(chResult), privacy: .public)")
            throw RFCOMMOpenError.noRFCOMMChannelID(chResult)
        }

        log.debug("open: opening RFCOMM channel \(channelID) on \(device.addressString ?? "?", privacy: .public)")
        var ch: IOBluetoothRFCOMMChannel?
        let openResult = device.openRFCOMMChannelAsync(
            &ch,
            withChannelID: channelID,
            delegate: self
        )
        guard openResult == kIOReturnSuccess else {
            log.error("open: openRFCOMMChannelAsync \(ioReturnString(openResult), privacy: .public)")
            throw RFCOMMOpenError.openCallFailed(openResult)
        }
        guard let ch else {
            log.error("open: channel pointer not populated after openRFCOMMChannelAsync")
            throw RFCOMMOpenError.channelLost
        }
        self.channel = ch

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                    self.openContinuation = cont
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw RFCOMMOpenError.openCompleteFailed(kIOReturnTimeout)
            }
            defer { group.cancelAll() }
            try await group.next()
        }
    }

    /// Closes the underlying RFCOMM channel and waits for IOBluetooth to
    /// actually release it (via the `rfcommChannelClosed` delegate) before
    /// returning. Without this await, a fast popover reopen would race the
    /// async release and the next openRFCOMMChannelAsync would hang.
    /// Safe to call multiple times.
    public func close() async {
        guard let ch = channel else { return }
        log.debug("close(): closing RFCOMM channel")
        channel = nil

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            closeContinuation = cont
            let r = ch.close()
            if r != kIOReturnSuccess {
                // Synchronous failure — no delegate will fire.
                resolveCloseIfPending()
            }
            // Safety timeout: delegate normally fires within <100ms.
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                self?.resolveCloseIfPending()
            }
        }

        inboundContinuation.finish()
    }

    private func resolveCloseIfPending() {
        guard let cont = closeContinuation else { return }
        closeContinuation = nil
        cont.resume()
    }

    public var transport: MaestroTransport {
        let stream = inboundStream
        let writer: @Sendable (Data) async throws -> Void = { [weak self] data in
            guard let self else { throw RFCOMMOpenError.channelLost }
            try await self.write(data)
        }
        return MaestroTransport(send: writer, inbound: stream)
    }

    private func write(_ data: Data) async throws {
        guard let channel = self.channel else {
            throw RFCOMMOpenError.channelLost
        }
        let mtu = Int(channel.getMTU())
        let chunkSize = mtu > 0 ? mtu : 512
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            writeQueue.async { [channel] in
                var offset = 0
                while offset < data.count {
                    let end = min(offset + chunkSize, data.count)
                    let slice = data[offset..<end]
                    let r: IOReturn = slice.withUnsafeBytes { raw -> IOReturn in
                        guard let base = raw.baseAddress else { return kIOReturnInternalError }
                        let mutable = UnsafeMutableRawPointer(mutating: base)
                        return channel.writeSync(mutable, length: UInt16(slice.count))
                    }
                    if r != kIOReturnSuccess {
                        log.error("writeSync failed: \(ioReturnString(r), privacy: .public) offset=\(offset) chunkSize=\(slice.count)")
                        cont.resume(throwing: NSError(
                            domain: "RFCOMMTransport", code: Int(r),
                            userInfo: [NSLocalizedDescriptionKey: "writeSync failed: \(ioReturnString(r))"]
                        ))
                        return
                    }
                    offset = end
                }
                cont.resume()
            }
        }
    }

    // MARK: IOBluetoothRFCOMMChannelDelegate

    public func rfcommChannelOpenComplete(
        _ rfcommChannel: IOBluetoothRFCOMMChannel!,
        status error: IOReturn
    ) {
        let cont = openContinuation
        openContinuation = nil
        guard let cont else { return }
        if error == kIOReturnSuccess {
            log.info("rfcommChannelOpenComplete: ok")
            cont.resume()
        } else {
            log.error("rfcommChannelOpenComplete: \(ioReturnString(error), privacy: .public)")
            cont.resume(throwing: RFCOMMOpenError.openCompleteFailed(error))
        }
    }

    public func rfcommChannelData(
        _ rfcommChannel: IOBluetoothRFCOMMChannel!,
        data dataPointer: UnsafeMutableRawPointer!,
        length dataLength: Int
    ) {
        inboundContinuation.yield(Data(bytes: dataPointer, count: dataLength))
    }

    public func rfcommChannelClosed(_ rfcommChannel: IOBluetoothRFCOMMChannel!) {
        log.info("rfcommChannelClosed: peer closed or link dropped")
        // Clear the channel ref so any pending writes throw a clean
        // `.channelLost` instead of hitting writeSync on a dead handle
        // (IOBluetooth returns 0xE00002CD / kIOReturnNotOpen in that case).
        channel = nil
        inboundContinuation.finish()
        resolveCloseIfPending()
    }

    public func rfcommChannelControlSignalsChanged(_ rfcommChannel: IOBluetoothRFCOMMChannel!) {}
    public func rfcommChannelFlowControlChanged(_ rfcommChannel: IOBluetoothRFCOMMChannel!) {}
    public func rfcommChannelWriteComplete(
        _ rfcommChannel: IOBluetoothRFCOMMChannel!,
        refcon: UnsafeMutableRawPointer!,
        status error: IOReturn
    ) {}
    public func rfcommChannelQueueSpaceAvailable(_ rfcommChannel: IOBluetoothRFCOMMChannel!) {}
}
