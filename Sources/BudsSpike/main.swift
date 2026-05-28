import Foundation
import IOBluetooth

func log(_ msg: String) {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss.SSS"
    print("[\(f.string(from: Date()))] \(msg)")
}

log("BudsSpike starting — Phase 0 RFCOMM connectivity probe")
log("")

let allPaired = DeviceFinder.allPaired()
log("Paired Bluetooth devices on this Mac: \(allPaired.count)")
for d in allPaired {
    let cod = UInt32(d.classOfDevice)
    log(String(
        format: "  • %@  [%@]  CoD=0x%06X  connected=%@",
        d.name ?? "(no name)",
        d.addressString ?? "??",
        cod,
        d.isConnected() ? "yes" : "no"
    ))
}
log("")

let candidates = DeviceFinder.findPairedBuds()
guard !candidates.isEmpty else {
    log("No Pixel Buds Pro found in paired devices (CoD 0x240404 or 0x244404).")
    log("Checks:")
    log("  1. Buds are paired in System Settings → Bluetooth")
    log("  2. This terminal has Bluetooth permission in System Settings → Privacy → Bluetooth")
    log("     (you may need to grant Terminal.app or your IDE Bluetooth access)")
    exit(1)
}

log("Pixel Buds candidates: \(candidates.count)")
for (i, c) in candidates.enumerated() {
    log("  [\(i)] \(c.model) — \(c.device.name ?? "?") (\(c.device.addressString ?? "?"))")
}
log("")

let target = candidates[0]
log("Targeting [0]: \(target.device.name ?? "?")  (\(target.model))  connected=\(target.device.isConnected() ? "yes" : "no")")

let client = RFCOMMClient(device: target.device)
let r = client.openMaestro()
if r != kIOReturnSuccess {
    log("Failed to initiate Maestro RFCOMM open, exit code \(ioReturnString(r))")
    exit(2)
}

log("")
log("Spike is running. Tap a bud or change ANC state on the buds to trigger event traffic.")
log("Press Ctrl-C to exit.")
log("")

signal(SIGINT) { _ in
    print("\n[interrupt] exiting")
    exit(0)
}

let heartbeatStart = Date()
let timer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { _ in
    let elapsed = Int(Date().timeIntervalSince(heartbeatStart))
    log("… still alive, \(elapsed)s elapsed (no inbound bytes yet)")
}
RunLoop.main.add(timer, forMode: .common)

RunLoop.main.run()
