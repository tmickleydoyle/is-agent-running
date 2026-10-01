#!/bin/zsh
# Removes Agent Snake: stops the overlay, removes the login item and the Claude Code hooks.
set -uo pipefail
LABEL="com.agentsnake.overlay"
BIN="$HOME/.claude/agent-snake/bin/agent-snake"

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"
[[ -x "$BIN" ]] && "$BIN" uninstall-hooks
rm -rf "$HOME/.claude/agent-snake"
echo "✓ Agent Snake removed."
