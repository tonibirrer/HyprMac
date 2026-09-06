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
| 📌 **Window Rules** *(fork)* | Pin apps to workspaces and fix their tile sort order by bundle ID, Hyprland-style |
| 🧷 **Sticky Apps** *(fork)* | Hyprland's `pin`, extended to tiles: chosen apps follow you across the workspaces that opt in |
| 🏛 **Full-Height Apps** *(fork)* | Per-app guarantee of a full-height column in the dwindle layout, master-layout style |
| 🔗 **Linked Monitors** *(fork)* | Toggle: all monitors show one workspace, tiles load-balanced across screens by size |
| 🪗 **Accordion Mode** *(fork)* | AeroSpace-style stacked layout when only the chosen screen (default: built-in) is connected, with configurable side peek; the tiled layout is kept in the background and restored when monitors return |
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

Hyprland-style per-app rules, modeled on `windowrule = <effect>, class:...`. Each rule is keyed by bundle ID and can apply two effects, independently or together:

- **Workspace pin** — when the app opens a new window, it is placed on its pinned workspace instead of the active one, and by default the workspace is switched to, so e.g. opening your terminal takes you straight to its workspace. Set `silent` to move the window without switching (Hyprland's `workspace N silent`).
- **Sort priority** — keeps the app's tiles at a fixed end of the dwindle order: higher priority tiles further **top-left**, lower further **bottom-right**, 0 (default) leaves the window in plain insertion order. So `"sortPriority": -1` on Mattermost means it always ends up in the rightmost tile, no matter which order your apps opened in. (Hyprland has no native equivalent — the request was [declined upstream](https://github.com/hyprwm/Hyprland/issues/5388) — but per-class window rules are the idiomatic place for it.)
- **Focus on activate** (`"focusOnActivate": true`, the UI's "Activate") — Hyprland's `focus_on_activate` / `windowrule = activate`, per app: always honor the app's activation requests and switch to its workspace even without a click or keystroke. By default, activations of apps with no visible window are honored only when a user gesture (recent click, recent ⌘ keystroke, or a launcher as the previous app) proves intent — a terminal self-raising when a background job prints must not yank the workspace. Set this on your browser so a URL opened from another app (an SSO login from the terminal, e.g.) still takes you there.

- **Sticky** (`"sticky": true`) — Hyprland's `windowrule = pin` ("show it on all workspaces"), per app. The app's windows follow you across every workspace that opts in; see [Sticky Apps](#sticky-apps-fork-feature) below.
- **Full height** (`"fullHeight": true`) — the app's tiles always span the full tiled height. Hyprland's dwindle has no per-window equivalent (its `split_width_multiplier` and `preserve_split` are global); the semantics come from Hyprland's **master layout**, where a master window is a full-height column and slaves stack beside it. See [Full-Height Apps](#full-height-apps-fork-feature).

Configure in **Settings → Layout → Window Rules** (app picker, workspace 1–9 or "—" for no pin, per-rule "Follow" / "Activate" / "Sticky" checkboxes, sort stepper), or directly in `~/Library/Application Support/HyprMac/config.json`:

```json
"windowRules": [
  { "bundleID": "com.mitchellh.ghostty",    "workspace": 2 },
  { "bundleID": "dev.zed.Zed",              "workspace": 2, "sortPriority": 1 },
  { "bundleID": "md.obsidian",              "workspace": 3, "silent": true },
  { "bundleID": "Mattermost.Desktop",       "workspace": 0, "sortPriority": -1, "sticky": true, "fullHeight": true },
  { "bundleID": "app.zen-browser.zen",      "workspace": 0, "sticky": true, "fullHeight": true }
],
"stickyWorkspaces": [1, 2, 3]
```

Find an app's bundle ID with `mdls -name kMDItemCFBundleIdentifier -r /Applications/App.app`.

Semantics:

- Workspace pins are evaluated **once per window**, when it is first discovered; first match wins. Un-minimizing or switching workspaces never re-triggers a rule, but apps that recycle their window on reopen (Teams-style) are re-pinned correctly.
- On HyprMac startup and **Retile All**, existing windows of ruled apps are sorted onto their pinned workspaces *silently* — no workspace-switch storm at launch.
- A full target workspace falls back to normal placement instead of rejecting the window.
- "Never tile" (excluded) apps always float and are ignored by rules.
- Since workspaces are statically anchored to monitors, a rule also decides which monitor the app lands on — e.g. with two monitors, odd workspaces pin to the left screen and even to the right.
- Sort priority, by contrast, is enforced on **every membership change** (a window opens or is discovered) and immediately when you edit a rule. It reorders only which window sits in which tile — tree shape and split ratios stay put. Equal-priority windows keep their relative order, so manual swaps between unruled windows survive; a swap that violates a priority is undone the next time a window opens.
- `"workspace": 0` (the UI's "—") means no pin — the rule only carries a sort priority.

---

## Sticky Apps *(fork feature)*

Hyprland's `pin` (`windowrule = pin` / the `pin` dispatcher) shows a window "on all workspaces" — but only floating windows, and always on every workspace of the monitor. HyprMac adapts the idea in two ways: sticky works for **tiled** windows too, and **workspaces opt in** individually, so a chat client and a browser can ride along on your working workspaces while a presentation or focus workspace stays clean.

- Mark the app **Sticky** in Settings → Layout → Window Rules (`"sticky": true`; no workspace pin needed).
- Tick **Sticky** on each workspace that should show sticky apps in Settings → Layout → Workspaces (`"stickyWorkspaces": [1, 2, 3]`). Nothing happens until at least one workspace opts in.

Semantics:

- A sticky window is a member of exactly one workspace at a time and is **carried** into the workspace being shown on its monitor, if that workspace opts in. The carried tile is removed from the workspace it leaves and inserted into the new one's layout — sort priority applies, so `"sortPriority": -1` keeps Mattermost in the rightmost tile everywhere. Its former slot on the old workspace collapses; when you come back, the tile is re-inserted.
- Switching to a workspace that does **not** opt in hides sticky windows like any other window. The next switch to an opted-in workspace on that monitor brings them back.
- Sticky windows stay on their monitor: workspaces are statically anchored, and a sticky window on the left screen's workspaces never jumps to the right screen. With linked monitors the workspace spans all screens and the balancer decides which screen the tile lands on.
- Explicit moves still work — `Hypr+Shift+N` sends a sticky window to workspace N (even a non-opt-in one) and it stays there until an opt-in workspace is shown on that monitor.
- Floating sticky windows keep their frame and simply stay put across switches (Hyprland's exact behavior).
- Capacity is respected: if the target workspace is already at its dwindle depth, the sticky tile stays behind (hidden) rather than being auto-floated.
- Editing a rule or the opt-in list, "Retile All", startup, and monitor changes all run a reconcile that carries sticky windows onto the currently visible opted-in workspaces.
- After a switch, focus goes to the workspace's own windows first — the sticky app was already in front of you.
- IPC: `hyprmacctl workspaces` reports `"sticky": true` for opted-in workspaces and `hyprmacctl windows <ws>` marks sticky windows, so status bars can render them differently.

---

## Full-Height Apps *(fork feature)*

Dwindle's spiral alternates split axes, so the second window on a wide screen gets cut in half the moment a third one opens. For a browser or a chat client you usually want a column that keeps its full height no matter what opens next. Hyprland's dwindle has nothing per window for this; its master layout does (the master area is a full-height column, `orientation = left`, slaves stacked beside it), and so does its scrolling layout (every window is a column). HyprMac takes the master semantics and makes them a per-app window rule: **Full height** in Settings → Layout → Window Rules, or `"fullHeight": true`.

How it works inside the BSP tree:

- A full-height tile only ever splits **left | right**. A new window opening "into" it lands beside it, never below it.
- Every split above a full-height tile is **column-locked**: it always divides left | right, whatever the aspect ratio says and whatever `togglesplit` asks for. So with Zen and Mattermost both full height, three windows give three columns; a fourth stacks under the third, never under Zen or Mattermost.
- A full-height window that opens into an existing layout prefers a slot that is already a column (shallowest first) so it does not pry open someone else's stack.
- The lock follows the window, not the slot: close or swap the window away and the column is released on the same pass, and dwindle stacking resumes there.
- Column widths follow the usual split ratios (50 % for the first column, 25 % for the next, and so on); drag-resize a boundary to change them, the resize sticks like any other.
- Combine with a **sort priority** so the column stays at a screen edge; without one, a full-height window still gets a column, just wherever it opened.
- Depth still applies: the max-splits cap is unchanged, and if a full-height column would push the layout past it the window auto-floats like any other overflow.

---

## Linked Monitors *(fork feature)*

Hyprland (like HyprMac's default) binds each workspace to one monitor and [declined](https://github.com/hyprwm/Hyprland/issues/747) a spanning mode — this toggle is a fork experiment. **Settings → Layout → Per-Monitor Settings → Link monitors** (shown with 2+ screens; machine-local, never iCloud-synced):

- All enabled monitors show the **same workspace**; switching workspaces flips every screen at once, and `Hypr+1…9` gives nine spanning workspaces.
- A tile always lives wholly on one screen — nothing ever straddles the border. The workspace's tiles form one left-to-right strip cut into per-screen chunks: with two equal screens, 1 window → screen 1; 2 → one each; 3 → 2+1; 4 → 2+2. Unequal screens (say an ultrawide next to a 4:3) balance proportionally to usable area, capped by each screen's max-splits depth.
- App sort priorities span the whole strip: highest priority = leftmost tile of the leftmost screen, lowest = rightmost tile of the rightmost screen.
- Each screen keeps its own BSP tree, so gaps, padding, per-monitor max splits, resizes, and toggled splits all behave exactly as unlinked.
- Toggling runs the same reconcile as a monitor connect/disconnect: workspaces remap, trees migrate, hidden windows re-park. Unlinking restores static anchoring.

Known v1 limits: cross-screen **drag**-swap works, but keyboard swap stays within one screen; "move window to monitor" is a no-op while linked (the balancer owns which screen a tile lands on); capacity checks for workspace pins consider only the leftmost screen.

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
