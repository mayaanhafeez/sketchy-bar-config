#!/usr/bin/env bash
# Reports whether either Codex CLI or OpenCode currently has a live process.
set -uo pipefail

count=$(/bin/ps -axo comm=,args= 2>/dev/null | /usr/bin/awk '
  $1 ~ /(^|\/)(codex|opencode)$/ || $0 ~ /(^|[ \/])(codex|opencode)([ ]|$)/ { count++ }
  END { print count + 0 }
')

if [ "$count" -gt 0 ]; then
  printf 'active %s\n' "$count"
else
  printf 'none 0\n'
fi
