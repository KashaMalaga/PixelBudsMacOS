import Sparkle

/// Thin wrapper around SPUStandardUpdaterController.
/// Owned by AppDelegate for its lifetime; calling checkForUpdates() opens
/// Sparkle's standard update UI.
final class UpdaterController {
    private let controller: SPUStandardUpdaterController

    init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}
