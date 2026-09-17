#!/usr/bin/env bash
# Amphetamine bridge for the coffee-cup widget.
#
# `get` deliberately avoids AppleScript: it runs on every routine tick, and
# `session is active` costs an Apple event round trip plus an Automation grant
# for whoever is asking. The power assertion Amphetamine registers says the
# same thing and is free to read. The two click actions do need scripting, so
# they pay for it -- macOS prompts once for Automation (Amphetamine) and once
# for Accessibility (System Events, for the menu), attributed to sketchybar
# rather than to whatever shell you tested from.

set -u

# Until those grants are in place the Apple event blocks rather than failing,
# and sketchybar has no timeout of its own -- a few stray clicks would leave
# osascript wedged forever. Cap it.
osa() {
  osascript -e "$1" >/dev/null 2>&1 &
  local pid=$!
  ( sleep 15; kill -9 "$pid" ) >/dev/null 2>&1 &
  local watchdog=$!
  wait "$pid" 2>/dev/null
  local status=$?
  kill "$watchdog" >/dev/null 2>&1
  return $status
}

case "${1:-}" in
  get)
    # Amphetamine names its assertions "Amphetamine (<kind> - System|Display)";
    # matching the process name in the pid column is enough and survives any
    # renaming of the session kinds.
    if pmset -g assertions 2>/dev/null | grep -q 'pid [0-9]*(Amphetamine)'; then
      echo "active=1"
    else
      echo "active=0"
    fi
    ;;

  toggle)
    # duration 0 + interval 0 is Amphetamine's spelling of "indefinite". All
    # three keys have to be present -- the handler rejects a partial record --
    # so display sleep is read back from the app's own preference rather than
    # being silently decided here.
    osa 'tell application "Amphetamine"
  if session is active then
    end session
  else
    set allowDisplaySleep to display sleep allowed
    start new session with options {duration:0, interval:0, displaySleepAllowed:allowDisplaySleep}
  end if
end tell'
    ;;

  menu)
    # The Amphetamine status item lives in menu bar 2 (the extras bar); menu bar
    # 1 is the regular File/Edit/Window menu bar. This still works with the
    # system menu bar hidden -- macOS reveals it for as long as the menu is up.
    osa 'tell application "System Events" to tell process "Amphetamine" to click menu bar item 1 of menu bar 2'
    ;;

  *)
    echo "usage: $(basename "$0") get|toggle|menu" >&2
    exit 1
    ;;
esac
