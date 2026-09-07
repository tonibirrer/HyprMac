// User-facing configuration. SwiftUI views bind to the published
// properties; mutations write through to disk via `ConfigStore` and
// notify observers. Persists to
// `~/Library/Application Support/HyprMacExperiments/config.json`
// (`AppIdentity.directoryName` — separate from the stock app's).

import Foundation
import Cocoa

/// Persisted user preferences exposed as a SwiftUI-observable model.
///
/// Each public field is `@Published` so SwiftUI views and Combine
/// subscribers re-render on change. Every mutation writes through to
/// `ConfigStore` (debounce by `isReloading` during programmatic
/// reloads) and emits notifications to drive `WindowManager`'s live
/// re-tile / re-bind paths.
///
/// Threading: main-thread only. The shared singleton is accessed
/// directly across SwiftUI and orchestration code.
class UserConfig: ObservableObject {
    /// Process-wide singleton bound by SwiftUI views and the
    /// orchestration layer.
    static let shared = UserConfig()

    @Published var keybinds: [Keybind] {
        didSet { if !isReloading { save() } }
    }
    @Published var gapSize: CGFloat {
        didSet { if !isReloading { save() } }
    }
    @Published var outerPadding: CGFloat {
        didSet { if !isReloading { save() } }
    }
    @Published var enabled: Bool {
        didSet { if !isReloading { save() } }
    }
    @Published var focusFollowsMouse: Bool {
        didSet { if !isReloading { save() } }
    }
    @Published var mouseHoverPollHz: Int {
        didSet { if !isReloading { save() } }
    }
    @Published var hyprKey: HyprKey {
        didSet { if !isReloading { save() } }
    }
    @Published var excludedBundleIDs: Set<String> {
        didSet { if !isReloading { save() } }
    }
    @Published var showMenuBarIndicator: Bool {
        didSet { if !isReloading { save() } }
    }
    @Published var maxSplitsPerMonitor: [String: Int] {
        didSet { if !isReloading { save() } }
    }
    @Published var disabledMonitors: Set<String> {
        didSet { if !isReloading { save() } }
    }
    // all enabled screens show one workspace, tiles partitioned across
    // them by usable area. machine-local, stored in the monitor file.
    @Published var linkedMonitors: Bool {
        didSet { if !isReloading { save() } }
    }
    // accordion mode: when accordionMonitor is the only connected screen,
    // windows stack near-fullscreen instead of tiling. machine-local,
    // stored in the monitor file like linkedMonitors.
    @Published var accordionMode: Bool {
        didSet { if !isReloading { save() } }
    }
    // localizedName of the screen accordion applies to; nil = built-in
    @Published var accordionMonitor: String? {
        didSet { if !isReloading { save() } }
    }
    // visible px of the neighbor stacks on each side of the focused window
    @Published var accordionOverlap: CGFloat {
        didSet { if !isReloading { save() } }
    }
    @Published var showFocusBorder: Bool {
        didSet { if !isReloading { save() } }
    }
    // hex string like "007AFF" — nil means system accent color
    @Published var focusBorderColorHex: String? {
        didSet { if !isReloading { save() } }
    }
    // hex string for floating window border — nil means default orange
    @Published var floatingBorderColorHex: String? {
        didSet { if !isReloading { save() } }
    }
    @Published var dimInactiveWindows: Bool {
        didSet { if !isReloading { save() } }
    }
    // 0..1 alpha of the dimming overlay; 0.2 is subtle, 0.4 is strong
    @Published var dimIntensity: Double {
        didSet { if !isReloading { save() } }
    }
    // shared fade duration for the focus border show/hide and the dim
    // overlay opacity transitions. Settings slider clamps to a sensible
    // range; both subsystems read from this on every animation start.
    @Published var chromeFadeDurationSec: Double {
        didSet { if !isReloading { save() } }
    }
    // corner curvature shared by focus borders, brackets, and dim cut-outs
    @Published var windowCornerRadius: CGFloat {
        didSet { if !isReloading { save() } }
    }
    // windows sent to the scratchpad tile into the layer by default;
    // ones that don't fit stay floating members either way
    @Published var scratchpadTileByDefault: Bool {
        didSet { if !isReloading { save() } }
    }
    // per-edge inset fraction of the scratchpad's tiled region (0 = edge
    // to edge, 0.06 = classic scrimmed border)
    @Published var scratchpadRegionInset: CGFloat {
        didSet { if !isReloading { save() } }
    }
    // Hyprland-style app → workspace pins, matched by bundle ID on window
    // discovery. First match wins.
    @Published var windowRules: [WindowRule] {
        didSet { if !isReloading { save() } }
    }
    // per-side overrides of `outerPadding` (nil side = uniform value);
    // e.g. top-only padding to reserve space for sketchybar
    @Published var outerPaddingSides: PaddingSides {
        didSet { if !isReloading { save() } }
    }
    // per-workspace wallpaper image paths, keyed by workspace number as a
    // string ("1"..."9"). workspaces without an entry keep the current
    // desktop image.
    @Published var workspaceWallpapers: [String: String] {
        didSet { if !isReloading { save() } }
    }
    // per-workspace accent colors (hex), keyed by workspace number as a
    // string. drives the focus border on that workspace and is served
    // over IPC so status bars can color-match their indicators.
    @Published var workspaceColors: [String: String] {
        didSet { if !isReloading { save() } }
    }
    // workspaces that opt into showing sticky-ruled apps (WindowRule.sticky).
    // a sticky window follows the user between these workspaces on its
    // monitor and hides like any other window on workspaces not listed.
    // empty = sticky rules have no effect.
    @Published var stickyWorkspaces: Set<Int> {
        didSet { if !isReloading { save() } }
    }

    /// Focus-border accent for a window on `workspace` — the workspace's
    /// own color when set, else the global focus border color.
    func accentColor(forWorkspace workspace: Int?) -> NSColor {
        if let workspace, let hex = workspaceColors[String(workspace)],
           let c = NSColor.fromHex(hex) { return c }
        return resolvedFocusBorderColor
    }

    /// The uniform slider value with per-side overrides applied — what the
    /// tiling engine actually consumes.
    var resolvedOuterPadding: OuterPadding {
        OuterPadding(top: outerPaddingSides.top ?? outerPadding,
                     left: outerPaddingSides.left ?? outerPadding,
                     bottom: outerPaddingSides.bottom ?? outerPadding,
                     right: outerPaddingSides.right ?? outerPadding)
    }

    // iCloud sync state — stored in UserDefaults, not config.json
    @Published var iCloudSyncEnabled: Bool {
        didSet {
            UserDefaults.standard.set(iCloudSyncEnabled, forKey: "iCloudSyncEnabled")
            if iCloudSyncEnabled {
                store.enableICloudSync(snapshot: { [weak self] in self?.makeSavedConfig() ?? .empty })
            } else {
                store.disableICloudSync(snapshot: { [weak self] in self?.makeSavedConfig() ?? .empty })
            }
        }
    }

    /// Gates `didSet` save handlers during a programmatic reload.
    ///
    /// Every `@Published` property writes to disk in its `didSet`
    /// unless this flag is `true`. Without the flag, a single
    /// `reloadFromDisk` would rewrite the file 17 times — once per
    /// property update — and the file watcher would observe each
    /// write and re-fire reload in a tight loop. Set `true` *before*
    /// mass property updates, then `false`. Main-thread only.
    private var isReloading = false

    private let store: ConfigStore

    // path-shaped accessor used by SettingsView's "Reveal in Finder" affordance
    var configURL: URL { store.localConfigURL }

    var isICloudDriveAvailable: Bool { store.isICloudDriveAvailable }

    init() {
        self.store = ConfigStore()
        self.iCloudSyncEnabled = UserDefaults.standard.bool(forKey: "iCloudSyncEnabled")

        let monitorConfig = store.loadSavedMonitorConfig()
        let savedConfig = store.loadSavedConfig()

        if let saved = savedConfig {
            self.keybinds = Self.mergeNewDefaults(saved: saved.keybinds)
            self.gapSize = saved.gapSize
            self.outerPadding = saved.outerPadding
            self.enabled = saved.enabled
            self.focusFollowsMouse = saved.focusFollowsMouse ?? UserConfigDefaults.focusFollowsMouse
            self.mouseHoverPollHz = saved.mouseHoverPollHz ?? UserConfigDefaults.mouseHoverPollHz
            self.hyprKey = saved.hyprKey ?? UserConfigDefaults.hyprKey
            self.excludedBundleIDs = Set(saved.excludedBundleIDs ?? Self.defaultExcludedBundleIDs)
            self.showMenuBarIndicator = saved.showMenuBarIndicator ?? UserConfigDefaults.showMenuBarIndicator
            self.showFocusBorder = saved.showFocusBorder ?? UserConfigDefaults.showFocusBorder
            self.focusBorderColorHex = saved.focusBorderColorHex
            self.floatingBorderColorHex = saved.floatingBorderColorHex
            self.dimInactiveWindows = saved.dimInactiveWindows ?? UserConfigDefaults.dimInactiveWindows
            self.dimIntensity = saved.dimIntensity ?? UserConfigDefaults.dimIntensity
            self.chromeFadeDurationSec = saved.chromeFadeDurationSec ?? UserConfigDefaults.chromeFadeDurationSec
            self.windowCornerRadius = saved.windowCornerRadius ?? UserConfigDefaults.windowCornerRadius
            self.scratchpadTileByDefault = saved.scratchpadTileByDefault ?? UserConfigDefaults.scratchpadTileByDefault
            self.scratchpadRegionInset = saved.scratchpadRegionInset ?? UserConfigDefaults.scratchpadRegionInset
            self.windowRules = saved.windowRules ?? []
            self.outerPaddingSides = saved.outerPaddingSides ?? .none
            self.workspaceWallpapers = saved.workspaceWallpapers ?? [:]
            self.workspaceColors = saved.workspaceColors ?? [:]
            self.stickyWorkspaces = Set(saved.stickyWorkspaces ?? [])
        } else {
            self.keybinds = Keybind.defaults
            self.gapSize = UserConfigDefaults.gapSize
            self.outerPadding = UserConfigDefaults.outerPadding
            self.enabled = UserConfigDefaults.enabled
            self.focusFollowsMouse = UserConfigDefaults.focusFollowsMouse
            self.mouseHoverPollHz = UserConfigDefaults.mouseHoverPollHz
            self.hyprKey = UserConfigDefaults.hyprKey
            self.excludedBundleIDs = Set(Self.defaultExcludedBundleIDs)
            self.showMenuBarIndicator = UserConfigDefaults.showMenuBarIndicator
            self.showFocusBorder = UserConfigDefaults.showFocusBorder
            self.focusBorderColorHex = nil
            self.floatingBorderColorHex = nil
            self.dimInactiveWindows = UserConfigDefaults.dimInactiveWindows
            self.dimIntensity = UserConfigDefaults.dimIntensity
            self.chromeFadeDurationSec = UserConfigDefaults.chromeFadeDurationSec
            self.windowCornerRadius = UserConfigDefaults.windowCornerRadius
            self.scratchpadTileByDefault = UserConfigDefaults.scratchpadTileByDefault
            self.scratchpadRegionInset = UserConfigDefaults.scratchpadRegionInset
            self.windowRules = []
            self.outerPaddingSides = .none
            self.workspaceWallpapers = [:]
            self.workspaceColors = [:]
            self.stickyWorkspaces = []
        }

        // monitor settings: prefer the local file; fall back to (and migrate
        // from) the synced config if the local file isn't there yet.
        let resolved = ConfigMigration.resolveMonitorConfig(local: monitorConfig, embedded: savedConfig)
        self.maxSplitsPerMonitor = resolved.maxSplits
        self.disabledMonitors = resolved.disabled
        // linkedMonitors postdates the migration split — local file only
        self.linkedMonitors = monitorConfig?.linkedMonitors ?? UserConfigDefaults.linkedMonitors
        // accordion settings postdate the split too — local file only
        self.accordionMode = monitorConfig?.accordionMode ?? UserConfigDefaults.accordionMode
        self.accordionMonitor = monitorConfig?.accordionMonitor
        self.accordionOverlap = monitorConfig?.accordionOverlap ?? UserConfigDefaults.accordionOverlap

        if iCloudSyncEnabled {
            store.ensureICloudSymlinkIntegrity(snapshot: { [weak self] in self?.makeSavedConfig() ?? .empty })
        }

        if resolved.needsLocalWrite {
            store.writeSavedMonitorConfig(SavedMonitorConfig(
                maxSplitsPerMonitor: resolved.maxSplits,
                disabledMonitors: Array(resolved.disabled),
                linkedMonitors: linkedMonitors))
        }

        store.onFileChanged = { [weak self] in self?.reloadFromDisk() }
        store.startFileWatcher()
    }

    // inject any default keybinds whose action doesn't exist in the saved set.
    // handles upgrades where new actions are added (e.g. focusFloating).
    // never inject onto a chord the user already bound — the injected bind
    // would silently shadow (or be shadowed by) the user's, and neither is
    // discoverable. the user can bind the new action manually in Settings.
    private static func mergeNewDefaults(saved: [Keybind]) -> [Keybind] {
        let savedActions = Set(saved.map { "\($0.action)" })
        let takenChords = Set(saved.map { "\($0.modifiers.rawValue)-\($0.keyCode)" })
        var merged = saved
        for bind in Keybind.defaults {
            guard !savedActions.contains("\(bind.action)") else { continue }
            guard !takenChords.contains("\(bind.modifiers.rawValue)-\(bind.keyCode)") else {
                hyprLog(.notice, .config, "default keybind for \(bind.action) not injected — chord already bound by user")
                continue
            }
            merged.append(bind)
        }
        return merged
    }

    static let defaultExcludedBundleIDs: [String] = [
        "com.apple.FaceTime",
        "com.apple.systempreferences",
    ]

    /// Pending coalesced write. Every `@Published` `didSet` calls `save()`;
    /// a slider drag fires it per tick, and each write encodes and rewrites
    /// both files synchronously on the main thread — with the file watcher
    /// then reloading each write. Coalescing keeps the Settings UI fluid;
    /// `flushPendingSave` runs the write before the process exits.
    private var pendingSave: DispatchWorkItem?
    private static let saveCoalesceSec: TimeInterval = 0.3

    func save() {
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingSave = nil
            self.writeNow()
        }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.saveCoalesceSec, execute: work)
    }

    /// Write any coalesced change immediately. Call before quitting.
    func flushPendingSave() {
        guard let work = pendingSave else { return }
        work.cancel()
        pendingSave = nil
        writeNow()
    }

    private func writeNow() {
        store.writeSavedConfig(makeSavedConfig())
        store.writeSavedMonitorConfig(SavedMonitorConfig(
            maxSplitsPerMonitor: maxSplitsPerMonitor,
            disabledMonitors: Array(disabledMonitors),
            linkedMonitors: linkedMonitors,
            accordionMode: accordionMode,
            accordionMonitor: accordionMonitor,
            accordionOverlap: accordionOverlap))
    }

    // build a SavedConfig snapshot from the current @Published state.
    // monitor settings stay nil here — they're written separately to the
    // local-only monitor file via ConfigStore.writeSavedMonitorConfig.
    private func makeSavedConfig() -> SavedConfig {
        SavedConfig(
            version: nil,
            keybinds: keybinds, gapSize: gapSize,
            outerPadding: outerPadding, enabled: enabled,
            focusFollowsMouse: focusFollowsMouse,
            hyprKey: hyprKey,
            excludedBundleIDs: Array(excludedBundleIDs),
            showMenuBarIndicator: showMenuBarIndicator,
            maxSplitsPerMonitor: nil,
            disabledMonitors: nil,
            showFocusBorder: showFocusBorder,
            focusBorderColorHex: focusBorderColorHex,
            floatingBorderColorHex: floatingBorderColorHex,
            dimInactiveWindows: dimInactiveWindows,
            dimIntensity: dimIntensity,
            mouseHoverPollHz: mouseHoverPollHz,
            chromeFadeDurationSec: chromeFadeDurationSec,
            windowCornerRadius: windowCornerRadius,
            scratchpadTileByDefault: scratchpadTileByDefault,
            scratchpadRegionInset: scratchpadRegionInset,
            windowRules: windowRules,
            outerPaddingSides: outerPaddingSides == .none ? nil : outerPaddingSides,
            workspaceWallpapers: workspaceWallpapers.isEmpty ? nil : workspaceWallpapers,
            workspaceColors: workspaceColors.isEmpty ? nil : workspaceColors,
            stickyWorkspaces: stickyWorkspaces.isEmpty ? nil : stickyWorkspaces.sorted())
    }

    func resetToDefaults() {
        keybinds = Keybind.defaults
        gapSize = UserConfigDefaults.gapSize
        outerPadding = UserConfigDefaults.outerPadding
        enabled = UserConfigDefaults.enabled
        focusFollowsMouse = UserConfigDefaults.focusFollowsMouse
        mouseHoverPollHz = UserConfigDefaults.mouseHoverPollHz
        hyprKey = UserConfigDefaults.hyprKey
        excludedBundleIDs = Set(Self.defaultExcludedBundleIDs)
        showMenuBarIndicator = UserConfigDefaults.showMenuBarIndicator
        maxSplitsPerMonitor = [:]
        disabledMonitors = []
        linkedMonitors = UserConfigDefaults.linkedMonitors
        accordionMode = UserConfigDefaults.accordionMode
        accordionMonitor = nil
        accordionOverlap = UserConfigDefaults.accordionOverlap
        showFocusBorder = UserConfigDefaults.showFocusBorder
        focusBorderColorHex = nil
        floatingBorderColorHex = nil
        dimInactiveWindows = UserConfigDefaults.dimInactiveWindows
        dimIntensity = UserConfigDefaults.dimIntensity
        chromeFadeDurationSec = UserConfigDefaults.chromeFadeDurationSec
        windowCornerRadius = UserConfigDefaults.windowCornerRadius
        scratchpadTileByDefault = UserConfigDefaults.scratchpadTileByDefault
        scratchpadRegionInset = UserConfigDefaults.scratchpadRegionInset
        windowRules = []
        outerPaddingSides = .none
        workspaceWallpapers = [:]
        workspaceColors = [:]
        stickyWorkspaces = []
    }

    // resolve the border color — custom hex or brand cyan
    var resolvedFocusBorderColor: NSColor {
        if let hex = focusBorderColorHex, let c = NSColor.fromHex(hex) { return c }
        return NSColor.hyprCyan
    }

    // resolve floating border color — custom hex or brand magenta
    var resolvedFloatingBorderColor: NSColor {
        if let hex = floatingBorderColorHex, let c = NSColor.fromHex(hex) { return c }
        return NSColor.hyprMagenta
    }

    func reloadFromDisk() {
        guard let saved = store.loadSavedConfig() else { return }

        isReloading = true
        keybinds = saved.keybinds
        gapSize = saved.gapSize
        outerPadding = saved.outerPadding
        enabled = saved.enabled
        focusFollowsMouse = saved.focusFollowsMouse ?? true
        hyprKey = saved.hyprKey ?? .capsLock
        excludedBundleIDs = Set(saved.excludedBundleIDs ?? Self.defaultExcludedBundleIDs)
        showMenuBarIndicator = saved.showMenuBarIndicator ?? true
        showFocusBorder = saved.showFocusBorder ?? true
        focusBorderColorHex = saved.focusBorderColorHex
        floatingBorderColorHex = saved.floatingBorderColorHex
        dimInactiveWindows = saved.dimInactiveWindows ?? false
        dimIntensity = saved.dimIntensity ?? 0.2
        chromeFadeDurationSec = saved.chromeFadeDurationSec ?? UserConfigDefaults.chromeFadeDurationSec
        windowCornerRadius = saved.windowCornerRadius ?? UserConfigDefaults.windowCornerRadius
        scratchpadTileByDefault = saved.scratchpadTileByDefault ?? UserConfigDefaults.scratchpadTileByDefault
        scratchpadRegionInset = saved.scratchpadRegionInset ?? UserConfigDefaults.scratchpadRegionInset
        windowRules = saved.windowRules ?? []
        outerPaddingSides = saved.outerPaddingSides ?? .none
        workspaceWallpapers = saved.workspaceWallpapers ?? [:]
        workspaceColors = saved.workspaceColors ?? [:]
        stickyWorkspaces = Set(saved.stickyWorkspaces ?? [])

        // monitor settings come from the local file, not the synced config
        if let mc = store.loadSavedMonitorConfig() {
            maxSplitsPerMonitor = mc.maxSplitsPerMonitor ?? [:]
            disabledMonitors = Set(mc.disabledMonitors ?? [])
            linkedMonitors = mc.linkedMonitors ?? UserConfigDefaults.linkedMonitors
            accordionMode = mc.accordionMode ?? UserConfigDefaults.accordionMode
            accordionMonitor = mc.accordionMonitor
            accordionOverlap = mc.accordionOverlap ?? UserConfigDefaults.accordionOverlap
        }
        // else keep current values — don't overwrite with synced defaults

        isReloading = false
    }
}

// fallback used by ConfigStore's iCloud snapshot closure when the UserConfig
// reference has been deallocated — empty defaults are acceptable because the
// only call site is "user just toggled iCloud on a machine that's already
// shutting down," and we'd rather write a well-formed empty config than
// crash on a force-unwrap.
extension SavedConfig {
    static var empty: SavedConfig {
        SavedConfig(
            version: nil,
            keybinds: [],
            gapSize: UserConfigDefaults.gapSize,
            outerPadding: UserConfigDefaults.outerPadding,
            enabled: UserConfigDefaults.enabled,
            focusFollowsMouse: UserConfigDefaults.focusFollowsMouse,
            hyprKey: UserConfigDefaults.hyprKey,
            excludedBundleIDs: nil,
            showMenuBarIndicator: UserConfigDefaults.showMenuBarIndicator,
            maxSplitsPerMonitor: nil, disabledMonitors: nil,
            showFocusBorder: UserConfigDefaults.showFocusBorder,
            focusBorderColorHex: nil, floatingBorderColorHex: nil,
            dimInactiveWindows: UserConfigDefaults.dimInactiveWindows,
            dimIntensity: UserConfigDefaults.dimIntensity,
            mouseHoverPollHz: UserConfigDefaults.mouseHoverPollHz,
            chromeFadeDurationSec: UserConfigDefaults.chromeFadeDurationSec,
            windowCornerRadius: UserConfigDefaults.windowCornerRadius,
            scratchpadTileByDefault: UserConfigDefaults.scratchpadTileByDefault,
            scratchpadRegionInset: UserConfigDefaults.scratchpadRegionInset,
            windowRules: nil,
            outerPaddingSides: nil,
            workspaceWallpapers: nil,
            workspaceColors: nil,
            stickyWorkspaces: nil)
    }
}

extension NSColor {
    // returns nil + logs at .warning on malformed input. callers fall back
    // to a system color (controlAccentColor / systemOrange) so a corrupt or
    // empty hex string can't take down the focus-border / floating-border
    // pipeline. retained as `fromHex` for compat with existing call sites;
    // the logging is the phase-6 hardening per §11.1.
    static func fromHex(_ hex: String) -> NSColor? {
        let h = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard h.count == 6, let val = UInt64(h, radix: 16) else {
            hyprLog(.warning, .config,
                    "malformed hex color '\(hex)'; falling back to system default")
            return nil
        }
        return NSColor(red: CGFloat((val >> 16) & 0xFF) / 255,
                       green: CGFloat((val >> 8) & 0xFF) / 255,
                       blue: CGFloat(val & 0xFF) / 255, alpha: 1.0)
    }

    var hexString: String {
        guard let c = usingColorSpace(.sRGB) else { return "007AFF" }
        return String(format: "%02X%02X%02X",
                      Int(c.redComponent * 255),
                      Int(c.greenComponent * 255),
                      Int(c.blueComponent * 255))
    }
}
