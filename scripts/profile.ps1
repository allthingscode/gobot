# gobot Binary Footprint Profiler (Windows)
# Usage: .\scripts\profile.ps1

$ErrorActionPreference = "Stop"

$Binary = "gobot.exe"
$FootprintFile = "docs/footprint.txt"
$ThresholdBinary = 0.15 # 15%
$ThresholdRSS = 0.20    # 20%

Write-Host "Building gobot..." -ForegroundColor Cyan
go build -o $Binary ./cmd/gobot/
if ($LASTEXITCODE -ne 0) { exit 1 }

$BinarySize = (Get-Item $Binary).Length
$BinarySizeMB = [math]::Round($BinarySize / 1MB, 2)

Write-Host "Starting gobot for RSS measurement..." -ForegroundColor Cyan
# Start in background. We use 'version' or 'doctor' if we want it to exit, 
# but for RSS we want steady state. 'run' might fail without config, 
# so we'll use a 10s sleep in a sub-shell if needed, but let's try 'version' first 
# and see if we can catch it, or just use 'run' and ignore errors.
$Process = Start-Process -FilePath $Binary -ArgumentList "run" -NoNewWindow -PassThru
Start-Sleep -Seconds 10

$RSS = 0
try {
    $TaskInfo = tasklist /FI "PID eq $($Process.Id)" /FO CSV /NH | ConvertFrom-Csv -Header "Name","PID","SessionName","SessionNum","MemUsage"
    if ($TaskInfo) {
        $MemStr = $TaskInfo.MemUsage.Replace(",", "").Replace(" K", "")
        $RSS = [int]$MemStr # In KB
    }
} catch {
    Write-Host "Warning: Could not capture RSS. Process may have exited early." -ForegroundColor Yellow
}

if ($Process -and -not $Process.HasExited) {
    Stop-Process -Id $Process.Id -Force
}

$RSSMB = [math]::Round($RSS / 1024, 2)

Write-Host ""
Write-Host "Results:" -ForegroundColor Green
Write-Host "  Binary Size: $BinarySizeMB MB"
Write-Host "  Steady RSS:  $RSSMB MB"
Write-Host ""

$Now = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
$NewEntry = "$Now | Size: $BinarySizeMB MB | RSS: $RSSMB MB"

if (Test-Path $FootprintFile) {
    $Content = Get-Content $FootprintFile
    if ($Content.Count -gt 0) {
        $LastLine = $Content[-1]
        # Match "Size: 8.8 MB | RSS: 4.5 MB"
        if ($LastLine -match "Size: ([\d.]+) MB \| RSS: ([\d.]+) MB") {
            $OldSize = [double]$Matches[1]
            $OldRSS = [double]$Matches[2]

            if ($OldSize -gt 0) {
                $SizeDiff = ($BinarySizeMB - $OldSize) / $OldSize
                if ($SizeDiff -gt $ThresholdBinary) {
                    Write-Host "WARNING: Binary size increased by $([math]::Round($SizeDiff*100, 1))% (Threshold: $($ThresholdBinary*100)%)" -ForegroundColor Yellow
                }
            }
            if ($OldRSS -gt 0) {
                $RSSDiff = ($RSSMB - $OldRSS) / $OldRSS
                if ($RSSDiff -gt $ThresholdRSS) {
                    Write-Host "WARNING: Steady RSS increased by $([math]::Round($RSSDiff*100, 1))% (Threshold: $($ThresholdRSS*100)%)" -ForegroundColor Yellow
                }
            }
        }
    }
} else {
    New-Item -ItemType File -Path $FootprintFile -Force | Out-Null
    "Timestamp           | Binary Size | Steady RSS" | Out-File $FootprintFile -Encoding utf8
    "--------------------|-------------|------------" | Out-File $FootprintFile -Append -Encoding utf8
}

$NewEntry | Out-File $FootprintFile -Append -Encoding utf8
Write-Host "Baseline updated in $FootprintFile" -ForegroundColor Gray
