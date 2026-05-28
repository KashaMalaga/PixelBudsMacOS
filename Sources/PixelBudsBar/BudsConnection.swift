import Foundation
import IOBluetooth
import MaestroIOBluetooth

/// Encapsulates one Maestro session: paired device → RFCOMM channel →
/// RpcConnection → MaestroService. Created on popover open, destroyed on close.
final class BudsConnection {
    enum ConnectError: Error, CustomStringConvertible {
        case noPairedBuds
        case rfcommOpen(Error)
        case channelResolution(Error)
        case timeout

        var description: String {
            switch self {
            case .noPairedBuds:
                return String(localized: "No paired Pixel Buds Pro found")
            case .rfcommOpen(let e):
                return String(localized: "RFCOMM channel could not be opened — \(String(describing: e)). Another app (e.g. mypixelbuds.google.com in Chrome) may be holding the channel.")
            case .channelResolution(let e):
                return String(localized: "Maestro channel resolution failed: \(String(describing: e))")
            case .timeout:
                return String(localized: "Timed out connecting to the buds. Another app may be holding the channel — quit Chrome if mypixelbuds is open.")
            }
        }
    }

    enum Model {
        case gen1
        case gen2
        case unknown

        var supportsAdaptiveAnc: Bool {
            self == .gen2
        }

        /// Identify the hardware generation from the IOBluetooth device.
        /// Both "Pixel Buds Pro" (Gen 1) and "Pixel Buds Pro 2" (Gen 2) report
        /// CoD 0x240404 — the CoD alone can't distinguish them. Google always
        /// starts the default Bluetooth name with "Pixel Buds Pro 2" for Gen 2;
        /// users may add a personal suffix ("Pixel Buds Pro 2 de Manmen") but
        /// the product prefix stays intact, so a case-insensitive substring
        /// check is the only reliable distinguisher available without a firmware
        /// probe.
        static func from(device: IOBluetoothDevice) -> Model {
            switch UInt32(device.classOfDevice) {
            case 0x240404:
                let name = device.name ?? ""
                return name.range(of: "Pixel Buds Pro 2", options: .caseInsensitive) != nil
                    ? .gen2 : .gen1
            default:
                return .unknown
            }
        }
    }

    let device: IOBluetoothDevice
    private(set) var service: MaestroService
    let model: Model
    /// Secondary RFCOMM channel that carries the GFPS Message Stream (used
    /// for ring-the-buds). Optional because not every firmware/CoD pair
    /// advertises the GFPS SDP record; the rest of the app works without it.
    let gfps: GFPSChannel?
    private let adapter: RFCOMMTransportAdapter
    let connection: RpcConnection

    func updateService(channel: UInt32) {
        self.service = MaestroService(connection: self.connection, channel: channel)
    }

    private init(
        device: IOBluetoothDevice,
        model: Model,
        adapter: RFCOMMTransportAdapter,
        connection: RpcConnection,
        service: MaestroService,
        gfps: GFPSChannel?
    ) {
        self.device = device
        self.model = model
        self.adapter = adapter
        self.connection = connection
        self.service = service
        self.gfps = gfps
    }

    static func open(timeout seconds: TimeInterval = 15.0) async throws -> BudsConnection {
        try await withThrowingTaskGroup(of: BudsConnection.self) { group in
            group.addTask { try await openImpl() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw ConnectError.timeout
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else {
                throw ConnectError.timeout
            }
            return result
        }
    }

    private static func openImpl() async throws -> BudsConnection {
        guard let device = MaestroChannelOpener.findFirstPairedBuds() else {
            throw ConnectError.noPairedBuds
        }
        let adapter = RFCOMMTransportAdapter()
        do {
            try await adapter.open(on: device)
        } catch {
            throw ConnectError.rfcommOpen(error)
        }
        let conn = RpcConnection(transport: adapter.transport)
        await conn.start()
        let channel: UInt32
        do {
            channel = try await ChannelResolver.resolve(on: conn)
        } catch {
            await conn.stop()
            await adapter.close()
            throw ConnectError.channelResolution(error)
        }
        let svc = MaestroService(connection: conn, channel: channel)
        let model = Model.from(device: device)
        // Best-effort GFPS opener — short timeout so a missing channel
        // doesn't block the rest of the connect path. Result is allowed to
        // be nil; UI hides the Ring button in that case.
        let gfps = await GFPSChannel.open(on: device, timeout: 4.0)
        return BudsConnection(
            device: device,
            model: model,
            adapter: adapter,
            connection: conn,
            service: svc,
            gfps: gfps
        )
    }

    func close() async {
        await connection.stop()
        await adapter.close()
        await gfps?.close()
    }
}
