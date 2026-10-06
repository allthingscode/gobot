# Verifies the two-stage model selection (docs/policy.md 2.3):
#   1. Get-SpecialistModel maps (target_phase, budget_tier, design_required) to an abstract
#      capability TIER (strong/default/light) -- provider-agnostic routing.
#   2. Get-ConfiguredModel resolves that tier to a concrete model for the active -Target
#      (claude/codex/antigravity/grok), preferring the config.yaml `models:` block and falling
#      back to the framework default map. For codex a tier is a level, a model and an effort
#      together, resolved as one pair by Get-CodexLevel.

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$REPO_ROOT = (Resolve-Path -Path "$PSScriptRoot/../..").Path
. (Join-Path $PSScriptRoot '_harness.ps1')
. (Join-Path $REPO_ROOT "powershell/crucible-lib.ps1")

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

$results += Run-Test "Operator is light whatever the budget; escalates to default only on deployment trouble" {
    Assert-Result "op low" ((Get-SpecialistModel -TargetPhase 'deployment' -BudgetTier 'low') -eq 'light') "expected light"
    Assert-Result "op medium" ((Get-SpecialistModel -TargetPhase 'deployment' -BudgetTier 'medium') -eq 'light') "expected light"
    Assert-Result "op high" ((Get-SpecialistModel -TargetPhase 'deployment' -BudgetTier 'high') -eq 'light') "expected light"
    Assert-Result "op extended" ((Get-SpecialistModel -TargetPhase 'deployment' -BudgetTier 'extended') -eq 'light') "expected light"
    Assert-Result "op rebase re-entry" ((Get-SpecialistModel -TargetPhase 'deployment' -BudgetTier 'low' -RebaseCount 1) -eq 'default') "expected default"
    Assert-Result "op retried handoff" ((Get-SpecialistModel -TargetPhase 'deployment' -BudgetTier 'low' -HandoffRetryCount 1) -eq 'default') "expected default"
    Assert-Result "counters do not escalate other phases" ((Get-SpecialistModel -TargetPhase 'verification' -BudgetTier 'low' -RebaseCount 2 -HandoffRetryCount 2) -eq 'default') "expected default"
}

$results += Run-Test "done has no tier; blank/dirty tier defaults safely" {
    Assert-Result "done empty" ((Get-SpecialistModel -TargetPhase 'done' -BudgetTier 'low') -eq '') "expected empty"
    Assert-Result "blank tier -> medium -> default for groom" ((Get-SpecialistModel -TargetPhase 'grooming' -BudgetTier '') -eq 'default') "expected default"
    Assert-Result "case/space-insensitive tier" ((Get-SpecialistModel -TargetPhase 'implementation' -BudgetTier '  HIGH ' -DesignRequired $false) -eq 'strong') "expected strong"
}

# --- Stage 2: tier + target -> concrete model (framework default map) ---

$noCfgRoot = New-TestFixtureRoot -NameHint "modelsel-nocfg"

$results += Run-Test "Default map: claude tiers -> opus/sonnet/haiku" {
    Assert-Result "claude strong" ((Get-ConfiguredModel -Target 'claude' -Tier 'strong' -ProjectRoot $noCfgRoot) -eq 'opus') "expected opus"
    Assert-Result "claude default" ((Get-ConfiguredModel -Target 'claude' -Tier 'default' -ProjectRoot $noCfgRoot) -eq 'sonnet') "expected sonnet"
    Assert-Result "claude light" ((Get-ConfiguredModel -Target 'claude' -Tier 'light' -ProjectRoot $noCfgRoot) -eq 'haiku') "expected haiku"
}

$results += Run-Test "Default map: 'agent' resolves to the claude row" {
    Assert-Result "agent strong" ((Get-ConfiguredModel -Target 'agent' -Tier 'strong' -ProjectRoot $noCfgRoot) -eq 'opus') "expected opus"
    Assert-Result "empty target -> claude" ((Get-ConfiguredModel -Target '' -Tier 'light' -ProjectRoot $noCfgRoot) -eq 'haiku') "expected haiku"
}

$results += Run-Test "Default map: codex tiers -> gpt-6.1-sol/gpt-6.1-sol/gpt-6-luna" {
    Assert-Result "codex strong" ((Get-ConfiguredModel -Target 'codex' -Tier 'strong' -ProjectRoot $noCfgRoot) -eq 'gpt-6.1-sol') "expected gpt-6.1-sol"
    Assert-Result "codex default" ((Get-ConfiguredModel -Target 'codex' -Tier 'default' -ProjectRoot $noCfgRoot) -eq 'gpt-6.1-sol') "expected gpt-6.1-sol"
    Assert-Result "codex light" ((Get-ConfiguredModel -Target 'codex' -Tier 'light' -ProjectRoot $noCfgRoot) -eq 'gpt-6-luna') "expected gpt-6-luna"
}

$results += Run-Test "Default map: grok tiers -> inherit, not a Claude slug" {
    Assert-Result "grok strong" ((Get-ConfiguredModel -Target 'grok' -Tier 'strong' -ProjectRoot $noCfgRoot) -eq 'inherit') "expected inherit"
    Assert-Result "grok default" ((Get-ConfiguredModel -Target 'grok' -Tier 'default' -ProjectRoot $noCfgRoot) -eq 'inherit') "expected inherit"
    Assert-Result "grok light" ((Get-ConfiguredModel -Target 'grok' -Tier 'light' -ProjectRoot $noCfgRoot) -eq 'inherit') "expected inherit"
}

$results += Run-Test "Default map: antigravity tiers -> Gemini labels" {
    Assert-Result "ag strong" ((Get-ConfiguredModel -Target 'antigravity' -Tier 'strong' -ProjectRoot $noCfgRoot) -eq 'Gemini 3.1 Pro (High)') "expected Gemini 3.1 Pro (High)"
    Assert-Result "ag default" ((Get-ConfiguredModel -Target 'antigravity' -Tier 'default' -ProjectRoot $noCfgRoot) -eq 'Gemini 3.8 Flash (High)') "expected Gemini 3.8 Flash (High)"
    Assert-Result "ag light" ((Get-ConfiguredModel -Target 'antigravity' -Tier 'light' -ProjectRoot $noCfgRoot) -eq 'Gemini 3.8 Flash (Medium)') "expected Gemini 3.8 Flash (Medium)"
}

$results += Run-Test "Empty tier (done phase) resolves to empty model; unknown target/tier degrade safely" {
    Assert-Result "empty tier" ((Get-ConfiguredModel -Target 'codex' -Tier '' -ProjectRoot $noCfgRoot) -eq '') "expected empty"
    Assert-Result "case-insensitive target" ((Get-ConfiguredModel -Target 'CODEX' -Tier 'light' -ProjectRoot $noCfgRoot) -eq 'gpt-6-luna') "expected gpt-6-luna"
    Assert-Result "unknown tier -> token" ((Get-ConfiguredModel -Target 'codex' -Tier 'bogus' -ProjectRoot $noCfgRoot) -eq 'bogus') "expected bogus token"
}

# --- Stage 2: config.yaml override wins over the default map ---

$cfgRoot = New-TestFixtureRoot -NameHint "modelsel-cfg"
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
    grok:
      strong: grok-4.6
verification:
  quick: []
"@
[System.IO.File]::WriteAllText((Join-Path $cfgRoot ".crucible/config.yaml"), $cfgBody, (New-Object System.Text.UTF8Encoding $false))

$results += Run-Test "config.yaml models: block overrides the default map" {
    Assert-Result "override claude strong" ((Get-ConfiguredModel -Target 'claude' -Tier 'strong' -ProjectRoot $cfgRoot) -eq 'my-strong-claude') "expected my-strong-claude"
    Assert-Result "override codex strong" ((Get-ConfiguredModel -Target 'codex' -Tier 'strong' -ProjectRoot $cfgRoot) -eq 'pinned-codex-x') "expected pinned-codex-x"
    Assert-Result "override antigravity default (quoted, spaces)" ((Get-ConfiguredModel -Target 'antigravity' -Tier 'default' -ProjectRoot $cfgRoot) -eq 'My Gemini (High)') "expected My Gemini (High)"
    Assert-Result "override grok strong" ((Get-ConfiguredModel -Target 'grok' -Tier 'strong' -ProjectRoot $cfgRoot) -eq 'grok-4.6') "expected grok-4.6"
}

$results += Run-Test "Tiers absent from config fall back to the default map" {
    Assert-Result "claude default (not in cfg) -> sonnet" ((Get-ConfiguredModel -Target 'claude' -Tier 'default' -ProjectRoot $cfgRoot) -eq 'sonnet') "expected sonnet"
    Assert-Result "codex default (not in cfg) -> gpt-6.1-sol" ((Get-ConfiguredModel -Target 'codex' -Tier 'default' -ProjectRoot $cfgRoot) -eq 'gpt-6.1-sol') "expected gpt-6.1-sol"
    Assert-Result "codex light (not in cfg) -> gpt-6-luna" ((Get-ConfiguredModel -Target 'codex' -Tier 'light' -ProjectRoot $cfgRoot) -eq 'gpt-6-luna') "expected gpt-6-luna"
    Assert-Result "grok default (not in cfg) -> inherit" ((Get-ConfiguredModel -Target 'grok' -Tier 'default' -ProjectRoot $cfgRoot) -eq 'inherit') "expected inherit"
}

# --- Stage 2b: a Codex tier is a level, a model and an effort together ---

function Get-LevelPair {
    param([string]$Tier, [string]$Root)
    $level = Get-CodexLevel -Tier $Tier -ProjectRoot $Root
    if ($null -eq $level) { return "" }
    return ($level.Model + "/" + $level.Effort)
}

function New-LevelConfigRoot {
    param([string]$Name, [string]$Models)
    $root = New-TestFixtureRoot -NameHint $Name
    New-Item -ItemType Directory -Path (Join-Path $root ".crucible") -Force | Out-Null
    $body = "project:`n  name: Tmp`n" + $Models.TrimEnd() + "`nverification:`n  quick: []`n"
    [System.IO.File]::WriteAllText((Join-Path $root ".crucible/config.yaml"), $body, (New-Object System.Text.UTF8Encoding $false))
    return $root
}

$results += Run-Test "Built-in Codex levels: strong sol/high, default sol/low, light luna/high" {
    Assert-Result "strong" ((Get-LevelPair 'strong' $noCfgRoot) -eq 'gpt-6.1-sol/high') "expected gpt-6.1-sol/high"
    Assert-Result "default" ((Get-LevelPair 'default' $noCfgRoot) -eq 'gpt-6.1-sol/low') "expected gpt-6.1-sol/low"
    Assert-Result "light" ((Get-LevelPair 'light' $noCfgRoot) -eq 'gpt-6-luna/high') "expected gpt-6-luna/high"
}

$results += Run-Test "Codex level: empty/unknown tier has no level (nothing emitted)" {
    Assert-Result "empty tier" ($null -eq (Get-CodexLevel -Tier '' -ProjectRoot $noCfgRoot)) "expected no level"
    Assert-Result "unknown tier" ($null -eq (Get-CodexLevel -Tier 'bogus' -ProjectRoot $noCfgRoot)) "expected no level"
    Assert-Result "case/space-insensitive" ((Get-LevelPair '  STRONG ' $noCfgRoot) -eq 'gpt-6.1-sol/high') "expected gpt-6.1-sol/high"
}

$pairRoot = New-LevelConfigRoot -Name "modelsel-pair" -Models @"
models:
  targets:
    codex:
      strong:
        model: gpt-6.1-sol
        effort: XHigh
      light:
        model: gpt-5.6-terra
        effort: low
"@

$results += Run-Test "config.yaml sets a Codex level as one model and effort pair" {
    $warnings = $null
    $strong = Get-CodexLevel -Tier 'strong' -ProjectRoot $pairRoot -WarningVariable warnings
    Assert-Result "strong pair" (($strong.Model + "/" + $strong.Effort) -eq 'gpt-6.1-sol/xhigh') "expected gpt-6.1-sol/xhigh"
    Assert-Result "light pair" ((Get-LevelPair 'light' $pairRoot) -eq 'gpt-5.6-terra/low') "expected gpt-5.6-terra/low"
    Assert-Result "unset level keeps its built-in pair" ((Get-LevelPair 'default' $pairRoot) -eq 'gpt-6.1-sol/low') "expected gpt-6.1-sol/low"
    Assert-Result "pair form is silent" (@($warnings).Count -eq 0) ("expected no warning, got: " + (@($warnings) -join "`n"))
    Assert-Result "model resolution reads the pair" ((Get-ConfiguredModel -Target 'codex' -Tier 'light' -ProjectRoot $pairRoot) -eq 'gpt-5.6-terra') "expected gpt-5.6-terra"
}

$halfRoot = New-LevelConfigRoot -Name "modelsel-half" -Models @"
models:
  targets:
    codex:
      strong:
        model: gpt-6.1-sol
"@
$badEffortRoot = New-LevelConfigRoot -Name "modelsel-badpair" -Models @"
models:
  targets:
    codex:
      light:
        model: gpt-6-luna
        effort: turbo
"@

$results += Run-Test "A Codex level missing a half, or with an unknown effort, is unreadable" {
    $halfError = ""
    try { Get-CodexLevel -Tier 'strong' -ProjectRoot $halfRoot | Out-Null } catch { $halfError = $_.Exception.Message }
    Assert-Result "half a pair throws" ($halfError -match "models\.targets\.codex\.strong' is a Codex level, so it needs both a model and an effort") ("expected a both-halves error, got: " + $halfError)
    $badError = ""
    try { Get-CodexLevel -Tier 'light' -ProjectRoot $badEffortRoot | Out-Null } catch { $badError = $_.Exception.Message }
    Assert-Result "unknown effort throws" ($badError -match "models\.targets\.codex\.light\.effort' is 'turbo'") ("expected an unknown-effort error, got: " + $badError)
}

$effortRoot = New-TestFixtureRoot -NameHint "modelsel-effort"
New-Item -ItemType Directory -Path (Join-Path $effortRoot ".crucible") -Force | Out-Null
$effortBody = @"
project:
  name: Tmp
models:
  targets:
    codex:
      strong: gpt-5.6-terra
  effort:
    codex:
      strong: Medium
      default: Low
      light: turbo
verification:
  quick: []
"@
[System.IO.File]::WriteAllText((Join-Path $effortRoot ".crucible/config.yaml"), $effortBody, (New-Object System.Text.UTF8Encoding $false))

$results += Run-Test "The older split form still reads, and warns that it splits a level" {
    $warnings = $null
    $strong = Get-CodexLevel -Tier 'strong' -ProjectRoot $effortRoot -WarningVariable warnings -WarningAction SilentlyContinue
    Assert-Result "split strong -> terra/medium" (($strong.Model + "/" + $strong.Effort) -eq 'gpt-5.6-terra/medium') "expected gpt-5.6-terra/medium"
    Assert-Result "split effort warns" ((@($warnings) -join "`n") -match "models\.effort\.codex\.strong sets the effort of the strong level apart from its model") ("expected a split warning, got: " + (@($warnings) -join "`n"))
    $warnings = $null
    $light = Get-CodexLevel -Tier 'light' -ProjectRoot $effortRoot -WarningVariable warnings -WarningAction SilentlyContinue
    Assert-Result "invalid light -> built-in high" ($light.Effort -eq 'high') ("expected high, got " + $light.Effort)
    Assert-Result "invalid light names the value" ((@($warnings) -join "`n") -match "models\.effort\.codex\.light is 'turbo'") ("expected a warning naming 'turbo', got: " + (@($warnings) -join "`n"))
    Assert-Result "model resolution reads the split model" ((Get-ConfiguredModel -Target 'codex' -Tier 'strong' -ProjectRoot $effortRoot) -eq 'gpt-5.6-terra') "expected gpt-5.6-terra"
}

$results += Run-Test "A bare model that changes a level's model, with no effort, warns" {
    $warnings = $null
    $strong = Get-CodexLevel -Tier 'strong' -ProjectRoot $cfgRoot -WarningVariable warnings -WarningAction SilentlyContinue
    Assert-Result "pinned model at the built-in effort" (($strong.Model + "/" + $strong.Effort) -eq 'pinned-codex-x/high') "expected pinned-codex-x/high"
    Assert-Result "half change warns" ((@($warnings) -join "`n") -match "changes the strong level's model to 'pinned-codex-x' but not its effort") ("expected a half-change warning, got: " + (@($warnings) -join "`n"))
    $sameRoot = New-LevelConfigRoot -Name "modelsel-same" -Models "models:`n  targets:`n    codex:`n      strong: gpt-6.1-sol`n"
    $warnings = $null
    Get-CodexLevel -Tier 'strong' -ProjectRoot $sameRoot -WarningVariable warnings | Out-Null
    Assert-Result "bare built-in model is silent" (@($warnings).Count -eq 0) ("expected no warning, got: " + (@($warnings) -join "`n"))
    Remove-Item -Recurse -Force -LiteralPath $sameRoot -ErrorAction SilentlyContinue
}

# --- End-to-end: phase -> tier -> level for a codex pipeline ---

$results += Run-Test "End-to-end: low-tier grooming on codex resolves to the gpt-6.1-sol at low level" {
    $tier = Get-SpecialistModel -TargetPhase 'grooming' -BudgetTier 'low'
    Assert-Result "tier is default" ($tier -eq 'default') "expected default tier"
    Assert-Result "default level" ((Get-LevelPair $tier $noCfgRoot) -eq 'gpt-6.1-sol/low') "expected gpt-6.1-sol/low"
}

$results += Run-Test "End-to-end: deployment on codex resolves to the gpt-6-luna at high level" {
    $tier = Get-SpecialistModel -TargetPhase 'deployment' -BudgetTier 'low'
    Assert-Result "light level" ((Get-LevelPair $tier $noCfgRoot) -eq 'gpt-6-luna/high') "expected gpt-6-luna/high"
}

Remove-Item -Recurse -Force -LiteralPath $noCfgRoot -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force -LiteralPath $effortRoot -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force -LiteralPath $pairRoot -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force -LiteralPath $halfRoot -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force -LiteralPath $badEffortRoot -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force -LiteralPath $cfgRoot -ErrorAction SilentlyContinue

if ($results -contains $false) {
    Write-Host "`nSOME TESTS FAILED" -ForegroundColor Red
    exit 1
}

Write-Host ("`nALL TESTS PASSED (" + $results.Count + " tests)") -ForegroundColor Green
exit 0
