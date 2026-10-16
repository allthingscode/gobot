# Deployment & Persistence Guide

This guide provides instructions for deploying Gobot as a persistent background service on both Linux and Windows.

## Overview
Gobot is designed to be an "always-on" assistant. To ensure it remains active across system reboots and survives unexpected crashes, it should be managed by a service manager or task scheduler.

> **Zero-maintenance note:** An enabled cron job with a positive persisted next-run timestamp that is overdue dispatches once on the first successful poll after restart. Gobot does not replay every missed recurring occurrence. A zero or absent timestamp initializes scheduling instead. Dispatch does not guarantee successful delivery. See [Cron Job Scheduling & Missed Job Behavior](#cron-job-scheduling--missed-job-behavior).

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
Build, then explicitly check the executable before human launch or registration.

```powershell
# Build the binary
pwsh -NoProfile -File scripts/build.ps1
pwsh -NoProfile -File scripts/check_selected_binary.ps1
# Equivalent inspection-only entry: .\start_gobot.ps1 -CheckBinaryOnly
```

The check prefers `bin/gobot.exe`, falling back to root `gobot.exe`, independent of
caller location. It never runs Gobot. Go and git must be available; the maintained
helper verifies govulncheck v1.8.0 or installs that pin. Provisioning and the
vulnerability database require network access. Missing tools/evidence, dirty builds,
revision/toolchain/dependency differences, findings and scanner/database errors
all fail with a rebuild/recheck command. Resolve the intended checkout/toolchain,
rebuild, and repeat until exit 0 before manually launching or registering the task.
Build alone does not establish a clean scan. A revision mismatch means a different
checkout, not necessarily an older build. Binary findings are retained-symbol
advisories, not demonstrated runtime exploits; source checks are separate evidence.
This is a point-in-time check and cannot prevent subsequent artifact replacement.
Normal launch/restart stays human-operated and does not run automatic online scans.

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

## Modular Cron Ownership and Legacy Cleanup

Imported Markdown cron definitions acquire `"source": "modular"` in `jobs.json`, including an existing job with the same ID. A valid definition controls that job's name, schedule, payload and enabled flag while preserving its execution state. Use unique IDs across modular definitions, operator jobs and seeded jobs to avoid adopting an unrelated job.

Removing a definition removes its modular-owned job on the next complete, readable scan, including when the last definition is removed or the scheduler starts with an empty items directory. Ownership and removals persist atomically before due selection. Already dispatched work continues. Missing directories, unreadable files and malformed definitions cannot authorize deletion; reconciliation retries after the problem is corrected.

Jobs with missing, empty or unknown `source` values remain unowned and survive reconciliation. This conservative upgrade policy intentionally preserves possible legacy orphans: origin cannot be inferred from a job's ID, name, schedule or payload. A legacy job acquires modular ownership only when a valid same-ID definition is imported. Do not bulk-mark legacy jobs as modular.

For a confirmed obsolete legacy job:

1. Stop the Gobot service or scheduled process using your deployment's service controls.
2. Back up the durable storage root's `jobs.json`.
3. Remove only the record whose ID you have verified as obsolete, preserving all other jobs and valid JSON.
4. Restart the service and confirm the retained jobs are present.

## Cron Job Scheduling & Missed Job Behavior

Gobot evaluates background jobs on a short polling interval while running. Restart behavior depends on the enabled job's persisted `state.nextRunAtMs`, a Unix timestamp in **milliseconds**.

### One persisted overdue run, without per-occurrence backfill

On the first successful poll after restart, an enabled job with a valid positive next-run timestamp at or before the poll time dispatches once. Equality with the poll time is due too. Multiple missed days still produce one persisted overdue dispatch, not one dispatch per missed occurrence. After dispatch completes, the scheduler computes the next run from completion time. Dispatch is an execution attempt, not a guarantee of successful delivery; check job state, logs and output.

A zero timestamp initializes scheduling without dispatch on that poll. An absent `state` or `nextRunAtMs` field decodes to zero. For a valid recurring cron schedule, initialization computes the next future occurrence. This future-occurrence behavior does not apply to expired one-shot or invalid schedules. A positive future timestamp waits until due. Disabled jobs are skipped.

### Design rationale

Each job retains one next-run timestamp. Preserving an overdue timestamp allows one late execution after downtime, while computing the next occurrence from completion avoids replaying every missed recurring occurrence. Several different overdue jobs can still dispatch after restart; the policy does not guarantee that stale work is skipped or that deliveries succeed.

### Manual recovery: check for an automatic execution first

Before requesting work manually, check the job's execution state, logs and output: an overdue persisted job may already have run after restart. Repeating its request can duplicate work. If the work is still needed, use one of the options below.

#### Option A — Ask the bot to run it now (recommended)

After checking for an already recovered execution, ask Gobot to do the work from Telegram or a local CLI chat session:

```bash
# Start a local chat session (no Telegram required)
gobot chat
```

Then send a message describing the job, for example:

```text
Run my morning briefing now.
```

This requests the work in the current session without changing the recurring schedule. Check the response or output to confirm the result; requesting work does not guarantee successful delivery.

#### Option B — Force the next scheduled run to be due (advanced)

The durable store is `<storage root>/workspace/jobs.json`. Resolve the actual storage root using the [storage precedence above](#5-environment-variable-inheritance-important): `runtime.storage_root`, then `GOBOT_STORAGE`, then `$GOBOT_HOME/data`, then `~/gobot_data`. Do not assume `GOBOT_STORAGE` is set or that your interactive shell uses the service's store.

1. Check for an already recovered execution before forcing another attempt.
2. Stop Gobot using the service or scheduled-process controls and ensure it remains stopped before editing.
3. Back up the actual durable workspace's `jobs.json`.
4. Locate the intended enabled job by ID. Change only its `state.nextRunAtMs` to a **positive past** millisecond timestamp, preserving other fields, all other jobs and valid JSON.
5. Restart Gobot. On the next successful poll, that job dispatches once; for a valid recurring cron schedule its next occurrence is computed from completion time. Check state, logs and output for the result.

For example, set the intended job's existing field to `1` (1970-01-01T00:00:00.001Z). This is a field fragment, not a replacement store:

```json
"nextRunAtMs": 1
```

Do **not** use `0` to force a run: it initializes scheduling without dispatch on that poll. Keep comments outside `jobs.json`, which must remain strict JSON. Editing while Gobot is running risks racing the scheduler's writes.

### Example scenario: a missed morning briefing

An enabled daily job uses `0 7 * * *` in UTC. Gobot was offline at 07:00 and restarts at **2026-10-16 09:00 UTC**. Assuming the first successful poll occurs then:

| Persisted `state.nextRunAtMs` | Dispatches on first poll | Next occurrence |
|---|---|---|
| 2026-10-16 07:00 UTC (`1792134000000`) | 1 | 2026-10-17 07:00 UTC, assuming dispatch completes before then |
| `0` or absent | 0 | Initializes to 2026-10-17 07:00 UTC |
| 2026-10-17 07:00 UTC (`1792220400000`) | 0 | Waits for 2026-10-17 07:00 UTC |

The overdue case attempts today's briefing once, even if several days were missed. The zero/absent case only initializes tomorrow's run. In the future case, the stored run is not due yet. Before asking for today's briefing manually, check whether the overdue execution already produced it. Use Option A if the work is still needed, and verify its result. The recurring schedule remains in place.

---

## Environment Variables & Docker

All sensitive values can be supplied entirely via environment variables — no secrets in config.json is required. This is the right approach for containers and CI pipelines.

| Variable | Purpose |
|---|---|
| `GOBOT_STORAGE` | Root data directory (databases, logs, secrets vault) |
| `GOBOT_HOME` | Root directory: config at `$GOBOT_HOME/.gobot/config.json` (default `~/.gobot/config.json`), data at `$GOBOT_HOME/data` when `GOBOT_STORAGE` is unset |
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
3. On Windows, run `pwsh -NoProfile -File scripts/check_selected_binary.ps1` and require exit 0 before human restart or task registration.
4. Restart the service:
   - **Linux:** `sudo systemctl restart gobot`
   - **Windows:** Stop the `powershell.exe` process or the Task, then restart it.

### Backups
Always backup the following:
1. **Database:** `gobot.db` and `memory.db` in your `GOBOT_STORAGE` directory (default `~/gobot_data/`).
2. **Linux/macOS encryption key:** `~/.config/gobot/encryption.key` (or `$GOBOT_ENCRYPTION_KEY_FILE` if overridden). **This file is not inside your data directory.** Back it up separately — e.g., export to a password manager. If it is lost, all secrets stored via `gobot secrets set` become permanently unrecoverable.
3. **Windows:** The secrets vault is tied to your Windows user account via DPAPI. Ensure you retain access to that user profile; the vault cannot be decrypted on a different account or machine.
4. **Config:** `~/.gobot/config.json` (or `$GOBOT_HOME/.gobot/config.json` if `GOBOT_HOME` is set).
