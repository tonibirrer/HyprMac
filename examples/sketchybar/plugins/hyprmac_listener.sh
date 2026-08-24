#!/bin/bash
# Relay HyprMac IPC events into sketchybar triggers. Started (and
# restarted) by items/hyprmac.sh; reconnects if HyprMac restarts.
#
#   workspace>>FOCUSED>>PREV  → hyprmac_workspace_change (with env vars)
#   windowschanged>>          → hyprmac_update_windows

while true; do
  hyprmacctl subscribe 2>/dev/null | while IFS= read -r line; do
    case "$line" in
      workspace\>\>*)
        data="${line#workspace>>}"
        focused="${data%%>>*}"
        prev="${data#*>>}"
        sketchybar --trigger hyprmac_workspace_change \
          FOCUSED_WORKSPACE="$focused" PREV_WORKSPACE="$prev"
        ;;
      windowschanged\>\>*)
        sketchybar --trigger hyprmac_update_windows
        ;;
    esac
  done
  # socket closed — HyprMac quit or restarted. retry until it's back.
  sleep 2
done
