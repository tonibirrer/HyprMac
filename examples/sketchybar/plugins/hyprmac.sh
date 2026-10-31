#!/bin/bash
# Repaint every workspace item from HyprMac's state.json: the focused
# highlight (the workspace's accent color when set, Settings → Layout →
# Workspaces), the app-icon strip (via icon_map.sh) and visibility.
# Non-empty and focused workspaces show; empty unfocused ones hide.
# Fired on hyprmac_change, which plugins/hyprmac_hook.sh triggers.

STATE="$HOME/Library/Application Support/HyprMacExperiments/state.json"
ICON_MAP="$HOME/.config/sketchybar/icon_map.sh"
DEFAULT_FOCUSED=0x88FF00FF
UNFOCUSED=0x44FFFFFF

# HyprMac removes the file when it quits or pauses tiling
if [ ! -s "$STATE" ]; then
  sketchybar --set '/space\.[0-9][0-9]*/' drawing=off
  exit 0
fi

FOCUSED=$(jq -r '.focusedWorkspace // empty' "$STATE")
args=()
# one line per workspace: id, accent color, its apps joined by "|". the
# fields are split on \x1f: tab is whitespace to `read`, so an empty color
# between two tabs would collapse and shift the apps into its place
while IFS=$'\x1f' read -r sid color apps; do
  if [ "$sid" = "$FOCUSED" ]; then
    bg="$DEFAULT_FOCUSED"
    [ -n "$color" ] && bg="0xCC${color#\#}"
    args+=(--set "space.$sid" background.color="$bg" background.border_width=2)
  else
    args+=(--set "space.$sid" background.color="$UNFOCUSED" background.border_width=0)
  fi

  if [ -n "$apps" ]; then
    icon_strip=" "
    IFS='|' read -ra names <<<"$apps"
    for app in "${names[@]}"; do
      [ -n "$app" ] && icon_strip+=" $("$ICON_MAP" "$app")"
    done
    args+=(--set "space.$sid" drawing=on label="$icon_strip")
  elif [ "$sid" = "$FOCUSED" ]; then
    args+=(--set "space.$sid" drawing=on label=" ")
  else
    args+=(--set "space.$sid" drawing=off label="")
  fi
done < <(jq -r '.workspaces[] | [(.id | tostring), (.color // ""), ([.windows[].app] | unique | join("|"))] | join("\u001f")' "$STATE")

sketchybar "${args[@]}"
