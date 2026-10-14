# TODO item 196: root precedence and the accessors' existing resolution policies.
$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$frameworkRoot = (Resolve-Path -LiteralPath "$PSScriptRoot/../..").Path
. (Join-Path $PSScriptRoot "_harness.ps1")
. (Join-Path $frameworkRoot "powershell/lib/config-helpers.ps1")

$results = @()
$tempRoot = New-TestFixtureRoot -NameHint "config-project-root"

try {
    $project = Join-Path $tempRoot "project"
    $foreign = Join-Path $tempRoot "foreign"
    New-Item -ItemType Directory -Path (Join-Path $project ".crucible"), $foreign -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $project "hooks") -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $project ".crucible/config.yaml") -Encoding UTF8 -Value @"
paths:
  backlog: work/items
review:
  editor: fixture-editor
manifest_files: [fixture.mod]
models:
  targets:
    claude:
      strong: fixture-model
hooks:
  project_dir: hooks
orchestration:
  approval: to-gate
"@
    Push-Location $tempRoot
    try {
        $results += Run-Test -Name "Explicit root wins and existing relative paths resolve" -Body {
            $REPO_ROOT = $foreign
            $got = Resolve-ConfigProjectRoot -ProjectRoot "./project"
            Assert-Result "explicit root" ($got -eq $project) "Expected explicit root '$project', got '$got'."
        }

        $results += Run-Test -Name "REPO_ROOT falls back through dynamic scope" -Body {
            $REPO_ROOT = "./project"
            $got = Resolve-ConfigProjectRoot
            Assert-Result "repo root" ($got -eq $project) "Expected REPO_ROOT '$project', got '$got'."
            $REPO_ROOT = ""
            Assert-Result "empty repo root" ((Resolve-ConfigProjectRoot) -eq $tempRoot) "An empty REPO_ROOT must use the current directory."
            $REPO_ROOT = "   "
            Assert-Result "blank repo root" ((Resolve-ConfigProjectRoot) -eq $tempRoot) "A blank REPO_ROOT must use the current directory."
        }

        $results += Run-Test -Name "Current directory works under strict mode without REPO_ROOT" -Body {
            Assert-Result "no repo root in scope" ($null -eq (Get-Variable -Name "REPO_ROOT" -ErrorAction SilentlyContinue)) "This test must run with REPO_ROOT unset."
            Assert-Result "current directory" ((Resolve-ConfigProjectRoot) -eq $tempRoot) "An unset REPO_ROOT must use the current directory without throwing."
        }

        $results += Run-Test -Name "Root policies preserve literal paths and missing-root errors" -Body {
            $REPO_ROOT = $foreign
            Assert-Result "ignore repo root" ((Resolve-ConfigProjectRoot -IgnoreRepoRoot) -eq $tempRoot) "Ignoring REPO_ROOT must use the current directory."
            Assert-Result "no normalization" ((Resolve-ConfigProjectRoot -ProjectRoot "./project" -PathResolution None) -eq "./project") "None must retain the supplied path."
            Assert-Result "missing root retained" ((Resolve-ConfigProjectRoot -ProjectRoot "./missing") -eq "./missing") "Existing must retain a missing root."
            Assert-Result "always resolves" ((Resolve-ConfigProjectRoot -ProjectRoot "./project" -PathResolution Always) -eq $project) "Always must resolve an existing path."
            $threw = $false
            try { $null = Resolve-ConfigProjectRoot -ProjectRoot "./missing" -PathResolution Always } catch { $threw = $true }
            Assert-Result "missing root throws" $threw "Always must preserve Resolve-Path's missing-root error."
        }

        $results += Run-Test -Name "Path review manifest and model accessors retain REPO_ROOT fallback" -Body {
            $REPO_ROOT = "./project"
            Assert-Result "configured path" ((Get-ConfiguredPath -Key backlog) -eq (Join-Path $project "work/items")) "Path must resolve REPO_ROOT."
            Assert-Result "configured review" ((Get-ConfiguredReview -Key editor) -eq "fixture-editor") "Review must read REPO_ROOT's config."
            Assert-Result "configured manifests" ((@(Get-ConfiguredManifestFiles) -join ",") -eq "fixture.mod") "Manifest must read REPO_ROOT's config."
            Assert-Result "config file" ((Get-ProjectConfigFile) -eq (Join-Path $project ".crucible/config.yaml")) "Config lookup must resolve REPO_ROOT."
            Assert-Result "configured model" ((Get-ConfiguredModel -Target claude -Tier strong) -eq "fixture-model") "Model lookup must retain REPO_ROOT fallback."
        }

        $results += Run-Test -Name "Hooks and approval ignore REPO_ROOT and use the current directory" -Body {
            $REPO_ROOT = $project
            Push-Location $foreign
            try {
                Assert-Result "hooks cwd" ($null -eq (Get-ConfiguredProjectHooksDir)) "Hooks must ignore REPO_ROOT."
                Assert-Result "approval cwd" ((Get-ConfiguredApprovalMode) -eq "per-phase") "Approval must ignore REPO_ROOT."
                Assert-Result "explicit hooks" ((Get-ConfiguredProjectHooksDir -ProjectRoot $project) -eq (Join-Path $project "hooks")) "Explicit hooks root must win."
                Assert-Result "explicit approval" ((Get-ConfiguredApprovalMode -ProjectRoot $project) -eq "to-gate") "Explicit approval root must win."
            } finally { Pop-Location }
        }

        $results += Run-Test -Name "Accessors preserve missing explicit roots" -Body {
            $REPO_ROOT = $project
            Assert-Result "missing path root" ((Get-ConfiguredPath -Key backlog -ProjectRoot "./missing") -eq (Join-Path "./missing" ".crucible/backlog")) "Path must keep a nonexistent explicit root."
            Assert-Result "missing review root" ((Get-ConfiguredReview -Key editor -ProjectRoot "./missing") -eq "") "Review must use its default."
            Assert-Result "missing manifest root" (@(Get-ConfiguredManifestFiles -ProjectRoot "./missing").Count -eq 0) "Manifest must return no entries."
            Assert-Result "missing config root" ((Get-ProjectConfigFile -ProjectRoot "./missing") -eq "") "Config lookup must return empty."
            Assert-Result "missing approval root" ((Get-ConfiguredApprovalMode -ProjectRoot "./missing") -eq "per-phase") "Approval must use its default."
            $threw = $false
            try { $null = Get-ConfiguredProjectHooksDir -ProjectRoot "./missing" } catch { $threw = $true }
            Assert-Result "missing hooks root throws" $threw "Hooks must preserve Resolve-Path's missing-root error."
        }

        $results += Run-Test -Name "Primary branch keeps relative and nonexistent roots for git" -Body {
            function git {
                $script:branchRoot = $args[1]
                $global:LASTEXITCODE = 0
            }
            $REPO_ROOT = "./project"
            Assert-Result "branch fallback" ((Get-ConfiguredPrimaryBranch) -eq "main") "Primary branch must use REPO_ROOT."
            Assert-Result "relative repo root" ($script:branchRoot -eq "./project") "Primary branch must not Resolve-Path REPO_ROOT."
            $null = Get-ConfiguredPrimaryBranch -ProjectRoot "./missing"
            Assert-Result "missing explicit branch root" ($script:branchRoot -eq "./missing") "Primary branch must pass a missing explicit root to git."
            $REPO_ROOT = "   "
            $null = Get-ConfiguredPrimaryBranch
            Assert-Result "blank branch root" ($script:branchRoot -eq $tempRoot) "A blank REPO_ROOT must fall back to the current directory."
        }
    } finally { Pop-Location }
} finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-TestFileSummary -Results $results
