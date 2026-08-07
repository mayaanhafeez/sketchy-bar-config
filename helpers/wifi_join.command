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
else
  /usr/local/bin/macwifi connect "$ssid"
fi
