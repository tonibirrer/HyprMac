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

# relay daemon: streams HyprMac IPC events into the sketchybar triggers.
# restart it on every sketchybar reload so exactly one instance runs.
pkill -f "plugins/hyprmac_listener.sh" 2>/dev/null
nohup "$PLUGIN_DIR/hyprmac_listener.sh" >/dev/null 2>&1 &

WORKSPACES_JSON=$(hyprmacctl workspaces 2>/dev/null || echo '[]')

for sid in $(echo "$WORKSPACES_JSON" | jq -r '.[].id'); do
  ws=$(echo "$WORKSPACES_JSON" | jq -r ".[] | select(.id == $sid)")
  windows=$(echo "$ws" | jq -r '.windows')
  focused=$(echo "$ws" | jq -r '.focused')

  drawing=off
  if [ "$windows" -gt 0 ] || [ "$focused" = "true" ]; then drawing=on; fi

  sketchybar --add item space.$sid left \
    --subscribe space.$sid hyprmac_workspace_change \
    --set space.$sid \
    drawing=$drawing \
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

# initial paint: highlight + app icon strips
"$PLUGIN_DIR/hyprmac_windows.sh" &
