# sketchybar integration

Workspace indicators with per-workspace app icons for [sketchybar](https://github.com/FelixKratz/SketchyBar), driven by HyprMac's Hyprland-style IPC. A drop-in replacement for the common AeroSpace setup: same look, but clickable (click an indicator to switch) and color-matched to each workspace's accent color from Settings → Layout → Workspaces.

## How it works

- `scripts/hyprmacctl` (repo root) talks to HyprMac's two unix sockets — `hyprmac.sock` for JSON queries (`workspaces`, `windows <ws>`, `focused`, `dispatch workspace <ws>`) and `hyprmac.events.sock` for the event stream (`workspace>>FOCUSED>>PREV`, `windowschanged>>`). This mirrors Hyprland's `hyprctl` + `socat`-on-socket2 pattern.
- `plugins/hyprmac_listener.sh` streams those events into sketchybar triggers (`hyprmac_workspace_change`, `hyprmac_update_windows`). It is started by the item script and reconnects if HyprMac restarts.
- `items/hyprmac.sh` creates one item per workspace; `plugins/hyprmac.sh` handles the focused highlight (workspace accent color when set); `plugins/hyprmac_windows.sh` renders the app-icon strips via your existing `icon_map.sh`.

## Install

```sh
ln -s "$(pwd)/scripts/hyprmacctl" /opt/homebrew/bin/hyprmacctl
cp examples/sketchybar/items/hyprmac.sh ~/.config/sketchybar/items/
cp examples/sketchybar/plugins/hyprmac{,_windows,_listener}.sh ~/.config/sketchybar/plugins/
```

Then in `~/.config/sketchybar/sketchybarrc`, replace `source "$ITEM_DIR/aerospace.sh"` with `source "$ITEM_DIR/hyprmac.sh"` and `sketchybar --reload`. Requires `jq` and a `sketchybar-app-font` `icon_map.sh` (the standard AeroSpace-setup one works unchanged).

Reserve space for the bar with Settings → Layout → Gaps → Per-side overrides → Top (or `"outerPaddingSides": {"top": 40}` in `config.json`).
