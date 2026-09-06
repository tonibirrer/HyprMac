// Hyprland-style window rule: per-app effects keyed by bundle
// identifier, modeled on Hyprland's `windowrule = <effect>, class:...`.
// Two effects exist: a workspace pin (`windowrule = workspace N`; by
// default opening a ruled app switches to the target workspace, `silent`
// moves the window without switching), a tile sort priority that
// keeps an app's tiles at a fixed end of the dwindle order, a sticky
// flag (Hyprland's `pin`) that makes the app's windows follow the user
// across every workspace that opts in, and a full-height flag that
// guarantees the app a full-height column in the dwindle layout.

import Foundation

/// Per-app rule, matched by exact bundle identifier.
///
/// The workspace pin is evaluated once per window, when it is first
/// discovered. The sort priority is enforced on every membership
/// change (see `TilingEngine.applySortPriority`). First match wins, so
/// at most one rule should exist per bundle ID (the Settings UI
/// enforces this; a hand-edited config with duplicates just uses the
/// first).
struct WindowRule: Codable, Equatable, Hashable, Identifiable {
    /// Exact bundle identifier of the owning app, e.g. "com.mitchellh.ghostty".
    var bundleID: String
    /// Target workspace, 1...9. Any value outside that range (the UI
    /// writes 0) means "no pin" — the rule then only carries a sort
    /// priority.
    var workspace: Int
    /// `true` moves the window without switching to the workspace
    /// (Hyprland's `workspace N silent`). Default is to switch.
    var silent: Bool
    /// Tile ordering weight: higher tiles further top-left, lower
    /// further bottom-right. 0 (the default) leaves the window in
    /// plain insertion order.
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

    var id: String { bundleID }

    init(bundleID: String, workspace: Int, silent: Bool = false, sortPriority: Int = 0,
         focusOnActivate: Bool = false, sticky: Bool = false, fullHeight: Bool = false) {
        self.bundleID = bundleID
        self.workspace = workspace
        self.silent = silent
        self.sortPriority = sortPriority
        self.focusOnActivate = focusOnActivate
        self.sticky = sticky
        self.fullHeight = fullHeight
    }

    // everything but the key fields decodes as optional so hand-edited
    // configs (and configs written before a field existed) can omit them.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bundleID = try c.decode(String.self, forKey: .bundleID)
        workspace = try c.decode(Int.self, forKey: .workspace)
        silent = try c.decodeIfPresent(Bool.self, forKey: .silent) ?? false
        sortPriority = try c.decodeIfPresent(Int.self, forKey: .sortPriority) ?? 0
        focusOnActivate = try c.decodeIfPresent(Bool.self, forKey: .focusOnActivate) ?? false
        sticky = try c.decodeIfPresent(Bool.self, forKey: .sticky) ?? false
        fullHeight = try c.decodeIfPresent(Bool.self, forKey: .fullHeight) ?? false
    }
}

extension Array where Element == WindowRule {
    /// First rule matching `bundleID` with a valid workspace pin, or nil.
    /// Priority-only rules (workspace outside 1...9) never match here.
    func firstMatch(bundleID: String?) -> WindowRule? {
        guard let bundleID else { return nil }
        return first { $0.bundleID == bundleID && (1...9).contains($0.workspace) }
    }

    /// Sort priority of the first rule matching `bundleID`, or 0 when no
    /// rule exists. Unlike `firstMatch`, a rule without a workspace pin
    /// still contributes its priority.
    func sortPriority(bundleID: String?) -> Int {
        guard let bundleID else { return 0 }
        return first { $0.bundleID == bundleID }?.sortPriority ?? 0
    }

    /// `true` when the first rule matching `bundleID` opts the app into
    /// focus-on-activate. Like `sortPriority`, a workspace pin is not
    /// required for the flag to apply.
    func focusOnActivate(bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return first { $0.bundleID == bundleID }?.focusOnActivate ?? false
    }

    /// `true` when the first rule matching `bundleID` marks the app
    /// sticky. A workspace pin is not required.
    func isSticky(bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return first { $0.bundleID == bundleID }?.sticky ?? false
    }

    /// `true` when the first rule matching `bundleID` grants the app a
    /// full-height column. A workspace pin is not required.
    func isFullHeight(bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return first { $0.bundleID == bundleID }?.fullHeight ?? false
    }
}
