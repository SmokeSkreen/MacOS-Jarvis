# Jarvis

Jarvis is a tiny native macOS companion that floats in the bottom-right corner and sends chat turns through your local OpenClaw install.

## Build

```bash
./scripts/build_app.sh
```

## Run

```bash
open dist/Jarvis.app
```

Click the robot to open the chat. Right-click the robot to quit.

Jarvis also adds a small menu-bar item. Use it to show, reposition, open chat, or quit if the desktop robot ever gets covered.

Jarvis can run a few local desktop actions directly:

- `open YouTube`
- `open Roblox`
- `open Chrome`
- `open a new Chrome tab`

Jarvis opens known websites with explicit URLs, so `open YouTube` opens `https://www.youtube.com` instead of relying on a vague browser request. If a direct local action fails, Jarvis falls back to OpenClaw agent mode. Other messages go straight to OpenClaw.
