import Foundation
import OSLog
import SwiftUI
import MaestroIOBluetooth

private let log = Logger(subsystem: "com.kshmlg.PixelBudsBar", category: "session")

@MainActor
final class BudsViewModel: ObservableObject {
    enum ConnectionState: Equatable {
        case idle
        case connecting
        case connected
        case error(String)
    }

    struct BudsSnapshot: Equatable {
        var updatedAt: Date
        var leftBattery: Int32
        var leftCharging: Bool
        var rightBattery: Int32
        var rightCharging: Bool
        var caseBattery: Int32
        var caseChargingKnown: Bool
        var caseCharging: Bool
        var leftInCase: Bool
        var rightInCase: Bool
        var anc: MaestroPw_AncState
        var deviceName: String
        var supportsAdaptiveAnc: Bool
        /// Optional bools: `nil` means we never managed to read the current
        /// value (read may fail on certain firmwares with server status 2).
        /// Writes still work; the UI shows the toggle as indeterminate.
        var conversationDetection: Bool?
        var multipoint: Bool?
        var touchControls: Bool?
        /// Long-press action per ear (ANC control vs Assistant) and which ANC
        /// modes the long-press cycles through. Both `nil` until the initial
        /// read completes.
        var gestureControl: MaestroPw_GestureControl?
        var ancGestureLoop: MaestroPw_AncrGestureLoop?
        /// Pause-when-removed feature. `nil` until read.
        var onHeadDetection: Bool?
        /// "Volume EQ": firmware auto-tweaks the response curve based on level.
        var volumeEqEnabled: Bool?
        /// 5-band parametric EQ (-6…+6 dB per band). `nil` until read.
        var eq: MaestroPw_EqBands?
        /// The named preset that matches the current EQ bands, or `nil` when
        /// the user has a custom (non-matching) configuration or EQ hasn't
        /// loaded yet. Recomputed whenever `eq` changes.
        var eqPreset: EqPreset? { eq.flatMap { EqPreset.match($0) } }
        /// L/R volume balance in the wire format: 0…200 where parity encodes
        /// which side is louder (even = left bias, odd = right bias).
        var volumeAsymmetry: Int32?
        /// Sums both channels to mono so a single bud carries the full mix.
        var monoAudio: Bool?
        /// Warns after prolonged loud listening (hearing health).
        /// `nil` until the initial read completes (may fail on older firmware).
        var volumeExposureNotifications: Bool?
        /// Increases touch-sensor sensitivity — useful when wearing gloves.
        /// Proto field is Int32; we surface it as Bool (0 = off, non-zero = on).
        /// `nil` until the initial read completes.
        var ottsMode: Bool?
        /// Read-once metadata about the device: firmware versions + serial
        /// numbers per bud and the case. `nil` until the initial reads succeed
        /// (these don't change during a session so we never re-fetch).
        var deviceInfo: DeviceInfo?
        /// True if the GFPS Message Stream channel opened successfully. The
        /// Find/Ring controls are gated on this — Maestro alone can't ring.
        var canRingBuds: Bool = false
        /// Active A2DP codec label derived from CoreAudio stream format.
        /// `nil` while the probe hasn't completed or the codec can't be determined
        /// (hide the label rather than showing "Unknown"). Updated once per session
        /// shortly after the connection is established.
        var activeCodec: String?

        /// Whether each bud is physically in the user's ear, as synthesised from
        /// proximity-sensor edge events streamed by `SubscribeToOobeActions`.
        /// Starts `.unknown` (no event yet received) or `.outOfEar` (if the bud
        /// is in the case at connect time). Transitions to `.inEar` / `.outOfEar`
        /// on ON_HEAD / OFF_HEAD events respectively.
        /// Reverts to `.outOfEar` whenever placement reports the bud is in the case.
        var leftInEar: InEarState = .unknown
        var rightInEar: InEarState = .unknown

        /// True when both buds are reported sitting in the case. In this state
        /// the firmware rejects practically every settings write (status 9 /
        /// FAILED_PRECONDITION), so the UI surfaces a banner and grays out
        /// the most affected control (ANC picker).
        var bothInCase: Bool { leftInCase && rightInCase }
    }

    /// Physical wearing state of a single earbud, synthesised from OOBE action events.
    /// `unknown` means no event has arrived yet — the bud is out of the case but
    /// we haven't observed the user putting it in or taking it out.
    enum InEarState: Equatable {
        case unknown
        case inEar
        case outOfEar
    }

    struct DeviceInfo: Equatable {
        var firmwareLeft: String
        var firmwareRight: String
        var firmwareCase: String
        var serialLeft: String
        var serialRight: String
        var serialCase: String
    }

    @Published private(set) var connectionState: ConnectionState = .idle
    @Published private(set) var snapshot: BudsSnapshot?
    /// Last error from an individual setting write (not a connection drop).
    /// Surfaced as a transient banner in the UI; the underlying connection
    /// stays open. Cleared on the next successful write or via `clearWriteError()`.
    @Published private(set) var lastWriteError: String?
    /// When true, the AppDelegate has asked us to keep the session alive
    /// even with no UI on screen — needed for low-battery alerts. Backed by
    /// UserDefaults so the choice survives relaunch. Mutated via
    /// `setBackgroundMonitoring(_:)` so we can react with side effects.
    @Published private(set) var backgroundMonitoringEnabled: Bool

    private static let backgroundMonitoringKey = "pixelBudsBar.backgroundMonitoring"

    private var liveTask: Task<Void, Never>?
    private var connection: BudsConnection?
    /// Tracks the previous session's teardown so a fast reopen waits for the
    /// old RFCOMM channel to actually release before trying to open a new one.
    private var pendingClose: Task<Void, Never>?
    /// Set when a write triggered a forced reconnect. The next successful
    /// connection clears `lastWriteError` so the user doesn't have to dismiss
    /// the "Reconnecting…" banner manually.
    private var clearWriteErrorOnReconnect = false
    /// How many transport-level write errors we've seen in a row without an
    /// intervening successful operation. We tolerate the first few (the buds
    /// often hiccup briefly when a bud transitions in/out of the case while
    /// the user is clicking) and only force a reconnect once the failures
    /// look persistent. Reset on any successful write or server reply.
    private var consecutiveTransportErrors = 0
    private static let forceReconnectAfterTransportErrors = 4

    /// Counts how many UI surfaces (popover, settings window, …) currently
    /// hold the connection. We open the connection on 0→1 and tear it down
    /// on N→0, so popover and settings can coexist without churning the
    /// RFCOMM channel.
    private var consumerCount: Int = 0
    /// True while we're holding a consumer slot on behalf of background
    /// monitoring (in addition to the UI surfaces). Kept separate from the
    /// stored toggle so we don't double-acquire if the toggle flips twice.
    private var backgroundConsumerActive: Bool = false

    init() {
        // UserDefaults stores Bool as a number under-the-hood; `object(forKey:)`
        // returns nil on first launch so we can distinguish "never set" (use
        // the default ON) from "explicitly set to false".
        let stored = UserDefaults.standard.object(forKey: Self.backgroundMonitoringKey) as? Bool
        self.backgroundMonitoringEnabled = stored ?? true
    }

    /// Returns the smaller of left/right battery, or nil if no snapshot exists.
    var menuBarBatteryPercent: Int32? {
        guard let s = snapshot else { return nil }
        return min(s.leftBattery, s.rightBattery)
    }

    /// Called once at launch (from AppDelegate) so the side effect of opening
    /// the connection is observable in the UI lifecycle, not buried in init.
    /// If the user had background monitoring enabled (or this is first run
    /// with the default ON), grabs a consumer slot so the session stays
    /// alive between popover sessions.
    func bootstrapBackgroundMonitoring() {
        guard backgroundMonitoringEnabled, !backgroundConsumerActive else { return }
        backgroundConsumerActive = true
        acquireConnection()
    }

    /// Persists the user's choice and acquires/releases the background slot.
    /// Idempotent — flipping the same value twice is a no-op.
    func setBackgroundMonitoring(_ enabled: Bool) {
        guard enabled != backgroundMonitoringEnabled else { return }
        backgroundMonitoringEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.backgroundMonitoringKey)
        if enabled, !backgroundConsumerActive {
            backgroundConsumerActive = true
            acquireConnection()
        } else if !enabled, backgroundConsumerActive {
            backgroundConsumerActive = false
            releaseConnection()
        }
    }

    /// Register a UI consumer. The first acquire opens the connection;
    /// further acquires just bump the count. Pair with `releaseConnection()`.
    func acquireConnection() {
        consumerCount += 1
        guard consumerCount == 1, liveTask == nil else { return }
        connectionState = .connecting
        liveTask = Task { [weak self] in
            await self?.runLiveSession()
        }
    }

    /// Unregister a UI consumer. The last release tears down the connection.
    func releaseConnection() {
        guard consumerCount > 0 else { return }
        consumerCount -= 1
        guard consumerCount == 0 else { return }
        // Capture the old task BEFORE cancelling it so pendingClose can await
        // its full exit. Without this, the cancelled task's openImpl() cleanup
        // (adapter.close → CBMsgIdPeerCloseRFCOMM) races with the NEW session's
        // RFCOMM open on the same channelID, silently killing channel resolution.
        let oldTask = liveTask
        liveTask?.cancel()
        liveTask = nil
        let conn = connection
        connection = nil
        pendingClose = Task {
            _ = await oldTask?.value   // wait for old task to fully exit + clean up its adapter
            await conn?.close()
        }
        if case .connected = connectionState {
            connectionState = .idle
        }
    }

    func setAnc(_ state: MaestroPw_AncState) {
        guard let connection else { return }
        let skipRetry = snapshot?.bothInCase ?? false
        Task { [weak self] in
            do {
                try await Self.writeWithTransientRetry(label: "Noise Control", skipRetry: skipRetry) {
                    try await connection.service.setAncState(state)
                }
                await MainActor.run {
                    guard var s = self?.snapshot else { return }
                    s.anc = state
                    s.updatedAt = Date()
                    self?.snapshot = s
                    self?.lastWriteError = nil
                    self?.consecutiveTransportErrors = 0
                }
            } catch {
                await MainActor.run {
                    self?.handleWriteError(error, label: "Noise Control")
                }
            }
        }
    }

    /// Dismiss the current write-error banner. Called from the UI's close button.
    func clearWriteError() {
        lastWriteError = nil
    }

    /// Translates RPC errors that have predictable user-facing causes into
    /// short actionable hints. Falls back to the raw error string for anything
    /// we don't know how to phrase. The two cases worth special-casing:
    /// - status 9 / FAILED_PRECONDITION → "current state doesn't allow this".
    ///   In practice this fires for several reasons: both buds docked, neither
    ///   bud worn, a brief transition window after another change, etc. We
    ///   used to attribute it solely to "not in ear" but that confused users
    ///   who were wearing them — now we list the likeliest causes instead.
    /// - status 12 / UNIMPLEMENTED → firmware on this generation doesn't ship
    ///   the setting. Phrasing it as a firmware limitation is less alarming
    ///   than "internal error".
    static func friendlyWriteError(label: String, error: Error) -> String {
        if let rpc = error as? RpcError, case .serverError(let status) = rpc {
            switch status {
            case 9:
                // FAILED_PRECONDITION. We can't tell from the wire which
                // precondition failed — could be in-case, transient, or a
                // firmware quirk. Acknowledge that the buds said no and
                // offer the on-device gesture as a fallback.
                return String(localized: "Buds rejected the \(label) change. Try again in a moment, or use the touch gesture on a bud.")
            case 12:
                return String(localized: "Your buds don't support \(label) on this firmware.")
            default:
                break
            }
        }
        return String(localized: "Could not set \(label): \(String(describing: error))")
    }

    func setConversationDetection(_ enabled: Bool) {
        writeSetting(label: "conversation detection",
                     write: { try await $0.setSpeechDetection(enabled) },
                     update: { $0.conversationDetection = enabled })
    }

    func setMultipoint(_ enabled: Bool) {
        writeSetting(label: "multipoint",
                     write: { try await $0.setMultipointEnabled(enabled) },
                     update: { $0.multipoint = enabled })
    }

    func setTouchControls(_ enabled: Bool) {
        writeSetting(label: "touch controls",
                     write: { try await $0.setGestureEnabled(enabled) },
                     update: { $0.touchControls = enabled })
    }

    /// Full GestureControl (both ears) must be written together — there's no
    /// per-ear write. The SettingsView mutates the snapshot's copy and hands
    /// us the new value.
    func setGestureControl(_ control: MaestroPw_GestureControl) {
        writeSetting(label: "hold gesture",
                     write: { try await $0.setGestureControl(control) },
                     update: { $0.gestureControl = control })
    }

    func setAncGestureLoop(_ loop: MaestroPw_AncrGestureLoop) {
        writeSetting(label: "ANC cycle modes",
                     write: { try await $0.setAncrGestureLoop(loop) },
                     update: { $0.ancGestureLoop = loop })
    }

    func setOnHeadDetection(_ enabled: Bool) {
        writeSetting(label: "on-head detection",
                     write: { try await $0.setOnHeadDetection(enabled) },
                     update: { $0.onHeadDetection = enabled })
    }

    func setVolumeEqEnabled(_ enabled: Bool) {
        writeSetting(label: "volume-adaptive EQ",
                     write: { try await $0.setVolumeEqEnabled(enabled) },
                     update: { $0.volumeEqEnabled = enabled })
    }

    func setEq(_ bands: MaestroPw_EqBands) {
        writeSetting(label: "equalizer",
                     write: { try await $0.setCurrentUserEq(bands) },
                     update: { $0.eq = bands })
    }

    /// Convenience wrapper that applies all five bands of a named preset at once.
    /// Delegates entirely to `setEq` so optimistic UI patch and firmware echo
    /// rollback reuse the same code path.
    func setEqPreset(_ preset: EqPreset) {
        setEq(preset.bands)
    }

    /// `raw` is the wire-format value (0…200, even=left bias / odd=right bias).
    /// The SettingsView slider converts a -100…+99 user value to this raw form.
    func setVolumeAsymmetry(_ raw: Int32) {
        writeSetting(label: "balance",
                     write: { try await $0.setVolumeAsymmetry(raw) },
                     update: { $0.volumeAsymmetry = raw })
    }

    func setMonoAudio(_ enabled: Bool) {
        writeSetting(label: "mono audio",
                     write: { try await $0.setSumToMono(enabled) },
                     update: { $0.monoAudio = enabled })
    }

    func setVolumeExposureNotifications(_ enabled: Bool) {
        writeSetting(label: "volume exposure notifications",
                     write: { try await $0.setVolumeExposureNotifications(enabled) },
                     update: { $0.volumeExposureNotifications = enabled })
    }

    // NOTE: setOttsMode is intentionally absent. Writing ALLEGRO_OTTS_MODE
    // causes the buds to drop the RFCOMM connection instead of returning a
    // proper error. The read works fine so we keep ottsMode in the snapshot
    // for future use, but the toggle is hidden from the UI until we understand
    // the correct write semantics.

    /// Send a GFPS ring command. Fire-and-forget: the buds beep loudly until
    /// the user touches a bud or we send a `.stop`. Errors land in the
    /// standard write-error banner. If the underlying channel turns out to
    /// be dead (the peer closed it silently), we also hide the bell button
    /// so the user doesn't keep hitting a broken control.
    func ringBuds(_ target: GFPSChannel.RingTarget) {
        guard let gfps = connection?.gfps else { return }
        Task { [weak self] in
            do {
                try await gfps.ring(target)
                await MainActor.run { self?.lastWriteError = nil }
            } catch {
                await MainActor.run {
                    self?.lastWriteError = String(localized: "Could not ring buds: \(String(describing: error))")
                    self?.markRingUnavailable()
                }
            }
        }
    }

    /// Hide the Ring control in the popover. Called when GFPS closes from
    /// the peer side (whenClosed) or when a write reveals the channel is dead.
    private func markRingUnavailable() {
        guard var s = snapshot, s.canRingBuds else { return }
        s.canRingBuds = false
        snapshot = s
    }

    /// Common path: write a single setting and patch the snapshot.
    /// `write` performs the RPC; `update` applies the optimistic UI change.
    /// Transport-level failures (RFCOMM writeSync timeout / channel dead) are
    /// routed through `handleWriteError` which also forces a reconnect.
    private func writeSetting(
        label: String,
        write: @escaping (MaestroService) async throws -> Void,
        update: @escaping (inout BudsSnapshot) -> Void
    ) {
        guard connection != nil else { return }
        let skipRetry = snapshot?.bothInCase ?? false
        Task { [weak self] in
            do {
                do {
                    try await Self.writeWithTransientRetry(label: label, skipRetry: skipRetry) {
                        guard let currentService = self?.connection?.service else { return }
                        try await write(currentService)
                    }
                } catch {
                    guard let conn = self?.connection,
                          let altChannel = MaestroChannel.alternativeBudChannel(for: conn.service.channel) else {
                        throw error
                    }
                    
                    log.info("Write failed on channel \(conn.service.channel) with error: \(error, privacy: .public). Trying alternative bud channel \(altChannel)…")
                    
                    let altService = MaestroService(connection: conn.connection, channel: altChannel)
                    
                    // Warm up the cold alternative channel with a quick, harmless query before writing
                    _ = try? await altService.getSoftwareInfo()
                    
                    try await Self.writeWithTransientRetry(label: label, skipRetry: skipRetry) {
                        try await write(altService)
                    }
                    
                    await MainActor.run {
                        self?.connection?.updateService(channel: altChannel)
                        log.info("Successfully switched active channel to \(altChannel)")
                    }
                }
                
                await MainActor.run {
                    guard var s = self?.snapshot else { return }
                    update(&s)
                    s.updatedAt = Date()
                    self?.snapshot = s
                    self?.lastWriteError = nil
                    self?.consecutiveTransportErrors = 0
                }
            } catch {
                await MainActor.run {
                    self?.handleWriteError(error, label: label)
                }
            }
        }
    }

    /// Some `FAILED_PRECONDITION` (9) and `UNAVAILABLE` (14) replies from the
    /// firmware are transient — the buds emit them when they aren't quite
    /// ready to apply a setting (notably, the very first user click after a
    /// session warms up tends to get rejected even with the buds worn). One
    /// brief retry catches those without bothering the user. We skip the
    /// retry when both buds are docked, because then status 9 is the
    /// firmware's correct, persistent answer and another attempt would just
    /// delay the inevitable error.
    private static func writeWithTransientRetry(
        label: String,
        skipRetry: Bool,
        write: @escaping () async throws -> Void
    ) async throws {
        do {
            try await write()
        } catch {
            guard !skipRetry, Self.isTransientServerError(error) else { throw error }
            log.info("transient '\(label, privacy: .public)' rejection — retrying once: \(error, privacy: .public)")
            try? await Task.sleep(nanoseconds: 400_000_000)
            try await write()
        }
    }

    private static func isTransientServerError(_ error: Error) -> Bool {
        guard let rpc = error as? RpcError,
              case .serverError(let status) = rpc else { return false }
        return status == 9 || status == 14
    }

    /// Routes a write error.
    ///
    /// Transport-level failures (writeSync IOReturn errors, `.transportClosed`)
    /// USED to immediately force a reconnect on the theory that a failed write
    /// meant the link was dead. In practice the buds also reject writes during
    /// brief state transitions — putting a bud in the case while a setting
    /// click is in flight, for example — and the firmware then refuses our
    /// reconnect attempts for an extended window, leaving the app stuck in an
    /// infinite "Reconnecting…" loop until the user quits and relaunches.
    ///
    /// New behaviour: surface a "try again" banner and keep the session alive.
    /// Only force a reconnect once we've seen several transport errors in a
    /// row with nothing successful in between, which is the actual signature
    /// of a dead link. The natural inbound-stream death in `runOneSession`
    /// still handles the case where the RFCOMM channel really has closed.
    ///
    /// Server-level RPC rejections (status 9, 12, …) leave the connection
    /// intact; those are per-write policy errors, not link failures, and they
    /// also reset the transport-error counter because a server reply proves
    /// the link is round-tripping.
    private func handleWriteError(_ error: Error, label: String) {
        if Self.isTransportError(error) {
            consecutiveTransportErrors += 1
            log.error("write '\(label, privacy: .public)' transport error #\(self.consecutiveTransportErrors): \(error, privacy: .public)")
            if consecutiveTransportErrors >= Self.forceReconnectAfterTransportErrors {
                log.error("persistent transport errors — forcing reconnect")
                lastWriteError = "Lost contact with the buds. Reconnecting…"
                clearWriteErrorOnReconnect = true
                connectionState = .connecting
                consecutiveTransportErrors = 0
                let conn = connection
                Task { await conn?.close() }
                return
            }
            lastWriteError = "Couldn't update \(label) — the buds didn't respond. Try again in a moment."
            return
        }
        // Server reply received → link is fine, reset the transport counter.
        consecutiveTransportErrors = 0
        log.error("write '\(label, privacy: .public)' server error: \(error, privacy: .public)")
        lastWriteError = Self.friendlyWriteError(label: label, error: error)
    }

    /// Returns true for errors that indicate the underlying RFCOMM link is
    /// broken: raw transport write failures from IOBluetooth and the RPC-layer
    /// `.transportClosed` that fires when the inbound stream ends.
    private static func isTransportError(_ error: Error) -> Bool {
        if let rpc = error as? RpcError, case .transportClosed = rpc { return true }
        return (error as NSError).domain == "RFCOMMTransport"
    }

    // MARK: - Live session driver

    /// Drives the connection lifetime for the whole popover-open window:
    /// open → fetch initial snapshot → subscribe → if the stream drops, retry
    /// with exponential backoff. Cancellation (popoverClosed) breaks out
    /// immediately at any await point.
    private func runLiveSession() async {
        if let pending = pendingClose {
            await pending.value
            pendingClose = nil
        }

        // Fresh-connect attempts share a budget; once we've actually had a
        // snapshot in the popover the budget resets so a healthy session can
        // recover from intermittent drops indefinitely.
        var consecutiveFailures = 0
        let maxFailuresBeforeGivingUp = 5
        var lastError: Error?
        // True after background mode exhausts its fast-retry budget. We stop
        // showing "Connecting…" on every attempt (which looks broken) and instead
        // leave the error state visible while slow-retrying in the background.
        var suppressConnectingState = false

        while !Task.isCancelled {
            if !suppressConnectingState {
                connectionState = .connecting
            }
            log.info("session: attempt \(consecutiveFailures + 1) (failures so far: \(consecutiveFailures))")

            let (gotSnapshot, err) = await runOneSession()
            await teardownConnection()
            if Task.isCancelled { return }

            lastError = err ?? lastError

            if gotSnapshot {
                log.info("session: ended after publishing snapshot — error: \(err.map { String(describing: $0) } ?? "none", privacy: .public)")
                consecutiveFailures = 0
                suppressConnectingState = false
            } else {
                consecutiveFailures += 1
                log.error("session: failed before snapshot (attempt \(consecutiveFailures)) — \(err.map { String(describing: $0) } ?? "unknown", privacy: .public)")
                if consecutiveFailures >= maxFailuresBeforeGivingUp {
                    let message = lastError.map { String(describing: $0) }
                        ?? "Could not connect after \(maxFailuresBeforeGivingUp) attempts"
                    if backgroundMonitoringEnabled {
                        // Surface the error so the UI doesn't show "Connecting…"
                        // forever, but keep retrying at the capped 10s interval —
                        // the buds will come back when taken out of the case.
                        connectionState = .error(message)
                        suppressConnectingState = true
                        consecutiveFailures = 4
                    } else {
                        connectionState = .error(message)
                        return
                    }
                }
            }

            // Backoff: 1s, 2s, 4s, 8s, 10s cap. After a successful drop the
            // failure counter is 0 so we start at 1s again, which is what we want.
            let shift = min(consecutiveFailures, 4)
            let backoffNs = min(
                UInt64(1_000_000_000) << UInt64(shift),
                UInt64(10_000_000_000)
            )
            let backoffMs = backoffNs / 1_000_000
            log.info("session: backing off \(backoffMs)ms")
            try? await Task.sleep(nanoseconds: backoffNs)
        }
    }

    /// Runs one open→subscribe cycle.
    /// Returns `(gotSnapshot, error)` where:
    ///   - `gotSnapshot == true`  → we successfully published initial data
    ///     (so the user has seen something); the session then ended (drop or
    ///     cancellation). Caller should retry without consuming the budget.
    ///   - `gotSnapshot == false` → never got data; caller decrements budget.
    private func runOneSession() async -> (Bool, Error?) {
        let conn: BudsConnection
        do {
            conn = try await BudsConnection.open()
        } catch {
            return (false, error)
        }
        if Task.isCancelled { return (false, nil) }
        self.connection = conn

        // Channel resolution serializes RPCs internally; we await sequentially
        // so the buds don't reject parallel requests on freshly-resolved
        // channels (we learned this the hard way during channel resolution).
        let initialAnc = (try? await conn.service.getAncState()) ?? .unknown
        let initialRuntime = try? await conn.service.currentRuntimeInfo()
        let initialConversation = try? await conn.service.getSpeechDetection()
        let initialMultipoint = try? await conn.service.getMultipointEnabled()
        let initialTouch = try? await conn.service.getGestureEnabled()
        let initialGesture = try? await conn.service.getGestureControl()
        let initialAncLoop = try? await conn.service.getAncrGestureLoop()
        let initialOhd = try? await conn.service.getOnHeadDetection()
        let initialVolumeEq = try? await conn.service.getVolumeEqEnabled()
        let initialEq = try? await conn.service.getCurrentUserEq()
        let initialBalance = try? await conn.service.getVolumeAsymmetry()
        let initialMono = try? await conn.service.getSumToMono()
        let initialVolumeExposure = try? await conn.service.getVolumeExposureNotifications()
        let initialOtts = try? await conn.service.getOttsMode()
        let software = try? await conn.service.getSoftwareInfo()
        let hardware = try? await conn.service.getHardwareInfo()
        let deviceInfo: DeviceInfo? = {
            // Both reads must succeed for an "About" block to be useful;
            // anything less and we hide the section.
            guard let sw = software, let hw = hardware else { return nil }
            return DeviceInfo(
                firmwareLeft: sw.firmware.left.versionString,
                firmwareRight: sw.firmware.right.versionString,
                firmwareCase: sw.firmware.case.versionString,
                serialLeft: hw.serialNumber.left,
                serialRight: hw.serialNumber.right,
                serialCase: hw.serialNumber.case
            )
        }()

        guard let rt = initialRuntime else {
            return (false, LiveSessionError.noRuntime)
        }

        let snap = BudsSnapshot(
            updatedAt: Date(),
            leftBattery: rt.batteryInfo.left.level,
            leftCharging: rt.batteryInfo.left.state == .batteryCharging,
            rightBattery: rt.batteryInfo.right.level,
            rightCharging: rt.batteryInfo.right.state == .batteryCharging,
            caseBattery: rt.batteryInfo.case.level,
            caseChargingKnown: rt.batteryInfo.case.state != .unknown,
            caseCharging: rt.batteryInfo.case.state == .batteryCharging,
            leftInCase: rt.placement.leftBudInCase,
            rightInCase: rt.placement.rightBudInCase,
            anc: initialAnc,
            deviceName: conn.device.name ?? "Pixel Buds",
            supportsAdaptiveAnc: conn.model.supportsAdaptiveAnc,
            conversationDetection: initialConversation,
            multipoint: initialMultipoint,
            touchControls: initialTouch,
            gestureControl: initialGesture,
            ancGestureLoop: initialAncLoop,
            onHeadDetection: initialOhd,
            volumeEqEnabled: initialVolumeEq,
            eq: initialEq,
            volumeAsymmetry: initialBalance,
            monoAudio: initialMono,
            volumeExposureNotifications: initialVolumeExposure,
            ottsMode: initialOtts,
            deviceInfo: deviceInfo,
            canRingBuds: conn.gfps != nil,
            // A bud in the case is definitively not in an ear. Otherwise we
            // start as .unknown — the OOBE stream will supply the first event.
            leftInEar:  rt.placement.leftBudInCase  ? .outOfEar : .unknown,
            rightInEar: rt.placement.rightBudInCase ? .outOfEar : .unknown
        )
        self.snapshot = snap
        self.connectionState = .connected
        log.info("session: connected — device=\(snap.deviceName, privacy: .public) anc=\(String(describing: snap.anc), privacy: .public) inCase=\(snap.bothInCase)")
        // If a previous write triggered a forced reconnect, clear the
        // "Reconnecting…" banner now that we're back online.
        if clearWriteErrorOnReconnect {
            clearWriteErrorOnReconnect = false
            lastWriteError = nil
        }
        // Fresh session — any prior transport-error streak is irrelevant now.
        consecutiveTransportErrors = 0

        // Codec probe: synchronous CoreAudio read, but run in a Task so we
        // don't block the session setup path. Updates the snapshot once when
        // the result arrives. Cached implicitly — codec doesn't change mid-session
        // unless the OS switches profiles (e.g. A2DP → HFP on a call), which
        // would also trigger a new session and a fresh probe.
        let deviceName = snap.deviceName
        Task { [weak self] in
            let codec = CodecProbe.label(forDeviceNamed: deviceName)
            await MainActor.run {
                guard var s = self?.snapshot else { return }
                s.activeCodec = codec
                self?.snapshot = s
            }
        }

        // GFPS observer: if the secondary channel dies mid-session (e.g. the
        // buds drop it on case re-seat), hide the Ring control so the user
        // doesn't hit a broken button. We attach this *outside* the main
        // task group below because GFPS going down should NOT end the Maestro
        // session — the rest of the app keeps working.
        if let gfps = conn.gfps {
            Task { [weak self] in
                await gfps.whenClosed()
                await MainActor.run { self?.markRingUnavailable() }
            }
        }

        // NOTE: SubscribeToOobeActions (on-head/off-head events) is intentionally
        // NOT subscribed here. Testing revealed that sending this RPC causes the
        // Pixel Buds Pro firmware to stop emitting updates on the runtime and
        // settings streams, freezing the UI silently. The method exists in
        // MaestroService for future use when firmware compatibility improves.

        // Two mandatory streams that drive the session lifetime:
        // - runtime info (battery / placement)
        // - settings changes (so toggles reflect the authoritative device state)
        // If either ends or throws, the session is treated as dropped and the
        // outer runLiveSession loop reconnects with exponential backoff.
        //
        // A third, non-mandatory task polls RuntimeInfo every 30 seconds.
        // Gen 2 firmware is event-driven for placement (emits on case-close,
        // not on "bud placed in open case"), so without this poll the charging
        // indicator and in-case badge can stay stale for minutes. The poll
        // task is cancelled automatically when the group ends.
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { [conn] in
                    let stream = try await conn.service.subscribeRuntimeInfo()
                    for try await update in stream {
                        if Task.isCancelled { return }
                        await MainActor.run { self.applyRuntimeUpdate(update) }
                    }
                }
                group.addTask { [conn] in
                    let stream = try await conn.service.subscribeToSettingsChanges()
                    for try await update in stream {
                        if Task.isCancelled { return }
                        await MainActor.run { self.applySettingsUpdate(update) }
                    }
                }
                group.addTask { [conn] in
                    // Non-throwing: a failed refresh is silent; the mandatory
                    // streams above will surface any real transport failure.
                    while !Task.isCancelled {
                        try await Task.sleep(for: .seconds(30))
                        if Task.isCancelled { return }
                        if let rt = try? await conn.service.currentRuntimeInfo() {
                            await MainActor.run { self.applyRuntimeUpdate(rt) }
                        }
                    }
                }
                // Wait for either mandatory stream to finish — session drop.
                try await group.next()
                group.cancelAll()
            }
            return (true, nil)
        } catch {
            return (true, error)
        }
    }

    private func teardownConnection() async {
        let conn = connection
        connection = nil
        await conn?.close()
    }

    private enum LiveSessionError: Error, CustomStringConvertible {
        case noRuntime
        var description: String {
            switch self {
            case .noRuntime: return "Connected but the buds did not report runtime info."
            }
        }
    }

    /// The device pushes a `SettingValue` whenever a setting it considers
    /// canonical changes (including our own writes echoed back). The oneof
    /// case tells us which field is current; we patch that field in the
    /// snapshot. If a write is rejected, the device pushes the old value
    /// and our optimistic UI snaps back to reality.
    private func applySettingsUpdate(_ value: MaestroPw_SettingValue) {
        guard var s = snapshot, let kind = value.valueOneof else { return }
        switch kind {
        case .currentAncrState(let state):
            s.anc = state
        case .speechDetection(let enabled):
            s.conversationDetection = enabled
        case .multipointEnable(let enabled):
            s.multipoint = enabled
        case .gestureEnable(let enabled):
            s.touchControls = enabled
        case .gestureControl(let gc):
            s.gestureControl = gc
        case .ancrGestureLoop(let loop):
            s.ancGestureLoop = loop
        case .ohdEnable(let enabled):
            s.onHeadDetection = enabled
        case .volumeEqEnable(let enabled):
            s.volumeEqEnabled = enabled
        case .currentUserEq(let bands):
            s.eq = bands
        case .volumeAsymmetry(let raw):
            s.volumeAsymmetry = raw
        case .sumToMono(let enabled):
            s.monoAudio = enabled
        case .volumeExposureNotifications(let enabled):
            s.volumeExposureNotifications = enabled
        case .ottsMode(let raw):
            s.ottsMode = raw != 0
        default:
            // We don't surface other settings in the snapshot yet.
            return
        }
        s.updatedAt = Date()
        snapshot = s
    }

    private func applyRuntimeUpdate(_ rt: MaestroPw_RuntimeInfo) {
        guard var s = snapshot else { return }
        let wasBothInCase = s.bothInCase
        s.updatedAt = Date()
        if rt.hasBatteryInfo {
            s.leftBattery = rt.batteryInfo.left.level
            s.leftCharging = rt.batteryInfo.left.state == .batteryCharging
            s.rightBattery = rt.batteryInfo.right.level
            s.rightCharging = rt.batteryInfo.right.state == .batteryCharging
            s.caseBattery = rt.batteryInfo.case.level
            s.caseChargingKnown = rt.batteryInfo.case.state != .unknown
            s.caseCharging = rt.batteryInfo.case.state == .batteryCharging
        }
        if rt.hasPlacement {
            s.leftInCase = rt.placement.leftBudInCase
            s.rightInCase = rt.placement.rightBudInCase
            // Placement is authoritative: docked buds are never in an ear,
            // regardless of what OOBE events may have said before.
            if rt.placement.leftBudInCase  { s.leftInEar  = .outOfEar }
            if rt.placement.rightBudInCase { s.rightInEar = .outOfEar }
        }
        snapshot = s
        // If we connected while both buds were docked the firmware rejected
        // most settings reads with status 9, and the snapshot got published
        // with nil fields ("almost all gray"). Once a bud comes back out, the
        // firmware will answer those reads — but the subscription stream only
        // pushes settings on *change*, so we have to re-issue the reads
        // ourselves. One-shot, only for fields that are still missing.
        if wasBothInCase, !s.bothInCase {
            Task { [weak self] in await self?.refreshNilSettings() }
        }
    }

    /// Re-reads each setting whose snapshot value is still `nil` (or, for
    /// non-optional fields like ANC, still the sentinel `.unknown`). Called
    /// when placement transitions from "both buds docked" back to "at least
    /// one out", because that's the moment the firmware starts answering
    /// reads it previously rejected with status 9. We patch successes into
    /// the snapshot incrementally so partial recovery still helps the UI;
    /// failed reads stay nil and the next placement change will try again.
    /// Reads are sequential for the same reason the initial connect path
    /// is sequential — the buds dislike bursts of parallel RPCs.
    private func refreshNilSettings() async {
        guard let connection else { return }
        let svc = connection.service
        if snapshot?.anc == .unknown,
           let v = try? await svc.getAncState(), v != .unknown {
            patchSnapshot { $0.anc = v }
        }
        if snapshot?.conversationDetection == nil,
           let v = try? await svc.getSpeechDetection() {
            patchSnapshot { $0.conversationDetection = v }
        }
        if snapshot?.multipoint == nil,
           let v = try? await svc.getMultipointEnabled() {
            patchSnapshot { $0.multipoint = v }
        }
        if snapshot?.touchControls == nil,
           let v = try? await svc.getGestureEnabled() {
            patchSnapshot { $0.touchControls = v }
        }
        if snapshot?.gestureControl == nil,
           let v = try? await svc.getGestureControl() {
            patchSnapshot { $0.gestureControl = v }
        }
        if snapshot?.ancGestureLoop == nil,
           let v = try? await svc.getAncrGestureLoop() {
            patchSnapshot { $0.ancGestureLoop = v }
        }
        if snapshot?.onHeadDetection == nil,
           let v = try? await svc.getOnHeadDetection() {
            patchSnapshot { $0.onHeadDetection = v }
        }
        if snapshot?.volumeEqEnabled == nil,
           let v = try? await svc.getVolumeEqEnabled() {
            patchSnapshot { $0.volumeEqEnabled = v }
        }
        if snapshot?.eq == nil,
           let v = try? await svc.getCurrentUserEq() {
            patchSnapshot { $0.eq = v }
        }
        if snapshot?.volumeAsymmetry == nil,
           let v = try? await svc.getVolumeAsymmetry() {
            patchSnapshot { $0.volumeAsymmetry = v }
        }
        if snapshot?.monoAudio == nil,
           let v = try? await svc.getSumToMono() {
            patchSnapshot { $0.monoAudio = v }
        }
        if snapshot?.volumeExposureNotifications == nil,
           let v = try? await svc.getVolumeExposureNotifications() {
            patchSnapshot { $0.volumeExposureNotifications = v }
        }
        if snapshot?.ottsMode == nil,
           let v = try? await svc.getOttsMode() {
            patchSnapshot { $0.ottsMode = v }
        }
        if snapshot?.deviceInfo == nil,
           let sw = try? await svc.getSoftwareInfo(),
           let hw = try? await svc.getHardwareInfo() {
            let info = DeviceInfo(
                firmwareLeft: sw.firmware.left.versionString,
                firmwareRight: sw.firmware.right.versionString,
                firmwareCase: sw.firmware.case.versionString,
                serialLeft: hw.serialNumber.left,
                serialRight: hw.serialNumber.right,
                serialCase: hw.serialNumber.case
            )
            patchSnapshot { $0.deviceInfo = info }
        }
    }

    private func patchSnapshot(_ mutate: (inout BudsSnapshot) -> Void) {
        guard var s = snapshot else { return }
        mutate(&s)
        s.updatedAt = Date()
        snapshot = s
    }

    /// Applies a single OOBE proximity-sensor edge event to the snapshot.
    /// Only the four head-detection cases are handled; all others are ignored.
    private func applyOobeAction(_ action: MaestroPw_OobeAction) {
        guard var s = snapshot else { return }
        switch action {
        case .leftOnHead:   s.leftInEar  = .inEar
        case .leftOffHead:  s.leftInEar  = .outOfEar
        case .rightOnHead:  s.rightInEar = .inEar
        case .rightOffHead: s.rightInEar = .outOfEar
        default: return
        }
        s.updatedAt = Date()
        snapshot = s
    }
}
