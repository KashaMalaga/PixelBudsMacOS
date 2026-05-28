import Foundation
import SwiftProtobuf

/// High-level wrapper around the Maestro RPC service. Binds an `RpcConnection`
/// to a specific channel (resolved via `ChannelResolver`) and exposes typed
/// async methods for the calls the UI actually needs.
public struct MaestroService: Sendable {
    private static let servicePath = "maestro_pw.Maestro"

    public let connection: RpcConnection
    public let channel: UInt32

    public init(connection: RpcConnection, channel: UInt32) {
        self.connection = connection
        self.channel = channel
    }

    // MARK: - Info

    public func getSoftwareInfo() async throws -> MaestroPw_SoftwareInfo {
        let payload = try await unary(method: "GetSoftwareInfo", request: Google_Protobuf_Empty())
        return try MaestroPw_SoftwareInfo(serializedBytes: payload)
    }

    public func getHardwareInfo() async throws -> MaestroPw_HardwareInfo {
        let payload = try await unary(method: "GetHardwareInfo", request: Google_Protobuf_Empty())
        return try MaestroPw_HardwareInfo(serializedBytes: payload)
    }

    // MARK: - Runtime info (battery, placement)

    public func subscribeRuntimeInfo() async throws -> AsyncThrowingStream<MaestroPw_RuntimeInfo, Error> {
        let raw = try await serverStream(method: "SubscribeRuntimeInfo", request: Google_Protobuf_Empty())
        return AsyncThrowingStream<MaestroPw_RuntimeInfo, Error> { continuation in
            let task = Task {
                do {
                    for try await bytes in raw {
                        let info = try MaestroPw_RuntimeInfo(serializedBytes: bytes)
                        continuation.yield(info)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Streams on-head / off-head edge events from the buds' proximity sensor.
    /// Each element is the raw `OobeAction` enum value; only the four head-
    /// detection cases are surfaced to callers — all others are filtered out.
    /// The stream ends when the underlying RFCOMM session closes.
    /// NOTE: some firmware versions do not implement this RPC (status 12 /
    /// UNIMPLEMENTED). Callers must handle that gracefully — the recommended
    /// pattern is to consume this stream in a separate non-throwing Task so a
    /// rejection does not tear down the main Maestro session.
    public func subscribeOobeActions() async throws -> AsyncThrowingStream<MaestroPw_OobeAction, Error> {
        let raw = try await serverStream(method: "SubscribeToOobeActions", request: Google_Protobuf_Empty())
        return AsyncThrowingStream<MaestroPw_OobeAction, Error> { continuation in
            let task = Task {
                do {
                    for try await bytes in raw {
                        let rsp = try MaestroPw_OobeActionRsp(serializedBytes: bytes)
                        continuation.yield(rsp.action)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Fetches a single runtime info snapshot (battery + placement).
    public func currentRuntimeInfo() async throws -> MaestroPw_RuntimeInfo {
        let stream = try await subscribeRuntimeInfo()
        for try await info in stream {
            return info
        }
        throw RpcError.transportClosed
    }

    // MARK: - Settings

    public func readSetting(_ id: MaestroPw_AllegroSettingType) async throws -> MaestroPw_SettingValue {
        var req = MaestroPw_ReadSettingMsg()
        req.settingsID = id
        let payload = try await unary(method: "ReadSetting", request: req)
        let rsp = try MaestroPw_SettingsRsp(serializedBytes: payload)
        return rsp.value
    }

    public func writeSetting(_ value: MaestroPw_SettingValue) async throws {
        var req = MaestroPw_WriteSettingMsg()
        req.setting = value
        _ = try await unary(method: "WriteSetting", request: req)
    }

    public func subscribeToSettingsChanges() async throws -> AsyncThrowingStream<MaestroPw_SettingValue, Error> {
        let raw = try await serverStream(method: "SubscribeToSettingsChanges", request: Google_Protobuf_Empty())
        return AsyncThrowingStream<MaestroPw_SettingValue, Error> { continuation in
            let task = Task {
                do {
                    for try await bytes in raw {
                        let rsp = try MaestroPw_SettingsRsp(serializedBytes: bytes)
                        continuation.yield(rsp.value)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Settings convenience

    public func getAncState() async throws -> MaestroPw_AncState {
        let value = try await readSetting(.allegroCurrentAncrState)
        return value.currentAncrState
    }

    public func setAncState(_ state: MaestroPw_AncState) async throws {
        var value = MaestroPw_SettingValue()
        value.currentAncrState = state
        try await writeSetting(value)
    }

    public func getMultipointEnabled() async throws -> Bool {
        try await readSetting(.allegroMultipointEnable).multipointEnable
    }

    public func setMultipointEnabled(_ enabled: Bool) async throws {
        var value = MaestroPw_SettingValue()
        value.multipointEnable = enabled
        try await writeSetting(value)
    }

    public func getGestureEnabled() async throws -> Bool {
        try await readSetting(.allegroGestureEnable).gestureEnable
    }

    public func setGestureEnabled(_ enabled: Bool) async throws {
        var value = MaestroPw_SettingValue()
        value.gestureEnable = enabled
        try await writeSetting(value)
    }

    public func getOnHeadDetection() async throws -> Bool {
        try await readSetting(.allegroOhdEnable).ohdEnable
    }

    public func setOnHeadDetection(_ enabled: Bool) async throws {
        var value = MaestroPw_SettingValue()
        value.ohdEnable = enabled
        try await writeSetting(value)
    }

    public func getVolumeEqEnabled() async throws -> Bool {
        try await readSetting(.allegroVolumeEqEnable).volumeEqEnable
    }

    public func setVolumeEqEnabled(_ enabled: Bool) async throws {
        var value = MaestroPw_SettingValue()
        value.volumeEqEnable = enabled
        try await writeSetting(value)
    }

    public func getGestureControl() async throws -> MaestroPw_GestureControl {
        try await readSetting(.allegroGestureControl).gestureControl
    }

    public func setGestureControl(_ control: MaestroPw_GestureControl) async throws {
        var value = MaestroPw_SettingValue()
        value.gestureControl = control
        try await writeSetting(value)
    }

    public func getAncrGestureLoop() async throws -> MaestroPw_AncrGestureLoop {
        try await readSetting(.allegroAncrGestureLoop).ancrGestureLoop
    }

    public func setAncrGestureLoop(_ loop: MaestroPw_AncrGestureLoop) async throws {
        var value = MaestroPw_SettingValue()
        value.ancrGestureLoop = loop
        try await writeSetting(value)
    }

    public func getCurrentUserEq() async throws -> MaestroPw_EqBands {
        try await readSetting(.allegroCurrentUserEq).currentUserEq
    }

    public func setCurrentUserEq(_ bands: MaestroPw_EqBands) async throws {
        var value = MaestroPw_SettingValue()
        value.currentUserEq = bands
        try await writeSetting(value)
    }

    public func getVolumeAsymmetry() async throws -> Int32 {
        try await readSetting(.allegroVolumeAsymmetry).volumeAsymmetry
    }

    public func setVolumeAsymmetry(_ asymmetry: Int32) async throws {
        var value = MaestroPw_SettingValue()
        value.volumeAsymmetry = asymmetry
        try await writeSetting(value)
    }

    /// Speech detection (a.k.a. "Conversation detection"). The matching
    /// `AllegroSettingType` entry isn't documented upstream; reading may fail
    /// with server status 2 on some firmwares. Writing is expected to work.
    public func getSpeechDetection() async throws -> Bool {
        try await readSetting(.allegroSpeechDetection).speechDetection
    }

    public func setSpeechDetection(_ enabled: Bool) async throws {
        var value = MaestroPw_SettingValue()
        value.speechDetection = enabled
        try await writeSetting(value)
    }

    public func getSumToMono() async throws -> Bool {
        try await readSetting(.allegroSumToMono).sumToMono
    }

    public func setSumToMono(_ enabled: Bool) async throws {
        var value = MaestroPw_SettingValue()
        value.sumToMono = enabled
        try await writeSetting(value)
    }

    /// Volume exposure notifications — warns the user after prolonged high-volume listening.
    /// Maps to ALLEGRO_VOLUME_EXPOSURE_NOTIFICATIONS (id 21).
    public func getVolumeExposureNotifications() async throws -> Bool {
        try await readSetting(.allegroVolumeExposureNotifications).volumeExposureNotifications
    }

    public func setVolumeExposureNotifications(_ enabled: Bool) async throws {
        var value = MaestroPw_SettingValue()
        value.volumeExposureNotifications = enabled
        try await writeSetting(value)
    }

    /// OTTS mode — increases touch sensitivity (e.g. when wearing gloves).
    /// Maps to ALLEGRO_OTTS_MODE (id 14). The proto field is Int32 but behaves
    /// as a boolean: 0 = off, 1 = on.
    public func getOttsMode() async throws -> Bool {
        try await readSetting(.allegroOttsMode).ottsMode != 0
    }

    public func setOttsMode(_ enabled: Bool) async throws {
        var value = MaestroPw_SettingValue()
        value.ottsMode = enabled ? 1 : 0
        try await writeSetting(value)
    }

    // MARK: - Internals

    private func unary(method: String, request: some Message) async throws -> Data {
        try await connection.unary(
            channel: channel,
            path: RpcPath(service: Self.servicePath, method: method),
            request: request
        )
    }

    private func serverStream(method: String, request: some Message) async throws -> AsyncThrowingStream<Data, Error> {
        try await connection.serverStream(
            channel: channel,
            path: RpcPath(service: Self.servicePath, method: method),
            request: request
        )
    }
}
