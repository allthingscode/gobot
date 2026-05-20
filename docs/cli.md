# CLI Usage

Use CLI mode when you want to run Gobot locally without Telegram.

## Interactive Chat

Start an interactive multi-turn session:

```bash
gobot chat
```

Useful flags:

- `--session <name>`: Session identifier suffix (stored as `cli:<name>`). Default: `default`.
- `--user <id>`: User identifier for local dispatch. Default: `cli-user`.

Example:

```bash
gobot chat --session debug --user local-dev
```

Exit methods:

- Type `/exit` or `/quit`
- Press `Ctrl+C`
- Send EOF (`Ctrl+Z` then Enter on Windows, `Ctrl+D` on Linux/macOS)

If a tool requires Human-in-the-Loop approval, CLI mode remains fail-closed and prints a message telling you to re-run that action from Telegram.
