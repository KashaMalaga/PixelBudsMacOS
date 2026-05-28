import SwiftUI
import MaestroIOBluetooth

struct BudsPopoverView: View {
    @ObservedObject var model: BudsViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Divider()

            if let snap = model.snapshot {
                batteryRows(snap)
                if snap.bothInCase {
                    inCaseHint
                }
                Divider()
                ancControl(snap)
            } else if case .error(let message) = model.connectionState {
                errorView(message)
            } else {
                connectingPlaceholder
            }

            if let writeError = model.lastWriteError {
                writeErrorBanner(writeError)
            }

            Spacer(minLength: 0)
            footer
        }
        .padding(16)
        .frame(width: 280)
        .onAppear { model.acquireConnection() }
        .onDisappear { model.releaseConnection() }
    }

    /// Small inline banner for failed setting writes (e.g. ANC change rejected
    /// because the buds aren't in ears). The connection itself is still fine.
    private func writeErrorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .imageScale(.small)
            Text(message)
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button {
                model.clearWriteError()
            } label: {
                Image(systemName: "xmark")
                    .imageScale(.small)
            }
            .buttonStyle(.borderless)
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(.orange.opacity(0.1))
        )
    }

    private var header: some View {
        HStack {
            Text(model.snapshot?.deviceName ?? "Pixel Buds")
                .font(.headline)
            Spacer()
            statusIndicator
        }
    }

    private var statusIndicator: some View {
        Group {
            switch model.connectionState {
            case .idle:
                Text("Idle", comment: "Connection state label in popover header").foregroundStyle(.secondary)
            case .connecting:
                HStack(spacing: 4) {
                    ProgressView().controlSize(.small)
                    Text("Connecting…", comment: "Connection state label").foregroundStyle(.secondary)
                }
            case .connected:
                HStack(spacing: 4) {
                    Circle().fill(.green).frame(width: 6, height: 6)
                    Text("Connected", comment: "Connection state label").foregroundStyle(.secondary)
                    if let codec = model.snapshot?.activeCodec {
                        Text("· \(codec)")
                            .foregroundStyle(.tertiary)
                    }
                }
            case .error:
                HStack(spacing: 4) {
                    Circle().fill(.red).frame(width: 6, height: 6)
                    Text("Error", comment: "Connection error label").foregroundStyle(.secondary)
                }
            }
        }
        .font(.caption)
    }

    private var connectingPlaceholder: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(0..<3, id: \.self) { _ in
                HStack {
                    RoundedRectangle(cornerRadius: 4).fill(.quaternary).frame(width: 60, height: 14)
                    Spacer()
                    RoundedRectangle(cornerRadius: 4).fill(.quaternary).frame(width: 40, height: 14)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func errorView(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Couldn't connect", systemImage: "exclamationmark.triangle")
                .font(.subheadline)
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func batteryRows(_ snap: BudsViewModel.BudsSnapshot) -> some View {
        VStack(spacing: 8) {
            BatteryRow(
                label: String(localized: "Left", comment: "Earbud side label"),
                percent: Int(snap.leftBattery),
                charging: snap.leftCharging,
                placement: snap.leftInCase ? String(localized: "in case", comment: "Earbud placement label") : nil
            )
            BatteryRow(
                label: String(localized: "Right", comment: "Earbud side label"),
                percent: Int(snap.rightBattery),
                charging: snap.rightCharging,
                placement: snap.rightInCase ? String(localized: "in case", comment: "Earbud placement label") : nil
            )
            if snap.caseChargingKnown {
                BatteryRow(
                    label: String(localized: "Case", comment: "Battery case label"),
                    percent: Int(snap.caseBattery),
                    charging: snap.caseCharging,
                    placement: nil
                )
            }
        }
    }

    private func ancControl(_ snap: BudsViewModel.BudsSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Noise Control", comment: "ANC section title").font(.subheadline)
            Picker("", selection: ancBinding(snap)) {
                Text("Off", comment: "ANC mode off").tag(MaestroPw_AncState.off)
                Text("Active", comment: "ANC mode active").tag(MaestroPw_AncState.active)
                Text("Aware", comment: "ANC mode aware/transparency").tag(MaestroPw_AncState.aware)
                if snap.supportsAdaptiveAnc {
                    Text("Adaptive", comment: "ANC mode adaptive").tag(MaestroPw_AncState.adaptive)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            // Firmware refuses ANC writes while both buds are docked, so we
            // disable the picker and let the in-case banner explain why.
            .disabled(snap.bothInCase)
        }
    }

    /// Informational banner shown when both buds are sitting in the case.
    /// Most settings writes will fail with status 9 in that state, so we tell
    /// the user upfront instead of letting them discover it through errors.
    private var inCaseHint: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
                .imageScale(.small)
            Text("Buds are in the case. Take one out and wear it to change settings.", comment: "In-case hint banner")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.secondary.opacity(0.08))
        )
    }

    private func ancBinding(_ snap: BudsViewModel.BudsSnapshot) -> Binding<MaestroPw_AncState> {
        Binding(
            get: { snap.anc },
            set: { model.setAnc($0) }
        )
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if let s = model.snapshot {
                Text("Updated \(s.updatedAt, format: .dateTime.hour().minute().second())")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if model.snapshot?.canRingBuds == true {
                findMenu
            }
            Button {
                NotificationCenter.default.post(name: .openPixelBudsSettings, object: nil)
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help("Settings…")
            Button(String(localized: "Quit", comment: "Quit application button")) {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
        }
    }

    /// Drop-down for the GFPS "ring my buds" command. Only renders when the
    /// secondary GFPS channel actually opened. We keep a separate Stop entry
    /// because the buds keep beeping until they hear a tap or our stop frame.
    private var findMenu: some View {
        Menu {
            Button(String(localized: "Ring both", comment: "Ring both buds menu item")) { model.ringBuds(.both) }
            Button(String(localized: "Ring left only", comment: "Ring left bud menu item")) { model.ringBuds(.left) }
            Button(String(localized: "Ring right only", comment: "Ring right bud menu item")) { model.ringBuds(.right) }
            Divider()
            Button(String(localized: "Stop ringing", comment: "Stop ring menu item")) { model.ringBuds(.stop) }
        } label: {
            Image(systemName: "bell")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .controlSize(.small)
        .help("Find my buds")
    }
}

private struct BatteryRow: View {
    let label: String
    let percent: Int
    let charging: Bool
    let placement: String?

    var body: some View {
        HStack {
            Text(label).frame(width: 50, alignment: .leading)
            BatteryBar(percent: percent, charging: charging)
            HStack(spacing: 4) {
                Text("\(percent)%")
                    .font(.system(.body, design: .monospaced))
                if charging {
                    Image(systemName: "bolt.fill").foregroundStyle(.green).imageScale(.small)
                }
                if let placement {
                    Text(placement).font(.caption2).foregroundStyle(.secondary)
                }
            }
            .frame(width: 90, alignment: .trailing)
        }
    }
}

private struct BatteryBar: View {
    let percent: Int
    let charging: Bool

    private var fraction: CGFloat {
        CGFloat(max(0, min(100, percent))) / 100.0
    }

    private var color: Color {
        if percent < 20 { return .red }
        if percent < 40 { return .yellow }
        return .green
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(.quaternary)
                RoundedRectangle(cornerRadius: 3)
                    .fill(color)
                    .frame(width: geo.size.width * fraction)
            }
        }
        .frame(height: 10)
    }
}
