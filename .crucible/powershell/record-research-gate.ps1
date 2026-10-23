# Records a human Research Gate decision and generates a self-contained post-gate
# continuation prompt (gate-filing.md) so a re-dispatched Researcher FILES the approved
# backlog stubs instead of re-presenting the gate.
#
# A plain re-dispatch follows the audit SOP's present-and-wait step and can repeat
# the gate without filing. Record the decision and generate a self-contained filing
# prompt so the resumed Researcher proceeds with approved deliverables.
#
# Usage:
#   record-research-gate.ps1 -TaskId R-021 -Reason "Gate approved" `
#     -Approved "C-350","C-351" -Deferred "C-352" -Rejected ""
# A recommendation to fix the installed Crucible bundle upstream has no backlog ID here;
# record its approval with -ApprovedUpstream "<reference>: <one-line summary>".
# Then dispatch the Researcher with a ONE-LINE pointer to the generated gate-filing.md
# (Codex: launch-codex-specialist.ps1 -TaskId <id> -Phase research
# -PromptFile <path to gate-filing-pointer.md>; or the Claude Agent tool with the same
# one-line prompt).

param(
    [Parameter(Mandatory = $true)]
    [string]$TaskId,

    [Parameter(Mandatory = $true)]
    [string]$Reason,

    [string[]]$Approved = @(),
    [string[]]$Deferred = @(),
    [string[]]$Rejected = @(),

    # Upstream referrals: free text, one entry per referral, never filed as a stub. Item 235.
    [string[]]$ApprovedUpstream = @(),

    [string]$CrucibleRoot = ".crucible",

    [Parameter(Mandatory = $false)]
    [string]$ProjectRoot = ""
)

Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot "lib/time.ps1")
. (Join-Path $PSScriptRoot "lib/project-root.ps1")
. (Join-Path $PSScriptRoot "lib/config-helpers.ps1")
. (Join-Path $PSScriptRoot "lib/crucible-command.ps1")
. (Join-Path $PSScriptRoot "lib/backlog-io.ps1")

$ErrorActionPreference = "Stop"

$REPO_ROOT = Resolve-CrucibleProjectRoot -ProjectRoot $ProjectRoot -ScriptRoot $PSScriptRoot

function Split-ItemList {
    param([string[]]$Items)
    $out = @()
    foreach ($raw in @($Items)) {
        if ($null -eq $raw) { continue }
        foreach ($part in ($raw -split ',')) {
            # pwsh -File passes "B-034","B-035" as one string with its quotes kept. Item 174.
            $t = $part.Trim().Trim('"', "'").Trim()
            if ($t -eq "") { continue }
            if ($t -notmatch '^[A-Z]+-\d+[a-z]?$') {
                throw ("'" + $t + "' is not a backlog item ID (for example B-034 or C-305a). Pass IDs separated by commas, without extra quoting.")
            }
            $out += $t
        }
    }
    return , @($out)
}

$approvedList = Split-ItemList -Items $Approved
$deferredList = Split-ItemList -Items $Deferred
$rejectedList = Split-ItemList -Items $Rejected
$upstreamList = @(@($ApprovedUpstream) | Where-Object { $null -ne $_ } | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" })

if ($approvedList.Count -eq 0 -and $deferredList.Count -eq 0 -and $rejectedList.Count -eq 0 -and $upstreamList.Count -eq 0) {
    throw "At least one of -Approved / -Deferred / -Rejected / -ApprovedUpstream must be provided; a Research Gate decision cannot be empty."
}

$resolvedCrucibleRoot = Resolve-CrucibleBundleRoot -ProjectRoot $REPO_ROOT -CrucibleRoot $CrucibleRoot
# Item 188: gate continuation and decision records follow paths.session.
$sessionRoot = Get-ConfiguredPath -Key "session" -ProjectRoot $REPO_ROOT
$researchSessionDir = Join-Path $sessionRoot (Join-Path $TaskId "research")
if (-not (Test-Path -LiteralPath $researchSessionDir)) {
    throw "No research session directory at $researchSessionDir. Run the research phase for $TaskId before recording its gate."
}

# Every command the continuation and the guidance print. The human's reason and IDs are data:
# the builder quotes them as literals, and one it cannot put on a command line prints as
# command unavailable rather than stopping the gate from being recorded. Item 247.
$pointerPath = Join-Path $researchSessionDir "gate-filing-pointer.md"
$handoffParameters = [ordered]@{ TaskId = $TaskId; Source = "research"; Target = "grooming"; Reason = $Reason }
if ($approvedList.Count -gt 0) { $handoffParameters["HumanApproved"] = @($approvedList); $handoffParameters["StubSpecsCreated"] = @($approvedList) }
if ($deferredList.Count -gt 0) { $handoffParameters["HumanDeferred"] = @($deferredList) }
if ($rejectedList.Count -gt 0) { $handoffParameters["HumanRejected"] = @($rejectedList) }
$handoffCommand = New-CrucibleCommand -Script "powershell/new-handoff.ps1" -Transport PowerShell -Parameters $handoffParameters -CrucibleRoot $CrucibleRoot
$validateCommand = New-CrucibleCommand -Script "powershell/validate-backlog.ps1" -Transport PowerShell -Parameters ([ordered]@{ ProjectRoot = $REPO_ROOT }) -CrucibleRoot $CrucibleRoot
$advanceCommand = New-CrucibleCommand -Script "powershell/crucible.ps1" -Transport PowerShell -Parameters ([ordered]@{ Init = $true; TaskId = $TaskId; Quiet = $true; ProjectRoot = $REPO_ROOT }) -CrucibleRoot $CrucibleRoot
$dispatchCommand = New-CrucibleCommand -Script "powershell/launch-codex-specialist.ps1" -Transport PowerShell -Parameters ([ordered]@{ TaskId = $TaskId; Phase = "research"; Model = "<model>"; Effort = "<effort>"; ProjectRoot = $REPO_ROOT; PromptFile = $pointerPath }) -CrucibleRoot $CrucibleRoot

$researchDir = Join-Path $resolvedCrucibleRoot "research"
$findingsRel = "$CrucibleRoot/research/<findings artifact>"
if (Test-Path -LiteralPath $researchDir) {
    $artifacts = @(Get-ResearchFindingsArtifact -TaskId $TaskId -ResearchDirectory $researchDir)
    if ($artifacts.Count -gt 1) {
        [Console]::Error.WriteLine("Multiple exact findings artifacts for ${TaskId}:`n" + (($artifacts | ForEach-Object { $_.FullName }) -join "`n") + "`nKeep one exact findings file (move or rename the others), then record the research gate again.")
        exit 1
    }
    if ($artifacts.Count -eq 1) { $findingsRel = "$CrucibleRoot/research/$($artifacts[0].Name)" }
}

$timestamp = Get-UtcFileTimestamp

# --- Structural decision record (auditability + a machine-detectable gate marker) ---
$gateDir = Join-Path $sessionRoot "global/research_gate"
if (-not (Test-Path -LiteralPath $gateDir)) { New-Item -ItemType Directory -Path $gateDir -Force | Out-Null }
$decision = [ordered]@{
    task_id     = $TaskId
    outcome     = if ($approvedList.Count -gt 0) { "approved" } else { "closed" }
    reason      = $Reason
    approved    = @($approvedList)
    deferred    = @($deferredList)
    rejected    = @($rejectedList)
    approved_upstream = @($upstreamList)
    recorded_at = $timestamp
    recorded_by = "record-research-gate.ps1"
}
$decisionPath = Join-Path $gateDir ($TaskId + "-" + $timestamp + ".json")
$decisionJson = $decision | ConvertTo-Json -Depth 6
[System.IO.File]::WriteAllText($decisionPath, $decisionJson, (New-Object System.Text.UTF8Encoding($false)))

# --- Generated continuation prompt ---
function Format-List {
    param([string[]]$Items)
    if (@($Items).Count -eq 0) { return "  (none)" }
    return (@($Items | ForEach-Object { "  - " + $_ }) -join "`n")
}

$approvedMd = Format-List -Items $approvedList
$deferredMd = Format-List -Items $deferredList
$rejectedMd = Format-List -Items $rejectedList
$upstreamMd = Format-List -Items $upstreamList

# Leave terminal status to human acceptance: the deployment gate refuses Production
# or Resolved tasks before acceptance, and the Human Gate finalizes them.
$statusRule = @(
    "Leave $TaskId's own status as it is. Do NOT set it to ``Production`` or ``Resolved``:",
    "the human gate finalizes it on acceptance, and the deployment gate refuses it as terminal",
    "before then."
) -join "`n"

# Item 229: stub filing must follow the adopter's backlog directory.
$backlogRoot = Get-ConfiguredPath -Key "backlog" -ProjectRoot $REPO_ROOT

$fileStep = if ($approvedList.Count -gt 0) {
@"
## Step 1 - File the APPROVED backlog stubs

For each APPROVED item above, create a stub under the correct backlog directory
(``$backlogRoot/{bugs,chores,features}/active/`` by ID prefix B-/C-/F-). Each
stub MUST have valid YAML frontmatter (item_id, title, type, status: "Stub", priority,
target_specialist, budget_tier, parent_task: "$TaskId", depends_on, file_affinity,
created_at), a ``## Summary``, a concrete testable ``## Acceptance Criteria`` checklist, and a
``## Rationale`` line citing the specific finding in the findings artifact. Take the title,
type, priority, effort, and rationale from the "Recommended Backlog Items" table in
``$findingsRel``. Do NOT invent items beyond the approved list.

Encoding: UTF-8 without BOM, ASCII only. No em-dashes, smart quotes, or arrow glyphs.

## Step 2 - Update BACKLOG.md

Add one Active Items row per approved stub with Status ``Stub``, bump the Priority Summary counts and Item IDs
columns, and update the Status Overview count. Do NOT file rows for deferred or rejected
items.

$statusRule
"@
} else {
@"
## Step 1 - No stubs to file

The human deferred or rejected every recommendation, so file NO new backlog stubs.

## Step 2 - Update BACKLOG.md

Do NOT add rows for deferred or rejected items.

$statusRule
"@
}

$gateFilingContent = @"
<!-- generated_by: record-research-gate.ps1 -->
# $TaskId Research Gate - CLOSED. Filing task only.

The Research Gate for $TaskId is ALREADY DECIDED by the human. Do NOT re-run the audit,
do NOT regenerate the findings artifact, and do NOT ask any further gate questions. The
findings report ``$findingsRel`` is accepted as-is. Your ONLY job now is the mechanical
filing below, then the handoff.

## Human gate decision ($timestamp)

Reason: $Reason

APPROVED (file these):
$approvedMd

DEFERRED (do NOT file; recorded only):
$deferredMd

REJECTED (do NOT file; recorded only):
$rejectedMd

APPROVED UPSTREAM REFERRALS (do NOT file; the orchestrator routes these to the framework project):
$upstreamMd

$fileStep

## Step 3 - Write the research -> grooming handoff (do NOT hand-edit JSON)

Run new-handoff.ps1:

    $handoffCommand

This records the human decision in the handoff ``human_decisions`` block.

## Step 4 - Validate and advance

    $validateCommand
    $advanceCommand

Fix any validate-backlog count mismatch before finishing. Append a ``### CHECKPOINT`` line to
your research task.md noting the stubs filed and the handoff written. Report the Crucible
output. Do NOT spawn successor agents.
"@

$gateFilingPath = Join-Path $researchSessionDir "gate-filing.md"
[System.IO.File]::WriteAllText($gateFilingPath, ($gateFilingContent -replace "`r`n", "`n"), (New-Object System.Text.UTF8Encoding($false)))

# --- Orchestrator guidance ---
$pointer = "Researcher: $TaskId - read and follow all instructions in $gateFilingPath"
# TODO item 208: file-sourced prompts survive background pwsh -File argument parsing.
[System.IO.File]::WriteAllText($pointerPath, ($pointer + "`n"), (New-Object System.Text.UTF8Encoding($false)))
Write-Host ""
Write-Host "[RESEARCH GATE RECORDED] $TaskId" -ForegroundColor Green
Write-Host ("  outcome: " + $decision.outcome + "  |  approved: " + $approvedList.Count + "  deferred: " + $deferredList.Count + "  rejected: " + $rejectedList.Count + "  upstream: " + $upstreamList.Count)
if ($upstreamList.Count -gt 0) {
    Write-Host "  Upstream referrals are recorded, not filed. Route each to the framework project:" -ForegroundColor Cyan
    foreach ($ref in $upstreamList) { Write-Host ("    - " + $ref) }
}
Write-Host ("  decision record: " + $decisionPath)
Write-Host ("  continuation prompt: " + $gateFilingPath)
Write-Host ""
Write-Host "  Re-dispatch the Researcher with a ONE-LINE pointer to the continuation prompt:" -ForegroundColor Cyan
Write-Host ("    Codex:  " + $dispatchCommand)
Write-Host ("    Claude: Agent tool, prompt = `"$pointer`"")
Write-Host ""
Write-Host "  The gate is CLOSED; the specialist will file the approved stubs and hand off without re-presenting."
