// Hyprland-style window rule: per-app effects keyed by bundle
// identifier, modeled on Hyprland's `windowrule = <effect>, class:...`.
// Two effects exist: a workspace pin (`windowrule = workspace N`; by
// default opening a ruled app switches to the target workspace, `silent`
// moves the window without switching) and a tile sort priority that
// keeps an app's tiles at a fixed end of the dwindle order.

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

    var id: String { bundleID }

    init(bundleID: String, workspace: Int, silent: Bool = false, sortPriority: Int = 0) {
        self.bundleID = bundleID
        self.workspace = workspace
        self.silent = silent
        self.sortPriority = sortPriority
    }

    // `silent` and `sortPriority` decode as optional so hand-edited
    // configs (and configs written before the field existed) can omit them.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bundleID = try c.decode(String.self, forKey: .bundleID)
        workspace = try c.decode(Int.self, forKey: .workspace)
        silent = try c.decodeIfPresent(Bool.self, forKey: .silent) ?? false
        sortPriority = try c.decodeIfPresent(Int.self, forKey: .sortPriority) ?? 0
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
}
