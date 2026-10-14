# Item 188: runtime consumers must use the adopter's configured directories.
$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
$REPO_ROOT = (Resolve-Path "$PSScriptRoot/../..").Path
. (Join-Path $PSScriptRoot "_harness.ps1")
. (Join-Path $REPO_ROOT "powershell/crucible-lib.ps1")
$results = @()
$tempRoot = New-TestFixtureRoot -NameHint "configured-paths"
$enc = [System.Text.UTF8Encoding]::new($false)

function Write-PathFixtureFile {
    param([string]$Path, [string]$Content)
    New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force | Out-Null
    [System.IO.File]::WriteAllText($Path, $Content, $enc)
}

function New-PathProject {
    param([string]$Name)
    $root = Join-Path $tempRoot $Name
    Write-PathFixtureFile (Join-Path $root ".crucible/config.yaml") "project: CustomPaths`npaths:`n  session: runtime state`n  workspaces: task worktrees`n"
    git -C $root init --quiet
    git -C $root config user.name "Test User"
    git -C $root config user.email "test@example.com"
    return $root
}

try {
    $results += Run-Test "Eval analysis reads all configured session inputs" {
        $root = New-PathProject "eval"
        $session = Join-Path $root "runtime state"
        Write-PathFixtureFile (Join-Path $session "global/gate_decisions/F-188.json") '{"task_id":"F-188","gate_fired_at":"2026-10-13T12:00:00Z","outcome":"accepted","rework_requested":false,"reason":"checked work"}'
        Write-PathFixtureFile (Join-Path $session "archived/pipeline-F-188.log.jsonl") '{"event":"session_end","task_id":"F-188","phase":"implementation","metrics":{"phase_wall_seconds":120}}'
        Write-PathFixtureFile (Join-Path $session "eval/eval-F-188.json") '{"task_id":"F-188","ac_verified":true}'
        $handoff = '{"task_id":"F-188","source_phase":"implementation","target_phase":"verification","handoff_retry_count":0,"review_strike_count":0,"rebase_count":0,"prompt_version":"v1"}'
        Write-PathFixtureFile (Join-Path $session "handoffs/current.json") $handoff
        Write-PathFixtureFile (Join-Path $session "handoffs/archived/previous.json") $handoff
        Push-Location $root
        try {
            $run = Invoke-ExternalCommand { & (Get-PwshCommand) -NoProfile -File (Join-Path $REPO_ROOT "powershell/analyze-evals.ps1") -Json }
        } finally { Pop-Location }
        Assert-Result "analysis succeeds" ($run.ExitCode -eq 0) ($run.Output -join "`n")
        $data = ($run.Output -join "`n") | ConvertFrom-Json
        Assert-Result "configured gate records" ($data.total_tasks -eq 1) "expected one gate record"
        Assert-Result "configured eval records" ($data.eval_records -eq 1) "expected one eval record"
        Assert-Result "both configured handoff directories" ($data.handoff_quality.total_handoffs -eq 2) "expected two handoffs"
        Assert-Result "configured archived log" (@($data.avg_phase_wall_minutes).Count -eq 1) "missing phase duration"
    }

    $results += Run-Test "Research gate reads session and writes decision and continuation there" {
        $root = New-PathProject "research"
        $phase = Join-Path $root "runtime state/R-188/research"
        New-Item -ItemType Directory -Path $phase -Force | Out-Null
        $run = Invoke-ExternalCommand {
            & (Get-PwshCommand) -NoProfile -File (Join-Path $REPO_ROOT "powershell/record-research-gate.ps1") -ProjectRoot $root -TaskId R-188 -Reason "reviewed findings" -Approved C-188
        }
        Assert-Result "research gate succeeds" ($run.ExitCode -eq 0) ($run.Output -join "`n")
        Assert-Result "continuation in configured session" (Test-Path (Join-Path $phase "gate-filing.md")) "missing continuation"
        Assert-Result "decision in configured session" (@(Get-ChildItem (Join-Path $root "runtime state/global/research_gate") -Filter 'R-188-*.json').Count -eq 1) "missing decision"
        Assert-Result "no default session" (-not (Test-Path (Join-Path $root ".crucible/session"))) "default session created"
    }

    $results += Run-Test "Health reads configured handoffs, gates and scratchpads" {
        $root = New-PathProject "health"
        $session = Join-Path $root "runtime state"
        Write-PathFixtureFile (Join-Path $root ".crucible/backlog/BACKLOG.md") "| ID | Title | Status |`n| --- | --- | --- |`n| F-188 | Finished | Resolved |`n"
        Write-PathFixtureFile (Join-Path $session "F-188/implementation/task.md") ((1..502 | ForEach-Object { "line $_" }) -join "`n")
        Write-PathFixtureFile (Join-Path $session "architect/task.md") "legacy scratchpad"
        Write-PathFixtureFile (Join-Path $session "architect/prompt.md") "legacy prompt"
        Write-PathFixtureFile (Join-Path $session "handoffs/F-188-old.json") '{}'
        (Get-Item (Join-Path $session "handoffs/F-188-old.json")).LastWriteTime = (Get-Date).AddDays(-8)
        Write-PathFixtureFile (Join-Path $session "global/gate_decisions/gate_decision_F-188_pending.json") '{}'
        $run = Invoke-ExternalCommand { & (Get-PwshCommand) -NoProfile -File (Join-Path $REPO_ROOT "powershell/crucible-health.ps1") -ProjectRoot $root -Health }
        $output = $run.Output -join "`n"
        Assert-Result "health succeeds" ($run.ExitCode -eq 0) $output
        foreach ($pattern in @('Stale Handoff Files over 24h: 1', 'Stale Session Scratchpads: 2', 'Orphaned Pending Gate Files: 1', '502 lines')) {
            Assert-Result $pattern ($output -match [regex]::Escape($pattern)) $output
        }
    }

    $results += Run-Test "Cleanup archives configured task sessions and handoffs" {
        $root = New-PathProject "cleanup"
        $session = Join-Path $root "runtime state"
        Write-PathFixtureFile (Join-Path $root ".crucible/backlog/BACKLOG.md") "| ID | Title | Status |`n| --- | --- | --- |`n| F-188 | Finished | Resolved |`n"
        Write-PathFixtureFile (Join-Path $session "F-188/implementation/task.md") "completed task"
        Write-PathFixtureFile (Join-Path $session "architect/task.md") "legacy scratchpad"
        Write-PathFixtureFile (Join-Path $session "architect/prompt.md") "legacy prompt"
        Write-PathFixtureFile (Join-Path $session "handoffs/F-188-old.json") '{}'
        (Get-Item (Join-Path $session "handoffs/F-188-old.json")).LastWriteTime = (Get-Date).AddDays(-8)
        Write-PathFixtureFile (Join-Path $session "global/gate_decisions/gate_decision_F-188_pending.json") '{}'
        $run = Invoke-ExternalCommand { & (Get-PwshCommand) -NoProfile -File (Join-Path $REPO_ROOT "powershell/crucible-health.ps1") -ProjectRoot $root -Cleanup -Force }
        Assert-Result "cleanup succeeds" ($run.ExitCode -eq 0) ($run.Output -join "`n")
        Assert-Result "task session archived" (-not (Test-Path (Join-Path $session "F-188"))) "task session was ignored"
        Assert-Result "handoff archived" (Test-Path (Join-Path $session "handoffs/archived/F-188-old.json")) "handoff was ignored"
        foreach ($path in @('architect/task.md', 'architect/prompt.md', 'global/gate_decisions/gate_decision_F-188_pending.json')) {
            Assert-Result $path (-not (Test-Path (Join-Path $session $path))) "cleanup ignored $path"
        }
        Assert-Result "task archive uses configured root" (@(Get-ChildItem (Join-Path $session "archived/stale-task-sessions") -Directory).Count -eq 1) "task archive missing"
        Assert-Result "no default session" (-not (Test-Path (Join-Path $root ".crucible/session"))) "default session created"
    }

    $results += Run-Test "Input normalization strips configured worktree prefix for missing artifacts" {
        $root = New-PathProject "normalize"
        $session = Join-Path $root "runtime state"
        $path = Join-Path $session "handoffs/F-188.json"
        Write-PathFixtureFile $path '{"task_id":"F-188","source_phase":"grooming","target_phase":"implementation","reason":"reviewed spec","artifacts":["task worktrees/implementation-F-188/src/missing.txt"]}'
        $handoff = Get-Content $path -Raw | ConvertFrom-Json
        $ctx = @{ Handoff = $handoff; LatestHandoff = Get-Item $path; SessionDir = $session; Recover = $false; FrameworkPowerShell = Join-Path $REPO_ROOT "powershell"; LogFile = Join-Path $session "F-188/pipeline.log.jsonl"; CircuitBreakerHistoryFile = Join-Path $session "global/breakers.jsonl"; RepoRoot = $root; TaskId = "F-188" }
        Normalize-CrucibleInputState -Context $ctx
        Assert-Result "artifact relative to configured worktree" ($ctx.Handoff.artifacts[0] -eq 'src/missing.txt') ($ctx.Handoff.artifacts -join ', ')
    }

    $results += Run-Test "New handoff reports missing artifacts relative to configured worktree" {
        $root = New-PathProject "new-handoff"
        Write-PathFixtureFile (Join-Path $root ".crucible/backlog/BACKLOG.md") "| ID | Title | Status |`n| --- | --- | --- |`n| F-188 | [Paths](features/active/F-188_Paths.md) | Ready |`n"
        Write-PathFixtureFile (Join-Path $root ".crucible/backlog/features/active/F-188_Paths.md") "---`nitem_id: F-188`nstatus: Ready`nbudget_tier: low`n---`nPaths.`n"
        $run = Invoke-ExternalCommand {
            & (Get-PwshCommand) -NoProfile -File (Join-Path $REPO_ROOT "powershell/new-handoff.ps1") -ProjectRoot $root -TaskId F-188 -Source grooming -Target implementation -Reason "reviewed scope" -Artifacts "task worktrees/implementation-F-188/src/missing.txt" -FileAffinity src/
        }
        Assert-Result "CLI reports normalized missing artifact" ($run.ExitCode -ne 0 -and ($run.Output -join "`n").Contains("[src/missing.txt]")) ($run.Output -join "`n")
    }

    $results += Run-Test "Research scope allows the configured session directory" {
        $root = New-PathProject "scope"
        git -C $root add .crucible/config.yaml
        git -C $root commit -m "fixture config" --quiet
        $session = Join-Path $root "runtime state"
        Write-PathFixtureFile (Join-Path $session "R-188/research/task.md") "research notes"
        $log = Join-Path $session "R-188/pipeline.log.jsonl"
        $ctx = @{ Handoff = [pscustomobject]@{ task_id = "R-188"; source_phase = "research"; target_phase = "grooming" }; FrameworkPowerShell = Join-Path $root "scripts"; LogFile = $log; CircuitBreakerHistoryFile = Join-Path $session "global/breakers.jsonl"; BacklogDir = Join-Path $root ".crucible/backlog"; WorkspacesDir = Join-Path $root "task worktrees"; RepoRoot = $root }
        Invoke-CrucibleScopeGates -Context $ctx
        $events = if (Test-Path $log) { Get-Content $log -Raw } else { "" }
        Assert-Result "no false research scope warning" ($events -notmatch 'research_scope_violation') $events
    }

    foreach ($phase in @("grooming", "deployment")) {
        $results += Run-Test ("Repository integrity uses configured runtime paths at " + $phase) {
            $root = New-PathProject ("integrity-" + $phase)
            git -C $root add .crucible/config.yaml
            git -C $root commit -m "fixture config" --quiet
            Write-PathFixtureFile (Join-Path $root "runtime state/F-188/task.md") "runtime"
            Write-PathFixtureFile (Join-Path $root "task worktrees/placeholder.txt") "runtime"
            Write-PathFixtureFile (Join-Path $root ".crucible/dev-logs/UNPUBLISHED_LOGS.md") "valid dev log"
            $scripts = Join-Path $root "scripts"
            Write-PathFixtureFile (Join-Path $scripts "validate-backlog.ps1") "param([switch]`$FixSummary, [switch]`$Quiet, [string]`$ProjectRoot)`nexit 0`n"
            Write-PathFixtureFile (Join-Path $scripts "validate-dev-log.ps1") "param([string]`$FileToPublish)`nexit 0`n"
            $driver = Join-Path $root "driver.ps1"
            Write-PathFixtureFile $driver @"
. '$REPO_ROOT/powershell/crucible-lib.ps1'
`$ctx = @{ Handoff = [pscustomobject]@{ task_id = 'F-188'; source_phase = '$phase'; target_phase = 'grooming' }; IsBootstrap = `$true; Quiet = `$false; FrameworkPowerShell = '$scripts'; SessionDir = '$root/runtime state'; LogFile = '$root/runtime state/F-188/pipeline.log.jsonl'; CircuitBreakerHistoryFile = '$root/runtime state/global/breakers.jsonl'; RepoRoot = '$root'; Init = `$true; CrucibleRoot = '.crucible' }
if ('$phase' -eq 'deployment') { `$ctx.IsBootstrap = `$false; `$ctx.Handoff.target_phase = 'done' }
Push-Location '$root'
Invoke-RepositoryIntegrityGates -Context `$ctx
"@
            git -C $root add driver.ps1 scripts/validate-dev-log.ps1 scripts/validate-backlog.ps1
            git -C $root commit -m "fixture driver" --quiet
            $run = Invoke-ExternalCommand { & (Get-PwshCommand) -NoProfile -File $driver }
            $output = $run.Output -join "`n"
            Assert-Result "integrity accepts runtime directories" ($run.ExitCode -eq 0 -and $output -notmatch 'Pre-existing untracked|Workspace is not clean') $output
            if ($phase -eq "deployment") {
                Assert-Result "dev log found in bundle" ($output -match 'Dev Log security validation') $output
            }
        }
    }

    $results += Run-Test "Configured runtime exclusions respect directory boundaries" {
        $root = New-PathProject "boundaries"
        Assert-Result "session child" (Test-ConfiguredRuntimePath -Path "runtime state/F-188/task.md" -ProjectRoot $root) "session child not excluded"
        Assert-Result "workspace child" (Test-ConfiguredRuntimePath -Path "task worktrees/implementation-F-188/src/file.txt" -ProjectRoot $root) "workspace child not excluded"
        Assert-Result "similarly named source directory" (-not (Test-ConfiguredRuntimePath -Path "runtime state-source/file.txt" -ProjectRoot $root)) "source directory excluded"
    }

    foreach ($site in @("handoffs/broken.json", "fixtures/handoff-validation/research-valid.json")) {
        $results += Run-Test ("Go runtime lint reads configured session " + $site) {
            $lint = Join-Path $REPO_ROOT "scripts/crucible_lint.go"
            if (-not (Test-Path $lint)) { Skip-Test "Go authoring lint is not shipped in adopter bundles" }
            $root = New-PathProject ($site.Replace('/', '-'))
            $session = Get-ConfiguredPath -Key "session" -ProjectRoot $root
            Write-PathFixtureFile (Join-Path $session $site) "invalid JSON"
            Push-Location $root
            try {
                $run = Invoke-ExternalCommand { go run $lint -framework-root $REPO_ROOT -backlog-dir (Get-ConfiguredPath -Key "backlog" -ProjectRoot $root) -session-dir $session }
            } finally { Pop-Location }
            $output = $run.Output -join "`n"
            Assert-Result "invalid configured runtime file is rejected" ($run.ExitCode -eq 1 -and $output.Contains((Join-Path $session $site))) $output
        }
    }


    $results += Run-Test "CI resolves and passes configured session to runtime lint" {
        $workflow = Join-Path $REPO_ROOT ".github/workflows/ci.yml"
        if (-not (Test-Path $workflow)) { Skip-Test "CI workflow is framework-only" }
        $text = Get-Content $workflow -Raw
        Assert-Result "CI resolves session" ($text -match 'resolve-config-path.ps1 -Key session -ProjectRoot') "session not resolved through shared helper"
        Assert-Result "CI passes session" ($text -match '-session-dir \$session') "configured session not passed to Go"
    }

    $results += Run-Test "Authoring hook resolves session with shared config helper" {
        $hook = Join-Path $REPO_ROOT "scripts/hooks/pre-commit"
        if (-not (Test-Path $hook)) { Skip-Test "Authoring hook is not shipped in adopter bundles" }
        $text = Get-Content $hook -Raw
        Assert-Result "hook resolves session" ($text -match 'resolve-config-path.ps1 -Key session -ProjectRoot') "session not resolved through shared helper"
        Assert-Result "hook passes session to linter" ($text -match '-session-dir "\$SESSION_DIR"') "configured session not passed to Go"
    }
} finally {
    if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force }
}
Write-TestFileSummary -Results $results
