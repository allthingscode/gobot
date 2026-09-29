# Item 139: a bundle update committed while a task waits between phases trips the
# framework-integrity breaker, because the update lands between the handoff's base_commit
# and HEAD. The breaker's recovery text must be runnable as printed, and the recovery must
# carry the incoming handoff forward with only base_commit moved, spending no handoff.

$ErrorActionPreference = "Stop"
$REPO_ROOT = (Resolve-Path -Path "$PSScriptRoot/../..").Path
. (Join-Path $PSScriptRoot '_harness.ps1')
. (Join-Path $REPO_ROOT "powershell/lib/platform.ps1")
$Quiet = $true
. (Join-Path $REPO_ROOT "powershell/crucible-lib.ps1")
$pwshCmd = Get-PwshCommand

$taskId = "F-139"
$allChecks = @("tests_pass", "vet_pass", "acceptance_criteria_met", "scope_bounded", "no_regressions", "no_hard_mandates_violated")
$results = @()

function Invoke-Git {
    param([string]$Repo, [string[]]$GitArgs)
    $out = & git -C $Repo @GitArgs 2>&1
    if ($LASTEXITCODE -ne 0) { throw ("git " + ($GitArgs -join " ") + " failed: " + ($out -join "`n")) }
    return $out
}

# An adopter repo with a real bundle under .crucible, one committed baseline, and a
# verification -> deployment handoff waiting on it, as B-014 was.
function New-InFlightAdopter {
    param([Parameter(Mandatory = $true)][string]$Path)

    $crucible = Join-Path $Path ".crucible"
    New-Item -ItemType Directory -Path (Join-Path $crucible "backlog") -Force | Out-Null
    Copy-Item -Path (Join-Path $REPO_ROOT "powershell") -Destination (Join-Path $crucible "powershell") -Recurse -Force
    Remove-Item -LiteralPath (Join-Path $crucible "powershell/tests") -Recurse -Force
    Copy-Item -Path (Join-Path $REPO_ROOT "schemas") -Destination (Join-Path $crucible "schemas") -Recurse -Force
    @(
        "project: RebaselineTest",
        "paths:",
        "  backlog: .crucible/backlog",
        "  session: .crucible/session",
        "  workspaces: .crucible/.agent-workspaces"
    ) | Set-Content -LiteralPath (Join-Path $crucible "config.yaml") -Encoding UTF8
    @("- $taskId", "- F-140") | Set-Content -LiteralPath (Join-Path $crucible "backlog/BACKLOG.md") -Encoding UTF8
    ".crucible/session/" | Set-Content -LiteralPath (Join-Path $Path ".gitignore") -Encoding UTF8

    Invoke-Git $Path @("init", "-b", "master", "--quiet") | Out-Null
    Invoke-Git $Path @("config", "user.name", "Test") | Out-Null
    Invoke-Git $Path @("config", "user.email", "test@example.com") | Out-Null
    Invoke-Git $Path @("config", "core.autocrlf", "false") | Out-Null
    Invoke-Git $Path @("config", "commit.gpgSign", "false") | Out-Null
    Invoke-Git $Path @("add", "-A") | Out-Null
    Invoke-Git $Path @("commit", "-m", "baseline", "--quiet") | Out-Null
    $baseSha = ([string](Invoke-Git $Path @("rev-parse", "HEAD"))).Trim()

    $handoffDir = Join-Path $crucible "session/handoffs"
    New-Item -ItemType Directory -Path $handoffDir -Force | Out-Null
    $original = Join-Path $handoffDir ($taskId + "-20260101T000000Z.json")
    $gen = Invoke-ExternalCommand {
        & $pwshCmd -NoProfile -ExecutionPolicy Bypass -File (Join-Path $crucible "powershell/new-handoff.ps1") `
            -TaskId $taskId -Source verification -Target deployment -Reason "Review approved - no blockers" `
            -ReviewerChecksPassed ($allChecks -join ",") -CumulativeHandoffCount 5 -BaseCommit $baseSha `
            -SessionCycleId "cycle-139" -OutputPath $original -ProjectRoot $Path
    }
    if ($gen.ExitCode -ne 0) { throw ("fixture handoff was refused: " + ($gen.Output -join "`n")) }

    return @{ Repo = $Path; Base = $baseSha; HandoffDir = $handoffDir; Original = $original }
}

function Add-BundleUpdate {
    param([Parameter(Mandatory = $true)][string]$Repo)
    Add-Content -LiteralPath (Join-Path $Repo ".crucible/powershell/crucible.ps1") -Value "# bundle update" -Encoding UTF8
    Invoke-Git $Repo @("add", "-A") | Out-Null
    Invoke-Git $Repo @("commit", "-m", "chore(crucible): bundle update", "--quiet") | Out-Null
    return ([string](Invoke-Git $Repo @("rev-parse", "HEAD"))).Trim()
}

function Get-IntegrityChanges {
    param([string]$Repo, $Handoff)
    $ctx = @{ RepoRoot = $Repo; CrucibleRoot = ".crucible"; TaskId = $taskId; Handoff = $Handoff }
    return @(Get-CrucibleFrameworkStatusChanges -Context $ctx)
}

function Get-ActiveHandoffFiles {
    param([string]$HandoffDir)
    return @(Get-ChildItem -Path $HandoffDir -Filter ($taskId + "-*.json") | Where-Object {
        $o = Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
        -not ($o.PSObject.Properties["superseded"] -and $o.superseded -eq $true)
    })
}

# pwsh wraps an uncaught throw to the host width with ANSI codes and '|' gutters, so
# compare word runs only.
function ConvertTo-FlatText {
    param([object[]]$Lines)
    $text = (@($Lines) | ForEach-Object { [string]$_ }) -join " "
    return (($text -replace "$([char]0x1b)\[[0-9;]*m", '') -replace '[^\w]+', ' ').Trim()
}

function Invoke-Rebaseline {
    param([string]$Repo, [string[]]$ExtraArgs)
    return Invoke-ExternalCommand {
        & $pwshCmd -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Repo ".crucible/powershell/new-handoff.ps1") `
            -TaskId $taskId -ProjectRoot $Repo @ExtraArgs
    }
}

$tempRoot = New-TestFixtureRoot -NameHint "rebaseline-handoff"
try {
    $results += Run-Test -Name "The breaker's printed recovery re-baselines an in-flight task without spending a handoff" -Body {
        $fx = New-InFlightAdopter -Path (Join-Path $tempRoot "recover")
        $updateSha = Add-BundleUpdate -Repo $fx.Repo
        $originalObj = Get-Content -LiteralPath $fx.Original -Raw -Encoding UTF8 | ConvertFrom-Json

        $flagged = @(Get-IntegrityChanges -Repo $fx.Repo -Handoff $originalObj)
        Assert-Result -Name "bundle update is flagged before recovery" -Condition (($flagged -join "`n") -match "committed \.crucible/powershell/crucible\.ps1") -FailureMessage ("fixture does not reproduce the B-014 breaker, got: " + ($flagged -join ", "))

        $driver = Join-Path $tempRoot "breaker-driver.ps1"
        $driverText = @"
`$Quiet = `$true
. (Join-Path '$REPO_ROOT' 'powershell/crucible-lib.ps1')
`$ErrorActionPreference = 'Stop'
Assert-CrucibleFrameworkIntegrity -Context @{
    RepoRoot = '$($fx.Repo)'
    CrucibleRoot = '.crucible'
    TaskId = '$taskId'
    LogFile = (Join-Path '$($fx.Repo)' '.crucible/session/$taskId/pipeline.log.jsonl')
    CircuitBreakerHistoryFile = (Join-Path '$($fx.Repo)' '.crucible/session/global/circuit_breakers.jsonl')
    Handoff = (Get-Content -LiteralPath '$($fx.Original)' -Raw | ConvertFrom-Json)
}
exit 0
"@
        [System.IO.File]::WriteAllText($driver, $driverText, (New-Object System.Text.UTF8Encoding($false)))
        $breaker = Invoke-ExternalCommand { & $pwshCmd -NoProfile -ExecutionPolicy Bypass -File $driver }
        $breakerText = ($breaker.Output -join "`n")
        Assert-Result -Name "breaker blocks" -Condition ($breaker.ExitCode -eq 2) -FailureMessage ("expected exit 2, got " + $breaker.ExitCode + ". Output: " + $breakerText)
        Assert-Result -Name "breaker states the budget cost" -Condition ($breakerText -match "does not count against the handoff budget") -FailureMessage ("recovery text does not state the budget cost. Output: " + $breakerText)

        $commandLine = @($breaker.Output | ForEach-Object { ([string]$_) -split "\r?\n" } | Where-Object { $_ -match "new-handoff\.ps1" })
        Assert-Result -Name "one recovery command printed" -Condition ($commandLine.Count -eq 1) -FailureMessage ("expected one new-handoff.ps1 line, got: " + ($commandLine -join " | "))
        $printed = $commandLine[0].Trim()
        Assert-Result -Name "command names the task" -Condition ($printed -match ("-TaskId " + [regex]::Escape($taskId) + " -Rebaseline")) -FailureMessage ("expected the real task id, got: " + $printed)

        # Run the line as printed, with only the placeholder filled in, from the project root.
        $runnable = $printed.Replace("<commit-of-the-bundle-update>", $updateSha) -replace '^pwsh ', ("& '" + $pwshCmd + "' -NoProfile ")
        Push-Location $fx.Repo
        try {
            $run = Invoke-ExternalCommand { Invoke-Expression $runnable }
        } finally {
            Pop-Location
        }
        Assert-Result -Name "printed command succeeds" -Condition ($run.ExitCode -eq 0) -FailureMessage ("printed recovery failed (exit " + $run.ExitCode + "): " + $runnable + "`n" + ($run.Output -join "`n"))

        $active = @(Get-ActiveHandoffFiles -HandoffDir $fx.HandoffDir)
        Assert-Result -Name "one active handoff" -Condition ($active.Count -eq 1 -and $active[0].FullName -ne $fx.Original) -FailureMessage ("expected only the re-baselined handoff to be active, got: " + (($active | ForEach-Object { $_.Name }) -join ", "))
        $newObj = Get-Content -LiteralPath $active[0].FullName -Raw -Encoding UTF8 | ConvertFrom-Json

        Assert-Result -Name "base moved to the update" -Condition ($newObj.base_commit -eq $updateSha) -FailureMessage ("expected base_commit " + $updateSha + ", got " + $newObj.base_commit)
        Assert-Result -Name "old base recorded" -Condition ($newObj.rebaselined_from -eq $fx.Base) -FailureMessage ("expected rebaselined_from " + $fx.Base + ", got " + $newObj.rebaselined_from)
        Assert-Result -Name "no handoff spent" -Condition ([int]$newObj.cumulative_handoff_count -eq 5) -FailureMessage ("expected cumulative_handoff_count 5, got " + $newObj.cumulative_handoff_count)
        foreach ($field in @("source_phase", "target_phase", "reason", "review_strike_count", "rebase_count", "handoff_retry_count", "budget_tier", "session_cycle_id", "prompt_version")) {
            Assert-Result -Name ("carried " + $field) -Condition ([string]$newObj.$field -eq [string]$originalObj.$field) -FailureMessage ($field + " changed: '" + $originalObj.$field + "' -> '" + $newObj.$field + "'")
        }
        Assert-Result -Name "reviewer checks carried" -Condition ((@($newObj.reviewer_checks_passed) -join ",") -eq ($allChecks -join ",")) -FailureMessage ("reviewer checks changed: " + (@($newObj.reviewer_checks_passed) -join ","))

        $oldObj = Get-Content -LiteralPath $fx.Original -Raw -Encoding UTF8 | ConvertFrom-Json
        Assert-Result -Name "old handoff superseded as a rebaseline" -Condition ($oldObj.superseded -eq $true -and $oldObj.superseded_reason -eq "rebaseline" -and $oldObj.superseded_by -eq $active[0].Name) -FailureMessage ("old handoff not superseded by the new one: " + ($oldObj | ConvertTo-Json -Compress))

        # -Init's own resolution: dedupe first, then the sorted active handoff.
        Mark-DuplicateHandoffsAsSuperseded -TaskId $taskId -HandoffDir $fx.HandoffDir
        $resolved = @(Sort-HandoffFiles -Files @(Get-ActiveHandoffFiles -HandoffDir $fx.HandoffDir))
        Assert-Result -Name "-Init resolves the re-baselined handoff" -Condition ($resolved.Count -ge 1 -and $resolved[0].Name -eq $active[0].Name) -FailureMessage ("-Init would resolve: " + (($resolved | ForEach-Object { $_.Name }) -join ", "))

        $after = @(Get-IntegrityChanges -Repo $fx.Repo -Handoff $newObj)
        Assert-Result -Name "integrity passes after re-baseline" -Condition ($after.Count -eq 0) -FailureMessage ("still flagged after re-baseline: " + ($after -join ", "))

        # From the fixture root, as -Init runs it: the validator resolves the backlog from
        # the working directory, and an adopter running this suite has specs of its own.
        Push-Location $fx.Repo
        try {
            $validate = Invoke-ExternalCommand {
                & $pwshCmd -NoProfile -ExecutionPolicy Bypass -File (Join-Path $fx.Repo ".crucible/powershell/validate-handoff.ps1") -HandoffFile $active[0].FullName
            }
        } finally {
            Pop-Location
        }
        Assert-Result -Name "re-baselined handoff passes preflight validation" -Condition ($validate.ExitCode -eq 0) -FailureMessage ("validator refused it: " + ($validate.Output -join "`n"))

        # The re-baseline moves only the baseline: a framework edit committed after the
        # update is still caught.
        Add-Content -LiteralPath (Join-Path $fx.Repo ".crucible/powershell/crucible.ps1") -Value "# specialist edit" -Encoding UTF8
        Invoke-Git $fx.Repo @("commit", "-am", "specialist edit", "--quiet") | Out-Null
        $later = @(Get-IntegrityChanges -Repo $fx.Repo -Handoff $newObj)
        Assert-Result -Name "later framework edit still flagged" -Condition (($later -join "`n") -match "committed \.crucible/powershell/crucible\.ps1") -FailureMessage ("a framework edit after the re-baseline went unseen: " + ($later -join ", "))
    }

    $results += Run-Test -Name "-Rebaseline refuses anything but a forward move of the base" -Body {
        $fx = New-InFlightAdopter -Path (Join-Path $tempRoot "refuse")
        $updateSha = Add-BundleUpdate -Repo $fx.Repo

        # A commit that does not descend from the task's base: moving there would drop
        # history from the integrity diff rather than accept an update on top of it.
        Invoke-Git $fx.Repo @("checkout", "--orphan", "unrelated", "--quiet") | Out-Null
        Invoke-Git $fx.Repo @("commit", "-m", "unrelated", "--quiet") | Out-Null
        $sideSha = ([string](Invoke-Git $fx.Repo @("rev-parse", "HEAD"))).Trim()
        Invoke-Git $fx.Repo @("checkout", "master", "--quiet") | Out-Null

        $cases = @(
            @{ Name = "no -BaseCommit"; Args = @("-Rebaseline"); Expect = "needs -BaseCommit" },
            @{ Name = "unknown commit"; Args = @("-Rebaseline", "-BaseCommit", "0000000000000000000000000000000000000bad"); Expect = "does not name a commit" },
            @{ Name = "same base"; Args = @("-Rebaseline", "-BaseCommit", $fx.Base); Expect = "already based on" },
            @{ Name = "unrelated base"; Args = @("-Rebaseline", "-BaseCommit", $sideSha); Expect = "does not descend from the current base_commit" },
            @{ Name = "other handoff fields"; Args = @("-Rebaseline", "-BaseCommit", $updateSha, "-Artifacts", "README.md"); Expect = "Remove: -Artifacts" },
            @{ Name = "transition fields"; Args = @("-Rebaseline", "-BaseCommit", $updateSha, "-Source", "verification"); Expect = "" }
        )
        foreach ($case in $cases) {
            $before = @(Get-ChildItem -Path $fx.HandoffDir -Filter "*.json").Count
            $r = Invoke-Rebaseline -Repo $fx.Repo -ExtraArgs $case.Args
            $flat = ConvertTo-FlatText $r.Output
            $after = @(Get-ChildItem -Path $fx.HandoffDir -Filter "*.json").Count
            Assert-Result -Name ($case.Name + " refused") -Condition ($r.ExitCode -ne 0) -FailureMessage ($case.Name + " was accepted: " + $flat)
            Assert-Result -Name ($case.Name + " wrote nothing") -Condition ($after -eq $before) -FailureMessage ($case.Name + " wrote a handoff file")
            if ($case.Expect -ne "") {
                $expect = ConvertTo-FlatText @($case.Expect)
                Assert-Result -Name ($case.Name + " names the reason") -Condition ($flat.Contains($expect)) -FailureMessage ("expected '" + $case.Expect + "', got: " + $flat)
            }
        }

        $none = Invoke-ExternalCommand {
            & $pwshCmd -NoProfile -ExecutionPolicy Bypass -File (Join-Path $fx.Repo ".crucible/powershell/new-handoff.ps1") `
                -TaskId "F-140" -Rebaseline -BaseCommit $updateSha -ProjectRoot $fx.Repo
        }
        $noneText = ConvertTo-FlatText $none.Output
        Assert-Result -Name "no handoff refused" -Condition ($none.ExitCode -ne 0 -and $noneText.Contains("No active handoff for F 140")) -FailureMessage ("expected a no-handoff refusal, got exit " + $none.ExitCode + ": " + $noneText)
    }
} finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

$failed = @($results | Where-Object { -not $_ }).Count
if ($failed -gt 0) {
    Write-Host ("`n$failed rebaseline-handoff test(s) failed.") -ForegroundColor Red
    exit 1
}
Write-Host "`nAll rebaseline-handoff tests passed." -ForegroundColor Green
exit 0
