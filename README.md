# HyprMac

> [!WARNING]
> **This is an experimental fork** ([upstream: zacharytgray/HyprMac](https://github.com/zacharytgray/HyprMac)) used to try out some opinionated ideas — starting with Hyprland-style window rules. It builds as **HyprMacExperiments** with its own bundle ID so it can run alongside a regular HyprMac install, auto-updates are disabled, and there is no stability promise: features may change or disappear without notice.

A keyboard-driven tiling window manager for macOS.

Caps Lock becomes a **Hypr** modifier key by default, and the physical Hypr key can be changed in Settings. From there: BSP dwindle tiling, 9 virtual workspaces, directional focus and window swapping, drag-to-swap, and focus-follows-mouse — all without touching System Integrity Protection.

[![HyprMac demo](docs/screenshots/demo-thumb.png)](https://github.com/user-attachments/assets/1f6f12ff-8e89-49ab-8be9-f2996025763a)

> HyprMac is in active development. Contributions and bug reports are welcome.

---

## What It Solves

macOS doesn't ship with a tiling window manager. Third-party options either require disabling SIP, rely on AppleScript hacks, or bolt tiling on top of macOS Spaces in ways that feel fragile. HyprMac takes a different approach: it manages its own virtual workspaces in userspace, uses Accessibility APIs only, and provides a dedicated Hypr modifier for a clean, Hyprland-style workflow that works within macOS's constraints.

---

## Features

| | |
|---|---|
| 🪟 **BSP Dwindle Tiling** | Smart insertion with min-size adaptation and automatic split ratio adjustment |
| 🗂 **9 Virtual Workspaces** | Managed in userspace — no macOS Spaces dependency, no SIP needed |
| 🎯 **Directional Focus & Swap** | Move focus or swap windows left/right/up/down across monitors |
| 🖱 **Focus-Follows-Mouse** | Toggleable, with automatic suppression when menus are open |
| 🔄 **Drag-to-Swap** | Drag any window onto another to exchange positions |
| 🔲 **Floating Toggle** | Pop windows in and out of the tiling layout on demand |
| 📌 **Window Rules** *(fork)* | Pin apps to workspaces by bundle ID, Hyprland-style |
| 🔌 **IPC + sketchybar** *(fork)* | Hyprland-style event socket + `hyprmacctl`, clickable workspace indicators |
| 🎨 **Workspace Identity** *(fork)* | Per-workspace accent colors and wallpapers |
| 📐 **Per-Side Padding** *(fork)* | Top-only outer padding to reserve space for a status bar |
| 🖥 **Multi-Monitor** | Per-monitor workspace assignment with directional cross-monitor navigation |
| ⌨️ **Fully Configurable** | Edit the Hypr key, keybinds, app launchers, gaps, and padding in-app or via JSON |
| 📋 **Keybind Overlay** | `Hypr+K` shows all active shortcuts at a glance |

---

## Requirements

- macOS 13 (Ventura) or later
- Accessibility permission — System Settings → Privacy & Security → Accessibility
- For the default Caps Lock Hypr key: Caps Lock set to **"⇪ Caps Lock"** in Modifier Keys (not "No Action")

---

## Installation

### Homebrew (recommended)

```sh
brew tap zacharytgray/hyprmac
brew install --cask hyprmac
```

### Manual Download

Download the latest DMG from [GitHub Releases](https://github.com/zacharytgray/HyprMac/releases), open it, and drag HyprMac to Applications.

### Build from Source

```sh
git clone https://github.com/zacharytgray/HyprMac.git
cd HyprMac

brew install xcodegen
xcodegen generate

export DEVELOPMENT_TEAM=YOUR_TEAM_ID
xcodebuild -project HyprMac.xcodeproj -scheme HyprMac -configuration Debug \
  -derivedDataPath build DEVELOPMENT_TEAM=$DEVELOPMENT_TEAM build

cp -r build/Build/Products/Debug/HyprMac.app /Applications/
```

---

## Keybinds

All keybinds are configurable in Settings (menubar icon → Settings → Keybinds).
The physical Hypr key is configurable in Settings → General. Options include Caps Lock, Tab, backtick, backslash, F13-F20, and left/right variants of Shift, Control, Option, and Command.

### Defaults

| Shortcut | Action |
|----------|--------|
| `⇪ + ←/→/↑/↓` | Focus window in direction |
| `⇪ + ⇧ + ←/→/↑/↓` | Swap window in direction |
| `⇪ + J` | Toggle split direction |
| `⇪ + ⇧ + T` | Toggle floating/tiling |
| `⇪ + F` | Cycle focus through floating windows |
| `⇪ + 1–9` | Switch to workspace N |
| `⇪ + ⇧ + 1–9` | Move window to workspace N |
| `⇪ + ⌃ + ←/→` | Move window to adjacent monitor |
| `⇪ + ⇥` / `⇪ + ⇧ + ⇥` | Cycle occupied workspaces on current monitor |
| `⇪ + W` | Close window |
| `⇪ + K` | Show keybind overlay |
| `⇪ + ↵` | Launch/focus Terminal |
| `⇪ + \`` | Warp cursor to menu bar |

### Mouse

| Action | Effect |
|--------|--------|
| Hover over tiled window | Focus follows mouse (when enabled) |
| Drag window onto another | Swap positions |

---

## Menu Bar Access

Focus-follows-mouse and the macOS menu bar don't always play nicely together — mousing up to the menu bar can accidentally shift focus to a window underneath. HyprMac handles this two ways:

1. **Menu tracking detection** — FFM is automatically suppressed while any app's menu is open, so focus won't shift once you've clicked a menu item.
2. **`Hypr + \``** — Instantly warps the cursor to the menu bar on the current monitor. It's faster than mousing there manually and sidesteps the focus-switching problem entirely. The action, shortcut, and physical Hypr key are configurable in Settings.

---

## Virtual Workspaces

HyprMac manages 9 workspaces entirely in userspace, bypassing macOS Spaces.

- Every workspace is **statically anchored** to a monitor: `(N − 1) mod monitorCount`, left to right. With 3 monitors, workspaces 1/4/7 live on the left, 2/5/8 in the middle, 3/6/9 on the right
- Switching to workspace N always lands on its home monitor — workspace identity never drifts between monitors
- Switching to a workspace that's already visible just focuses its monitor
- `⇪ + ⌃ + ←/→` throws the focused window to the adjacent monitor's visible workspace
- Inactive windows are hidden off-screen (a macOS constraint — one pixel remains visible in a corner)
- Monitor connects/disconnects preserve workspace assignments; layouts migrate to each workspace's current home

A single macOS Space per monitor is recommended for the cleanest experience.

---

## Window Rules *(fork feature)*

Hyprland-style app → workspace pins, modeled on `windowrule = workspace N, class:...`. When an app with a rule opens a new window, the window is placed on its pinned workspace instead of the active one — and by default the workspace is switched to, so e.g. opening your terminal takes you straight to its workspace. Set `silent` to move the window without switching (Hyprland's `workspace N silent`).

Configure in **Settings → Layout → Window Rules** (app picker, workspace 1–9, per-rule "Follow" checkbox), or directly in `~/Library/Application Support/HyprMac/config.json`:

```json
"windowRules": [
  { "bundleID": "com.mitchellh.ghostty", "workspace": 2 },
  { "bundleID": "dev.zed.Zed",           "workspace": 2 },
  { "bundleID": "md.obsidian",           "workspace": 3, "silent": true }
]
```

Find an app's bundle ID with `mdls -name kMDItemCFBundleIdentifier -r /Applications/App.app`.

Semantics:

- Rules are evaluated **once per window**, when it is first discovered; first match wins. Un-minimizing or switching workspaces never re-triggers a rule, but apps that recycle their window on reopen (Teams-style) are re-pinned correctly.
- On HyprMac startup and **Retile All**, existing windows of ruled apps are sorted onto their pinned workspaces *silently* — no workspace-switch storm at launch.
- A full target workspace falls back to normal placement instead of rejecting the window.
- "Never tile" (excluded) apps always float and are ignored by rules.
- Since workspaces are statically anchored to monitors, a rule also decides which monitor the app lands on — e.g. with two monitors, odd workspaces pin to the left screen and even to the right.

---

## IPC & sketchybar *(fork feature)*

HyprMac exposes its state the way Hyprland does — over unix sockets, not callbacks. `hyprmac.sock` answers queries; `hyprmac.events.sock` streams events to whoever connects (Hyprland's `.socket` / `.socket2` split). `scripts/hyprmacctl` wraps both:

```sh
hyprmacctl workspaces              # JSON: id, monitor, visible, focused, windows, color
hyprmacctl windows 2               # JSON: app, bundleID, title per window
hyprmacctl focused                 # JSON: focused workspace
hyprmacctl dispatch workspace 3    # switch workspace (clickable indicators)
hyprmacctl subscribe               # stream: workspace>>FOCUSED>>PREV / windowschanged>>
```

[`examples/sketchybar/`](examples/sketchybar/) has a ready-made integration: workspace indicators with per-workspace app icons (AeroSpace-setup parity), clickable to switch, highlighted in each workspace's accent color.

## Workspace Colors & Wallpapers *(fork feature)*

Settings → Layout → Workspaces assigns each workspace an accent color and a wallpaper. The color tints the focus border while that workspace is focused and is served over IPC for status bars; the wallpaper swaps in per monitor the instant the workspace is shown (Hyprland needs hyprpaper + an IPC script for this — macOS lets HyprMac do it natively via `NSWorkspace.setDesktopImageURL`).

Picking a wallpaper auto-derives the workspace's accent color from the image — the dominant hue, lifted into a vivid border-ready tone. Near-monochrome images keep the current color, and the guess can always be overridden with the color picker.

Per-side outer padding lives in Settings → Layout → Gaps → "Per-side overrides" — e.g. top = 40 reserves space for sketchybar while the other sides keep the uniform padding (`"outerPaddingSides": {"top": 40}` in `config.json`).

---

## Architecture

HyprMac is structured as a thin orchestration layer over a handful of focused services. Hotkeys feed into an `ActionDispatcher` that routes work to the right service; a polling loop drives a `WindowDiscoveryService` that detects new, gone, and drifted windows and hands the diff back to the dispatcher.

```
HotkeyManager (CGEventTap)
    └→ WindowManager.handleAction
        └→ ActionDispatcher.dispatch
            ├→ FocusStateController       (focus id + visual border)
            ├→ WorkspaceOrchestrator      (workspace switch / move)
            ├→ FloatingWindowController   (toggle / cycle / raise)
            ├→ TilingEngine               (swap / split toggle / retile)
            └→ AppLauncherManager         (launch / focus)
                ↓
        WindowStateCache mutations
                ↓
        TilingEngine.applyLayout (two-pass via FrameReadbackPoller)
                ↓
        FocusBorder, FocusBrackets, DimmingOverlay (visual layer)
```

Polling and discovery run in parallel:

```
PollingScheduler (1 Hz timer + coalesced notification triggers)
    └→ WindowDiscoveryService.computeChanges
        └→ ActionDispatcher.applyChanges
```

Window-keyed state lives in `WindowStateCache`; focus state in `FocusStateController`; date-gated suppressions (`activation-switch`, `mouse-focus`, `cross-swap-in-flight`) in `SuppressionRegistry`. BSP trees live in `TilingEngine` (one per `(workspace, screen)` pair) with smart insert backtracking on constrained monitors and two-pass min-size resolution via `FrameReadbackPoller`.

Everything runs on the main thread. UI-touching classes (`FocusBorder`, `DimmingOverlay`, `KeybindOverlayController`, `CursorManager`, `MouseTrackingManager`) assert this in DEBUG via `mainThreadOnly()`.

For deeper reading:

- [`docs/architecture.md`](docs/architecture.md) — long-form architecture, ownership rules, threading.
- [`docs/tiling-algorithm.md`](docs/tiling-algorithm.md) — BSP dwindle, smart insert, two-pass layout, min-size memory.
- [`docs/coordinate-systems.md`](docs/coordinate-systems.md) — CG ↔ NS conversion, multi-monitor edge cases.
- [`docs/keybinds-and-actions.md`](docs/keybinds-and-actions.md) — `Action` enum, frozen JSON case keys, schema versioning.
- [`docs/debugging.md`](docs/debugging.md) — Console.app filters, verbose-logging toggle, common debugging recipes.
- [`CLAUDE.md`](CLAUDE.md) — build/run, code style, key technical decisions.

---

## Updating

> [!NOTE]
> In this fork the Sparkle update feed is removed — it never auto-updates. Build from source to update. The rest of this section describes upstream HyprMac.

**In-app updates are recommended for most users.** HyprMac checks for updates automatically via Sparkle — when one is available, you'll be prompted to install it directly from the app. You can also check manually via the menubar icon → "Check for Updates..."

For Homebrew installs, `brew upgrade --cask hyprmac` works as well. Or download the latest DMG from [GitHub Releases](https://github.com/zacharytgray/HyprMac/releases) and replace the app manually.

> After any update method, macOS may ask you to re-grant Accessibility permission in System Settings, since the binary signature changes with each release.

---

## Inspired By

- [Hyprland](https://hyprland.org) — Wayland compositor, the primary inspiration for this project
- [yabai](https://github.com/koekeishiya/yabai) — macOS tiling WM
- [AeroSpace](https://github.com/nikitabobko/AeroSpace) — Swift macOS tiling WM with virtual workspaces
- [Amethyst](https://github.com/ianyh/Amethyst) — macOS tiling WM
- [skhd](https://github.com/koekeishiya/skhd) — Hotkey daemon

---

## License

MIT
