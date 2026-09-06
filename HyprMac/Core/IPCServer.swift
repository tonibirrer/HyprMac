// Hyprland-style IPC over unix domain sockets. Two sockets, mirroring
// Hyprland's .socket.sock / .socket2.sock split:
//
//   hyprmac.sock        — request/response: one line in, JSON out, close.
//   hyprmac.events.sock — event stream: connect and receive one line per
//                         event ("EVENT>>DATA"), stay connected.
//
// This is the integration surface for status bars (sketchybar) and
// scripting — the moral equivalent of `hyprctl` + `socat` on Hyprland.

import Cocoa

/// Serves workspace/window state over `hyprmac.sock` and broadcasts
/// change events over `hyprmac.events.sock` (both in the HyprMac
/// Application Support directory).
///
/// Commands (newline-terminated):
///   workspaces        → JSON array: id, monitor, visible, focused, windows
///   windows <ws>      → JSON array: window id, app, bundleID, title, hidden, sticky
///   focused           → JSON object: focused workspace + monitor
///
/// Events:
///   workspace>>FOCUSED>>PREV   — visible/focused workspace changed
///   windowschanged>>           — window set changed (open/close/move)
///
/// State reads happen on the main thread; socket I/O on background
/// queues. Events are fired from NotificationCenter observers.
final class IPCServer {

    static let commandSocketURL = ConfigStore.configDir.appendingPathComponent("hyprmac.sock")
    static let eventSocketURL = ConfigStore.configDir.appendingPathComponent("hyprmac.events.sock")

    private let workspaceManager: WorkspaceManager
    private let displayManager: DisplayManager
    private let stateCache: WindowStateCache
    private let config: UserConfig
    /// Workspace considered focused — the one on the cursor's monitor.
    private let focusedWorkspace: () -> Int
    /// Switch to a workspace (for `dispatch workspace N` — clickable
    /// status-bar indicators). Runs on the main thread.
    private let switchWorkspace: (Int) -> Void

    private var commandListenFD: Int32 = -1
    private var eventListenFD: Int32 = -1
    private var commandSource: DispatchSourceRead?
    private var eventSource: DispatchSourceRead?
    private var eventClients: Set<Int32> = []
    private var observers: [NSObjectProtocol] = []
    private var lastFocusedWorkspace: Int = 1
    private let ioQueue = DispatchQueue(label: "hyprmac.ipc", qos: .userInitiated)

    init(workspaceManager: WorkspaceManager,
         displayManager: DisplayManager,
         stateCache: WindowStateCache,
         config: UserConfig,
         focusedWorkspace: @escaping () -> Int,
         switchWorkspace: @escaping (Int) -> Void) {
        self.workspaceManager = workspaceManager
        self.displayManager = displayManager
        self.stateCache = stateCache
        self.config = config
        self.focusedWorkspace = focusedWorkspace
        self.switchWorkspace = switchWorkspace
    }

    // MARK: - lifecycle

    func start() {
        commandListenFD = listenSocket(at: Self.commandSocketURL.path)
        eventListenFD = listenSocket(at: Self.eventSocketURL.path)
        guard commandListenFD >= 0, eventListenFD >= 0 else {
            hyprLog(.warning, .lifecycle, "IPC: failed to open sockets — integration disabled")
            return
        }

        commandSource = acceptSource(commandListenFD) { [weak self] fd in
            self?.handleCommandClient(fd)
        }
        eventSource = acceptSource(eventListenFD) { [weak self] fd in
            guard let self else { close(fd); return }
            var yes: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
            self.ioQueue.async { self.eventClients.insert(fd) }
        }

        lastFocusedWorkspace = focusedWorkspace()
        observers.append(NotificationCenter.default.addObserver(
            forName: .hyprMacWorkspaceChanged, object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                let focused = self.focusedWorkspace()
                let prev = self.lastFocusedWorkspace
                self.lastFocusedWorkspace = focused
                self.broadcast("workspace>>\(focused)>>\(prev)")
            })
        observers.append(NotificationCenter.default.addObserver(
            forName: .hyprMacWindowsChanged, object: nil, queue: .main) { [weak self] _ in
                self?.broadcast("windowschanged>>")
            })

        hyprLog(.notice, .lifecycle, "IPC: listening at \(Self.commandSocketURL.path)")
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
        commandSource?.cancel()
        eventSource?.cancel()
        if commandListenFD >= 0 { close(commandListenFD) }
        if eventListenFD >= 0 { close(eventListenFD) }
        for fd in eventClients { close(fd) }
        unlink(Self.commandSocketURL.path)
        unlink(Self.eventSocketURL.path)
    }

    // MARK: - sockets

    private func listenSocket(at path: String) -> Int32 {
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return -1 }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let ok = path.withCString { cstr -> Bool in
            let maxLen = MemoryLayout.size(ofValue: addr.sun_path) - 1
            guard strlen(cstr) <= maxLen else { return false }
            withUnsafeMutableBytes(of: &addr.sun_path) { raw in
                raw.baseAddress!.assumingMemoryBound(to: CChar.self)
                    .update(from: cstr, count: strlen(cstr) + 1)
            }
            return true
        }
        guard ok else { close(fd); return -1 }

        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, size) }
        }
        guard bound == 0, listen(fd, 8) == 0 else {
            hyprLog(.warning, .lifecycle, "IPC: bind/listen failed for \(path) errno=\(errno)")
            close(fd)
            return -1
        }
        return fd
    }

    private func acceptSource(_ listenFD: Int32, onAccept: @escaping (Int32) -> Void) -> DispatchSourceRead {
        let source = DispatchSource.makeReadSource(fileDescriptor: listenFD, queue: ioQueue)
        source.setEventHandler {
            let fd = accept(listenFD, nil, nil)
            guard fd >= 0 else { return }
            onAccept(fd)
        }
        source.resume()
        return source
    }

    // MARK: - command handling

    private func handleCommandClient(_ fd: Int32) {
        ioQueue.async { [weak self] in
            var buf = [UInt8](repeating: 0, count: 4096)
            let n = read(fd, &buf, buf.count)
            guard n > 0, let self else { close(fd); return }
            let command = String(decoding: buf[0..<n], as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            DispatchQueue.main.async {
                let reply = self.respond(to: command)
                self.ioQueue.async {
                    var yes: Int32 = 1
                    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
                    reply.withCString { _ = write(fd, $0, strlen($0)) }
                    close(fd)
                }
            }
        }
    }

    /// Main-thread state snapshot → JSON string for one command.
    private func respond(to command: String) -> String {
        let parts = command.split(separator: " ", maxSplits: 1).map(String.init)
        switch parts.first {
        case "workspaces":
            return json(workspacesPayload())
        case "windows":
            guard parts.count == 2, let ws = Int(parts[1]), (1...9).contains(ws) else {
                return json(["error": "usage: windows <1-9>"])
            }
            return json(windowsPayload(ws))
        case "focused":
            return json(["workspace": focusedWorkspace()])
        case "dispatch":
            // Hyprland's `hyprctl dispatch workspace N` shape — the hook
            // for clickable status-bar workspace indicators.
            guard parts.count == 2 else { return json(["error": "usage: dispatch workspace <1-9>"]) }
            let args = parts[1].split(separator: " ").map(String.init)
            guard args.count == 2, args[0] == "workspace",
                  let ws = Int(args[1]), (1...9).contains(ws) else {
                return json(["error": "usage: dispatch workspace <1-9>"])
            }
            switchWorkspace(ws)
            return json(["ok": true, "workspace": ws])
        default:
            return json(["error": "unknown command '\(command)' (try: workspaces | windows <ws> | focused | dispatch workspace <ws>)"])
        }
    }

    private func workspacesPayload() -> [[String: Any]] {
        let focused = focusedWorkspace()
        // left-to-right monitor ordinal (1-based), matching the static
        // workspace anchoring — NOT the internal origin-derived screenID.
        let ordered = displayManager.screens.sorted { $0.frame.origin.x < $1.frame.origin.x }
        return (1...workspaceManager.workspaceCount).map { ws in
            let home = workspaceManager.homeScreenForWorkspace(ws)
            let windowIDs = workspaceManager.windowIDs(onWorkspace: ws)
            return [
                "id": ws,
                "monitor": home?.localizedName ?? "",
                "monitorIndex": home.flatMap { h in ordered.firstIndex(of: h).map { $0 + 1 } } ?? -1,
                "visible": workspaceManager.isWorkspaceVisible(ws),
                "focused": ws == focused,
                "windows": windowIDs.count,
                "color": config.workspaceColors[String(ws)].map { "#\($0)" } ?? "",
                "sticky": workspaceManager.stickyWorkspaces.contains(ws),
            ]
        }
    }

    private func windowsPayload(_ ws: Int) -> [[String: Any]] {
        workspaceManager.windowIDs(onWorkspace: ws).sorted().compactMap { wid in
            guard let pid = stateCache.windowOwners[wid],
                  let app = NSRunningApplication(processIdentifier: pid) else { return nil }
            return [
                "id": Int(wid),
                "app": app.localizedName ?? "",
                "bundleID": app.bundleIdentifier ?? "",
                "title": stateCache.cachedWindows[wid]?.title ?? "",
                "hidden": stateCache.hiddenWindowIDs.contains(wid),
                "sticky": workspaceManager.isStickyWindow(wid),
            ]
        }
    }

    private func json(_ obj: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
              let s = String(data: data, encoding: .utf8) else { return "{\"error\":\"encoding\"}" }
        return s + "\n"
    }

    // MARK: - events

    private func broadcast(_ line: String) {
        ioQueue.async { [weak self] in
            guard let self, !self.eventClients.isEmpty else { return }
            let payload = line + "\n"
            var dead: [Int32] = []
            for fd in self.eventClients {
                let sent = payload.withCString { write(fd, $0, strlen($0)) }
                if sent < 0 { dead.append(fd) }
            }
            for fd in dead {
                close(fd)
                self.eventClients.remove(fd)
            }
        }
    }
}

extension Notification.Name {
    /// Posted after a discovery pass changed the window set (open, close,
    /// hide, return, drift). IPC relays it as `windowschanged>>`.
    static let hyprMacWindowsChanged = Notification.Name("hyprMacWindowsChanged")
}
