#!/usr/bin/env bash
# The single AI widget is visible for Claude Code, Codex, or OpenCode.
set -uo pipefail

config_dir="${CONFIG_DIR:-$HOME/.config/sketchybar}"
claude=$("$config_dir/helpers/claude_status.sh")
if [ "${claude%% *}" != "none" ]; then
  printf '%s\n' "$claude"
  exit 0
fi

"$config_dir/helpers/codex_status.sh"
