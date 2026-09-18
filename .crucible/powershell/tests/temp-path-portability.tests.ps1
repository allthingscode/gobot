# Production PowerShell must reach the temp directory through [System.IO.Path]::GetTempPath()
# and not through the environment variable names, because no single variable name works on
# every platform Crucible runs on. GetTempPath() reads TMP then TEMP on Windows, and TMPDIR
# on every other edition, so a file naming one of them directly is correct on at most one
# platform and silently wrong on the rest: an unset variable is an empty string, and the
# functions that consume it - Join-Path above all - fail somewhere downstream of the line that
# actually caused it.
#
# This is the inverse of the rule in fixture-root-conformance.tests.ps1, and the two are
# deliberately separate files rather than one scan pointed at more directories. There, under
# powershell/tests, reaching the machine temp directory at all is the defect and GetTempPath is
# one of the spellings it flags, because a test's scratch space belongs under the run root where
# the reaper can find it. Here, in production, reaching the temp directory is ordinary and
# GetTempPath is the required spelling. Same three variable names, opposite verdicts, because
# the question being asked is not the same question. Merging them would produce one file that
# contradicts itself depending on which half of its own scan is running.
#
# Item 103 is why this exists: lib/crucible-gates.ps1 generated a review-diff helper whose
# scratch path came from $env:TEMP, so an adopter on Linux got a difftool that opened nothing
# during human review. The TEMP-reach rule that might have caught it had never been pointed at
# production code, by design and with that scope stated in its own header, so nothing was
# looking at lib/ at all.
#
# There is no allowlist. An empty ledger is scaffolding for a case that does not exist, and it
# would hand the next author a sanctioned route to keep the bug rather than fix it - every
# legitimate read of the machine temp directory in this repository is already served by
# GetTempPath(), which reads those variables itself on the platform where they mean something.
# If a real exception ever turns up, whoever finds it adds the ledger then, with one entry, a
# real path and a stated reason, which is a better record than an empty array nobody wrote for
# a reason they could name.

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$REPO_ROOT = (Resolve-Path -Path "$PSScriptRoot/../..").Path
. (Join-Path $PSScriptRoot '_harness.ps1')
. (Join-Path $REPO_ROOT "powershell/lib/platform.ps1")
. (Join-Path $REPO_ROOT "powershell/lib/repo-scan.ps1")

$results = @()

# Written as an alternation inside the group rather than as three spelled-out alternatives so
# this line does not match itself under fixture-root-conformance.tests.ps1's scan of this very
# directory. That is cosmetic here, but the reason is not: a rule whose own source has to be
# exempted from a neighbouring rule accumulates ledger entries that later readers cannot tell
# from real exceptions.
#
# It catches assignment as well as reading. Redirecting a child process's temp directory is a
# legitimate thing to do and there is no production site that does it, so the first one to
# appear should arrive with a reason attached rather than slip through a rule that only looked
# at reads.
$TEMP_ENV_PATTERN = '\$env:(TEMP|TMP|TMPDIR)\b'

# The spelling the rule requires, named once. Everything below that needs to say it - the
# failure message a violator reads, and the clean fixture the mutation test plants - composes
# it from here rather than repeating the literal, so this is the single line in this file that
# fixture-root-conformance.tests.ps1 has to carry an exemption for.
$REQUIRED_CALL = '[System.IO.Path]::GetTempPath()'

# The three names, as data. The violating fixtures below are built from this list rather than
# written out, which keeps the literal spellings out of this file's source and, more usefully,
# makes it impossible to add a name to the pattern without the mutation test planting it too.
$TEMP_ENV_NAMES = @("TEMP", "TMP", "TMPDIR")

# The shape Get-RepoScannableFile returns. The mutation fixtures below plant a file in a
# directory that is not a git repository, so they cannot go through the real enumeration, and
# should not: what they prove is that the pattern matches, which is a different question from
# what the enumeration hands it.
function New-ScanEntry {
    param(
        [Parameter(Mandatory = $true)][string]$FullName,
        [Parameter(Mandatory = $true)][string]$RelativePath
    )
    return [pscustomobject]@{ FullName = $FullName; RelativePath = $RelativePath }
}

function Get-ProductionPs1File {
    param([string]$RepoRoot)
    # The same two prefixes native-stderr-idiom.tests.ps1 excludes, for the same two reasons.
    # powershell/tests is test code, where the opposite rule applies and is enforced by
    # fixture-root-conformance.tests.ps1. examples/ is the generated adopter mirror, whose
    # .ps1 files are copies of the ones already being read here, so a violation there is the
    # same violation reported twice. Everything else that a recursive walk would have to skip
    # by hand comes from .gitignore, through git, inside Get-RepoScannableFile.
    return @(Get-RepoScannableFile -RepoRoot $RepoRoot -Extension ".ps1" -ExcludePrefix @("powershell/tests", "examples"))
}

function Find-TempEnvViolation {
    param([array]$Files)
    $violations = @()
    foreach ($f in $Files) {
        $rel = $f.RelativePath
        $lines = @(Get-Content -LiteralPath $f.FullName)
        for ($i = 0; $i -lt $lines.Count; $i++) {
            $line = [string]$lines[$i]
            if ($line -cmatch $TEMP_ENV_PATTERN -and $line -notmatch '^\s*#') {
                $violations += ($rel + ": line " + ($i + 1) + ": " + $line.Trim())
            }
        }
    }
    return $violations
}

$results += Run-Test -Name "No production PowerShell file names the temp directory by a platform-specific variable" -Body {
    $prodFiles = @(Get-ProductionPs1File -RepoRoot $REPO_ROOT)
    # An enumeration that returns nothing makes the assertion below pass having read no code
    # at all, which is the failure mode this whole file exists to prevent one level down.
    Assert-Result -Name "the production scan is non-empty" -Condition ($prodFiles.Count -ge 50) -FailureMessage (
        "the scan found " + $prodFiles.Count + " production .ps1 files; below 50 it is no longer reading this " +
        "repository and the violation assertion below would pass vacuously")

    $violations = @(Find-TempEnvViolation -Files $prodFiles)
    Assert-Result -Name "no platform-specific temp variable in production code" -Condition ($violations.Count -eq 0) -FailureMessage (
        "These production files reach the temp directory by a name that resolves on one platform only. " +
        "Use (" + $REQUIRED_CALL + ") instead, which reads the right variable per platform:`n" +
        ($violations -join "`n"))
}

$results += Run-Test -Name "MUT: the scan catches every spelling it claims to catch" -Body {
    # Each spelling separately, not one representative. The omission this rule was written
    # after was exactly a rule that knew two of three names, and a mutation test that planted
    # only $env:TEMP would have passed against a pattern with the same gap.
    Assert-Result -Name "the spelling list is not empty" -Condition ($TEMP_ENV_NAMES.Count -eq 3) -FailureMessage (
        "expected three spellings to plant, found " + $TEMP_ENV_NAMES.Count + "; a shortened list makes this " +
        "test pass while proving less than it did yesterday")
    $fixtureRoot = New-TestFixtureRoot -NameHint "mut-temp-env"
    try {
        foreach ($name in $TEMP_ENV_NAMES) {
            $body = '$tmp = Join-Path $env:' + $name + ' "crucible-review"'
            $planted = Join-Path $fixtureRoot "leak.ps1"
            Set-Content -LiteralPath $planted -Value $body -Encoding UTF8
            $found = @(Find-TempEnvViolation -Files @(New-ScanEntry -FullName $planted -RelativePath "leak.ps1"))
            Assert-Result -Name ("the scan reports " + $body) -Condition ($found.Count -eq 1) -FailureMessage (
                "planted '" + $body + "' and the scan reported " + $found.Count + " violations rather than 1")
        }
    } finally {
        Remove-Item -LiteralPath $fixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

$results += Run-Test -Name "MUT: the scan passes the spelling it requires, and comments about the ones it forbids" -Body {
    # The other half of the mutation. A pattern that flagged everything would satisfy the test
    # above and fail the repository, and a pattern that flagged comments would make the rule
    # impossible to document in the files it governs - including the comment in
    # lib/crucible-gates.ps1 that explains why that call site changed.
    $cleanBody = '$tmp = Join-Path (' + $REQUIRED_CALL + ') "crucible-review"'
    $commentBody = '# $env:' + $TEMP_ENV_NAMES[0] + ' is named here in prose and must not be reported'
    $fixtureRoot = New-TestFixtureRoot -NameHint "mut-temp-clean"
    try {
        $planted = Join-Path $fixtureRoot "clean.ps1"
        Set-Content -LiteralPath $planted -Value @($cleanBody, $commentBody) -Encoding UTF8
        $found = @(Find-TempEnvViolation -Files @(New-ScanEntry -FullName $planted -RelativePath "clean.ps1"))
        Assert-Result -Name "the required spelling and a comment are both clean" -Condition ($found.Count -eq 0) -FailureMessage (
            "the scan reported " + $found.Count + " violations against a file using " + $REQUIRED_CALL +
            " and a comment:`n" + ($found -join "`n"))
    } finally {
        Remove-Item -LiteralPath $fixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

$failed = @($results | Where-Object { -not $_ }).Count
if ($failed -gt 0) {
    Write-Host "`nSOME TESTS FAILED ($failed of $($results.Count))" -ForegroundColor Red
    exit 1
} else {
    Write-Host "`nALL TESTS PASSED ($($results.Count) tests)" -ForegroundColor Green
    exit 0
}
