// Per-workspace wallpaper: swap the desktop image of each screen to match
// the workspace visible on it. Hyprland delegates this to hyprpaper plus
// an IPC script; macOS lets us do it directly via
// NSWorkspace.setDesktopImageURL, so it's a built-in here.

import Cocoa

/// Applies per-workspace wallpapers on workspace switches and display
/// changes.
///
/// Config is `UserConfig.workspaceWallpapers` (workspace number as string
/// → image path). Workspaces without an entry leave the desktop image
/// untouched, so mixing "wallpapered" and default workspaces works.
///
/// The swap is instantaneous (no crossfade — macOS applies the image
/// directly), and the last applied path per screen is remembered so
/// repeated switches to the same workspace don't rewrite the desktop.
///
/// Threading: main-thread only.
final class WallpaperManager {

    private let workspaceManager: WorkspaceManager
    private let displayManager: DisplayManager
    private let config: UserConfig
    private var observers: [NSObjectProtocol] = []

    /// Last applied image path per screenID — avoids redundant
    /// setDesktopImageURL calls (they flash on some systems).
    private var lastApplied: [Int: String] = [:]

    init(workspaceManager: WorkspaceManager,
         displayManager: DisplayManager,
         config: UserConfig) {
        self.workspaceManager = workspaceManager
        self.displayManager = displayManager
        self.config = config
    }

    func start() {
        observers.append(NotificationCenter.default.addObserver(
            forName: .hyprMacWorkspaceChanged, object: nil, queue: .main) { [weak self] _ in
                self?.applyForVisibleWorkspaces()
            })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
                self?.lastApplied.removeAll()
                self?.applyForVisibleWorkspaces()
            })
        applyForVisibleWorkspaces()
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    /// Re-evaluate after the wallpaper config changed in Settings: drop
    /// the memo so edited entries re-apply immediately.
    func configChanged() {
        lastApplied.removeAll()
        applyForVisibleWorkspaces()
    }

    private func applyForVisibleWorkspaces() {
        guard !config.workspaceWallpapers.isEmpty else { return }
        for screen in displayManager.screens where !workspaceManager.isMonitorDisabled(screen) {
            let ws = workspaceManager.workspaceForScreen(screen)
            guard let rawPath = config.workspaceWallpapers[String(ws)], !rawPath.isEmpty else { continue }
            let path = (rawPath as NSString).expandingTildeInPath
            let sid = workspaceManager.screenID(for: screen)
            guard lastApplied[sid] != path else { continue }
            guard FileManager.default.fileExists(atPath: path) else {
                hyprLog(.warning, .config, "wallpaper for ws\(ws) not found: \(path)")
                continue
            }
            do {
                let url = URL(fileURLWithPath: path)
                let options = NSWorkspace.shared.desktopImageOptions(for: screen) ?? [:]
                try NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: options)
                lastApplied[sid] = path
                hyprLog(.debug, .lifecycle, "wallpaper: ws\(ws) on \(screen.localizedName) → \((path as NSString).lastPathComponent)")
            } catch {
                hyprLog(.warning, .config, "wallpaper: failed to set for ws\(ws): \(error.localizedDescription)")
            }
        }
    }
}
