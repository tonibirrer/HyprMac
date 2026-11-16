// Floaters a display change leaves in a park corner on a workspace that is
// showing again. The park corner is the bottom-right of the rightmost screen,
// so it moves when screens come and go. When a dock attaches one monitor
// before the other, a hidden workspace's floaters are parked at the first
// monitor's corner. That spot can then be mid-screen on the next monitor, and
// it stays there when the workspace shows: the reconcile placed only tiles
// and sticky floaters. macOS nudges such a window up until its title bar
// shows, which leaves a strip the user cannot grab.

import CoreGraphics

enum StrandedFloaterRestore {
    /// Where to put a floater on a visible workspace, or nil to leave it.
    /// A frame substantially visible on some screen stays. A stranded one
    /// goes back to its saved frame, or, without one, to the middle of
    /// `home` at its own size (the write clamps it into the screen).
    static func target(frame: CGRect, saved: CGRect?, screens: [CGRect], home: CGRect?) -> CGRect? {
        guard !screens.contains(where: { frame.isSubstantiallyVisible(on: $0) }) else { return nil }
        if let saved { return saved }
        guard let home else { return nil }
        return CGRect(x: home.midX - frame.width / 2, y: home.midY - frame.height / 2,
                      width: frame.width, height: frame.height)
    }
}
