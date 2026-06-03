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
    /// Guards `openContinuation` so the open-complete delegate, the timeout
    /// child, and a cancellation handler can't double-resume or leak it.
    private let openLock = NSLock()
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
        serviceUUID: [UInt8] = maestroUUIDBytes,
        refreshSDPIfMissing: Bool = true
    ) async throws {
        let sdpUUID = serviceUUID.withUnsafeBufferPointer { ptr in
            IOBluetoothSDPUUID(bytes: ptr.baseAddress!, length: ptr.count)
        }
        var record = device.getServiceRecord(for: sdpUUID)
        if record == nil, refreshSDPIfMissing {
            // The SDP cache can be momentarily empty right after the device
            // (re)connects — notably during a multipoint handoff back from the
            // phone, where the buds re-advertise their services a beat after the
            // ACL link comes up. Rather than failing the whole connect attempt
            // on this transient miss, force a fresh SDP query and poll briefly.
            log.info("open: SDP record missing — forcing SDP refresh and polling")
            _ = device.performSDPQuery(nil)
            for _ in 0..<12 {   // up to ~3s
                try await Task.sleep(nanoseconds: 250_000_000)
                try Task.checkCancellation()
                if let r = device.getServiceRecord(for: sdpUUID) {
                    log.info("open: SDP record appeared after refresh")
                    record = r
                    break
                }
            }
        }
        guard let record else {
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

        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    // Cancellation-safe wait: if this task is cancelled (e.g. a
                    // forced reconnect tears the session down mid-open), the
                    // handler resumes the continuation so the task group can
                    // actually finish. Without this, the continuation would
                    // never resume and `withThrowingTaskGroup` would block
                    // forever waiting on this child — deadlocking teardown.
                    try await withTaskCancellationHandler {
                        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                            self.openLock.lock()
                            if Task.isCancelled {
                                self.openLock.unlock()
                                cont.resume(throwing: CancellationError())
                                return
                            }
                            self.openContinuation = cont
                            self.openLock.unlock()
                        }
                    } onCancel: {
                        self.resolveOpen(.failure(CancellationError()))
                    }
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                    throw RFCOMMOpenError.openCompleteFailed(kIOReturnTimeout)
                }
                defer { group.cancelAll() }
                try await group.next()
            }
        } catch {
            // We created the channel object but never completed the handshake
            // (timeout or cancellation). Release it so IOBluetooth doesn't keep
            // a half-open channel around for the next open to collide with.
            ch.close()
            self.channel = nil
            throw error
        }
    }

    /// Resolve the pending open continuation exactly once. Safe to call from
    /// the open-complete delegate, the channel-closed delegate, and the
    /// cancellation handler concurrently — the lock guarantees a single resume.
    private func resolveOpen(_ result: Result<Void, Error>) {
        openLock.lock()
        let cont = openContinuation
        openContinuation = nil
        openLock.unlock()
        cont?.resume(with: result)
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

    /// Upper bound on a single `write`. `writeSync` is a blocking IOBluetooth
    /// call that has been observed to hang for >60s when the RFCOMM link goes
    /// half-dead (multipoint focus moving to the phone: the channel still
    /// reports "open" but writes never drain). Normal writes complete in well
    /// under 100ms, so this only ever trips on a wedged link.
    private static let writeTimeout: TimeInterval = 5.0

    private func write(_ data: Data) async throws {
        guard let channel = self.channel else {
            throw RFCOMMOpenError.channelLost
        }
        let mtu = Int(channel.getMTU())
        let chunkSize = mtu > 0 ? mtu : 512

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { [weak self] in
                guard let self else { throw RFCOMMOpenError.channelLost }
                try await self.rawWrite(data, on: channel, chunkSize: chunkSize)
            }
            group.addTask { [weak self] in
                try await Task.sleep(nanoseconds: UInt64(Self.writeTimeout * 1_000_000_000))
                // The write is wedged on a half-dead link. Closing the channel
                // aborts the stuck `writeSync` and tears the session down so the
                // session driver reconnects on a fresh channel — the same
                // recovery a manual Reconnect performs, but automatic.
                log.error("write: timed out after \(Self.writeTimeout, format: .fixed(precision: 0))s — link wedged, closing channel")
                await self?.close()
                throw NSError(
                    domain: "RFCOMMTransport", code: Int(kIOReturnTimeout),
                    userInfo: [NSLocalizedDescriptionKey: "RFCOMM write timed out — link wedged"]
                )
            }
            defer { group.cancelAll() }
            try await group.next()
        }
    }

    /// One cancellation-aware chunked write. The continuation resumes when
    /// `writeSync` finishes on the write queue, OR immediately if the task is
    /// cancelled — so a cancelled/timed-out write can't leave a parent task
    /// group hanging on a `writeSync` that may block for a very long time.
    private func rawWrite(
        _ data: Data,
        on channel: IOBluetoothRFCOMMChannel,
        chunkSize: Int
    ) async throws {
        let box = WriteContinuationBox()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                box.store(cont)
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
                            box.resume(.failure(NSError(
                                domain: "RFCOMMTransport", code: Int(r),
                                userInfo: [NSLocalizedDescriptionKey: "writeSync failed: \(ioReturnString(r))"]
                            )))
                            return
                        }
                        offset = end
                    }
                    box.resume(.success(()))
                }
            }
        } onCancel: {
            box.resume(.failure(CancellationError()))
        }
    }

    // MARK: IOBluetoothRFCOMMChannelDelegate

    public func rfcommChannelOpenComplete(
        _ rfcommChannel: IOBluetoothRFCOMMChannel!,
        status error: IOReturn
    ) {
        if error == kIOReturnSuccess {
            log.info("rfcommChannelOpenComplete: ok")
            resolveOpen(.success(()))
        } else {
            log.error("rfcommChannelOpenComplete: \(ioReturnString(error), privacy: .public)")
            resolveOpen(.failure(RFCOMMOpenError.openCompleteFailed(error)))
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
        // If the channel closed while an open was still in flight, unblock the
        // opener instead of letting it wait out the full timeout.
        resolveOpen(.failure(RFCOMMOpenError.channelLost))
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

/// Thread-safe one-shot box for a write continuation. The write-queue callback
/// (writeSync finished) and the cancellation handler can race; the lock makes
/// sure the continuation is resumed exactly once, and storing it after a
/// cancellation has already fired resumes it immediately.
private final class WriteContinuationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var cont: CheckedContinuation<Void, Error>?
    private var pending: Result<Void, Error>?
    private var done = false

    func store(_ c: CheckedContinuation<Void, Error>) {
        lock.lock()
        if done { lock.unlock(); return }
        if let pending {
            self.pending = nil
            done = true
            lock.unlock()
            c.resume(with: pending)
            return
        }
        cont = c
        lock.unlock()
    }

    func resume(_ result: Result<Void, Error>) {
        lock.lock()
        if done { lock.unlock(); return }
        if let c = cont {
            cont = nil
            done = true
            lock.unlock()
            c.resume(with: result)
        } else {
            // Cancelled/finished before the continuation was stored — stash the
            // result so `store` resumes immediately when it arrives.
            pending = result
            lock.unlock()
        }
    }
}
