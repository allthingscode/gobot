param(
    [Parameter(Mandatory=$true)]
    [string]$FileToPublish
)

$ErrorActionPreference = "Stop"

if (-Not (Test-Path $FileToPublish)) {
    Write-Error "File not found: $FileToPublish"
    exit 1
}

$Content = Get-Content -Path $FileToPublish -Raw
$HasErrors = $false

# 1. Check for specific PII
$PIIPatterns = @(
    "<user>",
    ("C:" + "\\Users\\[^\\]+")
)

foreach ($Pattern in $PIIPatterns) {
    if ($Content -match $Pattern) {
        Write-Host "::error:: PII detected! Found pattern '$Pattern'." -ForegroundColor Red
        $HasErrors = $true
    }
}

# 2. Check for internal directory structures
if ($Content -match "\.crucible") {
    Write-Host "::error:: Internal path reference detected! Found '.crucible' directory." -ForegroundColor Red
    $HasErrors = $true
}

# 3. Check for API keys (matching the internal reference application audit regexes)
$SecretPatterns = @(
    "AIzaSy[A-Za-z0-9_\-]{33}",   # Google / Gemini API key
    "ya29\.[A-Za-z0-9_\-.]{10,}", # Google OAuth access token
    "xoxb-[A-Za-z0-9\-]+"         # Slack bot token
)

foreach ($Pattern in $SecretPatterns) {
    if ($Content -match $Pattern) {
        Write-Host "::error:: Secret or API key detected! (Pattern: $Pattern)" -ForegroundColor Red
        $HasErrors = $true
    }
}

if ($HasErrors) {
    Write-Host ""
    Write-Host "ABORTING PUBLISH: The Dev Log contains sensitive information." -ForegroundColor Red
    Write-Host "Please edit the file '$FileToPublish' and run this check again."
    exit 1
}

Write-Host "Scan Passed: No PII or secrets detected." -ForegroundColor Green
Write-Host "You may manually publish the contents of '$FileToPublish' to GitHub Discussions."
