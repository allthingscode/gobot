# Gobot - Startup Script
# Usage: .\start_gobot.ps1

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$AppPath    = $PSScriptRoot
$GobotExe   = Join-Path $AppPath "bin\gobot.exe"
if (-not (Test-Path $GobotExe)) {
    $GobotExe = Join-Path $AppPath "gobot.exe"
}

# Resolve StorageRoot using the executable to ensure consistency with config.json
if (Test-Path $GobotExe) {
    $StorageRoot = & $GobotExe config storage-root
    if ($LASTEXITCODE -ne 0 -or -not $StorageRoot) {
        $StorageRoot = if ($env:GOBOT_STORAGE) { $env:GOBOT_STORAGE } else { Join-Path $env:USERPROFILE "gobot_data" }
    }
} else {
    $StorageRoot = if ($env:GOBOT_STORAGE) { $env:GOBOT_STORAGE } else { Join-Path $env:USERPROFILE "gobot_data" }
}

$LogDir     = Join-Path $StorageRoot "logs"
$LockFile   = Join-Path $LogDir "gobot.pid"
$PreflightLog = Join-Path $LogDir "gobot-startup.log"

if (-not (Test-Path $GobotExe)) {
    Write-Host "Error: gobot.exe not found at bin\gobot.exe or project root" -ForegroundColor Red
    Write-Host "Build first: .\scripts\build.ps1" -ForegroundColor Yellow
    exit 1
}

if (-not (Test-Path $LogDir)) {
    New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
}

function Write-StartupLog {
    param([string]$Message)
    $timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    Add-Content -Path $PreflightLog -Value "[$timestamp] $Message" -Encoding UTF8
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

function Wait-ForNetwork {
    # Bounded network-availability wait. The scheduled task no longer gates on
    # -RunOnlyIfNetworkAvailable (C-314), so the bot may launch a few seconds
    # before the network stack is ready at logon. Probe with a DNS resolve
    # (more firewall-robust than ICMP/Test-Connection, which some environments
    # block) up to 5 times at 3s intervals (~15s cap). Proceed on first success;
    # fall through after the cap regardless so the bot always starts and lets its
    # in-process resilience recover. Never throws; every probe is caught.
    $maxAttempts = 5
    $delaySeconds = 3
    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        try {
            [System.Net.Dns]::GetHostEntry("dns.google") | Out-Null
            Write-StartupLog "Network check: reachable on attempt $attempt/$maxAttempts. Proceeding."
            return
        } catch {
            Write-StartupLog "Network check: attempt $attempt/$maxAttempts failed ($($_.Exception.Message))."
            if ($attempt -lt $maxAttempts) {
                Start-Sleep -Seconds $delaySeconds
            }
        }
    }
    Write-StartupLog "Network check: not reachable after $maxAttempts attempts (~$($maxAttempts * $delaySeconds)s). Proceeding anyway; bot will recover in-process."
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
Write-Host "--- Initializing Gobot ---" -ForegroundColor Cyan
Write-Host "Log output: $LogDir\gobot.log" -ForegroundColor Gray
Write-Host ""

# Check for existing instance before starting
Check-GobotLock

# Wait briefly for network at logon before pre-flight / startup (C-314).
Write-Host "--- Waiting for network availability ---" -ForegroundColor Cyan
Wait-ForNetwork

Write-Host "--- Running secrets pre-flight (gobot secrets test) ---" -ForegroundColor Cyan
& $GobotExe secrets test
if ($LASTEXITCODE -ne 0) {
    $msg = "Pre-flight failed: 'gobot secrets test' exited with code $LASTEXITCODE. Ensure this task runs under the same Windows account used for gobot authorize/reauth."
    Write-Host $msg -ForegroundColor Red
    Write-StartupLog $msg
    exit $LASTEXITCODE
}
Write-Host "Secrets pre-flight passed." -ForegroundColor Green

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
