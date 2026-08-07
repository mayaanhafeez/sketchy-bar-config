#!/usr/bin/env bash
# Wi-Fi scan snapshot: every network in range plus which of them are saved,
# straight from `macwifi scan` and `macwifi preferred`. Tab-separated rows:
#
#   ssid<tab>rssi<tab>channel<tab>security<tab>bssid<tab>known(0|1)
#
# The scan table uses fixed-width columns (SSID left-padded to 32 chars), so
# fields are cut by position — SSIDs may contain spaces.
set -uo pipefail

pref=$(/usr/local/bin/macwifi preferred 2>/dev/null)
scan=$(/usr/local/bin/macwifi scan 2>/dev/null)
[ -z "$scan" ] && exit 0

known=$(mktemp)
trap 'rm -f "$known"' EXIT
printf '%s\n' "$pref" > "$known"

printf '%s\n' "$scan" | awk '
  NR == FNR { known[$0] = 1; next }
  NR > 1 {
    line = $0
    ssid = substr(line, 1, 32); sub(/[[:space:]]+$/, "", ssid)
    rssi = substr(line, 35, 5);  gsub(/[[:space:]]/, "", rssi)
    ch   = substr(line, 42, 4);  gsub(/[[:space:]]/, "", ch)
    sec  = substr(line, 48, 10); sub(/[[:space:]]+$/, "", sec)
    bssid = substr(line, 59); sub(/^[[:space:]]+/, "", bssid); sub(/[[:space:]]+$/, "", bssid)
    if (rssi !~ /^-?[0-9]+$/) next
    k = (ssid in known) ? 1 : 0
    print ssid "\t" rssi "\t" ch "\t" sec "\t" bssid "\t" k
  }
' "$known" -