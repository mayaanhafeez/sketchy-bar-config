#!/bin/bash
# Launches macwifi in a centered, generously sized kitty window that fully
# quits when macwifi exits.

DIR="$(cd "$(dirname "$0")" && pwd)"

# Desired window size in logical points.
W=1100
H=740

# Logical screen size (points). Falls back to a sane default if Finder query fails.
read -r SW SH < <(osascript -e 'tell application "Finder" to get bounds of window of desktop' 2>/dev/null | awk -F', ' '{print $3, $4}')
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
