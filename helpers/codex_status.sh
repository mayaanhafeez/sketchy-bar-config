#!/usr/bin/env bash
# Reports whether either Codex CLI or OpenCode currently has a live process.
set -uo pipefail

count=$(/bin/ps -axww -o args= 2>/dev/null | /usr/bin/awk '
  function agent(command) {
    return command ~ /(^|\/)(codex|opencode|opencode-cli|OpenCode)([.]exe)?$/
  }
  # V2 ships opencode.exe even on macOS; comm can also truncate long paths.
  # Inspect only the executable (or the JS runtime script), never arbitrary
  # arguments: a shell editing an opencode config is not a running agent.
  agent($1) || ($1 ~ /(^|\/)(node|bun)([.]exe)?$/ && agent($2)) { count++ }
  END { print count + 0 }
')

if [ "$count" -gt 0 ]; then
  printf 'active %s\n' "$count"
else
  printf 'none 0\n'
fi
