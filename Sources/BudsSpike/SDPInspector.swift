import Foundation
import IOBluetooth

enum SDPInspector {
    static func dumpServices(of device: IOBluetoothDevice) {
        guard let records = device.services as? [IOBluetoothSDPServiceRecord], !records.isEmpty else {
            log("  (no SDP service records cached on this device)")
            return
        }
        log("  SDP service records on \(device.name ?? "?") (\(records.count) total):")
        for (i, record) in records.enumerated() {
            describeRecord(record, index: i)
        }
    }

    static func describeRecord(_ record: IOBluetoothSDPServiceRecord, index: Int) {
        let name = record.getServiceName() ?? "(no name)"
        var channel: BluetoothRFCOMMChannelID = 0
        let chResult = record.getRFCOMMChannelID(&channel)
        let chStr = chResult == kIOReturnSuccess ? "ch=\(channel)" : "ch=(none)"

        let uuids = extractServiceClassUUIDs(from: record)
        log(String(format: "    [%02d] %@  %@", index, chStr, name))
        for u in uuids {
            log("         UUID: \(u)")
        }
    }

    static func findMaestroRecord(in device: IOBluetoothDevice) -> IOBluetoothSDPServiceRecord? {
        guard let records = device.services as? [IOBluetoothSDPServiceRecord] else { return nil }
        let target = maestroUUIDString.uppercased()
        for record in records {
            let uuids = extractServiceClassUUIDs(from: record).map { $0.uppercased() }
            if uuids.contains(target) {
                return record
            }
        }
        return nil
    }

    private static func extractServiceClassUUIDs(from record: IOBluetoothSDPServiceRecord) -> [String] {
        guard let attrs = record.attributes as? [NSNumber: IOBluetoothSDPDataElement] else { return [] }
        // Attribute ID 0x0001 = ServiceClassIDList
        guard let element = attrs[NSNumber(value: 0x0001)] else { return [] }
        return collectUUIDs(from: element)
    }

    private static func collectUUIDs(from element: IOBluetoothSDPDataElement) -> [String] {
        var out: [String] = []
        // Type 3 = UUID, Type 6 = Data Element Sequence
        switch element.getTypeDescriptor() {
        case 3:
            if let uuid = element.getUUIDValue() {
                out.append(formatUUID(uuid))
            }
        case 6, 7:
            if let arr = element.getArrayValue() as? [IOBluetoothSDPDataElement] {
                for child in arr {
                    out.append(contentsOf: collectUUIDs(from: child))
                }
            }
        default:
            break
        }
        return out
    }

    private static func formatUUID(_ sdpUUID: IOBluetoothSDPUUID) -> String {
        guard let expanded = sdpUUID.getWithLength(16) else { return "?" }
        let data = expanded as NSData
        var bytes = [UInt8](repeating: 0, count: 16)
        data.getBytes(&bytes, length: 16)
        let parts = [
            bytes[0...3].map { String(format: "%02x", $0) }.joined(),
            bytes[4...5].map { String(format: "%02x", $0) }.joined(),
            bytes[6...7].map { String(format: "%02x", $0) }.joined(),
            bytes[8...9].map { String(format: "%02x", $0) }.joined(),
            bytes[10...15].map { String(format: "%02x", $0) }.joined(),
        ]
        return parts.joined(separator: "-")
    }
}

let maestroUUIDString = "25e97ff7-24ce-4c4c-8951-f764a708f7b5"
