// One-time data migrations and schema-version bookkeeping. Lives in
// Persistence so changes here do not touch the `@Published` surface
// in `UserConfig`. Today: the monitor-config split (per-machine
// settings extracted from the iCloud-synced file) and the one-time
// import from the stock app's Application Support directory. Future
// schema bumps land here too.

import Foundation

/// One-time migrations and schema-version helpers for `SavedConfig`.
enum ConfigMigration {

    /// Current on-disk schema version. Bump in lockstep with the
    /// migration code that handles the new shape.
    static let currentVersion: Int = 1

    /// Schema version of a loaded `SavedConfig`. `nil` maps to v1 —
    /// the version when the field was introduced; every pre-existing
    /// config decodes as v1.
    static func schemaVersion(of saved: SavedConfig) -> Int {
        saved.version ?? 1
    }

    /// Resolve monitor config, preferring the local file and falling
    /// back to the monitor fields embedded in an older
    /// `SavedConfig`.
    ///
    /// `maxSplitsPerMonitor` and `disabledMonitors` used to live in
    /// the main (iCloud-synced) `config.json`; they now live in a
    /// local-only `monitor-config.json` so per-machine settings do
    /// not round-trip through iCloud and clobber each machine's
    /// setup.
    ///
    /// - Returns: the resolved values plus `needsLocalWrite`, which
    ///   indicates the caller should persist the local file because
    ///   the values were just migrated out of the synced config.
    static func resolveMonitorConfig(
        local: SavedMonitorConfig?,
        embedded saved: SavedConfig?
    ) -> (maxSplits: [String: Int], disabled: Set<String>, needsLocalWrite: Bool) {
        if let local {
            return (local.maxSplitsPerMonitor ?? [:],
                    Set(local.disabledMonitors ?? []),
                    false)
        }
        // no local file — adopt the embedded values from the synced config.
        // if either embedded set is non-empty we need to persist a local copy
        // so the next launch reads from the local file directly.
        let maxSplits = saved?.maxSplitsPerMonitor ?? [:]
        let disabled = Set(saved?.disabledMonitors ?? [])
        let needsWrite = !maxSplits.isEmpty || !disabled.isEmpty
        return (maxSplits, disabled, needsWrite)
    }

    /// Name of the stamp written into the dedicated directory once the
    /// import decision has been made. Its presence, not the presence of
    /// `config.json`, gates the import — otherwise "delete config.json to
    /// reset to defaults" would silently re-import the stock app's file.
    static let importMarkerName = ".imported-from-HyprMac"

    /// One-time import of the stock app's files into this build's own
    /// directory.
    ///
    /// The fork used to share `~/Library/Application Support/HyprMac/`
    /// with the stock app. On the first launch with a dedicated
    /// directory, copy `config.json` and `monitor-config.json` across
    /// (only when the destination does not have them yet), then stamp
    /// the marker so the import never runs again. The source is read
    /// through any iCloud symlink and written as a regular file — iCloud
    /// sync for this build is set up afresh by `UserConfig` from its own
    /// preference. Nothing in `legacy` is modified or removed.
    ///
    /// - Returns: `true` when at least one file was copied.
    @discardableResult
    static func importUpstreamDirectory(from legacy: URL, to current: URL,
                                        fileManager fm: FileManager = .default) -> Bool {
        let marker = current.appendingPathComponent(importMarkerName)
        guard !fm.fileExists(atPath: marker.path) else { return false }
        try? fm.createDirectory(at: current, withIntermediateDirectories: true)

        var copied: [String] = []
        for name in ["config.json", "monitor-config.json"] {
            let src = legacy.appendingPathComponent(name)
            let dst = current.appendingPathComponent(name)
            guard !fm.fileExists(atPath: dst.path),
                  let data = try? Data(contentsOf: src) else { continue }
            if (try? data.write(to: dst)) != nil { copied.append(name) }
        }

        let note = "Imported \(copied.isEmpty ? "nothing" : copied.joined(separator: ", ")) from \(legacy.path) on \(Date())\n"
        try? note.data(using: .utf8)?.write(to: marker)
        hyprLog(.notice, .config, "config import from \(legacy.lastPathComponent): \(copied.isEmpty ? "nothing to copy" : copied.joined(separator: ", ")) → \(current.path)")
        return !copied.isEmpty
    }
}
