import Foundation

/// Pigweed-style varint encoding used in HDLC frame addresses.
///
/// Format: each byte's LSB is the "last byte" flag (1 = last, 0 = continue).
/// The upper 7 bits carry value; bytes are ordered little-endian.
///
/// This is NOT the same as protobuf varint (which uses the MSB as the
/// continuation bit). Ported verbatim from libmaestro/src/hdlc/varint.rs.
public enum Varint {
    public enum DecodeError: Error, Equatable {
        case incomplete
        case overflow
    }

    /// Decodes a varint from the beginning of `src`.
    /// Returns the decoded value plus the number of bytes consumed.
    public static func decode(_ src: some Sequence<UInt8>) throws -> (value: UInt32, consumed: Int) {
        var address: UInt64 = 0
        for (i, b) in src.enumerated() {
            address |= UInt64(b >> 1) << (i * 7)
            if address > UInt64(UInt32.max) {
                throw DecodeError.overflow
            }
            if (b & 0x01) == 0x01 {
                return (UInt32(address), i + 1)
            }
        }
        throw DecodeError.incomplete
    }

    /// Encodes `num` into varint bytes appended to `out`.
    public static func encode(_ num: UInt32, into out: inout [UInt8]) {
        var n = num
        while (n >> 7) != 0 {
            out.append(UInt8(n & 0x7F) << 1)
            n >>= 7
        }
        out.append((UInt8(n & 0x7F) << 1) | 0x01)
    }

    public static func encode(_ num: UInt32) -> [UInt8] {
        var out: [UInt8] = []
        encode(num, into: &out)
        return out
    }

    /// Number of bytes needed to encode `value`.
    public static func numBytes(_ value: UInt32) -> Int {
        if value == 0 { return 1 }
        let bits = 32 - value.leadingZeroBitCount
        return (bits + 6) / 7
    }
}
