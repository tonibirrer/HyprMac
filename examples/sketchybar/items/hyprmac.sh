#!/bin/bash
# HyprMac workspaces for sketchybar — drop-in replacement for the popular
# aerospace integration, driven by HyprMac's Hyprland-style IPC via
# `hyprmacctl` (workspace indicators, per-workspace app icons, click to
# switch, per-workspace accent colors).
#
# Requires: hyprmacctl on PATH, jq, and the hyprmac_* plugins next to
# your other sketchybar plugins.

sketchybar --add event hyprmac_workspace_change
sketchybar --add event hyprmac_update_windows

# HyprMac has a fixed set of workspaces, so the items do not depend on
# HyprMac running: sketchybar usually loads first at login. They start
# hidden; the listener paints them once it reaches HyprMac.
WORKSPACE_COUNT=10

for sid in $(seq 1 "$WORKSPACE_COUNT"); do
  sketchybar --add item space.$sid left \
    --subscribe space.$sid hyprmac_workspace_change \
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
    click_script="hyprmacctl dispatch workspace $sid" \
    script="$PLUGIN_DIR/hyprmac.sh $sid"
done

sketchybar --add item space_separator left \
  --set space_separator icon="􀆊" \
  icon.font="$FONT:Heavy:16.0" \
  icon.padding_left=4 \
  padding_left=10 \
  padding_right=15 \
  label.drawing=off \
  background.drawing=off \
  script="$PLUGIN_DIR/hyprmac_windows.sh" \
  --subscribe space_separator hyprmac_update_windows \
  --subscribe space_separator hyprmac_workspace_change

# relay daemon: streams HyprMac IPC events into the sketchybar triggers
# and paints the items above. started last, so they exist by then.
# restart it on every sketchybar reload so exactly one instance runs.
# pkill -f is async (returns before the target actually exits), so wait for
# it to actually die before spawning the replacement -- otherwise a fast
# reload can leave two listeners racing on the same socket.
pkill -f "plugins/hyprmac_listener.sh" 2>/dev/null
for i in $(seq 1 20); do
  pgrep -f "plugins/hyprmac_listener.sh" >/dev/null || break
  sleep 0.1
done
pkill -9 -f "plugins/hyprmac_listener.sh" 2>/dev/null
nohup "$PLUGIN_DIR/hyprmac_listener.sh" >/dev/null 2>&1 &
