// Linked monitors (fork): the user's own split of a linked workspace across
// its screens. `tileLinked` cuts the strip by screen area until the user
// moves a tile from one screen to another — a drag onto the other screen or
// Hypr+Ctrl+←/→. From then on each screen keeps the tiles it was given, new
// windows join the screen of the tile before them in the strip, and Retile
// All goes back to the area split.

import Cocoa

/// The user's split of one linked workspace: the screen each tile is on, by
/// index into the left-to-right screen list the split was made for.
struct LinkedSplit: Equatable {
    /// The linked screens, left to right, when the split was made. A split
    /// made for another set of screens does not apply; it waits for them.
    let screenNames: [String]
    var screenOf: [CGWindowID: Int]
}

extension TilingEngine {

    enum LinkedMove: Equatable {
        case moved(from: Int, to: Int)
        /// no linked screen in that direction
        case noScreen
        /// the window is in none of the workspace's linked trees (floating,
        /// or not tiled yet)
        case notTiled
        /// the target screen already holds as many tiles as its dwindle depth allows
        case full(capacity: Int)
    }

    /// The user's split for `workspace` when it was made for `screens`.
    func linkedSplit(onWorkspace workspace: Int, screens: [NSScreen]) -> LinkedSplit? {
        guard let split = linkedSplits[workspace],
              split.screenNames == screens.map(\.localizedName) else { return nil }
        return split
    }

    /// Take the workspace's trees as they stand as the user's split: a drag
    /// across the border just put a tile where the user wants it.
    func pinLinkedSplit(onWorkspace workspace: Int, screens: [NSScreen]) {
        guard screens.count > 1 else { return }
        var screenOf: [CGWindowID: Int] = [:]
        for (index, screen) in screens.enumerated() {
            for id in windowIDs(inTreeForWorkspace: workspace, screen: screen) { screenOf[id] = index }
        }
        linkedSplits[workspace] = LinkedSplit(screenNames: screens.map(\.localizedName), screenOf: screenOf)
        hyprLog(.notice, .tiling, "linked split ws\(workspace): \(Self.describe(screenOf, screenCount: screens.count))")
    }

    /// Give `windowID` to the linked screen at `target`. It joins that
    /// screen's tiles on the side facing the screen it came from; every other
    /// tile keeps its screen. The caller retiles, and `tileLinked` lays the
    /// split out.
    func moveAcrossLinkedScreens(_ windowID: CGWindowID, onWorkspace workspace: Int,
                                 to target: Int, screens: [NSScreen]) -> LinkedMove {
        let trees = screens.map { windowIDs(inTreeForWorkspace: workspace, screen: $0) }
        guard let source = trees.firstIndex(where: { $0.contains(windowID) }) else { return .notTiled }
        guard screens.indices.contains(target), target != source else { return .noScreen }

        var screenOf = linkedSplit(onWorkspace: workspace, screens: screens)?.screenOf ?? [:]
        for (index, ids) in trees.enumerated() {
            for id in ids where screenOf[id] == nil { screenOf[id] = index }
        }
        screenOf[windowID] = target
        let strip = trees.flatMap { $0 }
        let assignment = Self.linkedAssignment(strip: strip, screenOf: screenOf, screenCount: screens.count)
        let capacity = 1 << maxDepth(for: screens[target])
        guard assignment.filter({ $0 == target }).count <= capacity else { return .full(capacity: capacity) }

        linkedSplits[workspace] = LinkedSplit(screenNames: screens.map(\.localizedName), screenOf: screenOf)
        hyprLog(.notice, .tiling, "linked split ws\(workspace): \(windowID) screen \(source) → \(target); "
                + Self.describe(screenOf, screenCount: screens.count))
        return .moved(from: source, to: target)
    }

    /// Forget the user's split of `workspace`, or of every workspace.
    func clearLinkedSplits(onWorkspace workspace: Int? = nil) {
        if let workspace {
            linkedSplits[workspace] = nil
        } else {
            linkedSplits.removeAll()
        }
    }

    /// The screen index of each strip window: the split's for a window it
    /// knows, else that of the window before it (the first screen for the
    /// front of the strip). A new window at the end of the strip joins the
    /// last screen that has tiles.
    static func linkedAssignment(strip: [CGWindowID], screenOf: [CGWindowID: Int],
                                 screenCount: Int) -> [Int] {
        var previous = 0
        return strip.map { id in
            let index = screenOf[id].map { min(max($0, 0), screenCount - 1) } ?? previous
            previous = index
            return index
        }
    }

    /// `strip` regrouped so each screen's windows are contiguous, in their
    /// strip order, then ordered by `priorities` (higher first) within the
    /// screen. Returns the per-screen counts and the split it lays out.
    static func linkedCut(strip: [CGWindowID], assignment: [Int], priorities: [Int]?,
                          screenCount: Int) -> (strip: [CGWindowID], sizes: [Int], screenOf: [CGWindowID: Int]) {
        let ordered = strip.indices.sorted { a, b in
            if assignment[a] != assignment[b] { return assignment[a] < assignment[b] }
            if let priorities, priorities[a] != priorities[b] { return priorities[a] > priorities[b] }
            return a < b
        }
        var sizes = Array(repeating: 0, count: screenCount)
        var screenOf: [CGWindowID: Int] = [:]
        for index in ordered {
            sizes[assignment[index]] += 1
            screenOf[strip[index]] = assignment[index]
        }
        return (ordered.map { strip[$0] }, sizes, screenOf)
    }

    private static func describe(_ screenOf: [CGWindowID: Int], screenCount: Int) -> String {
        (0..<screenCount).map { index in
            "[" + screenOf.filter { $0.value == index }.keys.sorted().map(String.init).joined(separator: ",") + "]"
        }.joined(separator: " | ")
    }
}
