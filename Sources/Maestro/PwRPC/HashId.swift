import Foundation

/// Pigweed RPC uses a 65599-multiplier rolling hash on service and method
/// names to produce the 32-bit service_id / method_id fields of an RpcPacket.
///
/// Ported verbatim from libmaestro/src/pwrpc/id.rs::hash_65599.
public enum PigweedHash {
    public static func hash(_ id: String) -> UInt32 {
        var h: UInt32 = UInt32(id.unicodeScalars.count)
        var coef: UInt32 = 65599
        for scalar in id.unicodeScalars {
            h = h &+ coef &* UInt32(scalar.value)
            coef = coef &* 65599
        }
        return h
    }
}

/// A fully-qualified RPC path in the form `"package.Service/Method"`.
public struct RpcPath: Hashable, Sendable {
    public let service: String
    public let method: String

    public init(service: String, method: String) {
        self.service = service
        self.method = method
    }

    public init(_ fullyQualified: String) {
        if let slash = fullyQualified.lastIndex(of: "/") {
            self.service = String(fullyQualified[..<slash])
            self.method = String(fullyQualified[fullyQualified.index(after: slash)...])
        } else {
            self.service = fullyQualified
            self.method = ""
        }
    }

    public var serviceHash: UInt32 { PigweedHash.hash(service) }
    public var methodHash: UInt32 { PigweedHash.hash(method) }
}
