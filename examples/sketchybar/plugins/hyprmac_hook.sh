#!/bin/bash
# HyprMac's statusHookCommand. HyprMac runs it after every state.json write,
# and once with empty focus variables after it removed the file (quit or
# pause). It runs with no shell profile, so put Homebrew on PATH first.

export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
sketchybar --trigger hyprmac_change FOCUSED_WORKSPACE="$HYPRMAC_FOCUSED_WORKSPACE"
