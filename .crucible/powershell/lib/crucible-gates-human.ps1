# The human gate: decision intake on both input paths, the dispatch to the accept and
# reject arms, each arm's phases, and the review surface the human is shown.
#
# Enforced here: I3 (the phase order in Invoke-HumanGateAcceptRedirect), I7 (decision
# persistence in Write-HumanGateDecision), I8 at the reject unwind
# (Get-HumanGateRejectUnwind), I12 at the Human Gate menu (Write-GatePendingSurface), and
# I11 for every refusal here, each an exit. docs/policy.md section 8.
#
# Loaded by crucible-gates.ps1. The functions it calls from that file (Move-TaskHandoffsToArchive,
# Get-ResearchMisrouteAdvisory) resolve at call time, so it is not loadable on its own.
. (Join-Path $PSScriptRoot "platform.ps1")
. (Join-Path $PSScriptRoot "git.ps1")
. (Join-Path $PSScriptRoot "crucible-context.ps1")
. (Join-Path $PSScriptRoot "backlog-io.ps1")
. (Join-Path $PSScriptRoot "worktree.ps1")
. (Join-Path $PSScriptRoot "crucible-gates-wedge-report.ps1")
. (Join-Path $PSScriptRoot "checks-not-run.ps1")

function Invoke-HumanGateMerge {
    # Merges task/$TaskId into $PrimaryBranch at the accept gate. A clean merge returns
    # "merged". On conflict it NEVER leaves the tree mid-merge: it aborts, then attempts
    # to auto-rebase the task branch onto the advanced primary branch inside its worktree.
    # A clean rebase (git resolved non-overlapping changes) is re-validated and the merge
    # retried -> "merged". A genuine same-line conflict cannot be resolved mechanically, so
    # the branch is left intact and the task is routed back to implementation via a
    # sanctioned re-entry handoff with rebase_count bumped -> "rework". Once rebase_count
    # would exceed MaxRebaseAttempts the recurring-conflict circuit breaker trips ->
    # "breaker". Any unexpected post-rebase failure also routes to "rework".
    param(
        [Parameter(Mandatory = $true)][string]$TaskId,
        [Parameter(Mandatory = $true)][string]$PrimaryBranch,
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        # Declare the circuit-breaker destination explicitly; dynamic scope can
        # silently misfile the operator's failure record. Item 16.
        [Parameter(Mandatory = $true)][string]$LogFile,
        [Parameter(Mandatory = $true)][string]$CircuitBreakerHistoryFile,
        $Handoff = $null,
        [int]$MaxRebaseAttempts = 3,
        [string]$CheckScript = "",
        [string]$HandoffScript = ""
    )

    if ([string]::IsNullOrEmpty($CheckScript)) {
        $CheckScript = Join-Path (Split-Path -Parent $PSScriptRoot) "run-isolated-checks.ps1"
    }
    if ([string]::IsNullOrEmpty($HandoffScript)) {
        $HandoffScript = Join-Path (Split-Path -Parent $PSScriptRoot) "new-handoff.ps1"
    }

    # Both gate inputs persist an "accepted" decision BEFORE calling this action (the
    # reject path's rework handoff depends on that ordering). When an accepted merge
    # does not complete -- it routes to rework or trips the breaker -- that premature
    # advancing record (accepted or redirected) must be removed, or the deployment->done completion guard will
    # see it on the next run and block the retry (commit not merged into primary).
    $removePrematureAccept = {
        try {
            $sessDir = Get-ConfiguredPath -Key "session" -ProjectRoot $ProjectRoot
            $gdDir = Join-Path $sessDir "global/gate_decisions"
            if (Test-Path -LiteralPath $gdDir -ErrorAction Stop) {
                $candidates = @(Get-ChildItem -LiteralPath $gdDir -Filter ($TaskId + "-*.json") -ErrorAction Stop |
                    Sort-Object LastWriteTime -Descending)
                foreach ($f in $candidates) {
                    try {
                        $d = Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json
                    } catch {
                        Write-Quiet "[HUMAN GATE] Warning: Could not inspect gate decision $($f.Name) while removing premature acceptance: $($_.Exception.Message)" -ForegroundColor Yellow
                        continue
                    }
                    if ($d.outcome -in @("accepted", "redirected")) {
                        try {
                            Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop
                        } catch {
                            throw ("Could not inspect or remove premature accepted gate decisions before returning the merge outcome: " + $_.Exception.Message)
                        }
                        Write-Quiet "[HUMAN GATE] Removed premature '$($d.outcome)' gate decision $($f.Name) (merge did not complete)."
                        break
                    }
                }
            }
        } catch {
            throw ("Could not inspect or remove premature accepted gate decisions before returning the merge outcome: " + $_.Exception.Message)
        }
    }

    if (-not (Test-GitDiscardSafe -Directory $ProjectRoot -Operation "human gate merge and abort" -IncludeUntracked:$false)) {
        try { & $removePrematureAccept } catch { Write-Host $_.Exception.Message -ForegroundColor Red }
        exit 2
    }
    Write-Quiet "[HUMAN GATE] Merging branch task/$TaskId into $PrimaryBranch..."
    Invoke-GitChecked { git checkout $PrimaryBranch } | Out-Null
    Invoke-GitChecked { git merge --no-ff --no-edit "task/$TaskId" } | Out-Null
    if ($LASTEXITCODE -eq 0) {
        return "merged"
    }

    # Conflict: restore the tree first so the adopter is never left mid-merge.
    Write-Host "[HUMAN GATE] task/$TaskId conflicts with $PrimaryBranch; aborting merge and attempting auto-rebase..." -ForegroundColor Yellow
    Invoke-GitChecked { git merge --abort } | Out-Null

    $currentRebase = 0
    if ($null -ne $Handoff -and $Handoff.PSObject.Properties["rebase_count"]) {
        $currentRebase = [int]$Handoff.rebase_count
    }
    $nextRebase = $currentRebase + 1

    if ($nextRebase -gt $MaxRebaseAttempts) {
        Write-EventLog -Event "circuit_breaker" -TaskId $TaskId -Specialist "deployment" -Outcome "blocked" -Notes "Recurring Merge Conflicts - $MaxRebaseAttempts strikes at human gate" `
            -LogFile $LogFile -CircuitBreakerHistoryFile $CircuitBreakerHistoryFile
        if (Get-Command Write-BlockedTaskRecord -ErrorAction SilentlyContinue) {
            Write-BlockedTaskRecord -TaskId $TaskId -CircuitBreaker "recurring_merge_conflicts" -AttemptCount $currentRebase -LastSpecialist "deployment" -Summary "Recurring Merge Conflicts at human gate. Manual conflict resolution required."
        }
        Write-WedgeReport -TaskId $TaskId -ProjectRoot $ProjectRoot -SourcePhase "deployment" -TargetPhase "deployment" -BreakerCode "recurring_merge_conflicts" `
            -Why "Recurring Merge Conflicts: task/$TaskId rebased $currentRebase time(s) and still conflicts with $PrimaryBranch. Reduce scope or resolve the conflict manually."
        & $removePrematureAccept
        return "breaker"
    }

    $workspacesDir = Get-ConfiguredPath -Key "workspaces" -ProjectRoot $ProjectRoot
    $wtPath = Resolve-ImplementationWorktreePath -TaskId $TaskId -WorkspacesDir $workspacesDir

    $rebaseClean = $false
    if (Test-Path $wtPath) {
        if (-not (Test-GitDiscardSafe -Directory $wtPath -Operation "task rebase and abort" -IncludeUntracked:$false)) {
            try { & $removePrematureAccept } catch { Write-Host $_.Exception.Message -ForegroundColor Red }
            exit 2
        }
        Write-Quiet "[HUMAN GATE] Rebasing task/$TaskId onto $PrimaryBranch in $wtPath..."
        $rebaseRes = Invoke-Git -Directory $wtPath rebase $PrimaryBranch
        foreach ($line in $rebaseRes.Lines) { Write-Quiet $line }
        if ($rebaseRes.ExitCode -eq 0) {
            $rebaseClean = $true
        } else {
            Invoke-Git -Directory $wtPath rebase --abort | Out-Null
        }
    }

    if ($rebaseClean) {
        Write-Quiet "[HUMAN GATE] Auto-rebase clean; re-running isolated checks before merge..."
        $checksOk = $true
        if (Test-Path $CheckScript) {
            & (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $CheckScript -TaskId $TaskId -Mode full -ProjectRoot $ProjectRoot | Out-Null
            if ($LASTEXITCODE -ne 0) { $checksOk = $false }
        }
        if ($checksOk) {
            Invoke-GitChecked { git checkout $PrimaryBranch } | Out-Null
            Invoke-GitChecked { git merge --no-ff --no-edit "task/$TaskId" } | Out-Null
            if ($LASTEXITCODE -eq 0) {
                Write-Quiet "[HUMAN GATE] Auto-rebase resolved the conflict; merge succeeded."
                return "merged"
            }
            Invoke-GitChecked { git merge --abort } | Out-Null
            Write-Host "[HUMAN GATE] Post-rebase merge still failed unexpectedly; routing to rework." -ForegroundColor Yellow
        } else {
            Write-Host "[HUMAN GATE] Isolated checks failed after rebase; routing to rework." -ForegroundColor Yellow
        }
    }

    # Genuine conflict (or post-rebase failure): route back to implementation for a
    # specialist to rebase and resolve. Leave $PrimaryBranch clean and unpushed.
    Invoke-GitChecked { git checkout $PrimaryBranch } | Out-Null
    $reason = "Rebase conflict: task/$TaskId no longer applies cleanly onto $PrimaryBranch (rebase attempt $nextRebase/$MaxRebaseAttempts). Rebase onto $PrimaryBranch in the worktree, resolve conflicts, and re-run the pipeline."
    Write-Host "[HUMAN GATE] $reason" -ForegroundColor Yellow

    if (-not (Test-Path $wtPath)) {
        Invoke-GitChecked { git worktree prune } | Out-Null
        Invoke-GitChecked { git worktree add $wtPath "task/$TaskId" } | Out-Null
    }

    if (Test-Path $HandoffScript) {
        $sessionCycleId = ""
        $artifacts = @()
        if ($null -ne $Handoff) {
            if ($Handoff.PSObject.Properties["session_cycle_id"]) {
                $sessionCycleId = $Handoff.session_cycle_id
            } elseif ($Handoff.PSObject.Properties["cycle_id"]) {
                $sessionCycleId = $Handoff.cycle_id
            }
            if ($Handoff.PSObject.Properties["artifacts"]) {
                $artifacts = $Handoff.artifacts
            }
        }
        $handoffParams = @{
            TaskId      = $TaskId
            Source      = "deployment"
            Target      = "implementation"
            Reason      = $reason
            RebaseCount = $nextRebase
            ProjectRoot = $ProjectRoot
        }
        if (-not [string]::IsNullOrEmpty($sessionCycleId)) {
            $handoffParams["SessionCycleId"] = $sessionCycleId
        }
        if ($artifacts.Count -gt 0) {
            $handoffParams["Artifacts"] = @($artifacts)
        }
        & $HandoffScript @handoffParams | Out-Null
    }
    & $removePrematureAccept
    return "rework"
}

function Get-ActionsUrlFromOriginUrl {
    # Maps a GitHub remote (SSH or HTTPS, with or without .git) to its Actions page.
    # An unrecognized remote is handed back unchanged rather than guessed at, so the
    # operator sees a real URL or the literal remote, never a fabricated one.
    param([Parameter(Mandatory=$true)][AllowEmptyString()][string]$OriginUrl)

    $originText = ([string]$OriginUrl).Trim()
    if ($originText -match '^git@github\.com:([^/]+/[^/]+?)(\.git)?$') {
        return "https://github.com/" + $Matches[1] + "/actions"
    }
    if ($originText -match '^https://github\.com/([^/]+/[^/]+?)(\.git)?/?$') {
        return "https://github.com/" + $Matches[1] + "/actions"
    }
    return $originText
}

function Write-GateCiRunUrl {
    # Emitted when CI could not be confirmed before finalizing, so the human has a
    # place to go and check. A missing or unreadable origin is not worth failing the
    # gate over: the advisory is simply omitted.
    $originUrl = (git remote get-url origin 2>$null)
    if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($originUrl)) {
        Write-Host ("[HUMAN GATE] CI run URL: " + (Get-ActionsUrlFromOriginUrl -OriginUrl $originUrl)) -ForegroundColor Yellow
    }
}

function Get-HumanGateOutcomes {
    # The one list. Invoke-HumanGate validates -GateOutcome against it and
    # Invoke-HumanGateAction names it when it refuses one. A second copy is how a
    # value comes to pass one check and match no dispatch arm.
    return @("accepted", "rejected", "redirected", "abandoned")
}

function Get-LowSignalGateReasons {
    # Exact phrases only, compared after trim and lowercase. A stock phrase with
    # more words ("Looks good. I see nothing concerning.") is the human's reason
    # and is recorded. sops/deployment.md and prompts/deployment_prompt.md list
    # these; gate-reason-rule.tests.ps1 keeps them in step. Item 144.
    return @(
        "n/a", "na", "none", "ok", "looks good", "looks good.",
        "approved", "accept", "accepted", "done", "ship it", "auto"
    )
}

function Test-GateReasonRefused {
    param([string]$Reason)
    if ([string]::IsNullOrWhiteSpace($Reason)) { return $true }
    $normalized = (ConvertTo-AsciiSafeText -Text $Reason).Trim().ToLowerInvariant()
    if ($normalized -eq "") { return $true }
    return ((Get-LowSignalGateReasons) -contains $normalized)
}

function Assert-GateReason {
    # TODO item 192: check both input paths before recording or acting on a decision.
    # A refusal names where the reason came from, so a human who filled the pending file is
    # not told to pass a CLI flag they never used.
    param([string]$Reason, [string]$DecisionFile = "")
    if (Test-GateReasonRefused -Reason $Reason) {
        $stock = (Get-LowSignalGateReasons) -join ", "
        if ([string]::IsNullOrWhiteSpace($DecisionFile)) {
            Write-Host ("Error: -GateReason is required and cannot be only a stock phrase (" + $stock + ").") -ForegroundColor Red
        } else {
            Write-Host ("Error: the `"reason`" in " + $DecisionFile + " is required and cannot be only a stock phrase (" + $stock + ").") -ForegroundColor Red
            Write-Host "       Write one concrete reason for the decision in that file, then rerun crucible.ps1. Nothing was recorded." -ForegroundColor Red
        }
        exit 1
    }
}

function Assert-HumanGateDecisionSafe {
    # Run before either intake path records reject/abandon. The action repeats the
    # guard for direct callers and immediately before the checkout/reset.
    param([string]$TaskId, [string]$Outcome, [string]$SourcePhase, [string]$ProjectRoot)
    if ($SourcePhase -eq 'grooming' -or $Outcome -notin @('rejected', 'abandoned')) { return }
    $primary = Get-ConfiguredPrimaryBranch -ProjectRoot $ProjectRoot
    $unwind = Get-HumanGateRejectUnwind -TaskId $TaskId -PrimaryBranch $primary
    $target = if ($unwind.HeadIsTaskMerge) { $unwind.UnwindTarget } else { '' }
    $null = Test-GitDiscardSafe -Directory $ProjectRoot -Operation "$Outcome decision unwind" -AllowConfiguredRuntime -IncludeUntracked:$false -ResetTarget $target -Refuse
}

function Write-HumanGateDecision {
    # Both inputs must persist the authorization before dispatch. A merge that does
    # not complete removes premature acceptance in Invoke-HumanGateMerge. I7, item 251.
    # The pending-file input's template is consumed here, before dispatch, so the archived
    # record is the only authority: an action that exits early cannot leave a filled
    # template to be replayed without a human when the gate next fires. The CLI input
    # never reads the template, so it passes none. Item 242.
    param(
        [Parameter(Mandatory=$true)][hashtable]$Context,
        [Parameter(Mandatory=$true)][psobject]$Decision,
        [Parameter(Mandatory=$true)][string]$ProjectRoot,
        [AllowEmptyString()][string]$SessionCycleId,
        [switch]$ResolveReviewRange,
        [string]$DecisionFile = "",
        [string]$PendingTemplate = ""
    )
    $archivePath = ""
    $recorded = $false
    try {
        Assert-CrucibleContextKeys -Context $Context -RequiredKeys @() -NonNullKeys @("Handoff", "SessionDir")
        if ((Get-HumanGateOutcomes) -notcontains $Decision.outcome) {
            throw ("Unrecognized gate outcome '" + $Decision.outcome + "'. Expected one of: " + ((Get-HumanGateOutcomes) -join ", ") + ".")
        }
        $reason = if ($Decision.PSObject.Properties["reason"]) { [string]$Decision.reason } else { "" }
        Assert-GateReason -Reason $reason -DecisionFile $DecisionFile
        Assert-HumanGateDecisionSafe -TaskId $Context.Handoff.task_id -Outcome $Decision.outcome `
            -SourcePhase $Context.Handoff.source_phase -ProjectRoot $ProjectRoot
        # CLI metadata is resolved only after validation. A refused reason must
        # not depend on a readable Git range. Pending templates already carry it.
        if ($ResolveReviewRange) {
            $handoff = $Context.Handoff
            $commit = if ($handoff.PSObject.Properties["commit_hash"]) { $handoff.commit_hash } else { "" }
            $range = Get-GateReviewRange -PrimaryBranch (Get-ConfiguredPrimaryBranch -ProjectRoot $ProjectRoot) `
                -TaskId $handoff.task_id -CommitHash $commit
            $Decision | Add-Member -NotePropertyName "base_sha" -NotePropertyValue $range.BaseSha -Force
            $Decision | Add-Member -NotePropertyName "branch_sha" -NotePropertyValue $range.BranchSha -Force
        }
        $fields = @{
            task_id = $Context.Handoff.task_id
            backlog_item = $Context.Handoff.task_id
            gate_fired_at = Get-UtcTimestamp
            reason = (ConvertTo-AsciiSafeText -Text $reason).Trim()
            rework_requested = ($Decision.outcome -eq "rejected")
            session_cycle_id = $SessionCycleId
        }
        foreach ($key in $fields.Keys) {
            $Decision | Add-Member -NotePropertyName $key -NotePropertyValue $fields[$key] -Force
        }
        $gateDir = Join-Path $Context.SessionDir "global/gate_decisions"
        $archivePath = Join-Path $gateDir ($Context.Handoff.task_id + "-" + (Get-UtcFileTimestamp) + ".json")
        $Decision | ConvertTo-Json | Set-Content -LiteralPath $archivePath -Encoding UTF8 -ErrorAction Stop
        $recorded = $true
        if (-not [string]::IsNullOrEmpty($PendingTemplate) -and (Test-Path -LiteralPath $PendingTemplate)) {
            Remove-Item -LiteralPath $PendingTemplate -Force -ErrorAction Stop
        }
    } catch {
        # A catch in the pending-file path or an embedding caller cannot authorize
        # the action after persistence failed. Write-Error could throw before exit.
        $message = $_.Exception.Message
        if ($recorded) {
            # Withdraw the record so the template stays the one copy of the decision and
            # a rerun retries it, rather than finding the gate passed with nothing done.
            try {
                Remove-Item -LiteralPath $archivePath -Force -ErrorAction Stop
                $message = "could not consume the pending template " + $PendingTemplate + ": " + $message + " The recorded decision was withdrawn; nothing was dispatched."
            } catch {
                $message = "could not consume the pending template " + $PendingTemplate + ": " + $message + " The recorded decision " + $archivePath + " could not be withdrawn either: " + $_.Exception.Message + " Remove both files before the gate fires again."
            }
        }
        [Console]::Error.WriteLine("Cannot record human gate decision: " + $message)
        exit 1
    }
}

function Invoke-HumanGateAction {
    param(
        [Parameter(Mandatory=$true)][string]$TaskId,
        [Parameter(Mandatory=$true)][string]$Outcome,
        # Require declared event destinations so caller scope cannot misroute or
        # suppress circuit-breaker and CI-verification records. Item 16.
        [Parameter(Mandatory=$true)][string]$LogFile,
        [Parameter(Mandatory=$true)][string]$CircuitBreakerHistoryFile,
        [string]$ProjectRoot = "",
        [string]$SourcePhase = "deployment",
        [string]$GateReason = "",
        # The handoff Invoke-HumanGate bound; passed rather than read from caller scope. Item 249.
        $Handoff = $null
    )
    $primaryBranch = Get-ConfiguredPrimaryBranch
    $resolvedProjectRoot = Resolve-ConfigProjectRoot -ProjectRoot $ProjectRoot

    if ($Outcome -eq "accepted" -or $Outcome -eq "redirected") {
        Invoke-HumanGateAcceptRedirect -TaskId $TaskId -Outcome $Outcome -LogFile $LogFile `
            -CircuitBreakerHistoryFile $CircuitBreakerHistoryFile -ProjectRoot $resolvedProjectRoot `
            -PrimaryBranch $primaryBranch -SourcePhase $SourcePhase -Handoff $Handoff
    } elseif ($Outcome -eq "rejected" -or $Outcome -eq "abandoned") {
        Invoke-HumanGateRejectAbandon -TaskId $TaskId -Outcome $Outcome -ProjectRoot $resolvedProjectRoot `
            -PrimaryBranch $primaryBranch -SourcePhase $SourcePhase -GateReason $GateReason -Handoff $Handoff
    } else {
        # Reject unknown outcomes before side effects so a typo cannot pass the gate;
        # keep the pending file for the operator to correct. Item 38.
        throw ("Unrecognized gate outcome '" + $Outcome + "'. Expected one of: " + ((Get-HumanGateOutcomes) -join ", ") + ".")
    }
}

function Invoke-HumanGateAcceptRedirect {
    # Finalize human-approved work. This function owns the order, which is I3's
    # enforcement point: merge, then backlog finalization, then publish (push and CI),
    # then worktree and branch cleanup, archival and session-state pruning. A phase that
    # refuses exits, so nothing after it runs. Item 14 step C4.
    # Event destinations are mandatory here because this arm writes events; the
    # reject/abandon arm does not need them. Item 14.
    param(
        [Parameter(Mandatory=$true)][string]$TaskId,
        [Parameter(Mandatory=$true)][string]$Outcome,
        [Parameter(Mandatory=$true)][string]$LogFile,
        [Parameter(Mandatory=$true)][string]$CircuitBreakerHistoryFile,
        [Parameter(Mandatory=$true)][string]$ProjectRoot,
        [Parameter(Mandatory=$true)][string]$PrimaryBranch,
        [string]$SourcePhase = "deployment",
        $Handoff = $null
    )

    $backlogDir = Get-ConfiguredPath -Key "backlog" -ProjectRoot $ProjectRoot
    $backlogPath = Join-Path $backlogDir "BACKLOG.md"

    # Read once, above the merge and archival, and used twice. The merge already decides whether
    # this task shipped code by asking whether it has a branch to merge; the archival needs
    # the same fact to record Production rather than Resolved, and reading it in two places
    # is how the two answers come to disagree.
    $hasTaskBranch = $false
    git show-ref --quiet "refs/heads/task/$TaskId"
    if ($LASTEXITCODE -eq 0) {
        $hasTaskBranch = $true
    }

    if ($SourcePhase -ne "grooming") {
        if ($hasTaskBranch) {
            Invoke-HumanGateAcceptMerge -TaskId $TaskId -PrimaryBranch $PrimaryBranch -ProjectRoot $ProjectRoot -Handoff $Handoff `
                -LogFile $LogFile -CircuitBreakerHistoryFile $CircuitBreakerHistoryFile
        }
    }

    # Archive only after the merge succeeded and before any push: Production means merged, and
    # a merge that routes to rework must leave the spec active. Item 222.
    # TODO item 197: keep the refusal decision here; archival returns its result.
    $finalizationOk = Invoke-HumanGateBacklogFinalization -TaskId $TaskId -ProjectRoot $ProjectRoot `
        -BacklogPath $backlogPath -HasTaskBranch $hasTaskBranch -SourcePhase $SourcePhase

    if (-not $finalizationOk) {
        try {
            Write-EventLog -Event "quality_gate_retry" -TaskId $TaskId -Phase "deployment" `
                -Outcome "retry_required" -Notes "Auto-finalization failed at human gate; push withheld" `
                -LogFile $LogFile -CircuitBreakerHistoryFile $CircuitBreakerHistoryFile
        } catch {
            Write-Host "[D44] WARNING: Failed to write quality_gate_retry event: $_" -ForegroundColor Yellow
        }
        exit 2
    }

    if ($SourcePhase -ne "grooming") {
        $acceptConfig = Get-HumanGateAcceptConfig -ProjectRoot $ProjectRoot
        $mergedSha = (git rev-parse HEAD 2>$null).Trim()

        Invoke-HumanGatePublish -TaskId $TaskId -ProjectRoot $ProjectRoot -PrimaryBranch $PrimaryBranch -Config $acceptConfig -MergedSha $mergedSha `
            -LogFile $LogFile -CircuitBreakerHistoryFile $CircuitBreakerHistoryFile

        $worktreeRemoved = Remove-ImplementationWorktree -TaskId $TaskId -ProjectRoot $ProjectRoot
        if ($hasTaskBranch -and $worktreeRemoved) {
            Write-Quiet "[HUMAN GATE] Deleting task branch task/$TaskId..."
            Invoke-GitChecked { git branch -d "task/$TaskId" }
        }
    }

    Invoke-HumanGateAcceptArchival -TaskId $TaskId -ProjectRoot $ProjectRoot
}

function Invoke-HumanGateAcceptMerge {
    # Merges the accepted task branch. Only "merged" returns; rework (3), the
    # recurring-conflict breaker (2) and a failed merge (1) exit, so finalization and
    # every later phase run only on a merge that landed (I3, item 222).
    param(
        [Parameter(Mandatory=$true)][string]$TaskId,
        [Parameter(Mandatory=$true)][string]$PrimaryBranch,
        [Parameter(Mandatory=$true)][string]$ProjectRoot,
        [Parameter(Mandatory=$true)][string]$LogFile,
        [Parameter(Mandatory=$true)][string]$CircuitBreakerHistoryFile,
        $Handoff = $null
    )

    $mergeResult = Invoke-HumanGateMerge -TaskId $TaskId -PrimaryBranch $PrimaryBranch -ProjectRoot $ProjectRoot -Handoff $Handoff `
        -LogFile $LogFile -CircuitBreakerHistoryFile $CircuitBreakerHistoryFile
    if ($mergeResult -eq "rework") {
        # Auto-rebase hit a genuine conflict; task routed back to implementation.
        # Repo is clean and unpushed. Exit 3 signals "not shipped, rework queued".
        Write-Host "[HUMAN GATE] task/$TaskId routed back to implementation for rebase-conflict rework. Nothing was pushed; re-run the pipeline to resolve." -ForegroundColor Cyan
        exit 3
    } elseif ($mergeResult -eq "breaker") {
        exit 2
    } elseif ($mergeResult -ne "merged") {
        Write-Host "[ERROR] git merge --no-ff --no-edit task/$TaskId failed!" -ForegroundColor Red
        exit 1
    }
}

function Get-HumanGateAcceptConfig {
    # The review.* settings the accept arm acts on, read once. An absent key takes
    # Get-ConfiguredReview's default; a timeout or grace that is not a non-negative
    # integer also takes it (item 252). ci_staging_branch_prefix is read by
    # Invoke-HumanGatePublish, only when it publishes a staging ref.
    param([Parameter(Mandatory=$true)][string]$ProjectRoot)

    $autoPushVal = Get-ConfiguredReview -Key "auto_push" -ProjectRoot $ProjectRoot
    $autoPush = $false
    if ($autoPushVal -eq "true") {
        $autoPush = $true
    }
    $requireGreenCiVal = Get-ConfiguredReview -Key "require_green_ci" -ProjectRoot $ProjectRoot
    $requireGreenCi = $false
    if ($requireGreenCiVal -eq "true") {
        $requireGreenCi = $true
    }
    $ciTimeoutVal = Get-ConfiguredReview -Key "ci_timeout_minutes" -ProjectRoot $ProjectRoot
    $ciTimeoutMinutes = 20
    if (-not [string]::IsNullOrWhiteSpace($ciTimeoutVal)) {
        $parsedTimeout = 0
        if ([int]::TryParse($ciTimeoutVal, [ref]$parsedTimeout) -and $parsedTimeout -ge 0) {
            $ciTimeoutMinutes = $parsedTimeout
        }
    }
    $ciQueuedGraceVal = Get-ConfiguredReview -Key "ci_queued_grace_minutes" -ProjectRoot $ProjectRoot
    $ciQueuedGraceMinutes = 15
    if (-not [string]::IsNullOrWhiteSpace($ciQueuedGraceVal)) {
        $parsedGrace = 0
        if ([int]::TryParse($ciQueuedGraceVal, [ref]$parsedGrace) -and $parsedGrace -ge 0) {
            $ciQueuedGraceMinutes = $parsedGrace
        }
    }
    $ciRequiredChecks = Get-ConfiguredReview -Key "ci_required_checks" -ProjectRoot $ProjectRoot
    $ciPostPushWatchVal = Get-ConfiguredReview -Key "ci_post_push_watch" -ProjectRoot $ProjectRoot
    $ciPostPushWatch = ($ciPostPushWatchVal -eq "true")

    return @{
        AutoPush = $autoPush
        RequireGreenCi = $requireGreenCi
        CiTimeoutMinutes = $ciTimeoutMinutes
        CiQueuedGraceMinutes = $ciQueuedGraceMinutes
        CiRequiredChecks = $ciRequiredChecks
        CiPostPushWatch = $ciPostPushWatch
    }
}

function Invoke-HumanGatePublish {
    # Publishes the accepted merge. With review.auto_push off it prints the push command
    # and pushes nothing. With review.require_green_ci on it pushes a staging ref, watches
    # CI, and refuses the primary-branch push on a red, incomplete or unverifiable run;
    # only a timeout, a run that never left the queue, or no registered runs finalize with
    # a warning. Every refusal exits (I11).
    param(
        [Parameter(Mandatory=$true)][string]$TaskId,
        [Parameter(Mandatory=$true)][string]$ProjectRoot,
        [Parameter(Mandatory=$true)][string]$PrimaryBranch,
        [Parameter(Mandatory=$true)][string]$LogFile,
        [Parameter(Mandatory=$true)][string]$CircuitBreakerHistoryFile,
        [Parameter(Mandatory=$true)][hashtable]$Config,
        [Parameter(Mandatory=$true)][AllowEmptyString()][string]$MergedSha
    )

    $autoPush = $Config.AutoPush
    $requireGreenCi = $Config.RequireGreenCi
    $ciTimeoutMinutes = $Config.CiTimeoutMinutes
    $ciQueuedGraceMinutes = $Config.CiQueuedGraceMinutes
    $ciRequiredChecks = $Config.CiRequiredChecks
    $ciPostPushWatch = $Config.CiPostPushWatch

    if ($autoPush) {
        $remotes = @(Invoke-GitChecked { git remote 2>$null })
        if ($remotes -contains "origin") {
            if ($requireGreenCi) {
                $ciStagingPrefixVal = Get-ConfiguredReview -Key "ci_staging_branch_prefix" -ProjectRoot $ProjectRoot
                $ciStagingPrefix = "crucible-ci"
                if (-not [string]::IsNullOrWhiteSpace($ciStagingPrefixVal)) {
                    $ciStagingPrefix = $ciStagingPrefixVal.TrimEnd('/')
                }
                $stagingBranch = "$ciStagingPrefix/$TaskId"

                Write-Host ("[HUMAN GATE] Publishing CI staging ref origin/" + $stagingBranch + "...") -ForegroundColor Cyan
                Invoke-GitChecked { git push origin ("$mergedSha" + ":refs/heads/" + $stagingBranch) --force }
                if ($LASTEXITCODE -ne 0) {
                    Write-Host ("[ERROR] Failed to publish CI staging ref " + $stagingBranch + ". Please check network/credentials.") -ForegroundColor Red
                    exit 1
                }

                $watchScript = Join-Path (Split-Path -Parent $PSScriptRoot) "watch-adopter-ci.ps1"
                Write-Host ("[HUMAN GATE] Watching origin CI for " + $mergedSha + " on staging ref " + $stagingBranch + " before finalizing...") -ForegroundColor Cyan
                $watchCmdArgs = @("-Commit", $mergedSha, "-TimeoutMinutes", $ciTimeoutMinutes, "-QueuedGraceMinutes", $ciQueuedGraceMinutes, "-CrucibleRoot", $ProjectRoot)
                if (-not [string]::IsNullOrWhiteSpace($ciRequiredChecks)) {
                    $watchCmdArgs += @("-RequiredJobs", $ciRequiredChecks)
                }
                $ciOutput = @(& (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $watchScript @watchCmdArgs 2>&1)
                $ciExitCode = $LASTEXITCODE
                foreach ($line in $ciOutput) {
                    Write-Host $line
                }

                if ($ciExitCode -eq 0) {
                    Write-Quiet "[HUMAN GATE] Pushing merged changes to origin/$PrimaryBranch..."
                    Invoke-GitChecked { git push origin $PrimaryBranch }
                    if ($LASTEXITCODE -ne 0) {
                        Write-Host "[ERROR] git push failed. Please check network/credentials or run manually." -ForegroundColor Red
                        exit 1
                    }
                    Invoke-GitChecked { git push origin --delete $stagingBranch }

                    if ($ciPostPushWatch) {
                        Write-Host ("[HUMAN GATE] Watching origin CI post-push on " + $PrimaryBranch + " for " + $mergedSha + "...") -ForegroundColor Cyan
                        $postPushOutput = @(& (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $watchScript @watchCmdArgs 2>&1)
                        $postPushExitCode = $LASTEXITCODE
                        foreach ($line in $postPushOutput) {
                            Write-Host $line
                        }
                        if ($postPushExitCode -eq 1) {
                            Write-Host ("[CI WATCH] STATUS=POST_PUSH_RED: Commit " + $mergedSha + " passed staging CI but failed branch CI on " + $PrimaryBranch + "!") -ForegroundColor Red
                            try {
                                Write-EventLog -Event "post_push_ci_red" -TaskId $TaskId -Specialist "crucible" -Outcome "warning" -Notes ("Commit " + $mergedSha + " failed post-push branch CI.") `
                                    -LogFile $LogFile -CircuitBreakerHistoryFile $CircuitBreakerHistoryFile
                            } catch {
                                Write-Host "[HUMAN GATE] WARNING: Failed to write post_push_ci_red event: $_" -ForegroundColor Yellow
                            }
                        } elseif ($postPushExitCode -eq 5) {
                            Write-Host ("[CI WATCH] STATUS=POST_PUSH_MISSING_REQUIRED_JOBS: Commit " + $mergedSha + " branch CI run is missing required jobs (" + $ciRequiredChecks + ")!") -ForegroundColor Red
                            try {
                                Write-EventLog -Event "post_push_ci_missing_required_jobs" -TaskId $TaskId -Specialist "crucible" -Outcome "warning" -Notes ("Post-push branch CI for " + $mergedSha + " missing required jobs: " + $ciRequiredChecks) `
                                    -LogFile $LogFile -CircuitBreakerHistoryFile $CircuitBreakerHistoryFile
                            } catch {
                                Write-Host "[HUMAN GATE] WARNING: Failed to write post_push_ci_missing_required_jobs event: $_" -ForegroundColor Yellow
                            }
                        }
                    }
                } elseif ($ciExitCode -eq 1) {
                    Invoke-GitChecked { git push origin --delete $stagingBranch }
                    Write-Host ("[HUMAN GATE] CI is RED for " + $mergedSha + "; task " + $TaskId + " is NOT done and master was NOT published (still local only). Fix forward and re-run the gate.") -ForegroundColor Red
                    exit 1
                } elseif ($ciExitCode -eq 5) {
                    Invoke-GitChecked { git push origin --delete $stagingBranch }
                    Write-Host ("[HUMAN GATE] MISSING_REQUIRED_JOBS: Staging CI run for " + $mergedSha + " is missing required jobs (" + $ciRequiredChecks + "); refusing to publish master. Fix CI config/workflow and re-run the gate.") -ForegroundColor Red
                    try {
                        Write-EventLog -Event "ci_missing_required_jobs" -TaskId $TaskId -Specialist "crucible" -Outcome "blocked" -Notes ("Staging CI run for " + $mergedSha + " missing required jobs: " + $ciRequiredChecks) `
                            -LogFile $LogFile -CircuitBreakerHistoryFile $CircuitBreakerHistoryFile
                    } catch {
                        Write-Host "[HUMAN GATE] WARNING: Failed to write ci_missing_required_jobs event: $_" -ForegroundColor Yellow
                    }
                    exit 1
                } elseif ($ciExitCode -notin @(2, 3, 4)) {
                    Invoke-GitChecked { git push origin --delete $stagingBranch }
                    Write-Host ("[HUMAN GATE] CI_CHECK_FAILED: Could not verify CI for " + $mergedSha + " (exit code " + $ciExitCode + "); refusing to publish " + $PrimaryBranch + " because require_green_ci is enabled. Fix gh CLI authentication/permissions or network and re-run the gate.") -ForegroundColor Red
                    try {
                        Write-EventLog -Event "ci_check_failed" -TaskId $TaskId -Specialist "crucible" -Outcome "blocked" -Notes ("Could not verify CI for " + $mergedSha + ": watch-adopter-ci exited with code " + $ciExitCode) `
                            -LogFile $LogFile -CircuitBreakerHistoryFile $CircuitBreakerHistoryFile
                    } catch {
                        Write-Host "[HUMAN GATE] WARNING: Failed to write ci_check_failed event: $_" -ForegroundColor Yellow
                    }
                    exit 1
                } else {
                    # Rationale: Only a CONFIRMED RED or API/tool failure withholds the master push; genuine inconclusive CI (timeout, CI_NOT_STARTED, NO_RUNS)
                    # still finalizes-with-warning so an infrastructure stall does not wedge the pipeline (F1/F2 stance).
                    Write-Quiet "[HUMAN GATE] Pushing merged changes to origin/$PrimaryBranch..."
                    Invoke-GitChecked { git push origin $PrimaryBranch }
                    if ($LASTEXITCODE -ne 0) {
                        Write-Host "[ERROR] git push failed. Please check network/credentials or run manually." -ForegroundColor Red
                        exit 1
                    }

                    if ($ciExitCode -eq 2) {
                        Write-Host ("[HUMAN GATE] CI did not finish before timeout for " + $mergedSha + "; finalizing while CI continues.") -ForegroundColor Yellow
                        Write-GateCiRunUrl
                    } elseif ($ciExitCode -eq 4) {
                        Write-Host ("[HUMAN GATE] CI never left GitHub's queue for " + $mergedSha + " (no runner assigned within the grace window). This is likely a runner-availability outage, NOT a slow build. Finalizing, but re-check CI - and consider re-running the workflow - before treating " + $TaskId + " as shipped.") -ForegroundColor Yellow
                        Write-GateCiRunUrl
                    } elseif ($ciExitCode -eq 3) {
                        Write-Host ("[HUMAN GATE] CI could not be confirmed for " + $mergedSha + ": no workflow runs registered within the grace window. Finalizing, but verify CI manually before treating " + $TaskId + " as shipped.") -ForegroundColor Yellow
                    }

                    Invoke-GitChecked { git push origin --delete $stagingBranch }
                }
            } else {
                Write-Quiet "[HUMAN GATE] Pushing merged changes to origin/$PrimaryBranch..."
                Invoke-GitChecked { git push origin $PrimaryBranch }
                if ($LASTEXITCODE -ne 0) {
                    Write-Host "[ERROR] git push failed. Please check network/credentials or run manually." -ForegroundColor Red
                    exit 1
                }
            }
        } else {
            Write-Quiet "[HUMAN GATE] No remote 'origin' configured. Skipping git push."
        }
    } else {
        Write-Host "[HUMAN GATE] Refusing to push; merge remains LOCAL only." -ForegroundColor Yellow
        Write-Host "Run the following command to publish:" -ForegroundColor Yellow
        Write-Host "  git push origin $PrimaryBranch" -ForegroundColor Cyan
        if ($requireGreenCi) {
            Write-Host "[HUMAN GATE] After that push, watch adopter CI for the merge commit:" -ForegroundColor Yellow
            Write-Host ("  pwsh -File .crucible/powershell/watch-adopter-ci.ps1 -Commit " + $mergedSha) -ForegroundColor Cyan
        }
    }
}

function Invoke-HumanGateAcceptArchival {
    # The accept arm's last phase: archive the task's pipeline log and handoffs and prune
    # it from session_state.json. Nothing here refuses; it runs after the merge, the
    # finalization and the publish have all held.
    param(
        [Parameter(Mandatory=$true)][string]$TaskId,
        [Parameter(Mandatory=$true)][string]$ProjectRoot
    )

    # Item 188: acceptance archives the same session used by the pipeline.
    $sessionDir = Get-ConfiguredPath -Key "session" -ProjectRoot $ProjectRoot
    $timestamp = Get-UtcFileTimestamp

    # Move pipeline log to archived if it exists
    $pipelineLogPath = Join-Path $sessionDir "$TaskId/pipeline.log.jsonl"
    if (Test-Path -LiteralPath $pipelineLogPath) {
        $archivedDir = Join-Path $sessionDir "archived"
        if (-not (Test-Path $archivedDir)) {
            New-Item -ItemType Directory -Force -Path $archivedDir | Out-Null
        }
        $destPath = Join-Path $archivedDir "pipeline-$TaskId-$timestamp.log.jsonl"
        Move-Item -LiteralPath $pipelineLogPath -Destination $destPath -Force
        Write-Quiet "[HUMAN GATE] Archived pipeline log to $destPath"
    }

    $archivedHandoffs = @(Move-TaskHandoffsToArchive -TaskId $TaskId -SessionDir $sessionDir -Timestamp $timestamp)
    if ($archivedHandoffs.Count -gt 0) {
        Write-Quiet ("[HUMAN GATE] Archived " + $archivedHandoffs.Count + " handoff file(s) for " + $TaskId)
    }

    # Prune the finalized task from session_state.json so -Status does not render it
    # as a ghost "In Progress" entry. The deployment/grooming done-handoff path prunes
    # via the same call; the accept finalize path must too, otherwise a task archived
    # here (and later invisible to the backlog parser) falls through to "In Progress".
    try {
        $updateStateScript = Join-Path (Split-Path -Parent $PSScriptRoot) "update-session-state.ps1"
        & $updateStateScript -Specialist done -TaskId $TaskId -UpdateJson "{}" -Merge $false -ProjectRoot $ProjectRoot | Out-Null
    } catch {
        Write-Quiet ("[HUMAN GATE] Could not prune session state for " + $TaskId + ": " + $_.Exception.Message)
    }
}

function Get-HumanGateRejectUnwind {
    # Decides whether a rejection or abandonment must reset the primary branch, and to
    # which commit. Reads git only; the caller resets. I8's reject-unwind enforcement point.
    param(
        [Parameter(Mandatory=$true)][string]$TaskId,
        [Parameter(Mandatory=$true)][string]$PrimaryBranch
    )

    $currentHead = (Invoke-GitChecked { git rev-parse "refs/heads/$PrimaryBranch" }).Trim()
    $parents = (Invoke-GitChecked { git log --pretty=%P -n 1 $currentHead }).Trim()
    $parentList = @(if ([string]::IsNullOrWhiteSpace($parents)) { } else { $parents -split '\s+' })

    # In the review-before-merge flow a rejected or abandoned task was never merged, so
    # there is normally nothing to undo. Unwind only when git proves the primary branch's
    # head is this task's merge: a merge commit whose second parent is the task branch
    # tip, or, once that branch is gone, whose subject names it. A hand-made fast-forward
    # leaves no merge commit, so it counts only when the branch's newest reflog entry is
    # that fast-forward. Being ahead of origin proves nothing: accepted merges
    # stay local until pushed, and resetting them would lose other tasks' work. Item 180.
    $headIsTaskMerge = $false
    $unwindTarget = $null
    $lastMove = Invoke-Git reflog show --format=%gs -n 1 "refs/heads/$PrimaryBranch"
    if ($parentList.Count -lt 2 -and $lastMove.ExitCode -eq 0 -and $lastMove.Raw.Trim() -eq "merge task/${TaskId}: Fast-forward") {
        $priorRes = Invoke-Git rev-parse --verify --quiet "refs/heads/$PrimaryBranch@{1}"
        if ($priorRes.ExitCode -eq 0) {
            $headIsTaskMerge = $true
            $unwindTarget = $priorRes.Raw.Trim()
        }
    }
    if ($parentList.Count -ge 2) {
        $taskTipRes = Invoke-Git rev-parse --verify --quiet "refs/heads/task/$TaskId"
        if ($taskTipRes.ExitCode -eq 0) {
            $headIsTaskMerge = ($taskTipRes.Raw.Trim() -eq $parentList[1])
        } else {
            $subject = (Invoke-GitChecked { git log --pretty=%s -n 1 $currentHead }).Trim()
            $headIsTaskMerge = ($subject -eq "Merge branch 'task/$TaskId'")
        }
        $unwindTarget = $parentList[0]
    }

    return @{
        CurrentHead = $currentHead
        ParentList = $parentList
        HeadIsTaskMerge = $headIsTaskMerge
        UnwindTarget = $unwindTarget
    }
}

function Invoke-HumanGateRejectAbandon {
    # Return unaccepted work through backlog restore or Abandoned archival, then
    # the rework handoff to implementation.
    # The caller enforces GateReason for rejection so the rework handoff carries
    # the human's reason; it remains optional in this helper's signature.
    param(
        [Parameter(Mandatory=$true)][string]$TaskId,
        [Parameter(Mandatory=$true)][string]$Outcome,
        [Parameter(Mandatory=$true)][string]$ProjectRoot,
        [Parameter(Mandatory=$true)][string]$PrimaryBranch,
        [string]$SourcePhase = "deployment",
        [string]$GateReason = "",
        $Handoff = $null
    )
    if ($SourcePhase -ne "grooming") {
        $unwind = Get-HumanGateRejectUnwind -TaskId $TaskId -PrimaryBranch $PrimaryBranch
        $target = if ($unwind.HeadIsTaskMerge) { $unwind.UnwindTarget } else { '' }
        $null = Test-GitDiscardSafe -Directory $ProjectRoot -Operation "$Outcome decision unwind" -AllowConfiguredRuntime -IncludeUntracked:$false -ResetTarget $target -Refuse
        $currentHead = $unwind.CurrentHead
        $parentList = @($unwind.ParentList)
        $headIsTaskMerge = $unwind.HeadIsTaskMerge
        $unwindTarget = $unwind.UnwindTarget
        Invoke-GitChecked { git -C $ProjectRoot checkout $PrimaryBranch }
        if ($headIsTaskMerge) {
            Write-Quiet "[HUMAN GATE] Unwinding this task's local merge. Resetting $PrimaryBranch to its pre-merge tip ($unwindTarget)..."
            $null = Test-GitDiscardSafe -Directory $ProjectRoot -Operation "$Outcome decision unwind" -AllowConfiguredRuntime -IncludeUntracked:$false -ResetTarget $unwindTarget -Refuse
            Invoke-GitChecked { git -C $ProjectRoot reset --hard $unwindTarget }
        } else {
            Write-Quiet "[HUMAN GATE] $PrimaryBranch does not end in a merge of task/$TaskId; leaving it untouched."
        }

        # Restore/archive only after safety and unwind: neither may dirty files that
        # the reset would then discard. A refused decision has no partial state.
        if ($Outcome -eq "rejected") {
            Restore-BacklogTask -TaskId $TaskId -ProjectRoot $ProjectRoot -ActiveStatus "In Progress"
        } elseif ($Outcome -eq "abandoned") {
            Invoke-AbandonedBacklogTaskArchive -TaskId $TaskId -ProjectRoot $ProjectRoot
        }

        if ($Outcome -eq "rejected") {
            Invoke-GitChecked { git show-ref --quiet "refs/heads/task/$TaskId" }
            if ($LASTEXITCODE -ne 0) {
                if ($parentList.Count -ge 2) {
                    Invoke-GitChecked { git branch "task/$TaskId" $parentList[1] }
                } else {
                    Invoke-GitChecked { git branch "task/$TaskId" $currentHead }
                }
                Write-Quiet "[HUMAN GATE] Restored task branch task/$TaskId"
            }

            Restore-ImplementationWorktree -TaskId $TaskId -ProjectRoot $ProjectRoot

            # Check if the task is present in the backlog before running new-handoff.ps1
            $backlogDir = Get-ConfiguredPath -Key "backlog" -ProjectRoot $ProjectRoot
            $backlogPath = Join-Path $backlogDir "BACKLOG.md"
            $hasTaskInBacklog = $false
            if (Test-Path -LiteralPath $backlogPath) {
                try {
                    $backlogContent = Get-Content -LiteralPath $backlogPath -Raw -Encoding UTF8
                    if ($backlogContent -match [regex]::Escape($TaskId)) {
                        $hasTaskInBacklog = $true
                    }
                } catch {}
            }

            if ($hasTaskInBacklog) {
                # Calculate next strike count
                $nextStrike = 1
                $activeHandoff = $Handoff
                if ($null -ne $activeHandoff) {
                    if ($activeHandoff.PSObject.Properties["review_strike_count"]) {
                        $nextStrike = [int]$activeHandoff.review_strike_count + 1
                    }
                }

                # Write a sanctioned re-entry handoff into implementation
                $generatorScript = Join-Path (Split-Path -Parent $PSScriptRoot) "new-handoff.ps1"
                if (Test-Path $generatorScript) {
                    $reasonMsg = if ([string]::IsNullOrWhiteSpace($GateReason)) { "Deployment rejected. Rework requested." } else { "Deployment rejected: $GateReason" }
                    Write-Quiet "[HUMAN GATE] Generating sanctioned re-entry handoff targeting implementation..."
                    
                    # Extract values from current handoff
                    $sessionCycleId = ""
                    $artifacts = @()
                    if ($null -ne $activeHandoff) {
                        if ($activeHandoff.PSObject.Properties["session_cycle_id"]) {
                            $sessionCycleId = $activeHandoff.session_cycle_id
                        } elseif ($activeHandoff.PSObject.Properties["cycle_id"]) {
                            $sessionCycleId = $activeHandoff.cycle_id
                        }
                        if ($activeHandoff.PSObject.Properties["artifacts"]) {
                            $artifacts = $activeHandoff.artifacts
                        }
                    }

                    $handoffParams = @{
                        TaskId = $TaskId
                        Source = "deployment"
                        Target = "implementation"
                        Reason = $reasonMsg
                        ReviewStrikeCount = $nextStrike
                        ProjectRoot = $ProjectRoot
                    }
                    if (-not [string]::IsNullOrEmpty($sessionCycleId)) {
                        $handoffParams["SessionCycleId"] = $sessionCycleId
                    }
                    if ($artifacts.Count -gt 0) {
                        $handoffParams["Artifacts"] = @($artifacts)
                    }
                    
                    & $generatorScript @handoffParams
                }
            } else {
                Write-Quiet "[HUMAN GATE] Task $TaskId not found in backlog; skipping handoff generation."
            }
        }
    }
}

function Get-GateReviewRange {
    # Computes the base..branch commit range the Human Gate shows for visual/text
    # review. The branch endpoint is the task branch TIP (the actual reviewed work),
    # not the handoff's commit_hash -- that is the stale bootstrap-era HEAD recorded
    # when the task was first created, before any implementation commit. The base
    # endpoint is the MERGE-BASE of the primary branch and the task branch, not the
    # primary-branch tip: when the primary branch has advanced past where the task
    # was cut, its tip skews the diff (wrong direction / unrelated commits) and omits
    # the task's own changes. Falls back to the legacy (primary-tip..commit_hash)
    # behavior only when no task branch exists (e.g. Crucible's own tasks whose changes are
    # not carried on a task branch).
    param(
        [Parameter(Mandatory = $true)][string]$PrimaryBranch,
        [Parameter(Mandatory = $true)][string]$TaskId,
        [string]$CommitHash = ""
    )

    $branchRef = "task/$TaskId"
    $baseSha = ""
    $branchSha = ""

    git show-ref --quiet "refs/heads/$branchRef"
    if ($LASTEXITCODE -eq 0) {
        $branchSha = (git rev-parse $branchRef 2>$null).Trim()
        $mergeBase = (git merge-base $PrimaryBranch $branchRef 2>$null).Trim()
        if (-not [string]::IsNullOrEmpty($mergeBase)) { $baseSha = $mergeBase }
    }

    if ([string]::IsNullOrEmpty($branchSha)) { $branchSha = $CommitHash }
    if ([string]::IsNullOrEmpty($baseSha)) {
        $baseSha = (git rev-parse $PrimaryBranch 2>$null).Trim()
    }

    return @{ BaseSha = $baseSha; BranchSha = $branchSha }
}

function Get-GateAcceptDescription {
    # What "1) Accept" promises depends on review.auto_push: with it off the merge
    # stays local, and the menu must not offer a push that will not happen.
    param(
        [Parameter(Mandatory=$true)][string]$PrimaryBranch,
        [Parameter(Mandatory=$true)][string]$ProjectRoot
    )

    $autoPushVal = Get-ConfiguredReview -Key "auto_push" -ProjectRoot $ProjectRoot
    if ($autoPushVal -eq "true") {
        return "work looks good; merges to $PrimaryBranch and pushes to origin; pause after this item"
    }
    return "work looks good; merges to $PrimaryBranch (local only); pause after this item"
}

function Write-GatePendingSurface {
    # First firing and re-runs of an unfilled template must show the same review surface.
    # Callers supply the range because re-runs prefer the original gate shas over a
    # freshly computed range that may have moved beneath the human. Item 14.
    param(
        [Parameter(Mandatory=$true)][hashtable]$Context,
        [Parameter(Mandatory=$true)][string]$RepoRoot,
        [Parameter(Mandatory=$true)][string]$SessionDir,
        [Parameter(Mandatory=$true)][string]$TaskId,
        [Parameter(Mandatory=$true)][string]$PendingFilePath,
        [Parameter(Mandatory=$true)][bool]$TaskBranchExists,
        [string]$BaseSha = "",
        [string]$BranchSha = "",
        [string]$NoCodeReviewHint = "",
        [string]$AcceptDesc = ""
    )

    $workspacesDir = if ($Context.ContainsKey("WorkspacesDir")) { $Context.WorkspacesDir } else { Get-ConfiguredPath -Key "workspaces" -ProjectRoot $RepoRoot }
    $wtPath = Join-Path $workspacesDir ("implementation-" + $TaskId)
    $wtPathDisplay = $wtPath -replace '\\', '/'

    $diffTool = Get-ConfiguredReview -Key "diff_tool" -ProjectRoot $RepoRoot
    $editor = Get-ConfiguredReview -Key "editor" -ProjectRoot $RepoRoot

    $diffToolCommand = ""
    $editorOpenCommand = ""

    if (![string]::IsNullOrEmpty($diffTool)) {
        $resolvedDiffTool = Get-ConfiguredEditorCommand -EditorOrToolName $diffTool
        $taskSessionDir = Join-Path $SessionDir $TaskId
        if (-not (Test-Path $taskSessionDir)) {
            New-Item -ItemType Directory -Force -Path $taskSessionDir | Out-Null
        }
        $helperScriptPath = Join-Path $taskSessionDir "review-diff.ps1"
        $resolvedDiffToolEscaped = $resolvedDiffTool -replace '"', '`"'
        # GetTempPath() works across platforms: Windows uses TMP then TEMP, others TMPDIR.
        # TEMP alone can be unset off Windows. Emit the call bare so it runs in the
        # generated helper on the reviewer's platform; there is no $ to defer. Item 103.
        $scriptContent = @"
`$left = `$args[0]
`$right = `$args[1]
`$tmp = Join-Path ([System.IO.Path]::GetTempPath()) "crucible-review/$TaskId"
if (-not (Test-Path `$tmp)) { New-Item -ItemType Directory -Path `$tmp -Force | Out-Null }
`$leftCopy = Join-Path `$tmp ("left_" + (Split-Path -Leaf `$left))
`$rightCopy = Join-Path `$tmp ("right_" + (Split-Path -Leaf `$right))
Copy-Item `$left `$leftCopy -Force
Copy-Item `$right `$rightCopy -Force
& "$resolvedDiffToolEscaped" --diff `$leftCopy `$rightCopy
"@
        try {
            $scriptContent | Set-Content -LiteralPath $helperScriptPath -Encoding UTF8
        } catch {}

        $helperScriptPathDisplay = $helperScriptPath -replace '\\', '/'
        $pwshCmd = Get-PwshCommand
        $diffToolCommand = "git -C `"$RepoRoot`" difftool -y --extcmd=`"$pwshCmd -NoProfile -ExecutionPolicy Bypass -File \`"$helperScriptPathDisplay\`"`" $BaseSha..$BranchSha"
    }

    $editorToUse = if (![string]::IsNullOrEmpty($editor)) { $editor } else { $diffTool }
    if (![string]::IsNullOrEmpty($editorToUse)) {
        $resolvedEditor = Get-ConfiguredEditorCommand -EditorOrToolName $editorToUse
        $editorOpenCommand = "& `"$resolvedEditor`" `"$wtPathDisplay`""
    }

    $notRunChecks = @(Get-ChecksNotRun -SessionDir $SessionDir -TaskId $TaskId)
    if ($notRunChecks.Count -gt 0) {
        Write-Host "[CHECKS NOT RUN] These checks did not run; accepting means accepting this gap:" -ForegroundColor Yellow
        foreach ($notRunCheck in $notRunChecks) { Write-Host ("  - " + $notRunCheck) -ForegroundColor Yellow }
    }
    Write-Host "`n[HUMAN GATE] Visual review options:" -ForegroundColor Yellow
    if ($TaskBranchExists) {
        if (-not [string]::IsNullOrEmpty($diffToolCommand)) {
            Write-Host "  - Launch visual diff tool (per-file):" -ForegroundColor Yellow
            Write-Host "    $diffToolCommand" -ForegroundColor Cyan
        }
        Write-Host "  - Command-line text diff:" -ForegroundColor Yellow
        Write-Host "    git -C `"$RepoRoot`" diff $BaseSha..$BranchSha" -ForegroundColor Cyan
        Write-Host "  - Open the worktree folder in your editor:" -ForegroundColor Yellow
        if (-not [string]::IsNullOrEmpty($editorOpenCommand)) {
            Write-Host "    $editorOpenCommand" -ForegroundColor Cyan
        } else {
            Write-Host "    $wtPathDisplay" -ForegroundColor Cyan
        }
    } else {
        Write-Host "  - $NoCodeReviewHint" -ForegroundColor Cyan
    }

    # Write machine-readable signal file
    $menu = "[HUMAN GATE] Task $TaskId complete. Present this menu to the human:`n`n" +
            "  1) Accept     - $AcceptDesc`n" +
            "  2) Reject     - something is wrong, send back for rework`n" +
            "  3) Redirect   - accept this item and work on a specific item next (ask which one)`n" +
            "  4) Abandon    - do not accept; stop the pipeline entirely`n`n" +
            "Review options:`n"
    if ($TaskBranchExists) {
        if (-not [string]::IsNullOrEmpty($diffToolCommand)) {
            $menu += "  - Launch visual diff tool (per-file):`n" +
                     "    $diffToolCommand`n"
        }
        $menu += "  - Command-line text diff:`n" +
                 "    git -C `"$RepoRoot`" diff $BaseSha..$BranchSha`n" +
                 "  - Open the worktree folder in your editor:`n"
        if (-not [string]::IsNullOrEmpty($editorOpenCommand)) {
            $menu += "    $editorOpenCommand`n`n"
        } else {
            $menu += "    $wtPathDisplay`n`n"
        }
    } else {
        $menu += "  - $NoCodeReviewHint`n`n"
    }
    $menu += "Gate fired. Run crucible.ps1 -Init -TaskId $TaskId -ProjectRoot `"$RepoRoot`" -GateOutcome <choice> [-GateReason `"Reason`"] to record the decision."
    $menu | Set-Content -Path $PendingFilePath -Encoding UTF8
}

function Invoke-HumanGate {
    param([Parameter(Mandatory=$true)][hashtable]$Context)

    if ($null -eq $Context) {
        throw "CrucibleContext is null."
    }
    # Require LogFile and CircuitBreakerHistoryFile in the context so downstream
    # actions receive explicit destinations rather than caller scope or missing events. Item 16.
    Assert-CrucibleContextKeys -Context $Context `
        -RequiredKeys @("Handoff", "IsBootstrap", "SessionDir", "GateOutcome", "GateReason", "GateRedirectTarget", "CrucibleRoot", "Quiet") `
        -NonNullKeys @("LogFile", "CircuitBreakerHistoryFile")

    $handoff = $Context.Handoff
    $isBootstrap = [bool]$Context.IsBootstrap
    $sessionDir = $Context.SessionDir
    $GateOutcome = $Context.GateOutcome
    $GateReason = $Context.GateReason
    $GateRedirectTarget = $Context.GateRedirectTarget
    $crucibleRoot = $Context.CrucibleRoot
    $Quiet = [bool]$Context.Quiet
    $repoRoot = if ($Context.ContainsKey("RepoRoot")) { $Context.RepoRoot } else { Resolve-ConfigProjectRoot }
    $LOG_FILE = $Context.LogFile
    $CB_HISTORY_FILE = $Context.CircuitBreakerHistoryFile

    $taskBranchExists = $false
    $isGit = $false
    $checkDir = $repoRoot
    while (-not [string]::IsNullOrEmpty($checkDir)) {
        if (Test-Path -LiteralPath (Join-Path $checkDir ".git")) {
            $isGit = $true
            break
        }
        $parent = Split-Path -Parent $checkDir
        if ($parent -eq $checkDir -or [string]::IsNullOrEmpty($parent)) { break }
        $checkDir = $parent
    }
    if ($isGit) {
        git -C $repoRoot show-ref --verify --quiet "refs/heads/task/$($handoff.task_id)" 2>$null
        if ($LASTEXITCODE -eq 0) {
            $taskBranchExists = $true
        }
    }

    # Resolve a concrete review pointer for a No-Code Closure. Prefer a
    # findings/.md artifact named in the handoff; else the newest research/.md file
    # matching the task id; else fall back to the archived spec.
    $noCodeClosureReviewDoc = ""
    $reviewDocCandidates = @()
    if ($handoff.PSObject.Properties["artifacts"] -and $handoff.artifacts) {
        foreach ($artifact in $handoff.artifacts) {
            if ($artifact -and ([string]$artifact -match '\.md$')) { $reviewDocCandidates += [string]$artifact }
        }
    }
    $noCodeClosureReviewDoc = $reviewDocCandidates | Where-Object { $_ -match '(?i)findings' } | Select-Object -First 1
    if ([string]::IsNullOrEmpty($noCodeClosureReviewDoc)) {
        $noCodeClosureReviewDoc = $reviewDocCandidates | Select-Object -First 1
    }
    if ([string]::IsNullOrEmpty($noCodeClosureReviewDoc) -and -not [string]::IsNullOrEmpty($crucibleRoot)) {
        $noCodeClosureResearchDir = Join-Path $repoRoot (Join-Path $crucibleRoot "research")
        if (Test-Path -LiteralPath $noCodeClosureResearchDir) {
            $noCodeClosureFound = Get-ChildItem -LiteralPath $noCodeClosureResearchDir -Filter "$($handoff.task_id)*.md" -File -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending | Select-Object -First 1
            if ($noCodeClosureFound) {
                $noCodeClosureReviewDoc = ((Join-Path $crucibleRoot "research") + "/" + $noCodeClosureFound.Name) -replace '\\', '/'
            }
        }
    }
    $noCodeClosureReviewHint = if (-not [string]::IsNullOrEmpty($noCodeClosureReviewDoc)) {
        "No-Code Closure - no code diff; review $noCodeClosureReviewDoc + filed stubs"
    } else {
        "No-Code Closure - no code diff; review the archived spec + filed stubs"
    }

    # --- 3a. Human Gate ---
    $isGroomingClosure = ($handoff.source_phase -eq "grooming" -and $handoff.target_phase -eq "done")
    if ($isGroomingClosure) {
        $researchMisrouteAdvisory = Get-ResearchMisrouteAdvisory -Handoff $handoff -Context $Context -ProjectRoot $repoRoot
        if (-not [string]::IsNullOrEmpty($researchMisrouteAdvisory)) {
            Write-Host ("[ADVISORY] " + $researchMisrouteAdvisory) -ForegroundColor Yellow
        }
    }
    $shouldRunHumanGate = $false
    if ($handoff.source_phase -eq "deployment") {
        if (-not [string]::IsNullOrEmpty($GateOutcome)) {
            $shouldRunHumanGate = -not $isBootstrap
        } else {
            $shouldRunHumanGate = -not $isBootstrap -and $handoff.target_phase -eq "done"
        }
    } elseif ($isGroomingClosure) {
        # Check if research gate approved it
        $researchGateApproved = $false
        $handoffDir = $Context.HandoffDir
        if (-not [string]::IsNullOrEmpty($handoffDir) -and (Test-Path $handoffDir)) {
            $handoffFiles = @(Get-ChildItem -Path $handoffDir -Filter ($handoff.task_id + "-*.json") -ErrorAction SilentlyContinue)
            foreach ($file in $handoffFiles) {
                try {
                    $hObj = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
                    if ($hObj.source_phase -eq "research" -and $hObj.human_decisions -and $hObj.human_decisions.approved -and $hObj.human_decisions.approved.Count -gt 0) {
                        $researchGateApproved = $true
                        break
                    }
                } catch {}
            }
        }
        $shouldRunHumanGate = -not $researchGateApproved
    }

    if ($shouldRunHumanGate) {
        $GATE_DIR = Join-Path $sessionDir "global/gate_decisions"
        if (-not (Test-Path $GATE_DIR)) {
            New-Item -ItemType Directory -Force -Path $GATE_DIR | Out-Null
        }

        $GATE_PENDING_FILE = Join-Path $sessionDir ($handoff.task_id + "/gate_pending.txt")
        $pendingDir = Split-Path -Parent $GATE_PENDING_FILE
        if (-not (Test-Path $pendingDir)) {
            New-Item -ItemType Directory -Force -Path $pendingDir | Out-Null
        }
        $validOutcomes = Get-HumanGateOutcomes
        # Cycle that this gate is firing in. An advancing decision is only honored
        # as "already passed" on a re-run within the SAME cycle, so a stale accept
        # from a prior cycle cannot silently bypass a fresh human gate encounter.
        $currentGateCycle = if ($handoff.PSObject.Properties["session_cycle_id"] -and -not [string]::IsNullOrEmpty($handoff.session_cycle_id)) {
            [string]$handoff.session_cycle_id
        } elseif (-not [string]::IsNullOrEmpty($env:CRUCIBLE_CYCLE_ID)) {
            [string]$env:CRUCIBLE_CYCLE_ID
        } else {
            ""
        }

        # --- Handle automated gate outcome from CLI flag ---
        if (-not [string]::IsNullOrEmpty($GateOutcome)) {
            # Support numeric mapping (1-4)
            if ($GateOutcome -match '^[1-4]$') {
                $map = @{ "1"="accepted"; "2"="rejected"; "3"="redirected"; "4"="abandoned" }
                $GateOutcome = $map[$GateOutcome]
            }

            if ($validOutcomes -notcontains $GateOutcome) {
                Write-Host ("Error: Invalid -GateOutcome: " + $GateOutcome) -ForegroundColor Red
                exit 1
            }

            $trimmedGateReason = if ([string]::IsNullOrWhiteSpace($GateReason)) { "" } else { (ConvertTo-AsciiSafeText -Text $GateReason).Trim() }
            
            $decision = [ordered]@{
                outcome = $GateOutcome
                reason = $trimmedGateReason
                redirect_target = $GateRedirectTarget
            }
            
            Write-HumanGateDecision -Context $Context -Decision ([pscustomobject]$decision) -ProjectRoot $repoRoot -SessionCycleId $currentGateCycle -ResolveReviewRange
            Write-Host ("`n[HUMAN GATE] Decision recorded via CLI flag: " + $GateOutcome) -ForegroundColor Green
            Write-Host ("Reason: " + $trimmedGateReason) -ForegroundColor Gray

            # Execute push or reset based on automated CLI decision. An accepted merge
            # that conflicts routes to rework and removes this premature decision itself
            # (see Invoke-HumanGateMerge) so a non-completed accept cannot block a retry.
            Invoke-HumanGateAction -TaskId $handoff.task_id -Outcome $GateOutcome -ProjectRoot $repoRoot -SourcePhase $handoff.source_phase -GateReason $trimmedGateReason -Handoff $handoff `
            -LogFile $LOG_FILE -CircuitBreakerHistoryFile $CB_HISTORY_FILE

            if ($GateOutcome -eq "abandoned") {
                Write-Host "[ABANDONED] Pipeline stopped per human request." -ForegroundColor Gray
                exit 0
            }
            
            # Cleanup pending files
            if (Test-Path $GATE_PENDING_FILE) { Remove-Item $GATE_PENDING_FILE -Force }
            $legacyPending = Join-Path $GATE_DIR ("gate_decision_" + $handoff.task_id + "_pending.json")
            if (Test-Path $legacyPending) { Remove-Item $legacyPending -Force }
            Write-Host "[HUMAN GATE] Session complete. Start the next task explicitly when ready." -ForegroundColor Gray
            exit 0
        } else {
            $gateAlreadyPassed = $false
            
            # Check for already completed decisions for this task
            $decisions = @(Get-ChildItem -Path $GATE_DIR -Filter ($handoff.task_id + "-*.json") |
                Where-Object { $_.Name -notmatch "gate_decision_.*_pending.json" } |
                Sort-Object LastWriteTime -Descending)

            if ($decisions.Count -gt 0) {
                try {
                    $latestDecision = Get-Content $decisions[0].FullName -Raw -Encoding UTF8 | ConvertFrom-Json
                    # Only outcomes that advance the pipeline bypass the gate.
                    # "rejected" and "abandoned" require a fresh human decision on the reworked item.
                    $advancingOutcomes = @("accepted", "redirected")
                    if ($advancingOutcomes -contains $latestDecision.outcome) {
                        # Scope the bypass to the current cycle: an advancing decision
                        # only counts as "already passed" if it was recorded in the same
                        # cycle as this handoff. A stale accept from a prior cycle (e.g. a
                        # re-opened task or a rework re-entry) must NOT auto-advance; the
                        # human is re-prompted. Unstamped (legacy) decisions fail safe the
                        # same way. Empty current cycle also fails safe (re-prompt).
                        $decisionCycle = if ($latestDecision.PSObject.Properties["session_cycle_id"]) { [string]$latestDecision.session_cycle_id } else { "" }
                        if (-not [string]::IsNullOrEmpty($currentGateCycle) -and $decisionCycle -eq $currentGateCycle) {
                            $gateAlreadyPassed = $true
                        }
                    }
                } catch {
                    Write-Quiet ("[GATE] Warning: Could not parse gate decision file " + $decisions[0].Name) -ForegroundColor Yellow
                }
            }

            if (-not $gateAlreadyPassed) {
                $gateTemplatePath = Join-Path $GATE_DIR ("gate_decision_" + $handoff.task_id + "_pending.json")
                
                # Cross-validation: Archive legacy pending gate files
                $otherPending = @()
                    
                $legacyTemplate = Join-Path $GATE_DIR "gate_decision_template.json"
                if (Test-Path $legacyTemplate) { $otherPending += Get-Item $legacyTemplate }
                    
                foreach ($stale in $otherPending) {
                    $timestamp = Get-UtcFileTimestamp
                    $staleArchive = Join-Path $GATE_DIR ($stale.BaseName + "-stale-" + $timestamp + ".json")
                    Write-Quiet ("[GATE] Warning: Found legacy template file. Archiving to: $($staleArchive)") -ForegroundColor Yellow
                    Move-Item -Path $stale.FullName -Destination $staleArchive -Force
                }
                
                if (Test-Path $gateTemplatePath) {
                    try {
                        $gateData = Get-Content $gateTemplatePath -Raw -Encoding UTF8 | ConvertFrom-Json
                        if ([string]::IsNullOrWhiteSpace($gateData.outcome) -or $gateData.outcome -eq "accepted | rejected | redirected | abandoned") {
                            Write-Host "`n[HUMAN GATE] Action Required: Please complete the gate decision." -ForegroundColor Yellow
                            Write-Host ("File: " + $gateTemplatePath) -ForegroundColor White
                            
                            $primaryBranch = Get-ConfiguredPrimaryBranch
                            $acceptDesc = Get-GateAcceptDescription -PrimaryBranch $primaryBranch -ProjectRoot $repoRoot

                            $baseSha = ""
                            $branchSha = ""
                            if ($gateData.PSObject.Properties["base_sha"]) { $baseSha = $gateData.base_sha }
                            if ($gateData.PSObject.Properties["branch_sha"]) { $branchSha = $gateData.branch_sha }
                            if ([string]::IsNullOrEmpty($baseSha) -or [string]::IsNullOrEmpty($branchSha)) {
                                $primaryBranch = Get-ConfiguredPrimaryBranch
                                $gateHandoffCommit = if ($handoff.PSObject.Properties["commit_hash"]) { $handoff.commit_hash } else { "" }
                                $gateRange = Get-GateReviewRange -PrimaryBranch $primaryBranch -TaskId $handoff.task_id -CommitHash $gateHandoffCommit
                                $baseSha = $gateRange.BaseSha
                                $branchSha = $gateRange.BranchSha
                            }

                            Write-GatePendingSurface -Context $Context -RepoRoot $repoRoot -SessionDir $sessionDir `
                                -TaskId $handoff.task_id -PendingFilePath $GATE_PENDING_FILE -TaskBranchExists $taskBranchExists `
                                -BaseSha $baseSha -BranchSha $branchSha -NoCodeReviewHint $noCodeClosureReviewHint -AcceptDesc $acceptDesc
                            
                            # Construct gate-specific command for next_step.txt
                            $pwshCmd = Get-PwshCommand
                            $gateCommand = "$pwshCmd -ExecutionPolicy Bypass -File `"$crucibleRoot/powershell/crucible.ps1`" -Init -TaskId $($handoff.task_id) -ProjectRoot `"$repoRoot`" -GateOutcome accepted -GateReason `"<one concrete quality reason>`" -Quiet"
                            Write-NextStep -SessionDir $sessionDir -Command $gateCommand -TaskId $handoff.task_id -Specialist $handoff.source_phase
                            
                            exit 0
                        } else {
                            Write-HumanGateDecision -Context $Context -Decision $gateData -ProjectRoot $repoRoot -SessionCycleId $currentGateCycle -DecisionFile $gateTemplatePath `
                                -PendingTemplate $gateTemplatePath

                            # Execute push or reset based on manual decision
                            Invoke-HumanGateAction -TaskId $handoff.task_id -Outcome $gateData.outcome -ProjectRoot $repoRoot -SourcePhase $handoff.source_phase -GateReason $gateData.reason -Handoff $handoff `
            -LogFile $LOG_FILE -CircuitBreakerHistoryFile $CB_HISTORY_FILE

                            Write-Host ("`n[HUMAN GATE] Decision recorded: " + $gateData.outcome) -ForegroundColor Green
                            
                            # Cleanup machine-readable signal
                            if (Test-Path $GATE_PENDING_FILE) { Remove-Item $GATE_PENDING_FILE -Force }

                            if ($gateData.outcome -eq "rejected" -or $gateData.outcome -eq "abandoned") {
                                exit 0
                            }
                        }
                    } catch {
                        # This catch spans the gate action too, not just the parse, so a
                        # fixed message would report an unrecognized outcome as bad JSON
                        # and send the operator to debug a file that is well-formed.
                        Write-Host ("Error handling gate decision template: " + $_.Exception.Message) -ForegroundColor Red
                        exit 1
                    }
                } else {
                    # Create template and exit
                    $primaryBranch = Get-ConfiguredPrimaryBranch
                    $acceptDesc = Get-GateAcceptDescription -PrimaryBranch $primaryBranch -ProjectRoot $repoRoot
                    $gateHandoffCommit = if ($handoff.PSObject.Properties["commit_hash"]) { $handoff.commit_hash } else { "" }
                    $gateRange = Get-GateReviewRange -PrimaryBranch $primaryBranch -TaskId $handoff.task_id -CommitHash $gateHandoffCommit
                    $baseSha = $gateRange.BaseSha
                    $branchSha = $gateRange.BranchSha

                    $template = [ordered]@{
                        task_id = $handoff.task_id
                        backlog_item = $handoff.task_id
                        gate_fired_at = Get-UtcTimestamp
                        outcome = "accepted | rejected | redirected | abandoned"
                        reason = "Brief human description of why"
                        rework_requested = $false
                        redirect_target = $null
                        base_sha = $baseSha
                        branch_sha = $branchSha
                    }
                    $template | ConvertTo-Json | Set-Content -Path $gateTemplatePath -Encoding UTF8
                    
                    Write-GatePendingSurface -Context $Context -RepoRoot $repoRoot -SessionDir $sessionDir `
                        -TaskId $handoff.task_id -PendingFilePath $GATE_PENDING_FILE -TaskBranchExists $taskBranchExists `
                        -BaseSha $baseSha -BranchSha $branchSha -NoCodeReviewHint $noCodeClosureReviewHint -AcceptDesc $acceptDesc

                    Write-Host "`n[HUMAN GATE] Task $($handoff.task_id) complete. Present this menu to the human:" -ForegroundColor Yellow
                    Write-Host ""
                    Write-Host "  1) Accept     - $acceptDesc" -ForegroundColor Cyan
                    Write-Host "  2) Reject     - something is wrong, send back for rework" -ForegroundColor Cyan
                    Write-Host "  3) Redirect   - accept this item and work on a specific item next (ask which one)" -ForegroundColor Cyan
                    Write-Host "  4) Abandon    - do not accept; stop the pipeline entirely" -ForegroundColor Cyan
                    Write-Host ""
                    Write-Host "[NEXT SESSION COMMAND] Run the following command:" -ForegroundColor Magenta
                    Write-Host "1. Show the menu above to the human and ask them to reply with 1, 2, 3, or 4." -ForegroundColor White
                    Write-Host "2. Map their choice to the outcome: 1=accepted 2=rejected 3=redirected 4=abandoned." -ForegroundColor White
                    Write-Host "3. Execute the gate recording command using -GateOutcome <choice> (e.g. -GateOutcome accepted)." -ForegroundColor White
                    Write-Host "4. Stop after recording the decision unless the human explicitly starts another task." -ForegroundColor White
                    
                    # Construct gate-specific command for next_step.txt
                    $pwshCmd = Get-PwshCommand
                    $gateCommand = "$pwshCmd -ExecutionPolicy Bypass -File `"$crucibleRoot/powershell/crucible.ps1`" -Init -TaskId $($handoff.task_id) -ProjectRoot `"$repoRoot`" -GateOutcome accepted -GateReason `"<one concrete quality reason>`" -Quiet"
                    Write-NextStep -SessionDir $sessionDir -Command $gateCommand -TaskId $handoff.task_id -Specialist $handoff.source_phase
                    
                    exit 0
                }
            } else {
                # Cleanup machine-readable signal
                if (Test-Path $GATE_PENDING_FILE) { Remove-Item $GATE_PENDING_FILE -Force }
            }
        }
    }
}
