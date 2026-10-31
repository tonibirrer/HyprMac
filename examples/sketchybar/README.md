# sketchybar integration

Workspace indicators with per-workspace app icons for [sketchybar](https://github.com/FelixKratz/SketchyBar), driven by HyprMac's status export. A drop-in replacement for the common AeroSpace setup: same look, but clickable (click an indicator to switch) and color-matched to each workspace's accent color from Settings → Layout → Workspaces.

## How it works

- HyprMac writes `~/Library/Application Support/HyprMacExperiments/state.json` on every change a bar shows, then runs the hook command (upstream's status export, `docs/status-bar.md`). The fork adds each workspace's accent `color` to the file and lists native-fullscreen windows on their workspace.
- `plugins/hyprmac_hook.sh` is that hook. It puts Homebrew on `PATH` (HyprMac runs hooks without a shell profile) and triggers `hyprmac_change`.
- `items/hyprmac.sh` creates one item for each of the ten workspaces, whether or not HyprMac is running yet. sketchybar usually loads first at login, so the items start hidden. A click opens `hyprmac-experiments://workspace?n=N`: the fork's own link scheme, so the link never reaches a stock HyprMac installed beside it.
- `plugins/hyprmac.sh` repaints every item from `state.json` on `hyprmac_change`: the focused highlight (accent color when set), the app-icon strip via your existing `icon_map.sh`, and visibility. When HyprMac quits or pauses tiling it removes the file and runs the hook once more, and the items hide until it is back.

## Install

```sh
cp examples/sketchybar/items/hyprmac.sh ~/.config/sketchybar/items/
cp examples/sketchybar/plugins/hyprmac{,_hook}.sh ~/.config/sketchybar/plugins/
```

Turn the export on in `~/Library/Application Support/HyprMacExperiments/monitor-config.json`. Quit HyprMac first: it reads this file at launch and writes its own copy over it on the next settings change. Add the two keys to the object already there and keep the others:

```json
{
  "statusExportEnabled": true,
  "statusHookCommand": "~/.config/sketchybar/plugins/hyprmac_hook.sh"
}
```

Then in `~/.config/sketchybar/sketchybarrc`, replace `source "$ITEM_DIR/aerospace.sh"` with `source "$ITEM_DIR/hyprmac.sh"`, `sketchybar --reload`, and start HyprMac. Requires `jq` and a `sketchybar-app-font` `icon_map.sh` (the standard AeroSpace-setup one works unchanged).

Reserve space for the bar per monitor with Settings → Layout → Per-Monitor Settings → Edge padding → Top.

Upgrading from the `hyprmacctl` version: delete `plugins/hyprmac_listener.sh` and `plugins/hyprmac_windows.sh` from `~/.config/sketchybar/plugins/`, and the `hyprmacctl` link from your `PATH`. The fork no longer opens the IPC sockets.
