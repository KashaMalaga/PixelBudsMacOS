import Foundation
import OSLog
import SwiftProtobuf

private let log = Logger(subsystem: "com.kshmlg.PixelBudsBar", category: "rpc")

/// Manages an active RPC session over an HDLC-framed transport. Routes
/// inbound RpcPackets to outstanding unary calls and server-stream
/// subscriptions identified by (channelID, serviceHash, methodHash, callID).
///
/// Usage:
/// ```swift
/// let conn = RpcConnection(transport: t)
/// await conn.start()
/// let channel = try await conn.resolveChannel()
/// let payload = try await conn.unary(channel: channel, path: ..., request: ...)
/// ```
public actor RpcConnection {
    private let transport: MaestroTransport
    private let decoder = HDLCDecoder()
    private var readerTask: Task<Void, Never>?
    private let sessionStartCallID: UInt32
    private var nextCallID: UInt32

    public init(transport: MaestroTransport) {
        self.transport = transport
        let start = UInt32.random(in: 1...1_000_000)
        self.sessionStartCallID = start
        self.nextCallID = start
    }

    private struct CallKey: Hashable {
        let channelID: UInt32
        let serviceID: UInt32
        let methodID: UInt32
        let callID: UInt32
    }

    private var unaryWaiters: [CallKey: CheckedContinuation<Data, Error>] = [:]
    private var streamContinuations: [CallKey: AsyncThrowingStream<Data, Error>.Continuation] = [:]
    private var stopped = false

    public func start() {
        guard readerTask == nil else { return }
        readerTask = Task { [weak self] in
            guard let self else { return }
            await self.readLoop()
        }
    }

    public func stop() {
        stopped = true
        readerTask?.cancel()
        readerTask = nil
        for (_, c) in unaryWaiters { c.resume(throwing: RpcError.transportClosed) }
        unaryWaiters.removeAll()
        for (_, c) in streamContinuations { c.finish(throwing: RpcError.transportClosed) }
        streamContinuations.removeAll()
    }

    // MARK: - Public API

    public func unary(
        channel: UInt32,
        path: RpcPath,
        request: some Message
    ) async throws -> Data {
        try await assertStarted()
        let callID = allocateCallID()
        let key = CallKey(
            channelID: channel,
            serviceID: path.serviceHash,
            methodID: path.methodHash,
            callID: callID
        )
        log.debug("→ unary \(path.method, privacy: .public) ch=\(channel) callID=\(callID)")
        try await sendRequest(key: key, type: .request, payload: try request.serializedData())

        // CheckedContinuation does not respond to task cancellation on its own.
        // Wrap it in a cancellation handler that fails the waiter so a cancelled
        // caller doesn't leave the actor with a dangling continuation that would
        // make a parent TaskGroup hang on tear-down.
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
                unaryWaiters[key] = cont
            }
        } onCancel: { [weak self] in
            guard let self else { return }
            Task { await self.cancelUnaryWaiter(key) }
        }
    }

    private func cancelUnaryWaiter(_ key: CallKey) {
        if let cont = unaryWaiters.removeValue(forKey: key) {
            cont.resume(throwing: CancellationError())
        }
    }

    public func serverStream(
        channel: UInt32,
        path: RpcPath,
        request: some Message
    ) async throws -> AsyncThrowingStream<Data, Error> {
        try await assertStarted()
        let callID = allocateCallID()
        let key = CallKey(
            channelID: channel,
            serviceID: path.serviceHash,
            methodID: path.methodHash,
            callID: callID
        )
        log.debug("→ serverStream \(path.method, privacy: .public) ch=\(channel) callID=\(callID)")

        return AsyncThrowingStream<Data, Error> { continuation in
            streamContinuations[key] = continuation
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                Task { await self.cancelStream(key: key) }
            }
            Task {
                do {
                    try await self.sendRequest(
                        key: key,
                        type: .request,
                        payload: try request.serializedData()
                    )
                } catch {
                    continuation.finish(throwing: error)
                    self.streamContinuations.removeValue(forKey: key)
                }
            }
        }
    }

    // MARK: - Internals

    private func assertStarted() async throws {
        guard readerTask != nil, !stopped else { throw RpcError.notStarted }
    }

    private func allocateCallID() -> UInt32 {
        defer { nextCallID = (nextCallID == UInt32.max - 1) ? 1 : nextCallID + 1 }
        return nextCallID
    }

    private func sendRequest(
        key: CallKey,
        type: Pw_Rpc_Packet_PacketType,
        payload: Data
    ) async throws {
        var packet = Pw_Rpc_Packet_RpcPacket()
        packet.type = type
        packet.channelID = key.channelID
        packet.serviceID = key.serviceID
        packet.methodID = key.methodID
        packet.callID = key.callID
        packet.payload = payload

        guard let address = MaestroChannel.address(for: key.channelID) else {
            throw RpcError.unknownChannel(key.channelID)
        }
        let rpcBytes = try packet.serializedData()
        let frame = HDLCFrame(
            address: address.value,
            control: HDLCConsts.unnumberedControl,
            data: rpcBytes
        )
        let encoded = HDLCEncoder.encode(frame)
        try await transport.send(encoded)
    }

    private func cancelStream(key: CallKey) {
        guard streamContinuations.removeValue(forKey: key) != nil else { return }
        log.debug("cancelStream callID=\(key.callID)")
        Task {
            try? await sendRequest(key: key, type: .clientStreamEnd, payload: Data())
        }
    }

    private func readLoop() async {
        let stream = transport.inbound
        for await chunk in stream {
            if Task.isCancelled || stopped { break }
            decoder.process(chunk) { frame in
                Task { await self.handleFrame(frame) }
            } onError: { err in
                // HDLC errors are non-fatal; we resync at the next flag.
                _ = err
            }
        }
        closeAll()
    }

    private func handleFrame(_ frame: HDLCFrame) async {
        let packet: Pw_Rpc_Packet_RpcPacket
        do {
            packet = try Pw_Rpc_Packet_RpcPacket(serializedBytes: frame.data)
        } catch {
            return
        }

        // Packets whose callID pre-dates this session are buffered leftovers
        // from the previous RFCOMM connection (the firmware sends a final
        // response when it closes a subscription). Silently drop them — they
        // can never match an outstanding waiter and logging them as warnings
        // produces confusing noise in the Console.
        if packet.callID < sessionStartCallID {
            log.debug("dropping ghost packet callID=\(packet.callID) type=\(packet.type.rawValue) from previous session")
            return
        }

        let key = CallKey(
            channelID: packet.channelID,
            serviceID: packet.serviceID,
            methodID: packet.methodID,
            callID: packet.callID
        )

        switch packet.type {
        case .response:
            if let cont = unaryWaiters.removeValue(forKey: key) {
                if packet.status == 0 {
                    log.debug("← response callID=\(packet.callID) ok bytes=\(packet.payload.count)")
                    cont.resume(returning: packet.payload)
                } else {
                    log.error("← response callID=\(packet.callID) status=\(packet.status)")
                    cont.resume(throwing: RpcError.serverError(status: packet.status))
                }
            } else if let stream = streamContinuations.removeValue(forKey: key) {
                // RESPONSE on a server-streaming call signals end-of-stream.
                if packet.status == 0 {
                    log.debug("← stream-end callID=\(packet.callID) ok")
                    stream.finish()
                } else {
                    log.error("← stream-end callID=\(packet.callID) status=\(packet.status)")
                    stream.finish(throwing: RpcError.streamEnded(status: packet.status))
                }
            } else {
                log.warning("← response callID=\(packet.callID) status=\(packet.status) — no waiter")
            }

        case .serverStream:
            if let stream = streamContinuations[key] {
                log.debug("← serverStream callID=\(packet.callID) bytes=\(packet.payload.count)")
                stream.yield(packet.payload)
            } else {
                log.warning("← serverStream callID=\(packet.callID) — no continuation (leaked stream?)")
            }

        case .serverError:
            log.error("← serverError callID=\(packet.callID) status=\(packet.status)")
            if let cont = unaryWaiters.removeValue(forKey: key) {
                cont.resume(throwing: RpcError.serverError(status: packet.status))
            } else if let stream = streamContinuations.removeValue(forKey: key) {
                stream.finish(throwing: RpcError.serverError(status: packet.status))
            }

        default:
            // Client-originated types should never arrive here; ignore.
            break
        }
    }

    private func closeAll() {
        log.debug("closeAll: draining \(self.unaryWaiters.count) waiters, \(self.streamContinuations.count) streams")
        for (_, c) in unaryWaiters { c.resume(throwing: RpcError.transportClosed) }
        unaryWaiters.removeAll()
        for (_, c) in streamContinuations { c.finish(throwing: RpcError.transportClosed) }
        streamContinuations.removeAll()
    }
}
