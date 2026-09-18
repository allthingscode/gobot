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
. (Join-Path $PSScriptRoot '_harness.ps1')
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

$tempRoot = New-TestFixtureRoot -NameHint "mojibake-test"

# Windows PowerShell 5.1 wraps each stderr line from a native command in an ErrorRecord, so
# under this file's $ErrorActionPreference = "Stop" a gate that writes anything to stderr
# terminates the test file instead of failing an assertion. Found by mutation: removing the
# gate's missing-file guard let Get-Item throw, and the run died with a NativeCommandError
# rather than reporting which assertion caught it. A kill by crash cannot be told apart from
# a harness falling over, which is the whole point of reading the assertion name.
function Invoke-GateProcess {
    param([string[]]$GateArgs = @(), [string]$ScriptFile = "")
    $target = if ([string]::IsNullOrWhiteSpace($ScriptFile)) { $scriptPath } else { $ScriptFile }
    $prev = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $out = & $psExe -NoProfile -ExecutionPolicy Bypass -File $target @GateArgs 2>&1
        return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = ($out | Out-String) }
    } finally {
        $ErrorActionPreference = $prev
    }
}

function Invoke-Check {
    param([string[]]$Files)
    # Mirror the hook: -File mode, files passed positionally.
    return Invoke-GateProcess -GateArgs $Files
}

function Invoke-MessageCheck {
    param([string]$Path)
    # Mirror scripts/hooks/commit-msg, which passes one named single-token argument.
    return Invoke-GateProcess -GateArgs @("-MessageFile", $Path)
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
        return Invoke-GateProcess -ScriptFile $ScriptFile
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

    # 10-14. A commit message file is the one input where this defect is permanent: a BOM in a
    # tracked file is fixable by a later commit, one in a subject line is not once pushed. The
    # gate could not see it, and worse, handed one explicitly it scanned zero files and printed
    # [PASS], because the leaf branch accepted only .md and .ps1. Item 89.
    # The extensionless names are the point - that is what git hands the hook.
    $msgBom = Join-Path $tempRoot "COMMIT_EDITMSG_bom"
    $msgClean = Join-Path $tempRoot "COMMIT_EDITMSG_clean"
    $msgMarker = Join-Path $tempRoot "COMMIT_EDITMSG_marker"
    [System.IO.File]::WriteAllText($msgBom, "fix(scope): a subject behind a byte-order mark`n", [System.Text.UTF8Encoding]::new($true))
    [System.IO.File]::WriteAllText($msgClean, "fix(scope): an ordinary subject`n`nA body line.`n", [System.Text.UTF8Encoding]::new($false))
    [System.IO.File]::WriteAllText($msgMarker, ("fix(scope): " + [char]0x00C3 + [char]0x00A9 + " in the subject`n"), [System.Text.UTF8Encoding]::new($false))

    $r10 = Invoke-MessageCheck -Path $msgBom
    Check "message file with a BOM: detected (exit 1)" ($r10.ExitCode -eq 1) "exit=$($r10.ExitCode)`n$($r10.Output)"
    Check "message file with a BOM: reports BOM" ($r10.Output -match "BOM") $r10.Output
    Check "message file with a BOM: names the file" ($r10.Output -match "COMMIT_EDITMSG_bom") $r10.Output

    # Without this, a gate that refused every message would satisfy the case above.
    $r11 = Invoke-MessageCheck -Path $msgClean
    Check "clean message file: exit 0" ($r11.ExitCode -eq 0) "exit=$($r11.ExitCode)`n$($r11.Output)"
    Check "clean message file: was opened rather than skipped" ($r11.Output -match "in 1 scoped file") $r11.Output

    $r12 = Invoke-MessageCheck -Path $msgMarker
    Check "message file with a mojibake marker: detected (exit 1)" ($r12.ExitCode -eq 1) "exit=$($r12.ExitCode)`n$($r12.Output)"

    # A gate that cannot find its input has verified nothing and must not report a clean message.
    # The exit code alone cannot say this: an unhandled Get-Item throw under
    # $ErrorActionPreference = "Stop" also exits 1, so deleting the guard left this case green
    # once the helper above stopped dying on the child's stderr. Assert the refusal is the
    # gate's own, by its words, and that no exception reached the surface.
    $r13 = Invoke-MessageCheck -Path (Join-Path $tempRoot "no-such-message-file")
    Check "missing message file: exit 1 rather than a clean report" ($r13.ExitCode -eq 1) "exit=$($r13.ExitCode)`n$($r13.Output)"
    Check "missing message file: refused by name rather than by an unhandled throw" (($r13.Output -match "names no readable file") -and ($r13.Output -notmatch "ObjectNotFound")) $r13.Output

    # A repository checked out under a path with a space is ordinary on Windows, and TEMP on
    # this machine has none, so the spaced case would otherwise never be exercised.
    $spacedDir = Join-Path $tempRoot "dir with spaces"
    New-Item -ItemType Directory -Path $spacedDir -Force | Out-Null
    $msgSpaced = Join-Path $spacedDir "COMMIT_EDITMSG"
    [System.IO.File]::WriteAllText($msgSpaced, "fix(scope): spaced path`n", [System.Text.UTF8Encoding]::new($true))
    $rSpace = Invoke-MessageCheck -Path $msgSpaced
    Check "message file under a spaced path: detected (exit 1)" ($rSpace.ExitCode -eq 1) "exit=$($rSpace.ExitCode)`n$($rSpace.Output)"

    # 14. The same silent skip by the positional route. Written BOM-free deliberately: the only
    # thing that can fail this case is the declined-extension report, not an encoding hit.
    $unscanned = Join-Path $tempRoot "notes.txt"
    [System.IO.File]::WriteAllText($unscanned, "plain text, correctly encoded`n", [System.Text.UTF8Encoding]::new($false))
    $r14 = Invoke-Check -Files @($unscanned)
    Check "unscanned extension: exit 1 rather than a vacuous pass" ($r14.ExitCode -eq 1) "exit=$($r14.ExitCode)`n$($r14.Output)"
    Check "unscanned extension: names the file it declined" ($r14.Output -match "notes.txt") $r14.Output
    Check "unscanned extension: says it scanned nothing for it" ($r14.Output -match "does not scan") $r14.Output

    # 15. The gate being right is not enough; it has to be wired, and wired before the merge
    # short-circuit, or a merge message is exempt from a check that costs one file read. Pinned
    # statically so that deleting the hook line fails here, the way case 9 pins pre-commit.
    $msgHookPath = Join-Path $REPO_ROOT "scripts/hooks/commit-msg"
    if (-not (Test-Path -LiteralPath $msgHookPath)) {
        Write-Host "SKIPPED: commit-msg wiring guard (framework-only; no $msgHookPath)" -ForegroundColor Yellow
    } else {
        $msgHookLines = @([System.IO.File]::ReadAllText($msgHookPath) -split "`n")
        $gateIdx = -1
        $mergeIdx = -1
        for ($i = 0; $i -lt $msgHookLines.Count; $i++) {
            # Comments are skipped: a comment mentioning the gate is not the gate running.
            if ($msgHookLines[$i] -match '^\s*#') { continue }
            if ($gateIdx -lt 0 -and $msgHookLines[$i] -match 'check-mojibake\.ps1' -and $msgHookLines[$i] -match '-MessageFile') { $gateIdx = $i }
            if ($mergeIdx -lt 0 -and $msgHookLines[$i] -match 'MERGE_HEAD') { $mergeIdx = $i }
        }
        $gateLine = if ($gateIdx -ge 0) { $msgHookLines[$gateIdx] } else { "(none)" }
        Check "commit-msg invokes the encoding gate on the message file" ($gateIdx -ge 0) "no uncommented 'check-mojibake.ps1 ... -MessageFile' invocation in $msgHookPath"
        Check "commit-msg passes the message path git gave it" (($gateIdx -ge 0) -and ($gateLine -match '"\$MSG_FILE"')) "the invocation does not pass the hook's own MSG_FILE: $gateLine"
        Check "merge short-circuit located" ($mergeIdx -ge 0) "no MERGE_HEAD check in $msgHookPath"
        Check "encoding check runs before the merge short-circuit" (($gateIdx -ge 0) -and ($mergeIdx -ge 0) -and ($gateIdx -lt $mergeIdx)) "gate at line $($gateIdx + 1), MERGE_HEAD at line $($mergeIdx + 1)"
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
