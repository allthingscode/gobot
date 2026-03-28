# Gobot Log Retrieval Script
# Extracts critical issues from the last session for the 'clog' command.

$logFile = "D:\Gobot_Storage\logs\gobot.log"
$keywords = @("level=ERROR", "level=WARN", "failed", "Error", "Exception", "panic", "timeout", "Bad Request")
$pattern = ($keywords | ForEach-Object { [regex]::Escape($_) }) -join "|"

# Set output encoding to UTF-8
$OutputEncoding = [System.Text.Encoding]::UTF8
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

if (Test-Path $logFile) {
    # Get content from the last 24 hours or the last 1000 lines
    $content = Get-Content -Path $logFile -Tail 1000
    
    # Filter for keywords
    $matches = $content | Where-Object { $_ -match $pattern }
    
    if ($matches) {
        Write-Output "--- EXTRACTED FROM: $logFile ---"
        $matches | Out-String
    } else {
        Write-Output "No critical issues (ERROR/WARN) found in the last 1000 lines of $logFile."
    }
} else {
    Write-Output "Error: Log file not found at $logFile"
}
