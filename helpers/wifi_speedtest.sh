#!/usr/bin/env bash
# Speed-test backend for the Wi-Fi popup, wrapping `macwifi speedtest`.
#
# A speed test runs for 30s to several minutes, but sbar.exec is one-shot and
# cannot stream a subprocess. So the run is detached into the background with
# macwifi's JSONL event stream landing in a state directory, and the popup polls
# that directory for the latest numbers.
#
#   wifi_speedtest.sh capability     supported=1|0 (+ reason when 0)
#   wifi_speedtest.sh start [provider]
#   wifi_speedtest.sh poll           current state and the latest numbers
#   wifi_speedtest.sh cancel         stop a run in flight
#
# Every subcommand prints key=value lines and exits 0 — failures are reported in
# the payload rather than through exit status, so the Lua side has a single path
# to parse. Values are single-line; error text is flattened.
#
# poll keys:
#   state                idle | running | done | failed
#   provider             apple | ookla | netflix | custom
#   elapsed_ms           ms since the run started            (running)
#   download_mbps        latest sample, or the final figure   (running, done)
#   upload_mbps          latest sample, or the final figure   (running, done)
#   ping_ms              latest probe, or the final figure    (running, done)
#   responsiveness_rpm   Apple's responsiveness score         (done)
#   bytes_downloaded     total bytes pulled                   (done)
#   bytes_uploaded       total bytes pushed                   (done)
#   interface            interface the test ran over          (done)
#   server               server host                          (done)
#   duration_ms          total run time                       (done)
#   error                single-line failure message          (failed)
#
# Live progress samples are interface-wide and can include unrelated traffic;
# the values reported with state=done are the provider's authoritative result.
#
# Set MACWIFI_BIN to point at a different macwifi build (e.g. a debug binary).
set -uo pipefail

# ------------------------------------------------------------------ locations
if [ -n "${MACWIFI_BIN:-}" ]; then
  BIN="$MACWIFI_BIN"
elif [ -x /usr/local/bin/macwifi ]; then
  BIN=/usr/local/bin/macwifi
else
  BIN="$(command -v macwifi 2>/dev/null || true)"
fi

DIR="$HOME/Library/Caches/sketchybar/speedtest"
STREAM="$DIR/run.jsonl"
ERRLOG="$DIR/run.err"
PIDFILE="$DIR/run.pid"

# ------------------------------------------------------------------ utilities
# Flatten to one line: a key=value stream cannot carry embedded newlines.
flatten() {
  printf '%s' "$1" | tr '\n\r\t' '   ' | sed 's/  */ /g; s/^ //; s/ $//'
}

fail() {
  printf 'state=failed\nerror=%s\n' "$(flatten "$1")"
  exit 0
}

# The pid of a run in flight, or empty. Also clears a stale pidfile left behind
# by a reboot or a kill -9.
running_pid() {
  [ -f "$PIDFILE" ] || return 0
  local pid
  pid="$(cat "$PIDFILE" 2>/dev/null)"
  case "$pid" in
    '' | *[!0-9]*) rm -f "$PIDFILE"; return 0 ;;
  esac
  if kill -0 "$pid" 2>/dev/null; then
    printf '%s' "$pid"
  else
    rm -f "$PIDFILE"
  fi
}

# `macwifi speedtest --help` exits 0 where the subcommand exists and 2 on the
# builds that predate it, which is the whole capability probe.
supports_speedtest() {
  [ -n "$BIN" ] && [ -x "$BIN" ] || return 1
  "$BIN" speedtest --help >/dev/null 2>&1
}

# ---------------------------------------------------------------- subcommands
cmd_capability() {
  if [ -z "$BIN" ]; then
    printf 'supported=0\nreason=macwifi not installed\n'
  elif [ ! -x "$BIN" ]; then
    printf 'supported=0\nreason=macwifi at %s is not executable\n' "$BIN"
  elif supports_speedtest; then
    printf 'supported=1\n'
  else
    printf 'supported=0\nreason=this macwifi build has no speedtest subcommand\n'
  fi
}

cmd_start() {
  local provider="${1:-}"

  case "$provider" in
    '' | apple | ookla | netflix | custom) ;;
    *) fail "unknown provider: $provider" ;;
  esac

  [ -n "$BIN" ] && [ -x "$BIN" ] || fail "macwifi not installed"
  supports_speedtest || fail "this macwifi build has no speedtest subcommand"

  # Already in flight: report it rather than starting a second run.
  local pid
  pid="$(running_pid)"
  if [ -n "$pid" ]; then
    cmd_poll
    return
  fi

  mkdir -p "$DIR" || fail "cannot create $DIR"
  rm -f "$STREAM" "$ERRLOG"

  # No --provider unless one was asked for, so macwifi's own
  # ~/.config/macwifi/config.toml [speedtest] provider stays in charge.
  local args=(speedtest --format jsonl)
  [ -n "$provider" ] && args+=(--provider "$provider")
  [ -n "${MACWIFI_SPEEDTEST_TIMEOUT:-}" ] && args+=(--timeout "$MACWIFI_SPEEDTEST_TIMEOUT")

  # Detached, with every descriptor redirected: this script has to return now,
  # not in three minutes, and the run has to outlive it.
  nohup "$BIN" "${args[@]}" >"$STREAM" 2>"$ERRLOG" </dev/null &
  local child=$!
  disown "$child" 2>/dev/null
  printf '%s\n' "$child" >"$PIDFILE"

  printf 'state=running\nelapsed_ms=0\n'
  [ -n "$provider" ] && printf 'provider=%s\n' "$provider"
  return 0
}

cmd_cancel() {
  local pid
  pid="$(running_pid)"
  if [ -n "$pid" ]; then
    # Providers shell out (speedtest, fast-cli), so take the children too.
    pkill -P "$pid" 2>/dev/null
    kill "$pid" 2>/dev/null
    sleep 0.3
    kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null
  fi
  rm -f "$PIDFILE" "$STREAM" "$ERRLOG"
  printf 'state=idle\n'
}

cmd_poll() {
  local pid alive=0
  pid="$(running_pid)"
  [ -n "$pid" ] && alive=1

  if [ "$alive" -eq 0 ] && [ ! -f "$STREAM" ]; then
    printf 'state=idle\n'
    return
  fi

  local stderr_tail=''
  [ -f "$ERRLOG" ] && stderr_tail="$(tail -c 400 "$ERRLOG" 2>/dev/null)"

  ALIVE="$alive" STDERR_TAIL="$stderr_tail" python3 - "$STREAM" <<'PY'
import json, os, sys

path = sys.argv[1]
alive = os.environ.get("ALIVE") == "1"
stderr_tail = os.environ.get("STDERR_TAIL", "").strip()

started, last_progress, complete, failed = None, None, None, None
try:
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                event = json.loads(line)
            except ValueError:
                # The tail of the file can be a half-written line while the run
                # is live; skip it rather than failing the whole poll.
                continue
            kind = event.get("type")
            if kind == "started":
                started = event
            elif kind == "progress":
                last_progress = event
            elif kind == "complete":
                complete = event
            elif kind == "failed":
                failed = event
except OSError:
    pass

out = []

def put(key, value):
    if value is None:
        return
    if isinstance(value, float):
        value = f"{value:.2f}".rstrip("0").rstrip(".")
    text = " ".join(str(value).split())
    if text:
        out.append(f"{key}={text}")

def provider_of(*events):
    for event in events:
        if event and event.get("provider"):
            return event["provider"]
    result = (complete or {}).get("result") or {}
    return result.get("provider")

if complete:
    result = complete.get("result") or {}
    out.append("state=done")
    put("provider", result.get("provider") or provider_of(started, last_progress))
    put("download_mbps", result.get("download_mbps"))
    put("upload_mbps", result.get("upload_mbps"))
    put("ping_ms", result.get("ping_ms"))
    put("responsiveness_rpm", result.get("responsiveness_rpm"))
    put("bytes_downloaded", result.get("bytes_downloaded"))
    put("bytes_uploaded", result.get("bytes_uploaded"))
    put("interface", result.get("interface"))
    put("server", (result.get("server") or {}).get("host"))
    put("duration_ms", result.get("duration_ms"))
elif failed:
    out.append("state=failed")
    put("provider", provider_of(failed, started, last_progress))
    put("error", failed.get("error") or "speed test failed")
elif alive:
    out.append("state=running")
    put("provider", provider_of(started, last_progress))
    if last_progress:
        put("elapsed_ms", last_progress.get("elapsed_ms"))
        put("download_mbps", last_progress.get("download_mbps"))
        put("upload_mbps", last_progress.get("upload_mbps"))
        put("ping_ms", last_progress.get("ping_ms"))
    else:
        put("elapsed_ms", 0)
else:
    # The process is gone without a terminal event: killed, crashed, or timed
    # out. macwifi's diagnostics went to stderr, so surface those if present.
    out.append("state=failed")
    put("provider", provider_of(started, last_progress))
    put("error", stderr_tail or "speed test ended without a result")

print("\n".join(out))
PY
}

# ---------------------------------------------------------------------- entry
case "${1:-poll}" in
  capability) cmd_capability ;;
  start)      cmd_start "${2:-}" ;;
  poll)       cmd_poll ;;
  cancel)     cmd_cancel ;;
  *)          fail "unknown subcommand: ${1:-}" ;;
esac
