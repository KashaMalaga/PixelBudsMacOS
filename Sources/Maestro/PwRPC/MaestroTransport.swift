import Foundation

/// A bidirectional byte transport, typically backed by an RFCOMM channel.
/// The connection layer reads chunks of bytes from `inbound` and writes
/// HDLC-framed packets via `send`.
public struct MaestroTransport: Sendable {
    public let send: @Sendable (Data) async throws -> Void
    public let inbound: AsyncStream<Data>

    public init(
        send: @Sendable @escaping (Data) async throws -> Void,
        inbound: AsyncStream<Data>
    ) {
        self.send = send
        self.inbound = inbound
    }
}
