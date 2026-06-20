Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot '_harness.ps1')
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_harness.ps1')

# Test harness setup
$results = @()







$results += Run-Test -Name "No literal '(m)' or `"(m)` regex flags in scripts" -Body {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "../..")).Path
    $psDir = Join-Path $repoRoot "powershell"
    $scriptsDir = Join-Path $repoRoot "scripts"
    
    $files = @()
    if (Test-Path $psDir) {
        $files += Get-ChildItem -Path $psDir -Filter "*.ps1" -Recurse
    }
    if (Test-Path $scriptsDir) {
        $files += Get-ChildItem -Path $scriptsDir -Filter "*.ps1" -Recurse
        $files += Get-ChildItem -Path $scriptsDir -Filter "*.go" -Recurse
    }

    $violatingFiles = @()
    foreach ($file in $files) {
        if ($file.Name -eq "regex-hygiene.tests.ps1" -or $file.Name -eq "factory_lint.go") { continue }
        $content = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8
        # Check for literal '(m) or "(m)
        if ($content -match "'\(m\)" -or $content -match '"\(m\)') {
            $violatingFiles += $file.FullName
        }
    }

    Assert-Result -Name "no '(m) or `"(m) regex flags" -Condition ($violatingFiles.Count -eq 0) -FailureMessage ("Found violating regex flags in files: " + ($violatingFiles -join ", "))
}

$failed = @($results | Where-Object { -not $_ }).Count
if ($failed -gt 0) {
    Write-Host "`n$failed regex hygiene test(s) failed." -ForegroundColor Red
    exit 1
}
Write-Host "`nAll regex hygiene tests passed." -ForegroundColor Green
exit 0
