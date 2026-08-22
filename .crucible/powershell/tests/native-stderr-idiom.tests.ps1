# Tests for native stderr idiom and anti-regression gate for 2>&1 in production scripts.
# Enforces that native git calls use Invoke-Git rather than raw 2>&1 / 2>$null,
# and that any remaining 2>&1 in production PowerShell files is explicitly allowlisted with rationale.

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$REPO_ROOT = (Resolve-Path -Path "$PSScriptRoot/../..").Path
. (Join-Path $PSScriptRoot '_harness.ps1')
. (Join-Path $REPO_ROOT "powershell/lib/platform.ps1")

$results = @()

# Documented allowlist of legitimate 2>&1 usages in production PowerShell scripts (outside tests and examples).
# Each entry requires an exact RelativePath, a regex Pattern matching the line, and an explicit Decision reason.
$PRODUCTION_2TO1_ALLOWLIST = @(
    @{
        RelativePath = "powershell/factory-doctor.ps1"
        Pattern      = '(?i)\$output\s*=\s*&\s*\$Command\s*@Arguments\s*2>&1'
        Reason       = "Generic command runner in diagnostic doctor tool that executes arbitrary user/diagnostic commands and captures combined output."
    },
    @{
        RelativePath = "powershell/factory-lib.ps1"
        Pattern      = '(?i)\$output\s*=\s*&\s*\$Command\s*@Arguments\s*2>&1'
        Reason       = "Generic command execution helper Invoke-Executable that captures output across varied external tools."
    },
    @{
        RelativePath = "powershell/launch-codex-specialist.ps1"
        Pattern      = '(?i)\$Prompt\s*\|\s*&\s*codex\s*@allArgs\s*2>&1'
        Reason       = "Codex CLI specialist execution capturing combined stdout and stderr to stream and parse agent verdicts."
    },
    @{
        RelativePath = "powershell/lib/factory-gates.ps1"
        Pattern      = '(?i)\$preflightRaw\s*=\s*&\s*\$preflightScript.*2>&1'
        Reason       = "PowerShell script invocation for handoff schema preflight validation capturing diagnostic stderr."
    },
    @{
        RelativePath = "powershell/lib/factory-gates.ps1"
        Pattern      = '(?i)\$testOutput\s*=\s*&\s*\(Get-PwshCommand\).*isolatedChecksScript.*2>&1'
        Reason       = "Child PowerShell process running isolated checks test suite to capture full runner output."
    },
    @{
        RelativePath = "powershell/lib/factory-gates.ps1"
        Pattern      = '(?i)\$pipeline\s*=\s*&\s*\$ScriptBlock\s*2>&1'
        Reason       = "Invoke-GitChecked wrapper executing scriptblocks and capturing pipeline output for error diagnosis."
    },
    @{
        RelativePath = "powershell/lib/factory-gates.ps1"
        Pattern      = '(?i)\$ciOutput\s*=\s*@\(&\s*\(Get-PwshCommand\).*watchScript.*2>&1\)'
        Reason       = "Child PowerShell process running CI watcher during automated promotion."
    },
    @{
        RelativePath = "powershell/lib/factory-gates.ps1"
        Pattern      = '(?i)\$postPushOutput\s*=\s*@\(&\s*\(Get-PwshCommand\).*watchScript.*2>&1\)'
        Reason       = "Child PowerShell process running post-push CI watcher during automated promotion."
    },
    @{
        RelativePath = "powershell/lib/factory-gates.ps1"
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

function Get-ProductionPs1Files {
    param([string]$RepoRoot)
    $files = @(Get-ChildItem -Path $RepoRoot -Filter "*.ps1" -Recurse -File)
    return @($files | Where-Object {
        $rel = ($_.FullName.Substring($RepoRoot.Length)).TrimStart('\', '/') -replace '\\', '/'
        -not (
            $rel.StartsWith("powershell/tests/") -or
            $rel.StartsWith("examples/") -or
            $rel.StartsWith(".private/") -or
            $rel.StartsWith(".gemini/") -or
            $rel.StartsWith(".agent-workspaces/") -or
            $rel.StartsWith(".crucible/")
        )
    })
}

function Find-NativeGit2To1Violations {
    param([array]$Files, [string]$RepoRoot)
    $violations = @()
    foreach ($f in $Files) {
        $rel = ($f.FullName.Substring($RepoRoot.Length)).TrimStart('\', '/') -replace '\\', '/'
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
    param([array]$Files, [string]$RepoRoot, [array]$Allowlist)
    $violations = @()
    foreach ($f in $Files) {
        $rel = ($f.FullName.Substring($RepoRoot.Length)).TrimStart('\', '/') -replace '\\', '/'
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
    $violations = @(Find-NativeGit2To1Violations -Files $prodFiles -RepoRoot $REPO_ROOT)
    Assert-Result -Name "no raw git 2>&1" -Condition ($violations.Count -eq 0) -FailureMessage ("Found raw git 2>&1 violations in production files:`n" + ($violations -join "`n"))
}

$results += Run-Test -Name "All production 2>&1 usages are in documented allowlist with explicit rationale" -Body {
    $prodFiles = @(Get-ProductionPs1Files -RepoRoot $REPO_ROOT)
    $violations = @(Find-Unallowlisted2To1Violations -Files $prodFiles -RepoRoot $REPO_ROOT -Allowlist $PRODUCTION_2TO1_ALLOWLIST)
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

$results += Run-Test -Name "MUT: Scanner detects synthetic raw git 2>&1 violation" -Body {
    $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ("crucible-mut-git-2to1-" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
    try {
        $fakePs1 = Join-Path $tempDir "leak.ps1"
        Set-Content -LiteralPath $fakePs1 -Value 'git status 2>&1'
        $fileInfo = Get-Item -LiteralPath $fakePs1
        $violations = @(Find-NativeGit2To1Violations -Files @($fileInfo) -RepoRoot $tempDir)
        Assert-Result -Name "MUT catches synthetic git 2>&1" -Condition ($violations.Count -gt 0) -FailureMessage "Scanner failed to detect synthetic git 2>&1"
    } finally {
        Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

$results += Run-Test -Name "MUT: Scanner detects synthetic unallowlisted 2>&1 violation" -Body {
    $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ("crucible-mut-unallowlisted-2to1-" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
    try {
        $fakePs1 = Join-Path $tempDir "unallowlisted.ps1"
        Set-Content -LiteralPath $fakePs1 -Value '$out = & my-native-tool 2>&1'
        $fileInfo = Get-Item -LiteralPath $fakePs1
        $violations = @(Find-Unallowlisted2To1Violations -Files @($fileInfo) -RepoRoot $tempDir -Allowlist $PRODUCTION_2TO1_ALLOWLIST)
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
