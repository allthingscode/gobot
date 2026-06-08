Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$testsDir = Join-Path $PSScriptRoot "tests"
$testFiles = Get-ChildItem -Path $testsDir -Filter '*test*.ps1' | Sort-Object Name

$failedTests = @()
$passCount = 0

foreach ($file in $testFiles) {
    Write-Host "Running $($file.Name)..." -ForegroundColor Cyan
    
    $testFailed = $false
    $prev = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        & $file.FullName
        if ($LASTEXITCODE -ne 0) {
            $testFailed = $true
        }
    } catch {
        Write-Host "Error in $($file.Name): $_" -ForegroundColor Red
        $testFailed = $true
    } finally {
        $ErrorActionPreference = $prev
    }

    if ($testFailed) {
        $failedTests += $file.Name
    } else {
        $passCount++
    }
}

Write-Host ""
Write-Host "--- Test Summary ---" -ForegroundColor Cyan
Write-Host "Passed: $passCount" -ForegroundColor Green
if ($failedTests.Count -gt 0) {
    Write-Host "Failed: $($failedTests.Count) ($($failedTests -join ', '))" -ForegroundColor Red
    exit 1
} else {
    Write-Host "All tests passed!" -ForegroundColor Green
    exit 0
}

