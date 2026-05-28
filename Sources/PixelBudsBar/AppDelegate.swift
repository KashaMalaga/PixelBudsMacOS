import AppKit
import Combine
import KeyboardShortcuts
import MaestroIOBluetooth
import SwiftUI

extension Notification.Name {
    /// Posted by the popover (or anywhere else in the UI) to ask the
    /// AppDelegate to open the settings window. Using a notification keeps
    /// SwiftUI views decoupled from the concrete delegate type.
    static let openPixelBudsSettings = Notification.Name("openPixelBudsSettings")
}

/// Owns the menu-bar UI: NSStatusItem with our custom icon + battery %,
/// plus an NSPopover that hosts BudsPopoverView. The model state is observed
/// via Combine so the status item label tracks @Published changes.
///
/// We use NSStatusItem instead of SwiftUI's MenuBarExtra because MenuBarExtra
/// doesn't expose programmatic control over its popover — we need that to
/// auto-open on first launch so the user discovers the icon.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let model = BudsViewModel()
    let loginItem = LoginItemManager()
    private let lowBatteryNotifier = LowBatteryNotifier()
    private let updater = UpdaterController()

    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var cancellables: Set<AnyCancellable> = []

    /// Settings window is created lazily on first open and reused afterwards.
    private var settingsWindow: NSWindow?
    /// True while the settings window has acquired the model's connection.
    /// Prevents double-acquire on re-open and double-release on close.
    private var settingsHoldsConnection = false

    /// Toggleable from Settings → Application. When true (the default) we
    /// pop the popover every time the app launches, so the latest battery
    /// and connection state are visible without clicking. False starts the
    /// app silent — the icon is there, but nothing pops.
    static let autoOpenOnLaunchKey = "pixelBudsBar.autoOpenOnLaunch"

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        configureStatusItem()
        configurePopover()
        observeModel()

        // If the user has background monitoring enabled (default ON) acquire
        // a long-lived connection slot now so battery alerts work without
        // requiring the popover to be open.
        model.bootstrapBackgroundMonitoring()

        // Register the system-wide hotkey for "ring both buds". The handler
        // only fires when the user has configured a combination in Settings;
        // until then KeyboardShortcuts ignores it silently.
        KeyboardShortcuts.onKeyUp(for: .ringBuds) { [weak self] in
            guard let self else { return }
            // Only attempt the ring if the GFPS channel actually opened —
            // otherwise we'd just produce a confusing write error in the UI.
            guard self.model.snapshot?.canRingBuds == true else { return }
            self.model.ringBuds(.both)
        }

        NotificationCenter.default.addObserver(
            forName: .openPixelBudsSettings,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // `queue: .main` guarantees we're on the main queue at runtime,
            // but the closure type itself is nonisolated. Assume isolation
            // so the call into our @MainActor method type-checks without an
            // extra Task hop.
            MainActor.assumeIsolated {
                self?.openSettings()
            }
        }

        // Launch UX: pop the popover so battery / connection state are
        // immediately visible. Two subtleties make this trickier than a
        // straight `showPopover()`:
        //  * AppKit needs a beat to lay out the status item, otherwise
        //    `popover.show(relativeTo:of:)` anchors to a button whose
        //    window isn't on screen yet and nothing renders.
        //  * Accessory apps start inactive, so a .transient popover
        //    dismisses itself the same run-loop tick it opens. Calling
        //    `NSApp.activate(...)` first makes it stick until the user
        //    clicks somewhere else.
        let defaults = UserDefaults.standard
        let autoOpenAllowed = defaults.object(forKey: Self.autoOpenOnLaunchKey) as? Bool ?? true
        if autoOpenAllowed {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self else { return }
                NSApp.activate(ignoringOtherApps: true)
                self.showPopover()
            }
        }
    }

    // MARK: - Setup

    private func configureStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem.button else { return }
        button.action = #selector(handleStatusItemClick(_:))
        button.target = self
        // Left = popover, right = NSMenu. We intentionally don't set
        // `statusItem.menu` directly because that hijacks the left-click too;
        // dispatching on both events and branching on `currentEvent.type`
        // keeps left-click behavior unchanged.
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        refreshStatusItem()
    }

    private func configurePopover() {
        popover.behavior = .transient
        popover.animates = true
        let hosting = NSHostingController(rootView: BudsPopoverView(model: model))
        // Let the popover size itself to whatever SwiftUI's intrinsic content
        // size happens to be (depends on number of battery rows, error state, etc.)
        hosting.sizingOptions = .preferredContentSize
        popover.contentViewController = hosting
    }

    private func observeModel() {
        Publishers
            .CombineLatest(model.$snapshot, model.$connectionState)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _ in self?.refreshStatusItem() }
            .store(in: &cancellables)

        // Funnel each new snapshot into the low-battery notifier. Distinct
        // values only, so a noisy stream of identical snapshots doesn't
        // matter — the notifier already has hysteresis but skipping the
        // re-evaluation entirely is cheaper.
        model.$snapshot
            .compactMap { $0 }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] snap in
                self?.lowBatteryNotifier.process(snapshot: snap)
            }
            .store(in: &cancellables)
    }

    // MARK: - Status item rendering

    private func refreshStatusItem() {
        guard let button = statusItem?.button else { return }
        if case .error = model.connectionState {
            button.image = NSImage(systemSymbolName: "exclamationmark.circle",
                                   accessibilityDescription: "Pixel Buds — error")
            button.title = ""
        } else {
            // ANC badge: only show a colored dot when ANC is actively doing
            // something. For Off/Unknown we keep the plain template so the
            // icon still inverts on click and follows label color naturally.
            let ancBadge = Self.ancBadgeColor(for: model.snapshot?.anc)
            let lowBattery = Self.hasLowBattery(snapshot: model.snapshot)
            button.image = Self.budsIcon(ancBadge: ancBadge, lowBattery: lowBattery)
            if let pct = model.menuBarBatteryPercent {
                button.title = " \(pct)%"
            } else {
                button.title = ""
            }
        }
    }

    private static func ancBadgeColor(for state: MaestroPw_AncState?) -> NSColor? {
        switch state {
        case .active:   return .systemBlue
        case .aware:    return .systemGreen
        case .adaptive: return .systemPurple
        default:        return nil
        }
    }

    /// True when any non-charging source (left, right, case) is at or below
    /// the same threshold the notifier uses (15%). We deliberately skip a bud
    /// that's actively charging — same reasoning as LowBatteryNotifier: the
    /// user just docked it, surfacing a "low" indicator is noise.
    private static func hasLowBattery(snapshot: BudsViewModel.BudsSnapshot?) -> Bool {
        guard let s = snapshot else { return false }
        let threshold: Int32 = 15
        if !s.leftCharging && s.leftBattery > 0 && s.leftBattery <= threshold { return true }
        if !s.rightCharging && s.rightBattery > 0 && s.rightBattery <= threshold { return true }
        if s.caseChargingKnown && !s.caseCharging && s.caseBattery > 0 && s.caseBattery <= threshold {
            return true
        }
        return false
    }

    // MARK: - Popover lifecycle

    @objc private func handleStatusItemClick(_ sender: Any?) {
        // `currentEvent` is set by AppKit to the event that fired the action,
        // so we can tell apart left vs. right click without subclassing the
        // status bar button.
        if NSApp.currentEvent?.type == .rightMouseUp {
            showContextMenu()
            return
        }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            showPopover()
        }
    }

    private func showPopover() {
        guard let button = statusItem?.button else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        // Bring the popover's window to front so it doesn't render behind other apps.
        popover.contentViewController?.view.window?.makeKey()
    }

    /// Builds and displays the right-click NSMenu next to the status item.
    /// We construct it fresh each time so item enablement (Ring) reflects the
    /// current snapshot without needing a validator selector.
    private func showContextMenu() {
        guard let statusItem else { return }
        let menu = NSMenu()

        let ringItem = NSMenuItem(
            title: "Ring both buds",
            action: #selector(menuRingBuds),
            keyEquivalent: ""
        )
        ringItem.target = self
        ringItem.isEnabled = model.snapshot?.canRingBuds == true
        menu.addItem(ringItem)

        menu.addItem(.separator())

        let checkUpdatesItem = NSMenuItem(
            title: "Check for Updates…",
            action: #selector(menuCheckForUpdates),
            keyEquivalent: ""
        )
        checkUpdatesItem.target = self
        menu.addItem(checkUpdatesItem)

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(
            title: "Settings…",
            action: #selector(menuOpenSettings),
            keyEquivalent: ","
        )
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "Quit Pixel Buds Bar",
            action: #selector(menuQuit),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)

        // Attach + pop + detach: setting `statusItem.menu = nil` after the
        // user dismisses the menu means the next left-click still opens the
        // popover (otherwise AppKit would re-show this menu).
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func menuCheckForUpdates() {
        updater.checkForUpdates()
    }

    @objc private func menuRingBuds() {
        guard model.snapshot?.canRingBuds == true else { return }
        model.ringBuds(.both)
    }

    @objc private func menuOpenSettings() {
        openSettings()
    }

    @objc private func menuQuit() {
        NSApp.terminate(nil)
    }

    // MARK: - Settings window

    /// Open (or refocus) the settings window. Holds a connection ticket while
    /// the window is visible so the popover closing afterwards doesn't churn
    /// the RFCOMM channel.
    func openSettings() {
        if settingsWindow == nil {
            let controller = NSHostingController(
                rootView: SettingsView(model: model, loginItem: loginItem)
            )
            controller.sizingOptions = .preferredContentSize

            // Build the window explicitly so size + style mask are guaranteed,
            // rather than relying on NSWindow(contentViewController:) defaults.
            // The sidebar layout asks for ~720×780 via its idealWidth/idealHeight;
            // matching the initial rect avoids a visible reflow on first open.
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 720, height: 780),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.contentViewController = controller
            window.title = "Pixel Buds Settings"
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            settingsWindow = window
        }
        // Acquire BEFORE popover closes so we don't drop count to 0 in the
        // middle of switching surfaces.
        if !settingsHoldsConnection {
            model.acquireConnection()
            settingsHoldsConnection = true
        }
        // Accessory apps don't bring windows to front via .activate alone;
        // temporarily switch to .regular so the OS treats the settings window
        // as a real app window. We flip back to .accessory on close.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        // Bounce to the main actor since the protocol method is nonisolated.
        Task { @MainActor in
            guard let window = notification.object as? NSWindow,
                  window == self.settingsWindow else { return }
            if self.settingsHoldsConnection {
                self.model.releaseConnection()
                self.settingsHoldsConnection = false
            }
            // Revert to menu-bar-only mode now that no window is visible.
            NSApp.setActivationPolicy(.accessory)
        }
    }

    // MARK: - Resources

    private static let iconSize = NSSize(width: 18, height: 18)

    /// Raw template glyph loaded once from the resource bundle. Kept as a
    /// template image so it follows the menu bar tint when used without a
    /// badge (Off/Unknown ANC).
    private static let budsTemplate: NSImage? = {
        for bundle in [Bundle.main, Bundle.module] {
            if let url = bundle.url(forResource: "BudsTemplate", withExtension: "png"),
               let img = NSImage(contentsOf: url) {
                img.size = iconSize
                img.isTemplate = true
                return img
            }
        }
        return nil
    }()

    /// Compose the menu-bar icon with optional badges:
    /// - `ancBadge`: bottom-right colored dot reflecting current ANC state.
    /// - `lowBattery`: top-right red dot when any source is below the
    ///   notifier's threshold. Stays visible regardless of the popover state.
    /// When neither badge is set, returns the bare template so AppKit keeps
    /// handling tinting and click-inversion natively.
    private static func budsIcon(ancBadge: NSColor?, lowBattery: Bool) -> NSImage? {
        guard let template = budsTemplate else { return nil }
        if ancBadge == nil && !lowBattery { return template }

        let size = iconSize
        let composite = NSImage(size: size, flipped: false) { rect in
            // 1. Paint the whole rect with the foreground color, then mask
            //    to the template's alpha. This effectively tints the glyph.
            NSColor.labelColor.setFill()
            rect.fill()
            template.draw(in: rect,
                          from: .zero,
                          operation: .destinationIn,
                          fraction: 1.0)

            // 2. Draw each badge in its own corner. The halo punch + colored
            //    fill pattern is identical for both — only the corner differs.
            let dotSize: CGFloat = 7
            let inset: CGFloat = 0.5
            if let badge = ancBadge {
                let dotRect = NSRect(
                    x: rect.maxX - dotSize - inset,
                    y: rect.minY + inset,
                    width: dotSize,
                    height: dotSize
                )
                drawBadgeDot(in: dotRect, color: badge)
            }
            if lowBattery {
                let dotRect = NSRect(
                    x: rect.maxX - dotSize - inset,
                    y: rect.maxY - dotSize - inset,
                    width: dotSize,
                    height: dotSize
                )
                drawBadgeDot(in: dotRect, color: .systemRed)
            }
            return true
        }
        composite.size = size
        // Re-render on every draw so labelColor tracks appearance changes
        // (light/dark mode, accessibility tint) without us having to observe.
        composite.cacheMode = .never
        composite.isTemplate = false
        return composite
    }

    /// Punch a transparent halo + fill a colored dot. Shared by the ANC and
    /// low-battery badges so they look consistent when both are visible.
    private static func drawBadgeDot(in dotRect: NSRect, color: NSColor) {
        let haloRect = dotRect.insetBy(dx: -1.5, dy: -1.5)
        NSColor.clear.setFill()
        let halo = NSBezierPath(ovalIn: haloRect)
        NSGraphicsContext.current?.cgContext.setBlendMode(.clear)
        halo.fill()
        NSGraphicsContext.current?.cgContext.setBlendMode(.normal)

        color.setFill()
        NSBezierPath(ovalIn: dotRect).fill()
    }
}
