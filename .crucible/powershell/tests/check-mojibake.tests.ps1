# Regression tests for check-mojibake.ps1 invoked with multiple file paths.
#
# The adopter pre-commit hook invokes this script via:
#   (Get-PwshCommand) -File check-mojibake.ps1 <file1> <file2> ...
# In -File mode a named array parameter (-Paths) binds only the first token, so the
# script must accept files as positional/remaining arguments. This regression guards
# the multi-file path that broke the first #31 implementation (a real gobot commit of
# ~100 staged files surfaced it; the single-file unit test did not).

$ErrorActionPreference = "Stop"

$REPO_ROOT = (Resolve-Path -Path "$PSScriptRoot/../..").Path
. (Join-Path $REPO_ROOT "powershell/lib/platform.ps1")
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

    # A file whose only defect is a UTF-8 BOM (EF BB BF). The mojibake marker scan is
    # blind to this; the dedicated BOM check must catch it. WriteAllText with a
    # BOM-emitting UTF8Encoding prepends the mark to otherwise clean content.
    $bom = Join-Path $tempRoot "bom.md"
    [System.IO.File]::WriteAllText($bom, "clean text after a bom`n", [System.Text.UTF8Encoding]::new($true))

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

    # 4. Bare invocation (default paths) -> no error, exit 0.
    $r4 = Invoke-Check -Files @()
    Check "bare invocation: exit 0" ($r4.ExitCode -eq 0) "exit=$($r4.ExitCode)`n$($r4.Output)"

    # 5. A BOM-only file (no mojibake markers) -> detected by the BOM check, exit 1.
    $r5 = Invoke-Check -Files @($bom)
    Check "bom file: detected (exit 1)" ($r5.ExitCode -eq 1) "exit=$($r5.ExitCode)`n$($r5.Output)"
    Check "bom file: names the file" ($r5.Output -match "bom.md") $r5.Output
    Check "bom file: reports BOM" ($r5.Output -match "BOM") $r5.Output

    # 6. Clean files (no BOM, no markers) are not false-flagged by the BOM check.
    $r6 = Invoke-Check -Files @($clean1, $clean2)
    Check "clean files: no BOM false positive (exit 0)" ($r6.ExitCode -eq 0) "exit=$($r6.ExitCode)`n$($r6.Output)"
} finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

if ($failures -gt 0) {
    Write-Host "`n$failures mojibake invocation test(s) failed." -ForegroundColor Red
    exit 1
}
Write-Host "`nAll mojibake invocation tests passed." -ForegroundColor Green
exit 0
