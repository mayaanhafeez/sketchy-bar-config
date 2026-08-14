#!/usr/bin/env bash
# Join a Wi-Fi network through macwifi. Usage:
#
#   wifi_join.command <ssid>           # open network (no password)
#   PASS=<password> wifi_join.command <ssid>   # secured network
#
# The password travels in the environment (the env-var form the widget uses
# for the osascript prompt) and lands in macwifi's argv only at the last step.
set -uo pipefail

ssid=$1
if [ -n "${PASS:-}" ]; then
  /usr/local/bin/macwifi connect "$ssid" "$PASS"
elif ! /usr/local/bin/macwifi connect "$ssid"; then
  # macwifi had no saved credential for this one (or the join failed). Say so
  # on stdout so the widget can fall back to asking.
  echo NEEDPASS
fi
