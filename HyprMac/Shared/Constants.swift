// Cross-module shared tunables. Subsystem-local values stay in their
// own files (`TilingConfig`, file-private `enum Tuning`, etc.).

import Foundation

/// Cross-module tunables. Every constant added here carries a comment
/// noting its origin (empirical / computed / OS-imposed) and the
/// effect of changing it. Empty so far — values land here when a
/// constant genuinely needs to leak across module boundaries.
enum Constants {}

/// On-disk identity of this build. The fork ships as HyprMacExperiments
/// with its own bundle id so it can run next to a stock HyprMac install;
/// its Application Support directory, iCloud Drive folder and IPC
/// sockets must be just as separate, or the two apps read and rewrite
/// each other's `config.json` (upstream drops the fork's keys on save,
/// the fork could not decode upstream's newer actions). Every path
/// derives from these names — change them here and nowhere else.
enum AppIdentity {
    /// `~/Library/Application Support/<directoryName>/` — config,
    /// monitor config, and the IPC sockets.
    static let directoryName = "HyprMacExperiments"
    /// `~/Library/Mobile Documents/com~apple~CloudDocs/<iCloudDirectoryName>/`
    /// when iCloud sync is on.
    static let iCloudDirectoryName = "HyprMacExperiments"
    /// The stock app's directory. Read exactly once, on the first launch
    /// of a build with a dedicated directory, to carry the user's config
    /// over; never written.
    static let upstreamDirectoryName = "HyprMac"
}
