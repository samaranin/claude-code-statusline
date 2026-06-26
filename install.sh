#!/usr/bin/env bash
# Installer for claude-statusline.
# Copies the script to ~/.config/claude-statusline.sh and prints the settings snippet.
# It does NOT edit your settings.json automatically (so it can't corrupt it) — paste the
# printed snippet yourself, or pass --print-config to only show the snippet.
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/claude-statusline.sh"
DEST="${XDG_CONFIG_HOME:-$HOME/.config}/claude-statusline.sh"

print_config() {
  cat <<EOF

Add this to your Claude Code settings.json (e.g. ~/.claude/settings.json):

  "statusLine": {
    "type": "command",
    "command": "$DEST"
  }

For a second profile that uses CLAUDE_CONFIG_DIR (e.g. ~/.claude-work/settings.json),
prefix the command so usage limits read that profile's credentials:

  "statusLine": {
    "type": "command",
    "command": "CLAUDE_CONFIG_DIR=$HOME/.claude-work $DEST"
  }
EOF
}

if [ "${1:-}" = "--print-config" ]; then
  print_config
  exit 0
fi

command -v jq   >/dev/null || { echo "warning: 'jq' not found — required at runtime"   >&2; }
command -v curl >/dev/null || { echo "warning: 'curl' not found — required for usage limits" >&2; }

mkdir -p "$(dirname "$DEST")"
install -m 0755 "$SRC" "$DEST"
echo "installed: $DEST"
print_config
