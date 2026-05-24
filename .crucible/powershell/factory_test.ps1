$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$factoryScript = Join-Path $scriptDir "factory.ps1"

if (-not (Test-Path -LiteralPath $factoryScript)) {
    throw "Missing script under test: $factoryScript"
}

$taskId = "{task_id}"
$output = powershell.exe -NoProfile -ExecutionPolicy Bypass -File $factoryScript -Init -TaskId $taskId -Quiet 2>&1
$exitCode = $LASTEXITCODE
$outputText = $output -join "`n"

if ($exitCode -ne 0) {
    Write-Host "FAILED: factory init returned exit code $exitCode" -ForegroundColor Red
    Write-Host $outputText
    exit 1
}

if ($outputText -notmatch "\[NEXT SESSION COMMAND\]") {
    Write-Host "FAILED: expected [NEXT SESSION COMMAND] block in output" -ForegroundColor Red
    Write-Host $outputText
    exit 1
}

Write-Host "PASS: factory init smoke test succeeded for $taskId" -ForegroundColor Green
