// Hyprland-style window rule: send an app's new windows to a fixed
// workspace, keyed by bundle identifier. Modeled on Hyprland's
// `windowrule = workspace N, class:...` — by default opening a ruled app
// switches to the target workspace; `silent` moves the window without
// switching (Hyprland's `workspace N silent`).

import Foundation

/// One app → workspace pin, matched by exact bundle identifier.
///
/// Rules are evaluated once per window, when it is first discovered.
/// First match wins, so at most one rule should exist per bundle ID
/// (the Settings UI enforces this; a hand-edited config with duplicates
/// just uses the first).
struct WindowRule: Codable, Equatable, Hashable, Identifiable {
    /// Exact bundle identifier of the owning app, e.g. "com.mitchellh.ghostty".
    var bundleID: String
    /// Target workspace, 1...9.
    var workspace: Int
    /// `true` moves the window without switching to the workspace
    /// (Hyprland's `workspace N silent`). Default is to switch.
    var silent: Bool

    var id: String { bundleID }

    init(bundleID: String, workspace: Int, silent: Bool = false) {
        self.bundleID = bundleID
        self.workspace = workspace
        self.silent = silent
    }

    // `silent` decodes as optional so hand-edited configs can omit it.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bundleID = try c.decode(String.self, forKey: .bundleID)
        workspace = try c.decode(Int.self, forKey: .workspace)
        silent = try c.decodeIfPresent(Bool.self, forKey: .silent) ?? false
    }
}

extension Array where Element == WindowRule {
    /// First rule matching `bundleID` with a valid workspace, or nil.
    func firstMatch(bundleID: String?) -> WindowRule? {
        guard let bundleID else { return nil }
        return first { $0.bundleID == bundleID && (1...9).contains($0.workspace) }
    }
}
