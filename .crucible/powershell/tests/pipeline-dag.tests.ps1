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
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("crucible-pipeline-dag-" + [System.Guid]::NewGuid().ToString("N"))
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
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("crucible-pipeline-dag-" + [System.Guid]::NewGuid().ToString("N"))
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
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("crucible-pipeline-dag-" + [System.Guid]::NewGuid().ToString("N"))
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
        $factoryGatesText = Get-Content -LiteralPath (Join-Path $REPO_ROOT "powershell/lib/factory-gates.ps1") -Raw
        $validateHandoffText = Get-Content -LiteralPath (Join-Path $REPO_ROOT "powershell/validate-handoff.ps1") -Raw
        Assert-Result -Name "factory-gates no literal validTransitions" -Condition (-not $factoryGatesText.Contains('$validTransitions = @{')) -FailureMessage "factory-gates.ps1 still duplicates the transition table"
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
} finally {
}

$failed = @($results | Where-Object { -not $_ }).Count
if ($failed -gt 0) {
    Write-Host ("`n$failed pipeline DAG test(s) failed.") -ForegroundColor Red
    exit 1
}
Write-Host "`nAll pipeline DAG tests passed." -ForegroundColor Green
exit 0
