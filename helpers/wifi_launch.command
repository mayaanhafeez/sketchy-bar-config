#!/bin/bash
# Launches macwifi in a centered, generously sized kitty window that fully
# quits when macwifi exits.

DIR="$(cd "$(dirname "$0")" && pwd)"

# Desired window size in logical points.
W=1100
H=740

# Primary display size in logical points (the one with the menu bar). Using the
# primary display only ensures we center on it rather than across the combined
# bounding box of all connected screens. Falls back to a sane default on failure.
read -r SW SH < <(osascript -l JavaScript -e 'ObjC.import("AppKit"); var s=$.NSScreen.screens.objectAtIndex(0).frame; s.size.width + " " + s.size.height' 2>/dev/null)
[ -z "$SW" ] && SW=1280
[ -z "$SH" ] && SH=832

X=$(( (SW - W) / 2 ))
Y=$(( (SH - H) / 2 ))

exec kitty \
  --override close_on_child_death=yes \
  --override macos_quit_when_last_window_closed=yes \
  --override remember_window_size=no \
  --override remember_window_position=no \
  --override initial_window_width="$W" \
  --override initial_window_height="$H" \
  --position "${X}x${Y}" \
  --title macwifi \
  -e "$DIR/macwifi.command"
