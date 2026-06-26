function Write-NextStep {
    param(
        [Parameter(Mandatory=$true)][string]$SessionDir,
        [string]$Command,
        [string]$TaskId,
        [string]$Specialist,
        [string]$ActionCmd = $null,
        [string]$RecommendedModel = $null,
        [switch]$ShouldAutoAdvance
    )
    $nsDir = if (-not [string]::IsNullOrEmpty($TaskId)) {
        Join-Path $SessionDir ($TaskId + "/" + $Specialist)
    } else {
        Join-Path $SessionDir $Specialist
    }
    if (-not (Test-Path $nsDir)) { New-Item -ItemType Directory -Force -Path $nsDir | Out-Null }
    $nsFile = Join-Path $nsDir "next_step.txt"
    $nsContent = "=== SESSION END COMMAND ===`n" +
                 "Run this via Bash tool when your work is complete:`n`n" +
                 $Command + "`n"
    $nsContent | Set-Content -Path $nsFile -Encoding UTF8

    if (-not [string]::IsNullOrEmpty($ActionCmd)) {
        Write-Host "----------------------------------------------------"
        if ($ShouldAutoAdvance) {
            Write-Host "[AUTO-ADVANCE] Non-gate transition - execute immediately without waiting for human confirmation:" -ForegroundColor Green
        } else {
            Write-Host "[NEXT SESSION COMMAND] Run the following command:" -ForegroundColor White
        }
        Write-Host ""
        Write-Host $ActionCmd
        if (-not [string]::IsNullOrEmpty($RecommendedModel)) {
            Write-Host ("[RECOMMENDED MODEL] " + $RecommendedModel + " - dispatch the specialist sub-agent with this model.") -ForegroundColor Cyan
        }
        Write-Host ""
        Write-Quiet ("[NEXT PIPELINE STEP] Run at session end (also saved to " + $nsFile + "):") -ForegroundColor DarkGray
        Write-Quiet $Command -ForegroundColor Yellow
        Write-Host "----------------------------------------------------`n"
    }
}

if (-not (Get-Command Get-PwshCommand -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot "platform.ps1")
}

function Assert-FactorySessionOutputContext {
    param(
        [Parameter(Mandatory=$true)][AllowNull()][hashtable]$Context,
        [Parameter(Mandatory=$true)][string[]]$RequiredKeys
    )

    if ($null -eq $Context) {
        throw "FactoryContext is null."
    }
    foreach ($key in $RequiredKeys) {
        if (-not $Context.ContainsKey($key) -or $null -eq $Context[$key]) {
            throw "Required key '$key' is missing from FactoryContext."
        }
    }
}

function New-FactoryPromptText {
    param([Parameter(Mandatory=$true)][hashtable]$Context)

    Assert-FactorySessionOutputContext -Context $Context -RequiredKeys @(
        "Handoff", "LatestHandoff", "PromptLib", "SessionDir", "TaskId", "Ceiling", "LogFile", "CircuitBreakerHistoryFile", "WorkspacesDir", "CrucibleRoot", "RepoRoot"
    )

    $handoff = $Context.Handoff
    $latestHandoff = $Context.LatestHandoff
    $PROMPT_LIB = $Context.PromptLib
    $sessionDir = $Context.SessionDir
    $TaskId = $Context.TaskId
    $ceiling = $Context.Ceiling
    $LOG_FILE = $Context.LogFile
    $CB_HISTORY_FILE = $Context.CircuitBreakerHistoryFile
    $workspacesDir = $Context.WorkspacesDir
    $crucibleRoot = $Context.CrucibleRoot
    $repoRoot = $Context.RepoRoot
    $resolvedCrucibleRoot = if ([System.IO.Path]::IsPathRooted($crucibleRoot)) { $crucibleRoot } else { Join-Path $repoRoot $crucibleRoot }
    $Recover = [bool]$Context.Recover

    # --- 5. Template Assembly ---
    $typeDir = "unknown"
    if ($handoff.task_id -match "^F-") { $typeDir = "features" }
    elseif ($handoff.task_id -match "^B-") { $typeDir = "bugs" }
    elseif ($handoff.task_id -match "^C-") { $typeDir = "chores" }

    $relativeHandoffPath = if ($null -ne $latestHandoff) {
        ".crucible/session/handoffs/" + $latestHandoff.Name
    } else {
        ".crucible/session/handoffs"
    }

    $templateFile = Join-Path $PROMPT_LIB ($handoff.target_phase + "_prompt.md")
    $promptVersion = "unknown"
    if (-not (Test-Path $templateFile)) {
        # Minimalist fallback
        $role = $script:PHASE_ROLE_MAP[$handoff.target_phase]
        $roleDisplay = $role.Substring(0,1).ToUpper() + $role.Substring(1)
        $promptText = $roleDisplay + ": Proceed with " + $handoff.task_id + ". See handoff."
    } else {
        $promptText = Get-Content $templateFile -Raw -Encoding UTF8
        
        # Extract prompt_version
        if ($promptText -match '<!--\s*prompt_version:\s*(.*?)\s*-->') {
            $promptVersion = $matches[1]
        }

        # Simple placeholder replacement
        $promptText = $promptText.Replace("{{crucible_root}}", $resolvedCrucibleRoot)
        $promptText = $promptText.Replace("powershell.exe", (Get-PwshCommand))
        $promptText = $promptText.Replace("{task_id}", $handoff.task_id)
        $promptText = $promptText.Replace("{worktree}", (Resolve-ImplementationWorktreePath -TaskId $handoff.task_id -WorkspacesDir $workspacesDir))
        $promptText = $promptText.Replace("{project_root}", $repoRoot)
        
        $rebaseCount = if ($handoff.psobject.Properties["rebase_count"]) { $handoff.rebase_count } else { 0 }
        $promptText = $promptText.Replace("{rebase_count}", $rebaseCount)

        # Conditional rebase section injection
        $architectRebaseContent = "`n## Rebase Workflow`n`n" +
            "If you are receiving this task for rebase (status: `"Ready for Rebase`"):`n`n" +
            "1. **Checkout Master**: ``git checkout master`` `n" +
            "2. **Update Master**: ``git pull origin master`` `n" +
            "3. **Rebase Task Branch**: ``git rebase master task/$($handoff.task_id)`` `n" +
            "4. **Resolve Conflicts**:`n" +
            "   - Manually resolve any conflicts in the files listed in ``conflict_report.json``.`n" +
            "   - Use ``git add`` to mark resolved files.`n" +
            "   - Continue rebase: ``git rebase --continue``.`n" +
            "5. **Validation**: Run full test suite to ensure the rebase didn't break anything.`n" +
            "6. **Handoff**:`n" +
            "   - Update ``rebase_count`` in handoff JSON.`n" +
            "   - Status: `"Ready for Review`".`n" +
            "   - Reason: `"Rebase onto master complete. Conflicts resolved.`"`n" +
            "   - Hand off to **Reviewer**."
            
        $reviewerRebaseContent = "`n## Post-Rebase Verification`n`n" +
            "If the handoff indicates this is a post-rebase review:`n`n" +
            "1. **Verify Clean Merge**: Confirm that the Architect resolved all conflicts from conflict_report.json.`n" +
            "2. **Full Regression Check**: Since a rebase involves changing the base of the branch, pay extra attention to any semantic conflicts that git might have missed.`n" +
            "3. **Check rebase_count**: If rebase_count is 3 or more, and conflicts persist, flag for human escalation."

        if ($rebaseCount -gt 0) {
            if ($handoff.target_phase -eq "implementation") {
                $promptText = $promptText.Replace("{rebase_section}", $architectRebaseContent)
            } elseif ($handoff.target_phase -eq "verification") {
                $promptText = $promptText.Replace("{rebase_section}", $reviewerRebaseContent)
            } else {
                $promptText = $promptText.Replace("{rebase_section}", "")
            }
        } else {
            $promptText = $promptText.Replace("{rebase_section}", "")
        }

        # Inject exact resolved handoff filename so agents don't have to glob
        $promptText = $promptText.Replace("{handoff_file}", $relativeHandoffPath)

        # Inject context bundle path
        $contextBundlePath = Join-Path $sessionDir "$TaskId/$($handoff.target_phase)/context.md"
        if (-not [string]::IsNullOrEmpty($TaskId) -and (Test-Path $contextBundlePath)) {
            $promptText = $promptText.Replace("{context_bundle_path}", $contextBundlePath)
        } else {
            $promptText = $promptText.Replace("{context_bundle_path}", "N/A")
        }

        if (-not [string]::IsNullOrEmpty($TaskId)) {
            $promptText = $promptText.Replace("{session_dir}", (".crucible/session/" + $TaskId))
        } else {
            # Legacy: use role-scoped path
            $promptText = $promptText.Replace("{session_dir}", (".crucible/session/" + $handoff.target_phase))
        }

        $promptText = $promptText.Replace("{type}", $typeDir)

        # Handoff context injection
        $promptText = $promptText.Replace("{handoff_reason}", $handoff.reason)

        # Build previous-session summary from event log
        $prevSummaryLines = @()
        $lastSessionEnd = Get-LastEntry -TaskId $handoff.task_id -Phase $handoff.source_phase -Event "session_end" -LogFile $LOG_FILE
        if ($lastSessionEnd) {
            $prevSummaryLines += ("- **Last phase**: " + $handoff.source_phase + " (completed " + $lastSessionEnd.timestamp + ")")
            $reasonText = $handoff.reason
            if ($reasonText.Length -gt 80) { $reasonText = $reasonText.Substring(0, 80) + "..." }
            $prevSummaryLines += ("- **Handoff reason**: " + $reasonText)
            if ($handoff.psobject.Properties["review_strike_count"] -and $handoff.review_strike_count -gt 0) {
                $prevSummaryLines += ("- **Strike count**: " + $handoff.review_strike_count + "/3 - scope has already failed review " + $handoff.review_strike_count + " time(s)")
            }
            if ($handoff.cumulative_handoff_count -gt 3) {
                $prevSummaryLines += ("- **Budget note**: " + $handoff.cumulative_handoff_count + " handoffs consumed - keep this session focused")
            }
        }
        $prevSessionSummary = if ($prevSummaryLines.Count -gt 0) {
            "## Previous Session Context`n" + ($prevSummaryLines -join "`n")
        } else { "" }
        $promptText = $promptText.Replace("{prev_session_summary}", $prevSessionSummary)

        $artifactsList = if ($handoff.psobject.Properties["artifacts"] -and $null -ne $handoff.artifacts -and @($handoff.artifacts).Count -gt 0) {
            ($handoff.artifacts -join ', ')
        } else { "none listed" }
        $promptText = $promptText.Replace("{artifacts_list}", $artifactsList)

        $strikeCount = if ($handoff.psobject.Properties["review_strike_count"] -and $null -ne $handoff.review_strike_count) {
            [string]$handoff.review_strike_count
        } else { "0" }
        $promptText = $promptText.Replace("{strike_count}", $strikeCount)

        $handoffCount = [string]$handoff.cumulative_handoff_count
        $promptText = $promptText.Replace("{handoff_count}", $handoffCount)

        $budgetRemaining = if ($ceiling -gt 0) {
            [string]([math]::Max(0, $ceiling - $handoff.cumulative_handoff_count))
        } else { "unknown" }
        $promptText = $promptText.Replace("{budget_remaining}", $budgetRemaining)

        $contextBlock = "## Handoff Context`n" +
            "- **Reason**: " + $handoff.reason + "`n" +
            "- **Artifacts**: " + $artifactsList + "`n" +
            "- **Strike count**: " + $strikeCount + "/3`n" +
            "- **Budget**: " + $handoffCount + "/" + $ceiling + " handoffs used (" + $budgetRemaining + " remaining)"
        if ([int]$strikeCount -eq 2) {
            $contextBlock += "`n`n> **WARNING (Strike 2/3):** One more review failure will BLOCK this task. " +
                "Architect: reduce scope, don't attempt a full re-implementation."
        }
        $promptText = $promptText.Replace("{context_block}", $contextBlock)
    }

    # Inject Recovery Mode header if active
    if ($Recover) {
        $recoveryMarker = "unknown"
        if ($Context.ContainsKey("RecoveryMarker") -and -not [string]::IsNullOrWhiteSpace([string]$Context.RecoveryMarker)) {
            $recoveryMarker = $Context.RecoveryMarker
        }
        $recoveryMsg = "## RECOVERY MODE`n" +
                       "You are in RECOVERY MODE. Your last recorded progress was: $recoveryMarker.`n" +
                       "Please re-read the session context and continue from this point.`n" +
                       "Do not repeat work that has already been verified as complete.`n`n"
        $promptText = $recoveryMsg + $promptText
    }

    $promptText = $promptText.Trim()

    # Guard: empty prompt means the template file was empty at read time.
    # Surface this immediately rather than spawning an uninstructed agent.
    if ([string]::IsNullOrWhiteSpace($promptText)) {
        Write-Host ("`n[ERROR] Template '$templateFile' produced an empty prompt.") -ForegroundColor Red
        Write-Host "[ERROR] Verify the template file has content and re-run factory.ps1." -ForegroundColor Red
        exit 1
    }

        # Final pass for task_id (may be introduced by other replacements like context_block)
        $promptText = $promptText.Replace("{task_id}", $handoff.task_id)

        # Unresolved placeholder guard - single-brace {token} only; {{double-brace}} tokens are
        # intentional runtime substitutions that agents resolve from config.yaml, not factory.ps1.
        $unresolvedTokens = [regex]::Matches($promptText, '(?<!\{)\{[a-zA-Z_][a-zA-Z0-9_]*\}(?!\})') |
            ForEach-Object { $_.Value } | Select-Object -Unique
        if (@($unresolvedTokens).Count -gt 0) {
            Write-EventLog -Event "circuit_breaker" -TaskId $handoff.task_id -Phase $handoff.target_phase `
                -Outcome "failed" -Notes ("Unresolved template placeholders: " + ($unresolvedTokens -join ", ")) `
                -LogFile $LOG_FILE -CircuitBreakerHistoryFile $CB_HISTORY_FILE
            Write-Host ("`n[ERROR] Template " + $templateFile + " has unresolved placeholders:") -ForegroundColor Red
            $unresolvedTokens | ForEach-Object { Write-Host ("  - " + $_) -ForegroundColor Red }
            Write-Host "[ERROR] Add a replacement rule in factory.ps1 section 5 for each token." -ForegroundColor Yellow
            exit 1
        }

    $Context.TypeDir = $typeDir
    $Context.RelativeHandoffPath = $relativeHandoffPath
    $Context.TemplateFile = $templateFile
    $Context.PromptVersion = $promptVersion
    $Context.PromptText = $promptText

    return $promptText
}

function Write-FactoryPromptOutput {
    param([Parameter(Mandatory=$true)][hashtable]$Context)

    Assert-FactorySessionOutputContext -Context $Context -RequiredKeys @(
        "Handoff", "SessionDir", "TaskId", "PromptText", "PromptVersion", "Ceiling"
    )

    $handoff = $Context.Handoff
    $sessionDir = $Context.SessionDir
    $TaskId = $Context.TaskId
    $promptText = $Context.PromptText
    $promptVersion = $Context.PromptVersion
    $ceiling = $Context.Ceiling

    # --- 6. Output Command ---
    # P-1: Write assembled prompt to file; emit short invocation command
    $targetSubDir = if (-not [string]::IsNullOrEmpty($TaskId)) {
        Join-Path $sessionDir "$TaskId/$($handoff.target_phase)"
    } else {
        Join-Path $sessionDir $($handoff.target_phase)
    }
    if (-not (Test-Path $targetSubDir)) { New-Item -ItemType Directory -Force -Path $targetSubDir | Out-Null }
    $promptFilePath = Join-Path $targetSubDir "prompt.md"
    $promptText | Set-Content -Path $promptFilePath -Encoding UTF8
    Write-Quiet ("[INIT] Prompt written to $promptFilePath") -ForegroundColor DarkGray

    Write-Quiet "`n[FACTORY] Handoff validated. Next step prepared." -ForegroundColor Green
    Write-Quiet "----------------------------------------------------"
    if (-not [string]::IsNullOrEmpty($TaskId)) {
        Write-Quiet ("PIPELINE  : scoped to " + $TaskId) -ForegroundColor Cyan
    } else {
        Write-Quiet ("PIPELINE  : unscoped (legacy mode)") -ForegroundColor DarkGray
    }
    Write-Quiet ("TASK ID   : " + $handoff.task_id) -ForegroundColor White
    Write-Quiet ("CYCLE ID  : " + $env:FACTORY_CYCLE_ID) -ForegroundColor DarkGray
    Write-Quiet ("FROM      : " + $handoff.source_phase) -ForegroundColor White
    Write-Quiet ("TO        : " + $handoff.target_phase) -ForegroundColor White
    if ($handoff.review_strike_count -gt 0) {
        $strikeColor = "White"
        if ($handoff.review_strike_count -ge 2) { $strikeColor = "Yellow" }
        Write-Quiet ("STRIKE    : " + $handoff.review_strike_count + "/3") -ForegroundColor $strikeColor
    }
    Write-Quiet ("BUDGET    : " + $handoff.budget_tier + " (" + $handoff.cumulative_handoff_count + "/" + $ceiling + ")") -ForegroundColor White
    Write-Quiet ("REASON    : " + $handoff.reason) -ForegroundColor Gray
    Write-Quiet ("TEMPLATE  : " + $handoff.target_phase + " (v: " + $promptVersion + ")") -ForegroundColor Gray

    $Context.TargetSubDir = $targetSubDir
    $Context.PromptFilePath = $promptFilePath
}

function Initialize-FactoryTargetSession {
    param([Parameter(Mandatory=$true)][hashtable]$Context)

    Assert-FactorySessionOutputContext -Context $Context -RequiredKeys @(
        "Handoff", "SessionDir", "BacklogDir", "RepoRoot", "CrucibleRoot", "FrameworkPowerShell", "TaskId",
        "Init", "TypeDir", "BudgetCeilings", "Ceiling", "RelativeHandoffPath", "WorkspacesDir"
    )

    $handoff = $Context.Handoff
    $sessionDir = $Context.SessionDir
    $backlogDir = $Context.BacklogDir
    $REPO_ROOT = $Context.RepoRoot
    $crucibleRoot = $Context.CrucibleRoot
    $resolvedCrucibleRoot = if ([System.IO.Path]::IsPathRooted($crucibleRoot)) { $crucibleRoot } else { Join-Path $REPO_ROOT $crucibleRoot }
    $FRAMEWORK_POWERSHELL = $Context.FrameworkPowerShell
    $TaskId = $Context.TaskId
    $Init = [bool]$Context.Init
    $typeDir = $Context.TypeDir
    $budgetCeilings = $Context.BudgetCeilings
    $ceiling = $Context.Ceiling
    $relativeHandoffPath = $Context.RelativeHandoffPath
    $workspacesDir = $Context.WorkspacesDir

    if ($Init -and $handoff.target_phase -eq "grooming") {
        Write-Quiet "[INIT] Identifying target task for Groomer..." -ForegroundColor Cyan
        $backlogPath = Join-Path $backlogDir "BACKLOG.md"
        if (Test-Path $backlogPath) {
            $backlogContent = Get-Content $backlogPath -Raw -Encoding UTF8
            $readyItems = $backlogContent -split "`n" | Where-Object { $_ -match "\|\s*Ready\s*\|" }
            
            $candidates = @()
            foreach ($item in $readyItems) {
                if ($item -match '\|\s*\[?([FBC]-[0-9]+)') {
                    $tid = $matches[1]
                    $type = if ($tid -match "^F-") { "features" } elseif ($tid -match "^B-") { "bugs" } else { "chores" }
                    $specFiles = Get-ChildItem -Path (Join-Path $backlogDir "$type/active") -Filter "$($tid)_*.md" -ErrorAction SilentlyContinue
                    if ($specFiles) {
                        $specFile = $specFiles | Select-Object -First 1
                        $fm = Get-Content $specFile.FullName -Head 10 -Encoding UTF8
                        $priority = "P3"
                        $createdAt = "9999-99-99"
                        foreach ($fml in $fm) {
                            if ($fml -match 'priority:\s*"(P[0-3])"') { $priority = $matches[1] }
                            if ($fml -match 'created_at:\s*"(20[0-9]{2}-[0-9]{2}-[0-9]{2})"') { $createdAt = $matches[1] }
                        }
                        $candidates += [PSCustomObject]@{ TaskId = $tid; Priority = $priority; CreatedAt = $createdAt }
                    }
                }
            }
            
            if ($candidates.Count -gt 0) {
                $selected = $candidates | Sort-Object Priority, CreatedAt | Select-Object -First 1
                if ($selected.TaskId -eq $handoff.task_id) {
                    Write-Quiet "[INIT] Confirmed task: $($selected.TaskId) (Priority: $($selected.Priority))" -ForegroundColor Green
                } else {
                    Write-Quiet "[INIT] Next Ready task is $($selected.TaskId); keeping scoped handoff task $($handoff.task_id)." -ForegroundColor Yellow
                }
            } else {
                Write-Quiet "[INIT] No 'Ready' tasks found in backlog." -ForegroundColor Yellow
            }
        }
    }

    if ($handoff.target_phase -eq "implementation") {
        $wtPath = Resolve-ImplementationWorktreePath -TaskId $handoff.task_id -WorkspacesDir $workspacesDir
        Write-Quiet ("WORKTREE  : " + $wtPath) -ForegroundColor Cyan
        
        if ($Init) {
            # Enable per-worktree config
            if ((git config extensions.worktreeConfig) -ne "true") {
                Write-Quiet "[INIT] Enabling extensions.worktreeConfig..." -ForegroundColor Gray
                git config extensions.worktreeConfig true
            }

            # Prune stale worktrees first
            Invoke-GitChecked { git worktree prune }

            if (-not (Test-Path $wtPath)) {
                Write-Quiet ("[INIT] Creating git worktree at " + $wtPath + "...") -ForegroundColor Yellow
                $mainBranch = Get-PrimaryBranchName
                $taskBranch = "task/" + $handoff.task_id
                git show-ref --verify --quiet ("refs/heads/" + $taskBranch)
                # git worktree add prints "Preparing worktree" to stderr on success; under Windows
                # PowerShell 5.1 with EAP=Stop that benign stderr becomes a terminating
                # NativeCommandError and aborts -Init before task.md is written. Invoke-GitChecked
                # localizes EAP, demotes exit-0 stderr to a notice, and preserves $LASTEXITCODE.
                if ($LASTEXITCODE -eq 0) {
                    Invoke-GitChecked { git worktree add $wtPath $taskBranch }
                } else {
                    Invoke-GitChecked { git worktree add $wtPath -b $taskBranch $mainBranch }
                }
                if ($LASTEXITCODE -ne 0) {
                    Write-Host ("Error: Failed to create implementation worktree at " + $wtPath) -ForegroundColor Red
                    exit 1
                }
                # Resolve absolute path for architect hooks and ensure it exists
                $adopterHook = Join-Path $FRAMEWORK_POWERSHELL "..\..\scripts\hooks\architect"
                $repoHook = Join-Path $REPO_ROOT "scripts/hooks/architect"
                if (Test-Path $adopterHook) {
                    $hookDir = $adopterHook
                } else {
                    $hookDir = $repoHook
                }
                if (-not (Test-Path $hookDir)) {
                    New-Item -ItemType Directory -Force -Path $hookDir | Out-Null
                }
                git -C $wtPath config --worktree core.hooksPath $hookDir

            } else {
                Write-Quiet ("[INIT] Worktree already exists at $wtPath.") -ForegroundColor Cyan
            }

            # Create task-scoped session directory
            $archSessionDir = if (-not [string]::IsNullOrEmpty($TaskId)) {
                Join-Path $sessionDir "$TaskId/implementation"
            } else {
                Join-Path $sessionDir "implementation"
            }
            if (-not (Test-Path $archSessionDir)) {
                New-Item -ItemType Directory -Force -Path $archSessionDir | Out-Null
                Write-Quiet ("[INIT] Created session dir: $archSessionDir") -ForegroundColor Gray
            }
        }
    }

    if ($Init) {
        # Initialize task.md for the target phase - task-scoped when -TaskId is set
        $targetDir = if (-not [string]::IsNullOrEmpty($TaskId)) {
            Join-Path $sessionDir "$TaskId/$($handoff.target_phase)"
        } else {
            Join-Path $sessionDir $handoff.target_phase
        }
        if (-not (Test-Path $targetDir)) {
            New-Item -ItemType Directory -Force -Path $targetDir | Out-Null
        }
        $taskFile = Join-Path $targetDir "task.md"
        if (-not (Test-Path $taskFile)) {
            Write-Quiet ("[INIT] Initializing " + $taskFile + "...") -ForegroundColor Yellow
            $wtPath = Resolve-ImplementationWorktreePath -TaskId $handoff.task_id -WorkspacesDir $workspacesDir
            $sessionPath = if (-not [string]::IsNullOrEmpty($TaskId)) {
                Join-Path $sessionDir $TaskId
            } else {
                Join-Path $sessionDir $handoff.target_phase
            }
            
            $affinitySection = ""
            if ($handoff.psobject.Properties["file_affinity"] -and $handoff.file_affinity -ne $null -and @($handoff.file_affinity).Count -gt 0) {
                $affinitySection = "`n## Scope Boundary (File Affinity)`n- " + ($handoff.file_affinity -join "`n- ") + "`n"
            }

            # Resolve backlog item path so agents don't need to search
            $backlogItemPath = "unknown"
            if ($typeDir -ne "unknown") {
                $activeFile = Get-ChildItem -Path (Join-Path $backlogDir ($typeDir + "/active")) -Filter ($handoff.task_id + "_*.md") -ErrorAction SilentlyContinue | Select-Object -First 1
                if ($activeFile) {
                    $backlogItemPath = Join-Path $backlogDir ($typeDir + "/active/" + $activeFile.Name)
                } else {
                    # Fall back to root of type dir (Groomer may not have moved it yet)
                    $rootFile = Get-ChildItem -Path (Join-Path $backlogDir $typeDir) -Filter ($handoff.task_id + "_*.md") -ErrorAction SilentlyContinue | Select-Object -First 1
                    if ($rootFile) { $backlogItemPath = Join-Path $backlogDir ($typeDir + "/" + $rootFile.Name) }
                }
            }

            # Validate budget_tier against backlog spec to prevent agent budget escalation (Fix 10)
            if ($backlogItemPath -ne "unknown" -and (Test-Path $backlogItemPath)) {
                $specFrontmatter = Get-Content $backlogItemPath -Head 20 -Encoding UTF8
                foreach ($fml in $specFrontmatter) {
                    if ($fml -match 'budget_tier:\s*"(\w+)"') {
                        $specBudgetTier = $matches[1].ToLower()
                        if ($specBudgetTier -ne $handoff.budget_tier.ToLower()) {
                            Write-Host "[WARN] budget_tier mismatch: handoff says '$($handoff.budget_tier)' but spec says '$specBudgetTier'. Using spec value to prevent budget escalation." -ForegroundColor Yellow
                            $handoff | Add-Member -MemberType NoteProperty -Name budget_tier -Value $specBudgetTier -Force
                            if ($budgetCeilings.ContainsKey($specBudgetTier)) { $ceiling = $budgetCeilings[$specBudgetTier] }
                        }
                        break
                    }
                }
            }

            # Check dependencies before creating task file
            Check-Dependencies -BacklogItemPath $backlogItemPath -TargetSpecialist $handoff.target_phase -TaskId $handoff.task_id

            $pwshCmd = Get-PwshCommand
            $backlogPath = Join-Path $backlogDir "BACKLOG.md"
            $archiveCmd = "$pwshCmd -ExecutionPolicy Bypass -File `"$resolvedCrucibleRoot/powershell/archive-task.ps1`" -BacklogPath `"$backlogPath`" -SpecPath `"$backlogItemPath`""

            $taskLists = @{
                grooming = "- [ ] Read BACKLOG.md and identify target item (or confirm {task_id})`n- [ ] Read existing spec file or create from template`n- [ ] Validate/paraphrase any Researcher findings (never copy-paste)`n- [ ] Write detailed implementation spec with acceptance criteria`n- [ ] Set ``depends_on`` frontmatter if applicable`n- [ ] Update BACKLOG.md status + run validate-backlog.ps1`n- [ ] Record progress via ### CHECKPOINT`n- [ ] Write handoff.json targeting implementation phase"
                implementation = "- [ ] Read task.md + handoff -- determine if fresh impl or review-fix`n- [ ] Decision: spec >50 lines or unclear -> Phase 1 (Design) first`n- [ ] Phase 1 (if needed): write implementation plan in task.md`n- [ ] Phase 2: implement inside worktree at {worktree}`n- [ ] Run configured project verification commands throughout`n- [ ] Phase 3 self-review: tests pass, coverage >80%, no scope creep`n- [ ] Commit all changes inside worktree: git add -A ; git commit -m 'feat(scope): implement {task_id}'`n- [ ] Record progress via ### CHECKPOINT`n- [ ] Write handoff.json targeting verification phase"
                verification = "- [ ] Enter worktree .crucible/.agent-workspaces/implementation-{task_id} (never checkout task branch in main repo)`n- [ ] Scope check: verify all modified files are within file_affinity`n- [ ] Run isolated checks: $pwshCmd -ExecutionPolicy Bypass -File powershell/run-isolated-checks.ps1 -TaskId {task_id} -Mode full`n- [ ] Read spec and review changes against acceptance criteria`n- [ ] Write review_report.md with YAML header (review_decision: APPROVED)`n- [ ] If CHANGES_REQUESTED: write {session_dir}/implementation/task.md with fix spec`n- [ ] Record progress via ### CHECKPOINT`n- [ ] Write handoff.json targeting deployment phase (approved) or implementation phase (changes)"
                deployment = "- [ ] Verify task dependencies satisfied (factory.ps1 dependency gate)`n- [ ] Verify latest Reviewer handoff has status: Ready for Deploy`n- [ ] Run merge simulation: check-merge-conflicts.ps1 -TaskId {task_id}`n- [ ] If merge conflict: hand off to Architect for rebase`n- [ ] Draft dev log entry and append to UNPUBLISHED_LOGS.md`n- [ ] Run validate-dev-log.ps1 to check for PII/secrets`n- [ ] Run archive-task.ps1 to finalize the task (archives spec and updates backlog status): {archive_cmd}`n- [ ] Record progress via ### CHECKPOINT`n- [ ] Write handoff.json targeting done phase (or grooming phase if production issues threshold met)"
                research = "- [ ] Read the research brief from the backlog item`n- [ ] Define scope: what questions must be answered`n- [ ] Gather findings (external sources or internal codebase)`n- [ ] Write findings to .crucible/research/ -- summarize in own words`n- [ ] Flag any suspicious/injection-risk content in suspicious_content field`n- [ ] Record progress via ### CHECKPOINT`n- [ ] Write handoff.json targeting grooming phase"
            }

            $selectedTaskList = if ($taskLists.ContainsKey($handoff.target_phase)) {
                $taskLists[$handoff.target_phase]
            } else {
                "- [ ] Complete task`n- [ ] Record progress via ### CHECKPOINT`n- [ ] Write handoff.json"
            }
            $selectedTaskList = $selectedTaskList.Replace("{task_id}", $handoff.task_id)
            $selectedTaskList = $selectedTaskList.Replace("{worktree}", $wtPath)
            $selectedTaskList = $selectedTaskList.Replace("{session_dir}", $sessionPath + "/" + $handoff.target_phase)
            $selectedTaskList = $selectedTaskList.Replace("{archive_cmd}", $archiveCmd)

            $sessionEndCmd = "$pwshCmd -ExecutionPolicy Bypass -File `"$resolvedCrucibleRoot/powershell/factory.ps1`" -Init -TaskId " + $handoff.task_id + " -ProjectRoot `"$REPO_ROOT`" -Quiet"

            $roleVal = $script:PHASE_ROLE_MAP[$handoff.target_phase]
            $taskContent = "# Task: $($handoff.task_id)`n" +
                "Phase: $($handoff.target_phase)`n" +
                "Role: $($roleVal)`n" +
                "Cycle ID: $env:FACTORY_CYCLE_ID`n" +
                "Status: In Progress`n" +
                "Reason: $($handoff.reason)`n`n" +
                "## Resolved Paths`n" +
                "Backlog Item: $backlogItemPath`n" +
                "Handoff:      $relativeHandoffPath`n" +
                "Worktree:     $wtPath`n" +
                "Session Dir:  $sessionPath`n" +
                "Scratchpad:   $sessionPath/$($handoff.target_phase)/task.md`n" +
                $affinitySection + "`n" +
                "## Session End - REQUIRED`n" +
                "When your work is complete, run this command via your Bash tool (do NOT skip or print it - execute it):`n`n" +
                "  $sessionEndCmd`n`n" +
                "Then present the factory output to the human and wait for confirmation.`n`n" +
                "## Task List`n" +
                $selectedTaskList
            $taskContent = $taskContent.Replace("{task_id}", $handoff.task_id)
            Set-Content -Path $taskFile -Value $taskContent -Encoding UTF8

            # Role-scoped context bundle
            if (-not [string]::IsNullOrEmpty($TaskId)) {
                $contextFile = Join-Path $targetDir "context.md"
                $contextContent = "# Context Bundle: $($handoff.task_id)`n" +
                           "Generated: $((Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ"))`n" +
                           "Phase: $($handoff.target_phase)`n" +
                           "Role: $($roleVal)`n" +
                           "Cycle ID: $env:FACTORY_CYCLE_ID`n`n" +
                           "## Handoff Metadata`n" +
                           "- Source: $($handoff.source_phase)`n" +
                           "- Reason: $($handoff.reason)`n" +
                           "- Handoff Count: $($handoff.cumulative_handoff_count)`n" +
                           "- Budget Tier: $($handoff.budget_tier)`n"
                
                if ($handoff.psobject.Properties["file_affinity"]) {
                    $contextContent += "`n## File Affinity`n"
                    $handoff.file_affinity | ForEach-Object { $contextContent += "- $($_)`n" }
                }
                
                $contextContent | Set-Content -Path $contextFile -Encoding UTF8
                Write-Quiet "[INIT] Context bundle generated: $contextFile" -ForegroundColor DarkGray
            }
        }
    }

    $Context.Handoff = $handoff
    $Context.Ceiling = $ceiling
}

function Write-FactoryCiStatusBanner {
    param([Parameter(Mandatory=$true)][hashtable]$Context)

    Assert-FactorySessionOutputContext -Context $Context -RequiredKeys @(
        "Handoff", "Target", "PromptFilePath", "AutoAdvance", "IsBootstrap", "NextFactoryCommand", "SessionDir"
    )

    $handoff = $Context.Handoff
    $Target = $Context.Target
    $promptFilePath = $Context.PromptFilePath
    $AutoAdvance = [bool]$Context.AutoAdvance
    $isBootstrap = [bool]$Context.IsBootstrap
    $nextFactoryCmd = $Context.NextFactoryCommand

    # --- CI Status Banner ---
    # Surface CI health before the agent starts work so regressions are visible immediately.
    $ghAvailable = $null -ne (Get-Command gh -ErrorAction SilentlyContinue)
    if ($ghAvailable) {
        try {
            $ciBranch = Get-PrimaryBranchName
            $ghOutput = Invoke-NativeCommand -Command "gh" -Arguments "run", "list", "--branch=$ciBranch", "--limit", "1", "--json", "conclusion,status,url"
            $ciJson = $ghOutput | ConvertFrom-Json
            if ($ciJson -and $ciJson.Count -gt 0) {
                $run = $ciJson[0]
                $ciStatus = $run.status
                $ciConclusion = $run.conclusion
                $ciUrl = $run.url
                if ($ciStatus -eq "in_progress" -or $ciStatus -eq "queued") {
                    Write-Quiet "[CI] ${ciBranch}: RUNNING - $ciUrl" -ForegroundColor Yellow
                } elseif ($ciConclusion -eq "success") {
                    Write-Quiet "[CI] ${ciBranch}: GREEN" -ForegroundColor Green
                } elseif ($ciConclusion -eq "failure") {
                    Write-Quiet "[CI] ${ciBranch}: FAILING - $ciUrl" -ForegroundColor Red
                    Write-Quiet "     Fix CI before starting new work, or verify this task IS the fix." -ForegroundColor Red
                } else {
                    Write-Quiet ("[CI] " + $ciBranch + ": " + $ciConclusion + " / " + $ciStatus) -ForegroundColor Gray
                }
            } else {
                Write-Quiet "[CI] ${ciBranch}: no recent runs found" -ForegroundColor Gray
            }
        } catch {
            Write-Quiet "[CI] status unavailable (no GitHub remote, or gh could not reach the repo) - skipping" -ForegroundColor Gray
        }
    } else {
        Write-Quiet "[CI] WARN: gh not found - cannot check CI status" -ForegroundColor Gray
    }

    # Short invocation - agent reads prompt.md rather than receiving it inline (P-1)
    $roleName = $script:PHASE_ROLE_MAP[$handoff.target_phase]
    $targetDisplay = $roleName.Substring(0,1).ToUpper() + $roleName.Substring(1)
    $shortPrompt = "$($targetDisplay): $($handoff.task_id) - read and follow all instructions in $promptFilePath"
    $actionCmd = $Target + " " + '"' + $shortPrompt + '"'

    $designRequired = $false
    if ($handoff.PSObject.Properties["design_required"]) { $designRequired = [bool]$handoff.design_required }
    $handoffTier = if ($handoff.PSObject.Properties["budget_tier"]) { [string]$handoff.budget_tier } else { "" }
    $recommendedModel = Get-SpecialistModel -TargetPhase $handoff.target_phase -BudgetTier $handoffTier -DesignRequired $designRequired

    # Gate transitions always require human confirmation regardless of -AutoAdvance.
    # Research Gate is enforced by Researcher SOP; Human Gate fires on all operator handoffs.
    $isGateTransition = (($handoff.source_phase -eq "deployment") -or ($handoff.source_phase -eq "research")) -and -not $isBootstrap
    $shouldAutoAdvance = $AutoAdvance -and -not $isGateTransition

    Write-NextStep -SessionDir $Context.SessionDir -Command $nextFactoryCmd -TaskId $handoff.task_id -Specialist $handoff.target_phase -ActionCmd $actionCmd -RecommendedModel $recommendedModel -ShouldAutoAdvance:$shouldAutoAdvance

    $Context.ActionCmd = $actionCmd
    $Context.ShouldAutoAdvance = $shouldAutoAdvance
}

function Start-FactoryTargetSessionLog {
    param([Parameter(Mandatory=$true)][hashtable]$Context)

    Assert-FactorySessionOutputContext -Context $Context -RequiredKeys @("Handoff", "Recover", "LogFile", "CircuitBreakerHistoryFile")

    $handoff = $Context.Handoff
    $Recover = [bool]$Context.Recover
    $LOG_FILE = $Context.LogFile
    $CB_HISTORY_FILE = $Context.CircuitBreakerHistoryFile

    # --- 7. Log Session Start for Target ---
    if ($Recover) {
        # recovery_start already logged in Section 2d
    } else {
        $lastStart = Get-LastEntry -TaskId $handoff.task_id -Phase $handoff.target_phase -Event "session_start" -LogFile $LOG_FILE
        $lastStartHandoffCount = if ($lastStart -and $lastStart.PSObject.Properties['handoff_count']) { $lastStart.handoff_count } else { 0 }
        if (-not $lastStart -or $lastStartHandoffCount -lt $handoff.cumulative_handoff_count) {
            Write-EventLog -Event "session_start" -TaskId $handoff.task_id -Phase $handoff.target_phase -HandoffCount $handoff.cumulative_handoff_count -LogFile $LOG_FILE -CircuitBreakerHistoryFile $CB_HISTORY_FILE
        }
    }
}
