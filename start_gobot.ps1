# Gobot Strategic Edition — Startup Script
# Usage: .\start_gobot.ps1

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$AppPath    = $PSScriptRoot
$GobotExe   = Join-Path $AppPath "gobot.exe"
$LogDir     = "D:\Gobot_Storage\logs"
$LockFile   = Join-Path $LogDir "gobot.pid"
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

function Check-GobotLock {
    if (Test-Path $LockFile) {
        $oldPid = Get-Content $LockFile -ErrorAction SilentlyContinue
        if ($oldPid) {
            $proc = Get-Process -Id $oldPid -ErrorAction SilentlyContinue
            if ($proc -and $proc.Name -eq "gobot") {
                Write-Host "Gobot is already running (PID: $oldPid). This instance will exit." -ForegroundColor Yellow
                exit 0
            }
        }
        # Stale lock or not gobot
        Write-Host "Removing stale lock file: $LockFile" -ForegroundColor Gray
        Remove-Item $LockFile -Force -ErrorAction SilentlyContinue
    }
}

function Stop-GobotProcesses {
    if (Test-Path $LockFile) {
        $pidToStop = Get-Content $LockFile -ErrorAction SilentlyContinue
        if ($pidToStop) {
            $p = Get-Process -Id $pidToStop -ErrorAction SilentlyContinue
            if ($p -and $p.Name -eq "gobot") {
                Write-Host "Stopping managed gobot process (PID: $pidToStop)..." -ForegroundColor Gray
                $p | Stop-Process -Force -ErrorAction SilentlyContinue
            }
        }
        Remove-Item $LockFile -Force -ErrorAction SilentlyContinue
    }
}

Write-Host ""
Write-Host "--- Initializing Gobot Strategic Edition ---" -ForegroundColor Cyan
Write-Host "Log output: $LogDir\gobot.log" -ForegroundColor Gray
Write-Host ""

# Check for existing instance before starting
Check-GobotLock

try {
    while ($true) {
        Stop-GobotProcesses
        Write-Host "--- Starting Gobot ---" -ForegroundColor Cyan
        
        # Start gobot and capture its PID
        $process = Start-Process -FilePath $GobotExe -ArgumentList "run" -NoNewWindow -PassThru
        $process.Id | Out-File $LockFile -Encoding utf8
        
        # Wait for the process to exit
        $process | Wait-Process
        $exitCode = $process.ExitCode

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
