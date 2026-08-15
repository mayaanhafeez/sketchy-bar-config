#!/bin/bash
# Launches macwifi in a centered Ghostty window that fully quits on exit.
DIR="$(cd "$(dirname "$0")" && pwd)"
GHOSTTY="/Applications/Ghostty.app/Contents/MacOS/ghostty"

# Window size in CELLS (Ghostty has no pixel sizing).
COLS=120
ROWS=32

# The same window's measured size in points — used only for the centering math.
# Re-measure these if you change font-family or font-size. See note below.
W=1100
H=740

read -r SW SH < <(osascript -l JavaScript -e 'ObjC.import("AppKit"); var s=$.NSScreen.screens.objectAtIndex(0).frame; s.size.width + " " + s.size.height' 2>/dev/null)
[ -z "$SW" ] && SW=1280
[ -z "$SH" ] && SH=832

X=$(( (SW - W) / 2 ))
Y=$(( (SH - H) / 2 ))

exec "$GHOSTTY" \
  --window-save-state=never \
  --window-width="$COLS" \
  --window-height="$ROWS" \
  --window-position-x="$X" \
  --window-position-y="$Y" \
  --title=btop \
  --font-size=15 \
  -e "btop"
