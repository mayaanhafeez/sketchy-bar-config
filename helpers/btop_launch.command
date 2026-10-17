#!/bin/bash
# Launches btop (RAM) or htop (CPU) in the same centered Ghostty window.
MONITOR="${1:-btop}"
case "$MONITOR" in
  btop | htop) ;;
  *) exit 2 ;;
esac
ARGS=("/opt/homebrew/bin/$MONITOR")
if [ "$MONITOR" = htop ]; then
  ARGS+=(--sort-key=PERCENT_CPU)
fi
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
  --title="$MONITOR" \
  --font-size=15 \
  -e "${ARGS[@]}"
