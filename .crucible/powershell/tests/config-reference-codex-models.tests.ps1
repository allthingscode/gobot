# Regression test for the measured ChatGPT-login Codex model guidance.

$ErrorActionPreference = "Stop"
$REPO_ROOT = (Resolve-Path -Path "$PSScriptRoot/../..").Path
. (Join-Path $PSScriptRoot '_harness.ps1')

$results = @()
$results += Run-Test -Name "Codex model guidance records the per-family preflight evidence" -Body {
    $docPath = Join-Path $REPO_ROOT "docs/config-reference.md"
    $doc = Get-Content -LiteralPath $docPath -Raw -Encoding UTF8

    Assert-Result -Name "measurement date is recorded" -Condition (($doc -match "2026-09-02") -and ($doc -match "2026-09-28")) -FailureMessage "config reference does not date the Codex model measurement"
    Assert-Result -Name "preflight method is recorded" -Condition ($doc -match [regex]::Escape("launch-codex-specialist.ps1 -Preflight -Model")) -FailureMessage "config reference does not name the preflight method"
    Assert-Result -Name "superseded 5.4 and 5.5 slugs are not named" -Condition ($doc -notmatch "gpt-5\.[45]\b") -FailureMessage "config reference still names a gpt-5.4 or gpt-5.5 slug"
    Assert-Result -Name "tier slugs are recorded as passing" -Condition (($doc -match "gpt-6-sol.*PASS") -and ($doc -match "gpt-6-luna") -and ($doc -match "gpt-5\.6-terra")) -FailureMessage "config reference does not record the GPT-6 preflight"
    Assert-Result -Name "5.6 variants are named" -Condition (($doc -match "gpt-5\.6-terra") -and ($doc -match "gpt-5\.6-sol")) -FailureMessage "config reference does not name the passing gpt-5.6 variants"
    Assert-Result -Name "5.6 plain slug failure is recorded" -Condition ($doc -match "gpt-5\.6.*FAIL") -FailureMessage "config reference does not record the failing plain gpt-5.6 slug"
    Assert-Result -Name "obsolete all-family plain-slug claim is absent" -Condition ($doc -notmatch "ChatGPT-login Codex accepts the plain `gpt-5\.x` slugs") -FailureMessage "config reference still claims every gpt-5.x family accepts a plain slug"
}

if ($results -contains $false) {
    Write-Host "`nSOME TESTS FAILED" -ForegroundColor Red
    exit 1
}

Write-Host "`nALL TESTS PASSED" -ForegroundColor Green
exit 0
