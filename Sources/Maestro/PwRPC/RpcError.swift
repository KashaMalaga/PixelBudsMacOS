import Foundation

public enum RpcError: Error, CustomStringConvertible {
    case transportClosed
    case hdlcDecodeError(HDLCDecoder.DecodeError)
    case protobufDecodeError(Error)
    case unknownChannel(UInt32)
    case serverError(status: UInt32)
    case streamEnded(status: UInt32)
    case channelResolutionFailed
    case notStarted

    public var description: String {
        switch self {
        case .transportClosed: return "transport closed"
        case .hdlcDecodeError(let e): return "HDLC decode error: \(e)"
        case .protobufDecodeError(let e): return "protobuf decode error: \(e)"
        case .unknownChannel(let c): return "received packet for unknown channel \(c)"
        case .serverError(let s): return "server error: \(Self.statusName(s))"
        case .streamEnded(let s): return "stream ended: \(Self.statusName(s))"
        case .channelResolutionFailed: return "no Maestro channel responded to GetSoftwareInfo"
        case .notStarted: return "connection has not been started"
        }
    }

    /// Maps Pigweed RPC status codes (gRPC-compatible) to friendly names.
    private static func statusName(_ status: UInt32) -> String {
        switch status {
        case 0: return "ok"
        case 1: return "cancelled"
        case 2: return "unknown — possibly not readable on this firmware"
        case 3: return "invalid argument"
        case 4: return "deadline exceeded"
        case 5: return "not found"
        case 6: return "already exists"
        case 7: return "permission denied"
        case 8: return "resource exhausted"
        case 9: return "not allowed in current state — try with the buds in your ears or check that prerequisites are met"
        case 10: return "aborted"
        case 11: return "out of range"
        case 12: return "unimplemented — this firmware doesn't support this setting"
        case 13: return "internal device error"
        case 14: return "buds unavailable"
        case 15: return "data loss"
        case 16: return "unauthenticated"
        default: return "status \(status)"
        }
    }
}
