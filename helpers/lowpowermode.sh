#!/bin/bash
# Reads and flips macOS Low Power Mode.
#
#   lowpowermode.sh get          -> state=0 | state=1 | state=unsupported
#   lowpowermode.sh set 0|1      -> the state after the attempt, same format
#
# `pmset -g` reports the settings in force for the current power source, which
# is the one the bar should be showing. Machines that predate Low Power Mode
# have no such key at all, hence the unsupported answer -- the widget hides the
# row rather than offering a switch that cannot move.
#
# Changing it is root-only and sketchybar has no terminal to type a password
# into, so `set` goes through the standard authorization dialog. A cancelled
# dialog is not an error here: the state is simply re-read and reported back,
# and the widget redraws whatever is actually true.

set -u

read_state() {
  local line
  line=$(pmset -g 2>/dev/null | awk '/lowpowermode/ { print $2; exit }')
  if [ -z "$line" ]; then
    echo "state=unsupported"
  else
    echo "state=$line"
  fi
}

case "${1:-get}" in
  get)
    read_state
    ;;
  set)
    target="${2:-}"
    case "$target" in
      0 | 1) ;;
      *)
        read_state
        exit 0
        ;;
    esac
    osascript -e "do shell script \"/usr/bin/pmset -a lowpowermode $target\" with administrator privileges" \
      >/dev/null 2>&1
    read_state
    ;;
  *)
    read_state
    ;;
esac
