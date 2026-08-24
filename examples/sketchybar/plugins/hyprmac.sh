#!/bin/bash
# Per-workspace-item script: highlight the focused workspace, using its
# HyprMac accent color when one is set (Settings → Layout → Workspaces).
# $1 = workspace id; fired on hyprmac_workspace_change.

SID="$1"
DEFAULT_FOCUSED=0x88FF00FF
UNFOCUSED=0x44FFFFFF

if [ "$SENDER" = "hyprmac_workspace_change" ]; then
  CURRENT="$FOCUSED_WORKSPACE"
else
  CURRENT=$(hyprmacctl focused 2>/dev/null | jq -r '.workspace')
fi

if [ "$SID" = "$CURRENT" ]; then
  color=$(hyprmacctl workspaces 2>/dev/null | jq -r ".[] | select(.id == $SID).color")
  if [ -n "$color" ] && [ "$color" != "null" ]; then
    bg="0xCC${color#\#}"
  else
    bg="$DEFAULT_FOCUSED"
  fi
  sketchybar --set "$NAME" drawing=on background.color="$bg" background.border_width=2
else
  sketchybar --set "$NAME" background.color="$UNFOCUSED" background.border_width=0
fi
