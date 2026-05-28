import Foundation
import IOBluetooth
import SwiftProtobuf
import Maestro
import MaestroIOBluetooth

func log(_ msg: String) {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss.SSS"
    FileHandle.standardError.write(Data("[\(f.string(from: Date()))] \(msg)\n".utf8))
}

Task.detached(priority: .userInitiated) {
    do {
        try await asyncMain()
        exit(0)
    } catch {
        log("error: \(error)")
        exit(2)
    }
}

// Run the main runloop forever so IOBluetooth delegate callbacks can fire.
// The detached Task above will call exit() when the async work is done.
RunLoop.main.run()


func asyncMain() async throws {
    log("BudsRead starting — end-to-end Maestro probe")

    guard let device = MaestroChannelOpener.findFirstPairedBuds() else {
        log("No paired Pixel Buds Pro found.")
        throw NSError(domain: "BudsRead", code: 1)
    }
    log("Using device: \(device.name ?? "?") (\(device.addressString ?? "?"))")

    log("Opening Maestro RFCOMM channel…")
    let adapter = RFCOMMTransportAdapter()
    try await adapter.open(on: device)
    log("RFCOMM channel opened.")

    let connection = RpcConnection(transport: adapter.transport)
    await connection.start()

    log("Probing all candidate channels sequentially…")
    var responsiveChannels: [UInt32] = []
    let path = RpcPath("maestro_pw.Maestro/GetSoftwareInfo")
    for candidate in MaestroChannel.candidateIDs {
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    _ = try await connection.unary(
                        channel: candidate,
                        path: path,
                        request: SwiftProtobuf.Google_Protobuf_Empty()
                    )
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                    throw RpcError.channelResolutionFailed
                }
                defer { group.cancelAll() }
                try await group.next()
            }
            log("  Channel \(candidate) is RESPONSIVE!")
            responsiveChannels.append(candidate)
        } catch {
            log("  Channel \(candidate) is silent: \(error)")
        }
    }

    log("Testing settings writes across all responsive channels…")
    for ch in responsiveChannels {
        let chService = MaestroService(connection: connection, channel: ch)
        log("--- Testing writes on Channel \(ch) ---")
        
        // Touch controls write test
        do {
            let touchEnabled = try await chService.getGestureEnabled()
            log("  [Ch \(ch)] Current touch controls = \(touchEnabled)")
            log("  [Ch \(ch)] Trying to write-same \(touchEnabled)…")
            try await chService.setGestureEnabled(touchEnabled)
            log("  [Ch \(ch)] WRITE SUCCESSFUL!")
        } catch {
            log("  [Ch \(ch)] WRITE FAILED: \(error)")
        }
        
        // ANC write test
        do {
            let anc = try await chService.getAncState()
            log("  [Ch \(ch)] Trying to set ANC to OFF…")
            try await chService.setAncState(.off)
            log("  [Ch \(ch)] ANC WRITE SUCCESSFUL! Restoring state...")
            try await chService.setAncState(anc)
        } catch {
            log("  [Ch \(ch)] ANC WRITE FAILED: \(error)")
        }
    }

    log("Reading current runtime info (battery + placement)…")
    let maestroChannel = responsiveChannels.first ?? 0
    let service = MaestroService(connection: connection, channel: maestroChannel)
    let sw = try await service.getSoftwareInfo()
    let anc = try await service.getAncState()
    let rt = try await service.currentRuntimeInfo()
    log("  battery case:  \(batteryString(rt.batteryInfo.case))")
    log("  battery left:  \(batteryString(rt.batteryInfo.left))")
    log("  battery right: \(batteryString(rt.batteryInfo.right))")
    log("  placement: left in case = \(rt.placement.leftBudInCase), right in case = \(rt.placement.rightBudInCase)")

    log("Emitting JSON snapshot to stdout:")
    let snapshot: [String: Any] = [
        "device": device.name ?? "?",
        "channel": maestroChannel,
        "firmware": [
            "case": sw.firmware.case.versionString,
            "left": sw.firmware.left.versionString,
            "right": sw.firmware.right.versionString,
        ],
        "battery": [
            "case": batteryDict(rt.batteryInfo.case),
            "left": batteryDict(rt.batteryInfo.left),
            "right": batteryDict(rt.batteryInfo.right),
        ],
        "placement": [
            "left_in_case": rt.placement.leftBudInCase,
            "right_in_case": rt.placement.rightBudInCase,
        ],
        "anc": ancName(anc),
    ]
    let data = try JSONSerialization.data(withJSONObject: snapshot, options: [.prettyPrinted, .sortedKeys])
    print(String(data: data, encoding: .utf8) ?? "")

    await connection.stop()
}

func ancName(_ state: MaestroPw_AncState) -> String {
    switch state {
    case .UNRECOGNIZED, .unknown: return "unknown"
    case .off: return "off"
    case .active: return "active"
    case .aware: return "aware"
    case .adaptive: return "adaptive"
    }
}

func batteryStateName(_ s: MaestroPw_BatteryState, slug: Bool = false) -> String {
    switch s {
    case .batteryCharging: return "charging"
    case .batteryNotCharging: return slug ? "not_charging" : "not charging"
    case .unknown, .UNRECOGNIZED: return "unknown"
    }
}

func batteryString(_ b: MaestroPw_DeviceBatteryInfo) -> String {
    "\(b.level)% (\(batteryStateName(b.state)))"
}

func batteryDict(_ b: MaestroPw_DeviceBatteryInfo) -> [String: Any] {
    ["level": b.level, "state": batteryStateName(b.state, slug: true)]
}
