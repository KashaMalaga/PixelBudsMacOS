import SwiftUI
import KeyboardShortcuts
import MaestroIOBluetooth

// MARK: - Tab enum

private enum SettingsTab: String, CaseIterable, Identifiable {
    case general  = "General"
    case controls = "Controls"
    case audio    = "Audio"
    case about    = "About"

    var id: String { rawValue }

    var localizedLabel: LocalizedStringKey {
        switch self {
        case .general:  return "General"
        case .controls: return "Controls"
        case .audio:    return "Audio"
        case .about:    return "About"
        }
    }

    var icon: String {
        switch self {
        case .general:  return "gearshape"
        case .controls: return "hand.tap"
        case .audio:    return "waveform"
        case .about:    return "info.circle"
        }
    }
}

// MARK: - Root

struct SettingsView: View {
    @ObservedObject var model: BudsViewModel
    @ObservedObject var loginItem: LoginItemManager

    @AppStorage(AppDelegate.autoOpenOnLaunchKey) private var autoOpenOnLaunch = true
    @State private var selectedTab: SettingsTab? = .general

    var body: some View {
        NavigationSplitView {
            // `id: \.self` is the key bit: it makes the row identity match
            // the selection binding type (SettingsTab?) so clicks actually
            // update $selectedTab. Without it the shorthand picks up
            // Identifiable.ID (String) and clicks compile but never track.
            List(SettingsTab.allCases, id: \.self, selection: $selectedTab) { tab in
                Label(tab.localizedLabel, systemImage: tab.icon)
                    .padding(.vertical, 2)
            }
            .navigationSplitViewColumnWidth(min: 150, ideal: 175, max: 220)
        } detail: {
            detailContent
                .frame(minWidth: 480, minHeight: 480)
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 680, idealWidth: 720, minHeight: 580, idealHeight: 780)
        .onAppear { loginItem.refresh() }
    }

    // MARK: Detail scaffold

    @ViewBuilder
    private var detailContent: some View {
        VStack(spacing: 0) {
            // Persistent non-scrolling area: connection state (when notable) + banners
            statusAndBanners
            // Per-tab scrollable content
            switch selectedTab ?? .general {
            case .general:  generalTab
            case .controls: controlsTab
            case .audio:    audioTab
            case .about:    aboutTab
            }
        }
    }

    /// Shows a non-scrolling Form section at the top of the detail pane when
    /// there is something worth surfacing: we're not yet connected (so the user
    /// knows why controls are greyed), there's an active write error, or the
    /// buds are in the case. While fully connected and error-free the header is
    /// hidden entirely — letting the tab content breathe.
    @ViewBuilder
    private var statusAndBanners: some View {
        let showConnection = model.connectionState != .connected
        let showError      = model.lastWriteError != nil
        let showInCase     = model.snapshot?.bothInCase == true

        if showConnection || showError || showInCase {
            Form {
                if showConnection { connectionSection }
                if showError      { writeErrorBanner }
                if showInCase     { inCaseBanner }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - General tab

    private var generalTab: some View {
        Form {
            Section("Application") {
                Toggle(isOn: Binding(
                    get: { model.backgroundMonitoringEnabled },
                    set: { model.setBackgroundMonitoring($0) }
                )) {
                    labeledRow(
                        String(localized: "Background battery monitoring"),
                        String(localized: "Keeps the connection alive between popover sessions so the app can notify you when a bud or the case drops below 15%.")
                    )
                }
                Toggle(isOn: Binding(
                    get: { loginItem.state == .enabled || loginItem.state == .requiresApproval },
                    set: { loginItem.setEnabled($0) }
                )) {
                    labeledRow(String(localized: "Launch at login"), loginItemSubtitle)
                }
                Toggle(isOn: $autoOpenOnLaunch) {
                    labeledRow(
                        String(localized: "Open popover at launch"),
                        String(localized: "Pops the menu-bar popover every time the app starts so battery and connection are visible at a glance. Turn off for a quiet launch.")
                    )
                }
                HStack(alignment: .top) {
                    labeledRow(
                        String(localized: "Ring buds shortcut"),
                        String(localized: "Global hotkey that triggers \"Ring both\" from any app. Click the field and press your combination, or clear it to disable.")
                    )
                    Spacer()
                    KeyboardShortcuts.Recorder(for: .ringBuds)
                }
                if loginItem.state == .requiresApproval {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text("Approval required in System Settings.", comment: "Login item approval prompt")
                            .font(.caption)
                        Spacer()
                        Button(String(localized: "Open Login Items", comment: "Button to open Login Items settings")) {
                            loginItem.openLoginItemsSettings()
                        }
                        .controlSize(.small)
                    }
                }
                if let err = loginItem.lastError {
                    Text(err).font(.caption).foregroundStyle(.orange)
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Controls tab

    private var controlsTab: some View {
        Form {
            Section("Controls") {
                toggleRow(
                    title: String(localized: "Conversation detection"),
                    subtitle: String(localized: "Switches to Aware mode and pauses media when you start talking."),
                    value: model.snapshot?.conversationDetection,
                    onChange: model.setConversationDetection
                )
                toggleRow(
                    title: String(localized: "In-ear detection"),
                    subtitle: String(localized: "Pause media when an earbud is removed."),
                    value: model.snapshot?.onHeadDetection,
                    onChange: model.setOnHeadDetection
                )
                toggleRow(
                    title: String(localized: "Multipoint"),
                    subtitle: String(localized: "Stay connected to two Bluetooth devices at once."),
                    value: model.snapshot?.multipoint,
                    onChange: model.setMultipoint
                )
                toggleRow(
                    title: String(localized: "Touch controls"),
                    subtitle: String(localized: "Tap, swipe and hold gestures on the earbud stem."),
                    value: model.snapshot?.touchControls,
                    onChange: model.setTouchControls
                )
                toggleRow(
                    title: String(localized: "Mono audio"),
                    subtitle: String(localized: "Send the same mix to both earbuds so a single bud carries everything."),
                    value: model.snapshot?.monoAudio,
                    onChange: model.setMonoAudio
                )
            }
            Section("Hold Gesture") {
                if let gc = model.snapshot?.gestureControl {
                    Picker(String(localized: "Left earbud"), selection: gestureBinding(side: \.left, current: gc.left.type.value)) {
                        Text("Noise control", comment: "Hold gesture option").tag(MaestroPw_RegularActionTarget.actionTargetAncControl)
                        Text("Digital assistant", comment: "Hold gesture option").tag(MaestroPw_RegularActionTarget.actionTargetAssistantQuery)
                    }
                    .pickerStyle(.menu)
                    Picker(String(localized: "Right earbud"), selection: gestureBinding(side: \.right, current: gc.right.type.value)) {
                        Text("Noise control", comment: "Hold gesture option").tag(MaestroPw_RegularActionTarget.actionTargetAncControl)
                        Text("Digital assistant", comment: "Hold gesture option").tag(MaestroPw_RegularActionTarget.actionTargetAssistantQuery)
                    }
                    .pickerStyle(.menu)
                    Text("Long-press an earbud to trigger this action.", comment: "Hold gesture caption")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    placeholder(String(localized: "Loading hold gesture…", comment: "Loading placeholder"))
                }
            }
            Section("Noise Control Cycle") {
                if let loop = model.snapshot?.ancGestureLoop {
                    Toggle(String(localized: "Cancellation", comment: "ANC loop mode"), isOn: ancLoopBinding(\.active, current: loop))
                    Toggle(String(localized: "Off", comment: "ANC loop mode"), isOn: ancLoopBinding(\.off, current: loop))
                    Toggle(String(localized: "Aware (transparency)", comment: "ANC loop mode"), isOn: ancLoopBinding(\.aware, current: loop))
                    if model.snapshot?.supportsAdaptiveAnc == true {
                        Toggle(String(localized: "Adaptive", comment: "ANC loop mode"), isOn: ancLoopBinding(\.adaptive, current: loop))
                    }
                    Text("Modes the long-press cycles through when hold gesture is set to Noise control.", comment: "ANC cycle caption")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    placeholder(String(localized: "Loading ANC cycle…", comment: "Loading placeholder"))
                }
            }
        }
        .formStyle(.grouped)
        .disabled(model.connectionState != .connected)
    }

    // MARK: - Audio tab

    private var audioTab: some View {
        Form {
            EqualizerSection(model: model)
            BalanceSection(model: model)
            HearingHealthSection(model: model)
        }
        .formStyle(.grouped)
    }

    // MARK: - About tab

    /// Read-only device information. Shows connection state inline so the user
    /// always has somewhere to check "am I connected?" even when the status
    /// strip at the top of other tabs is hidden.
    private var aboutTab: some View {
        Form {
            Section("Connection") {
                switch model.connectionState {
                case .idle:
                    Label("Not connected", systemImage: "circle.dotted")
                        .foregroundStyle(.secondary)
                case .connecting:
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Connecting…", comment: "Connection state").foregroundStyle(.secondary)
                    }
                case .connected:
                    HStack(spacing: 6) {
                        Circle().fill(.green).frame(width: 6, height: 6)
                        Text(model.snapshot?.deviceName ?? String(localized: "Pixel Buds"))
                    }
                case .error(let message):
                    Label(message, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
                if let codec = model.snapshot?.activeCodec {
                    infoRow(String(localized: "Audio codec", comment: "Info row label"), codec)
                }
            }

            if let info = model.snapshot?.deviceInfo {
                Section("Firmware") {
                    infoRow(String(localized: "Left", comment: "Firmware side label"),  info.firmwareLeft)
                    infoRow(String(localized: "Right", comment: "Firmware side label"), info.firmwareRight)
                    if !info.firmwareCase.isEmpty {
                        infoRow(String(localized: "Case", comment: "Case firmware label"), info.firmwareCase)
                    }
                }
                Section("Serials") {
                    infoRow(String(localized: "Left", comment: "Serial side label"),  info.serialLeft,  monospaced: true)
                    infoRow(String(localized: "Right", comment: "Serial side label"), info.serialRight, monospaced: true)
                    if !info.serialCase.isEmpty {
                        infoRow(String(localized: "Case", comment: "Case serial label"), info.serialCase, monospaced: true)
                    }
                }
            } else {
                Section("Firmware") { placeholder(String(localized: "Loading device info…", comment: "Loading placeholder")) }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Shared section views

    @ViewBuilder
    private var connectionSection: some View {
        Section {
            switch model.connectionState {
            case .idle:
                Label("Not connected", systemImage: "circle.dotted")
                    .foregroundStyle(.secondary)
            case .connecting:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Connecting…", comment: "Connection state").foregroundStyle(.secondary)
                }
            case .connected:
                HStack(spacing: 6) {
                    Circle().fill(.green).frame(width: 6, height: 6)
                    Text(model.snapshot?.deviceName ?? String(localized: "Pixel Buds"))
                }
            case .error(let message):
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
        }
    }

    @ViewBuilder
    private var inCaseBanner: some View {
        Section {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "info.circle")
                    .foregroundStyle(.secondary)
                Text("Buds are in the case. Take one out and wear it to change settings.", comment: "In-case banner")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
            }
        }
    }

    @ViewBuilder
    private var writeErrorBanner: some View {
        if let message = model.lastWriteError {
            Section {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button {
                        model.clearWriteError()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.borderless)
                    .help("Dismiss")
                }
            }
        }
    }

    // MARK: - Helpers

    @ViewBuilder
    private func labeledRow(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var loginItemSubtitle: String {
        switch loginItem.state {
        case .enabled:          return String(localized: "Will start automatically when you log in.", comment: "Login item subtitle")
        case .requiresApproval: return String(localized: "Registered, but macOS needs you to approve it.", comment: "Login item subtitle")
        case .notRegistered:    return String(localized: "Off — start the app manually.", comment: "Login item subtitle")
        case .notFound:         return String(localized: "App bundle not found by macOS — try moving it to /Applications.", comment: "Login item subtitle")
        }
    }

    private func infoRow(_ label: String, _ value: String, monospaced: Bool = false) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value.isEmpty ? "—" : value)
                .font(monospaced ? .system(.body, design: .monospaced) : .body)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }

    private func placeholder(_ text: String) -> some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.small)
            Text(text).foregroundStyle(.secondary)
        }
    }

    private func toggleRow(
        title: String,
        subtitle: String,
        value: Bool?,
        onChange: @escaping (Bool) -> Void
    ) -> some View {
        let binding = Binding<Bool>(
            get: { value ?? false },
            set: onChange
        )
        return Toggle(isOn: binding) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .disabled(value == nil || model.connectionState != .connected)
    }

    private func gestureBinding(
        side: WritableKeyPath<MaestroPw_GestureControl, MaestroPw_DeviceGestureControl>,
        current: MaestroPw_RegularActionTarget
    ) -> Binding<MaestroPw_RegularActionTarget> {
        Binding(
            get: { current },
            set: { newValue in
                guard var gc = model.snapshot?.gestureControl else { return }
                gc[keyPath: side].type.value = newValue
                model.setGestureControl(gc)
            }
        )
    }

    private func ancLoopBinding(
        _ keyPath: WritableKeyPath<MaestroPw_AncrGestureLoop, Bool>,
        current loop: MaestroPw_AncrGestureLoop
    ) -> Binding<Bool> {
        Binding(
            get: { loop[keyPath: keyPath] },
            set: { newValue in
                var newLoop = loop
                newLoop[keyPath: keyPath] = newValue
                model.setAncGestureLoop(newLoop)
            }
        )
    }
}

// MARK: - Equalizer

/// 5-band parametric EQ with a live visual bar chart above the sliders.
/// `inProgress` captures the in-flight drag state so we fire exactly one RPC
/// write per gesture (on slider release) instead of one per tick.
private struct EqualizerSection: View {
    @ObservedObject var model: BudsViewModel
    @State private var inProgress: MaestroPw_EqBands?

    var body: some View {
        Section("Equalizer") {
            presetPicker
            volumeEqToggle
            if let bands = effectiveBands {
                // Mini bar chart — gives immediate visual feedback as you drag.
                EqVisual(bands: bands)
                    .listRowSeparator(.hidden)
                slider(label: String(localized: "Low bass", comment: "EQ band label"),    keyPath: \.lowBass,    current: bands.lowBass)
                slider(label: String(localized: "Bass", comment: "EQ band label"),        keyPath: \.bass,       current: bands.bass)
                slider(label: String(localized: "Mid", comment: "EQ band label"),         keyPath: \.mid,        current: bands.mid)
                slider(label: String(localized: "Treble", comment: "EQ band label"),      keyPath: \.treble,     current: bands.treble)
                slider(label: String(localized: "Upper treble", comment: "EQ band label"),keyPath: \.upperTreble,current: bands.upperTreble)
                HStack {
                    Text("Each band ranges from -6 dB to +6 dB.", comment: "EQ caption")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(String(localized: "Reset to flat", comment: "EQ reset button")) {
                        var flat = MaestroPw_EqBands()
                        flat.lowBass = 0; flat.bass = 0; flat.mid = 0
                        flat.treble = 0; flat.upperTreble = 0
                        inProgress = nil
                        model.setEq(flat)
                    }
                    .controlSize(.small)
                }
            } else {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Loading equalizer…", comment: "Loading placeholder").foregroundStyle(.secondary)
                }
            }
        }
        .disabled(model.connectionState != .connected)
    }

    /// A menu-style picker that shows the active named preset (or "Custom" when
    /// the sliders are in a user-adjusted state). Selecting a preset writes all
    /// five bands at once and clears any in-flight drag state.
    @ViewBuilder
    private var presetPicker: some View {
        let selectedID = inProgress != nil ? "custom" : (model.snapshot?.eqPreset?.id ?? "custom")
        Picker("Preset", selection: Binding<String>(
            get: { selectedID },
            set: { id in
                inProgress = nil
                if let preset = EqPreset.all.first(where: { $0.id == id }) {
                    model.setEqPreset(preset)
                }
            }
        )) {
            ForEach(EqPreset.all) { preset in
                Text(preset.displayName).tag(preset.id)
            }
            Divider()
            Text("Custom").tag("custom")
        }
        .pickerStyle(.menu)
        .disabled(model.snapshot?.eq == nil || model.connectionState != .connected)
    }

    private var effectiveBands: MaestroPw_EqBands? {
        inProgress ?? model.snapshot?.eq
    }

    @ViewBuilder
    private var volumeEqToggle: some View {
        let value = model.snapshot?.volumeEqEnabled
        Toggle(isOn: Binding(
            get: { value ?? false },
            set: { model.setVolumeEqEnabled($0) }
        )) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Volume EQ", comment: "Volume EQ toggle title")
                Text("Boost bass automatically at low volume.", comment: "Volume EQ caption")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .disabled(value == nil || model.connectionState != .connected)
    }

    private func slider(
        label: String,
        keyPath: WritableKeyPath<MaestroPw_EqBands, Float>,
        current: Float
    ) -> some View {
        HStack {
            Text(label)
                .frame(width: 110, alignment: .leading)
            Slider(
                value: Binding(
                    get: { Double(effectiveBands?[keyPath: keyPath] ?? 0) },
                    set: { newValue in
                        var bands = effectiveBands ?? MaestroPw_EqBands()
                        bands[keyPath: keyPath] = Float(newValue)
                        inProgress = bands
                    }
                ),
                in: -6...6,
                onEditingChanged: { editing in
                    guard !editing, let bands = inProgress else { return }
                    model.setEq(bands)
                    inProgress = nil
                }
            )
            Text(String(format: "%+.1f dB", current))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 56, alignment: .trailing)
        }
    }
}

// MARK: - EQ Visual

/// Five-band bar chart rendered above the EQ sliders. Positive boosts grow
/// upward from the centre line; cuts grow downward. The bars animate smoothly
/// as `bands` changes (slider drag, preset switch, remote settings update).
private struct EqVisual: View {
    let bands: MaestroPw_EqBands

    private var values: [(label: String, value: Float)] {[
        ("Sub",  bands.lowBass),
        ("Bass", bands.bass),
        ("Mid",  bands.mid),
        ("Hi",   bands.treble),
        ("Air",  bands.upperTreble),
    ]}

    var body: some View {
        HStack(spacing: 0) {
            ForEach(values, id: \.label) { item in
                EqBarView(label: item.label, value: item.value)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.primary.opacity(0.04))
        )
    }
}

/// Single vertical bar centred on a zero line. Uses a fixed-height three-zone
/// layout (positive zone / centre line / negative zone) so positive and
/// negative bars animate independently without repositioning each other.
private struct EqBarView: View {
    let label: String
    let value: Float  // -6 … +6 dB

    private let halfPx: CGFloat = 28   // height of each half-zone

    private var posH: CGFloat { value > 0 ? CGFloat( value) / 6.0 * halfPx : 0 }
    private var negH: CGFloat { value < 0 ? CGFloat(-value) / 6.0 * halfPx : 0 }

    var body: some View {
        VStack(spacing: 4) {
            VStack(spacing: 0) {
                // Positive zone — bar anchored at its bottom (the centre line)
                ZStack(alignment: .bottom) {
                    Color.clear.frame(height: halfPx)
                    if posH > 0 {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.accentColor)
                            .frame(width: 12, height: posH)
                    }
                }

                // Centre line
                Color.secondary.opacity(0.25)
                    .frame(height: 1)

                // Negative zone — bar anchored at its top (the centre line)
                ZStack(alignment: .top) {
                    Color.clear.frame(height: halfPx)
                    if negH > 0 {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.accentColor.opacity(0.5))
                            .frame(width: 12, height: negH)
                    }
                }
            }
            .animation(.spring(duration: 0.2), value: value)

            Text(label)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Balance

/// Volume asymmetry between left and right earbud. Wire format: Int32 0…200,
/// even = left bias, odd = right bias, raw/2 = magnitude. Surfaced as
/// -100…+99 centred at 0.
private struct BalanceSection: View {
    @ObservedObject var model: BudsViewModel
    @State private var inProgress: Int?

    var body: some View {
        Section("Balance") {
            if let raw = model.snapshot?.volumeAsymmetry {
                let displayed = inProgress ?? Self.userValue(fromRaw: raw)
                HStack(spacing: 8) {
                    Text("L").foregroundStyle(.secondary)
                    Slider(
                        value: Binding(
                            get: { Double(displayed) },
                            set: { inProgress = Int($0.rounded()) }
                        ),
                        in: -100...99,
                        onEditingChanged: { editing in
                            guard !editing, let v = inProgress else { return }
                            model.setVolumeAsymmetry(Self.raw(fromUserValue: v))
                            inProgress = nil
                        }
                    )
                    Text("R").foregroundStyle(.secondary)
                }
                Text(Self.label(for: displayed))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                HStack {
                    Text("Bias playback towards one earbud. If L/R seems swapped on your firmware, let me know.", comment: "Balance caption")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(String(localized: "Center", comment: "Balance reset button")) {
                        inProgress = nil
                        model.setVolumeAsymmetry(0)
                    }
                    .controlSize(.small)
                }
            } else {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Loading balance…", comment: "Loading placeholder").foregroundStyle(.secondary)
                }
            }
        }
        .disabled(model.connectionState != .connected)
    }

    static func userValue(fromRaw raw: Int32) -> Int {
        let r = Int(raw)
        let magnitude = r / 2
        let isRightBias = r % 2 == 1
        return isRightBias ? magnitude : -magnitude
    }

    static func raw(fromUserValue v: Int) -> Int32 {
        let mag = abs(v)
        return Int32(mag * 2 + (v > 0 ? 1 : 0))
    }

    private static func label(for value: Int) -> String {
        if value == 0 { return String(localized: "Centered", comment: "Balance centered label") }
        if value < 0  { return String(localized: "Left +\(-value)%", comment: "Balance left bias label") }
        return String(localized: "Right +\(value)%", comment: "Balance right bias label")
    }
}

// MARK: - Hearing Health Section

private struct HearingHealthSection: View {
    @ObservedObject var model: BudsViewModel

    var body: some View {
        Section("Hearing Health") {
            volumeExposureToggle
        }
    }

    @ViewBuilder
    private var volumeExposureToggle: some View {
        if let enabled = model.snapshot?.volumeExposureNotifications {
            Toggle(isOn: Binding(
                get: { enabled },
                set: { model.setVolumeExposureNotifications($0) }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Loud volume warnings", comment: "Hearing health toggle title")
                    Text("Notifies you after prolonged listening at high volume.",
                         comment: "Hearing health toggle subtitle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } else {
            HStack {
                Text("Loud volume warnings", comment: "Hearing health toggle title")
                Spacer()
                ProgressView().controlSize(.small)
            }
        }
    }
}
