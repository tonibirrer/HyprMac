#!/bin/bash
# Relay HyprMac IPC events into sketchybar triggers. Started (and
# restarted) by items/hyprmac.sh; reconnects if HyprMac restarts.
#
#   workspace>>FOCUSED>>PREV  → hyprmac_workspace_change (with env vars)
#   windowschanged>>          → hyprmac_update_windows
#
# sketchybar usually loads before HyprMac at login, so the bar starts out
# blank. Each time the stream connects, the whole bar is repainted from
# HyprMac's current state; when the stream closes, the workspace items
# are hidden until HyprMac is back.

repaint() {
  local focused
  focused=$(hyprmacctl focused 2>/dev/null | jq -r '.workspace // empty')
  [ -n "$focused" ] || return
  # the separator's hyprmac_windows.sh also runs on this event, so one
  # trigger refreshes both the highlight and the app-icon strips
  sketchybar --trigger hyprmac_workspace_change \
    FOCUSED_WORKSPACE="$focused" PREV_WORKSPACE="$focused"
}

while true; do
  if hyprmacctl focused >/dev/null 2>&1; then
    # repaint once the subscription below is up, so a change made while
    # it connects is not lost
    (sleep 0.5; repaint) &
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
    # socket closed — HyprMac quit or restarted. hide the stale items.
    sketchybar --set '/space\.[0-9][0-9]*/' drawing=off
  fi
  sleep 2
done
