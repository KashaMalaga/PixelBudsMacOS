import Foundation
import ServiceManagement
import AppKit
import Combine

/// Thin wrapper around `SMAppService.mainApp` so SwiftUI can bind a toggle to
/// the launch-at-login state without leaking ServiceManagement APIs.
///
/// Notes on signing: with ad-hoc signatures (the dev-time builds), macOS
/// marks the registered item as `.requiresApproval` and the user has to
/// flip the switch manually in System Settings → General → Login Items.
/// We surface this case by linking to the panel.
@MainActor
final class LoginItemManager: ObservableObject {
    /// Mirrors `SMAppService.Status` but as a Combine-friendly @Published.
    enum State: Equatable {
        case notRegistered
        case enabled
        case requiresApproval
        case notFound

        init(_ status: SMAppService.Status) {
            switch status {
            case .notRegistered: self = .notRegistered
            case .enabled:       self = .enabled
            case .requiresApproval: self = .requiresApproval
            case .notFound:      self = .notFound
            @unknown default:    self = .notRegistered
            }
        }
    }

    @Published private(set) var state: State = .notRegistered
    /// Set when the last register/unregister attempt failed. Cleared on next attempt.
    @Published private(set) var lastError: String?

    private let service = SMAppService.mainApp

    init() {
        refresh()
    }

    func refresh() {
        state = State(service.status)
    }

    /// Toggle target state. We mirror the user intent immediately and then
    /// re-read the actual status — covers the case where macOS demoted us to
    /// `.requiresApproval` instead of `.enabled`.
    func setEnabled(_ enabled: Bool) {
        lastError = nil
        do {
            if enabled {
                try service.register()
            } else {
                try service.unregister()
            }
        } catch {
            lastError = String(describing: error)
        }
        refresh()
    }

    /// Open the System Settings panel where the user can approve the item.
    /// Required path when `state == .requiresApproval`.
    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
