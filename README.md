https://github.com/user-attachments/assets/fb9a328a-34c1-4214-8942-ed92508e34c2

# Agent Snake 🐍

Little colored snakes crawl around the edge of your screen while Claude Code is working, one snake per running session. Switch apps, spaces, or full-screen windows and you can still see at a glance whether your agents are busy.

| Snake | Meaning |
| --- | --- |
| Crawling around the edge | Agent is working |
| Frozen and pulsing | Agent needs you (permission prompt, question) |
| Flashes a few times, then vanishes | Agent finished, go check it |

The 🐍 in the menu bar shows how many agents are running (plus ⚠︎ for ones waiting on you). Click it to see which project each snake belongs to (color swatch), hide the snakes, clear a stuck one, or quit.

## Install

```sh
./install.sh
```

This will:
1. Compile the app (needs Xcode Command Line Tools for `swiftc`).
2. Copy it to `~/.claude/agent-snake/bin/agent-snake`.
3. Add hooks to `~/.claude/settings.json` (a backup is saved next to it as `settings.json.agent-snake-backup`).
4. Register a login item (`~/Library/LaunchAgents/com.agentsnake.overlay.plist`) so the overlay starts automatically.

Restart any `claude` sessions that were already open so they load the hooks.

After choosing **Quit Agent Snake** from the menu bar, bring it back with `./start.sh`.

## Uninstall

```sh
./uninstall.sh
```

## How it works

- **Claude Code hooks** (`UserPromptSubmit`, `PreToolUse`, `PermissionRequest`, `Stop`, …) run `agent-snake hook`, which writes one tiny JSON file per session to `~/.claude/agent-snake/sessions/`.
- **The overlay** is a transparent, click-through window on every display. It reads those files once a second and animates the snakes at 16 steps per second using Core Animation (under 1% CPU).
- A session's snake is removed if its `claude` process exits. Pressing **Esc** doesn't fire a hook, so the overlay also checks the session transcript for Claude Code's "interrupted" marker.

Everything lives in `Sources/main.swift`. Tweak `cellSize`, `segmentSize`, `snakeLength`, `ticksPerSecond`, or `palette` at the top of the Overlay section, then re-run `./install.sh`.
# is-agent-running
