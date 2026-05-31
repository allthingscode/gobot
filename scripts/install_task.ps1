# Gobot Strategic Edition — Windows Task Scheduler Registration
# Run once as Administrator: .\scripts\install_task.ps1
# Registers gobot to start automatically at user logon.
# start_gobot.ps1 resolves the binary from bin\gobot.exe first, falling back to project root.

param(
    [switch]$Uninstall
)

$TaskName = "Gobot Strategic Edition"
$ScriptPath = Join-Path $PSScriptRoot "..\start_gobot.ps1"
$ScriptPath = (Resolve-Path $ScriptPath).Path

if ($Uninstall) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    Write-Host "Gobot task unregistered." -ForegroundColor Yellow
    exit 0
}

# Remove stale registration if present
Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue

# --- Environment variable inheritance (GOBOT_STORAGE) ---
# Windows Task Scheduler does NOT inherit environment variables from the
# interactive shell that registers the task. If GOBOT_STORAGE is set in the
# current session but not baked into the task, the scheduled run falls back to
# the default storage root (~/gobot_data) via start_gobot.ps1 / config.go,
# silently splitting data across two locations. To avoid that, capture the
# current session's GOBOT_STORAGE (if any) and prepend an explicit assignment
# to the PowerShell command the task runs. This is PS 5.1-compatible and needs
# no COM objects. Only GOBOT_STORAGE is captured — by design, no other vars.
$GobotStorage = $env:GOBOT_STORAGE
$EnvPrefix = ""
if ($GobotStorage) {
    # Escape single quotes for the single-quoted PowerShell literal below.
    $EscapedStorage = $GobotStorage -replace "'", "''"
    $EnvPrefix = "`$env:GOBOT_STORAGE='$EscapedStorage'; "
}

$action = New-ScheduledTaskAction `
    -Execute "powershell.exe" `
    -Argument "-NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -Command `"$EnvPrefix& '$ScriptPath'`""

$trigger = New-ScheduledTaskTrigger -AtLogOn

$settings = New-ScheduledTaskSettingsSet `
    -RestartCount 5 `
    -RestartInterval (New-TimeSpan -Minutes 2) `
    -ExecutionTimeLimit (New-TimeSpan -Hours 0) `
    -StartWhenAvailable `
    -RunOnlyIfNetworkAvailable

$principal = New-ScheduledTaskPrincipal `
    -UserId $env:USERNAME `
    -LogonType Interactive `
    -RunLevel Highest

Register-ScheduledTask `
    -TaskName $TaskName `
    -Action $action `
    -Trigger $trigger `
    -Settings $settings `
    -Principal $principal `
    -Force | Out-Null

Write-Host "Gobot task registered." -ForegroundColor Green
Write-Host "It will start automatically at next logon." -ForegroundColor Gray

if ($GobotStorage) {
    Write-Host "Task created with GOBOT_STORAGE=$GobotStorage" -ForegroundColor Green
    Write-Host "The scheduled task will use this storage root." -ForegroundColor Gray
} else {
    Write-Host "GOBOT_STORAGE is not set in this session." -ForegroundColor Yellow
    Write-Host "The scheduled task will use the default storage root (~/gobot_data)." -ForegroundColor Gray
    Write-Host "To target a custom path, set `$env:GOBOT_STORAGE before re-running this script," -ForegroundColor Gray
    Write-Host "or set it permanently in config.json (strategic_edition.storage_root)." -ForegroundColor Gray
}

Write-Host "To start now: Start-ScheduledTask -TaskName '$TaskName'" -ForegroundColor Gray
Write-Host "To remove:    .\scripts\install_task.ps1 -Uninstall" -ForegroundColor Gray
