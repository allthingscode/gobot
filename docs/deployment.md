# Deployment & Persistence Guide

This guide provides instructions for deploying Gobot as a persistent background service on both Linux and Windows.

## Overview
Gobot is designed to be an "always-on" assistant. To ensure it remains active across system reboots and survives unexpected crashes, it should be managed by a service manager or task scheduler.

---

## Linux Deployment (systemd)

On Linux, `systemd` is the recommended way to manage Gobot.

### 1. Preparation
Ensure the `gobot` binary is built and located in a stable directory (e.g., `/opt/gobot`).

```bash
# Build the binary
./scripts/build.sh
# Move to opt
sudo mkdir -p /opt/gobot
sudo cp bin/gobot /opt/gobot/
```

### 2. Encryption Key
On Linux, Gobot uses an AES key file for secret encryption. By default, this is stored at `~/.config/gobot/encryption.key`. 

**Warning:** If you run the service as a dedicated user (recommended), you must ensure the key file is accessible to that user or provided via the `GOBOT_ENCRYPTION_KEY_FILE` environment variable.

### 3. Create systemd Unit File
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
# Environment variables
Environment=GOBOT_STORAGE=/var/lib/gobot
Environment=GOBOT_ENCRYPTION_KEY_FILE=/etc/gobot/encryption.key
# Start command
ExecStart=/opt/gobot/gobot run
# Persistence
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
```

### 4. Enable and Start
```bash
sudo systemctl daemon-reload
sudo systemctl enable gobot
sudo systemctl start gobot
```

### 5. Monitoring
To view real-time logs:
```bash
journalctl -u gobot -f
```

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
You can use the provided script to check for errors:
```powershell
.\scripts\get_logs.ps1
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
1. **Database:** `gobot.db` and `memory.db` (usually in `GOBOT_STORAGE`).
2. **Secrets:** On Linux, the `encryption.key` file. On Windows, ensure you have access to the user profile used for DPAPI.
3. **Config:** `config.json`.
