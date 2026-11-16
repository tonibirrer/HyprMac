// A window of an app pinned to the scratchpad that comes back while its app
// is in front brings the layer up, the way a new one does. Snagit reuses one
// editor window: it hides it during a capture and shows it again with the
// result, after activating itself. That activation came before the window was
// back, so the activation path found nothing to show; the window then
// returned into the parked layer and focus was pulled off it. A window that
// returns while another app is in front stays parked.

import CoreGraphics

enum ScratchpadReturnSummon {
    struct Candidate: Equatable {
        let windowID: CGWindowID
        let ownerPID: pid_t
        /// its app has a window rule pinning it to the scratchpad
        let pinned: Bool
        /// it is a member of the scratchpad layer
        let member: Bool
    }

    /// The returned window to show the layer for, or nil to park them all.
    static func windowToSummon(_ returned: [Candidate], frontmostPID: pid_t?,
                               layerVisible: Bool, transitionPending: Bool) -> CGWindowID? {
        guard !layerVisible, !transitionPending, let frontmostPID else { return nil }
        return returned.first { $0.pinned && $0.member && $0.ownerPID == frontmostPID }?.windowID
    }
}
