# Gobot Strategic Edition — Windows Task Scheduler Registration
# Run once as Administrator: .\scripts\install_task.ps1
# Registers gobot to start automatically at user logon.

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

$action = New-ScheduledTaskAction `
    -Execute "powershell.exe" `
    -Argument "-NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$ScriptPath`""

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
Write-Host "To start now: Start-ScheduledTask -TaskName '$TaskName'" -ForegroundColor Gray
Write-Host "To remove:    .\scripts\install_task.ps1 -Uninstall" -ForegroundColor Gray
