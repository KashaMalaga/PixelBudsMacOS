import Foundation
import UserNotifications

/// Tracks battery levels across snapshot updates and posts a UNNotification
/// when a bud (or the case) drops below a low-battery threshold for the
/// first time. Re-arms only after the level recovers past a higher mark, so
/// noisy readings that flap around the threshold don't spam the user.
///
/// Notifications are app-level UX; we keep this class out of `BudsViewModel`
/// to make it obvious from `AppDelegate` where the side effect originates.
@MainActor
final class LowBatteryNotifier {
    /// Below this percent we surface a notification.
    private let lowThreshold = 15
    /// Hysteresis: a bud must climb back to at least this percent before we
    /// re-arm. Without the gap, a reading flapping between 14 and 16 would
    /// re-fire every couple of seconds.
    private let rearmThreshold = 20

    /// Per-bud "armed" flag. Armed → next low reading fires; disarmed →
    /// silently track until the level crosses `rearmThreshold`.
    private var leftArmed = true
    private var rightArmed = true
    private var caseArmed = true

    /// First time we'd fire, we ask macOS for permission. We do it lazily
    /// (rather than at app launch) so users who never see a low reading
    /// don't get an out-of-context system prompt.
    private var requestedAuthorization = false

    func process(snapshot: BudsViewModel.BudsSnapshot) {
        // Skip a bud while it's actively charging. The user already knows
        // they docked it; firing a "low battery" right after they put it
        // in the case is the opposite of useful.
        if !snapshot.leftCharging {
            leftArmed = step(
                level: Int(snapshot.leftBattery),
                armed: leftArmed,
                label: String(localized: "Left bud")
            )
        }
        if !snapshot.rightCharging {
            rightArmed = step(
                level: Int(snapshot.rightBattery),
                armed: rightArmed,
                label: String(localized: "Right bud")
            )
        }
        // For the case we don't fire while it's plugged into a charger.
        // `caseChargingKnown` gates on whether we have a reading at all.
        if snapshot.caseChargingKnown && !snapshot.caseCharging {
            caseArmed = step(
                level: Int(snapshot.caseBattery),
                armed: caseArmed,
                label: String(localized: "Case")
            )
        }
    }

    /// Computes the new armed state for a single bud given the latest level.
    /// Returns the new armed value so the caller can store it.
    private func step(level: Int, armed: Bool, label: String) -> Bool {
        if armed && level <= lowThreshold {
            fire(label: label, level: level)
            return false
        }
        if !armed && level >= rearmThreshold {
            return true
        }
        return armed
    }

    private func fire(label: String, level: Int) {
        ensureAuthorization()
        let content = UNMutableNotificationContent()
        content.title = String(localized: "\(label) battery low")
        content.body = String(localized: "\(level)% remaining — consider charging soon.")
        content.sound = .default
        // Use a stable identifier per source so re-firing (in the rare case
        // hysteresis re-arms and the level dips again) replaces the previous
        // notification in Notification Center rather than stacking.
        let request = UNNotificationRequest(
            identifier: "pixelBudsBar.lowBattery.\(label)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }

    private func ensureAuthorization() {
        guard !requestedAuthorization else { return }
        requestedAuthorization = true
        UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .sound]
        ) { _, _ in
            // We don't track the result; if the user denies, the next
            // `add(...)` call silently drops and nothing bad happens.
        }
    }
}
