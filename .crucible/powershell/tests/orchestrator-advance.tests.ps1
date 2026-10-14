# TODO item 199: normal completion must consume the specialist's advance, not repeat it.
$ErrorActionPreference = "Stop"
$REPO_ROOT = (Resolve-Path "$PSScriptRoot/../..").Path
. (Join-Path $PSScriptRoot '_harness.ps1')
$results = @()

$results += Run-Test -Name "Step 6 verifies completed advancement without unconditional Init" -Body {
    $sop = Get-Content (Join-Path $REPO_ROOT "sops/orchestrator.md") -Raw
    $step = [regex]::Match($sop, '(?s)### Step 6\b.*?(?=\r?\n---)').Value
    Assert-Result -Name "no unconditional Init command block" -Condition ($step -notmatch '(?s)```powershell.*?-Init') -FailureMessage "Step 6 must not unconditionally run -Init again"
    Assert-Result -Name "verify output and phase artifacts" -Condition ($step -match 'reported Crucible output' -and $step -match 'prompt.md' -and $step -match 'task.md' -and $step -match 'expected phase') -FailureMessage "Step 6 must verify output and the expected next phase artifacts"
    Assert-Result -Name "Init limited to recovery repair or changed inputs" -Condition ($step -match 'only' -and $step -match 'ADVANCE_INCOMPLETE' -and $step -match 'repair' -and $step -match 'inputs changed') -FailureMessage "Step 6 must limit Init reruns to incomplete advancement, repair or changed inputs"
    Assert-Result -Name "gate breaker and failure routing retained" -Condition ($step -match 'Gate Protocol' -and $step -match 'Circuit Breaker Protocol' -and $step -match 'Failure Protocol' -and $step -match 'return to Step 3') -FailureMessage "Step 6 must preserve blocking and next-dispatch routing"
    $step1 = [regex]::Match($sop, '(?s)### Step 1\b.*?(?=### Step 2)').Value
    Assert-Result -Name "Step 1 reuses Step 6 advancement" -Condition ($step1 -match 'Step 6' -and $step1 -match 'Step 2') -FailureMessage "Step 1 must avoid another Init after Step 6 verified advancement"
}
$results += Run-Test -Name "Tool docs defer normal completion to Step 6" -Body {
    foreach ($tool in @("claude", "grok", "codex", "antigravity")) {
        $doc = Get-Content (Join-Path $REPO_ROOT "docs/orchestrators/$tool.md") -Raw
        Assert-Result -Name "$tool has no repeated cycle rule" -Condition ($doc -notmatch 'two points per specialist cycle|run Crucible and check for gates') -FailureMessage "$tool must not repeat the old unconditional Step 6 rule"
        Assert-Result -Name "$tool uses Step 6 verification" -Condition ($doc -match 'Step 6' -and $doc -match 'verify Crucible output and next phase artifacts') -FailureMessage "$tool must follow Step 6 verification"
    }
}
if (@($results | Where-Object { -not $_ }).Count -gt 0) { exit 1 }
Write-Host "All orchestrator advancement tests passed." -ForegroundColor Green
exit 0
