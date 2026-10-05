// Native-fullscreen Spaces, read straight from the window server.
//
// A native-fullscreen window lives on a Space of its own. While that Space
// shows, the display's desktop Space — where every tile and every parked
// window of HyprMac's virtual workspaces lives — is not on screen, and
// neither the on-screen window list nor AX's window list reports those
// windows. AX elements read before still answer, and a frame written
// through one moves the window (onto another display's Space, too).
// Verified live on macOS 27 (2026-10-05).

import Cocoa

/// One display's Spaces as the window server reports them.
struct DisplaySpaceState: Equatable {
    let displayUUID: String
    let currentSpace: CGSSpaceID
    /// The display shows a native-fullscreen Space right now.
    let currentIsFullscreen: Bool
    /// Its regular desktop Spaces (type 0).
    let desktopSpaces: Set<CGSSpaceID>
    /// Its native-fullscreen Spaces (type 4), with the owning process
    /// when the window server names one.
    let fullscreenSpaces: [CGSSpaceID: pid_t?]
}

/// A window that owns a native-fullscreen Space.
struct FullscreenWindowObservation: Equatable {
    let windowID: CGWindowID
    let pid: pid_t
    let space: CGSSpaceID
    let displayUUID: String
    /// Its Space is the one its display shows right now.
    let isShowing: Bool
}

/// Reads display Spaces and native-fullscreen windows from the window
/// server. Stateless; every call is a fresh read.
final class FullscreenSpaceReader {

    private static let desktopSpaceType = 0
    private static let fullscreenSpaceType = 4
    // every space a window is on, any type
    private static let allSpacesMask: CGSSpaceType = 7

    func displays() -> [DisplaySpaceState] {
        guard let raw = CGSCopyManagedDisplaySpaces(_CGSDefaultConnection()) as? [[String: Any]] else { return [] }
        return raw.compactMap { display in
            guard let uuid = display["Display Identifier"] as? String,
                  let current = (display["Current Space"] as? [String: Any]).flatMap(Self.spaceID) else { return nil }
            var desktops = Set<CGSSpaceID>()
            var fullscreen: [CGSSpaceID: pid_t?] = [:]
            var currentIsFullscreen = false
            for space in display["Spaces"] as? [[String: Any]] ?? [] {
                guard let id = Self.spaceID(space) else { continue }
                switch space["type"] as? Int {
                case Self.desktopSpaceType:
                    desktops.insert(id)
                case Self.fullscreenSpaceType:
                    fullscreen[id] = (space["pid"] as? Int).map { pid_t($0) }
                    if id == current { currentIsFullscreen = true }
                default:
                    break
                }
            }
            return DisplaySpaceState(displayUUID: uuid, currentSpace: current,
                                     currentIsFullscreen: currentIsFullscreen,
                                     desktopSpaces: desktops, fullscreenSpaces: fullscreen)
        }
    }

    /// Every Space `windowID` is on. Empty for a window the server does
    /// not know (closed) or one on no Space (minimized).
    func spaces(of windowID: CGWindowID) -> [CGSSpaceID] {
        let ids = [NSNumber(value: windowID)] as CFArray
        guard let raw = CGSCopySpacesForWindows(_CGSDefaultConnection(), Self.allSpacesMask, ids) as? [NSNumber] else { return [] }
        return raw.map(\.uint64Value)
    }

    /// The window owning each native-fullscreen Space, showing or not: the
    /// largest normal-layer window of the Space's process that sits on that
    /// Space alone. The thin toolbar strips a fullscreen app adds there are
    /// smaller. Size alone does not identify it: the window server keeps
    /// whatever bounds the window had when its Space last showed — after a
    /// wake that brought the displays back one by one, a fullscreen window
    /// read 1920×1080 on a 3440×1440 screen.
    func fullscreenWindows(in displays: [DisplaySpaceState], ignoring ignoredPIDs: Set<pid_t>) -> [FullscreenWindowObservation] {
        var owners: [CGSSpaceID: (display: DisplaySpaceState, pid: pid_t?)] = [:]
        for display in displays {
            for (space, pid) in display.fullscreenSpaces { owners[space] = (display, pid) }
        }
        guard !owners.isEmpty,
              let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return [] }
        // when the server names every Space's process, only theirs are read
        let ownerPIDs: Set<pid_t>? = owners.values.contains { $0.pid == nil } ? nil : Set(owners.values.compactMap(\.pid))

        var largest: [CGSSpaceID: (windowID: CGWindowID, pid: pid_t, area: CGFloat)] = [:]
        for info in list {
            guard let wid = info[kCGWindowNumber as String] as? CGWindowID,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  (info[kCGWindowLayer as String] as? Int) == 0,
                  !ignoredPIDs.contains(pid),
                  ownerPIDs?.contains(pid) ?? true,
                  let bounds = info[kCGWindowBounds as String] as? [String: CGFloat]
            else { continue }
            let width = bounds["Width"] ?? 0, height = bounds["Height"] ?? 0
            // toolbar and title strips are ~30 pt tall
            guard min(width, height) > 100 else { continue }
            let spaces = spaces(of: wid)
            guard spaces.count == 1, let space = spaces.first, let owner = owners[space],
                  owner.pid == nil || owner.pid == pid else { continue }
            if width * height > largest[space]?.area ?? 0 {
                largest[space] = (wid, pid, width * height)
            }
        }
        return largest.sorted { $0.key < $1.key }.compactMap { space, window in
            guard let owner = owners[space] else { return nil }
            return FullscreenWindowObservation(
                windowID: window.windowID, pid: window.pid, space: space,
                displayUUID: owner.display.displayUUID,
                isShowing: owner.display.currentSpace == space)
        }
    }

    /// The window server's identifier for `screen`, as `displays()` names it.
    static func displayUUID(for screen: NSScreen) -> String? {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }

    private static func spaceID(_ space: [String: Any]) -> CGSSpaceID? {
        if let id = space["ManagedSpaceID"] as? CGSSpaceID { return id }
        if let id = space["ManagedSpaceID"] as? Int { return CGSSpaceID(id) }
        if let id = space["id64"] as? CGSSpaceID { return id }
        return nil
    }
}
