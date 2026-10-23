# The [STOP] report Crucible prints when a gate wedges a task: the recovery command and
# the guard name for each breaker code, plus the formatting around them.
#
# Keep recovery tables and formatting independent of gate side effects. Item 14.
# Dot-sourcing places the $script: tables in the script that began the load chain.
#
# Each recovery is the human step in prose and whether the re-run passes -Recover; the
# re-run itself comes from New-CrucibleCommand, bound to crucible.ps1. Item 247.

. (Join-Path $PSScriptRoot "crucible-command.ps1")

$script:WEDGE_RECOVERY_BY_CODE = @{
    human_escalation = @{ Recover = $true; Text = "Review the flagged external source or handoff content, make a human allow/block decision, archive the blocked record, then run:" }
    handoff_retry_exceeded = @{ Recover = $true; Text = "Follow docs/circuit-breaker-runbook.md section 'Breaker 3 - Handoff Retry Limit', archive the blocked record, then run:" }
    review_stalemate = @{ Recover = $true; Text = "Follow docs/circuit-breaker-runbook.md section 'Breaker 1 - Review Stalemate (3-Strike Rule)', archive the blocked record, then run:" }
    budget_exceeded = @{ Recover = $true; Text = "Approve a budget_tier escalation, reduce scope, or abandon per docs/circuit-breaker-runbook.md section 'Breaker 4 - Token Budget Exceeded'; after the human decision, run:" }
    recurring_merge_conflicts = @{ Recover = $true; Text = "Follow docs/circuit-breaker-runbook.md section 'Breaker 7 - Recurring Merge Conflicts', archive the blocked record, then run:" }
    reviewer_verification_failed = @{ Recover = $true; Text = "Follow docs/circuit-breaker-runbook.md section 'Breaker 5 - Reviewer Verification Failure'; route the exact failing check back to Reviewer or Architect, then run:" }
    unreadable_handoff_history = @{ Recover = $true; Text = "Follow docs/circuit-breaker-runbook.md section 'Breaker 13 - Unverifiable Handoff Count'; repair or archive the malformed pipeline-log lines so the server-side count can be recomputed, then run:" }
    unreadable_retry_history = @{ Recover = $true; Text = "Follow docs/circuit-breaker-runbook.md section 'Breaker 12 - Unreadable Retry History'; read the pipeline log, repair or archive the malformed lines named in the blocked record, then run:" }
    git_hook_bypass = @{ Recover = $true; Text = "Follow docs/circuit-breaker-runbook.md section 'Breaker 8 - Git Hook Bypass Attempt'; fix the hook failure without bypassing hooks, then run:" }
    fabricated_artifacts = @{ Recover = $false; Text = "Follow docs/circuit-breaker-runbook.md section 'Breaker 6 - Fabricated Artifacts'; create the missing artifact or correct the handoff JSON, then run:" }
    scope_violation = @{ Recover = $true; Text = "Follow docs/circuit-breaker-runbook.md section 'Breaker 9 - Scope Boundary Violation'; expand file_affinity or revert out-of-scope edits, then run:" }
    artifact_verification_failed = @{ Recover = $true; Text = "Inspect completion artifacts and gate decision state, correct the artifact or decision record, then run:" }
    missing_isolated_checks_script = @{ Recover = $false; Text = "Restore powershell/run-isolated-checks.ps1 from the Crucible bundle, then rerun:" }
    uncommitted_task_worktree = @{ Recover = $false; Text = "Commit the listed changes on task/{task_id} in its worktree, or discard them, so the independent checks test what the merge ships, then rerun:" }
    missing_required_field = @{ Recover = $false; Text = "Correct the handoff JSON to include the required field, then rerun:" }
    invalid_field = @{ Recover = $false; Text = "Correct the invalid handoff field according to schemas/handoff.schema.json, then rerun:" }
    invalid_json = @{ Recover = $false; Text = "Fix the handoff JSON syntax or restore the schema file, then rerun:" }
    invalid_transition = @{ Recover = $false; Text = "Correct source_phase and target_phase to an allowed pipeline transition, then rerun:" }
    invalid_budget_tier = @{ Recover = $false; Text = "Set budget_tier to one of: low, medium, high, extended; then rerun:" }
    budget_tier_mismatch = @{ Recover = $false; Text = "Make the handoff budget_tier match the spec frontmatter, then rerun:" }
    missing_artifact = @{ Recover = $false; Text = "Create the missing artifact or correct the handoff artifact path, then rerun:" }
}

$script:WEDGE_GUARD_NAME_BY_CODE = @{
    human_escalation = "Human Escalation"
    handoff_retry_exceeded = "Handoff Retry Limit"
    review_stalemate = "Review Stalemate"
    budget_exceeded = "Token Budget Enforcement"
    recurring_merge_conflicts = "Recurring Merge Conflicts"
    reviewer_verification_failed = "Reviewer Verification Failure"
    unreadable_retry_history = "Retry History Integrity"
    unreadable_handoff_history = "Token Budget Enforcement"
    git_hook_bypass = "Git Hook Bypass Prevention"
    fabricated_artifacts = "Artifact Integrity Gate"
    scope_violation = "Scope Boundary Gate"
    artifact_verification_failed = "Completion Artifact Verification"
    missing_isolated_checks_script = "Isolated Checks Script Required"
    uncommitted_task_worktree = "Independent Verification"
    missing_required_field = "Preflight Validation"
    invalid_field = "Preflight Validation"
    invalid_json = "Preflight Validation"
    invalid_transition = "Preflight Validation"
    invalid_budget_tier = "Budget Tier Validation"
    budget_tier_mismatch = "Budget Tier Validation"
    missing_artifact = "Preflight Validation"
}

function Get-WedgeRecoveryCodes {
    return [string[]]($script:WEDGE_RECOVERY_BY_CODE.Keys | Sort-Object)
}

function Get-WedgeGuardNameCodes {
    return [string[]]($script:WEDGE_GUARD_NAME_BY_CODE.Keys | Sort-Object)
}

function Get-WedgeRecovery {
    param(
        [Parameter(Mandatory=$true)][AllowEmptyString()][string]$BreakerCode,
        [AllowEmptyString()][string]$TaskId = "",
        [AllowEmptyString()][string]$RecoveryOverride = "",
        [AllowEmptyString()][string]$ProjectRoot = ""
    )

    $code = ""
    if ($null -ne $BreakerCode) {
        $code = $BreakerCode.Trim()
    }

    $replacementTaskId = if ([string]::IsNullOrWhiteSpace($TaskId)) { "{task_id}" } else { $TaskId }
    $replacementProjectRoot = if ([string]::IsNullOrWhiteSpace($ProjectRoot)) { "{project_root}" } else { $ProjectRoot }

    if (-not [string]::IsNullOrWhiteSpace($RecoveryOverride)) {
        # Call sites build their re-run with the real root (item 247). An override that still
        # carries the placeholder gets the root too, or a re-run from the framework checkout
        # resolves the wrong tree (items 119, 126). Only a quoted placeholder, the argument of a
        # command, is filled, and with the root as a quoted literal, never spliced inside quotes
        # that would expand it.
        $recovery = $RecoveryOverride.Replace("{task_id}", $replacementTaskId)
        if ($replacementProjectRoot -ne "{project_root}" -and $recovery.Contains("{project_root}")) {
            try {
                $literal = Format-CrucibleCommandValue -Name "ProjectRoot" -Value $replacementProjectRoot
                foreach ($quoted in @('"{project_root}"', "'{project_root}'")) { $recovery = $recovery.Replace($quoted, $literal) }
            } catch {
                $recovery += (" # (command unavailable: " + (($_.Exception.Message -replace '^New-CrucibleCommand: ', '') -replace '[\r\n]+', ' ') + ")")
            }
        }
        return $recovery
    }
    if (-not [string]::IsNullOrWhiteSpace($code) -and $script:WEDGE_RECOVERY_BY_CODE.ContainsKey($code)) {
        $entry = $script:WEDGE_RECOVERY_BY_CODE[$code]
        $rerunParameters = [ordered]@{ Init = $true; TaskId = $replacementTaskId; ProjectRoot = $replacementProjectRoot }
        if ($entry.Recover) { $rerunParameters["Recover"] = $true }
        $rerun = New-CrucibleCommand -Script "powershell/crucible.ps1" -Transport PowerShell -Parameters $rerunParameters -CrucibleRoot (Get-CrucibleCommandRoot -ProjectRoot $ProjectRoot)
        return ([string]$entry.Text).Replace("{task_id}", $replacementTaskId) + " " + $rerun
    }
    return "No automated recovery is defined. Read docs/circuit-breaker-runbook.md and choose a human resolution before rerunning crucible.ps1."
}

function Get-WedgeBreakerName {
    param([Parameter(Mandatory=$true)][AllowEmptyString()][string]$BreakerCode)

    $code = ""
    if ($null -ne $BreakerCode) {
        $code = $BreakerCode.Trim()
    }
    if (-not [string]::IsNullOrWhiteSpace($code) -and $script:WEDGE_GUARD_NAME_BY_CODE.ContainsKey($code)) {
        return [string]$script:WEDGE_GUARD_NAME_BY_CODE[$code]
    }
    if ([string]::IsNullOrWhiteSpace($code)) {
        return "Crucible Gate"
    }
    return ($code -replace "_", " ")
}

function Get-WedgeReportLines {
    param(
        [Parameter(Mandatory=$true)][AllowEmptyString()][string]$TaskId,
        [Parameter(Mandatory=$true)][AllowEmptyString()][string]$SourcePhase,
        [Parameter(Mandatory=$true)][AllowEmptyString()][string]$TargetPhase,
        [Parameter(Mandatory=$true)][AllowEmptyString()][string]$BreakerCode,
        [Parameter(Mandatory=$true)][AllowEmptyString()][string]$Why,
        [AllowEmptyString()][string]$RecoveryOverride = "",
        [AllowEmptyString()][string]$ProjectRoot = ""
    )

    $guardName = Get-WedgeBreakerName -BreakerCode $BreakerCode
    $recovery = Get-WedgeRecovery -BreakerCode $BreakerCode -TaskId $TaskId -RecoveryOverride $RecoveryOverride -ProjectRoot $ProjectRoot
    $whyLine = $Why
    if ([string]::IsNullOrWhiteSpace($whyLine)) {
        $whyLine = "No reason supplied."
    }
    $whyLine = $whyLine -replace '[\r\n]+', ' '
    $recovery = $recovery -replace '[\r\n]+', ' '

    return @(
        "",
        "[STOP] HUMAN INTERVENTION REQUIRED",
        ("TASK:     " + $TaskId),
        ("PHASE:    " + $SourcePhase + " -> " + $TargetPhase),
        ("HALTED BY: " + $guardName + " (" + $BreakerCode + ")"),
        ("WHY:      " + $whyLine),
        ("RECOVERY: " + $recovery)
    )
}

function Write-WedgeReport {
    param(
        [Parameter(Mandatory=$true)][AllowEmptyString()][string]$TaskId,
        [Parameter(Mandatory=$true)][AllowEmptyString()][string]$SourcePhase,
        [Parameter(Mandatory=$true)][AllowEmptyString()][string]$TargetPhase,
        [Parameter(Mandatory=$true)][AllowEmptyString()][string]$BreakerCode,
        [Parameter(Mandatory=$true)][AllowEmptyString()][string]$Why,
        [AllowEmptyString()][string]$RecoveryOverride = "",
        [AllowEmptyString()][string]$ProjectRoot = ""
    )

    $lines = Get-WedgeReportLines -TaskId $TaskId -SourcePhase $SourcePhase -TargetPhase $TargetPhase -BreakerCode $BreakerCode -Why $Why -RecoveryOverride $RecoveryOverride -ProjectRoot $ProjectRoot
    foreach ($line in $lines) {
        if ($line -match "^\[STOP\]") {
            Write-Host $line -ForegroundColor Red
        } elseif ($line -match "^RECOVERY:") {
            Write-Host $line -ForegroundColor Cyan
        } else {
            Write-Host $line -ForegroundColor Yellow
        }
    }
}
