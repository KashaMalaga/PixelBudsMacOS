import Foundation

/// Logical peers inside the Pixel Buds. Used to build HDLC frame addresses.
/// Ported from libmaestro/src/protocol/addr.rs.
public enum MaestroPeer: UInt8, Sendable, CaseIterable {
    case unknown        = 0
    case host           = 1
    case `case`         = 2
    case leftBtCore     = 3
    case rightBtCore    = 4
    case leftSensorHub  = 5
    case rightSensorHub = 6
    case leftSpiBridge  = 7
    case rightSpiBridge = 8
    case debugApp       = 9
    case maestroA       = 10
    case leftTahiti     = 11
    case rightTahiti    = 12
    case maestroB       = 13
}

/// A 32-bit HDLC frame address. Source and target peers live in fixed bit
/// positions inside the value.
public struct MaestroAddress: Equatable, Sendable {
    public let value: UInt32

    public init(value: UInt32) {
        self.value = value
    }

    public init(source: MaestroPeer, target: MaestroPeer) {
        let s = UInt32(source.rawValue) & 0xF
        let t = UInt32(target.rawValue) & 0xF
        self.value = (s << 6) | (t << 10)
    }

    public var source: MaestroPeer {
        MaestroPeer(rawValue: UInt8((value >> 6) & 0xF)) ?? .unknown
    }

    public var target: MaestroPeer {
        MaestroPeer(rawValue: UInt8((value >> 10) & 0xF)) ?? .unknown
    }

    /// Reverses source and target — useful when responding to a frame.
    public func swapped() -> MaestroAddress {
        MaestroAddress(source: target, target: source)
    }

    /// Returns the Pigweed RPC channel ID associated with this frame address,
    /// or nil if the peer pair is not a known Maestro channel.
    public var channelID: UInt32? {
        if source == .maestroA || source == .maestroB {
            return MaestroChannel.id(local: source, remote: target)
        } else {
            return MaestroChannel.id(local: target, remote: source)
        }
    }
}

/// Mapping between Pigweed RPC channel IDs and (Maestro, peer) pairs.
public enum MaestroChannel {
    /// All known Maestro channel IDs that we should probe when resolving the
    /// active route to a connected device. Sensor hubs are excluded — they
    /// don't respond to GetSoftwareInfo.
    public static let candidateIDs: [UInt32] = [18, 19, 21, 23, 24, 26]

    /// Channel ID for the given (local Maestro, remote peer) pair, or nil.
    public static func id(local: MaestroPeer, remote: MaestroPeer) -> UInt32? {
        switch (local, remote) {
        case (.maestroA, .case):           return 18
        case (.maestroA, .leftBtCore):     return 19
        case (.maestroA, .leftSensorHub):  return 20
        case (.maestroA, .rightBtCore):    return 21
        case (.maestroA, .rightSensorHub): return 22
        case (.maestroB, .case):           return 23
        case (.maestroB, .leftBtCore):     return 24
        case (.maestroB, .leftSensorHub):  return 25
        case (.maestroB, .rightBtCore):    return 26
        case (.maestroB, .rightSensorHub): return 27
        default: return nil
        }
    }

    /// Returns the alternative bud channel for the given channel, mapping Left <-> Right buds.
    public static func alternativeBudChannel(for channel: UInt32) -> UInt32? {
        switch channel {
        case 19: return 21
        case 21: return 19
        case 24: return 26
        case 26: return 24
        default: return nil
        }
    }

    /// The 32-bit HDLC frame address for an outbound packet on the given channel.
    public static func address(for channel: UInt32) -> MaestroAddress? {
        switch channel {
        case 18: return MaestroAddress(source: .maestroA, target: .case)
        case 19: return MaestroAddress(source: .maestroA, target: .leftBtCore)
        case 20: return MaestroAddress(source: .maestroA, target: .leftSensorHub)
        case 21: return MaestroAddress(source: .maestroA, target: .rightBtCore)
        case 22: return MaestroAddress(source: .maestroA, target: .rightSensorHub)
        case 23: return MaestroAddress(source: .maestroB, target: .case)
        case 24: return MaestroAddress(source: .maestroB, target: .leftBtCore)
        case 25: return MaestroAddress(source: .maestroB, target: .leftSensorHub)
        case 26: return MaestroAddress(source: .maestroB, target: .rightBtCore)
        case 27: return MaestroAddress(source: .maestroB, target: .rightSensorHub)
        default: return nil
        }
    }
}
