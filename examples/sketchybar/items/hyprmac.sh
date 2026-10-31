#!/bin/bash
# HyprMac workspaces for sketchybar — drop-in replacement for the popular
# aerospace integration, driven by HyprMac's status export: state.json
# written on every change, a hook that triggers hyprmac_change, and
# hyprmac-experiments:// links for clicks (workspace indicators,
# per-workspace app icons, click to switch, per-workspace accent colors).
#
# Requires: jq, and plugins/hyprmac.sh + plugins/hyprmac_hook.sh next to
# your other sketchybar plugins. See README.md for the monitor-config.json
# keys that turn the export on.

sketchybar --add event hyprmac_change

# HyprMac has a fixed set of workspaces, so the items do not depend on
# HyprMac running: sketchybar usually loads first at login. They start
# hidden; plugins/hyprmac.sh paints them from state.json.
WORKSPACE_COUNT=10

for sid in $(seq 1 "$WORKSPACE_COUNT"); do
  sketchybar --add item space.$sid left \
    --set space.$sid \
    drawing=off \
    background.color=0x44ffffff \
    background.corner_radius=10 \
    background.drawing=on \
    background.border_color=0xAAFFFFFF \
    background.border_width=0 \
    background.height=25 \
    icon="$sid" \
    icon.padding_left=10 \
    label.font="sketchybar-app-font:Regular:16.0" \
    label.padding_right=20 \
    label.padding_left=0 \
    label.y_offset=-1 \
    click_script="open -g 'hyprmac-experiments://workspace?n=$sid'"
done

# one script repaints every workspace item from state.json, so a change
# reads the file once
sketchybar --add item space_separator left \
  --set space_separator icon="􀆊" \
  icon.font="$FONT:Heavy:16.0" \
  icon.padding_left=4 \
  padding_left=10 \
  padding_right=15 \
  label.drawing=off \
  background.drawing=off \
  script="$PLUGIN_DIR/hyprmac.sh" \
  --subscribe space_separator hyprmac_change

# HyprMac may already be running (a sketchybar reload): paint from the
# state file it last wrote
sketchybar --trigger hyprmac_change
