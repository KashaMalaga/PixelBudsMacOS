import Foundation
import IOBluetooth

enum BudsModel: CustomStringConvertible {
    case pixelBudsPro1
    case pixelBudsPro2
    case unknownByName

    static func detect(from device: IOBluetoothDevice) -> BudsModel? {
        let cod = UInt32(device.classOfDevice)
        let name = (device.name ?? "").lowercased()
        let nameMatches = name.contains("pixel buds")

        switch (cod, nameMatches) {
        case (0x244404, _):
            return .pixelBudsPro2
        case (0x240404, true):
            return .pixelBudsPro1
        case (_, true):
            return .unknownByName
        default:
            return nil
        }
    }

    var description: String {
        switch self {
        case .pixelBudsPro1: return "Pixel Buds Pro (Gen 1)"
        case .pixelBudsPro2: return "Pixel Buds Pro (Gen 2)"
        case .unknownByName: return "Pixel Buds (unknown variant — matched by name only)"
        }
    }
}

struct DiscoveredBuds {
    let device: IOBluetoothDevice
    let model: BudsModel
}

enum DeviceFinder {
    static func findPairedBuds() -> [DiscoveredBuds] {
        let paired = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
        let matches = paired.compactMap { d -> DiscoveredBuds? in
            guard let model = BudsModel.detect(from: d) else { return nil }
            return DiscoveredBuds(device: d, model: model)
        }
        return matches.sorted { lhs, rhs in
            if lhs.device.isConnected() != rhs.device.isConnected() {
                return lhs.device.isConnected()
            }
            return (lhs.device.name ?? "") < (rhs.device.name ?? "")
        }
    }

    static func allPaired() -> [IOBluetoothDevice] {
        (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
    }
}
