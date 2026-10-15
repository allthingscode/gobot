# Match rule terms without freezing editorial wording. TODO item 194.
# Tests for prompt/session output helpers.

$ErrorActionPreference = "Stop"
$REPO_ROOT = (Resolve-Path -Path "$PSScriptRoot/../..").Path
. (Join-Path $PSScriptRoot '_harness.ps1')
. (Join-Path $REPO_ROOT "powershell/lib/platform.ps1")
$CRUCIBLE_LIB = Join-Path $REPO_ROOT "powershell/crucible-lib.ps1"
$Quiet = $true
. $CRUCIBLE_LIB

if (-not (Get-Command Check-Dependencies -ErrorAction SilentlyContinue)) {
    function Check-Dependencies {
        param([string]$BacklogItemPath, [string]$TargetSpecialist, [string]$TaskId)
    }
}

$results = @()







function New-TestContext {
    param(
        [Parameter(Mandatory=$true)][string]$TempRoot,
        [string]$TaskId = "F-901",
        [string]$TargetPhase = "verification"
    )

    $sessionDir = Join-Path $TempRoot "session"
    $handoffDir = Join-Path $sessionDir "handoffs"
    $backlogDir = Join-Path $TempRoot "backlog"
    $promptDir = Join-Path $TempRoot "prompts"
    $frameworkDir = Join-Path $TempRoot "powershell"
    New-Item -ItemType Directory -Path $handoffDir, $backlogDir, $promptDir, $frameworkDir -Force | Out-Null

    $handoffPath = Join-Path $handoffDir "$TaskId-20260527T120000Z.json"
    "{}" | Set-Content -LiteralPath $handoffPath -Encoding UTF8

    return @{
        RepoRoot = $TempRoot
        CrucibleRoot = ".crucible"
        FrameworkPowerShell = $frameworkDir
        SessionDir = $sessionDir
        BacklogDir = $backlogDir
        WorkspacesDir = Join-Path $TempRoot "workspaces"
        HandoffDir = $handoffDir
        PromptLib = $promptDir
        LogFile = Join-Path $sessionDir "$TaskId/pipeline.log.jsonl"
        CircuitBreakerHistoryFile = Join-Path $sessionDir "global/circuit_breakers.jsonl"
        TaskId = $TaskId
        Target = "agent"
        Init = $true
        Recover = $false
        Quiet = $true
        AutoAdvance = $false
        GateOutcome = $null
        GateRedirectTarget = $null
        GateReason = $null
        BudgetCeilings = @{ low = 6; medium = 10; high = 24; extended = 32 }
        Ceiling = 6
        Handoff = [PSCustomObject]@{
            task_id = $TaskId
            source_phase = "grooming"
            target_phase = $TargetPhase
            cumulative_handoff_count = 1
            handoff_retry_count = 0
            review_strike_count = 0
            rebase_count = 0
            budget_tier = "low"
            reason = "unit test"
            artifacts = @("artifact.md")
            file_affinity = @("src/")
        }
        LatestHandoff = Get-Item $handoffPath
        RelativeHandoffPath = ".crucible/session/handoffs/" + (Split-Path -Leaf $handoffPath)
        CumulativeHandoffCount = 1
        IsBootstrap = $false
        Transition = "grooming -> verification"
        NextCrucibleCommand = "$((Get-PwshCommand)) -ExecutionPolicy Bypass -File `".crucible/powershell/crucible.ps1`" -Init -TaskId $TaskId -Quiet"
    }
}

$tempRoot = New-TestFixtureRoot -NameHint "session-output-test"

try {

    $results += Run-Test -Name "Generated handoff reference uses supplied custom session (item 188)" -Body {
        $ctx = New-TestContext -TempRoot (Join-Path $tempRoot "custom-handoff") -TaskId "F-188" -TargetPhase "verification"
        [System.IO.File]::WriteAllText((Join-Path $ctx.PromptLib "verification_prompt.md"), "<!-- prompt_version: test-v1 -->`nHandoff {handoff_file}`n", [System.Text.UTF8Encoding]::new($false))
        New-CruciblePromptText -Context $ctx | Out-Null
        Assert-Result -Name "handoff reference matches actual file" -Condition ($ctx.RelativeHandoffPath -eq $ctx.LatestHandoff.FullName) -FailureMessage $ctx.RelativeHandoffPath
    }

    $results += Run-Test -Name "Verification checklist uses supplied custom worktree (item 188)" -Body {
        $ctx = New-TestContext -TempRoot (Join-Path $tempRoot "custom-checklist") -TaskId "F-188" -TargetPhase "verification"
        $ctx.TypeDir = "features"
        $env:CRUCIBLE_CYCLE_ID = "item188-checklist"
        Initialize-CrucibleTargetSession -Context $ctx
        $text = Get-Content (Join-Path $ctx.SessionDir "F-188/verification/task.md") -Raw
        $wt = Join-Path $ctx.WorkspacesDir "implementation-F-188"
        Assert-Result -Name "checklist worktree" -Condition ($text.Contains("Enter worktree $wt")) -FailureMessage $text
    }

    $results += Run-Test -Name "Write-NextStep writes expected content with explicit SessionDir" -Body {
        $sessionDir = Join-Path $tempRoot "next-step/session"
        $command = "$((Get-PwshCommand)) -File crucible.ps1 -Init -TaskId F-901"

        Write-NextStep -SessionDir $sessionDir -Command $command -TaskId "F-901" -Specialist "verification"

        $file = Join-Path $sessionDir "F-901/verification/next_step.txt"
        Assert-Result -Name "next_step exists" -Condition (Test-Path -LiteralPath $file) -FailureMessage "next_step.txt was not written"
        $content = (Get-Content -LiteralPath $file -Raw -Encoding UTF8) -replace "`r`n", "`n"
        $expected = ("=== SESSION END COMMAND ===`nRun this via Bash tool when your work is complete:`n`n$command`n" + "`n") -replace "`r`n", "`n"
        Assert-Result -Name "next_step content" -Condition ($content -eq $expected) -FailureMessage "next_step.txt content changed"
    }

    $results += Run-Test -Name "Write-NextStep names the target and tells grok to omit model" -Body {
        $sessionDir = Join-Path $tempRoot "model-line/session"
        $grokLines = @(Write-NextStep -SessionDir $sessionDir -Command "init" -TaskId "F-911" -Specialist "grooming" -ActionCmd "go" -RecommendedModel "inherit" -RecommendedTarget "grok" 6>&1 | ForEach-Object { "$_" })
        $grokLine = @($grokLines | Where-Object { $_ -match '\[RECOMMENDED MODEL\]' })
        Assert-Result -Name "grok line omits model" -Condition ($grokLine.Count -eq 1 -and $grokLine[0] -match 'inherit \(target grok\) - omit model') -FailureMessage ("got: " + ($grokLine -join " | "))
        Assert-Result -Name "grok line does not name a Claude slug" -Condition ($grokLine[0] -notmatch 'sonnet|opus|haiku') -FailureMessage ("got: " + $grokLine[0])

        $claudeLines = @(Write-NextStep -SessionDir $sessionDir -Command "init" -TaskId "F-912" -Specialist "grooming" -ActionCmd "go" -RecommendedModel "claude-sonnet-5-5" -RecommendedTarget "claude" 6>&1 | ForEach-Object { "$_" })
        $claudeLine = @($claudeLines | Where-Object { $_ -match '\[RECOMMENDED MODEL\]' })
        Assert-Result -Name "claude line names its target" -Condition ($claudeLine.Count -eq 1 -and $claudeLine[0] -match 'claude-sonnet-5-5 \(target claude\) - dispatch the specialist') -FailureMessage ("got: " + ($claudeLine -join " | "))
        Assert-Result -Name "claude with no level prints no level" -Condition (-not ($claudeLines -match '\[RECOMMENDED LEVEL\]')) -FailureMessage ("got: " + ($claudeLines -join " | "))
    }

    # Item 163: a Codex level is a model and an effort together, so it is printed as one pair.
    $results += Run-Test -Name "Write-NextStep prints a Codex level as one model and effort pair" -Body {
        $sessionDir = Join-Path $tempRoot "level-line/session"
        $lines = @(Write-NextStep -SessionDir $sessionDir -Command "init" -TaskId "F-914" -Specialist "grooming" -ActionCmd "go" -RecommendedModel "gpt-6.1-sol" -RecommendedTarget "codex" -RecommendedEffort "low" -RecommendedLevel "default" 6>&1 | ForEach-Object { "$_" })
        $level = @($lines | Where-Object { $_ -match '\[RECOMMENDED LEVEL\]' })
        Assert-Result -Name "level line is the pair" -Condition ($level.Count -eq 1 -and $level[0] -match '\[RECOMMENDED LEVEL\] default = gpt-6\.1-sol at low effort \(target codex\)') -FailureMessage ("got: " + ($lines -join " | "))
        $effort = @($lines | Where-Object { $_ -match '\[RECOMMENDED EFFORT\]' })
        Assert-Result -Name "effort line names its model" -Condition ($effort.Count -eq 1 -and $effort[0] -match 'low - .*-Model gpt-6\.1-sol') -FailureMessage ("got: " + ($effort -join " | "))
    }

    # Item 212: a Claude tier is a level too; the effort goes to the Agent tool's effort parameter.
    $results += Run-Test -Name "Write-NextStep prints a Claude level as a pair and points the effort at the Agent tool" -Body {
        $sessionDir = Join-Path $tempRoot "claude-level-line/session"
        $lines = @(Write-NextStep -SessionDir $sessionDir -Command "init" -TaskId "F-916" -Specialist "grooming" -ActionCmd "go" -RecommendedModel "claude-sonnet-5-5" -RecommendedTarget "claude" -RecommendedEffort "medium" -RecommendedLevel "default" 6>&1 | ForEach-Object { "$_" })
        $level = @($lines | Where-Object { $_ -match '\[RECOMMENDED LEVEL\]' })
        Assert-Result -Name "claude level line is the pair" -Condition ($level.Count -eq 1 -and $level[0] -match '\[RECOMMENDED LEVEL\] default = claude-sonnet-5-5 at medium effort \(target claude\)') -FailureMessage ("got: " + ($lines -join " | "))
        $effort = @($lines | Where-Object { $_ -match '\[RECOMMENDED EFFORT\]' })
        Assert-Result -Name "claude effort line names the Agent tool" -Condition ($effort.Count -eq 1 -and $effort[0] -match "medium - pass as the Agent tool's effort parameter" -and $effort[0] -notmatch 'launch-codex-specialist|Codex only') -FailureMessage ("got: " + ($effort -join " | "))
    }
    # Item 178: -Init prints the approval mode in effect, and a dispatch after a gate always waits.
    $results += Run-Test -Name "Write-CrucibleCiStatusBanner prints the approval mode, per-phase after a gate" -Body {
        $cases = @(
            @{ Name = "no setting"; Local = $null; Source = "grooming"; Target = "implementation"; Want = "per-phase" },
            @{ Name = "local to-gate"; Local = "to-gate"; Source = "grooming"; Target = "implementation"; Want = "to-gate" },
            @{ Name = "to-gate after the Research Gate"; Local = "to-gate"; Source = "research"; Target = "grooming"; Want = "per-phase" }
        )
        $n = 0
        foreach ($case in $cases) {
            $n++
            $ctx = New-TestContext -TempRoot (Join-Path $tempRoot ("approval-" + $n)) -TaskId "F-915" -TargetPhase $case.Target
            $ctx.Handoff.source_phase = $case.Source
            if ($null -ne $case.Local) {
                $crucibleDir = Join-Path $ctx.RepoRoot ".crucible"
                New-Item -ItemType Directory -Path $crucibleDir -Force | Out-Null
                Set-Content -LiteralPath (Join-Path $crucibleDir "config.local.yaml") -Value ("orchestration:`n  approval: " + $case.Local + "`n") -Encoding UTF8
            }
            $ctx.PromptFilePath = Join-Path $ctx.SessionDir ("F-915/" + $case.Target + "/prompt.md")
            New-Item -ItemType Directory -Path (Split-Path -Parent $ctx.PromptFilePath) -Force | Out-Null
            $oldPath = $env:PATH
            try {
                $env:PATH = ""
                $output = & { Write-CrucibleCiStatusBanner -Context $ctx } 6>&1 | Out-String
            } finally {
                $env:PATH = $oldPath
            }
            $line = @(($output -split "`r?`n") | Where-Object { $_ -match '\[APPROVAL MODE\]' })
            Assert-Result -Name ($case.Name + " -> " + $case.Want) -Condition ($line.Count -eq 1 -and $line[0] -match ('\] ' + $case.Want + ' - ')) -FailureMessage ("got: " + ($line -join " | "))
        }
    }

    $results += Run-Test -Name "New-CruciblePromptText applies replacement map" -Body {
        $ctx = New-TestContext -TempRoot (Join-Path $tempRoot "replace") -TaskId "F-902" -TargetPhase "verification"
        @"
<!-- prompt_version: 9.9.9 -->
Task {task_id}
Worktree {worktree}
Reason {handoff_reason}
Handoff {handoff_file}
Session {session_dir}
Type {type}
Artifacts {artifacts_list}
Strikes {strike_count}
Count {handoff_count}
Remaining {budget_remaining}
Ceiling {budget_ceiling}
{context_block}
{prev_session_summary}
{rebase_section}
{context_bundle_path}
"@ | Set-Content -LiteralPath (Join-Path $ctx.PromptLib "verification_prompt.md") -Encoding UTF8

        $text = New-CruciblePromptText -Context $ctx

        Assert-Result -Name "task replaced" -Condition ($text -match "Task F-902") -FailureMessage "task id was not replaced"
        Assert-Result -Name "reason replaced" -Condition ($text -match "Reason unit test") -FailureMessage "handoff reason was not replaced"
        Assert-Result -Name "type replaced" -Condition ($text -match "Type features") -FailureMessage "type dir was not replaced"
        Assert-Result -Name "version captured" -Condition ($ctx.PromptVersion -eq "9.9.9") -FailureMessage "prompt version was not captured"
        Assert-Result -Name "ceiling replaced" -Condition ($text -match "Ceiling 6") -FailureMessage "budget_ceiling was not replaced"
        # Relative forms resolved inside a worktree, which holds no copy of the gitignored
        # session dir. Item 158.
        $sessionLine = @(($text -split "`r?`n") | Where-Object { $_ -like "Session *" })[0]
        $handoffLine = @(($text -split "`r?`n") | Where-Object { $_ -like "Handoff *" })[0]
        Assert-Result -Name "session dir absolute" -Condition ($sessionLine -eq ("Session " + $ctx.SessionDir.TrimEnd('\', '/') + "/F-902")) -FailureMessage ("got: " + $sessionLine)
        Assert-Result -Name "handoff file absolute" -Condition ($handoffLine -eq ("Handoff " + $ctx.LatestHandoff.FullName)) -FailureMessage ("got: " + $handoffLine)
    }

    $results += Run-Test -Name "A rebase prompt on a main-only repository names main, not master" -Body {
        # Item 189.
        $caseRoot = Join-Path $tempRoot "rebase-main"
        $ctx = New-TestContext -TempRoot $caseRoot -TaskId "F-916" -TargetPhase "implementation"
        $ctx.RepoRoot = $caseRoot
        $ctx.Handoff | Add-Member -NotePropertyName rebase_count -NotePropertyValue 1 -Force
        & git -C $caseRoot init --quiet -b main
        & git -C $caseRoot -c user.name=T -c user.email=t@example.com commit --allow-empty -m init --quiet
        "<!-- prompt_version: 1 -->`n{rebase_section}`n" | Set-Content -LiteralPath (Join-Path $ctx.PromptLib "implementation_prompt.md") -Encoding UTF8

        $text = New-CruciblePromptText -Context $ctx

        Assert-Result -Name "rebases onto main" -Condition ($text -match 'git rebase main task/F-916' -and $text -match 'git pull origin main') -FailureMessage ("prompt: " + $text)
        Assert-Result -Name "no master" -Condition (-not ($text -match 'master')) -FailureMessage ("prompt still names master: " + $text)
    }

    $results += Run-Test -Name "A no-code review-fix gets no worktree, no branch, and the project root as its workdir" -Body {
        $caseRoot = Join-Path $tempRoot "no-code-fix"
        $ctx = New-TestContext -TempRoot $caseRoot -TaskId "R-914" -TargetPhase "implementation"
        $ctx.Handoff.source_phase = "verification"
        $ctx.RepoRoot = $caseRoot
        $ctx.TypeDir = "features"
        $ctx.Init = $true
        $activeDir = Join-Path $ctx.BacklogDir "features/active"
        New-Item -ItemType Directory -Path $activeDir -Force | Out-Null
        "---`ntype: research`n---`nSpec`n" | Set-Content -LiteralPath (Join-Path $activeDir "R-914_spec.md") -Encoding UTF8
        "# Backlog`n| [R-914](features/active/R-914_spec.md) | Spec | P2 | Ready |`n" | Set-Content -LiteralPath (Join-Path $ctx.BacklogDir "BACKLOG.md") -Encoding UTF8
        "crucible_root: `".crucible`"`npaths:`n  backlog: `"" + ($ctx.BacklogDir -replace '\\', '/') + "`"`n" | Set-Content -LiteralPath (New-Item -ItemType File -Path (Join-Path $caseRoot ".crucible/config.yaml") -Force).FullName -Encoding UTF8
        & git -C $caseRoot init --quiet -b master
        & git -C $caseRoot -c user.name=T -c user.email=t@example.com commit --allow-empty -m init --quiet

        Assert-Result -Name "classified as a no-code review-fix" -Condition (Test-NoCodeReviewFix -Handoff $ctx.Handoff -RepoRoot $caseRoot) -FailureMessage "an R-* review-fix with no task branch should be a no-code review-fix"
        $grooming = $ctx.Handoff.PSObject.Copy(); $grooming.source_phase = "grooming"
        Assert-Result -Name "a fresh implementation is not" -Condition (-not (Test-NoCodeReviewFix -Handoff $grooming -RepoRoot $caseRoot)) -FailureMessage "grooming -> implementation must keep its worktree"

        $Push = Get-Location
        Set-Location -LiteralPath $caseRoot
        try { Initialize-CrucibleTargetSession -Context $ctx 6>&1 | Out-Null } finally { Set-Location -LiteralPath $Push }

        Assert-Result -Name "no worktree created" -Condition (-not (Test-Path -LiteralPath (Join-Path $ctx.WorkspacesDir "implementation-R-914"))) -FailureMessage "a worktree was created for a no-code review-fix"
        & git -C $caseRoot show-ref --verify --quiet refs/heads/task/R-914
        Assert-Result -Name "no task branch created" -Condition ($LASTEXITCODE -ne 0) -FailureMessage "task/R-914 was created, which defeats the No-Code Closure"
        $taskText = Get-Content -LiteralPath (Join-Path $ctx.SessionDir "R-914/implementation/task.md") -Raw -Encoding UTF8
        Assert-Result -Name "task.md names the project root" -Condition ($taskText -match ('Worktree:\s+' + [regex]::Escape($caseRoot))) -FailureMessage ("task.md: " + $taskText)
        # The generated checklist must follow the SOP instead of keeping another copy
        # of its commit and handoff rules. TODO item 193.
        $sopPath = (Join-Path $caseRoot '.crucible/sops/implementation.md').Replace('\', '/')
        Assert-Result -Name "implementation checklist links the resolved SOP" -Condition ($taskText -match ('\]\(<' + [regex]::Escape($sopPath) + '#phase-3-self-review>\)')) -FailureMessage "task.md does not link implementation self-review"
        Assert-Result -Name "implementation checklist has no duplicate commit recipe" -Condition ($taskText -notmatch 'git (?:add|commit)|coverage\s*>\s*80%') -FailureMessage "task.md still repeats implementation workflow details"
        Assert-Result -Name "implementation session end links the workflow" -Condition ($taskText -match ('\]\(<' + [regex]::Escape($sopPath) + '#phase-4-handoff-to-verification>\)')) -FailureMessage "task.md still duplicates the handoff workflow"
        Assert-Result -Name "implementation checklist resolves its placeholders" -Condition ($taskText -notmatch '\{sop_path\}|\{worktree\}') -FailureMessage "task.md has unresolved implementation paths"

        "<!-- prompt_version: 1 -->`nWork in {worktree}`n" | Set-Content -LiteralPath (Join-Path $ctx.PromptLib "implementation_prompt.md") -Encoding UTF8
        $text = New-CruciblePromptText -Context $ctx
        Assert-Result -Name "prompt workdir is the project root" -Condition ($text -match ('Work in ' + [regex]::Escape($caseRoot) + '\r?\n')) -FailureMessage ("prompt: " + $text)
        Assert-Result -Name "prompt says not to branch or commit" -Condition ($text -match 'No-Code Review-Fix' -and $text -match 'do not commit') -FailureMessage ("prompt: " + $text)
    }

    $results += Run-Test -Name "The re-review after a no-code review-fix is sent to the Stub-Only Close-Out, not the isolated checker" -Body {
        $caseRoot = Join-Path $tempRoot "no-code-rereview"
        $ctx = New-TestContext -TempRoot $caseRoot -TaskId "R-915" -TargetPhase "verification"
        $ctx.Handoff.source_phase = "implementation"
        $ctx.RepoRoot = $caseRoot
        $activeDir = Join-Path $ctx.BacklogDir "features/active"
        New-Item -ItemType Directory -Path $activeDir -Force | Out-Null
        "---`ntype: research`n---`nSpec`n" | Set-Content -LiteralPath (Join-Path $activeDir "R-915_spec.md") -Encoding UTF8
        "# Backlog`n| [R-915](features/active/R-915_spec.md) | Spec | P2 | Ready |`n" | Set-Content -LiteralPath (Join-Path $ctx.BacklogDir "BACKLOG.md") -Encoding UTF8
        "crucible_root: `".crucible`"`npaths:`n  backlog: `"" + ($ctx.BacklogDir -replace '\\', '/') + "`"`n" | Set-Content -LiteralPath (New-Item -ItemType File -Path (Join-Path $caseRoot ".crucible/config.yaml") -Force).FullName -Encoding UTF8
        & git -C $caseRoot init --quiet -b master
        & git -C $caseRoot -c user.name=T -c user.email=t@example.com commit --allow-empty -m init --quiet
        "<!-- prompt_version: 1 -->`nReview {task_id}`n" | Set-Content -LiteralPath (Join-Path $ctx.PromptLib "verification_prompt.md") -Encoding UTF8

        Assert-Result -Name "classified as a no-code re-review" -Condition (Test-NoCodeReReview -Handoff $ctx.Handoff -RepoRoot $caseRoot) -FailureMessage "an R-* re-review with no task branch should be a no-code re-review"
        $text = New-CruciblePromptText -Context $ctx
        Assert-Result -Name "prompt routes to the Stub-Only Close-Out" -Condition ($text -match '## No-Code Re-Review' -and $text -match 'Stub-Only Close-Out' -and $text -match 'Do not run run-isolated-checks\.ps1') -FailureMessage ("prompt: " + $text)

        $fromGrooming = $ctx.Handoff.PSObject.Copy(); $fromGrooming.source_phase = "grooming"
        Assert-Result -Name "a first close-out review is not" -Condition (-not (Test-NoCodeReReview -Handoff $fromGrooming -RepoRoot $caseRoot)) -FailureMessage "grooming -> verification already reads as the Stub-Only Close-Out"

        & git -C $caseRoot branch task/R-915
        Assert-Result -Name "a re-review with a task branch is not" -Condition (-not (Test-NoCodeReReview -Handoff $ctx.Handoff -RepoRoot $caseRoot)) -FailureMessage "a task with a branch has code to review"
        $text = New-CruciblePromptText -Context $ctx
        Assert-Result -Name "and its prompt keeps the code review" -Condition ($text -notmatch 'No-Code Re-Review') -FailureMessage ("prompt: " + $text)
    }

    # Step 3 of the deployment prompt hands a failed merge simulation to implementation.
    # Validation refuses deployment -> implementation at rebase_count 0, so the command the
    # Operator copies has to carry the next count. Rendered from the real prompt, because
    # the defect was in the prompt, not in a fixture. Item 127.
    $results += Run-Test -Name "Deployment prompt's merge-conflict handoff carries the next rebase count" -Body {
        foreach ($incoming in @(0, 2)) {
            $ctx = New-TestContext -TempRoot (Join-Path $tempRoot ("rebase-next-" + $incoming)) -TaskId "F-907" -TargetPhase "deployment"
            $ctx.Handoff.rebase_count = $incoming
            Copy-Item -LiteralPath (Join-Path $REPO_ROOT "prompts/deployment_prompt.md") -Destination (Join-Path $ctx.PromptLib "deployment_prompt.md")

            $text = New-CruciblePromptText -Context $ctx

            $reworkLines = @(($text -split "`r?`n") | Where-Object { $_ -match 'new-handoff\.ps1' -and $_ -match '-Source deployment -Target implementation' })
            Assert-Result -Name ("incoming " + $incoming + ": one merge-conflict handoff command") -Condition ($reworkLines.Count -eq 1) -FailureMessage ("expected one deployment -> implementation new-handoff command in the rendered prompt, found " + $reworkLines.Count)
            if ($reworkLines.Count -ne 1) { continue }
            Assert-Result -Name ("incoming " + $incoming + ": command passes the next rebase count") -Condition ($reworkLines[0] -match ('-RebaseCount ' + ($incoming + 1) + '\b')) -FailureMessage ("expected -RebaseCount " + ($incoming + 1) + " in: " + $reworkLines[0])
        }
    }

    $results += Run-Test -Name "The implementation prompt links the SOP's pipeline approval rule (items 177, 193)" -Body {
        $ctx = New-TestContext -TempRoot (Join-Path $tempRoot "impl-approval") -TaskId "F-908" -TargetPhase "implementation"
        Copy-Item -LiteralPath (Join-Path $REPO_ROOT "prompts/implementation_prompt.md") -Destination (Join-Path $ctx.PromptLib "implementation_prompt.md")
        $text = New-CruciblePromptText -Context $ctx
        $sopPath = Join-Path $ctx.RepoRoot '.crucible'
        Assert-Result -Name "prompt links session start" -Condition ($text -match ('\]\(<' + [regex]::Escape($sopPath) + '/sops/implementation\.md#session-start>\)')) -FailureMessage ("prompt: " + $text)
        $sop = Get-Content -LiteralPath (Join-Path $REPO_ROOT "sops/implementation.md") -Raw -Encoding UTF8
        Assert-Result -Name "dispatch is the approval" -Condition ($sop -match '(?im)^(?=[^\r\n]*dispatch)(?=[^\r\n]*approval)(?=[^\r\n]*implement)(?=[^\r\n]*plan approval)(?=[^\r\n]*does not apply)[^\r\n]+\r?$') -FailureMessage ("SOP: " + $sop)
    }

    $results += Run-Test -Name "New-CruciblePromptText substitutes PowerShell host for non-Windows prompts" -Body {
        $oldPlatformMock = $script:MockPlatformIsWindows
        $oldPwshMock = $script:MockPwshCommandExists
        try {
            $script:MockPlatformIsWindows = $false
            $script:MockPwshCommandExists = $true
            $ctx = New-TestContext -TempRoot (Join-Path $tempRoot "pwsh-host") -TaskId "F-906" -TargetPhase "verification"
            @"
Run powershell.exe -ExecutionPolicy Bypass -File {{crucible_root}}/powershell/crucible.ps1 -Init -TaskId {task_id}
"@ | Set-Content -LiteralPath (Join-Path $ctx.PromptLib "verification_prompt.md") -Encoding UTF8

            $text = New-CruciblePromptText -Context $ctx

            Assert-Result -Name "pwsh rendered" -Condition ($text -match "\bpwsh\b") -FailureMessage "non-Windows prompt did not render pwsh: $text"
            Assert-Result -Name "windows host removed" -Condition (-not $text.Contains("powershell.exe")) -FailureMessage "non-Windows prompt still contains powershell.exe: $text"
        } finally {
            $script:MockPlatformIsWindows = $oldPlatformMock
            $script:MockPwshCommandExists = $oldPwshMock
        }
    }

    $results += Run-Test -Name "New-CruciblePromptText exits on unresolved placeholders" -Body {
        $caseRoot = Join-Path $tempRoot "unresolved"
        $script = @"
`$ErrorActionPreference = 'Stop'
`$REPO_ROOT = '$($REPO_ROOT.Replace("'", "''"))'
`$Quiet = `$true
. (Join-Path `$REPO_ROOT 'powershell/crucible-lib.ps1')
`$root = '$($caseRoot.Replace("'", "''"))'
`$session = Join-Path `$root 'session'
`$handoffs = Join-Path `$session 'handoffs'
`$prompts = Join-Path `$root 'prompts'
New-Item -ItemType Directory -Path `$handoffs,`$prompts -Force | Out-Null
`$handoffPath = Join-Path `$handoffs 'F-903-20260527T120000Z.json'
'{}' | Set-Content -LiteralPath `$handoffPath -Encoding UTF8
'Task {task_id} {missing_token}' | Set-Content -LiteralPath (Join-Path `$prompts 'verification_prompt.md') -Encoding UTF8
`$ctx = @{
    RepoRoot = `$root; CrucibleRoot = '.crucible'; FrameworkPowerShell = (Join-Path `$root 'powershell')
    SessionDir = `$session; BacklogDir = (Join-Path `$root 'backlog'); WorkspacesDir = (Join-Path `$root 'workspaces')
    HandoffDir = `$handoffs; PromptLib = `$prompts; LogFile = (Join-Path `$session 'F-903/pipeline.log.jsonl')
    CircuitBreakerHistoryFile = (Join-Path `$session 'global/circuit_breakers.jsonl'); TaskId = 'F-903'; Target = 'agent'
    Init = `$true; Recover = `$false; Quiet = `$true; AutoAdvance = `$false; BudgetCeilings = @{ low = 6 }; Ceiling = 6
    Handoff = [PSCustomObject]@{ task_id = 'F-903'; source_phase = 'grooming'; target_phase = 'verification'; cumulative_handoff_count = 1; handoff_retry_count = 0; review_strike_count = 0; rebase_count = 0; budget_tier = 'low'; reason = 'unit test'; artifacts = @(); file_affinity = @() }
    LatestHandoff = (Get-Item `$handoffPath); RelativeHandoffPath = '.crucible/session/handoffs/F-903-20260527T120000Z.json'
    CumulativeHandoffCount = 1; IsBootstrap = `$false; Transition = 'grooming -> verification'; NextCrucibleCommand = 'next'
}
New-CruciblePromptText -Context `$ctx
"@
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($script))
        $output = & (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -EncodedCommand $encoded 2>&1
        Assert-Result -Name "exit code" -Condition ($LASTEXITCODE -eq 1) -FailureMessage "unresolved placeholder did not exit 1; output: $($output | Out-String)"
        Assert-Result -Name "message" -Condition (($output | Out-String) -match "unresolved placeholders") -FailureMessage "unresolved placeholder message changed"
    }

    $results += Run-Test -Name "Write-CrucibleCiStatusBanner uses no-gh fallback" -Body {
        $ctx = New-TestContext -TempRoot (Join-Path $tempRoot "ci") -TaskId "F-904" -TargetPhase "verification"
        $ctx.PromptFilePath = Join-Path $ctx.SessionDir "F-904/verification/prompt.md"
        New-Item -ItemType Directory -Path (Split-Path -Parent $ctx.PromptFilePath) -Force | Out-Null
        $oldPath = $env:PATH
        $oldQuiet = $Quiet
        try {
            $env:PATH = ""
            $script:Quiet = $false
            $output = & { Write-CrucibleCiStatusBanner -Context $ctx } 6>&1 | Out-String
            Assert-Result -Name "fallback output" -Condition ($output -match "\[CI\] WARN: gh not found - cannot check CI status") -FailureMessage "no-gh fallback message missing"
        } finally {
            $env:PATH = $oldPath
            $script:Quiet = $oldQuiet
        }
    }

    # Item 140: the Operator's tier follows deployment trouble read from the handoff, not the budget.
    $results += Run-Test -Name "Operator recommendation escalates on handoff rebase or retry counters, not budget" -Body {
        $cases = @(
            @{ Name = "clean high-budget deployment"; Budget = "high"; Rebase = 0; Retry = 0; Want = "claude-haiku-5-5"; WantLevel = "light = claude-haiku-5-5 at high" },
            @{ Name = "rebase re-entry"; Budget = "low"; Rebase = 1; Retry = 0; Want = "claude-sonnet-5-5"; WantLevel = "default = claude-sonnet-5-5 at medium" },
            @{ Name = "retried handoff"; Budget = "low"; Rebase = 0; Retry = 1; Want = "claude-sonnet-5-5"; WantLevel = "default = claude-sonnet-5-5 at medium" }
        )
        $n = 0
        foreach ($case in $cases) {
            $n++
            $ctx = New-TestContext -TempRoot (Join-Path $tempRoot ("op-tier-" + $n)) -TaskId "F-913" -TargetPhase "deployment"
            $ctx.Handoff.budget_tier = $case.Budget
            $ctx.Handoff.rebase_count = $case.Rebase
            $ctx.Handoff.handoff_retry_count = $case.Retry
            $ctx.PromptFilePath = Join-Path $ctx.SessionDir "F-913/deployment/prompt.md"
            New-Item -ItemType Directory -Path (Split-Path -Parent $ctx.PromptFilePath) -Force | Out-Null
            $oldPath = $env:PATH
            try {
                $env:PATH = ""
                $output = & { Write-CrucibleCiStatusBanner -Context $ctx } 6>&1 | Out-String
            } finally {
                $env:PATH = $oldPath
            }
            $line = @(($output -split "`r?`n") | Where-Object { $_ -match '\[RECOMMENDED MODEL\]' })
            Assert-Result -Name ($case.Name + " -> " + $case.Want) -Condition ($line.Count -eq 1 -and $line[0] -match ('\] ' + $case.Want + ' \(target claude\)')) -FailureMessage ("got: " + ($line -join " | "))
            $levelLine = @(($output -split "`r?`n") | Where-Object { $_ -match '\[RECOMMENDED LEVEL\]' })
            Assert-Result -Name ($case.Name + " prints the Claude level") -Condition ($levelLine.Count -eq 1 -and $levelLine[0].Contains($case.WantLevel + " effort (target claude)")) -FailureMessage ("got: " + ($levelLine -join " | "))
            Assert-Result -Name ($case.Name + " prints the Agent effort line") -Condition (@(($output -split "`r?`n") | Where-Object { $_ -match "\[RECOMMENDED EFFORT\].*Agent tool's effort" }).Count -eq 1) -FailureMessage $output
        }
    }

    # Item 100: the success line on a normal run, and nothing matched it - so item 51b's
    # [FACTORY] -> [CRUCIBLE] rename of it was made on inspection alone. Its absence is the
    # signal, which is what makes it a contract rather than a message: a run that prints no
    # banner and exits 0 is indistinguishable from one that finished. See CONTRIBUTING.md,
    # "Which output strings are contracts". The literal is deliberately kept out of this
    # test's name - _harness.ps1 echoes every name on a green run, which would inject the
    # string into the very output a search for it reads.
    $results += Run-Test -Name "Write-CruciblePromptOutput emits its validated-handoff success line" -Body {
        $ctx = New-TestContext -TempRoot (Join-Path $tempRoot "prompt-output") -TaskId "F-906" -TargetPhase "verification"
        $ctx.PromptText = "# prompt body"
        $ctx.PromptVersion = "verification_prompt-v29"
        $oldQuiet = $Quiet
        try {
            $script:Quiet = $false
            $output = & { Write-CruciblePromptOutput -Context $ctx } 6>&1 | Out-String
            Assert-Result -Name "the handoff success line is present" -Condition ($output -match "\[CRUCIBLE\] Handoff validated\. Next step prepared\.") -FailureMessage ("the line an operator reads to know the run finished is missing. Output:`n" + $output)
            Assert-Result -Name "the success line is followed by its handoff summary" -Condition ($output -match "TASK ID   : F-906") -FailureMessage ("the banner printed but the summary under it did not, so the function did not run to completion and the banner alone would be misleading. Output:`n" + $output)
        } finally {
            $script:Quiet = $oldQuiet
        }
    }

    $results += Run-Test -Name "Initialize-CrucibleTargetSession writes task and context files" -Body {
        $ctx = New-TestContext -TempRoot (Join-Path $tempRoot "target") -TaskId "F-905" -TargetPhase "verification"
        $ctx.TypeDir = "features"
        $activeDir = Join-Path $ctx.BacklogDir "features/active"
        New-Item -ItemType Directory -Path $activeDir -Force | Out-Null
        @"
---
budget_tier: "low"
---
Spec body
"@ | Set-Content -LiteralPath (Join-Path $activeDir "F-905_spec.md") -Encoding UTF8
        $env:CRUCIBLE_CYCLE_ID = "testcycle"

        Initialize-CrucibleTargetSession -Context $ctx

        $taskFile = Join-Path $ctx.SessionDir "F-905/verification/task.md"
        $contextFile = Join-Path $ctx.SessionDir "F-905/verification/context.md"
        Assert-Result -Name "task exists" -Condition (Test-Path -LiteralPath $taskFile) -FailureMessage "task.md was not written"
        Assert-Result -Name "context exists" -Condition (Test-Path -LiteralPath $contextFile) -FailureMessage "context.md was not written"
        $task = Get-Content -LiteralPath $taskFile -Raw -Encoding UTF8
        $context = Get-Content -LiteralPath $contextFile -Raw -Encoding UTF8
        Assert-Result -Name "task content" -Condition ($task -match "Task: F-905" -and $task -match "Phase: verification") -FailureMessage "task.md content changed"
        Assert-Result -Name "context content" -Condition ($context -match "Context Bundle: F-905" -and $context -match "Phase: verification") -FailureMessage "context.md content changed"
    }
    $results += Run-Test -Name "Worktree creation tolerates git stderr under EAP=Stop" -Body {
        # Regression: bare `git worktree add` writes "Preparing worktree" to stderr on success,
        # which under Windows PowerShell 5.1 with EAP=Stop becomes a terminating NativeCommandError
        # and aborted -Init before task.md was written. session-output.ps1 now routes the call
        # through Invoke-GitChecked; this asserts that contract holds (no throw, exit 0, worktree made).
        $repo = Join-Path $tempRoot "wt-stderr"
        New-Item -ItemType Directory -Path $repo -Force | Out-Null
        Push-Location $repo
        try {
            git init --quiet
            git config core.autocrlf false
            git config user.email "t@t.t"
            git config user.name "t"
            Set-Content -Path "README.md" -Value "# t" -Encoding UTF8
            git add README.md
            git commit -m "init" --quiet
            $mainBranch = (git rev-parse --abbrev-ref HEAD).Trim()
            $wtPath = Join-Path $repo ".crucible/.agent-workspaces/implementation-F-907"

            $threw = $false
            $eapAtCall = $ErrorActionPreference
            try {
                Invoke-GitChecked { git worktree add $wtPath -b "task/F-907" $mainBranch }
            } catch {
                $threw = $true
            }

            Assert-Result -Name "EAP is Stop at call site" -Condition ($eapAtCall -eq "Stop") -FailureMessage "test must run under EAP=Stop to exercise the regression; was $eapAtCall"
            Assert-Result -Name "did not terminate on git stderr" -Condition (-not $threw) -FailureMessage "Invoke-GitChecked threw on benign git worktree-add stderr"
            Assert-Result -Name "git exit code 0" -Condition ($LASTEXITCODE -eq 0) -FailureMessage "worktree add exit code was $LASTEXITCODE"
            Assert-Result -Name "worktree created" -Condition (Test-Path -LiteralPath $wtPath) -FailureMessage "worktree dir was not created at $wtPath"
        } finally {
            Pop-Location
        }
    }
    $results += Run-Test -Name "session-output routes git worktree add through Invoke-GitChecked" -Body {
        # Binds the call site cross-platform: the suite drives -Init via pwsh-7 child processes,
        # which do not reproduce the PS 5.1 NativeCommandError-on-stderr behavior, so a revert to a
        # bare `git worktree add` would silently pass the runtime test above. This static guard fails
        # on any unwrapped worktree-add line, including setup moved for TODO item 197.
        $src = foreach ($relativePath in @("powershell/lib/session-output.ps1", "powershell/lib/worktree.ps1")) {
            Get-Content -LiteralPath (Join-Path $REPO_ROOT $relativePath)
        }
        $bare = @($src | Where-Object { $_ -match 'git worktree add' -and $_ -notmatch 'Invoke-GitChecked' -and $_.TrimStart() -notmatch '^#' })
        Assert-Result -Name "no unwrapped worktree add" -Condition ($bare.Count -eq 0) -FailureMessage ("found bare git worktree add line(s): " + ($bare -join " | "))
    }
    $results += Run-Test -Name "Groomer initialization confirms the scoped task without ranking (item 200)" -Body {
        $ctx = New-TestContext -TempRoot (Join-Path $tempRoot "groomer-scoped") -TaskId "R-029" -TargetPhase "grooming"
        $ctx.TypeDir = "features"
        # A Ready row without a spec must not affect the scoped message. TODO item 200.
        [IO.File]::WriteAllText((Join-Path $ctx.BacklogDir "BACKLOG.md"), "| B-101 | Other task | Ready |`n", [Text.UTF8Encoding]::new($false))
        $oldQuiet = $script:Quiet
        try {
            $script:Quiet = $false
            $output = & { Initialize-CrucibleTargetSession -Context $ctx } 6>&1 | Out-String
            Assert-Result -Name "scoped Groomer task confirmed" -Condition ($output.Contains("[INIT] Confirmed task: R-029") -and $output -notmatch "Next Ready task|No 'Ready' tasks|Identifying target task") -FailureMessage $output
            Assert-Result -Name "scoped Groomer handoff retained" -Condition ($ctx.Handoff.task_id -eq "R-029" -and (Test-Path -LiteralPath (Join-Path $ctx.SessionDir "R-029/grooming/task.md"))) -FailureMessage "named task was not retained"
        } finally {
            $script:Quiet = $oldQuiet
        }
    }
} finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

$failed = @($results | Where-Object { -not $_ }).Count
if ($failed -gt 0) {
    Write-Host ("`n$failed session-output test(s) failed.") -ForegroundColor Red
    exit 1
}
Write-Host "`nAll session-output tests passed." -ForegroundColor Green
exit 0
