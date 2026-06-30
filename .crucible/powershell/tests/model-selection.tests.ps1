# Verifies the two-stage model selection (docs/policy.md 2.3):
#   1. Get-SpecialistModel maps (target_phase, budget_tier, design_required) to an abstract
#      capability TIER (strong/default/light) -- provider-agnostic routing.
#   2. Get-ConfiguredModel resolves that tier to a concrete model for the active -Target
#      (claude/codex/antigravity), preferring the config.yaml `models:` block and falling
#      back to the framework default map.

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$REPO_ROOT = (Resolve-Path -Path "$PSScriptRoot/../..").Path
. (Join-Path $PSScriptRoot '_harness.ps1')
. (Join-Path $REPO_ROOT "powershell/factory-lib.ps1")

$results = @()

# --- Stage 1: phase/budget/design -> capability tier ---

$results += Run-Test "Researcher is always the strong tier regardless of budget" {
    Assert-Result "research low" ((Get-SpecialistModel -TargetPhase 'research' -BudgetTier 'low') -eq 'strong') "expected strong"
    Assert-Result "research extended" ((Get-SpecialistModel -TargetPhase 'research' -BudgetTier 'extended') -eq 'strong') "expected strong"
}

$results += Run-Test "Groomer defaults, escalates to strong on high/extended" {
    Assert-Result "groom low" ((Get-SpecialistModel -TargetPhase 'grooming' -BudgetTier 'low') -eq 'default') "expected default"
    Assert-Result "groom medium" ((Get-SpecialistModel -TargetPhase 'grooming' -BudgetTier 'medium') -eq 'default') "expected default"
    Assert-Result "groom high" ((Get-SpecialistModel -TargetPhase 'grooming' -BudgetTier 'high') -eq 'strong') "expected strong"
    Assert-Result "groom extended" ((Get-SpecialistModel -TargetPhase 'grooming' -BudgetTier 'extended') -eq 'strong') "expected strong"
}

$results += Run-Test "Architect: design_required or high/extended -> strong, else default" {
    Assert-Result "arch low exec" ((Get-SpecialistModel -TargetPhase 'implementation' -BudgetTier 'low' -DesignRequired $false) -eq 'default') "expected default"
    Assert-Result "arch low design" ((Get-SpecialistModel -TargetPhase 'implementation' -BudgetTier 'low' -DesignRequired $true) -eq 'strong') "expected strong"
    Assert-Result "arch high exec" ((Get-SpecialistModel -TargetPhase 'implementation' -BudgetTier 'high' -DesignRequired $false) -eq 'strong') "expected strong"
    Assert-Result "arch extended exec" ((Get-SpecialistModel -TargetPhase 'implementation' -BudgetTier 'extended' -DesignRequired $false) -eq 'strong') "expected strong"
}

$results += Run-Test "Reviewer defaults, escalates to strong on high/extended" {
    Assert-Result "rev low" ((Get-SpecialistModel -TargetPhase 'verification' -BudgetTier 'low') -eq 'default') "expected default"
    Assert-Result "rev high" ((Get-SpecialistModel -TargetPhase 'verification' -BudgetTier 'high') -eq 'strong') "expected strong"
}

$results += Run-Test "Operator is light, escalates only to default on high/extended" {
    Assert-Result "op low" ((Get-SpecialistModel -TargetPhase 'deployment' -BudgetTier 'low') -eq 'light') "expected light"
    Assert-Result "op medium" ((Get-SpecialistModel -TargetPhase 'deployment' -BudgetTier 'medium') -eq 'light') "expected light"
    Assert-Result "op high" ((Get-SpecialistModel -TargetPhase 'deployment' -BudgetTier 'high') -eq 'default') "expected default"
}

$results += Run-Test "done has no tier; blank/dirty tier defaults safely" {
    Assert-Result "done empty" ((Get-SpecialistModel -TargetPhase 'done' -BudgetTier 'low') -eq '') "expected empty"
    Assert-Result "blank tier -> medium -> default for groom" ((Get-SpecialistModel -TargetPhase 'grooming' -BudgetTier '') -eq 'default') "expected default"
    Assert-Result "case/space-insensitive tier" ((Get-SpecialistModel -TargetPhase 'implementation' -BudgetTier '  HIGH ' -DesignRequired $false) -eq 'strong') "expected strong"
}

# --- Stage 2: tier + target -> concrete model (framework default map) ---

$noCfgRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("modelsel-nocfg-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $noCfgRoot -Force | Out-Null

$results += Run-Test "Default map: claude tiers -> opus/sonnet/haiku" {
    Assert-Result "claude strong" ((Get-ConfiguredModel -Target 'claude' -Tier 'strong' -ProjectRoot $noCfgRoot) -eq 'opus') "expected opus"
    Assert-Result "claude default" ((Get-ConfiguredModel -Target 'claude' -Tier 'default' -ProjectRoot $noCfgRoot) -eq 'sonnet') "expected sonnet"
    Assert-Result "claude light" ((Get-ConfiguredModel -Target 'claude' -Tier 'light' -ProjectRoot $noCfgRoot) -eq 'haiku') "expected haiku"
}

$results += Run-Test "Default map: 'agent' resolves to the claude row" {
    Assert-Result "agent strong" ((Get-ConfiguredModel -Target 'agent' -Tier 'strong' -ProjectRoot $noCfgRoot) -eq 'opus') "expected opus"
    Assert-Result "empty target -> claude" ((Get-ConfiguredModel -Target '' -Tier 'light' -ProjectRoot $noCfgRoot) -eq 'haiku') "expected haiku"
}

$results += Run-Test "Default map: codex tiers -> gpt-5.5/gpt-5.5/gpt-5.4" {
    Assert-Result "codex strong" ((Get-ConfiguredModel -Target 'codex' -Tier 'strong' -ProjectRoot $noCfgRoot) -eq 'gpt-5.5') "expected gpt-5.5"
    Assert-Result "codex default" ((Get-ConfiguredModel -Target 'codex' -Tier 'default' -ProjectRoot $noCfgRoot) -eq 'gpt-5.5') "expected gpt-5.5"
    Assert-Result "codex light" ((Get-ConfiguredModel -Target 'codex' -Tier 'light' -ProjectRoot $noCfgRoot) -eq 'gpt-5.4') "expected gpt-5.4"
}

$results += Run-Test "Default map: antigravity tiers -> Gemini labels" {
    Assert-Result "ag strong" ((Get-ConfiguredModel -Target 'antigravity' -Tier 'strong' -ProjectRoot $noCfgRoot) -eq 'Gemini 3.1 Pro (High)') "expected Gemini 3.1 Pro (High)"
    Assert-Result "ag default" ((Get-ConfiguredModel -Target 'antigravity' -Tier 'default' -ProjectRoot $noCfgRoot) -eq 'Gemini 3.5 Flash (High)') "expected Gemini 3.5 Flash (High)"
    Assert-Result "ag light" ((Get-ConfiguredModel -Target 'antigravity' -Tier 'light' -ProjectRoot $noCfgRoot) -eq 'Gemini 3.5 Flash (Medium)') "expected Gemini 3.5 Flash (Medium)"
}

$results += Run-Test "Empty tier (done phase) resolves to empty model; unknown target/tier degrade safely" {
    Assert-Result "empty tier" ((Get-ConfiguredModel -Target 'codex' -Tier '' -ProjectRoot $noCfgRoot) -eq '') "expected empty"
    Assert-Result "case-insensitive target" ((Get-ConfiguredModel -Target 'CODEX' -Tier 'light' -ProjectRoot $noCfgRoot) -eq 'gpt-5.4') "expected gpt-5.4"
    Assert-Result "unknown tier -> token" ((Get-ConfiguredModel -Target 'codex' -Tier 'bogus' -ProjectRoot $noCfgRoot) -eq 'bogus') "expected bogus token"
}

# --- Stage 2: config.yaml override wins over the default map ---

$cfgRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("modelsel-cfg-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path (Join-Path $cfgRoot ".crucible") -Force | Out-Null
$cfgBody = @"
project:
  name: Tmp
models:
  default_target: claude
  targets:
    claude:
      strong: my-strong-claude
      light: haiku
    codex:
      strong: pinned-codex-x
    antigravity:
      default: "My Gemini (High)"
verification:
  quick: []
"@
[System.IO.File]::WriteAllText((Join-Path $cfgRoot ".crucible/config.yaml"), $cfgBody, (New-Object System.Text.UTF8Encoding $false))

$results += Run-Test "config.yaml models: block overrides the default map" {
    Assert-Result "override claude strong" ((Get-ConfiguredModel -Target 'claude' -Tier 'strong' -ProjectRoot $cfgRoot) -eq 'my-strong-claude') "expected my-strong-claude"
    Assert-Result "override codex strong" ((Get-ConfiguredModel -Target 'codex' -Tier 'strong' -ProjectRoot $cfgRoot) -eq 'pinned-codex-x') "expected pinned-codex-x"
    Assert-Result "override antigravity default (quoted, spaces)" ((Get-ConfiguredModel -Target 'antigravity' -Tier 'default' -ProjectRoot $cfgRoot) -eq 'My Gemini (High)') "expected My Gemini (High)"
}

$results += Run-Test "Tiers absent from config fall back to the default map" {
    Assert-Result "claude default (not in cfg) -> sonnet" ((Get-ConfiguredModel -Target 'claude' -Tier 'default' -ProjectRoot $cfgRoot) -eq 'sonnet') "expected sonnet"
    Assert-Result "codex default (not in cfg) -> gpt-5.5" ((Get-ConfiguredModel -Target 'codex' -Tier 'default' -ProjectRoot $cfgRoot) -eq 'gpt-5.5') "expected gpt-5.5"
    Assert-Result "codex light (not in cfg) -> gpt-5.4" ((Get-ConfiguredModel -Target 'codex' -Tier 'light' -ProjectRoot $cfgRoot) -eq 'gpt-5.4') "expected gpt-5.4"
}

# --- Stage 1b: capability tier -> Codex reasoning effort ---

$results += Run-Test "Tier -> Codex effort: strong/light high, default medium" {
    Assert-Result "strong -> high" ((Get-SpecialistEffort -Tier 'strong') -eq 'high') "expected high"
    Assert-Result "default -> medium" ((Get-SpecialistEffort -Tier 'default') -eq 'medium') "expected medium"
    Assert-Result "light -> high" ((Get-SpecialistEffort -Tier 'light') -eq 'high') "expected high"
}

$results += Run-Test "Effort: empty/unknown tier yields empty (nothing emitted)" {
    Assert-Result "empty tier" ((Get-SpecialistEffort -Tier '') -eq '') "expected empty"
    Assert-Result "unknown tier" ((Get-SpecialistEffort -Tier 'bogus') -eq '') "expected empty"
    Assert-Result "case/space-insensitive" ((Get-SpecialistEffort -Tier '  STRONG ') -eq 'high') "expected high"
}

# --- End-to-end: phase -> tier -> model for a codex pipeline ---

$results += Run-Test "End-to-end: low-tier grooming on codex resolves to gpt-5.5 + medium effort" {
    $tier = Get-SpecialistModel -TargetPhase 'grooming' -BudgetTier 'low'
    Assert-Result "tier is default" ($tier -eq 'default') "expected default tier"
    Assert-Result "codex default -> gpt-5.5" ((Get-ConfiguredModel -Target 'codex' -Tier $tier -ProjectRoot $noCfgRoot) -eq 'gpt-5.5') "expected gpt-5.5"
    Assert-Result "codex default -> medium effort" ((Get-SpecialistEffort -Tier $tier) -eq 'medium') "expected medium"
}

Remove-Item -Recurse -Force -LiteralPath $noCfgRoot -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force -LiteralPath $cfgRoot -ErrorAction SilentlyContinue

if ($results -contains $false) {
    Write-Host "`nSOME TESTS FAILED" -ForegroundColor Red
    exit 1
}

Write-Host ("`nALL TESTS PASSED (" + $results.Count + " tests)") -ForegroundColor Green
exit 0
