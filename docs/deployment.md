# Deployment & Persistence Guide

This guide provides instructions for deploying Gobot as a persistent background service on both Linux and Windows.

## Overview
Gobot is designed to be an "always-on" assistant. To ensure it remains active across system reboots and survives unexpected crashes, it should be managed by a service manager or task scheduler.

> **Zero-maintenance note:** Even with restart-on-failure configured, scheduled (cron) jobs whose trigger time elapsed while Gobot was offline are **not** automatically replayed when it comes back up. This is intended behavior. See [Cron Job Scheduling & Missed Job Behavior](#cron-job-scheduling--missed-job-behavior) before relying on time-sensitive jobs in an unattended deployment.

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
Build the binary. The `start_gobot.ps1` script resolves `bin\gobot.exe` automatically.

```powershell
# Build the binary
.\scripts\build.ps1
```

### 2. Security & DPAPI (Critical)
Windows uses DPAPI for secret encryption, which is tied to the **specific Windows User account**.
- **Requirement:** The Task Scheduler task **MUST** run as the same user who performed the `gobot authorize` and `gobot reauth` commands.
- **Do NOT** run as `SYSTEM` or `LocalService` unless you performed authorization under those accounts.
- **Pre-flight check:** Run `gobot secrets test` from the same account before enabling your scheduled task. This verifies secrets encryption/decryption works in the current user context.

```powershell
# Verify secrets decryption using the compiled binary
.\bin\gobot.exe secrets test
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

### 5. Environment Variable Inheritance (Important)

**Windows Task Scheduler does not inherit environment variables from your interactive shell session.** A variable you set in your PowerShell profile or current session, including `GOBOT_STORAGE`, is **not** visible to a scheduled task unless it is explicitly baked into the task at registration time.

**Why this matters for `GOBOT_STORAGE`:** Gobot resolves its storage root in this order (`internal/config/config_paths.go`, `StorageRoot()`):

1. `config.json` -> `runtime.storage_root`
2. The `GOBOT_STORAGE` environment variable
3. `$GOBOT_HOME/data`
4. `~/gobot_data` (default)

If you rely on `GOBOT_STORAGE` (rather than `config.json`) to point at a custom path such as `D:\GobotData`, a scheduled task that does not see that variable falls back to `$GOBOT_HOME/data` when `GOBOT_HOME` is set, or `~/gobot_data` otherwise. The result is a **split-brain layout**: your interactive runs use `D:\GobotData` while the scheduled run uses a different default, so databases, logs, the secrets vault, and cron jobs end up in two locations.

**Automatic capture via `install_task.ps1`:** The provided `scripts\install_task.ps1` registration script handles this for you. At registration time it reads the current session's `GOBOT_STORAGE` and, if set, bakes it directly into the task's command line (`-Command "$env:GOBOT_STORAGE='<value>'; & '<start_gobot.ps1>'"`). After registration it prints a confirmation, e.g. `Task created with GOBOT_STORAGE=D:\GobotData`. If `GOBOT_STORAGE` is unset, it tells you the task will use the default storage root.

```powershell
# Set your custom path, then register the task so it is captured:
$env:GOBOT_STORAGE = "D:\GobotData"
.\scripts\install_task.ps1
```

> **Tip:** Setting `runtime.storage_root` in `config.json` is the most robust option, because it takes priority over environment variables and applies to every run - interactive, manual, or scheduled - regardless of how the process was launched.

#### Updating `GOBOT_STORAGE` on an existing task

The capture happens **at registration time only**; changing `$env:GOBOT_STORAGE` afterward does not update an already-registered task. To change the storage path for an existing task, re-run the installer with the new value (it removes and re-registers the task):

```powershell
$env:GOBOT_STORAGE = "E:\NewGobotData"
.\scripts\install_task.ps1
```

Alternatively, edit the task's action by hand in **Task Scheduler** (Actions tab -> Edit) and update the `-Command` argument so the `$env:GOBOT_STORAGE='...'` assignment reflects the new path, or remove the assignment entirely to fall back to the default. You can inspect the current command with:

```powershell
(Get-ScheduledTask -TaskName "Gobot").Actions.Arguments
```

If you manage the storage root through `config.json` instead, no task change is needed - just update `runtime.storage_root` and restart the task.

---

## Cron Job Scheduling & Missed Job Behavior

Gobot can run scheduled background jobs (for example, a daily morning briefing). These are evaluated by the internal scheduler on a short polling interval while Gobot is running. This section explains what happens to a scheduled job when Gobot is **not** running at the job's scheduled time, and how to run such a job on demand.

### Missed jobs are NOT replayed on startup

**Cron jobs that are missed — that is, whose scheduled time occurs while the bot is offline — are NOT automatically replayed on startup.** When Gobot restarts, the scheduler computes each job's *next* run time going forward from the current moment; it does not "catch up" by re-running every occurrence that was skipped while the process was down.

Concretely, if your morning briefing is scheduled for 07:00 and the machine was asleep or the service was stopped from 06:00 to 09:00, you will **not** receive a 07:00 briefing at 09:00. The job's next delivery will be at the next scheduled occurrence (07:00 the following day).

### Design rationale

**This follows standard Unix cron semantics and is acceptable for most use cases.** A traditional `cron` daemon behaves the same way: jobs that were due while the daemon was not running are simply skipped, not backfilled. This is the right default for a personal assistant because:

- **No surprise floods.** After a long outage (an overnight shutdown, a multi-day trip with the laptop closed), you do not want a burst of stale briefings, reminders, and digests all firing at once on startup.
- **Stale work is usually not worth doing late.** A "good morning" briefing delivered at 3 PM, or a reminder for a meeting that already happened, is noise rather than signal.
- **Deterministic, predictable behavior.** Each job has exactly one well-defined next run time, which keeps scheduling easy to reason about and avoids duplicate or out-of-order deliveries.

For the common zero-maintenance scenarios (daily briefings, periodic summaries, recurring digests), waiting until the next scheduled time is the desired outcome.

### When you need a missed job to run anyway: manual trigger

**If your job must run on startup when it was missed, use the manual-trigger workaround below.** Because a cron job in Gobot is simply a saved instruction that is dispatched to the agent at its scheduled time, you can reproduce that dispatch on demand by asking the agent to perform the same task now.

#### Option A — Ask the bot to run it now (recommended)

The simplest and safest way to recover a missed job is to ask Gobot to do the work immediately, either from Telegram or from a local CLI chat session:

```bash
# Start a local chat session (no Telegram required)
gobot chat
```

Then send a message describing the job, for example:

```text
Run my morning briefing now.
```

This dispatches the same kind of request the scheduler would have sent at 07:00, and the result is delivered back to you in the current session. It does not alter the job's recurring schedule — the next automatic run still happens at its normal time.

#### Option B — Force the next scheduled run to be "due" (advanced)

Scheduled jobs are persisted in `jobs.json` under your `GOBOT_STORAGE` directory (`<GOBOT_STORAGE>/workspace/jobs.json`). Each job tracks its next fire time in `state.nextRunAtMs` (a Unix timestamp in **milliseconds**). With Gobot stopped, you can set this value to a time in the past; on the next poll after startup the scheduler will see the job as due and run it once, then advance it to the next scheduled occurrence.

```jsonc
{
  "jobs": [
    {
      "id": "morning_briefing",
      "name": "Morning Briefing",
      "enabled": true,
      "schedule": { "kind": "cron", "expr": "0 7 * * *", "tz": "America/New_York" },
      "payload": { "channel": "email", "message": "Generate my morning briefing." },
      "state": {
        "nextRunAtMs": 0   // set to 0 (or any past millisecond timestamp) to force one run
      }
    }
  ]
}
```

Setting `nextRunAtMs` to `0` causes the scheduler to recompute and immediately schedule the job; a past timestamp causes it to fire once on the next poll. Use this only if you are comfortable editing the store file directly, and edit it while Gobot is stopped to avoid racing the scheduler's own writes.

### Example scenario: a missed morning briefing

You run Gobot on a laptop that is asleep overnight. Your `morning_briefing` job is scheduled for 07:00, but you do not open the laptop until 09:30.

1. **What happens by default:** At 09:30 the service restarts (via your login task / systemd / launchd). The scheduler sees that 07:00 has already passed and schedules the *next* run for 07:00 tomorrow. **No briefing arrives for today** — this is the intended no-replay behavior described above.
2. **Recovering the missed run:** Open a chat with Gobot (Telegram, or `gobot chat`) and send "Run my morning briefing now." Gobot generates and delivers today's briefing immediately.
3. **No further action needed:** Tomorrow's 07:00 run is unaffected and will fire normally. You did not need to recreate, re-enable, or reconfigure the job — it was never misconfigured; it simply followed standard cron semantics.

> **Tip:** If you regularly start your machine after a job's scheduled time and always want that job to run on first start, prefer Option A as a quick habit, or schedule the job for a time you know the machine is reliably awake.

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
