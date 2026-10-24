// Fork-only per-app effects (HyprMacExperiments), keyed by bundle id. The
// workspace pin is upstream's `WindowRule`; these are what the fork layers
// on top: a tile sort priority, a full-height column, honoring the app's
// own activations, sticky windows, and no synthetic clicks.
//
// Saved under `experimentsAppRules`, a key upstream never writes. Before
// the v0.17 sync these fields lived inside the fork's `windowRules`
// entries; `SavedConfig` moves them out on the first load.

import Foundation

/// Per-app effects, matched by exact bundle identifier. First match wins,
/// so at most one rule should exist per bundle ID (the Settings UI enforces
/// this; a hand-edited config with duplicates just uses the first).
struct AppRule: Codable, Equatable, Hashable, Identifiable {
    /// Exact bundle identifier of the owning app, e.g. "com.mitchellh.ghostty".
    var bundleID: String
    /// Tile ordering weight: higher tiles further top-left, lower
    /// further bottom-right. 0 (the default) leaves the window in
    /// plain insertion order. Enforced on every membership change (see
    /// `TilingEngine.applySortPriority`).
    var sortPriority: Int
    /// Hyprland's `focus_on_activate` / `windowrule = activate`, per app:
    /// always honor this app's activation requests — switch to its
    /// workspace even without a user gesture. Needed for browsers, where
    /// another app opening a URL activates them programmatically. Default
    /// off: activations without a user gesture are ignored.
    var focusOnActivate: Bool
    /// Hyprland's `windowrule = pin` ("show it on all workspaces"), per
    /// app. Hyprland pins floating windows only and shows them on every
    /// workspace of their monitor; HyprMac extends this to tiled
    /// windows — a sticky tile is carried into whichever workspace is
    /// shown on its monitor — and lets workspaces opt in individually
    /// via `UserConfig.stickyWorkspaces`. Default off.
    var sticky: Bool
    /// The app's tiles always span the full tiled height: the tile only
    /// ever splits left | right, and every split above it is locked to
    /// left | right (`BSPNode.forcedColumn`). Hyprland's dwindle has no
    /// per-window equivalent; this mirrors the master layout, where a
    /// master window is a full-height column and everything else stacks
    /// beside it. Default off.
    var fullHeight: Bool
    /// Never post a synthesized mouse click into this app to force
    /// activation (the focus-follows-mouse fallback on Tahoe). For apps
    /// that forward mouse input elsewhere — remote desktops, VMs, games —
    /// a fake down/up desynchronizes their button tracking. Well-known
    /// clients are blocked by default (`HyprWindow.syntheticClickBlockedBundleIDs`);
    /// this flag covers the rest. Default off.
    var noSyntheticClick: Bool

    var id: String { bundleID }

    init(bundleID: String, sortPriority: Int = 0, focusOnActivate: Bool = false,
         sticky: Bool = false, fullHeight: Bool = false, noSyntheticClick: Bool = false) {
        self.bundleID = bundleID
        self.sortPriority = sortPriority
        self.focusOnActivate = focusOnActivate
        self.sticky = sticky
        self.fullHeight = fullHeight
        self.noSyntheticClick = noSyntheticClick
    }

    // everything but the bundle id decodes as optional so hand-edited
    // configs (and configs written before a field existed) can omit them.
    // unknown keys — a legacy entry's `workspace` and `silent` — are ignored.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bundleID = try c.decode(String.self, forKey: .bundleID)
        sortPriority = try c.decodeIfPresent(Int.self, forKey: .sortPriority) ?? 0
        focusOnActivate = try c.decodeIfPresent(Bool.self, forKey: .focusOnActivate) ?? false
        sticky = try c.decodeIfPresent(Bool.self, forKey: .sticky) ?? false
        fullHeight = try c.decodeIfPresent(Bool.self, forKey: .fullHeight) ?? false
        noSyntheticClick = try c.decodeIfPresent(Bool.self, forKey: .noSyntheticClick) ?? false
    }

    /// `true` when the rule changes anything; an all-default rule is noise.
    var hasEffect: Bool {
        sortPriority != 0 || focusOnActivate || sticky || fullHeight || noSyntheticClick
    }
}

extension Array where Element == AppRule {
    /// Sort priority of the first rule matching `bundleID`, or 0 when no
    /// rule exists.
    func sortPriority(bundleID: String?) -> Int {
        guard let bundleID else { return 0 }
        return first { $0.bundleID == bundleID }?.sortPriority ?? 0
    }

    /// `true` when the first rule matching `bundleID` opts the app into
    /// focus-on-activate.
    func focusOnActivate(bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return first { $0.bundleID == bundleID }?.focusOnActivate ?? false
    }

    /// `true` when the first rule matching `bundleID` marks the app sticky.
    func isSticky(bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return first { $0.bundleID == bundleID }?.sticky ?? false
    }

    /// `true` when the first rule matching `bundleID` grants the app a
    /// full-height column.
    func isFullHeight(bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return first { $0.bundleID == bundleID }?.fullHeight ?? false
    }

    /// `true` when the first rule matching `bundleID` forbids the
    /// synthetic-click activation fallback.
    func blocksSyntheticClick(bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return first { $0.bundleID == bundleID }?.noSyntheticClick ?? false
    }
}
