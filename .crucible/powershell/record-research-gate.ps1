# Records a human Research Gate decision and generates a self-contained post-gate
# continuation prompt (gate-filing.md) so a re-dispatched Researcher FILES the approved
# backlog stubs instead of re-presenting the gate.
#
# Why this exists: the research-audit SOP tells the Researcher to "present findings and
# wait" at the Research Gate. On a plain re-dispatch (even with an inline note appended to
# the phase prompt) the SOP's present-and-wait step dominates, so the run re-presents the
# same questions and files nothing -- a launcher STATUS=SUCCESS with zero deliverables
# (caught only by verdict-not-label handoff inspection). This helper is the first-class
# "resume the specialist after a human gate decision" path: it records the decision and
# writes a forceful, self-contained continuation prompt that bypasses the audit framing.
#
# Usage:
#   record-research-gate.ps1 -TaskId R-021 -Reason "Gate approved" `
#     -Approved "C-350","C-351" -Deferred "C-352" -Rejected ""
# Then dispatch the Researcher with a ONE-LINE pointer to the generated gate-filing.md
# (Codex: launch-codex-specialist.ps1 -PromptText "Researcher: <id> - read and follow all
# instructions in <path>"; or the Claude Agent tool with the same one-line prompt).

param(
    [Parameter(Mandatory = $true)]
    [string]$TaskId,

    [Parameter(Mandatory = $true)]
    [string]$Reason,

    [string[]]$Approved = @(),
    [string[]]$Deferred = @(),
    [string[]]$Rejected = @(),

    [string]$CrucibleRoot = ".crucible",

    [Parameter(Mandatory = $false)]
    [string]$ProjectRoot = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($ProjectRoot)) {
    # Derive the project root from THIS script's location, never the caller's cwd, so the
    # orchestrator can record a gate while sitting in another checkout. The bundle ships at
    # <adopter>/.crucible/powershell/, so $PSScriptRoot names the adopter unambiguously; the
    # canonical framework copy at <crucible>/powershell/ is not itself an adopter, so we fall
    # back to cwd there.
    $derivedParent = Split-Path -Path $PSScriptRoot -Parent
    if ((Split-Path -Path $derivedParent -Leaf) -eq ".crucible") {
        $derivedParent = Split-Path -Path $derivedParent -Parent
    }
    $derivedRoot = (Resolve-Path -LiteralPath $derivedParent).Path
    if ((Test-Path -LiteralPath (Join-Path $derivedRoot ".crucible/backlog")) -or
        (Test-Path -LiteralPath (Join-Path $derivedRoot ".crucible/config.yaml"))) {
        $ProjectRoot = $derivedRoot
    } else {
        $cwd = (Get-Location).Path
        if (-not (Test-Path -LiteralPath (Join-Path $cwd ".crucible/backlog")) -and
            -not (Test-Path -LiteralPath (Join-Path $cwd ".crucible/config.yaml"))) {
            throw "ProjectRoot is omitted, the directory derived from this script ('$derivedRoot') is not a valid Crucible project, and neither is the current working directory ('$cwd')."
        }
        $ProjectRoot = $cwd
    }
}
$REPO_ROOT = (Resolve-Path -LiteralPath $ProjectRoot).Path

function Split-ItemList {
    param([string[]]$Items)
    $out = @()
    foreach ($raw in @($Items)) {
        if ($null -eq $raw) { continue }
        foreach ($part in ($raw -split ',')) {
            $t = $part.Trim()
            if ($t -ne "") { $out += $t }
        }
    }
    return , @($out)
}

$approvedList = Split-ItemList -Items $Approved
$deferredList = Split-ItemList -Items $Deferred
$rejectedList = Split-ItemList -Items $Rejected

if ($approvedList.Count -eq 0 -and $deferredList.Count -eq 0 -and $rejectedList.Count -eq 0) {
    throw "At least one of -Approved / -Deferred / -Rejected must be provided; a Research Gate decision cannot be empty."
}

$resolvedCrucibleRoot = if ([System.IO.Path]::IsPathRooted($CrucibleRoot)) { $CrucibleRoot } else { Join-Path $REPO_ROOT $CrucibleRoot }
$researchSessionDir = Join-Path $resolvedCrucibleRoot (Join-Path "session" (Join-Path $TaskId "research"))
if (-not (Test-Path -LiteralPath $researchSessionDir)) {
    throw "No research session directory at $researchSessionDir. Run the research phase for $TaskId before recording its gate."
}

$researchDir = Join-Path $resolvedCrucibleRoot "research"
$findingsRel = "$CrucibleRoot/research/<findings artifact>"
if (Test-Path -LiteralPath $researchDir) {
    $artifact = Get-ChildItem -LiteralPath $researchDir -Filter ($TaskId + "*.md") -File -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($artifact) { $findingsRel = "$CrucibleRoot/research/$($artifact.Name)" }
}

$timestamp = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ")

# --- Structural decision record (auditability + a machine-detectable gate marker) ---
$gateDir = Join-Path $resolvedCrucibleRoot (Join-Path "session" (Join-Path "global" "research_gate"))
if (-not (Test-Path -LiteralPath $gateDir)) { New-Item -ItemType Directory -Path $gateDir -Force | Out-Null }
$decision = [ordered]@{
    task_id     = $TaskId
    outcome     = if ($approvedList.Count -gt 0) { "approved" } else { "closed" }
    reason      = $Reason
    approved    = @($approvedList)
    deferred    = @($deferredList)
    rejected    = @($rejectedList)
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

$approvedQuoted = if ($approvedList.Count -gt 0) { ($approvedList | ForEach-Object { '"' + $_ + '"' }) -join "," } else { '' }
$deferredQuoted = if ($deferredList.Count -gt 0) { ($deferredList | ForEach-Object { '"' + $_ + '"' }) -join "," } else { '' }
$rejectedQuoted = if ($rejectedList.Count -gt 0) { ($rejectedList | ForEach-Object { '"' + $_ + '"' }) -join "," } else { '' }

$handoffArgs = "-TaskId $TaskId -Source research -Target grooming -Reason `"$Reason`" -SuspiciousContent none"
if ($approvedQuoted -ne '') { $handoffArgs += " -HumanApproved $approvedQuoted -StubSpecsCreated $approvedQuoted" }
if ($deferredQuoted -ne '') { $handoffArgs += " -HumanDeferred $deferredQuoted" }
if ($rejectedQuoted -ne '') { $handoffArgs += " -HumanRejected $rejectedQuoted" }

$fileStep = if ($approvedList.Count -gt 0) {
@"
## Step 1 - File the APPROVED backlog stubs

For each APPROVED item above, create a stub under the correct backlog directory
(`$CrucibleRoot/backlog/{bugs,chores,features}/active/` by ID prefix B-/C-/F-). Each
stub MUST have valid YAML frontmatter (item_id, title, type, status: "Ready", priority,
target_specialist, budget_tier, parent_task: "$TaskId", depends_on, file_affinity,
created_at), a `## Summary`, a concrete testable `## Acceptance Criteria` checklist, and a
`## Rationale` line citing the specific finding in the findings artifact. Take the title,
type, priority, effort, and rationale from the "Recommended Backlog Items" table in
`$findingsRel`. Do NOT invent items beyond the approved list.

Encoding: UTF-8 without BOM, ASCII only. No em-dashes, smart quotes, or arrow glyphs.

## Step 2 - Update BACKLOG.md

Add one Active Items row per approved stub, bump the Priority Summary counts and Item IDs
columns, update the Status Overview count, and set $TaskId's own status to `Production`.
Do NOT file rows for deferred or rejected items.
"@
} else {
@"
## Step 1 - No stubs to file

The human deferred or rejected every recommendation, so file NO new backlog stubs.

## Step 2 - Update BACKLOG.md

Set $TaskId's own status to `Production`. Do NOT add rows for deferred or rejected items.
"@
}

$gateFilingContent = @"
<!-- generated_by: record-research-gate.ps1 -->
# $TaskId Research Gate - CLOSED. Filing task only.

The Research Gate for $TaskId is ALREADY DECIDED by the human. Do NOT re-run the audit,
do NOT regenerate the findings artifact, and do NOT ask any further gate questions. The
findings report `$findingsRel` is accepted as-is. Your ONLY job now is the mechanical
filing below, then the handoff.

## Human gate decision ($timestamp)

Reason: $Reason

APPROVED (file these):
$approvedMd

DEFERRED (do NOT file; recorded only):
$deferredMd

REJECTED (do NOT file; recorded only):
$rejectedMd

$fileStep

## Step 3 - Write the research -> grooming handoff (do NOT hand-edit JSON)

Run new-handoff.ps1 (use powershell.exe on Windows):

    $CrucibleRoot/powershell/new-handoff.ps1 $handoffArgs

This records the human decision in the handoff `human_decisions` block.

## Step 4 - Validate and advance

    $CrucibleRoot/powershell/validate-backlog.ps1
    $CrucibleRoot/powershell/factory.ps1 -Init -TaskId $TaskId -Quiet

Fix any validate-backlog count mismatch before finishing. Append a `### CHECKPOINT` line to
your research task.md noting the stubs filed and the handoff written. Report the factory
output. Do NOT spawn successor agents.
"@

$gateFilingPath = Join-Path $researchSessionDir "gate-filing.md"
[System.IO.File]::WriteAllText($gateFilingPath, ($gateFilingContent -replace "`r`n", "`n"), (New-Object System.Text.UTF8Encoding($false)))

# --- Orchestrator guidance ---
$pointer = "Researcher: $TaskId - read and follow all instructions in $gateFilingPath"
Write-Host ""
Write-Host "[RESEARCH GATE RECORDED] $TaskId" -ForegroundColor Green
Write-Host ("  outcome: " + $decision.outcome + "  |  approved: " + $approvedList.Count + "  deferred: " + $deferredList.Count + "  rejected: " + $rejectedList.Count)
Write-Host ("  decision record: " + $decisionPath)
Write-Host ("  continuation prompt: " + $gateFilingPath)
Write-Host ""
Write-Host "  Re-dispatch the Researcher with a ONE-LINE pointer to the continuation prompt:" -ForegroundColor Cyan
Write-Host ("    Codex:  launch-codex-specialist.ps1 -TaskId $TaskId -Phase research -Model <model> -PromptText `"$pointer`"")
Write-Host ("    Claude: Agent tool, prompt = `"$pointer`"")
Write-Host ""
Write-Host "  The gate is CLOSED; the specialist will file the approved stubs and hand off without re-presenting."
