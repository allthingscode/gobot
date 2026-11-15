# Item 184: validate-handoff.ps1 enforces the whole handoff schema with Test-Json, not
# only the required fields a hand-written interpreter knew how to read. Each case below
# was accepted before.

$ErrorActionPreference = "Continue"
$REPO_ROOT = (Resolve-Path -Path "$PSScriptRoot/../..").Path
. (Join-Path $PSScriptRoot '_harness.ps1')
$validateScript = Join-Path $REPO_ROOT "powershell/validate-handoff.ps1"
. (Join-Path $REPO_ROOT "powershell/lib/platform.ps1")
$pwshCmd = Get-PwshCommand
$results = @()

function Invoke-ValidatorOn {
    param([Parameter(Mandatory = $true)][hashtable]$Overrides)
    $h = [ordered]@{
        task_id                  = "C-997"
        source_phase             = "grooming"
        target_phase             = "verification"
        reason                   = "Stub-Only Close-Out"
        generated_by             = "new-handoff.ps1"
        tool_version             = "1.0.0"
        handoff_retry_count      = 0
        review_strike_count      = 0
        rebase_count             = 0
        budget_tier              = "low"
        cumulative_handoff_count = 2
        prompt_version           = "grooming_prompt-v1"
        session_cycle_id         = "initial"
        artifacts                = @("README.md")
        stub_specs_created       = @("chores/active/C-996_Stub.md")
    }
    foreach ($k in $Overrides.Keys) { $h[$k] = $Overrides[$k] }
    $root = New-TestFixtureRoot -NameHint "vh-schema"
    try {
        $hf = Join-Path $root "handoff.json"
        $h | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $hf -Encoding UTF8
        Push-Location $root
        try {
            $out = Invoke-ExternalCommand -AsLines { & $pwshCmd -NoProfile -ExecutionPolicy Bypass -File $validateScript -HandoffFile $hf 2>&1 }
            return @{ Code = $LASTEXITCODE; Out = ($out -join '') }
        } finally { Pop-Location }
    } finally {
        Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue
    }
}

$results += Run-Test "a well-formed handoff validates" {
    $r = Invoke-ValidatorOn -Overrides @{}
    Assert-Result "valid-exit" ($r.Code -eq 0) ("expected exit 0, got " + $r.Code + ". Output: " + $r.Out)
}

$results += Run-Test "a counter written as a string is refused and named" {
    $r = Invoke-ValidatorOn -Overrides @{ handoff_retry_count = "-9" }
    Assert-Result "invalid-exit" ($r.Code -eq 1) ("expected exit 1, got " + $r.Code + ". Output: " + $r.Out)
    Assert-Result "names-field" ($r.Out -match 'schema_violation' -and $r.Out -match '/handoff_retry_count') ("expected a schema_violation naming /handoff_retry_count. Output: " + $r.Out)
}

$results += Run-Test "a negative counter is refused and named" {
    $r = Invoke-ValidatorOn -Overrides @{ review_strike_count = -1 }
    Assert-Result "invalid-exit" ($r.Code -eq 1) ("expected exit 1, got " + $r.Code + ". Output: " + $r.Out)
    Assert-Result "names-field" ($r.Out -match '/review_strike_count') ("expected /review_strike_count to be named. Output: " + $r.Out)
}

$results += Run-Test "grooming -> verification with no stub specs is refused" {
    $r = Invoke-ValidatorOn -Overrides @{ stub_specs_created = @() }
    Assert-Result "invalid-exit" ($r.Code -eq 1) ("expected exit 1, got " + $r.Code + ". Output: " + $r.Out)
    Assert-Result "names-rule" ($r.Out -match 'grooming -> verification rule' -and $r.Out -match 'minItems') ("expected the grooming -> verification rule to be named. Output: " + $r.Out)
    Assert-Result "no-branch-noise" (-not ($r.Out -match "at '/source_phase'")) ("if-clauses that do not apply must not be reported. Output: " + $r.Out)
}

$results += Run-Test "a type error is reported without noise from rules the handoff passes" {
    $r = Invoke-ValidatorOn -Overrides @{ file_affinity = "src/" }
    Assert-Result "invalid-exit" ($r.Code -eq 1) ("expected exit 1, got " + $r.Code + ". Output: " + $r.Out)
    Assert-Result "names-field" ($r.Out -match '/file_affinity') ("expected /file_affinity to be named. Output: " + $r.Out)
    Assert-Result "no-not-noise" (-not ($r.Out -match 'reviewer_checks_passed|human_decisions')) ("a forbidden field that is absent must not be reported. Output: " + $r.Out)
}

$passed = @($results | Where-Object { $_ }).Count
$total = $results.Count
Write-Host ("`n[validate-handoff-schema] {0}/{1} passed" -f $passed, $total) -ForegroundColor Cyan
if ($passed -ne $total) { exit 1 }
