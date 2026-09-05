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
$scriptPath = Join-Path $REPO_ROOT "powershell/gates/check-mojibake.ps1"
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

    # 7-8. Bare invocation must resolve the content root two levels up: the script lives in
    # <root>/powershell/gates. A single ".." pointed every default path at powershell/<name>,
    # none of which exist, so the script skipped them all and exited 0 having scanned
    # nothing. Case 4 above cannot see that - a vacuous pass and a real pass both exit 0 -
    # so the content root is pinned here against a synthetic framework-shaped tree instead.
    $fwRoot = Join-Path $tempRoot "fwfixture"
    New-Item -ItemType Directory -Path (Join-Path $fwRoot "proposals") -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $fwRoot "powershell/gates") -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $fwRoot "docs") -Force | Out-Null
    $fwScript = Join-Path $fwRoot "powershell/gates/check-mojibake.ps1"
    Copy-Item -LiteralPath $scriptPath -Destination $fwScript
    # Both markers must be present or the fixture takes the adopter branch.
    [System.IO.File]::WriteAllText((Join-Path $fwRoot "powershell/run-all-tests.ps1"), "# framework marker`n", [System.Text.UTF8Encoding]::new($false))
    $marker = "bad " + [char]0x00C3 + " marker`n"

    function Invoke-BareCheck {
        param([string]$ScriptFile)
        $out = & $psExe -NoProfile -ExecutionPolicy Bypass -File $ScriptFile 2>&1
        return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = ($out | Out-String) }
    }

    [System.IO.File]::WriteAllText((Join-Path $fwRoot "docs/dirty.md"), $marker, [System.Text.UTF8Encoding]::new($false))
    $r7 = Invoke-BareCheck -ScriptFile $fwScript
    Check "bare invocation actually scans a content dir (exit 1)" ($r7.ExitCode -eq 1) "exit=$($r7.ExitCode)`n$($r7.Output)"
    [System.IO.File]::WriteAllText((Join-Path $fwRoot "docs/dirty.md"), "clean again`n", [System.Text.UTF8Encoding]::new($false))

    # Every root doc named in the framework default list must really be scanned. Planting
    # the marker in one file at a time keeps each assertion attributable to its own path.
    foreach ($rootDoc in @("README.md", "ROADMAP.md", "CHANGELOG.md", "CONTRIBUTING.md", "TODO.md")) {
        $docPath = Join-Path $fwRoot $rootDoc
        [System.IO.File]::WriteAllText($docPath, $marker, [System.Text.UTF8Encoding]::new($false))
        $rDoc = Invoke-BareCheck -ScriptFile $fwScript
        Check "bare invocation scans root $rootDoc" ($rDoc.ExitCode -eq 1 -and $rDoc.Output -match [regex]::Escape($rootDoc)) "exit=$($rDoc.ExitCode)`n$($rDoc.Output)"
        [System.IO.File]::Delete($docPath)
    }

    # 9. The hook passes its own explicit list, so the scope exists twice and can drift.
    # Pin both copies against the tracked root *.md files: a new root doc added to neither
    # list would otherwise be committed with no encoding gate covering it at all.
    # This file is mirrored into the adopter bundle, where there is no framework hook and
    # no root docs of its own - nothing to drift, so the guard is framework-only. Cases
    # 1-8 above are layout-independent (synthetic fixtures) and do run in both contexts.
    $hookPath = Join-Path $REPO_ROOT "scripts/hooks/pre-commit"
    if (-not (Test-Path -LiteralPath $hookPath)) {
        Write-Host "SKIPPED: root-doc scope drift guard (framework-only; no $hookPath)" -ForegroundColor Yellow
    } else {
        $hookLine = @([System.IO.File]::ReadAllText($hookPath) -split "`n" | Where-Object { $_ -match 'check-mojibake\.ps1 ' } | Select-Object -First 1)[0]
        Check "pre-commit mojibake invocation located" ([string]::IsNullOrWhiteSpace($hookLine) -eq $false) "no explicit check-mojibake.ps1 invocation found in $hookPath"

        $scriptText = [System.IO.File]::ReadAllText($scriptPath)
        $fwBranch = ""
        if ($scriptText -match '(?s)if \(\$isFramework\) \{(.*?)\} else \{') { $fwBranch = $Matches[1] }
        Check "framework default branch located" ($fwBranch -ne "") "could not parse the isFramework branch of check-mojibake.ps1"

        $trackedRootDocs = @(& git -C $REPO_ROOT ls-files --full-name -- "*.md" | Where-Object { $_ -notmatch "/" })
        Check "tracked root docs enumerated" ($trackedRootDocs.Count -gt 0) "git ls-files returned no root *.md files"
        foreach ($doc in $trackedRootDocs) {
            Check "pre-commit hook scans root $doc" ($hookLine -match ("\s" + [regex]::Escape($doc) + "(\s|$)")) "not in the hook's explicit list: $hookLine"
            Check "framework default list scans root $doc" ($fwBranch -match ('"' + [regex]::Escape($doc) + '"')) "not in the isFramework branch of check-mojibake.ps1"
        }
    }
} finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

if ($failures -gt 0) {
    Write-Host "`n$failures mojibake invocation test(s) failed." -ForegroundColor Red
    exit 1
}
Write-Host "`nAll mojibake invocation tests passed." -ForegroundColor Green
exit 0
