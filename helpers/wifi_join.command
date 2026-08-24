#!/usr/bin/env bash
# Join a Wi-Fi network through macwifi. Usage:
#
#   wifi_join.command <ssid>           # open network (no password)
#   PASS=<password> wifi_join.command <ssid>   # secured network
#
# The password travels in the environment (the env-var form the widget uses
# for the osascript prompt) and lands in macwifi's argv only at the last step.
set -uo pipefail

if [ -n "${MACWIFI_BIN:-}" ]; then
  bin=$MACWIFI_BIN
elif [ -x /usr/local/bin/macwifi ]; then
  bin=/usr/local/bin/macwifi
else
  bin=$(command -v macwifi 2>/dev/null || true)
fi

if [ -z "$bin" ] || [ ! -x "$bin" ]; then
  printf 'FAILED\n'
  exit 1
fi

ssid=$1
if [ -n "${PASS:-}" ]; then
  "$bin" connect "$ssid" "$PASS"
else
  output=$("$bin" connect "$ssid" 2>&1)
  status=$?
  if [ "$status" -eq 0 ]; then
    printf '%s\n' "$output"
  elif printf '%s' "$output" | grep -qi 'resource busy'; then
    printf 'BUSY\n'
  elif printf '%s' "$output" | grep -qiE 'no cached credential|keychain|cached password did not associate'; then
    printf 'NEEDPASS\n'
  else
    printf 'FAILED\n'
  fi
fi
