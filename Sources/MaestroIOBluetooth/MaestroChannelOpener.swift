import Foundation
import IOBluetooth

public enum MaestroChannelOpener {
    public static func findFirstPairedBuds() -> IOBluetoothDevice? {
        let paired = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
        return paired.first { d in
            let cod = UInt32(d.classOfDevice)
            let nameOK = (d.name ?? "").lowercased().contains("pixel buds")
            return (cod == 0x240404 || cod == 0x244404) && nameOK
        }
    }
}
