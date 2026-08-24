#!/bin/bash
# Refresh every workspace item: app-icon strip (via icon_map.sh) and
# visibility. Non-empty and focused workspaces show; empty unfocused
# ones hide. Fired on hyprmac_update_windows and hyprmac_workspace_change.

ICON_MAP="$HOME/.config/sketchybar/icon_map.sh"

WORKSPACES_JSON=$(hyprmacctl workspaces 2>/dev/null) || exit 0
FOCUSED=$(echo "$WORKSPACES_JSON" | jq -r '.[] | select(.focused).id')

for sid in $(echo "$WORKSPACES_JSON" | jq -r '.[].id'); do
  windows=$(echo "$WORKSPACES_JSON" | jq -r ".[] | select(.id == $sid).windows")

  if [ "$windows" -gt 0 ]; then
    apps=$(hyprmacctl windows "$sid" 2>/dev/null | jq -r '.[].app' | sort -u)
    icon_strip=" "
    while IFS= read -r app; do
      [ -n "$app" ] && icon_strip+=" $("$ICON_MAP" "$app")"
    done <<<"$apps"
    sketchybar --set space.$sid drawing=on label="$icon_strip"
  elif [ "$sid" = "$FOCUSED" ]; then
    sketchybar --set space.$sid drawing=on label=" "
  else
    sketchybar --set space.$sid drawing=off label=""
  fi
done
