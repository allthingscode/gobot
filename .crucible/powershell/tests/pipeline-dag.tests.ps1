# Tests for the pipeline transition DAG helpers.

$ErrorActionPreference = "Stop"
$REPO_ROOT = (Resolve-Path -Path "$PSScriptRoot/../..").Path
. (Join-Path $PSScriptRoot '_harness.ps1')
$Quiet = $true

. (Join-Path $REPO_ROOT "powershell/lib/pipeline-dag.ps1")

function Assert-StringArrayEqual {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string[]]$Actual,
        [Parameter(Mandatory = $true)][string[]]$Expected
    )

    $actualText = ($Actual -join "|")
    $expectedText = ($Expected -join "|")
    Assert-Result -Name $Name -Condition ($actualText -eq $expectedText) -FailureMessage ("expected '" + $expectedText + "' but got '" + $actualText + "'")
}

function Assert-TransitionMapEqual {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)]$Actual,
        [Parameter(Mandatory = $true)]$Expected
    )

    foreach ($source in @("grooming", "implementation", "verification", "deployment", "research")) {
        Assert-Result -Name ($Name + " contains " + $source) -Condition ($Actual.ContainsKey($source)) -FailureMessage ("missing source " + $source)
        Assert-StringArrayEqual -Name ($Name + " " + $source) -Actual @($Actual[$source]) -Expected @($Expected[$source])
    }
}

function Write-Utf8NoBomFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Content
    )

    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Content, $encoding)
}

function Get-DocumentedTransitions {
    param([Parameter(Mandatory = $true)][string]$Path)

    $lines = Get-Content -LiteralPath $Path
    $transitions = @{}
    foreach ($line in $lines) {
        if ($line -match '^([a-z]+) -> ([a-z, ]+)$') {
            $transitions[$matches[1]] = @($matches[2].Split(",") | ForEach-Object { $_.Trim() })
        }
    }
    return $transitions
}

$results = @()

try {
    $results += Run-Test -Name "Get-PipelineValidTransitions returns base topology without deployment rework" -Body {
        $actual = Get-PipelineValidTransitions -DeploymentRework $false
        $expected = @{
            grooming       = @("implementation", "research", "verification", "done")
            implementation = @("verification")
            verification   = @("deployment", "implementation")
            deployment     = @("grooming", "done")
            research       = @("grooming")
        }

        Assert-TransitionMapEqual -Name "base topology" -Actual $actual -Expected $expected
        Assert-Result -Name "base deployment omits implementation" -Condition (-not (@($actual["deployment"]) -contains "implementation")) -FailureMessage "deployment should not reach implementation without rework"
    }

    $results += Run-Test -Name "Get-PipelineValidTransitions adds deployment rework edge in order" -Body {
        $actual = Get-PipelineValidTransitions -DeploymentRework $true
        $expected = @{
            grooming       = @("implementation", "research", "verification", "done")
            implementation = @("verification")
            verification   = @("deployment", "implementation")
            deployment     = @("grooming", "done", "implementation")
            research       = @("grooming")
        }

        Assert-TransitionMapEqual -Name "rework topology" -Actual $actual -Expected $expected
    }

    $results += Run-Test -Name "Test-DeploymentReworkReentry recognizes rebase count" -Body {
        $handoff = [PSCustomObject]@{ task_id = "F-123"; rebase_count = 1 }
        $actual = Test-DeploymentReworkReentry -Handoff $handoff -SessionDir ""
        Assert-Result -Name "rebase count rework" -Condition $actual -FailureMessage "expected rebase_count >= 1 to enable rework"
    }

    $results += Run-Test -Name "Test-DeploymentReworkReentry recognizes rejected rework decision" -Body {
        $tempRoot = New-TestFixtureRoot -NameHint "pipeline-dag-rejected"
        try {
            $gateDir = Join-Path $tempRoot "global/gate_decisions"
            New-Item -ItemType Directory -Force -Path $gateDir | Out-Null
            Write-Utf8NoBomFile -Path (Join-Path $gateDir "F-123-gate_decision_rejected.json") -Content '{"outcome":"rejected","rework_requested":true}'

            $handoff = [PSCustomObject]@{ task_id = " F-123 " }
            $actual = Test-DeploymentReworkReentry -Handoff $handoff -SessionDir $tempRoot
            Assert-Result -Name "rejected rework decision" -Condition $actual -FailureMessage "expected rejected rework decision to enable rework"
        } finally {
            if (Test-Path -LiteralPath $tempRoot) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force
            }
        }
    }

    $results += Run-Test -Name "Test-DeploymentReworkReentry returns false for clean handoff" -Body {
        $tempRoot = New-TestFixtureRoot -NameHint "pipeline-dag-clean"
        try {
            New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot "global/gate_decisions") | Out-Null
            $handoff = [PSCustomObject]@{ task_id = "F-123" }
            $actual = Test-DeploymentReworkReentry -Handoff $handoff -SessionDir $tempRoot
            Assert-Result -Name "clean handoff" -Condition (-not $actual) -FailureMessage "expected no rework for clean handoff"
        } finally {
            if (Test-Path -LiteralPath $tempRoot) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force
            }
        }
    }

    $results += Run-Test -Name "Test-DeploymentReworkReentry ignores pending decisions" -Body {
        $tempRoot = New-TestFixtureRoot -NameHint "pipeline-dag-pending"
        try {
            $gateDir = Join-Path $tempRoot "global/gate_decisions"
            New-Item -ItemType Directory -Force -Path $gateDir | Out-Null
            Write-Utf8NoBomFile -Path (Join-Path $gateDir "F-123-gate_decision_abc_pending.json") -Content '{"outcome":"rejected","rework_requested":true}'

            $handoff = [PSCustomObject]@{ task_id = "F-123" }
            $actual = Test-DeploymentReworkReentry -Handoff $handoff -SessionDir $tempRoot
            Assert-Result -Name "pending decision ignored" -Condition (-not $actual) -FailureMessage "expected pending decisions to be ignored"
        } finally {
            if (Test-Path -LiteralPath $tempRoot) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force
            }
        }
    }

    $results += Run-Test -Name "Consumers do not duplicate literal transition tables" -Body {
        # Globbed rather than named. crucible-gates.ps1 is being split into
        # crucible-gates-<concern>.ps1 files, and an assertion that names one path keeps
        # passing while covering less of the code it was written to cover - the table
        # could reappear in any sibling and nothing would look. The count is pinned first
        # because a glob that matches nothing satisfies every assertion about its contents.
        $gatesSources = @(Get-ChildItem -Path (Join-Path $REPO_ROOT "powershell/lib") -Filter "crucible-gates*.ps1" -File)
        Assert-Result -Name "gates sources were found" -Condition ($gatesSources.Count -ge 1) -FailureMessage "no powershell/lib/crucible-gates*.ps1 matched, so the scan below would report clean without reading anything"

        $duplicating = @()
        foreach ($gatesSource in $gatesSources) {
            if ((Get-Content -LiteralPath $gatesSource.FullName -Raw).Contains('$validTransitions = @{')) {
                $duplicating += $gatesSource.Name
            }
        }
        $validateHandoffText = Get-Content -LiteralPath (Join-Path $REPO_ROOT "powershell/validate-handoff.ps1") -Raw
        Assert-Result -Name "crucible-gates no literal validTransitions" -Condition ($duplicating.Count -eq 0) -FailureMessage ("these gates sources still duplicate the transition table: " + ($duplicating -join ", "))
        Assert-Result -Name "validate-handoff no literal validTransitions" -Condition (-not $validateHandoffText.Contains('$validTransitions = @{')) -FailureMessage "validate-handoff.ps1 still duplicates the transition table"
    }

    $results += Run-Test -Name "Documented transition table agrees with code" -Body {
        $docTransitions = Get-DocumentedTransitions -Path (Join-Path $REPO_ROOT "docs/pipeline-state-machine.md")
        $baseTransitions = Get-PipelineValidTransitions -DeploymentRework $false
        Assert-TransitionMapEqual -Name "doc base topology" -Actual $baseTransitions -Expected $docTransitions

        $reworkDocTransitions = @{}
        foreach ($key in $docTransitions.Keys) {
            $reworkDocTransitions[$key] = @($docTransitions[$key])
        }
        $reworkDocTransitions["deployment"] = @($reworkDocTransitions["deployment"] + "implementation")

        $reworkTransitions = Get-PipelineValidTransitions -DeploymentRework $true
        Assert-TransitionMapEqual -Name "doc rework topology" -Actual $reworkTransitions -Expected $reworkDocTransitions
    }
    # The prompt is what the specialist actually reads. When its declared successors and
    # the DAG disagree, the specialist either routes somewhere the gate refuses or, as in
    # item 58's pass, stops and asks - and the round trip is the cheap outcome. Nothing
    # compared the two, so a stale line survived the rename that introduced the edge it
    # was missing. Filed as TODO item 58.
    $results += Run-Test -Name "Phase prompts declare the successors the DAG allows" -Body {
        # Rework topology, because a prompt describes every route its phase can take,
        # not just the routes available on a clean pass.
        $transitions = Get-PipelineValidTransitions -DeploymentRework $true

        $promptFiles = @(Get-ChildItem -Path (Join-Path $REPO_ROOT "prompts") -Filter "*_prompt.md" -File)
        Assert-Result -Name "phase prompts were found" -Condition ($promptFiles.Count -ge 1) -FailureMessage "no prompts/*_prompt.md matched, so the scan below would report clean without reading anything"

        # Every phase in the table must have a prompt. Deriving the phase from the file
        # name and then checking coverage both ways means a renamed prompt fails loudly
        # instead of quietly dropping out of the comparison.
        $seenPhases = @()
        foreach ($promptFile in $promptFiles) {
            $phase = $promptFile.Name -replace '_prompt\.md$', ''
            if (-not $transitions.ContainsKey($phase)) { continue }
            $seenPhases += $phase

            $successorLine = @(Get-Content -LiteralPath $promptFile.FullName | Where-Object { $_ -match '^- \*\*Successors?\*\*:' })
            Assert-Result -Name ($phase + " prompt declares its successors") -Condition ($successorLine.Count -eq 1) -FailureMessage ("expected exactly one '- **Successor(s)**:' line in " + $promptFile.Name + " but found " + $successorLine.Count)
            if ($successorLine.Count -ne 1) { return }

            $declared = @([regex]::Matches($successorLine[0], '`([a-z]+)`') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
            $allowed = @($transitions[$phase] | Sort-Object -Unique)
            Assert-StringArrayEqual -Name ($phase + " prompt successors match the DAG") -Actual $declared -Expected $allowed
        }

        $missingPrompts = @($transitions.Keys | Where-Object { $seenPhases -notcontains $_ } | Sort-Object)
        Assert-Result -Name "every DAG phase has a prompt" -Condition ($missingPrompts.Count -eq 0) -FailureMessage ("these phases have no prompts/<phase>_prompt.md: " + ($missingPrompts -join ", "))
    }

    # policy.md calls itself the authoritative definition and the prompts point readers at
    # it, so it is the one document a drifting line does the most damage in.
    $results += Run-Test -Name "Policy DAG section agrees with code" -Body {
        $transitions = Get-PipelineValidTransitions -DeploymentRework $true

        $inSection = $false
        $documented = @{}
        foreach ($line in (Get-Content -LiteralPath (Join-Path $REPO_ROOT "docs/policy.md"))) {
            if ($line -match '^## 1\. FSM Phase Sequence') { $inSection = $true; continue }
            if ($inSection -and $line -match '^## ') { break }
            if (-not $inSection) { continue }
            if ($line -notmatch '^- \*\*([a-z]+)\*\*') { continue }
            $source = $matches[1]
            $rest = $line.Substring($matches[0].Length)
            $documented[$source] = @([regex]::Matches($rest, '`([a-z]+)`') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
        }

        Assert-Result -Name "policy DAG section was parsed" -Condition ($documented.Count -eq $transitions.Count) -FailureMessage ("expected " + $transitions.Count + " phase bullets under '## 1. FSM Phase Sequence' but parsed " + $documented.Count + ": " + (($documented.Keys | Sort-Object) -join ", "))
        if ($documented.Count -ne $transitions.Count) { return }

        foreach ($phase in @($transitions.Keys | Sort-Object)) {
            Assert-Result -Name ("policy documents " + $phase) -Condition ($documented.ContainsKey($phase)) -FailureMessage ("policy.md has no DAG bullet for " + $phase)
            if (-not $documented.ContainsKey($phase)) { continue }
            Assert-StringArrayEqual -Name ("policy " + $phase + " successors match the DAG") -Actual $documented[$phase] -Expected @($transitions[$phase] | Sort-Object -Unique)
        }
    }

} finally {
}

$failed = @($results | Where-Object { -not $_ }).Count
if ($failed -gt 0) {
    Write-Host ("`n$failed pipeline DAG test(s) failed.") -ForegroundColor Red
    exit 1
}
Write-Host "`nAll pipeline DAG tests passed." -ForegroundColor Green
exit 0
