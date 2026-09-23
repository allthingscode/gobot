# Tests for the [STOP] wedge report library: the guard name and recovery command Crucible
# prints when a circuit breaker halts a task.
#
# TODO item 100. Get-WedgeBreakerName's empty-code fallback ("Crucible Gate", renamed from
# "Factory Gate" by item 51b on inspection alone) had no test at all, and this library had no
# test file at all before this one. Dot-sourced directly rather than through crucible-lib.ps1,
# because the library's own header states it has nothing to get wrong outside itself: no
# $Context, no event log, no git, no filesystem.

$ErrorActionPreference = "Stop"
$REPO_ROOT = (Resolve-Path -Path "$PSScriptRoot/../..").Path
. (Join-Path $PSScriptRoot '_harness.ps1')
. (Join-Path $REPO_ROOT "powershell/lib/crucible-gates-wedge-report.ps1")

$results = @()

$results += Run-Test -Name "Get-WedgeBreakerName maps every known code through the guard-name table" -Body {
    $knownCodes = @(Get-WedgeGuardNameCodes)
    Assert-Result -Name "at least one known guard-name code exists" -Condition ($knownCodes.Count -gt 0) -FailureMessage "Get-WedgeGuardNameCodes returned nothing, so the loop below would prove nothing"

    $mismatches = @()
    foreach ($code in $knownCodes) {
        $expected = [string]$script:WEDGE_GUARD_NAME_BY_CODE[$code]
        $actual = Get-WedgeBreakerName -BreakerCode $code
        if ($actual -cne $expected) {
            $mismatches += ($code + ": expected '" + $expected + "', got '" + $actual + "'")
        }
    }
    Assert-Result -Name "every known code returns its table entry" -Condition ($mismatches.Count -eq 0) -FailureMessage ("mismatched guard names: " + ($mismatches -join "; "))
}

$results += Run-Test -Name "Get-WedgeBreakerName falls back to the literal 'Crucible Gate' for an empty or whitespace code" -Body {
    foreach ($code in @("", "   ", "`t")) {
        $actual = Get-WedgeBreakerName -BreakerCode $code
        Assert-Result -Name ("empty-ish code (length " + $code.Length + ") falls back to Crucible Gate") -Condition ($actual -ceq "Crucible Gate") -FailureMessage ("expected the fallback literal 'Crucible Gate', got '" + $actual + "'")
    }
}

$results += Run-Test -Name "Get-WedgeBreakerName humanizes an unknown non-empty code" -Body {
    $actual = Get-WedgeBreakerName -BreakerCode "some_unknown_breaker"
    Assert-Result -Name "unknown code replaces underscores with spaces" -Condition ($actual -ceq "some unknown breaker") -FailureMessage ("expected 'some unknown breaker', got '" + $actual + "'")
}

$results += Run-Test -Name "Get-WedgeReportLines assembles the STOP report with guard name, phases and recovery" -Body {
    $lines = Get-WedgeReportLines -TaskId "F-042" -SourcePhase "implementer" -TargetPhase "reviewer" -BreakerCode "scope_violation" -Why "touched a file outside file_affinity"
    Assert-Result -Name "report has content" -Condition ($lines.Count -gt 0) -FailureMessage "Get-WedgeReportLines returned nothing"

    $joined = $lines -join "`n"
    Assert-Result -Name "STOP banner present" -Condition ($joined -match "\[STOP\] HUMAN INTERVENTION REQUIRED") -FailureMessage "STOP banner missing. Lines:`n$joined"
    Assert-Result -Name "task id present" -Condition ($joined -match "TASK:\s+F-042") -FailureMessage "task id line missing. Lines:`n$joined"
    Assert-Result -Name "phase transition present" -Condition ($joined -match "PHASE:\s+implementer -> reviewer") -FailureMessage "phase line missing. Lines:`n$joined"
    Assert-Result -Name "guard name and code present" -Condition ($joined -match "HALTED BY: Scope Boundary Gate \(scope_violation\)") -FailureMessage "guard name/code line missing. Lines:`n$joined"
    Assert-Result -Name "why text present" -Condition ($joined -match "WHY:\s+touched a file outside file_affinity") -FailureMessage "why line missing. Lines:`n$joined"
    Assert-Result -Name "recovery text present" -Condition ($joined -match "RECOVERY:\s+Follow docs/circuit-breaker-runbook.md section 'Breaker 9") -FailureMessage "recovery line missing. Lines:`n$joined"
}

$results += Run-Test -Name "Get-WedgeReportLines defaults a blank Why to 'No reason supplied.'" -Body {
    $lines = Get-WedgeReportLines -TaskId "F-001" -SourcePhase "a" -TargetPhase "b" -BreakerCode "budget_exceeded" -Why "   "
    $joined = $lines -join "`n"
    Assert-Result -Name "blank why defaults to No reason supplied" -Condition ($joined -match "WHY:\s+No reason supplied\.") -FailureMessage "blank Why did not default. Lines:`n$joined"
}

$results += Run-Test -Name "Get-WedgeReportLines collapses embedded newlines in Why and a recovery override" -Body {
    $lines = Get-WedgeReportLines -TaskId "F-001" -SourcePhase "a" -TargetPhase "b" -BreakerCode "budget_exceeded" -Why "line one`nline two" -RecoveryOverride "step one`r`nstep two"
    $joined = $lines -join "`n"
    Assert-Result -Name "why newline collapsed to a space" -Condition ($joined -match "WHY:\s+line one line two") -FailureMessage "embedded newline in Why survived into the report. Lines:`n$joined"
    Assert-Result -Name "recovery override newline collapsed to a space" -Condition ($joined -match "RECOVERY:\s+step one step two") -FailureMessage "embedded newline in RecoveryOverride survived into the report. Lines:`n$joined"
}

# TODO item 126. A re-run command without -ProjectRoot inits whichever tree the shell is in,
# which from the framework checkout is the wrong one (item 119). The table cannot know the
# root, so it carries a placeholder the report fills in; these pin that it is filled in.
$results += Run-Test -Name "Every recovery that re-runs Init carries the supplied -ProjectRoot" -Body {
    $root = "C:/work/adopter"
    $codes = @(Get-WedgeRecoveryCodes)
    Assert-Result -Name "at least one recovery code exists" -Condition ($codes.Count -gt 0) -FailureMessage "Get-WedgeRecoveryCodes returned nothing, so the loop below would prove nothing"

    $rerunCount = 0
    $missing = @()
    foreach ($code in $codes) {
        $recovery = Get-WedgeRecovery -BreakerCode $code -TaskId "F-126" -ProjectRoot $root
        if ($recovery -notmatch 'crucible\.ps1"? -Init') { continue }
        $rerunCount++
        if (-not $recovery.Contains('-ProjectRoot "' + $root + '"') -or $recovery.Contains("{project_root}")) {
            $missing += ($code + ": " + $recovery)
        }
    }
    Assert-Result -Name "recovery table has Init re-run commands to check" -Condition ($rerunCount -gt 0) -FailureMessage "no recovery re-runs crucible.ps1 -Init, so this test checks nothing"
    Assert-Result -Name "each Init re-run passes the supplied root" -Condition ($missing.Count -eq 0) -FailureMessage ("re-run commands without the supplied -ProjectRoot:`n" + ($missing -join "`n"))
}

$results += Run-Test -Name "A recovery override gets the same -ProjectRoot substitution as a table entry" -Body {
    $override = 'Fix it, then run: crucible.ps1 -Init -TaskId F-126 -ProjectRoot "{project_root}" -Recover'
    $lines = Get-WedgeReportLines -TaskId "F-126" -SourcePhase "a" -TargetPhase "b" -BreakerCode "human_escalation" -Why "x" -RecoveryOverride $override -ProjectRoot "C:/work/adopter"
    $joined = $lines -join "`n"
    Assert-Result -Name "override root substituted" -Condition ($joined.Contains('-ProjectRoot "C:/work/adopter" -Recover')) -FailureMessage "override kept its placeholder or lost the root. Lines:`n$joined"
}

$results += Run-Test -Name "A blank ProjectRoot leaves the placeholder visible rather than an empty root" -Body {
    $recovery = Get-WedgeRecovery -BreakerCode "scope_violation" -TaskId "F-126"
    Assert-Result -Name "placeholder kept" -Condition ($recovery.Contains('-ProjectRoot "{project_root}"')) -FailureMessage ("expected the {project_root} placeholder, as {task_id} is kept for a blank TaskId. Got: " + $recovery)
    Assert-Result -Name "no empty root" -Condition (-not $recovery.Contains('-ProjectRoot ""')) -FailureMessage ("an empty -ProjectRoot resolves the current directory, which is the defect. Got: " + $recovery)
}
$failed = @($results | Where-Object { -not $_ }).Count
if ($failed -gt 0) {
    Write-Host ("`n$failed crucible-gates-wedge-report test(s) failed.") -ForegroundColor Red
    exit 1
}
Write-Host "`nAll crucible-gates-wedge-report tests passed." -ForegroundColor Green
exit 0
