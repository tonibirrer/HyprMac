// SwiftUI app entry. Composes the menu bar item and settings scene.
// Real lifecycle work lives in `AppDelegate`.

import SwiftUI
#if !HYPRMAC_DEBUG_VARIANT
import Sparkle
#endif

/// SwiftUI app shell.
@main
struct HyprMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    #if !HYPRMAC_DEBUG_VARIANT
    private let updaterController = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    #endif

    init() {
        Self.seedMenuBarPosition()
    }

    /// Items are laid out from the right edge; a larger preferred position sits
    /// further left. Without a stored value the wide indicator lands left of the
    /// notch cutoff and its menu becomes unreachable. Seed a small value once;
    /// a position the user (or macOS) already saved is left alone.
    private static func seedMenuBarPosition() {
        let key = "NSStatusItem Preferred Position Item-0"
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: key) == nil else { return }
        defaults.set(120, forKey: key)
    }

    var body: some Scene {
        MenuBarExtra {
            #if HYPRMAC_DEBUG_VARIANT
            MenuBarView(appDelegate: appDelegate)
            #else
            MenuBarView(appDelegate: appDelegate, updater: updaterController.updater)
            #endif
        } label: {
            WorkspaceIndicatorLabel()
        }
        .menuBarExtraStyle(.window)

        Window("HyprMac Settings", id: "settings") {
            SettingsView(showTutorial: { appDelegate.showTour() })
        }
        .defaultSize(width: 760, height: 600)
    }
}
