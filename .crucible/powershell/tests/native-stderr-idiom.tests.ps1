# Tests for native stderr idiom and anti-regression gate for 2>&1 in production scripts.
# Enforces that native git calls use Invoke-Git rather than raw 2>&1 / 2>$null,
# and that any remaining 2>&1 in production PowerShell files is explicitly allowlisted with rationale.

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$REPO_ROOT = (Resolve-Path -Path "$PSScriptRoot/../..").Path
. (Join-Path $PSScriptRoot '_harness.ps1')
. (Join-Path $REPO_ROOT "powershell/lib/platform.ps1")
. (Join-Path $REPO_ROOT "powershell/lib/repo-scan.ps1")

$results = @()

# Documented allowlist of legitimate 2>&1 usages in production PowerShell scripts (outside tests and examples).
# Each entry requires an exact RelativePath, a regex Pattern matching the line, and an explicit Decision reason.
$PRODUCTION_2TO1_ALLOWLIST = @(
    @{
        RelativePath = "powershell/crucible-doctor.ps1"
        Pattern      = '(?i)\$output\s*=\s*&\s*\$Command\s*@Arguments\s*2>&1'
        Reason       = "Generic command runner in diagnostic doctor tool that executes arbitrary user/diagnostic commands and captures combined output."
    },
    @{
        RelativePath = "powershell/crucible-lib.ps1"
        Pattern      = '(?i)\$output\s*=\s*&\s*\$Command\s*@Arguments\s*2>&1'
        Reason       = "Generic command execution helper Invoke-Executable that captures output across varied external tools."
    },
    @{
        RelativePath = "powershell/launch-codex-specialist.ps1"
        Pattern      = '(?i)\$Prompt\s*\|\s*&\s*codex\s*@allArgs\s*2>&1'
        Reason       = "Codex CLI specialist execution capturing combined stdout and stderr to stream and parse agent verdicts."
    },
    @{
        RelativePath = "powershell/lib/crucible-gates.ps1"
        Pattern      = '(?i)\$preflightRaw\s*=\s*&\s*\$preflightScript.*2>&1'
        Reason       = "PowerShell script invocation for handoff schema preflight validation capturing diagnostic stderr."
    },
    @{
        RelativePath = "powershell/lib/crucible-gates.ps1"
        Pattern      = '(?i)\$testOutput\s*=\s*&\s*\(Get-PwshCommand\).*isolatedChecksScript.*2>&1'
        Reason       = "Child PowerShell process running isolated checks test suite to capture full runner output."
    },
    @{
        RelativePath = "powershell/lib/git.ps1"
        Pattern      = '(?i)\$pipeline\s*=\s*&\s*\$ScriptBlock\s*2>&1'
        Reason       = "Invoke-GitChecked wrapper executing scriptblocks and capturing pipeline output for error diagnosis."
    },
    @{
        RelativePath = "powershell/lib/crucible-gates.ps1"
        Pattern      = '(?i)\$ciOutput\s*=\s*@\(&\s*\(Get-PwshCommand\).*watchScript.*2>&1\)'
        Reason       = "Child PowerShell process running CI watcher during automated promotion."
    },
    @{
        RelativePath = "powershell/lib/crucible-gates.ps1"
        Pattern      = '(?i)\$postPushOutput\s*=\s*@\(&\s*\(Get-PwshCommand\).*watchScript.*2>&1\)'
        Reason       = "Child PowerShell process running post-push CI watcher during automated promotion."
    },
    @{
        RelativePath = "powershell/lib/crucible-gates.ps1"
        Pattern      = '(?i)\$result\s*=\s*&\s*"\$FRAMEWORK_POWERSHELL/validate-backlog\.ps1".*2>&1'
        Reason       = "PowerShell script invocation for backlog validation before handoff."
    },
    @{
        RelativePath = "powershell/new-handoff.ps1"
        Pattern      = '(?i)\$validationRaw\s*=\s*&\s*\$validatorPath.*2>&1'
        Reason       = "PowerShell script invocation for handoff JSON validation against schema."
    },
    @{
        RelativePath = "powershell/watch-adopter-ci.ps1"
        Pattern      = '(?i)\$output\s*=\s*&\s*gh\s*@Arguments\s*2>&1'
        Reason       = "GitHub CLI runner in CI watcher capturing combined output to track remote check run status."
    },
    @{
        RelativePath = "powershell/watch-adopter-ci.ps1"
        Pattern      = '(?i)\$auth\s*=\s*&\s*gh\s*auth\s*status\s*2>&1'
        Reason       = "GitHub CLI authentication verification check in CI watcher capturing auth failure messages."
    }
)

# The shape Get-RepoScannableFile returns, for the two mutation fixtures below. They plant a
# single file in a temp directory that is not a git repository, so they cannot go through the
# real enumeration - and should not: what they prove is that the violation patterns match,
# which is a separate question from what the enumeration hands them.
function New-ScanEntry {
    param(
        [Parameter(Mandatory = $true)][string]$FullName,
        [Parameter(Mandatory = $true)][string]$RelativePath
    )
    return [pscustomobject]@{ FullName = $FullName; RelativePath = $RelativePath }
}

function Get-ProductionPs1Files {
    param([string]$RepoRoot)
    # This walked the filesystem from $RepoRoot with -Recurse until item 87, and excluded
    # .private/, .agent-workspaces/ and .crucible/ by hand - three entries each restating a
    # line of .gitignore. None of them was .claude/worktrees/, where agent tooling puts a
    # real git worktree, so a full suite run concurrent with a subagent linted that agent's
    # checkout of this very suite as production code and failed at 96/97, naming eighteen
    # paths under a directory that no longer existed by the time the failure was read.
    #
    # Get-RepoScannableFile asks git instead, so every one of those three exclusions comes
    # from .gitignore rather than from this list, and the worktree does too.
    #
    # The two prefixes left are scope, not noise: both are tracked, and both are deliberately
    # outside this rule. powershell/tests/ is test code, and examples/ is the generated
    # adopter mirror whose .ps1 files are copies of the ones already scanned here - a
    # violation there is the same violation reported twice. .gemini/ is no longer listed
    # because git does not ignore it and it holds no .ps1 at all; if one ever appears there
    # it should be read, not skipped by a line nobody remembers writing.
    return @(Get-RepoScannableFile -RepoRoot $RepoRoot -Extension ".ps1" -ExcludePrefix @("powershell/tests", "examples"))
}

function Find-NativeGit2To1Violations {
    param([array]$Files)
    $violations = @()
    foreach ($f in $Files) {
        $rel = $f.RelativePath
        $lines = @(Get-Content -LiteralPath $f.FullName)
        for ($i = 0; $i -lt $lines.Count; $i++) {
            $line = [string]$lines[$i]
            # Match raw git calls redirecting 2>&1
            if ($line -match '(?i)\bgit\b.*2>&1' -and $line -notmatch '^\s*#') {
                $violations += "$rel`: line $($i + 1): $line"
            }
        }
    }
    return $violations
}

function Find-Unallowlisted2To1Violations {
    param([array]$Files, [array]$Allowlist)
    $violations = @()
    foreach ($f in $Files) {
        $rel = $f.RelativePath
        $lines = @(Get-Content -LiteralPath $f.FullName)
        for ($i = 0; $i -lt $lines.Count; $i++) {
            $line = [string]$lines[$i]
            if ($line -match '2>&1' -and $line -notmatch '^\s*#') {
                # Check if this line matches any allowlist entry
                $matched = $false
                foreach ($entry in $Allowlist) {
                    if ($entry.RelativePath -eq $rel -and $line -match $entry.Pattern) {
                        $matched = $true
                        break
                    }
                }
                if (-not $matched) {
                    $violations += "$rel`: line $($i + 1): $line"
                }
            }
        }
    }
    return $violations
}

$results += Run-Test -Name "No raw 2>&1 on native git commands in production ps1 files" -Body {
    $prodFiles = @(Get-ProductionPs1Files -RepoRoot $REPO_ROOT)
    # Neither scan in this file asked how many files it had read until item 87. Both report
    # only the violations they find, so an enumeration that returned nothing - a bad root, a
    # filter that matched no extension, git failing - made both of them pass having read no
    # code at all. Get-RepoScannableFile throws rather than return an empty list for exactly
    # that reason, and this is the assertion that would say so here if it ever stopped.
    Assert-Result -Name "the production scan is non-empty" -Condition ($prodFiles.Count -ge 50) -FailureMessage (
        "the scan found " + $prodFiles.Count + " production .ps1 files; below 50 it is no longer reading this " +
        "repository and the violation assertions below would pass vacuously")
    $violations = @(Find-NativeGit2To1Violations -Files $prodFiles)
    Assert-Result -Name "no raw git 2>&1" -Condition ($violations.Count -eq 0) -FailureMessage ("Found raw git 2>&1 violations in production files:`n" + ($violations -join "`n"))
}

$results += Run-Test -Name "All production 2>&1 usages are in documented allowlist with explicit rationale" -Body {
    $prodFiles = @(Get-ProductionPs1Files -RepoRoot $REPO_ROOT)
    Assert-Result -Name "the production scan is non-empty" -Condition ($prodFiles.Count -ge 50) -FailureMessage (
        "the scan found " + $prodFiles.Count + " production .ps1 files; below 50 it is no longer reading this " +
        "repository and the violation assertion below would pass vacuously")
    $violations = @(Find-Unallowlisted2To1Violations -Files $prodFiles -Allowlist $PRODUCTION_2TO1_ALLOWLIST)
    Assert-Result -Name "all 2>&1 allowlisted" -Condition ($violations.Count -eq 0) -FailureMessage ("Found unallowlisted 2>&1 in production files:`n" + ($violations -join "`n"))
}

$results += Run-Test -Name "Every allowlist entry has a non-empty rationale and valid path" -Body {
    $missingRationale = @()
    foreach ($entry in $PRODUCTION_2TO1_ALLOWLIST) {
        if ([string]::IsNullOrWhiteSpace($entry.Reason) -or $entry.Reason.Length -lt 15) {
            $missingRationale += "$($entry.RelativePath): missing or insufficient rationale"
        }
        $fullPath = Join-Path $REPO_ROOT $entry.RelativePath
        if (-not (Test-Path -LiteralPath $fullPath)) {
            $missingRationale += "$($entry.RelativePath): file does not exist"
        }
    }
    $failureMsg = if ($missingRationale.Count -gt 0) { $missingRationale -join "`n" } else { "none" }
    Assert-Result -Name "valid allowlist entries" -Condition ($missingRationale.Count -eq 0) -FailureMessage $failureMsg
}

$results += Run-Test -Name "Every allowlist entry still matches a line in the file it names" -Body {
    # A stale entry - correct path, pattern that no longer matches anything - satisfies
    # every other assertion in this file forever. The scan above reports only 2>&1 lines
    # NOT covered by an entry, so an entry covering nothing is invisible to it, and the
    # check above confirms the file exists without ever asking whether the pattern hits.
    # Moving a sanctioned 2>&1 site from one file to another is exactly what strands one,
    # which is why this is pinned before powershell/lib/crucible-gates.ps1 is split.
    Assert-Result -Name "allowlist is not empty" -Condition ($PRODUCTION_2TO1_ALLOWLIST.Count -gt 0) -FailureMessage "the allowlist is empty, so every assertion made about its entries passes vacuously"

    $stale = @()
    foreach ($entry in $PRODUCTION_2TO1_ALLOWLIST) {
        $fullPath = Join-Path $REPO_ROOT $entry.RelativePath
        if (-not (Test-Path -LiteralPath $fullPath)) {
            $stale += "$($entry.RelativePath): file does not exist, so its pattern covers nothing"
            continue
        }
        $hits = @(Get-Content -LiteralPath $fullPath | Where-Object {
            $_ -match '2>&1' -and $_ -notmatch '^\s*#' -and $_ -match $entry.Pattern
        })
        if ($hits.Count -eq 0) {
            $stale += "$($entry.RelativePath): pattern $($entry.Pattern) matches no 2>&1 line in that file"
        }
    }
    $staleMsg = if ($stale.Count -gt 0) { "Stale allowlist entries (delete them, or point them at the file the code moved to):`n" + ($stale -join "`n") } else { "none" }
    Assert-Result -Name "no stale allowlist entries" -Condition ($stale.Count -eq 0) -FailureMessage $staleMsg
}

$results += Run-Test -Name "Every lib that calls Invoke-GitChecked resolves it when loaded alone" -Body {
    # Invoke-GitChecked is the sanctioned wrapper, so it is reachable from more than one
    # file, and dot-sourcing flattens scope: under the normal load through crucible-lib.ps1
    # a caller that never declares the dependency still gets it from whichever sibling
    # happened to load first. That is how the pre-split arrangement was safe - by accident
    # of load order rather than by declaration - and deleting a dot-source proved to change
    # nothing. Loading each caller on its own makes its own dot-source the only thing that
    # can satisfy the call.
    #
    # The caller list is derived, not written down. A hand-maintained list would go stale
    # the first time a new lib file started using the wrapper, and would then pass while
    # covering nothing new.
    $libDir = Join-Path $REPO_ROOT "powershell/lib"
    $callers = @(Get-ChildItem -Path $libDir -Filter "*.ps1" -File | Where-Object {
        $_.Name -ne "git.ps1" -and
        @(Get-Content -LiteralPath $_.FullName | Where-Object { $_ -match 'Invoke-GitChecked' -and $_ -notmatch '^\s*#' }).Count -gt 0
    })
    Assert-Result -Name "callers of the wrapper were found" -Condition ($callers.Count -gt 0) -FailureMessage "no powershell/lib file calls Invoke-GitChecked, so the loads below would prove nothing"

    $undeclared = @()
    foreach ($caller in $callers) {
        $libPath = $caller.FullName
        $probe = ". `"$libPath`"; if (Get-Command Invoke-GitChecked -ErrorAction SilentlyContinue) { exit 0 } else { exit 3 }"
        $run = Invoke-ExternalCommand -Command { & (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -Command $probe }
        if ($run.ExitCode -ne 0) {
            $undeclared += ("powershell/lib/" + $caller.Name + ": exit " + $run.ExitCode + " - " + $run.Output)
        }
    }
    $undeclaredMsg = if ($undeclared.Count -gt 0) { "These call Invoke-GitChecked but do not load powershell/lib/git.ps1 themselves:`n" + ($undeclared -join "`n") } else { "none" }
    Assert-Result -Name "wrapper callers declare their own dependency" -Condition ($undeclared.Count -eq 0) -FailureMessage $undeclaredMsg
}

$results += Run-Test -Name "MUT: Scanner detects synthetic raw git 2>&1 violation" -Body {
    $tempDir = New-TestFixtureRoot -NameHint "mut-git-2to1"
    try {
        $fakePs1 = Join-Path $tempDir "leak.ps1"
        Set-Content -LiteralPath $fakePs1 -Value 'git status 2>&1'
        $violations = @(Find-NativeGit2To1Violations -Files @(New-ScanEntry -FullName $fakePs1 -RelativePath "leak.ps1"))
        Assert-Result -Name "MUT catches synthetic git 2>&1" -Condition ($violations.Count -gt 0) -FailureMessage "Scanner failed to detect synthetic git 2>&1"
    } finally {
        Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

$results += Run-Test -Name "MUT: Scanner detects synthetic unallowlisted 2>&1 violation" -Body {
    $tempDir = New-TestFixtureRoot -NameHint "mut-unallow-2to1"
    try {
        $fakePs1 = Join-Path $tempDir "unallowlisted.ps1"
        Set-Content -LiteralPath $fakePs1 -Value '$out = & my-native-tool 2>&1'
        $violations = @(Find-Unallowlisted2To1Violations -Files @(New-ScanEntry -FullName $fakePs1 -RelativePath "unallowlisted.ps1") -Allowlist $PRODUCTION_2TO1_ALLOWLIST)
        Assert-Result -Name "MUT catches unallowlisted 2>&1" -Condition ($violations.Count -gt 0) -FailureMessage "Scanner failed to detect unallowlisted 2>&1"
    } finally {
        Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

$failedCount = @($results | Where-Object { -not $_ }).Count
if ($failedCount -gt 0) {
    Write-Host "`nSOME TESTS FAILED" -ForegroundColor Red
    exit 1
} else {
    Write-Host "`nALL TESTS PASSED ($($results.Count) tests)" -ForegroundColor Green
    exit 0
}
