import Foundation

/// HDLC frame as used by the Maestro protocol.
///
/// Wire format:
/// ```
/// 0x7e flag │ varint address │ control (1 byte) │ data │ CRC-32 LE (4 bytes) │ 0x7e flag
/// ```
/// Inside the frame body, bytes `0x7e` and `0x7d` are byte-stuffed:
/// `0x7e` → `0x7d 0x5e`, `0x7d` → `0x7d 0x5d`.
public struct HDLCFrame: Equatable {
    public var address: UInt32
    public var control: UInt8
    public var data: Data

    public init(address: UInt32, control: UInt8, data: Data) {
        self.address = address
        self.control = control
        self.data = data
    }
}

public enum HDLCConsts {
    public static let frameFlag: UInt8 = 0x7E
    public static let escapeFlag: UInt8 = 0x7D
    public static let escapeMask: UInt8 = 0x20
    public static let unnumberedControl: UInt8 = 0x03
}
