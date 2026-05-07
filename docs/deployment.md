# Deployment & Persistence Guide

This guide provides instructions for deploying Gobot as a persistent background service on both Linux and Windows.

## Overview
Gobot is designed to be an "always-on" assistant. To ensure it remains active across system reboots and survives unexpected crashes, it should be managed by a service manager or task scheduler.

---

## Linux Deployment (systemd)

On Linux, `systemd` is the recommended way to manage Gobot. There are two options depending on your setup.

### Option A: User Service (recommended for personal use)

A user service runs under your own account without `sudo` and starts when you log in. This is the right choice for a personal assistant.

```bash
# Build the binary
./scripts/build.sh
mkdir -p ~/.local/bin
cp bin/gobot ~/.local/bin/
```

Create `~/.config/systemd/user/gobot.service`:

```ini
[Unit]
Description=Gobot Strategic Agent
After=network.target

[Service]
Type=simple
ExecStart=%h/.local/bin/gobot run
Restart=always
RestartSec=5
Environment=GOBOT_STORAGE=%h/gobot_data
Environment=GOBOT_ENCRYPTION_KEY_FILE=%h/.config/gobot/encryption.key

[Install]
WantedBy=default.target
```

```bash
systemctl --user daemon-reload
systemctl --user enable --now gobot
# View logs:
journalctl --user -u gobot -f
```

> **Encryption key:** The key at `~/.config/gobot/encryption.key` is separate from your data directory. Back it up to a password manager or secure location — if it is lost, all stored secrets become permanently unrecoverable. See [Security & Secrets](security.md#4-criticality-of-encryptionkey-non-windows).

### Option B: System Service (for servers or headless machines)

A system service runs as a dedicated `gobot` user and starts at boot, independent of any login session.

```bash
# Build the binary
./scripts/build.sh
sudo mkdir -p /opt/gobot
sudo cp bin/gobot /opt/gobot/
```

**Encryption key:** Generate the key as the `gobot` user and store it somewhere that user can read:

```bash
sudo useradd -r -s /bin/false gobot
sudo mkdir -p /etc/gobot
sudo -u gobot gobot init   # creates key at ~gobot/.config/gobot/encryption.key
sudo mv ~gobot/.config/gobot/encryption.key /etc/gobot/encryption.key
sudo chown gobot:gobot /etc/gobot/encryption.key
sudo chmod 600 /etc/gobot/encryption.key
```

Create `/etc/systemd/system/gobot.service`:

```ini
[Unit]
Description=Gobot Strategic Agent
After=network.target

[Service]
Type=simple
User=gobot
Group=gobot
WorkingDirectory=/opt/gobot
Environment=GOBOT_STORAGE=/var/lib/gobot
Environment=GOBOT_ENCRYPTION_KEY_FILE=/etc/gobot/encryption.key
ExecStart=/opt/gobot/gobot run
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable gobot
sudo systemctl start gobot
# View logs:
journalctl -u gobot -f
```

---

## macOS Deployment (launchd)

On macOS, use `launchd` to run Gobot as a login agent (starts when you log in, runs in the background).

```bash
./scripts/build.sh
mkdir -p ~/bin
cp bin/gobot ~/bin/
```

Create `~/Library/LaunchAgents/com.gobot.agent.plist` (replace `YOUR_USERNAME` with your macOS username):

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.gobot.agent</string>
    <key>ProgramArguments</key>
    <array>
        <string>/Users/YOUR_USERNAME/bin/gobot</string>
        <string>run</string>
    </array>
    <key>EnvironmentVariables</key>
    <dict>
        <key>GOBOT_STORAGE</key>
        <string>/Users/YOUR_USERNAME/gobot_data</string>
        <key>GOBOT_ENCRYPTION_KEY_FILE</key>
        <string>/Users/YOUR_USERNAME/.config/gobot/encryption.key</string>
    </dict>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>/Users/YOUR_USERNAME/gobot_data/logs/gobot.log</string>
    <key>StandardErrorPath</key>
    <string>/Users/YOUR_USERNAME/gobot_data/logs/gobot-error.log</string>
</dict>
</plist>
```

```bash
launchctl load ~/Library/LaunchAgents/com.gobot.agent.plist
# View logs:
tail -f ~/gobot_data/logs/gobot.log
```

> **Encryption key:** Back up `~/.config/gobot/encryption.key` separately — losing it makes all stored secrets permanently unrecoverable.

---

## Windows Deployment (Task Scheduler)

On Windows, the `start_gobot.ps1` script provides built-in restart logic and is the preferred way to run Gobot persistently.

### 1. Preparation
Build the binary and ensure `gobot.exe` is in the same directory as `start_gobot.ps1`.

```powershell
# Build the binary
.\scripts\build.ps1
# Copy to root (so start_gobot.ps1 can find it)
Copy-Item bin\gobot.exe .
```

### 2. Security & DPAPI (Critical)
Windows uses DPAPI for secret encryption, which is tied to the **specific Windows User account**.
- **Requirement:** The Task Scheduler task **MUST** run as the same user who performed the `gobot authorize` and `gobot reauth` commands.
- **Do NOT** run as `SYSTEM` or `LocalService` unless you performed authorization under those accounts.
- **Pre-flight check:** Run `gobot secrets test` from the same account before enabling your scheduled task. This verifies secrets encryption/decryption works in the current user context.

```powershell
.\gobot.exe secrets test
```

If this test fails, do not enable persistence yet. Fix the task account so it matches the account used for authorization.

### 3. Create Scheduled Task
1. Open **Task Scheduler**.
2. Click **Create Basic Task...** (e.g., Name: "Gobot Persistence").
3. **Trigger:** Select **When I log on** or **When the computer starts**.
    - *Note: If selecting "When the computer starts", ensure the task is configured to "Run whether user is logged on or not".*
4. **Action:** Select **Start a program**.
5. **Program/script:** `powershell.exe`
6. **Add arguments:** `-ExecutionPolicy Bypass -File "C:\path\to\gobot\start_gobot.ps1"`
7. **Start in:** `C:\path\to\gobot`
8. **Settings:** Ensure "Allow task to be run on demand" is checked and "If the task fails, restart every:" is configured (optional, as the script handles its own restarts).

### 4. Monitoring
Logs are stored in the `logs/` directory within the `GOBOT_STORAGE` path (defaulting to the project root).
If DPAPI pre-flight fails in startup, `start_gobot.ps1` exits non-zero and writes details to `logs/gobot-startup.log` so Task Scheduler marks the run as failed.
You can use the provided script to check for errors:
```powershell
.\scripts\get_logs.ps1
```

---

## Environment Variables & Docker

All sensitive values can be supplied entirely via environment variables — no secrets in config.json is required. This is the right approach for containers and CI pipelines.

| Variable | Purpose |
|---|---|
| `GOBOT_STORAGE` | Root data directory (databases, logs, secrets vault) |
| `GOBOT_HOME` | Path to `config.json` (default `~/.gobot/config.json`) |
| `GOBOT_ENCRYPTION_KEY_FILE` | Linux/macOS AES key path (default `~/.config/gobot/encryption.key`) |
| `TELEGRAM_BOT_TOKEN` | Telegram bot token |
| `GEMINI_API_KEY` | Gemini API key |
| `ANTHROPIC_API_KEY` | Claude/Anthropic API key |
| `OPENAI_API_KEY` | OpenAI API key |
| `OPENROUTER_API_KEY` | OpenRouter API key |

**Fallback chain:** For each API key, gobot checks `config.json` first, then the encrypted secrets store, then the environment variable. Setting the environment variable is sufficient even if `config.json` has an empty value for that field.

Example minimal Docker run (Linux):
```bash
docker run \
  -e TELEGRAM_BOT_TOKEN=your_token \
  -e GEMINI_API_KEY=your_key \
  -v /host/gobot_data:/data \
  -v /host/encryption.key:/run/secrets/encryption.key:ro \
  -e GOBOT_STORAGE=/data \
  -e GOBOT_ENCRYPTION_KEY_FILE=/run/secrets/encryption.key \
  gobot run
```

---

## Updates & Maintenance

### Updating Gobot
To update a deployed instance:
1. Pull the latest code: `git pull`
2. Rebuild: `sh scripts/build.sh` or `.\scripts\build.ps1`
3. Restart the service:
   - **Linux:** `sudo systemctl restart gobot`
   - **Windows:** Stop the `powershell.exe` process or the Task, then restart it.

### Backups
Always backup the following:
1. **Database:** `gobot.db` and `memory.db` in your `GOBOT_STORAGE` directory (default `~/gobot_data/`).
2. **Linux/macOS encryption key:** `~/.config/gobot/encryption.key` (or `$GOBOT_ENCRYPTION_KEY_FILE` if overridden). **This file is not inside your data directory.** Back it up separately — e.g., export to a password manager. If it is lost, all secrets stored via `gobot secrets set` become permanently unrecoverable.
3. **Windows:** The secrets vault is tied to your Windows user account via DPAPI. Ensure you retain access to that user profile; the vault cannot be decrypted on a different account or machine.
4. **Config:** `~/.gobot/config.json` (or `$GOBOT_HOME` if overridden).
