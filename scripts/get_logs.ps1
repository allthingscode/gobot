# Gobot Log Retrieval Script
# Extracts critical issues from the LATEST session log for the 'clog' command.

$StorageRoot = if ($env:GOBOT_STORAGE) { $env:GOBOT_STORAGE } else { Join-Path $env:USERPROFILE "gobot_data" }
$logDir = Join-Path $StorageRoot "logs"
$keywords = @("level=ERROR", "level=WARN", "failed", "Error", "Exception", "panic", "timeout", "Bad Request")
$pattern = ($keywords | ForEach-Object { [regex]::Escape($_) }) -join "|"

# Set output encoding to UTF-8
$OutputEncoding = [System.Text.Encoding]::UTF8
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

if (Test-Path $logDir) {
    # Find the most recent log file
    $latestLog = Get-ChildItem -Path $logDir -Filter "gobot_*.log" | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    
    if ($latestLog) {
        $logFile = $latestLog.FullName
        # Get content from the last 1000 lines
        $content = Get-Content -Path $logFile -Tail 1000
        
        # Filter for keywords
        $matches = $content | Where-Object { $_ -match $pattern }
        
        if ($matches) {
            Write-Output "--- EXTRACTED FROM LATEST LOG: $($latestLog.Name) ---"
            $matches | Out-String
        } else {
            Write-Output "No critical issues (ERROR/WARN) found in the last 1000 lines of $($latestLog.Name)."
        }
    } else {
        # Fallback to legacy gobot.log if no timestamped files exist
        $legacyLog = Join-Path $logDir "gobot.log"
        if (Test-Path $legacyLog) {
            Write-Output "--- EXTRACTED FROM LEGACY LOG: gobot.log ---"
            Get-Content $legacyLog -Tail 1000 | Where-Object { $_ -match $pattern } | Out-String
        } else {
            Write-Output "No log files found in $logDir"
        }
    }
} else {
    Write-Output "Error: Log directory not found at $logDir"
}
