# The one place that decides whether a deployment -> done closure has no code to merge.
#
# This lived inline in the merge-verification gate, and validate-handoff.ps1 had no notion
# of it at all: the validator refused every deployment -> done handoff without a
# commit_hash, so the closure the gate is built to accept could not be written by
# new-handoff.ps1, which is the only writer the prompts allow. Two enforcement points
# asking the same question have to ask it of the same evidence, or the pipeline documents
# a path it cannot walk. Found by TODO item 72.

if (-not (Get-Command "Invoke-Git" -ErrorAction SilentlyContinue)) {
    $noCodeClosurePlatformPath = Join-Path $PSScriptRoot "platform.ps1"
    if (Test-Path -LiteralPath $noCodeClosurePlatformPath) {
        . $noCodeClosurePlatformPath
    }
}

if (-not (Get-Command "Get-BacklogItemPathForTaskProjectRoot" -ErrorAction SilentlyContinue)) {
    $noCodeClosureBacklogIoPath = Join-Path $PSScriptRoot "backlog-io.ps1"
    if (Test-Path -LiteralPath $noCodeClosureBacklogIoPath) {
        . $noCodeClosureBacklogIoPath
    }
}

function Test-NoCodeClosure {
    # Every clause is a fact about the repository rather than a claim the handoff makes
    # about itself, which is the whole point of the exemption: a task cannot talk its way
    # out of merge verification by declaring itself research.
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$TaskId,
        [AllowEmptyString()][AllowNull()][string]$CommitHash = "",
        [string]$ProjectRoot = ""
    )

    if ([string]::IsNullOrWhiteSpace($TaskId)) {
        return $false
    }

    # A claimed commit is a claim that something merged. Whether that commit is real is the
    # merge verification's business; either way this is not a closure with nothing to check.
    if (-not [string]::IsNullOrWhiteSpace($CommitHash)) {
        return $false
    }

    $resolvedRoot = if ([string]::IsNullOrWhiteSpace($ProjectRoot)) { (Get-Location).Path } else { $ProjectRoot }

    $specPath = Get-BacklogItemPathForTaskProjectRoot -Task $TaskId -ProjectRoot $resolvedRoot
    if ([string]::IsNullOrEmpty($specPath) -or -not (Test-Path -LiteralPath $specPath)) {
        return $false
    }

    $specText = Get-Content -LiteralPath $specPath -Raw -Encoding UTF8
    $isResearchOrGroomingType = ($specText -match '(?im)^\s*type:\s*["'']?(?:research|grooming)["'']?\s*$')
    $isResearchTaskId = ($TaskId -match '(?i)^R-')
    if (-not ($isResearchOrGroomingType -or $isResearchTaskId)) {
        return $false
    }

    $branchProbe = Invoke-Git "show-ref" "--verify" "--quiet" ("refs/heads/task/" + $TaskId) -Directory $resolvedRoot
    return ($branchProbe.ExitCode -ne 0)
}
