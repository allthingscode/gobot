# Regression tests for check-mojibake.ps1 invoked with multiple file paths.
#
# The adopter pre-commit hook invokes this script via:
#   powershell.exe -File check-mojibake.ps1 <file1> <file2> ...
# In -File mode a named array parameter (-Paths) binds only the first token, so the
# script must accept files as positional/remaining arguments. This regression guards
# the multi-file path that broke the first #31 implementation (a real gobot commit of
# ~100 staged files surfaced it; the single-file unit test did not).

$ErrorActionPreference = "Stop"
$scriptPath = Join-Path $PSScriptRoot "check-mojibake.ps1"
$psExe = (Get-Process -Id $PID).Path  # the same PowerShell host running this test

$failures = 0
function Check([string]$Name, [bool]$Condition, [string]$Detail) {
    if ($Condition) {
        Write-Host "PASSED: $Name" -ForegroundColor Green
    } else {
        Write-Host "FAILED: $Name - $Detail" -ForegroundColor Red
        $script:failures++
    }
}

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("crucible-mojibake-test-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

function Invoke-Check {
    param([string[]]$Files)
    # Mirror the hook: -File mode, files passed positionally.
    $out = & $psExe -NoProfile -ExecutionPolicy Bypass -File $scriptPath @Files 2>&1
    return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = ($out | Out-String) }
}

try {
    $clean1 = Join-Path $tempRoot "clean1.md"
    $clean2 = Join-Path $tempRoot "clean2.ps1"
    [System.IO.File]::WriteAllText($clean1, "clean content one`n", [System.Text.UTF8Encoding]::new($false))
    [System.IO.File]::WriteAllText($clean2, "Write-Host 'clean two'`n", [System.Text.UTF8Encoding]::new($false))

    # A genuine mojibake marker: U+00C3 (the script scans for it). Write as UTF-8 so
    # Select-String -Encoding UTF8 reads the marker char.
    $dirty = Join-Path $tempRoot "dirty.md"
    [System.IO.File]::WriteAllText($dirty, ("bad " + [char]0x00C3 + [char]0x00A9 + " marker`n"), [System.Text.UTF8Encoding]::new($false))

    # 1. Multiple clean files, passed positionally -> no positional-binding error, exit 0.
    $r1 = Invoke-Check -Files @($clean1, $clean2)
    Check "multi-file clean: no positional error" (-not ($r1.Output -match "positional parameter")) $r1.Output
    Check "multi-file clean: exit 0" ($r1.ExitCode -eq 0) "exit=$($r1.ExitCode)`n$($r1.Output)"

    # 2. Multiple files where one carries a mojibake marker -> detected, exit 1.
    $r2 = Invoke-Check -Files @($clean1, $dirty, $clean2)
    Check "multi-file with marker: detected (exit 1)" ($r2.ExitCode -eq 1) "exit=$($r2.ExitCode)`n$($r2.Output)"
    Check "multi-file with marker: names the dirty file" ($r2.Output -match "dirty.md") $r2.Output

    # 3. Single file still works (no regression of prior behavior).
    $r3 = Invoke-Check -Files @($clean1)
    Check "single-file clean: exit 0" ($r3.ExitCode -eq 0) "exit=$($r3.ExitCode)`n$($r3.Output)"
} finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

if ($failures -gt 0) {
    Write-Host "`n$failures mojibake invocation test(s) failed." -ForegroundColor Red
    exit 1
}
Write-Host "`nAll mojibake invocation tests passed." -ForegroundColor Green
exit 0
