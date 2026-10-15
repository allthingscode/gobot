# Deployment instructions and approval gate must agree. TODO item 215.
$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path "$PSScriptRoot/../..").Path
. (Join-Path $PSScriptRoot '_harness.ps1')
$results = @()
$results += Run-Test -Name 'Operator publishing policy' -Body {
    $text = Get-Content (Join-Path $repoRoot 'personas/operator.md') -Raw
    Assert-Result -Name 'no pre-handoff push' -Condition ($text -notmatch 'Push Before Handoff|Push must succeed') -FailureMessage 'Persona requires specialist push'
    Assert-Result -Name 'publishing policy explicit' -Condition ($text -match 'never pushes' -and $text -match 'review.auto_push') -FailureMessage 'Missing Human Gate publishing policy'
}
$results += Run-Test -Name 'Deployment approval instructions' -Body {
    $sop = Get-Content (Join-Path $repoRoot 'sops/deployment.md') -Raw
    $output = Get-Content (Join-Path $repoRoot 'powershell/lib/session-output.ps1') -Raw
    Assert-Result -Name 'no handoff status check' -Condition (($sop + $output) -notmatch '(?i)handoff[^\r\n]*status[: `"\x27]*Ready for Deploy') -FailureMessage 'Instructions require nonexistent handoff status'
    Assert-Result -Name 'approval evidence' -Condition ($sop -match 'review_decision: APPROVED' -and $sop -match 'target_phase') -FailureMessage 'Missing approval evidence'
}
$tempRoot = New-TestFixtureRoot -NameHint 'deployment-approval'
try {
    $runner = Join-Path $tempRoot 'gate.ps1'
    New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot 'C-215/verification') | Out-Null
    $script = @'
param($RepoRoot, $SessionDir)
. (Join-Path $RepoRoot 'powershell/crucible-lib.ps1')
function Write-EventLog {}
function Write-BlockedTaskRecord {}
$ctx = @{
    Handoff = [pscustomobject]@{ task_id = 'C-215'; source_phase = 'verification'; target_phase = 'deployment'; cumulative_handoff_count = 1 }
    BacklogDir = $SessionDir; SessionDir = $SessionDir; LogFile = "$SessionDir/log"; CircuitBreakerHistoryFile = "$SessionDir/history"
    RepoRoot = $RepoRoot; WorkspacesDir = $SessionDir
}
Test-CompletionArtifactGate -Context $ctx
exit 0
'@
    [IO.File]::WriteAllText($runner, $script)
    foreach ($case in @(
        @{ Name = 'missing report'; Text = $null; Exit = 1 },
        @{ Name = 'missing YAML decision'; Text = "---`nacceptance_criteria_met: true`n---`nAPPROVED"; Exit = 1 },
        @{ Name = 'rejected decision'; Text = "---`nreview_decision: CHANGES_REQUESTED`nacceptance_criteria_met: true`n---`nAPPROVED"; Exit = 1 },
        @{ Name = 'approved decision'; Text = "---`nreview_decision: APPROVED`nacceptance_criteria_met: true`n---`nApproved"; Exit = 0 }
    )) {
        $results += Run-Test -Name "Deployment gate: $($case.Name)" -Body {
            $report = Join-Path $tempRoot 'C-215/verification/review_report.md'
            if ($null -ne $case.Text) { [IO.File]::WriteAllText($report, $case.Text) }
            $output = & pwsh -NoProfile -File $runner $repoRoot $tempRoot 2>&1
            $code = $LASTEXITCODE
            Assert-Result -Name 'approval gate outcome' -Condition ($code -eq $case.Exit) -FailureMessage "Expected $($case.Exit), got ${code}: $output"
        }
    }
} finally {
    if (Test-Path $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force }
}
if ($results -contains $false) { exit 1 }
exit 0
