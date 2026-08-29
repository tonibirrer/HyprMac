// One BSP tree per `(workspace, screen)` pair plus the orchestration
// surface that drives smart insert, swap, split toggling, two-pass
// readback, and min-size memory.

import Cocoa

/// Stable key for a `(workspace, screen)` tree.
private struct TilingKey: Hashable {
    let workspace: Int
    let screenID: Int

    init(workspace: Int, screen: NSScreen) {
        self.workspace = workspace
        self.screenID = Int(screen.frame.origin.x * 10000 + screen.frame.origin.y)
    }
}

/// Owner of every BSP tree HyprMac maintains.
///
/// One tree per `(workspace, screen)` pair. Keeps gap/padding tunables,
/// per-screen depth overrides, the `MinSizeMemory` for two-pass layout
/// resolution, and the `onAutoFloat` callback that fires when a window
/// cannot fit. Public surface owns smart insert, swap, split toggling,
/// readback-driven settle/conflict resolution, and tree migration on
/// monitor reconnect.
///
/// Threading: main-thread only.
class TilingEngine {
    /// Pseudo-workspace the scratchpad layer's tree lives on. Matches
    /// `ScratchpadController.workspace`; kept local so the engine has no
    /// dependency on the controller.
    static let scratchpadWorkspace = 0

    private var trees: [TilingKey: BSPTree] = [:]
    private var pendingInsertedWindowIDs: [TilingKey: [CGWindowID]] = [:]
    let displayManager: DisplayManager

    /// Gap between adjacent tiles, in pixels. Default from
    /// `TilingConfig.defaultGap`; runtime-tunable from the settings UI.
    var gapSize: CGFloat = TilingConfig.defaultGap

    /// Padding between tiles and the screen edge, in pixels.
    /// Runtime-tunable.
    var outerPadding = OuterPadding(uniform: TilingConfig.defaultOuterPadding)

    /// Per-screen max BSP depth overrides, keyed by
    /// `NSScreen.localizedName`. Falls back to
    /// `TilingConfig.defaultMaxDepth` for screens without an override.
    var maxSplitsPerMonitor: [String: Int] = [:]

    /// Effective max depth for `screen`, honoring any per-screen
    /// override.
    func maxDepth(for screen: NSScreen) -> Int {
        maxSplitsPerMonitor[screen.localizedName] ?? TilingConfig.defaultMaxDepth
    }

    /// Minimum child dimension (px) below which smart insert
    /// backtracks to a shallower leaf.
    var minSlotDimension: CGFloat = TilingConfig.minSlotDimension

    /// Fired when a window cannot enter the tree (max depth reached
    /// even after smart-insert backtracking). The caller is expected to
    /// auto-float the window.
    var onAutoFloat: ((HyprWindow) -> Void)?

    // MARK: - accordion mode

    /// `true` when `screen` should render as an accordion instead of a
    /// tiled layout. Set by the owner (`WindowManager` checks the config
    /// toggle, the single-screen condition, and the selected monitor);
    /// defaults to never so tests and the scratchpad see plain tiling.
    ///
    /// Accordion is presentation-only: tree membership, insertion, swap
    /// and removal run identically to tile mode, so switching back to
    /// tiling restores the exact BSP layout.
    var accordionActive: (NSScreen) -> Bool = { _ in false }

    /// Visible peek, in px, of the neighbor stacks on each side of the
    /// focused window. Runtime-tunable from the settings UI.
    var accordionOverlap: CGFloat = UserConfigDefaults.accordionOverlap

    /// Resolves the window that currently has focus intent — accordion
    /// frames depend on which window is in front. `nil`/unknown falls
    /// back to the first window in tree order.
    var accordionFocusedWindowID: () -> CGWindowID? = { nil }

    /// Public probe for the dispatcher's order-based navigation.
    func isAccordionActive(on screen: NSScreen) -> Bool { accordionActive(screen) }

    /// The accordion (= tree in-order) window sequence for
    /// `(workspace, screen)`. Empty when no tree exists.
    func accordionOrder(onWorkspace workspace: Int, screen: NSScreen) -> [HyprWindow] {
        trees[TilingKey(workspace: workspace, screen: screen)]?.allWindows ?? []
    }

    /// Apply accordion frames + z-order for `tree` inside `rect`.
    ///
    /// Replaces the two-pass min-size layout: every window gets a
    /// near-fullscreen rect, so min-size conflicts cannot occur and no
    /// readback is needed. Raising outermost-first keeps the nearest
    /// neighbor on top of each peek stack, focused window frontmost.
    private func applyAccordionLayout(_ tree: BSPTree, rect: CGRect) {
        let order = tree.allWindows
        guard !order.isEmpty else { return }
        let focusedID = accordionFocusedWindowID()
        let frames = AccordionLayout.frames(order: order, focusedID: focusedID,
                                            in: rect, padding: outerPadding,
                                            overlap: accordionOverlap)
        applyLayoutFinal(frames)
        for w in AccordionLayout.raiseOrder(order, focusedID: focusedID) {
            w.raise()
        }
        hyprLog(.debug, .tiling, "accordion: \(order.count) windows, front=\(focusedID.map(String.init) ?? "first")")
    }

    /// Resolves a window's app sort priority (Hyprland-style window
    /// rule): higher tiles further top-left, lower further bottom-right,
    /// 0 is neutral. Set by the owner; nil disables priority ordering.
    var sortPriority: ((HyprWindow) -> Int)?

    private let minSizes = MinSizeMemory()

    init(displayManager: DisplayManager) {
        self.displayManager = displayManager
    }

    /// Seed `MinSizeMemory` from current AX values for every window.
    /// Called before any layout pass so size constraints are fresh.
    func primeMinimumSizes(_ windows: [HyprWindow]) { minSizes.prime(windows) }

    /// Drop any stored min-size memory for `windowID`. Called when a
    /// window is forgotten by the discovery layer.
    func forgetMinimumSize(windowID: CGWindowID) { minSizes.forget(windowID: windowID) }

    /// Defensive cleanup — drop `windowID` from whichever BSP tree
    /// currently holds it and prune empties. Called from the discovery
    /// gone path so a closed window's node cannot outlive its AX presence
    /// even when the owning workspace is hidden (and therefore skipped by
    /// `tileAllVisibleSpaces`). Sibling promotion keeps the surviving
    /// arrangement intact — no compact, so a transient disappearance
    /// (Cmd-H, minimize, missed AX poll) doesn't reshuffle the tree.
    /// No-op when no tree contains `windowID`.
    func removeWindowID(_ windowID: CGWindowID) {
        for (_, t) in trees {
            guard let w = t.allWindows.first(where: { $0.windowID == windowID }) else { continue }
            t.remove(w)
            t.root.pruneEmptyNodes()
            return
        }
    }

    private func minimumSize(for window: HyprWindow?) -> CGSize { minSizes.minimumSize(for: window) }

    private func tree(for key: TilingKey) -> BSPTree {
        if let existing = trees[key] { return existing }
        let tree = BSPTree()
        trees[key] = tree
        return tree
    }

    /// Non-creating tree accessor for tests. Returns the live tree
    /// for `(workspace, screen)`, or `nil` when none exists.
    /// Production callers go through `tree(for:)` so the tree is
    /// created on demand.
    internal func existingTree(forWorkspace workspace: Int, screen: NSScreen) -> BSPTree? {
        trees[TilingKey(workspace: workspace, screen: screen)]
    }

    /// Reconcile `trees` with the current monitor topology.
    ///
    /// When a screen is disconnected (e.g., laptop lid close, dock unplug), every
    /// `(workspace, screen)` tree keyed to the vanished screen must either move
    /// to the workspace's new home screen or be pruned. Without this, vanished
    /// trees linger forever, leaking memory and producing stale layouts when the
    /// monitor reconnects with the same physical position.
    ///
    /// - Parameters:
    ///   - currentScreens: the live screens (after `DisplayManager.refresh()`).
    ///   - homeScreensForWorkspace: closure that returns every screen a
    ///     workspace may legitimately keep a tree on — one static home
    ///     normally, all enabled screens in linked-monitors mode — or empty
    ///     if the workspace has no live home. The first element is the
    ///     migration destination for stale trees. Caller is responsible for
    ///     running `WorkspaceManager.initializeMonitors()` **before** calling
    ///     this — otherwise the home-screen map is stale and migrations
    ///     target vanished destinations.
    ///
    /// - Note: TilingKey currently keys on screen-origin coordinates. If two
    ///   monitors swap positions during a reconnect, trees follow the position,
    ///   not the physical display. Migrating to `displayID` keying is a future
    ///   change (see plan §4.2 — deferred for risk reasons).
    func handleDisplayChange(currentScreens: [NSScreen],
                             homeScreensForWorkspace: (Int) -> [NSScreen]) {
        var migrations: [(old: TilingKey, dest: NSScreen)] = []
        var orphans: [TilingKey] = []

        // static anchoring guarantees exactly one home screen per workspace
        // (linked mode: every enabled screen is a valid home), so a tree is
        // stale unless it sits on one of its workspace's *current* homes. this
        // catches two cases: (1) the home screen vanished (lid close / unplug),
        // and (2) the home moved to a different live screen after a reconnect —
        // e.g. ws1's home is the laptop when it's alone, but the leftmost
        // external once monitors return. case (2) leaves a tree behind on a
        // screen that still exists, so a plain "is the screen still here?" check
        // misses it and the window ends up duplicated across two trees, feeding
        // intendedTileRects a wrong-monitor rect and scrambling directional focus.
        for key in trees.keys {
            // scratchpad (ws 0) tree has no static home (homeScreensForWorkspace(0)
            // is empty) so it would land in orphans and get destroyed on every
            // display change / wake. leave it alone — the next show() reconciles
            // it (tileScratchpad clears any stale (0, deadScreen) tree).
            if key.workspace == Self.scratchpadWorkspace { continue }
            let homes = homeScreensForWorkspace(key.workspace)
            let homeIDs = homes.map { TilingKey(workspace: key.workspace, screen: $0).screenID }
            if homeIDs.contains(key.screenID) { continue }
            if let dest = homes.first {
                migrations.append((key, dest))
            } else {
                orphans.append(key)
            }
        }

        for (oldKey, newScreen) in migrations {
            guard let tree = trees.removeValue(forKey: oldKey) else { continue }
            let newKey = TilingKey(workspace: oldKey.workspace, screen: newScreen)
            // a tree may already exist on the destination if the workspace had
            // been visited there before. keep the larger one and merge the
            // other's windows into it — dropping a tree wholesale orphaned its
            // windows into arbitrary-order reinsertion (wake scramble).
            if let existing = trees[newKey] {
                let (keep, donor) = existing.allWindows.count >= tree.allWindows.count
                    ? (existing, tree) : (tree, existing)
                let keepIDs = Set(keep.allWindows.map { $0.windowID })
                let rect = displayManager.cgRect(for: newScreen)
                var merged = 0
                for w in donor.allWindows where !keepIDs.contains(w.windowID) {
                    if keep.smartInsert(w, maxDepth: maxDepth(for: newScreen), in: rect,
                                        gap: gapSize, padding: outerPadding,
                                        minSlotDimension: minSlotDimension) {
                        merged += 1
                    } else {
                        // depth ceiling — the window keeps its workspace
                        // assignment, so the next tile pass re-inserts or
                        // auto-floats it instead of it silently vanishing.
                        hyprLog(.notice, .lifecycle, "display change: no room to merge '\(w.title ?? "?")' (\(w.windowID)) into ws\(oldKey.workspace) tree — deferring to next tile pass")
                    }
                }
                trees[newKey] = keep
                hyprLog(.notice, .lifecycle, "display change: ws\(oldKey.workspace) tree collision at sid=\(newKey.screenID) — kept \(keep.allWindows.count - merged)-window tree, merged \(merged) from the other")
                continue
            }
            trees[newKey] = tree
            hyprLog(.notice, .lifecycle, "display change: migrated ws\(oldKey.workspace) tree from sid=\(oldKey.screenID) to home (\(tree.allWindows.count) windows)")
        }

        for key in orphans {
            let count = trees[key]?.allWindows.count ?? 0
            trees.removeValue(forKey: key)
            hyprLog(.debug, .lifecycle, "display change: pruned orphaned tree for ws \(key.workspace) (\(count) windows)")
        }
    }

    private var layoutEngine: LayoutEngine {
        LayoutEngine(gapSize: gapSize, outerPadding: outerPadding,
                     minSlotDimension: minSlotDimension)
    }

    private let readbackPoller = FrameReadbackPoller()

    // delegate to FrameReadbackPoller and reconcile its result against our
    // min-size memory. returns the conflicts the engine should pass into
    // BSPTree.adjustForMinSizes.
    private func applyLayout(_ layouts: [(HyprWindow, CGRect)]) -> [FrameReadbackPoller.Conflict] {
        let result = readbackPoller.applyLayout(layouts)
        for obs in result.observations {
            minSizes.recordObserved(obs.window, actual: obs.actual,
                                    widthConflict: obs.widthConflict,
                                    heightConflict: obs.heightConflict)
        }
        for (window, size) in result.accepted {
            minSizes.lowerIfAccepted(window, actual: size)
        }
        return result.conflicts
    }

    private func applyLayoutFinal(_ layouts: [(HyprWindow, CGRect)]) {
        readbackPoller.applyFinal(layouts)
    }

    private func overflowingWindows(in layouts: [(HyprWindow, CGRect)]) -> [HyprWindow] {
        layouts.compactMap { window, frame in
            let minSize = minimumSize(for: window)
            if minSize.width > frame.width + TilingConfig.frameToleranceXPx || minSize.height > frame.height + TilingConfig.frameToleranceXPx {
                return window
            }
            return nil
        }
    }

    private func layoutCanAccommodateKnownMinimums(_ tree: BSPTree, rect: CGRect) -> Bool {
        let initial = tree.layout(in: rect, gap: gapSize, padding: outerPadding)
        let conflicts = initial.compactMap { window, frame -> (window: HyprWindow, actual: CGSize)? in
            let minSize = minimumSize(for: window)
            if minSize.width > frame.width + TilingConfig.frameToleranceXPx || minSize.height > frame.height + TilingConfig.frameToleranceXPx {
                return (window: window, actual: minSize)
            }
            return nil
        }

        guard !conflicts.isEmpty else { return true }

        tree.adjustForMinSizes(conflicts, in: rect, gap: gapSize, padding: outerPadding)
        let adjusted = tree.layout(in: rect, gap: gapSize, padding: outerPadding)
        return overflowingWindows(in: adjusted).isEmpty
    }

    private func screen(for key: TilingKey) -> NSScreen? {
        displayManager.screens.first { TilingKey(workspace: key.workspace, screen: $0) == key }
    }

    private func treeContaining(_ window: HyprWindow) -> (key: TilingKey, tree: BSPTree)? {
        for (key, tree) in trees where tree.contains(window) {
            return (key, tree)
        }
        return nil
    }

    private func autoFloatOverflow(_ overflow: [HyprWindow],
                                   inserted: [HyprWindow],
                                   tree: BSPTree,
                                   key: TilingKey,
                                   screen: NSScreen) -> Bool {
        // Tahoe: AX readback lags AX setattr, so "overflow" frequently
        // reports false positives. yabai's window_manager.c:732 documents
        // the same race ("frame cache is not reliable... causing layout to
        // not be modified the way we expect"). auto-floating from a stale
        // readback is exactly what's been making windows mysteriously float
        // and land at wrong sizes. accept the apparent overflow and let the
        // next AX-event-driven retile fix it if it's real.
        guard !overflow.isEmpty, !inserted.isEmpty else { return false }
        let overflowIDs = Set(overflow.map { $0.windowID })
        let target = inserted.reversed().first { overflowIDs.contains($0.windowID) }
            ?? inserted.last
        guard let target else { return false }

        hyprLog(.notice, .tiling, "overflow detected (NOT auto-floating, may be stale readback): '\(target.title ?? "?")' (\(target.windowID))")
        // intentionally no longer remove from tree or call onAutoFloat —
        // returning false lets the caller fall through to applyLayoutFinal.
        _ = tree; _ = key; _ = screen
        return false
    }

    private func rememberPendingInserted(_ windows: [HyprWindow], for key: TilingKey) {
        guard !windows.isEmpty else { return }
        pendingInsertedWindowIDs[key, default: []].append(contentsOf: windows.map(\.windowID))
    }

    private func consumePendingInserted(for key: TilingKey, in tree: BSPTree) -> [HyprWindow] {
        guard let ids = pendingInsertedWindowIDs.removeValue(forKey: key), !ids.isEmpty else { return [] }
        let windowsByID = Dictionary(uniqueKeysWithValues: tree.allWindows.map { ($0.windowID, $0) })
        return ids.compactMap { windowsByID[$0] }
    }

    private func mergedInserted(_ inserted: [HyprWindow], pending: [HyprWindow]) -> [HyprWindow] {
        var seen: Set<CGWindowID> = []
        var result: [HyprWindow] = []
        for window in inserted + pending where !seen.contains(window.windowID) {
            seen.insert(window.windowID)
            result.append(window)
        }
        return result
    }


    @discardableResult
    private func smartInsertFitting(_ window: HyprWindow, into tree: BSPTree,
                                    maxDepth: Int, rect: CGRect) -> Bool {
        layoutEngine.smartInsertFitting(window, into: tree, maxDepth: maxDepth,
                                        rect: rect, minimumSize: minimumSize(for:))
    }

    private func fittingLeaf(for window: HyprWindow?, in tree: BSPTree,
                             maxDepth: Int, rect: CGRect) -> BSPNode? {
        layoutEngine.fittingLeaf(for: window, in: tree, maxDepth: maxDepth,
                                 rect: rect, minimumSize: minimumSize(for:))
    }

    private struct TileMembershipResult {
        let key: TilingKey
        let tree: BSPTree
        let rect: CGRect
        let insertedWindows: [HyprWindow]
    }

    // shared tree-update path between tileWindows and prepareTileLayout.
    // primes min-sizes, removes gone windows (sibling promotion keeps the
    // tree shape), smart-inserts new windows in a stable order
    // (auto-floating those that don't fit), and resets split ratios.
    // pure with respect to AX — only mutates the tree and engine state.
    // `order` (linked-monitors partitions) pins the final in-order window
    // sequence exactly; nil leaves insertion order + sort priority in charge.
    private func updateTreeMembership(_ windows: [HyprWindow],
                                      onWorkspace workspace: Int,
                                      screen: NSScreen,
                                      order: [CGWindowID]? = nil) -> TileMembershipResult {
        primeMinimumSizes(windows)
        let key = TilingKey(workspace: workspace, screen: screen)
        let t = tree(for: key)
        let rect = displayManager.cgRect(for: screen)

        let tileWindows = windows.filter { !$0.isFloating }
        let treeWindows = t.allWindows
        let currentIDs = Set(tileWindows.map { $0.windowID })
        let treeIDs = Set(treeWindows.map { $0.windowID })

        for w in treeWindows where !currentIDs.contains(w.windowID) { t.remove(w) }

        t.root.pruneEmptyNodes()
        // no compact on removal — BSPNode.remove promotes the sibling with
        // ratios/overrides intact. compacting here rebuilt the whole tree,
        // reshuffling unrelated windows every time anything closed or hid.

        // reset before insert decisions: fittingLeaf judges candidate rects
        // with live ratios, and a stale pass-2 adjustment (0.85/0.15) from a
        // previous cycle would skew which leaf accepts the window.
        t.root.resetSplitRatios()

        // deterministic batch order: app sort priority first (higher =
        // earlier = further top-left), then left-to-right by current
        // frame, id tiebreak. AX enumeration order shifts with focus/z
        // churn, which made multi-window inserts land differently every
        // time.
        var toInsert = tileWindows.filter { !treeIDs.contains($0.windowID) }
        if toInsert.count > 1 {
            let frames = Dictionary(uniqueKeysWithValues: toInsert.map { ($0.windowID, $0.frame ?? .zero) })
            let priorities = Dictionary(uniqueKeysWithValues: toInsert.map { ($0.windowID, sortPriority?($0) ?? 0) })
            toInsert.sort { a, b in
                let pa = priorities[a.windowID] ?? 0
                let pb = priorities[b.windowID] ?? 0
                if pa != pb { return pa > pb }
                let fa = frames[a.windowID] ?? .zero
                let fb = frames[b.windowID] ?? .zero
                if fa.origin.x != fb.origin.x { return fa.origin.x < fb.origin.x }
                if fa.origin.y != fb.origin.y { return fa.origin.y < fb.origin.y }
                return a.windowID < b.windowID
            }
        }

        var insertedWindows: [HyprWindow] = []
        for w in toInsert {
            if !smartInsertFitting(w, into: t, maxDepth: maxDepth(for: screen), rect: rect) {
                hyprLog(.debug, .lifecycle, "no fitting tile slot — auto-floating '\(w.title ?? "?")'")
                onAutoFloat?(w)
            } else {
                insertedWindows.append(w)
            }
        }

        if !insertedWindows.isEmpty {
            t.root.clearUserSetRatios()
            t.root.resetSplitRatios()
        }
        applySortPriority(to: t)
        if let order { applyOrder(order, to: t) }
        return TileMembershipResult(key: key, tree: t, rect: rect, insertedWindows: insertedWindows)
    }

    /// Pin the tree's in-order window sequence to `order` (window IDs).
    /// IDs not in the tree are ignored; tree windows missing from `order`
    /// sink to the end in their current relative order. Topology-preserving,
    /// like `applySortPriority`.
    private func applyOrder(_ order: [CGWindowID], to tree: BSPTree) {
        let current = tree.allWindows
        guard current.count > 1 else { return }
        let rank = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($0.element, $0.offset) })
        let desired = current.enumerated()
            .sorted { a, b in
                let ra = rank[a.element.windowID] ?? Int.max
                let rb = rank[b.element.windowID] ?? Int.max
                if ra != rb { return ra < rb }
                return a.offset < b.offset
            }
            .map { $0.element }
        guard desired.map({ $0.windowID }) != current.map({ $0.windowID }) else { return }
        tree.assignWindows(inOrder: desired)
    }

    /// Enforce app sort priorities on `tree`: stable-reorder the window
    /// references so higher-priority apps sit further top-left (earlier
    /// in the in-order traversal), lower-priority further bottom-right.
    /// Equal priorities keep their current relative order, so windows
    /// without a rule (priority 0) — and manual swaps between them —
    /// are never touched. Like `swap`, only the leaf → window mapping
    /// changes; topology, ratios and overrides stay intact.
    private func applySortPriority(to tree: BSPTree) {
        guard let sortPriority else { return }
        let current = tree.allWindows
        guard current.count > 1 else { return }
        let priorities = current.map(sortPriority)
        guard priorities.contains(where: { $0 != 0 }) else { return }
        // Swift's sort is not guaranteed stable — tiebreak on the
        // original index to keep equal-priority order.
        let desired = zip(current, priorities).enumerated()
            .sorted { a, b in
                if a.element.1 != b.element.1 { return a.element.1 > b.element.1 }
                return a.offset < b.offset
            }
            .map { $0.element.0 }
        guard desired.map({ $0.windowID }) != current.map({ $0.windowID }) else { return }
        hyprLog(.debug, .tiling, "sort priority reorder: \(current.map { $0.title ?? "?" }) → \(desired.map { $0.title ?? "?" })")
        tree.assignWindows(inOrder: desired)
    }

    /// Tile `windows` for `(workspace, screen)`.
    ///
    /// `screen` is supplied explicitly because window positions can be
    /// the hide-corner sliver — physical position is not trustworthy
    /// during a workspace switch. Two-pass: pass 1 lays out and reads
    /// back actual frames; pass 2 (when conflicts are detected)
    /// adjusts split ratios via `MinSizeMemory` and re-applies. If
    /// pass-2 still overflows and inserted windows are present, the
    /// engine auto-floats the overflowing windows; otherwise it
    /// preserves the recorded mins and falls back to pass-1 frames.
    func tileWindows(_ windows: [HyprWindow], onWorkspace workspace: Int, screen: NSScreen,
                     order: [CGWindowID]? = nil) {
        let m = updateTreeMembership(windows, onWorkspace: workspace, screen: screen, order: order)
        let key = m.key
        let t = m.tree
        let rect = m.rect

        // accordion mode: membership above ran identically (so the BSP
        // tree stays tile-mode-correct in the background); only the frame
        // application differs. no readback/min-size passes — every window
        // gets a near-fullscreen rect.
        if accordionActive(screen) {
            _ = consumePendingInserted(for: key, in: t)
            applyAccordionLayout(t, rect: rect)
            for (otherKey, other) in trees where otherKey.workspace == workspace {
                if other.allWindows.isEmpty && otherKey != key {
                    trees.removeValue(forKey: otherKey)
                }
            }
            return
        }

        // pass 1: layout + readback
        let layouts = t.layout(in: rect, gap: gapSize, padding: outerPadding)
        hyprLog(.debug, .lifecycle, "tiling \(layouts.count) windows on workspace \(workspace) screen \(Int(screen.frame.width))x\(Int(screen.frame.height))")
        let conflicts = applyLayout(layouts)
        let insertedForOverflow = mergedInserted(m.insertedWindows, pending: consumePendingInserted(for: key, in: t))

        if !conflicts.isEmpty {
            // pass 2: adjust ratios and re-layout
            let mapped = conflicts.map { (window: $0.window, actual: $0.actual) }
            t.adjustForMinSizes(mapped, in: rect, gap: gapSize, padding: outerPadding)
            let adjusted = t.layout(in: rect, gap: gapSize, padding: outerPadding)
            let overflow = overflowingWindows(in: adjusted)
            if autoFloatOverflow(overflow, inserted: insertedForOverflow,
                                 tree: t, key: key, screen: screen) {
                return
            }
            if !overflow.isEmpty {
                hyprLog(.debug, .lifecycle, "overflow persisted with no inserted target — discarding min-size adjustment")
                minSizes.clear(for: overflow)
                t.root.resetSplitRatios()
                applyLayoutFinal(layouts)
                return
            }
            for (window, frame) in adjusted {
                hyprLog(.debug, .lifecycle, "  '\(window.title ?? "?")' → \(frame)")
            }
            applyLayoutFinal(adjusted)
        } else {
            for (window, frame) in layouts {
                hyprLog(.debug, .lifecycle, "  '\(window.title ?? "?")' → \(frame)")
            }
        }

        // clean up empty trees for this workspace on other screens
        for (key, t) in trees where key.workspace == workspace {
            if !t.allWindows.isEmpty { continue }
            if TilingKey(workspace: workspace, screen: screen) != key {
                trees.removeValue(forKey: key)
            }
        }
    }

    /// Tile one workspace across several linked screens.
    ///
    /// The workspace's tiled windows form a single left-to-right strip:
    /// each screen's tree read in `screens` order, new windows appended
    /// (same deterministic comparator as batch insert), app sort
    /// priorities applied globally. The strip is cut into contiguous
    /// per-screen chunks sized proportionally to usable screen area —
    /// a tile lives wholly on one screen, never across the border — and
    /// each chunk tiles into its own `(workspace, screen)` tree with the
    /// strip order pinned.
    ///
    /// `screens` must be the enabled screens left-to-right. A single
    /// screen degenerates to plain `tileWindows`.
    func tileLinked(_ windows: [HyprWindow], onWorkspace workspace: Int, screens: [NSScreen]) {
        guard screens.count > 1 else {
            if let only = screens.first { tileWindows(windows, onWorkspace: workspace, screen: only) }
            return
        }
        primeMinimumSizes(windows)

        let tiled = windows.filter { !$0.isFloating }
        let tiledIDs = Set(tiled.map { $0.windowID })

        // existing strip: current trees in screen order, live members only
        var strip: [HyprWindow] = []
        var stripIDs = Set<CGWindowID>()
        for screen in screens {
            let key = TilingKey(workspace: workspace, screen: screen)
            for w in trees[key]?.allWindows ?? [] where tiledIDs.contains(w.windowID) {
                if stripIDs.insert(w.windowID).inserted { strip.append(w) }
            }
        }

        // new windows append at the right end, deterministically ordered
        // (priority desc, frame position, id — the batch-insert comparator)
        var incoming = tiled.filter { !stripIDs.contains($0.windowID) }
        if incoming.count > 1 {
            let frames = Dictionary(uniqueKeysWithValues: incoming.map { ($0.windowID, $0.frame ?? .zero) })
            let priorities = Dictionary(uniqueKeysWithValues: incoming.map { ($0.windowID, sortPriority?($0) ?? 0) })
            incoming.sort { a, b in
                let pa = priorities[a.windowID] ?? 0
                let pb = priorities[b.windowID] ?? 0
                if pa != pb { return pa > pb }
                let fa = frames[a.windowID] ?? .zero
                let fb = frames[b.windowID] ?? .zero
                if fa.origin.x != fb.origin.x { return fa.origin.x < fb.origin.x }
                if fa.origin.y != fb.origin.y { return fa.origin.y < fb.origin.y }
                return a.windowID < b.windowID
            }
        }
        strip.append(contentsOf: incoming)

        // sort priorities apply to the whole strip, so "higher = further
        // top-left" spans the border: the leftmost screen is the top-left end
        if let sortPriority, strip.count > 1 {
            let priorities = strip.map(sortPriority)
            if priorities.contains(where: { $0 != 0 }) {
                strip = zip(strip, priorities).enumerated()
                    .sorted { a, b in
                        if a.element.1 != b.element.1 { return a.element.1 > b.element.1 }
                        return a.offset < b.offset
                    }
                    .map { $0.element.0 }
            }
        }

        let weights = screens.map { max(1, displayManager.cgRect(for: $0).width * displayManager.cgRect(for: $0).height) }
        let capacities = screens.map { 1 << maxDepth(for: $0) }
        let sizes = Self.linkedChunkSizes(count: strip.count, weights: weights, capacities: capacities)
        hyprLog(.debug, .tiling, "tileLinked: ws\(workspace) \(strip.count) windows → chunks \(sizes) across \(screens.count) screens")

        var start = 0
        for (idx, screen) in screens.enumerated() {
            let end = min(start + sizes[idx], strip.count)
            let chunk = Array(strip[start..<end])
            start = end
            tileWindows(chunk, onWorkspace: workspace, screen: screen,
                        order: chunk.map { $0.windowID })
        }
    }

    /// Cut `count` windows into contiguous per-screen chunk sizes
    /// proportional to `weights` (usable screen area), capped by
    /// `capacities` (dwindle leaf budget, `2^maxDepth`).
    ///
    /// Guarantees, in priority order:
    /// 1. no chunk exceeds its capacity (excess falls to screens with
    ///    headroom; a total beyond all capacities lands on the last
    ///    screen, whose membership pass auto-floats the overflow),
    /// 2. every screen gets at least one window once `count >=`
    ///    screen count (a lone window stays on the first screen),
    /// 3. sizes sum to `count`, remainder assigned by largest
    ///    fractional share (ties leftmost-first).
    static func linkedChunkSizes(count: Int, weights: [CGFloat], capacities: [Int]) -> [Int] {
        let n = weights.count
        guard n > 0 else { return [] }
        guard count > 0 else { return Array(repeating: 0, count: n) }

        // fewer windows than screens: fill leftmost-first (tile 1 on
        // screen 1, tile 2 on screen 2, ...) — proportional shares are
        // degenerate here and would jump a lone window to the biggest
        // screen instead of the primary one.
        if count < n {
            return (0..<n).map { $0 < count ? 1 : 0 }
        }

        let total = weights.reduce(0, +)
        let ideals = weights.map { CGFloat(count) * $0 / max(total, 1) }
        var sizes = ideals.map { Int($0.rounded(.down)) }

        // distribute the remainder by largest fractional part, leftmost ties
        var remainder = count - sizes.reduce(0, +)
        let byFraction = ideals.enumerated()
            .sorted { a, b in
                let fa = a.element - a.element.rounded(.down)
                let fb = b.element - b.element.rounded(.down)
                if fa != fb { return fa > fb }
                return a.offset < b.offset
            }
            .map { $0.offset }
        var fi = 0
        while remainder > 0 {
            sizes[byFraction[fi % n]] += 1
            fi += 1
            remainder -= 1
        }

        // min-1: no screen sits empty while another holds several windows
        if count >= n {
            for i in 0..<n where sizes[i] == 0 {
                guard let donor = sizes.indices.max(by: { sizes[$0] < sizes[$1] }), sizes[donor] > 1 else { break }
                sizes[donor] -= 1
                sizes[i] += 1
            }
        }

        // capacity: shift excess to screens with headroom (leftmost first);
        // when everything is full, the last screen absorbs the overflow
        for i in 0..<n where sizes[i] > capacities[i] {
            var excess = sizes[i] - capacities[i]
            sizes[i] = capacities[i]
            for j in 0..<n where j != i && excess > 0 {
                let room = capacities[j] - sizes[j]
                if room > 0 {
                    let take = Swift.min(room, excess)
                    sizes[j] += take
                    excess -= take
                }
            }
            if excess > 0 { sizes[n - 1] += excess }
        }

        return sizes
    }

    /// Tile scratchpad members into a caller-supplied `rect` on the layer's
    /// `screen`, keyed on `TilingKey(workspace: 0, screen)`.
    ///
    /// Unlike `tileWindows`, the layout rect is passed in (the inset region
    /// inside the layer's monitor) rather than derived from
    /// `displayManager.cgRect(for:)`. Same membership-diff + two-pass min-size
    /// resolution otherwise. Windows that can't be smart-inserted (tree full at
    /// max depth) are returned as rejects — the caller keeps them floating.
    /// Deliberately never calls `onAutoFloat`: routing a scratchpad reject
    /// through the overflow-adopt path would loop back into the scratchpad.
    /// - Returns: the windows that didn't fit (stay floating members).
    @discardableResult
    func tileScratchpad(_ windows: [HyprWindow], screen: NSScreen, in rect: CGRect) -> [HyprWindow] {
        primeMinimumSizes(windows)
        let key = TilingKey(workspace: Self.scratchpadWorkspace, screen: screen)
        let t = tree(for: key)

        // the layer migrated monitors: drop any other (0, *) trees. their
        // windows re-enter here via the membership diff, since the caller
        // passes every AX-present tiled member.
        for other in trees.keys where other.workspace == Self.scratchpadWorkspace && other != key {
            trees.removeValue(forKey: other)
        }

        let currentIDs = Set(windows.map { $0.windowID })
        let treeWindows = t.allWindows
        let treeIDs = Set(treeWindows.map { $0.windowID })

        // membership diff: remove gone (sibling promotion keeps shape), insert new
        for w in treeWindows where !currentIDs.contains(w.windowID) { t.remove(w) }
        t.root.pruneEmptyNodes()
        t.root.resetSplitRatios()

        var rejects: [HyprWindow] = []
        for w in windows where !treeIDs.contains(w.windowID) {
            if !smartInsertFitting(w, into: t, maxDepth: maxDepth(for: screen), rect: rect) {
                hyprLog(.notice, .tiling, "scratchpad tile: no fitting slot for '\(w.title ?? "?")' (\(w.windowID)) — stays floating")
                rejects.append(w)
            }
        }

        t.root.resetSplitRatios()
        let layouts = t.layout(in: rect, gap: gapSize, padding: outerPadding)
        let conflicts = applyLayout(layouts)
        if !conflicts.isEmpty {
            let mapped = conflicts.map { (window: $0.window, actual: $0.actual) }
            t.adjustForMinSizes(mapped, in: rect, gap: gapSize, padding: outerPadding)
            let adjusted = t.layout(in: rect, gap: gapSize, padding: outerPadding)
            applyLayoutFinal(adjusted)
        }
        return rejects
    }

    /// Intended layout rects for the scratchpad layer's ws-0 tree, laid out in
    /// the caller's `rect` (the inset region) rather than the full screen.
    /// `intendedTileRects` derives its rect from `displayManager.cgRect(for:)`,
    /// so it's wrong for the layer — this is the layer-region equivalent the
    /// controller reads into `lastShownFrames`.
    func scratchpadTileRects(screen: NSScreen, in rect: CGRect) -> [CGWindowID: CGRect] {
        let key = TilingKey(workspace: Self.scratchpadWorkspace, screen: screen)
        guard let t = trees[key] else { return [:] }
        var out: [CGWindowID: CGRect] = [:]
        for (window, frame) in t.layout(in: rect, gap: gapSize, padding: outerPadding) {
            out[window.windowID] = frame
        }
        return out
    }

    /// Mutate the (workspace, screen) tree to reflect `windows` and return
    /// the resulting per-window layout rects WITHOUT applying frames.
    ///
    /// - Important: This call **mutates the tree** before returning — windows
    ///   missing from the input are removed (with `compact`), new windows are
    ///   added via `smartInsertFitting`, structural-change ratio flags are
    ///   cleared, and `resetSplitRatios` is run. The caller is committed to
    ///   either applying the returned layout (via `applyComputedLayout`) or
    ///   accepting that the tree is now in its post-tile state regardless of
    ///   what the caller does with the returned rects. This is intentional —
    ///   animation paths need post-mutation geometry to interpolate toward.
    /// - Returns: `[(window, frame)]` pairs in tree iteration order. Empty
    ///   array if the tree ends up empty.
    func prepareTileLayout(_ windows: [HyprWindow], onWorkspace workspace: Int, screen: NSScreen,
                           order: [CGWindowID]? = nil) -> [(HyprWindow, CGRect)] {
        let m = updateTreeMembership(windows, onWorkspace: workspace, screen: screen, order: order)
        rememberPendingInserted(m.insertedWindows, for: m.key)
        return m.tree.layout(in: m.rect, gap: gapSize, padding: outerPadding)
    }

    /// BSP-computed intended rect for every tiled window across all
    /// `(workspace, screen)` trees, keyed by window ID. This is the layout
    /// the engine *wants* — distinct from the live AX frame, which can be
    /// inflated when an app refuses to shrink to its slot. Use in geometric
    /// pickers (directional focus/swap) so a crammed window doesn't push
    /// its inflated edges past a neighbor's far edge and exclude that
    /// neighbor from the candidate set.
    func intendedTileRects() -> [CGWindowID: CGRect] {
        var out: [CGWindowID: CGRect] = [:]
        // diag: track which (ws, screen) tree last wrote each windowID so a
        // window living in two trees (stale dup) is loud. see directional-focus bug.
        var sourceTree: [CGWindowID: String] = [:]
        for (key, t) in trees {
            guard let screen = displayManager.screens.first(where: {
                TilingKey(workspace: key.workspace, screen: $0) == key
            }) else {
                hyprLog(.notice, .tiling, "intendedRects: tree ws\(key.workspace) sid=\(key.screenID) matches NO current screen — skipped (\(t.allWindows.count) windows)")
                continue
            }
            let rect = displayManager.cgRect(for: screen)
            hyprLog(.debug, .tiling, "intendedRects: tree ws\(key.workspace) sid=\(key.screenID) -> '\(screen.localizedName)' rect=\(rect) (\(t.allWindows.count) windows)")
            // accordion screens report accordion frames — those ARE the
            // intent there; BSP rects would disagree with every live frame.
            let layout = accordionActive(screen)
                ? AccordionLayout.frames(order: t.allWindows,
                                         focusedID: accordionFocusedWindowID(),
                                         in: rect, padding: outerPadding,
                                         overlap: accordionOverlap)
                : t.layout(in: rect, gap: gapSize, padding: outerPadding)
            for (window, frame) in layout {
                let tag = "ws\(key.workspace)@\(screen.localizedName)"
                if let prev = sourceTree[window.windowID] {
                    hyprLog(.notice, .tiling, "intendedRects: DUP windowID \(window.windowID) '\(window.title ?? "?")' in both [\(prev)] and [\(tag)] — \(tag) wins rect=\(frame)")
                }
                sourceTree[window.windowID] = tag
                out[window.windowID] = frame
            }
        }
        return out
    }

    /// Add a single window to the `(workspace, screen)` tree and
    /// retile. Auto-floats via `onAutoFloat` when smart insert cannot
    /// place the window without violating `minSlotDimension`. No-op
    /// for floating windows.
    func addWindow(_ window: HyprWindow, toWorkspace workspace: Int, on screen: NSScreen) {
        guard !window.isFloating else { return }
        primeMinimumSizes([window])
        let key = TilingKey(workspace: workspace, screen: screen)
        let t = tree(for: key)
        let rect = displayManager.cgRect(for: screen)
        var inserted: [HyprWindow] = []
        if !t.contains(window) {
            // judge fit against post-reset geometry, not stale pass-2 ratios
            t.root.resetSplitRatios()
            if !smartInsertFitting(window, into: t, maxDepth: maxDepth(for: screen), rect: rect) {
                hyprLog(.debug, .lifecycle, "no fitting tile slot — auto-floating '\(window.title ?? "?")'")
                onAutoFloat?(window)
                return
            }
            inserted.append(window)
        }
        if !inserted.isEmpty { applySortPriority(to: t) }
        retile(key: key, screen: screen, inserted: inserted)
    }

    /// Remove `window` from its workspace's tree on whichever screen
    /// holds it. Prunes the tree (sibling promotion preserves the
    /// surviving arrangement), then retiles the affected screen.
    func removeWindow(_ window: HyprWindow, fromWorkspace workspace: Int) {
        // search all trees for this workspace
        for (key, t) in trees where key.workspace == workspace {
            if t.contains(window) {
                t.remove(window)
                t.root.pruneEmptyNodes()
                if let screen = displayManager.screens.first(where: {
                    TilingKey(workspace: workspace, screen: $0) == key
                }) {
                    retile(key: key, screen: screen)
                }
                return
            }
        }
    }

    // preserveMinSizesOnOverflow:
    //   true  → swap-rejection callers (swapWindows + applyComputedLayout's
    //           animated swap revert) need the readback-confirmed mins to
    //           survive past this retile so their post-retile fit check sees
    //           the real bound and can reject the swap.
    //   false → all other callers want the pre-0f24775 behavior. preserving
    //           mins here ratchets every visible app's recorded minimum up to
    //           whatever-it-couldn't-shrink-to-this-attempt and keeps it
    //           sticky. forceInsertWindow's smart-insert pre-check then
    //           reads those bumped values via pairFits and false-rejects
    //           legitimate slots, dropping forceInsertWindow into its
    //           eviction fallback — which is supposed to fire only when the
    //           tree is full. user-observed bug: Caps+Shift+T on a floating
    //           window kicks an existing tile out instead of slotting in.
    private func retile(key: TilingKey, screen: NSScreen,
                        inserted: [HyprWindow] = [],
                        preserveMinSizesOnOverflow: Bool = false) {
        let t = tree(for: key)
        primeMinimumSizes(t.allWindows)
        let rect = displayManager.cgRect(for: screen)

        // accordion mode: same tree, presentation-only frames, no
        // readback (see tileWindows).
        if accordionActive(screen) {
            _ = consumePendingInserted(for: key, in: t)
            applyAccordionLayout(t, rect: rect)
            return
        }

        let insertedForOverflow = mergedInserted(inserted, pending: consumePendingInserted(for: key, in: t))

        t.root.resetSplitRatios()

        let layouts = t.layout(in: rect, gap: gapSize, padding: outerPadding)
        let conflicts = applyLayout(layouts)

        if !conflicts.isEmpty {
            let mapped = conflicts.map { (window: $0.window, actual: $0.actual) }
            t.adjustForMinSizes(mapped, in: rect, gap: gapSize, padding: outerPadding)
            let adjusted = t.layout(in: rect, gap: gapSize, padding: outerPadding)
            let overflow = overflowingWindows(in: adjusted)
            if autoFloatOverflow(overflow, inserted: insertedForOverflow,
                                 tree: t, key: key, screen: screen) {
                return
            }
            if !overflow.isEmpty {
                if preserveMinSizesOnOverflow {
                    hyprLog(.debug, .lifecycle, "overflow persisted with no inserted target — preserving recorded min sizes for caller's post-retile fit check")
                } else {
                    hyprLog(.debug, .lifecycle, "overflow persisted with no inserted target — discarding min-size adjustment")
                    minSizes.clear(for: overflow)
                }
                t.root.resetSplitRatios()
                applyLayoutFinal(layouts)
                return
            }
            applyLayoutFinal(adjusted)
        }
    }

    /// Apply a manual resize: update the surrounding split ratios so
    /// `window`'s new frame is preserved, then retile.
    func applyResize(_ window: HyprWindow, newFrame: CGRect, onWorkspace workspace: Int, screen: NSScreen) {
        let key = TilingKey(workspace: workspace, screen: screen)
        let t = tree(for: key)
        let rect = displayManager.cgRect(for: screen)

        t.applyResizeDelta(for: window, newFrame: newFrame, in: rect, gap: gapSize, padding: outerPadding)
        retile(key: key, screen: screen)
    }

    /// `true` when `a` and `b` can be swapped without violating any
    /// recorded min-size constraint.
    ///
    /// Snapshots the tree, performs a trial swap with cleared
    /// user-resize ratios, and asks `LayoutEngine` whether the result
    /// fits every window's currently-known minimum. Restores the
    /// original tree before returning regardless of outcome. Primes
    /// `MinSizeMemory` for every window in the tree first — siblings'
    /// min sizes still influence the post-swap fit decision.
    func canSwapWindows(_ a: HyprWindow, _ b: HyprWindow,
                        onWorkspace workspace: Int, screen: NSScreen) -> Bool {
        let key = TilingKey(workspace: workspace, screen: screen)
        let t = tree(for: key)
        // prime ALL tree windows, not just [a, b]. siblings still influence
        // whether adjustForMinSizes can resolve conflicts post-swap; if their
        // min sizes are stale or missing in the memory, the fit check produces
        // inconsistent rejections (e.g., a swap that should reject when a
        // sibling has a hard minimum sneaks through because its min wasn't
        // re-synced).
        primeMinimumSizes(t.allWindows)
        guard t.contains(a) && t.contains(b) else { return false }

        let snapshot = t.snapshot()
        defer { t.restore(snapshot) }

        let rect = displayManager.cgRect(for: screen)
        t.swap(a, b)
        // clear userSetRatio + reset to 50/50 for the test layout. matches
        // what the actual swap does below, so canSwapWindows and the
        // post-acceptance retile evaluate against the same baseline. without
        // this, a previously user-resized split that favored Spotify's old
        // slot biases the test in favor of *whatever lands in that slot
        // post-swap*, masking conflicts that the actual retile would hit.
        t.root.clearUserSetRatios()
        t.root.resetSplitRatios()
        return layoutCanAccommodateKnownMinimums(t, rect: rect)
    }

    /// `true` when a cross-monitor swap can place each window into the
    /// other's tree without violating recorded min-size constraints.
    ///
    /// Mirrors `canSwapWindows`, but evaluates both affected trees. The
    /// trial clears user ratios because those ratios belonged to the
    /// previous occupants on each screen; the real cross-swap path uses
    /// the same baseline so preflight and commit agree.
    func canCrossSwapWindows(_ a: HyprWindow, _ b: HyprWindow) -> Bool {
        guard let foundA = treeContaining(a),
              let foundB = treeContaining(b) else { return false }

        if foundA.key == foundB.key {
            guard let screen = screen(for: foundA.key) else { return false }
            return canSwapWindows(a, b, onWorkspace: foundA.key.workspace, screen: screen)
        }

        let windowsToPrime = foundA.tree.allWindows + foundB.tree.allWindows
        primeMinimumSizes(windowsToPrime)

        let snapshotA = foundA.tree.snapshot()
        let snapshotB = foundB.tree.snapshot()
        defer {
            foundA.tree.restore(snapshotA)
            foundB.tree.restore(snapshotB)
        }

        guard let nodeA = foundA.tree.root.find(a),
              let nodeB = foundB.tree.root.find(b),
              let screenA = screen(for: foundA.key),
              let screenB = screen(for: foundB.key) else { return false }

        nodeA.window = b
        nodeB.window = a
        foundA.tree.root.clearUserSetRatios()
        foundB.tree.root.clearUserSetRatios()
        foundA.tree.root.resetSplitRatios()
        foundB.tree.root.resetSplitRatios()

        return layoutCanAccommodateKnownMinimums(foundA.tree, rect: displayManager.cgRect(for: screenA))
            && layoutCanAccommodateKnownMinimums(foundB.tree, rect: displayManager.cgRect(for: screenB))
    }

    /// Synchronous swap path (no animation).
    ///
    /// Snapshots the tree before swapping so a post-readback overflow
    /// — which `canSwapWindows`' seeded mins can miss when an app's
    /// real minimum depends on UI state — can be reverted. Returns
    /// `true` on success, `false` when the swap was rejected up front
    /// or reverted after readback.
    @discardableResult
    func swapWindows(_ a: HyprWindow, _ b: HyprWindow, onWorkspace workspace: Int, screen: NSScreen) -> Bool {
        guard canSwapWindows(a, b, onWorkspace: workspace, screen: screen) else { return false }
        let key = TilingKey(workspace: workspace, screen: screen)
        let t = tree(for: key)

        // canSwapWindows uses the recorded min sizes which can be seeded
        // (AX-static) rather than confirmed via readback. for windows like
        // Spotify whose actual min depends on current UI state, the seeded
        // values can be too small — canSwapWindows accepts, but the real
        // pass-1 readback after the swap reveals overflow. snapshot the
        // tree first so we can revert on that case.
        let snapshot = t.snapshot()
        t.swap(a, b)
        // see canSwapWindows — swap is a structural change, prior manual
        // ratios applied to the OLD occupant of a slot, not the new one.
        t.root.clearUserSetRatios()
        // preserveMinSizesOnOverflow: the post-retile check below reads
        // minimumSize against the retile's freshly-recorded mins. if retile
        // cleared them on the no-inserted-target overflow branch, the
        // post-retile check would false-pass.
        retile(key: key, screen: screen, preserveMinSizesOnOverflow: true)

        // post-retile fit check: minSizes was updated by pass-1 readback
        // during retile. if the resulting layout still overflows the
        // freshly-recorded mins, the swap doesn't actually fit — revert.
        let rect = displayManager.cgRect(for: screen)
        let postLayout = t.layout(in: rect, gap: gapSize, padding: outerPadding)
        if !overflowingWindows(in: postLayout).isEmpty {
            hyprLog(.debug, .lifecycle, "swap overflow detected post-readback — reverting")
            t.restore(snapshot)
            retile(key: key, screen: screen)
            return false
        }
        return true
    }

    /// Pending pre-swap snapshot for the animated swap path. Set by
    /// `prepareSwapLayout`, consumed (or cleared) by `applyComputedLayout`.
    /// Defensively cleared by `prepareToggleSplitLayout` to prevent leakage
    /// across consecutive prepare-then-apply cycles when the user triggers
    /// a non-swap action between the two halves.
    private var pendingSwapRevert: (key: TilingKey, snapshot: BSPTree.Snapshot)?

    /// Swap two windows' positions in the tree and return post-swap layout
    /// rects without applying frames.
    ///
    /// - Important: **Mutates the tree** before returning — `BSPTree.swap`
    ///   exchanges leaf window references and `resetSplitRatios` runs. If the
    ///   caller does nothing with the returned layout, the tree is still in
    ///   its post-swap state. Captures a pre-swap snapshot for revert; the
    ///   matching `applyComputedLayout` call consumes it.
    /// - Returns: `nil` if either window is missing from the tree or the
    ///   pair fails the cross-axis fit check; otherwise the new layout.
    func prepareSwapLayout(_ a: HyprWindow, _ b: HyprWindow,
                           onWorkspace workspace: Int, screen: NSScreen) -> [(HyprWindow, CGRect)]? {
        guard canSwapWindows(a, b, onWorkspace: workspace, screen: screen) else { return nil }
        let key = TilingKey(workspace: workspace, screen: screen)
        let t = tree(for: key)
        guard t.contains(a) && t.contains(b) else { return nil }
        let rect = displayManager.cgRect(for: screen)

        // capture snapshot for post-readback overflow revert (animated swap
        // path). canSwapWindows uses the recorded min size which can be
        // seeded rather than confirmed via readback — for windows like
        // Spotify whose actual min depends on UI state, the seed lies and
        // canSwapWindows false-accepts. The real readback during retile
        // (triggered by applyComputedLayout) is the ground truth, and
        // applyComputedLayout reverts via this snapshot if overflow persists.
        pendingSwapRevert = (key: key, snapshot: t.snapshot())
        t.swap(a, b)
        // clear userSetRatio + reset to 50/50 so the test layout matches
        // canSwapWindows's evaluation baseline (see canSwapWindows).
        t.root.clearUserSetRatios()
        t.root.resetSplitRatios()
        return t.layout(in: rect, gap: gapSize, padding: outerPadding)
    }

    /// Re-apply the current tree state to AX frames using the two-pass
    /// min-size resolution. Pairs with `prepare*Layout`: caller mutates the
    /// tree (via prepare), drives an animation against the returned rects,
    /// then calls `applyComputedLayout` on completion to settle frames.
    ///
    /// If the prepare call was `prepareSwapLayout` (which captures a
    /// pre-swap snapshot), the post-retile layout is checked for overflow
    /// against the freshly-recorded min sizes; on overflow the snapshot is
    /// restored and a clean retile applied. Returns `false` in that case so
    /// the caller can `flashError`. For non-swap callers (toggleSplit etc.)
    /// the return is always `true`.
    @discardableResult
    func applyComputedLayout(onWorkspace workspace: Int, screen: NSScreen) -> Bool {
        let key = TilingKey(workspace: workspace, screen: screen)
        let t = tree(for: key)
        // when a swap is pending, the post-retile fit check below relies on
        // freshly-recorded mins surviving past retile (same contract as
        // swapWindows above). otherwise — toggleSplit, animated retile from
        // tileAllVisibleSpaces, etc. — fall through to the default which
        // matches forceInsertWindow's expectations.
        let preserve = (pendingSwapRevert?.key == key)
        retile(key: key, screen: screen, preserveMinSizesOnOverflow: preserve)

        // consume any pending swap snapshot for this key. only the swap
        // path sets this — toggleSplit etc. leave it nil.
        guard let pending = pendingSwapRevert, pending.key == key else { return true }
        pendingSwapRevert = nil

        let rect = displayManager.cgRect(for: screen)
        let postLayout = t.layout(in: rect, gap: gapSize, padding: outerPadding)
        if !overflowingWindows(in: postLayout).isEmpty {
            hyprLog(.debug, .lifecycle, "animated swap overflow detected post-readback — reverting")
            t.restore(pending.snapshot)
            retile(key: key, screen: screen)
            return false
        }
        return true
    }

    /// Cross-monitor swap. Locates whichever trees hold `a` and `b`,
    /// exchanges their leaf window references in place, and retiles
    /// both screens. Silent no-op when either window is not in any
    /// tree (handles drag-from-floating cases). The two retile passes
    /// run synchronously back-to-back; pollers are gated externally
    /// via `cross-swap-in-flight` for the ~800 ms it takes.
    @discardableResult
    func crossSwapWindows(_ a: HyprWindow, _ b: HyprWindow) -> Bool {
        guard canCrossSwapWindows(a, b),
              let foundA = treeContaining(a),
              let foundB = treeContaining(b),
              let screenA = screen(for: foundA.key),
              let screenB = screen(for: foundB.key) else { return false }

        if foundA.key == foundB.key {
            return swapWindows(a, b, onWorkspace: foundA.key.workspace, screen: screenA)
        }

        let snapshotA = foundA.tree.snapshot()
        let snapshotB = foundB.tree.snapshot()

        if let nodeA = foundA.tree.root.find(a) { nodeA.window = b }
        if let nodeB = foundB.tree.root.find(b) { nodeB.window = a }
        foundA.tree.root.clearUserSetRatios()
        foundB.tree.root.clearUserSetRatios()

        retile(key: foundA.key, screen: screenA, preserveMinSizesOnOverflow: true)
        retile(key: foundB.key, screen: screenB, preserveMinSizesOnOverflow: true)

        let overflowA = overflowingWindows(in: foundA.tree.layout(in: displayManager.cgRect(for: screenA),
                                                                  gap: gapSize,
                                                                  padding: outerPadding))
        let overflowB = overflowingWindows(in: foundB.tree.layout(in: displayManager.cgRect(for: screenB),
                                                                  gap: gapSize,
                                                                  padding: outerPadding))
        if !overflowA.isEmpty || !overflowB.isEmpty {
            hyprLog(.debug, .lifecycle, "cross-monitor swap overflow detected post-readback — reverting")
            foundA.tree.restore(snapshotA)
            foundB.tree.restore(snapshotB)
            retile(key: foundA.key, screen: screenA)
            retile(key: foundB.key, screen: screenB)
            return false
        }

        return true
    }

    /// Synchronous split-direction toggle for `window`'s parent
    /// node. Animation-free path; the dispatcher's animated path goes
    /// through `prepareToggleSplitLayout` instead.
    func toggleSplit(_ window: HyprWindow, onWorkspace workspace: Int, screen: NSScreen) {
        let key = TilingKey(workspace: workspace, screen: screen)
        let t = tree(for: key)
        let rect = displayManager.cgRect(for: screen)
        t.toggleSplit(for: window, in: rect, gap: gapSize, padding: outerPadding)
        retile(key: key, screen: screen)
    }

    /// Toggle the split direction of `window`'s parent and return post-toggle
    /// layout rects without applying frames.
    ///
    /// - Important: **Mutates the tree** before returning. `splitOverride`
    ///   flips on the parent and `resetSplitRatios` runs. Calling this twice
    ///   in succession reverts the toggle — that footgun is exactly what the
    ///   `WindowManager.toggleSplit()` fallthrough fix prevents (see plan
    ///   §4.2 + commit ee9e2df).
    /// - Returns: `nil` if `window` isn't in the tree (no toggle performed);
    ///   otherwise the post-toggle layout.
    func prepareToggleSplitLayout(_ window: HyprWindow,
                                  onWorkspace workspace: Int, screen: NSScreen) -> [(HyprWindow, CGRect)]? {
        let key = TilingKey(workspace: workspace, screen: screen)
        let t = tree(for: key)
        guard t.contains(window) else { return nil }
        // defensive: clear any stale pending swap snapshot so the next
        // applyComputedLayout doesn't try to revert this toggleSplit.
        pendingSwapRevert = nil
        let rect = displayManager.cgRect(for: screen)
        t.toggleSplit(for: window, in: rect, gap: gapSize, padding: outerPadding)
        t.root.resetSplitRatios()
        return t.layout(in: rect, gap: gapSize, padding: outerPadding)
    }

    /// `true` when the `(workspace, screen)` tree has room for an
    /// additional window without violating min-size constraints.
    ///
    /// `window` is optional — passing it primes its size for the
    /// pair-fit check; passing `nil` checks generic capacity.
    /// Empty trees are always fittable.
    func canFitWindow(_ window: HyprWindow? = nil,
                      onWorkspace workspace: Int,
                      screen: NSScreen) -> Bool {
        let key = TilingKey(workspace: workspace, screen: screen)
        let t = tree(for: key)
        if t.root.isEmpty { return true }
        // prime tree tenants AND incoming window — pairFits reads
        // minimumSize for both leaf occupant and incoming, so both must be
        // synced against the latest known/observed values.
        var toPrime = t.allWindows
        if let window { toPrime.append(window) }
        primeMinimumSizes(toPrime)

        let rect = displayManager.cgRect(for: screen)
        return fittingLeaf(for: window,
                           in: t,
                           maxDepth: maxDepth(for: screen),
                           rect: rect) != nil
    }

    /// Force `window` into the `(workspace, screen)` tree, evicting
    /// the deepest-right tile when no room remains.
    ///
    /// Used by float→tile toggles when the user explicitly wants
    /// `window` tiled even though smart insert would otherwise reject
    /// for capacity. Returns the evicted window so the caller can
    /// auto-float it; `nil` when the insert succeeded without
    /// eviction.
    func forceInsertWindow(_ window: HyprWindow, toWorkspace workspace: Int, on screen: NSScreen) -> HyprWindow? {
        primeMinimumSizes([window])
        let key = TilingKey(workspace: workspace, screen: screen)
        let t = tree(for: key)
        let rect = displayManager.cgRect(for: screen)

        if t.contains(window) { return nil }

        if smartInsertFitting(window, into: t, maxDepth: maxDepth(for: screen), rect: rect) {
            retile(key: key, screen: screen, inserted: [window])
            return nil
        }

        guard let evicted = t.deepestRightLeafWindow() else { return nil }
        t.remove(evicted)

        if smartInsertFitting(window, into: t, maxDepth: maxDepth(for: screen), rect: rect) {
            retile(key: key, screen: screen, inserted: [window])
            return evicted
        }

        _ = t.insert(evicted, maxDepth: maxDepth(for: screen))
        retile(key: key, screen: screen)
        return nil
    }
}
