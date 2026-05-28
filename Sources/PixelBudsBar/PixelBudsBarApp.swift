import SwiftUI

@main
struct PixelBudsBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // Required by `App`, but the UI lives in the AppDelegate-managed
        // NSStatusItem so we just expose an empty Settings scene.
        Settings { EmptyView() }
    }
}
