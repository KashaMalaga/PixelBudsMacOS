import Foundation
import IOBluetooth

let maestroUUIDBytes: [UInt8] = [
    0x25, 0xe9, 0x7f, 0xf7,
    0x24, 0xce,
    0x4c, 0x4c,
    0x89, 0x51,
    0xf7, 0x64, 0xa7, 0x08, 0xf7, 0xb5,
]

final class RFCOMMClient: NSObject, IOBluetoothRFCOMMChannelDelegate {
    private let device: IOBluetoothDevice
    private var channel: IOBluetoothRFCOMMChannel?
    private var totalBytesReceived = 0
    private var sdpQueryDone = false

    init(device: IOBluetoothDevice) {
        self.device = device
        super.init()
    }

    func openMaestro() -> IOReturn {
        log("Enumerating all SDP service records on device for diagnosis:")
        SDPInspector.dumpServices(of: device)
        log("")

        guard let record = SDPInspector.findMaestroRecord(in: device) else {
            log("No SDP service record matches Maestro UUID \(maestroUUIDString).")
            log("If the list above is empty, SDP cache may be stale — try repairing the device.")
            return kIOReturnNotFound
        }
        log("Maestro service record found by exact UUID match.")

        var channelID: BluetoothRFCOMMChannelID = 0
        let chResult = record.getRFCOMMChannelID(&channelID)
        if chResult != kIOReturnSuccess {
            log("getRFCOMMChannelID returned \(ioReturnString(chResult))")
            return chResult
        }
        log("Maestro service is on RFCOMM channel \(channelID)")

        var ch: IOBluetoothRFCOMMChannel?
        let openResult = device.openRFCOMMChannelAsync(
            &ch,
            withChannelID: channelID,
            delegate: self
        )
        if openResult != kIOReturnSuccess {
            log("openRFCOMMChannelAsync returned \(ioReturnString(openResult))")
            return openResult
        }
        self.channel = ch
        log("RFCOMM channel open initiated (waiting for openComplete delegate)…")
        return kIOReturnSuccess
    }

    // MARK: IOBluetoothRFCOMMChannelDelegate

    func rfcommChannelOpenComplete(
        _ rfcommChannel: IOBluetoothRFCOMMChannel!,
        status error: IOReturn
    ) {
        if error == kIOReturnSuccess {
            log("RFCOMM channel opened (channel ID \(rfcommChannel.getID()))")
            log("Listening for inbound frames. Anything below is raw RFCOMM payload.")
            log("Expected: HDLC U-frames starting with flag 0x7e.")
            log(String(repeating: "-", count: 60))
        } else {
            log("RFCOMM channel open failed: \(ioReturnString(error))")
        }
    }

    func rfcommChannelData(
        _ rfcommChannel: IOBluetoothRFCOMMChannel!,
        data dataPointer: UnsafeMutableRawPointer!,
        length dataLength: Int
    ) {
        let buf = Data(bytes: dataPointer, count: dataLength)
        totalBytesReceived += dataLength
        log("RX \(dataLength) bytes  (cumulative \(totalBytesReceived)):")
        HexDump.print(buf)
    }

    func rfcommChannelClosed(_ rfcommChannel: IOBluetoothRFCOMMChannel!) {
        log("RFCOMM channel closed.")
    }

    func rfcommChannelControlSignalsChanged(_ rfcommChannel: IOBluetoothRFCOMMChannel!) {}
    func rfcommChannelFlowControlChanged(_ rfcommChannel: IOBluetoothRFCOMMChannel!) {}
    func rfcommChannelWriteComplete(
        _ rfcommChannel: IOBluetoothRFCOMMChannel!,
        refcon: UnsafeMutableRawPointer!,
        status error: IOReturn
    ) {}
    func rfcommChannelQueueSpaceAvailable(_ rfcommChannel: IOBluetoothRFCOMMChannel!) {}

    // SDP query completion (perform SDP query callback)
    @objc func sdpQueryComplete(_ device: IOBluetoothDevice!, status: IOReturn) {
        log("SDP query complete: \(ioReturnString(status))")
        sdpQueryDone = true
    }
}

func ioReturnString(_ r: IOReturn) -> String {
    String(format: "0x%08X", UInt32(bitPattern: r))
}
