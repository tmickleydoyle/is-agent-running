#!/bin/zsh
# Builds Agent Snake, starts it at login, and wires it into Claude Code's hooks.
set -euo pipefail
cd "$(dirname "$0")"

BIN_DIR="$HOME/.claude/agent-snake/bin"
BIN="$BIN_DIR/agent-snake"
LABEL="com.agentsnake.overlay"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

echo "→ Building…"
mkdir -p build "$BIN_DIR"
swiftc -O -swift-version 5 Sources/main.swift -o build/agent-snake
cp build/agent-snake "$BIN"

echo "→ Adding Claude Code hooks (backup: ~/.claude/settings.json.agent-snake-backup)…"
"$BIN" install-hooks "$BIN"

echo "→ Starting overlay at login…"
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>$BIN</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
  <key>ProcessType</key><string>Interactive</string>
  <key>StandardErrorPath</key><string>$HOME/.claude/agent-snake/overlay.log</string>
</dict>
</plist>
PLIST
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"

echo "✓ Agent Snake is running (look for 🐍 in the menu bar)."
echo "  Restart any open Claude Code sessions so they pick up the hooks."
