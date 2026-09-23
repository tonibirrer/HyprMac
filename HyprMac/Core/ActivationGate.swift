import Foundation

/// Decides whether an app activation may switch workspaces.
///
/// `WindowManager.appDidActivate` implements the "dock-click takes me to
/// that app's workspace" affordance: an app that activates without a
/// visible window gets its workspace shown. macOS also activates apps on
/// its own — a terminal raising itself, and above all the fallback where
/// the front app refuses or loses activation and the window server hands
/// it to the topmost on-screen window, which on a single screen is a
/// window HyprMac parked in the hide corner. Those must never switch.
///
/// The gate tells the two apart by the user's recent gesture. Only an
/// unambiguous one counts:
/// - a ⌘-Tab keystroke (`HotkeyManager.lastCommandGestureTime`);
/// - a left click that did NOT land on a managed window — a click on a
///   tile or floater expresses intent for that window, not for whatever
///   app macOS activates next;
/// - a launcher (Dock, Spotlight, Raycast, Alfred) as the previous
///   frontmost app.
///
/// An explicit workspace switch (hotkey, IPC, overview) is the freshest
/// statement of where the user wants to be: for a second afterwards only
/// a fresh ⌘-Tab may move them again (`explicitSwitchRecent`).
enum ActivationGate {
    /// How long a gesture authorizes an activation. A Cmd-Tab's activation
    /// lands well under 0.5s after the ⌘ release.
    static let gestureWindow: CFAbsoluteTime = 0.75

    static let launcherBundleIDs: Set<String> = [
        "com.apple.dock",
        "com.apple.Spotlight",
        "com.raycast.macos",
        "com.runningwithcrayons.Alfred",
    ]

    enum Gesture: Equatable {
        case cmdTab
        case click
        case launcher(String)
    }

    struct Input {
        var now: CFAbsoluteTime
        var lastCmdTabTime: CFAbsoluteTime = 0
        var lastClickTime: CFAbsoluteTime = 0
        /// The last click landed on a tile or floater on a visible workspace.
        var clickHitManagedWindow = false
        var predecessorBundleID: String? = nil
        /// `"activation-switch"`: HyprMac's own focus churn is in flight.
        var ownChurnSuppressed = false
        /// `"activation-switch-hard"`: an explicit switch just happened.
        var explicitSwitchRecent = false
        /// The activated app already shows a window (or a summoned scratchpad member).
        var hasVisibleWindow = false
        /// A `focusOnActivate` window rule allows this app to switch on its own.
        var ruleActivate = false
    }

    enum Decision: Equatable {
        /// The app has a visible window; the affordance has nothing to do.
        case passThrough
        /// Our own churn, no gesture: ignore silently.
        case suppressed(String)
        /// No visible window, no gesture, no rule: programmatic self-activation.
        case ignoredProgrammatic(String)
        /// Switch to the app's workspace (or summon the scratchpad).
        case allowed(String)
    }

    /// The gesture that authorizes this activation, if any.
    static func gesture(_ input: Input) -> Gesture? {
        if input.now - input.lastCmdTabTime < gestureWindow { return .cmdTab }
        if input.explicitSwitchRecent { return nil }
        if input.now - input.lastClickTime < gestureWindow, !input.clickHitManagedWindow { return .click }
        if let prev = input.predecessorBundleID, launcherBundleIDs.contains(prev) { return .launcher(prev) }
        return nil
    }

    static func decide(_ input: Input) -> Decision {
        let gesture = gesture(input)
        let why = describe(gesture, input)
        if input.ownChurnSuppressed, gesture == nil { return .suppressed(why) }
        if input.hasVisibleWindow { return .passThrough }
        if gesture == nil, !input.ruleActivate { return .ignoredProgrammatic(why) }
        return .allowed(why)
    }

    /// One line for the log: which gesture qualified, or why none did.
    static func describe(_ gesture: Gesture?, _ input: Input) -> String {
        func age(_ t: CFAbsoluteTime) -> String { String(format: "%.2fs", input.now - t) }
        switch gesture {
        case .cmdTab: return "gesture=cmdTab age=\(age(input.lastCmdTabTime))"
        case .click: return "gesture=click(outside managed windows) age=\(age(input.lastClickTime))"
        case .launcher(let id): return "gesture=launcher(\(id))"
        case nil:
            var parts: [String] = []
            if input.explicitSwitchRecent { parts.append("explicit switch <1s ago") }
            if input.now - input.lastClickTime < gestureWindow {
                parts.append("click \(age(input.lastClickTime)) ago hit a managed window")
            }
            if input.ruleActivate { parts.append("focusOnActivate rule") }
            let detail = parts.isEmpty ? "no recent ⌘-Tab/click/launcher" : parts.joined(separator: ", ")
            return "gesture=none (\(detail); predecessor=\(input.predecessorBundleID ?? "none"))"
        }
    }
}
