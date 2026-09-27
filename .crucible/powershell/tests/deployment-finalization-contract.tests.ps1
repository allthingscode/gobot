# Tests that the deployment instructions agree with what the gates actually enforce.
#
# The gates are a matched pair keyed on whether a human has decided (crucible-gates.ps1):
# before an accepted/redirected decision exists, a terminal BACKLOG.md status is refused
# (F12); after it, a non-terminal status is refused, and the gate finalizes the task
# itself at D44. Both halves have their own tests.
#
# What had no test was the instructions. The deployment prompt, the deployment SOP and
# the generated task.md checklist all told the Operator to run archive-task.ps1 before
# the gate, which is precisely what F12 refuses, so following them could not reach the
# gate at all. Nothing in the suite compared what a prompt instructs against what a gate
# enforces, so 90 green tests stayed green while the documented path was unwalkable.
# Found by TODO item 53's Pass 29 and filed as item 56.

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

# Every document a specialist is told to read is a place the instruction can survive.
# Item 56 fixed the prompt and the SOP and pointed this test at exactly those two, so the
# same defect sat untouched in docs/operating-manual.md - which instruction-blocks.ps1
# tells every specialist to read - through a full pass and a green suite. The list is the
# guard: a fourth copy has to be added here to be trusted. Found by TODO item 73.
$operatorDocs = @(
    @{ Name = "prompts/deployment_prompt.md";  Path = "prompts/deployment_prompt.md" }
    @{ Name = "sops/deployment.md";            Path = "sops/deployment.md" }
    @{ Name = "docs/operating-manual.md";      Path = "docs/operating-manual.md" }
)

$prohibition = 'Do NOT run `archive-task.ps1`'

foreach ($doc in $operatorDocs) {
    $docName = $doc.Name
    $docText = Get-Content -LiteralPath (Join-Path $REPO_ROOT $doc.Path) -Raw -Encoding UTF8

    # Judged line by line rather than document-wide. The original check excused every
    # mention in a file that carried the prohibition anywhere in it, and only looked at
    # list items, so operating-manual.md:566 - a prose role description telling the
    # Operator to finalize - would have passed both halves of it.
    $results += Run-Test -Name "$docName does not instruct the Operator to run archive-task.ps1" -Body {
        $offending = @(($docText -split "`n") | Where-Object {
            $_ -match '\barchive-task\.ps1\b' -and $_ -notmatch [regex]::Escape($prohibition)
        })
        Assert-Result -Name "$docName leaves finalization to the gate" `
            -Condition ($offending.Count -eq 0) `
            -FailureMessage ("$docName names archive-task.ps1 outside a prohibition, which F12 refuses: " + ($offending -join " | "))
    }.GetNewClosure()

    # Saying so positively, not merely omitting it. An Operator carrying habit from the
    # old SOP needs to be told to stop, not left without an instruction.
    $results += Run-Test -Name "$docName tells the Operator not to finalize" -Body {
        Assert-Result -Name "$docName states the prohibition" `
            -Condition ($docText.Contains($prohibition)) `
            -FailureMessage "$docName should explicitly tell the Operator not to finalize"
    }.GetNewClosure()
}

$tempRoot = New-TestFixtureRoot -NameHint "deploy-finalization-test"
New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null

try {
    # The generated checklist is the third copy of the instruction, and the one the
    # required-checklist gate then demands be ticked. Leaving it in would have forced the
    # Operator to either lie on the checklist or trip F12.
    $results += Run-Test -Name "Generated deployment checklist does not instruct archiving" -Body {
        $caseRoot = Join-Path $tempRoot "generated"
        $sessionDir = Join-Path $caseRoot "session"
        $handoffDir = Join-Path $sessionDir "handoffs"
        $backlogDir = Join-Path $caseRoot "backlog"
        $promptDir = Join-Path $caseRoot "prompts"
        $activeDir = Join-Path $backlogDir "chores/active"
        New-Item -ItemType Directory -Force -Path $handoffDir, $activeDir, $promptDir | Out-Null

        @"
---
budget_tier: "low"
---
Fixture spec
"@ | Set-Content -LiteralPath (Join-Path $activeDir "C-560_Test_Spec.md") -Encoding UTF8

        $handoffPath = Join-Path $handoffDir "C-560-20260907T120000Z.json"
        "{}" | Set-Content -LiteralPath $handoffPath -Encoding UTF8

        $ctx = @{
            RepoRoot = $caseRoot
            CrucibleRoot = ".crucible"
            FrameworkPowerShell = Join-Path $caseRoot "powershell"
            SessionDir = $sessionDir
            BacklogDir = $backlogDir
            WorkspacesDir = Join-Path $caseRoot "workspaces"
            HandoffDir = $handoffDir
            PromptLib = $promptDir
            LogFile = Join-Path $sessionDir "C-560/pipeline.log.jsonl"
            CircuitBreakerHistoryFile = Join-Path $sessionDir "global/circuit_breakers.jsonl"
            TaskId = "C-560"
            TypeDir = "chores"
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
                task_id = "C-560"
                source_phase = "verification"
                target_phase = "deployment"
                cumulative_handoff_count = 4
                handoff_retry_count = 0
                review_strike_count = 0
                rebase_count = 0
                budget_tier = "low"
                reason = "Review approved - no blockers"
                artifacts = @()
                file_affinity = @("internal/")
            }
            LatestHandoff = Get-Item $handoffPath
            RelativeHandoffPath = ".crucible/session/handoffs/" + (Split-Path -Leaf $handoffPath)
            CumulativeHandoffCount = 4
            IsBootstrap = $false
            Transition = "verification -> deployment"
            NextCrucibleCommand = "$((Get-PwshCommand)) -ExecutionPolicy Bypass -File `".crucible/powershell/crucible.ps1`" -Init -TaskId C-560 -Quiet"
        }

        $env:CRUCIBLE_CYCLE_ID = "testcycle"
        Initialize-CrucibleTargetSession -Context $ctx

        $taskFile = Join-Path $sessionDir "C-560/deployment/task.md"
        Assert-Result -Name "deployment task.md was generated" `
            -Condition (Test-Path -LiteralPath $taskFile) `
            -FailureMessage "task.md was not written for the deployment phase"

        $task = Get-Content -LiteralPath $taskFile -Raw -Encoding UTF8
        Assert-Result -Name "generated deployment checklist omits archive-task.ps1" `
            -Condition ($task -notmatch 'archive-task\.ps1') `
            -FailureMessage ("generated checklist still instructs archiving: " + $task)

        # A literal, unsubstituted placeholder would be just as broken as the instruction.
        Assert-Result -Name "no unsubstituted archive placeholder leaks into task.md" `
            -Condition ($task -notmatch '\{archive_cmd\}') `
            -FailureMessage "task.md contains a literal {archive_cmd} placeholder"
    }

    # The placeholder and the value that fed it must both be gone. A left-behind
    # {archive_cmd} would render literally into the Operator's task.md.
    $results += Run-Test -Name "The archive_cmd placeholder is fully removed" -Body {
        $sessionOutput = Get-Content -LiteralPath (Join-Path $REPO_ROOT "powershell/lib/session-output.ps1") -Raw -Encoding UTF8
        Assert-Result -Name "no archive_cmd placeholder remains" `
            -Condition ($sessionOutput -notmatch '\{archive_cmd\}') `
            -FailureMessage "session-output.ps1 still references the {archive_cmd} placeholder"
    }
} finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

$failed = @($results | Where-Object { -not $_ }).Count
if ($failed -gt 0) {
    Write-Host ("`n$failed deployment-finalization-contract test(s) failed.") -ForegroundColor Red
    exit 1
}
Write-Host "`nAll deployment-finalization-contract tests passed." -ForegroundColor Green
exit 0
