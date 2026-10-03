# Tests for lib/no-code-closure.ps1: the single predicate that decides whether a
# deployment -> done closure has any code to merge, and for the two enforcement points
# that must agree on it. Before TODO item 72 the detection lived inline in the
# merge-verification gate and validate-handoff.ps1 knew nothing about it, so the gate
# accepted a shape that new-handoff.ps1 refused to write.

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$REPO_ROOT = (Resolve-Path -Path "$PSScriptRoot/../..").Path
. (Join-Path $PSScriptRoot '_harness.ps1')
. (Join-Path $REPO_ROOT "powershell/lib/platform.ps1")
. (Join-Path $REPO_ROOT "powershell/lib/config-helpers.ps1")
. (Join-Path $REPO_ROOT "powershell/lib/no-code-closure.ps1")

$results = @()
$generator = Join-Path $REPO_ROOT "powershell/new-handoff.ps1"

$tempRoot = New-TestFixtureRoot -NameHint "no-code-closure"

function Write-FixtureFile {
    param([string]$Path, [string]$Content)
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    [System.IO.File]::WriteAllText($Path, $Content, (New-Object System.Text.UTF8Encoding($false)))
}

function New-ClosureFixture {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$TaskId,
        [string]$TypeLine = 'type: "Research"',
        [switch]$WithTaskBranch,
        [switch]$WithoutSpec
    )

    $root = Join-Path $tempRoot $Name
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    Invoke-Git "init" "--initial-branch=master" -Directory $root | Out-Null
    Invoke-Git "config" "user.name" "Tester" -Directory $root | Out-Null
    Invoke-Git "config" "user.email" "test@example.com" -Directory $root | Out-Null

    Write-FixtureFile (Join-Path $root ".crucible/config.yaml") @"
crucible_root: ".crucible"
project:
  name: "Fixture"
  description: "Fixture"
  default_branch: "master"
paths:
  backlog: ".crucible/backlog"
"@

    $typeDir = if ($TaskId -match "^B-") { "bugs" } elseif ($TaskId -match "^C-") { "chores" } else { "features" }
    $backlogDir = Join-Path $root ".crucible/backlog"
    New-Item -ItemType Directory -Path (Join-Path $backlogDir ($typeDir + "/active")) -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $backlogDir ($typeDir + "/archived")) -Force | Out-Null

    if (-not $WithoutSpec) {
        $typeFrontmatter = if ([string]::IsNullOrWhiteSpace($TypeLine)) { "" } else { $TypeLine }
        Write-FixtureFile (Join-Path $backlogDir ($typeDir + "/active/" + $TaskId + "_Fixture.md")) @"
---
item_id: "$TaskId"
$typeFrontmatter
status: "Ready for Deploy"
priority: "P2"
target_phase: "deployment"
created_at: "2026-09-08"
---

# $TaskId Fixture
"@
    }

    Write-FixtureFile (Join-Path $backlogDir "BACKLOG.md") @"
# Backlog

## Active Items

| Item ID | Title | Priority | Status |
|---|---|---|---|
| [$TaskId]($typeDir/active/${TaskId}_Fixture.md) | Fixture | P2 | Ready for Deploy |
"@

    Write-FixtureFile (Join-Path $root "README.md") "initial"
    Invoke-Git "add" "-A" -Directory $root | Out-Null
    Invoke-Git "commit" "-m" "initial commit" -Directory $root | Out-Null

    if ($WithTaskBranch) {
        Invoke-Git "branch" ("task/" + $TaskId) -Directory $root | Out-Null
    }

    return $root
}

# --- The predicate itself ---

$results += Run-Test -Name "A research spec with no task branch is a No-Code Closure" -Body {
    # F-, not R-, so the verdict comes from the frontmatter type rather than the ID prefix.
    $root = New-ClosureFixture -Name "research-no-branch" -TaskId "F-501" -TypeLine 'type: "Research"'
    Assert-Result -Name "research spec with no branch qualifies" -Condition (Test-NoCodeClosure -TaskId "F-501" -ProjectRoot $root) -FailureMessage "a research spec with no task/F-501 branch has no merge to verify"
}

$results += Run-Test -Name "A grooming spec with no task branch is a No-Code Closure" -Body {
    $root = New-ClosureFixture -Name "grooming-no-branch" -TaskId "C-502" -TypeLine 'type: "Grooming"'
    Assert-Result -Name "grooming spec with no branch qualifies" -Condition (Test-NoCodeClosure -TaskId "C-502" -ProjectRoot $root) -FailureMessage "a grooming spec with no task/C-502 branch has no merge to verify"
}

$results += Run-Test -Name "An R-star task with no type line is a No-Code Closure" -Body {
    $root = New-ClosureFixture -Name "r-prefix-no-type" -TaskId "R-503" -TypeLine ""
    Assert-Result -Name "R-prefix with no type line qualifies" -Condition (Test-NoCodeClosure -TaskId "R-503" -ProjectRoot $root) -FailureMessage "an R-* task ID is evidence of research on its own"
}

$results += Run-Test -Name "A research spec that has a task branch is not a No-Code Closure" -Body {
    # The branch is the whole point: a task that built something has a merge to prove, and
    # calling itself research must not buy an exemption from proving it.
    $root = New-ClosureFixture -Name "research-with-branch" -TaskId "F-504" -TypeLine 'type: "Research"' -WithTaskBranch
    Assert-Result -Name "branch defeats the exemption" -Condition (-not (Test-NoCodeClosure -TaskId "F-504" -ProjectRoot $root)) -FailureMessage "task/F-504 exists, so there is a merge to verify"
}

$results += Run-Test -Name "A claimed commit_hash is not a No-Code Closure" -Body {
    $root = New-ClosureFixture -Name "research-with-commit" -TaskId "F-505" -TypeLine 'type: "Research"'
    Assert-Result -Name "claimed commit defeats the exemption" -Condition (-not (Test-NoCodeClosure -TaskId "F-505" -CommitHash "0123456789abcdef0123456789abcdef01234567" -ProjectRoot $root)) -FailureMessage "a handoff that names a commit is claiming a merge, not a closure with nothing to check"
}

$results += Run-Test -Name "A feature spec with no task branch is not a No-Code Closure" -Body {
    # Without this the predicate would exempt every task that simply failed to build
    # anything, which is the case merge verification exists to catch.
    $root = New-ClosureFixture -Name "feature-no-branch" -TaskId "F-506" -TypeLine 'type: "Feature"'
    Assert-Result -Name "a feature is never exempt" -Condition (-not (Test-NoCodeClosure -TaskId "F-506" -ProjectRoot $root)) -FailureMessage "only research and grooming specs close without code"
}

$results += Run-Test -Name "A task with no spec at all is not a No-Code Closure" -Body {
    $root = New-ClosureFixture -Name "no-spec" -TaskId "F-507" -WithoutSpec
    Assert-Result -Name "an unlocatable spec is not evidence" -Condition (-not (Test-NoCodeClosure -TaskId "F-507" -ProjectRoot $root)) -FailureMessage "with no spec to read there is nothing proving this closure has no code"
}

# --- The writing half: new-handoff.ps1 through validate-handoff.ps1 ---

function Invoke-DeploymentDoneHandoff {
    param([string]$Root, [string]$TaskId, [string]$CommitHash = "")

    $handoffArgs = @{
        TaskId         = $TaskId
        Source         = "deployment"
        Target         = "done"
        Reason         = "closing the fixture task"
        Artifacts      = @(".crucible/backlog/BACKLOG.md")
        SessionCycleId = "cycle-0001"
        ProjectRoot    = $Root
    }
    if (-not [string]::IsNullOrWhiteSpace($CommitHash)) {
        $handoffArgs["CommitHash"] = $CommitHash
    }

    try {
        $output = & $generator @handoffArgs 2>&1
        return @{ Ok = $true; Output = (@($output) -join ([string][char]10)) }
    } catch {
        return @{ Ok = $false; Output = $_.Exception.Message }
    }
}

$results += Run-Test -Name "new-handoff writes a deployment to done closure with CommitHash omitted" -Body {
    # The first acceptance criterion of TODO item 72. validate-handoff.ps1 required
    # commit_hash on every deployment -> done handoff, and new-handoff.ps1 runs that
    # validator before it will write the file, so the only way to produce a No-Code Closure
    # was to hand-author the JSON - which prompts/deployment_prompt.md forbids.
    $root = New-ClosureFixture -Name "handoff-no-code" -TaskId "R-510" -TypeLine 'type: "Research"'
    $r = Invoke-DeploymentDoneHandoff -Root $root -TaskId "R-510"
    Assert-Result -Name "no-code closure handoff is written" -Condition ($r.Ok) -FailureMessage ("expected the handoff to be written. Output: " + $r.Output)

    $written = @(Get-ChildItem -Path (Join-Path $root ".crucible/session/handoffs") -Filter "R-510-*.json" -ErrorAction SilentlyContinue)
    Assert-Result -Name "the handoff file exists" -Condition ($written.Count -eq 1) -FailureMessage ("expected exactly one handoff file, found " + $written.Count + ". Output: " + $r.Output)

    $handoff = (Get-Content -LiteralPath $written[0].FullName -Raw -Encoding UTF8) | ConvertFrom-Json
    $claimed = if ($handoff.PSObject.Properties["commit_hash"]) { [string]$handoff.commit_hash } else { "" }
    Assert-Result -Name "the written closure claims no commit" -Condition ([string]::IsNullOrWhiteSpace($claimed)) -FailureMessage ("a No-Code Closure names no merge; got commit_hash " + $claimed)
}

function Invoke-HandoffValidator {
    param([string]$Root, [string]$HandoffFile)

    $validator = Join-Path $REPO_ROOT "powershell/validate-handoff.ps1"
    $schema = Join-Path $REPO_ROOT "schemas/handoff.schema.json"
    Push-Location -LiteralPath $Root
    try {
        $out = @(& (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $validator -HandoffFile $HandoffFile -SchemaPath $schema)
        return @{ ExitCode = $LASTEXITCODE; Output = ($out -join ([string][char]10)) }
    } finally {
        Pop-Location
    }
}

$results += Run-Test -Name "A feature task with no branch and no commit_hash is still refused" -Body {
    # The other polarity, and the one that makes the exemption worth anything: a validator
    # that waved through every omitted commit_hash would pass the test above just as well.
    $root = New-ClosureFixture -Name "handoff-feature-no-branch" -TaskId "F-511" -TypeLine 'type: "Feature"'
    $r = Invoke-DeploymentDoneHandoff -Root $root -TaskId "F-511"
    Assert-Result -Name "a feature closure without a commit is refused" -Condition (-not $r.Ok) -FailureMessage ("expected the handoff to be refused. Output: " + $r.Output)
    Assert-Result -Name "the refusal names commit_hash" -Condition ($r.Output -match "commit_hash") -FailureMessage ("expected the refusal to name the missing field. Output: " + $r.Output)
    Assert-Result -Name "the refusal names the No-Code Closure it is not" -Condition ($r.Output -match "No-Code Closure") -FailureMessage ("expected the refusal to say what would have exempted it. Output: " + $r.Output)

    $written = @(Get-ChildItem -Path (Join-Path $root ".crucible/session/handoffs") -Filter "F-511-*.json" -ErrorAction SilentlyContinue)
    Assert-Result -Name "no handoff file is left behind" -Condition ($written.Count -eq 0) -FailureMessage ("a refused handoff must not be written; found " + $written.Count)
}

$results += Run-Test -Name "A research task that has a task branch has its commit_hash derived, not omitted" -Body {
    # new-handoff.ps1 fills commit_hash from the task branch tip, so a research task that
    # actually built something never reaches the validator with the field missing.
    $root = New-ClosureFixture -Name "handoff-research-branch" -TaskId "R-512" -TypeLine 'type: "Research"' -WithTaskBranch
    $r = Invoke-DeploymentDoneHandoff -Root $root -TaskId "R-512"
    Assert-Result -Name "the handoff is written" -Condition ($r.Ok) -FailureMessage ("expected the handoff to be written. Output: " + $r.Output)

    $written = @(Get-ChildItem -Path (Join-Path $root ".crucible/session/handoffs") -Filter "R-512-*.json" -ErrorAction SilentlyContinue)
    Assert-Result -Name "the handoff file exists" -Condition ($written.Count -eq 1) -FailureMessage ("expected exactly one handoff file, found " + $written.Count)

    $handoff = (Get-Content -LiteralPath $written[0].FullName -Raw -Encoding UTF8) | ConvertFrom-Json
    $tip = (Invoke-Git "rev-parse" "refs/heads/task/R-512" -Directory $root).Raw.Trim()
    Assert-Result -Name "the derived commit is the task branch tip" -Condition ([string]$handoff.commit_hash -eq $tip) -FailureMessage ("expected commit_hash " + $tip + ", got " + [string]$handoff.commit_hash)
}

$results += Run-Test -Name "The validator refuses a null commit_hash once a task branch exists" -Body {
    # The exemption has to be re-decided from the repository every time, not stamped onto
    # the handoff when it was written. This closure is written while no branch exists, so
    # it is legitimately a No-Code Closure; creating task/R-513 afterwards means there is a
    # merge to prove, and the same file must stop validating. A predicate that trusted the
    # spec type alone would keep accepting it.
    $root = New-ClosureFixture -Name "handoff-branch-appears" -TaskId "R-513" -TypeLine 'type: "Research"'
    $r = Invoke-DeploymentDoneHandoff -Root $root -TaskId "R-513"
    Assert-Result -Name "the closure is written while no branch exists" -Condition ($r.Ok) -FailureMessage ("expected the handoff to be written. Output: " + $r.Output)

    $written = @(Get-ChildItem -Path (Join-Path $root ".crucible/session/handoffs") -Filter "R-513-*.json" -ErrorAction SilentlyContinue)
    Assert-Result -Name "the handoff file exists" -Condition ($written.Count -eq 1) -FailureMessage ("expected exactly one handoff file, found " + $written.Count)

    $before = Invoke-HandoffValidator -Root $root -HandoffFile $written[0].FullName
    Assert-Result -Name "the validator accepts it with no branch" -Condition ($before.ExitCode -eq 0) -FailureMessage ("expected exit 0, got " + $before.ExitCode + ". Output: " + $before.Output)

    Invoke-Git "branch" "task/R-513" -Directory $root | Out-Null
    $after = Invoke-HandoffValidator -Root $root -HandoffFile $written[0].FullName
    Assert-Result -Name "the same file is refused once the branch exists" -Condition ($after.ExitCode -ne 0) -FailureMessage ("expected a non-zero exit once task/R-513 exists, got " + $after.ExitCode + ". Output: " + $after.Output)
    Assert-Result -Name "the refusal names commit_hash" -Condition ($after.Output -match "commit_hash") -FailureMessage ("expected the refusal to name the missing field. Output: " + $after.Output)
}

$results += Run-Test -Name "A closure does not inherit a deleted task branch's commit_hash" -Body {
    # gobot R-032: an implementation handoff recorded the tip of task/R-032, the branch was
    # deleted in a recovery, and every later handoff inherited the hash. The closure then
    # named a dangling commit and was not recognised as one. Found by TODO item 159.
    $root = New-ClosureFixture -Name "handoff-deleted-branch" -TaskId "R-514" -TypeLine 'type: "Research"' -WithTaskBranch
    $staleTip = (Invoke-Git "rev-parse" "refs/heads/task/R-514" -Directory $root).Raw.Trim()
    Write-FixtureFile (Join-Path $root ".crucible/session/handoffs/R-514-20261002T000000Z.json") (@"
{
  "task_id": "R-514",
  "source_phase": "verification",
  "target_phase": "deployment",
  "reason": "approved",
  "session_cycle_id": "cycle-0001",
  "artifacts": [],
  "commit_hash": "$staleTip"
}
"@)
    Invoke-Git "branch" "-D" "task/R-514" -Directory $root | Out-Null

    $r = Invoke-DeploymentDoneHandoff -Root $root -TaskId "R-514"
    Assert-Result -Name "the closure is written" -Condition ($r.Ok) -FailureMessage ("expected the handoff to be written. Output: " + $r.Output)
    $written = @(Get-ChildItem -Path (Join-Path $root ".crucible/session/handoffs") -Filter "R-514-*.json" | Sort-Object Name -Descending)
    $handoff = (Get-Content -LiteralPath $written[0].FullName -Raw -Encoding UTF8) | ConvertFrom-Json
    $claimed = if ($handoff.PSObject.Properties["commit_hash"]) { [string]$handoff.commit_hash } else { "" }
    Assert-Result -Name "the closure claims no commit" -Condition ([string]::IsNullOrWhiteSpace($claimed)) -FailureMessage ("inherited the deleted branch's tip: " + $claimed)
    Assert-Result -Name "the closure qualifies" -Condition (Test-NoCodeClosure -TaskId "R-514" -CommitHash $claimed -ProjectRoot $root) -FailureMessage "the written handoff should be a No-Code Closure"
}

# --- The two enforcement points ---

$results += Run-Test -Name "The gate and the validator both decide No-Code Closure through the shared predicate" -Body {
    # The third acceptance criterion of TODO item 72. The evidence is shared only for as
    # long as nobody re-inlines a second copy of it, and a second copy is invisible to every
    # behavioural test here until the two copies disagree.
    $gateText = Get-Content -LiteralPath (Join-Path $REPO_ROOT "powershell/lib/crucible-gates.ps1") -Raw -Encoding UTF8
    $validatorText = Get-Content -LiteralPath (Join-Path $REPO_ROOT "powershell/validate-handoff.ps1") -Raw -Encoding UTF8
    $libText = Get-Content -LiteralPath (Join-Path $REPO_ROOT "powershell/lib/no-code-closure.ps1") -Raw -Encoding UTF8

    Assert-Result -Name "the gate calls the shared predicate" -Condition ($gateText.Contains("Test-NoCodeClosure")) -FailureMessage "powershell/lib/crucible-gates.ps1 no longer calls Test-NoCodeClosure"
    Assert-Result -Name "the validator calls the shared predicate" -Condition ($validatorText.Contains("Test-NoCodeClosure")) -FailureMessage "powershell/validate-handoff.ps1 no longer calls Test-NoCodeClosure"

    $typeProbe = "research|grooming"
    Assert-Result -Name "the predicate is the one reading the spec type" -Condition ($libText.Contains($typeProbe)) -FailureMessage "lib/no-code-closure.ps1 no longer recognizes a research or grooming spec, so this test is checking nothing"
    Assert-Result -Name "the gate does not read the spec type itself" -Condition (-not $gateText.Contains($typeProbe)) -FailureMessage "powershell/lib/crucible-gates.ps1 matches the research/grooming spec type again instead of asking Test-NoCodeClosure"
    Assert-Result -Name "the validator does not read the spec type itself" -Condition (-not $validatorText.Contains($typeProbe)) -FailureMessage "powershell/validate-handoff.ps1 matches the research/grooming spec type instead of asking Test-NoCodeClosure"
    Assert-Result -Name "the validator does not probe the task branch itself" -Condition (-not $validatorText.Contains("refs/heads/task/")) -FailureMessage "powershell/validate-handoff.ps1 probes refs/heads/task/ directly instead of asking Test-NoCodeClosure"
}

Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue

if ($results -contains $false) {
    exit 1
} else {
    exit 0
}
