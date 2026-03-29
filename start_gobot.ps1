# Gobot Strategic Edition — Startup Script
# Usage: .\start_gobot.ps1

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$AppPath    = $PSScriptRoot
$GobotExe   = Join-Path $AppPath "gobot.exe"
$LogDir     = "D:\Gobot_Storage\logs"
$ConfigPath = "C:\Users\HayesChiefOfStaff\.gobot\config.json"
$PythonExe  = "C:\Users\HayesChiefOfStaff\Documents\nanobot\nanoClaw\Scripts\python.exe"

# --- JSON Auto-Formatting ---
if (Test-Path $ConfigPath) {
    Write-Host "Reformatting config.json for readability..." -ForegroundColor Gray
    $PathForPython = $ConfigPath.Replace('\', '/')
    & $PythonExe -c "import json; d=json.load(open('$PathForPython', 'r', encoding='utf-8-sig')); json.dump(d, open('$PathForPython', 'w', encoding='utf-8-sig'), indent=4, ensure_ascii=False)"
}

if (-not (Test-Path $GobotExe)) {
    Write-Host "Error: gobot.exe not found at $GobotExe" -ForegroundColor Red
    Write-Host "Build first: go build -mod=vendor ./cmd/gobot/" -ForegroundColor Yellow
    exit 1
}

if (-not (Test-Path $LogDir)) {
    New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
}

function Stop-GobotProcesses {
    $procs = Get-Process -Name "gobot" -ErrorAction SilentlyContinue
    if ($procs) {
        foreach ($p in $procs) {
            Write-Host "Stopping existing gobot process (PID: $($p.Id))..." -ForegroundColor Gray
            $p | Stop-Process -Force -ErrorAction SilentlyContinue
        }
        Start-Sleep -Milliseconds 500
    }
}

Write-Host ""
Write-Host "--- Initializing Gobot Strategic Edition ---" -ForegroundColor Cyan
Write-Host "Log output: $LogDir\gobot.log" -ForegroundColor Gray
Write-Host ""

try {
    while ($true) {
        Stop-GobotProcesses
        Write-Host "--- Starting Gobot ---" -ForegroundColor Cyan
        & $GobotExe run
        $exitCode = $LASTEXITCODE

        if ($exitCode -eq 0) {
            Write-Host "Gobot shut down gracefully." -ForegroundColor Green
            break
        }

        Write-Host "Gobot exited unexpectedly (code $exitCode). Restarting in 5s..." -ForegroundColor Red
        Start-Sleep -Seconds 5
    }
}
catch {
    Write-Host "Execution Interrupted." -ForegroundColor Yellow
}
finally {
    Write-Host "--- Shutdown Signal Received ---" -ForegroundColor Magenta
    Stop-GobotProcesses
    Write-Host "Gobot stopped. Safe to close this window." -ForegroundColor Green
}
