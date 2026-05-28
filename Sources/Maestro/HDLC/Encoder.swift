import Foundation

public enum HDLCEncoder {
    /// Encode a frame to its on-the-wire byte sequence (including outer flags).
    public static func encode(_ frame: HDLCFrame) -> Data {
        var raw: [UInt8] = []
        raw.reserveCapacity(frame.data.count + 8)
        Varint.encode(frame.address, into: &raw)
        raw.append(frame.control)
        raw.append(contentsOf: frame.data)

        let crc = CRC32.compute(raw)
        raw.append(UInt8(truncatingIfNeeded: crc))
        raw.append(UInt8(truncatingIfNeeded: crc >> 8))
        raw.append(UInt8(truncatingIfNeeded: crc >> 16))
        raw.append(UInt8(truncatingIfNeeded: crc >> 24))

        var out = Data()
        out.reserveCapacity(raw.count + 2)
        out.append(HDLCConsts.frameFlag)
        for b in raw {
            switch b {
            case HDLCConsts.frameFlag, HDLCConsts.escapeFlag:
                out.append(HDLCConsts.escapeFlag)
                out.append(b ^ HDLCConsts.escapeMask)
            default:
                out.append(b)
            }
        }
        out.append(HDLCConsts.frameFlag)
        return out
    }
}
