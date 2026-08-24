#!/usr/bin/env bash
# Machine-readable snapshot of the Wi-Fi radio, straight from `macwifi status`.
# Prints key=value lines (one per line):
#
#   iface   interface name (en0)         powered 1|0
#   ssid    connected network ("-" when none)
#   bssid   BSSID ("-" when none)        rssi    dBm (e.g. -56)
#   noise   dBm                           channel 0 when none
#   txrate  Mbps                         hwaddr  MAC of the interface
set -uo pipefail

if [ -n "${MACWIFI_BIN:-}" ]; then
  bin=$MACWIFI_BIN
elif [ -x /usr/local/bin/macwifi ]; then
  bin=/usr/local/bin/macwifi
else
  bin=$(command -v macwifi 2>/dev/null || true)
fi

if [ -z "$bin" ] || [ ! -x "$bin" ]; then
  printf 'error=macwifi not installed\n'
  exit 1
fi

if ! out=$($bin status 2>&1) || [ -z "$out" ]; then
  printf 'error=%s\n' "${out:-macwifi status returned no data}"
  exit 1
fi

printf 'ok=1\n'

printf '%s\n' "$out" | awk '
{
  key = $0; sub(/^[[:space:]]*/, "", key); sub(/[[:space:]]*:.*$/, "", key)
  val = $0; sub(/^[^:]*:[[:space:]]*/, "", val)
  if      (key == "interface") print "iface=" val
  else if (key == "powered")   print "powered=" (val == "true" ? 1 : 0)
  else if (key == "hw addr")   print "hwaddr=" val
  else if (key == "ssid")      print "ssid=" val
  else if (key == "bssid")     print "bssid=" val
  else if (key == "rssi")      print "rssi=" (val + 0)
  else if (key == "noise")     print "noise=" (val + 0)
  else if (key == "tx rate")   print "txrate=" (val + 0)
  else if (key == "channel")   print "channel=" (val + 0)
}'
