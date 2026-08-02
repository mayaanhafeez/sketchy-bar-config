#!/usr/bin/env bash
# Fast liveness probe for Claude Code sessions.
#
# Claude Code drops one JSON file per session in ~/.claude/sessions/, each
# carrying the pid and a status ("idle", "busy", "shell", ...). Files linger
# after a session dies, so every pid is checked against the process table
# before it counts -- that alone is enough to weed out stale entries, since
# the status field itself is only rewritten at turn boundaries.
#
# Prints a single line: "<state> <count>"   state = busy | idle | none
set -uo pipefail

SESSION_DIR="$HOME/.claude/sessions"

[ -d "$SESSION_DIR" ] || { echo "none 0"; exit 0; }

# pid<TAB>status, one per session file
raw=$(/usr/bin/jq -r --slurp '
    .[] | select(.pid != null) | [.pid, (.status // "idle")] | @tsv
  ' "$SESSION_DIR"/*.json 2>/dev/null)

[ -z "$raw" ] && { echo "none 0"; exit 0; }

pids=$(printf '%s\n' "$raw" | cut -f1 | paste -sd, -)
# One ps call for every candidate pid; keep only those that are really Claude.
live=$(/bin/ps -o pid=,comm= -p "$pids" 2>/dev/null | /usr/bin/awk '$2 ~ /claude|node/ {printf "%s ", $1}')
[ -z "$live" ] && { echo "none 0"; exit 0; }

printf '%s\n' "$raw" | /usr/bin/awk -v live="$live" '
  BEGIN { n = split(live, a, " "); for (i = 1; i <= n; i++) if (a[i] != "") ok[a[i]+0] = 1 }
  {
    if (!($1+0 in ok)) next
    count++
    if ($2 != "idle") busy = 1   # busy, shell, or anything else mid-flight
  }
  END {
    if (count == 0)   print "none 0"
    else if (busy)    print "busy " count
    else              print "idle " count
  }'
