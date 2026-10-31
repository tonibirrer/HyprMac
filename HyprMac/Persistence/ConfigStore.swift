// On-disk persistence for user config. File paths, raw JSON load /
// save, iCloud Drive sync lifecycle (move + symlink), and a file
// watcher that fires when the file changes externally.

import Foundation

/// Owns the on-disk representation of `UserConfig`.
///
/// File paths, JSON I/O for `SavedConfig` and `SavedMonitorConfig`,
/// and the iCloud Drive sync lifecycle: enabling sync moves the
/// config to iCloud Drive and replaces the local path with a
/// symlink; disabling sync resolves the symlink, copies the data
/// back, and removes the link. Also runs a file watcher that
/// notifies `UserConfig` when the file changes (iCloud sync from
/// another machine or a manual edit).
///
/// Not responsible for schema migration (lives in `ConfigMigration`),
/// the `@Published` observable surface (lives in `UserConfig`), or
/// building a `SavedConfig` from runtime state (lives in
/// `UserConfig`).
final class ConfigStore {

    // MARK: - paths

    static let configDir: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent(AppIdentity.directoryName, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// The stock HyprMac app's directory. Source of the one-time import in
    /// `ConfigMigration.importUpstreamDirectory`; never written to.
    static let upstreamConfigDir: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        .appendingPathComponent(AppIdentity.upstreamDirectoryName, isDirectory: true)

    init(localConfigURL: URL = ConfigStore.configPath) {
        self.localConfigURL = localConfigURL
        // first launch with a dedicated directory: carry the config over
        // from the shared one so the switch is invisible; the stock app
        // keeps its files untouched. a store on another file (the watcher
        // tests) never touches the real directory
        if localConfigURL == Self.configPath {
            ConfigMigration.importUpstreamDirectory(from: Self.upstreamConfigDir, to: Self.configDir)
        }
    }

    // main config — may be a symlink to iCloud when sync is on
    static let configPath = configDir.appendingPathComponent("config.json")

    // monitor-specific settings — always local, never synced
    static let monitorConfigPath = configDir.appendingPathComponent("monitor-config.json")

    // iCloud Drive path — no entitlements needed, just plain file access
    var iCloudConfigURL: URL {
        let iCloudDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/\(AppIdentity.iCloudDirectoryName)", isDirectory: true)
        return iCloudDir.appendingPathComponent("config.json")
    }

    let localConfigURL: URL
    var monitorConfigURL: URL { Self.monitorConfigPath }

    /// `localConfigURL` is injectable so tests can watch a scratch file.

    var isICloudDriveAvailable: Bool {
        FileManager.default.fileExists(atPath:
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs").path)
    }

    // MARK: - file watcher

    // fired (on main queue) when the watched file changes from disk.
    // owners typically reload state in response.
    var onFileChanged: (() -> Void)?

    private var fileWatcherSource: DispatchSourceFileSystemObject?
    private var fileWatcherFD: Int32 = -1
    // bumped by stopFileWatcher so a pending re-arm retry knows it's stale
    private var rearmGeneration = 0
    private static let rearmMaxDelay: TimeInterval = 4

    // MARK: - load

    func loadSavedConfig() -> SavedConfig? {
        guard let data = try? Data(contentsOf: localConfigURL),
              let saved = try? JSONDecoder().decode(SavedConfig.self, from: data) else { return nil }
        return saved
    }

    func loadSavedMonitorConfig() -> SavedMonitorConfig? {
        guard let data = try? Data(contentsOf: monitorConfigURL),
              let mc = try? JSONDecoder().decode(SavedMonitorConfig.self, from: data) else { return nil }
        return mc
    }

    // MARK: - save

    func writeSavedConfig(_ saved: SavedConfig) {
        if let data = try? JSONEncoder().encode(saved) {
            try? data.write(to: localConfigURL)
        }
    }

    func writeSavedMonitorConfig(_ mc: SavedMonitorConfig) {
        if let data = try? JSONEncoder().encode(mc) {
            try? data.write(to: monitorConfigURL)
        }
    }

    // MARK: - iCloud Drive sync

    // enable iCloud sync — moves the local file (or current state via the
    // snapshot closure) to iCloud, then symlinks the local path at it.
    func enableICloudSync(snapshot: () -> SavedConfig) {
        let fm = FileManager.default
        let iCloudDir = iCloudConfigURL.deletingLastPathComponent()

        try? fm.createDirectory(at: iCloudDir, withIntermediateDirectories: true)

        if fm.fileExists(atPath: localConfigURL.path) {
            let isSymlink = (try? localConfigURL.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink ?? false
            if !isSymlink {
                // move local file to iCloud location (overwrite if already present)
                if fm.fileExists(atPath: iCloudConfigURL.path) {
                    try? fm.removeItem(at: iCloudConfigURL)
                }
                try? fm.moveItem(at: localConfigURL, to: iCloudConfigURL)
            }
        } else {
            // no local file — write current state, then move it across
            writeSavedConfig(snapshot())
            if fm.fileExists(atPath: localConfigURL.path) {
                try? fm.moveItem(at: localConfigURL, to: iCloudConfigURL)
            }
        }

        if !fm.fileExists(atPath: localConfigURL.path) {
            try? fm.createSymbolicLink(at: localConfigURL, withDestinationURL: iCloudConfigURL)
        }

        restartFileWatcher()
    }

    // disable iCloud sync — read data via the symlink, remove it, write the
    // data back as a regular file. snapshot is a fallback if the read fails.
    func disableICloudSync(snapshot: () -> SavedConfig) {
        let fm = FileManager.default
        let isSymlink = (try? localConfigURL.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink ?? false

        if isSymlink {
            let data = try? Data(contentsOf: localConfigURL)
            try? fm.removeItem(at: localConfigURL) // removes the symlink only

            if let data = data {
                try? data.write(to: localConfigURL)
            } else {
                writeSavedConfig(snapshot())
            }
        }

        restartFileWatcher()
    }

    // verify symlink integrity when iCloudSyncEnabled is set in UserDefaults
    // but the local path is no longer a symlink (e.g. first launch on a new
    // machine where iCloud Drive hasn't materialized the file yet).
    func ensureICloudSymlinkIntegrity(snapshot: () -> SavedConfig) {
        let fm = FileManager.default
        let isSymlink = (try? localConfigURL.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink ?? false
        guard !isSymlink else { return }

        if fm.fileExists(atPath: iCloudConfigURL.path) {
            try? fm.removeItem(at: localConfigURL)
            try? fm.createSymbolicLink(at: localConfigURL, withDestinationURL: iCloudConfigURL)
        } else {
            // iCloud file doesn't exist — set up fresh
            enableICloudSync(snapshot: snapshot)
        }
    }

    // MARK: - file watcher

    func startFileWatcher() {
        stopFileWatcher()

        // resolve the actual file path (follows symlinks)
        let watchPath = localConfigURL.resolvingSymlinksInPath().path
        let fd = open(watchPath, O_EVTONLY)
        guard fd >= 0 else { return }
        fileWatcherFD = fd

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete],
            queue: .main
        )
        source.setEventHandler { [weak self, unowned source] in
            guard let self else { return }
            let replaced = !source.data.isDisjoint(with: [.rename, .delete])
            self.onFileChanged?()
            // an atomic save (most editors, `mv tmp config.json`) swaps in a
            // new inode and leaves this fd on the unlinked old one, which
            // never fires again. re-open the path so later edits still land
            if replaced {
                hyprLog(.notice, .config, "config file replaced on disk, re-arming watcher")
                self.rearmAfterReplace()
            }
        }
        source.setCancelHandler {
            close(fd)
        }
        source.resume()
        fileWatcherSource = source
    }

    var isWatchingFile: Bool { fileWatcherSource != nil }

    func stopFileWatcher() {
        fileWatcherSource?.cancel()
        fileWatcherSource = nil
        fileWatcherFD = -1
        rearmGeneration += 1
    }

    // re-open the path after the file was replaced. editors that rename the
    // old file away before writing the new one leave nothing to open for a
    // moment, so keep retrying with backoff. once the new file is watched,
    // reload again: a save that landed in the gap fired no event.
    private func rearmAfterReplace(delay: TimeInterval = 0.5) {
        stopFileWatcher()
        let generation = rearmGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, generation == self.rearmGeneration else { return }
            self.startFileWatcher()
            if self.isWatchingFile {
                self.onFileChanged?()
            } else {
                if delay == 0.5 {
                    hyprLog(.notice, .config, "config file missing at re-arm, retrying")
                }
                self.rearmAfterReplace(delay: min(delay * 2, Self.rearmMaxDelay))
            }
        }
    }

    func restartFileWatcher() {
        stopFileWatcher()
        // small delay — let the filesystem settle after move/symlink ops.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.startFileWatcher()
        }
    }
}

// MARK: - on-disk schemas

// the keys here are the v0.4.2 wire format. additions go behind Optional<T>
// so older configs decode without throwing; explicit defaults are applied
// in the loader.
//
// `version` was added in phase 6. it's optional so v0.4.2 configs (where the
// field is absent) still decode — ConfigMigration treats nil as version 1.
// the field is intentionally written as nil today so byte-equal round-trip
// holds for unchanged settings; future schema bumps will start emitting a
// concrete value when migration logic actually exists.
struct SavedConfig: Codable {
    let version: Int?
    let keybinds: [Keybind]
    let gapSize: CGFloat
    let outerPadding: CGFloat
    let enabled: Bool
    let focusFollowsMouse: Bool?
    let hyprKey: HyprKey?
    let excludedBundleIDs: [String]?
    let showMenuBarIndicator: Bool?
    var overlayAppearance: OverlayAppearance? = nil
    let maxSplitsPerMonitor: [String: Int]?
    let disabledMonitors: [String]?
    let showFocusBorder: Bool?
    let focusBorderColorHex: String?
    let floatingBorderColorHex: String?
    let focusBracketStyle: FocusBracketStyle?
    let focusBracketColorHex: String?
    let focusBracketRadius: CGFloat?
    let focusBracketThickness: CGFloat?
    var focusBracketLength: CGFloat? = nil
    let dimInactiveWindows: Bool?
    let dimIntensity: Double?
    let mouseHoverPollHz: Int?
    let chromeFadeDurationSec: Double?
    let windowCornerRadius: CGFloat?
    let scratchpadTileByDefault: Bool?
    let scratchpadRegionInset: CGFloat?
    // fork additions (HyprMacExperiments). `var` with a default, like
    // upstream's later fields, so upstream's `SavedConfig(...)` call sites
    // compile without naming them.
    var outerPaddingSides: PaddingSides? = nil
    var workspaceWallpapers: [String: String]? = nil
    var workspaceColors: [String: String]? = nil
    // workspaces (1...workspaceCount) that show sticky-ruled apps; sorted on write
    var stickyWorkspaces: [Int]? = nil
    // `var` with a default so the synthesized memberwise init takes it as a
    // trailing optional — existing `SavedConfig(...)` call sites keep compiling.
    var restoreLayoutOnLaunch: Bool? = nil
    var windowRules: [WindowRule]? = nil
    var workspaceNames: [String: String]? = nil
    // fork: per-app effects beside upstream's pins (see AppRule)
    var appRules: [AppRule]? = nil
}

/// The fork's retired global per-side padding (`outerPaddingSides`). Read
/// once so `ConfigMigration.perMonitorPadding` can move it onto upstream's
/// per-monitor overrides; never written again.
struct PaddingSides: Codable, Equatable {
    var top: CGFloat?
    var left: CGFloat?
    var bottom: CGFloat?
    var right: CGFloat?

    static let none = PaddingSides(top: nil, left: nil, bottom: nil, right: nil)
}

// MARK: - per-keybind decode tolerance

// SavedConfig decodes its keybinds one element at a time, so one bad entry
// can't take the whole config with it. config.json is shared between machines
// over iCloud, so an older build will meet actions a newer build wrote and
// knows nothing about. before this, a single unknown action key threw, the
// `try?` in loadSavedConfig returned nil, and every setting on the older
// machine reset to defaults. its next save then pushed the reset back out.
//
// the decoder lives in an extension so the memberwise init stays available to
// callers and tests, and encoding stays synthesized: the wire format does not
// change.
extension SavedConfig {

    enum CodingKeys: String, CodingKey {
        case version, keybinds, gapSize, outerPadding, enabled
        case focusFollowsMouse, hyprKey, excludedBundleIDs, showMenuBarIndicator, overlayAppearance
        case maxSplitsPerMonitor, disabledMonitors
        case showFocusBorder, focusBorderColorHex, floatingBorderColorHex
        case focusBracketStyle, focusBracketColorHex, focusBracketRadius, focusBracketThickness
        case focusBracketLength
        case dimInactiveWindows, dimIntensity, mouseHoverPollHz
        case chromeFadeDurationSec, windowCornerRadius
        case scratchpadTileByDefault, scratchpadRegionInset
        // fork additions (HyprMacExperiments)
        case outerPaddingSides, workspaceWallpapers, workspaceColors
        case stickyWorkspaces
        case appRules = "experimentsAppRules"
        case restoreLayoutOnLaunch
        case windowRules
        case workspaceNames
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)

        // keep every keybind that decodes; skip and log the rest. an empty
        // result is fine: UserConfig.mergeNewDefaults re-injects the defaults.
        var kept: [Keybind] = []
        var arr = try c.nestedUnkeyedContainer(forKey: .keybinds)
        while !arr.isAtEnd {
            // decodeNil advances past a null element; decode() would not.
            if (try? arr.decodeNil()) == true {
                hyprLog(.warning, .config, "skipping null entry in keybinds")
                continue
            }
            guard let element = try? arr.decode(FailableKeybind.self) else {
                // shouldn't happen, FailableKeybind swallows its own errors.
                // bail out rather than spin on an index that never advances.
                hyprLog(.warning, .config, "stopped decoding keybinds early on an unreadable element")
                break
            }
            if let kb = element.keybind { kept.append(kb) }
        }
        self.keybinds = kept

        // the core fields stay strict: every build since v0.4.2 writes them,
        // with these types. version too, since it will pick which migrations run.
        self.version = try c.decodeIfPresent(Int.self, forKey: .version)
        self.gapSize = try c.decode(CGFloat.self, forKey: .gapSize)
        self.outerPadding = try c.decode(CGFloat.self, forKey: .outerPadding)
        self.enabled = try c.decode(Bool.self, forKey: .enabled)
        self.focusFollowsMouse = Self.tolerant(c, .focusFollowsMouse)
        // an unknown value, like a case a newer build added, is the default Hypr key
        self.hyprKey = Self.tolerant(c, .hyprKey)
        self.excludedBundleIDs = Self.tolerant(c, .excludedBundleIDs)
        self.showMenuBarIndicator = Self.tolerant(c, .showMenuBarIndicator)
        self.overlayAppearance = c.contains(.overlayAppearance)
            ? ((try? c.decode(OverlayAppearance.self, forKey: .overlayAppearance))
                ?? UserConfigDefaults.overlayAppearance)
            : nil
        self.maxSplitsPerMonitor = Self.tolerant(c, .maxSplitsPerMonitor)
        self.disabledMonitors = Self.tolerant(c, .disabledMonitors)
        self.showFocusBorder = Self.tolerant(c, .showFocusBorder)
        self.focusBorderColorHex = Self.tolerant(c, .focusBorderColorHex)
        self.floatingBorderColorHex = Self.tolerant(c, .floatingBorderColorHex)
        // A style added by a newer build must not invalidate the whole config.
        // Key presence also marks the new bracket schema, so an unknown value
        // cannot accidentally reimport the old focus-border color.
        if c.contains(.focusBracketStyle) {
            self.focusBracketStyle = (try? c.decode(
                FocusBracketStyle.self,
                forKey: .focusBracketStyle)) ?? UserConfigDefaults.focusBracketStyle
        } else {
            self.focusBracketStyle = nil
        }
        self.focusBracketColorHex = Self.tolerant(c, .focusBracketColorHex)
        self.focusBracketRadius = Self.tolerant(c, .focusBracketRadius)
        self.focusBracketThickness = Self.tolerant(c, .focusBracketThickness)
        self.focusBracketLength = Self.tolerant(c, .focusBracketLength)
        self.dimInactiveWindows = Self.tolerant(c, .dimInactiveWindows)
        self.dimIntensity = Self.tolerant(c, .dimIntensity)
        self.mouseHoverPollHz = Self.tolerant(c, .mouseHoverPollHz)
        self.chromeFadeDurationSec = Self.tolerant(c, .chromeFadeDurationSec)
        self.windowCornerRadius = Self.tolerant(c, .windowCornerRadius)
        self.scratchpadTileByDefault = Self.tolerant(c, .scratchpadTileByDefault)
        self.scratchpadRegionInset = Self.tolerant(c, .scratchpadRegionInset)
        // fork additions (HyprMacExperiments)
        self.outerPaddingSides = Self.tolerant(c, .outerPaddingSides)
        self.workspaceWallpapers = Self.tolerant(c, .workspaceWallpapers)
        self.workspaceColors = Self.tolerant(c, .workspaceColors)
        self.stickyWorkspaces = Self.tolerant(c, .stickyWorkspaces)
        self.restoreLayoutOnLaunch = Self.tolerant(c, .restoreLayoutOnLaunch)
        let windowRules = Self.tolerantWindowRules(c)
        self.workspaceNames = Self.tolerantWorkspaceNames(c)
        if c.contains(.appRules) {
            self.windowRules = windowRules
            self.appRules = Self.tolerant(c, .appRules)
        } else {
            // a config from before the fork took upstream's pins: its
            // windowRules entries carry the fork's effects, which upstream's
            // WindowRule drops on the next save. move them out first
            let legacy = Self.legacyForkRuleEffects(c)
            self.appRules = legacy
            self.windowRules = legacy == nil
                ? windowRules
                : windowRules?.filter { Constants.workspaceRange.contains($0.workspace) }
        }
    }

    // keys "1"…"10" with a non-empty name; anything else is dropped, so a
    // hand edit can't leave a stray key that nothing ever shows
    private static func tolerantWorkspaceNames(_ c: KeyedDecodingContainer<CodingKeys>) -> [String: String]? {
        let valid = Set(Constants.workspaceRange.map(String.init))
        let names: [String: String]? = tolerant(c, .workspaceNames)
        let kept = names?.filter { valid.contains($0.key) && !$0.value.isEmpty }
        return kept?.isEmpty == false ? kept : nil
    }

    // the fork's effects inside legacy windowRules entries, one AppRule per
    // entry that sets any. nil when no entry does: nothing to move. entries
    // that only carried a priority (workspace 0) leave the pins
    private static func legacyForkRuleEffects(_ c: KeyedDecodingContainer<CodingKeys>) -> [AppRule]? {
        guard c.contains(.windowRules), (try? c.decodeNil(forKey: .windowRules)) == false,
              var arr = try? c.nestedUnkeyedContainer(forKey: .windowRules) else { return nil }
        var effects: [AppRule] = []
        while !arr.isAtEnd {
            if (try? arr.decodeNil()) == true { continue }
            guard let element = try? arr.decode(FailableAppRule.self) else { break }
            if let rule = element.rule, rule.hasEffect { effects.append(rule) }
        }
        guard !effects.isEmpty else { return nil }
        hyprLog(.notice, .config, "config.json: moved \(effects.count) app rule effect(s) out of windowRules into experimentsAppRules")
        return effects
    }

    // same per-element tolerance as keybinds: the rules are hand-editable
    // and travel between builds over iCloud, so a bad rule costs only itself
    private static func tolerantWindowRules(_ c: KeyedDecodingContainer<CodingKeys>) -> [WindowRule]? {
        guard c.contains(.windowRules), (try? c.decodeNil(forKey: .windowRules)) == false else { return nil }
        guard var arr = try? c.nestedUnkeyedContainer(forKey: .windowRules) else {
            hyprLog(.notice, .config, "config.json has a windowRules value this build can't read; using no rules")
            return nil
        }
        var kept: [WindowRule] = []
        while !arr.isAtEnd {
            if (try? arr.decodeNil()) == true { continue }
            guard let element = try? arr.decode(FailableWindowRule.self) else { break }
            if let rule = element.rule { kept.append(rule) }
        }
        return kept
    }

    // one optional field. a value this build can't read (a case a newer
    // build added, a changed type, a hand-edit typo) costs just that field,
    // which is treated as missing, instead of the whole config. the value
    // stays out of the log because it is hand-editable text.
    private static func tolerant<T: Decodable>(_ c: KeyedDecodingContainer<CodingKeys>,
                                               _ key: CodingKeys) -> T? {
        do {
            return try c.decodeIfPresent(T.self, forKey: key)
        } catch {
            hyprLog(.notice, .config,
                    "config.json has a \(key.stringValue) value this build can't read; using the default")
            return nil
        }
    }
}

// one keybind, or nil when it doesn't decode. catching the error in here is
// the whole trick: the array's decode() call succeeds, so the unkeyed
// container moves past the bad element instead of throwing out of the array.
private struct FailableKeybind: Decodable {
    let keybind: Keybind?

    init(from decoder: Decoder) throws {
        do {
            keybind = try Keybind(from: decoder)
        } catch {
            keybind = nil
            // the action key is hand-editable text, so it stays out of the log
            hyprLog(.warning, .config, "skipping keybind with an unknown or malformed action")
        }
    }
}

// one legacy fork rule's effects, or nil when they don't decode.
private struct FailableAppRule: Decodable {
    let rule: AppRule?

    init(from decoder: Decoder) throws {
        rule = try? AppRule(from: decoder)
    }
}

// one window rule, or nil when it doesn't decode. same trick as FailableKeybind.
private struct FailableWindowRule: Decodable {
    let rule: WindowRule?

    init(from decoder: Decoder) throws {
        do {
            rule = try WindowRule(from: decoder)
        } catch {
            rule = nil
            hyprLog(.warning, .config, "skipping malformed window rule")
        }
    }
}

// per-side outer padding override for one monitor. a nil side uses the
// shared outerPadding
struct EdgePadding: Codable, Equatable {
    var top: CGFloat? = nil
    var left: CGFloat? = nil
    var bottom: CGFloat? = nil
    var right: CGFloat? = nil

    var isEmpty: Bool { top == nil && left == nil && bottom == nil && right == nil }
}

// tolerant per side: a hand-edited bad value costs only that side
extension EdgePadding {
    private enum CodingKeys: String, CodingKey {
        case top, left, bottom, right
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func side(_ key: CodingKeys) -> CGFloat? {
            do {
                return try c.decodeIfPresent(CGFloat.self, forKey: key)
            } catch {
                hyprLog(.notice, .config,
                        "monitor-config.json has a \(key.stringValue) padding this build can't read; using outer padding")
                return nil
            }
        }
        self.init(top: side(.top), left: side(.left), bottom: side(.bottom), right: side(.right))
    }
}

// monitor-specific settings — stored locally, never synced via iCloud
struct SavedMonitorConfig: Codable {
    let maxSplitsPerMonitor: [String: Int]?
    let disabledMonitors: [String]?
    // a monitor without an entry pads every edge with outerPadding
    var outerPaddingPerMonitor: [String: EdgePadding]? = nil
    // monitor name → workspaces that live there. nil = the formula homes
    var workspaceMonitors: [String: [Int]]? = nil
    // status bar export, see docs/status-bar.md. per machine since the bar
    // and its hook are set up per Mac. no Settings UI, hand-edited
    var statusExportEnabled: Bool? = nil
    var statusHookCommand: String? = nil
    // hyprmac://action/… links, see docs/external-control.md. per machine
    var externalControlEnabled: Bool? = nil
    // fork fields default to nil so upstream's call sites compile unchanged
    var linkedMonitors: Bool? = nil
    // accordion mode (single-screen stacked layout). accordionMonitor nil
    // resolves to the built-in display at runtime.
    var accordionMode: Bool? = nil
    var accordionMonitor: String? = nil
    var accordionOverlap: CGFloat? = nil
    // the disabled-monitor set to restore when single-screen mode
    // (Action.toggleSingleScreen) is switched off; nil = not active
    var singleScreenRestore: [String]? = nil
    // game screen: the monitor a running game takes over — off limits for
    // tiles until the game quits; nil = off. gameBundleIDs adds games whose
    // Info.plist declares no game category.
    var gameMonitor: String? = nil
    var gameBundleIDs: [String]? = nil
}

// per-field tolerant like SavedConfig: a hand-edited bad value costs only
// its field. strict decoding failed the whole file, and the next save then
// wrote every monitor setting away.
extension SavedMonitorConfig {
    private enum CodingKeys: String, CodingKey {
        case maxSplitsPerMonitor, disabledMonitors, outerPaddingPerMonitor, workspaceMonitors,
             statusExportEnabled, statusHookCommand, externalControlEnabled,
             // fork (HyprMacExperiments)
             linkedMonitors, accordionMode, accordionMonitor, accordionOverlap,
             singleScreenRestore, gameMonitor, gameBundleIDs
    }

    // unreleased top-only shape from PR #51. read once, never written back
    private enum LegacyKeys: String, CodingKey {
        case topPaddingPerMonitor
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func tolerant<T: Decodable, K: CodingKey>(_ c: KeyedDecodingContainer<K>, _ key: K) -> T? {
            do {
                return try c.decodeIfPresent(T.self, forKey: key)
            } catch {
                hyprLog(.notice, .config,
                        "monitor-config.json has a \(key.stringValue) value this build can't read; using the default")
                return nil
            }
        }
        var padding: [String: EdgePadding]? = tolerant(c, .outerPaddingPerMonitor)
        if !c.contains(.outerPaddingPerMonitor) {
            let legacy = try decoder.container(keyedBy: LegacyKeys.self)
            let top: [String: CGFloat]? = tolerant(legacy, .topPaddingPerMonitor)
            padding = top?.mapValues { EdgePadding(top: $0) }
        }
        self.init(maxSplitsPerMonitor: tolerant(c, .maxSplitsPerMonitor),
                  disabledMonitors: tolerant(c, .disabledMonitors),
                  outerPaddingPerMonitor: padding,
                  workspaceMonitors: tolerant(c, .workspaceMonitors),
                  statusExportEnabled: tolerant(c, .statusExportEnabled),
                  statusHookCommand: tolerant(c, .statusHookCommand),
                  externalControlEnabled: tolerant(c, .externalControlEnabled),
                  linkedMonitors: tolerant(c, .linkedMonitors),
                  accordionMode: tolerant(c, .accordionMode),
                  accordionMonitor: tolerant(c, .accordionMonitor),
                  accordionOverlap: tolerant(c, .accordionOverlap),
                  singleScreenRestore: tolerant(c, .singleScreenRestore),
                  gameMonitor: tolerant(c, .gameMonitor),
                  gameBundleIDs: tolerant(c, .gameBundleIDs))
    }
}
