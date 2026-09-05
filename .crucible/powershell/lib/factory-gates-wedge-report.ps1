# The [STOP] report Crucible prints when a gate wedges a task: the recovery command and
# the guard name for each breaker code, plus the formatting around them.
#
# First piece cut out of factory-gates.ps1 (TODO item 14, step A) because it is the one
# with nothing to get wrong: data tables and pure string building, no $Context, no event
# log, no git, no filesystem. If the extraction mechanism is broken, it fails here where
# the cause is unambiguous rather than 1600 lines later.
#
# Dot-sourced by factory-gates.ps1. The $script: tables below resolve into the scope of
# whichever script began the dot-source chain, exactly as they did before the move.

$script:WEDGE_RECOVERY_BY_CODE = @{
    human_escalation = "Review the flagged external source or handoff content, make a human allow/block decision, archive the blocked record, then run: powershell.exe -ExecutionPolicy Bypass -File `".crucible/powershell/factory.ps1`" -Init -TaskId {task_id} -Recover"
    handoff_retry_exceeded = "Follow docs/circuit-breaker-runbook.md section 'Breaker 3 - Handoff Retry Limit', archive the blocked record, then run: powershell.exe -ExecutionPolicy Bypass -File `".crucible/powershell/factory.ps1`" -Init -TaskId {task_id} -Recover"
    review_stalemate = "Follow docs/circuit-breaker-runbook.md section 'Breaker 1 - Review Stalemate (3-Strike Rule)', archive the blocked record, then run: powershell.exe -ExecutionPolicy Bypass -File `".crucible/powershell/factory.ps1`" -Init -TaskId {task_id} -Recover"
    budget_exceeded = "Approve a budget_tier escalation, reduce scope, or abandon per docs/circuit-breaker-runbook.md section 'Breaker 4 - Token Budget Exceeded'; after the human decision, run: powershell.exe -ExecutionPolicy Bypass -File `".crucible/powershell/factory.ps1`" -Init -TaskId {task_id} -Recover"
    recurring_merge_conflicts = "Follow docs/circuit-breaker-runbook.md section 'Breaker 7 - Recurring Merge Conflicts', archive the blocked record, then run: powershell.exe -ExecutionPolicy Bypass -File `".crucible/powershell/factory.ps1`" -Init -TaskId {task_id} -Recover"
    reviewer_verification_failed = "Follow docs/circuit-breaker-runbook.md section 'Breaker 5 - Reviewer Verification Failure'; route the exact failing check back to Reviewer or Architect, then run: powershell.exe -ExecutionPolicy Bypass -File `".crucible/powershell/factory.ps1`" -Init -TaskId {task_id} -Recover"
    unreadable_handoff_history = "Follow docs/circuit-breaker-runbook.md section 'Breaker 13 - Unverifiable Handoff Count'; repair or archive the malformed pipeline-log lines so the server-side count can be recomputed, then run: powershell.exe -ExecutionPolicy Bypass -File `".crucible/powershell/factory.ps1`" -Init -TaskId {task_id} -Recover"
    unreadable_retry_history = "Follow docs/circuit-breaker-runbook.md section 'Breaker 12 - Unreadable Retry History'; read the pipeline log, repair or archive the malformed lines named in the blocked record, then run: powershell.exe -ExecutionPolicy Bypass -File `".crucible/powershell/factory.ps1`" -Init -TaskId {task_id} -Recover"
    git_hook_bypass = "Follow docs/circuit-breaker-runbook.md section 'Breaker 8 - Git Hook Bypass Attempt'; fix the hook failure without bypassing hooks, then run: powershell.exe -ExecutionPolicy Bypass -File `".crucible/powershell/factory.ps1`" -Init -TaskId {task_id} -Recover"
    fabricated_artifacts = "Follow docs/circuit-breaker-runbook.md section 'Breaker 6 - Fabricated Artifacts'; create the missing artifact or correct the handoff JSON, then run: powershell.exe -ExecutionPolicy Bypass -File `".crucible/powershell/factory.ps1`" -Init -TaskId {task_id}"
    scope_violation = "Follow docs/circuit-breaker-runbook.md section 'Breaker 9 - Scope Boundary Violation'; expand file_affinity or revert out-of-scope edits, then run: powershell.exe -ExecutionPolicy Bypass -File `".crucible/powershell/factory.ps1`" -Init -TaskId {task_id} -Recover"
    artifact_verification_failed = "Inspect completion artifacts and gate decision state, correct the artifact or decision record, then run: powershell.exe -ExecutionPolicy Bypass -File `".crucible/powershell/factory.ps1`" -Init -TaskId {task_id} -Recover"
    missing_isolated_checks_script = "Restore powershell/run-isolated-checks.ps1 from the Crucible bundle, then rerun: powershell.exe -ExecutionPolicy Bypass -File `".crucible/powershell/factory.ps1`" -Init -TaskId {task_id}"
    missing_required_field = "Correct the handoff JSON to include the required field, then rerun: powershell.exe -ExecutionPolicy Bypass -File `".crucible/powershell/factory.ps1`" -Init -TaskId {task_id}"
    invalid_field = "Correct the invalid handoff field according to schemas/handoff.schema.json, then rerun: powershell.exe -ExecutionPolicy Bypass -File `".crucible/powershell/factory.ps1`" -Init -TaskId {task_id}"
    invalid_json = "Fix the handoff JSON syntax or restore the schema file, then rerun: powershell.exe -ExecutionPolicy Bypass -File `".crucible/powershell/factory.ps1`" -Init -TaskId {task_id}"
    invalid_transition = "Correct source_phase and target_phase to an allowed pipeline transition, then rerun: powershell.exe -ExecutionPolicy Bypass -File `".crucible/powershell/factory.ps1`" -Init -TaskId {task_id}"
    invalid_budget_tier = "Set budget_tier to one of: low, medium, high, extended; then rerun: powershell.exe -ExecutionPolicy Bypass -File `".crucible/powershell/factory.ps1`" -Init -TaskId {task_id}"
    budget_tier_mismatch = "Make the handoff budget_tier match the spec frontmatter, then rerun: powershell.exe -ExecutionPolicy Bypass -File `".crucible/powershell/factory.ps1`" -Init -TaskId {task_id}"
    missing_artifact = "Create the missing artifact or correct the handoff artifact path, then rerun: powershell.exe -ExecutionPolicy Bypass -File `".crucible/powershell/factory.ps1`" -Init -TaskId {task_id}"
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
        [AllowEmptyString()][string]$RecoveryOverride = ""
    )

    if (-not [string]::IsNullOrWhiteSpace($RecoveryOverride)) {
        return $RecoveryOverride
    }

    $code = ""
    if ($null -ne $BreakerCode) {
        $code = $BreakerCode.Trim()
    }

    $recovery = ""
    if (-not [string]::IsNullOrWhiteSpace($code) -and $script:WEDGE_RECOVERY_BY_CODE.ContainsKey($code)) {
        $recovery = [string]$script:WEDGE_RECOVERY_BY_CODE[$code]
    } else {
        $recovery = "No automated recovery is defined. Read docs/circuit-breaker-runbook.md and choose a human resolution before rerunning factory.ps1."
    }

    $replacementTaskId = "{task_id}"
    if (-not [string]::IsNullOrWhiteSpace($TaskId)) {
        $replacementTaskId = $TaskId
    }
    return $recovery.Replace("{task_id}", $replacementTaskId)
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
        return "Factory Gate"
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
        [AllowEmptyString()][string]$RecoveryOverride = ""
    )

    $guardName = Get-WedgeBreakerName -BreakerCode $BreakerCode
    $recovery = Get-WedgeRecovery -BreakerCode $BreakerCode -TaskId $TaskId -RecoveryOverride $RecoveryOverride
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
        [AllowEmptyString()][string]$RecoveryOverride = ""
    )

    $lines = Get-WedgeReportLines -TaskId $TaskId -SourcePhase $SourcePhase -TargetPhase $TargetPhase -BreakerCode $BreakerCode -Why $Why -RecoveryOverride $RecoveryOverride
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
