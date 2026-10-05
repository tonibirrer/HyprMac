import Cocoa

/// A native-fullscreen window, treated as a member of a workspace that
/// takes its whole display while the workspace is up.
struct FullscreenMember: Equatable {
    let windowID: CGWindowID
    let pid: pid_t
    let workspace: Int
    var space: CGSSpaceID
    var displayUUID: String
    var isShowing: Bool
}

/// Which workspace each native-fullscreen window belongs to.
///
/// A fullscreen window is never tiled — it has a Space of its own — but it
/// belongs to a workspace like any other window: the workspace its app's
/// window rule names, or the one it was on (or that was up) when it went
/// fullscreen. Kept in step with the window server by `reconcile`, so a
/// window that leaves fullscreen or closes drops out.
///
/// Threading: main thread only.
final class FullscreenMembers {

    private(set) var byWindow: [CGWindowID: FullscreenMember] = [:]

    /// Bring the members in line with what the window server reports.
    ///
    /// - Parameter observed: every window that owns a fullscreen Space now.
    /// - Parameter assign: the workspace for a window seen for the first time.
    /// - Returns: the members that joined and the ones that left.
    @discardableResult
    func reconcile(_ observed: [FullscreenWindowObservation],
                   assign: (FullscreenWindowObservation) -> Int) -> (added: [FullscreenMember], removed: [FullscreenMember]) {
        let seen = Set(observed.map(\.windowID))
        let removed = byWindow.values.filter { !seen.contains($0.windowID) }.sorted { $0.windowID < $1.windowID }
        for member in removed { byWindow[member.windowID] = nil }

        var added: [FullscreenMember] = []
        for o in observed {
            if var member = byWindow[o.windowID], member.pid == o.pid {
                member.space = o.space
                member.displayUUID = o.displayUUID
                member.isShowing = o.isShowing
                byWindow[o.windowID] = member
            } else {
                let member = FullscreenMember(windowID: o.windowID, pid: o.pid, workspace: assign(o),
                                              space: o.space, displayUUID: o.displayUUID, isShowing: o.isShowing)
                byWindow[o.windowID] = member
                added.append(member)
            }
        }
        return (added.sorted { $0.windowID < $1.windowID }, removed)
    }

    var windowIDs: Set<CGWindowID> { Set(byWindow.keys) }

    func members(onWorkspace workspace: Int) -> [FullscreenMember] {
        byWindow.values.filter { $0.workspace == workspace }.sorted { $0.windowID < $1.windowID }
    }

    /// Displays the workspace's fullscreen members take while it is up.
    func occupiedDisplays(onWorkspace workspace: Int) -> Set<String> {
        Set(members(onWorkspace: workspace).map(\.displayUUID))
    }

    /// Workspaces holding a fullscreen window of `pid`.
    func workspaces(ownedBy pid: pid_t) -> Set<Int> {
        Set(byWindow.values.filter { $0.pid == pid }.map(\.workspace))
    }

    /// The member whose Space `display` shows right now, if any.
    func showingMember(onDisplay displayUUID: String) -> FullscreenMember? {
        byWindow.values.first { $0.displayUUID == displayUUID && $0.isShowing }
    }

    func forget(pid: pid_t) {
        byWindow = byWindow.filter { $0.value.pid != pid }
    }
}
