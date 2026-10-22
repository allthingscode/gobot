# I2: exercise the reject/abandon enforcement point in a child, since refusals exit.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_harness.ps1')
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
. (Join-Path $repoRoot 'powershell/lib/platform.ps1')
. (Join-Path $repoRoot 'powershell/lib/git.ps1')
$results = @()
$fixture = New-TestFixtureRoot -NameHint 'discard-safety'
try {
    foreach ($outcome in @('rejected', 'abandoned')) {
        foreach ($inputPath in @('action', 'CLI', 'pending')) {
            foreach ($dirty in @($true, $false)) {
                $results += Run-Test -Name "$outcome via $inputPath dirty=$dirty" -Body {
                    $root = Join-Path $fixture "$outcome-$inputPath-$dirty"
                    New-Item -ItemType Directory -Path (Join-Path $root '.crucible'), (Join-Path $root 'live/session'), (Join-Path $root 'live/workspaces') -Force | Out-Null
                    @'
project:
  default_branch: trunk
paths:
  session: live/session
  workspaces: live/workspaces
'@ | Set-Content -LiteralPath (Join-Path $root '.crucible/config.yaml')
                    'original' | Set-Content -LiteralPath (Join-Path $root 'human notes.txt')
                    'runtime' | Set-Content -LiteralPath (Join-Path $root 'live/session/state.txt')
                    git -C $root init -q -b trunk
                    git -C $root add .
                    git -C $root commit -qm base
                    $base = (git -C $root rev-parse HEAD).Trim()
                    git -C $root checkout -qb task/F-253
                    git -C $root commit -q --allow-empty -m task
                    git -C $root checkout -q trunk
                    git -C $root merge -q --no-ff --no-edit task/F-253
                    $merged = (git -C $root rev-parse HEAD).Trim()
                    # Configured runtime changes are permitted even when tracked.
                    'runtime changed' | Set-Content -LiteralPath (Join-Path $root 'live/session/state.txt')
                    if ($dirty) { 'precious human edit' | Set-Content -LiteralPath (Join-Path $root 'human notes.txt') }
                    $runner = Join-Path $fixture 'run.ps1'
                    @'
param($Lib, $Root, $Outcome, $InputPath)
$ErrorActionPreference = 'Stop'
$Quiet = $true
. $Lib
Set-Location -LiteralPath $Root
# Mark the first state mutation so a refusal must precede restore/archive.
function Restore-BacklogTask { 'restore' | Set-Content -LiteralPath (Join-Path $Root 'mutated.txt') }
function Invoke-AbandonedBacklogTaskArchive { 'archive' | Set-Content -LiteralPath (Join-Path $Root 'mutated.txt') }
function Restore-ImplementationWorktree {}
if ($InputPath -eq 'action') {
    Invoke-HumanGateAction -TaskId F-253 -Outcome $Outcome -ProjectRoot $Root -LogFile unused -CircuitBreakerHistoryFile unused
} else {
    $session = Join-Path $Root 'live/session'
    $gateDir = Join-Path $session 'global/gate_decisions'
    New-Item -ItemType Directory -Path $gateDir -Force | Out-Null
    $ctx = @{
        IsBootstrap = $false; RepoRoot = $Root; CrucibleRoot = '.crucible'
        SessionDir = $session; LogFile = 'unused'; CircuitBreakerHistoryFile = 'unused'
        GateOutcome = $null; GateReason = 'The implementation needs revision'; GateRedirectTarget = $null
        Quiet = $true
        Handoff = [pscustomobject]@{ task_id = 'F-253'; source_phase = 'deployment'; target_phase = 'done'; session_cycle_id = 'test' }
    }
    if ($InputPath -eq 'CLI') { $ctx.GateOutcome = $Outcome } else {
        @{ task_id = 'F-253'; outcome = $Outcome; reason = 'The implementation needs revision' } |
            ConvertTo-Json | Set-Content -LiteralPath (Join-Path $gateDir 'gate_decision_F-253_pending.json')
    }
    Invoke-HumanGate -Context $ctx
}
'@ | Set-Content -LiteralPath $runner
                    $run = Invoke-ExternalCommand -Command { & (Get-PwshCommand) -NoProfile -File $runner (Join-Path $repoRoot 'powershell/crucible-lib.ps1') $root $outcome $inputPath }
                    $head = (git -C $root rev-parse HEAD).Trim()
                    if ($dirty) {
                        Assert-Result -Name 'planted edit survives' -Condition ((Get-Content -LiteralPath (Join-Path $root 'human notes.txt') -Raw).Trim() -eq 'precious human edit') -FailureMessage $run.Output
                        Assert-Result -Name 'refusal exits 2 and names paths and remedy' -Condition ($run.ExitCode -eq 2 -and $run.Output -match 'human notes.txt' -and $run.Output -match '(?i)commit or stash' -and $run.Output -match '(?i)rerun') -FailureMessage $run.Output
                        Assert-Result -Name 'no partial state or reset' -Condition ($head -eq $merged -and -not (Test-Path (Join-Path $root 'mutated.txt'))) -FailureMessage $run.Output
                        $decisions = @(Get-ChildItem -LiteralPath (Join-Path $root 'live/session') -Recurse -Filter 'F-253-*.json')
                        Assert-Result -Name 'no decision recorded' -Condition ($decisions.Count -eq 0) -FailureMessage $run.Output
                    } else {
                        Assert-Result -Name 'runtime changes permit unwind and finalization' -Condition ($run.ExitCode -eq 0 -and $head -eq $base -and (Test-Path (Join-Path $root 'mutated.txt'))) -FailureMessage $run.Output
                    }
                }
            }
        }
    }
    $results += Run-Test -Name 'Merge safety refusal preserves work and removes premature acceptance' -Body {
        $root = Join-Path $fixture 'accept-refusal'
        $decisions = Join-Path $root '.crucible/session/global/gate_decisions'
        New-Item -ItemType Directory -Path $decisions -Force | Out-Null
        'original' | Set-Content -LiteralPath (Join-Path $root 'human.txt')
        git -C $root init -q -b trunk
        git -C $root add human.txt
        git -C $root commit -qm base
        git -C $root branch task/F-253
        $head = (git -C $root rev-parse HEAD).Trim()
        'precious human edit' | Set-Content -LiteralPath (Join-Path $root 'human.txt')
        $decision = Join-Path $decisions 'F-253-accepted.json'
        '{"outcome":"accepted"}' | Set-Content -LiteralPath $decision
        $runner = Join-Path $fixture 'merge-refusal.ps1'
        @'
param($Lib, $Root)
$ErrorActionPreference = 'Stop'
$Quiet = $true
. $Lib
Set-Location -LiteralPath $Root
try {
    Invoke-HumanGateMerge -TaskId F-253 -PrimaryBranch trunk -ProjectRoot $Root -LogFile unused -CircuitBreakerHistoryFile unused
} catch { Write-Host 'REFUSAL WAS CAUGHT'; exit 9 }
'@ | Set-Content -LiteralPath $runner
        $run = Invoke-ExternalCommand { & (Get-PwshCommand) -NoProfile -File $runner (Join-Path $repoRoot 'powershell/crucible-lib.ps1') $root }
        Assert-Result -Name 'unconditional merge refusal exits 2' -Condition ($run.ExitCode -eq 2 -and $run.Output -match 'human.txt') -FailureMessage $run.Output
        Assert-Result -Name 'acceptance record removed before refusal' -Condition (-not (Test-Path $decision)) -FailureMessage 'premature acceptance could bypass the next gate'
        Assert-Result -Name 'merge refusal preserves head and edit' -Condition ((git -C $root rev-parse HEAD).Trim() -eq $head -and (Get-Content -LiteralPath (Join-Path $root 'human.txt') -Raw).Trim() -eq 'precious human edit') -FailureMessage $run.Output
    }
    $results += Run-Test -Name 'Shared guard protects staged renames across a runtime boundary' -Body {
        $root = Join-Path $fixture 'rename'
        New-Item -ItemType Directory -Path (Join-Path $root '.crucible'), (Join-Path $root 'runtime') -Force | Out-Null
        "paths:`n  session: runtime" | Set-Content -LiteralPath (Join-Path $root '.crucible/config.yaml')
        'human work' | Set-Content -LiteralPath (Join-Path $root 'human.txt')
        git -C $root init -q -b trunk
        git -C $root add .
        git -C $root commit -qm base
        git -C $root mv human.txt runtime/moved.txt
        Assert-Result -Name 'rename source outside runtime is protected' -Condition (-not (Test-GitDiscardSafe -Directory $root -AllowConfiguredRuntime)) -FailureMessage 'staged rename was allowed'
        Assert-Result -Name 'renamed file survives' -Condition (Test-Path (Join-Path $root 'runtime/moved.txt')) -FailureMessage 'renamed file lost'
    }
    $results += Run-Test -Name 'Shared guard protects untracked and ignored reset obstructions and cleanup work' -Body {
        $root = Join-Path $fixture 'obstruction'
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        git -C $root init -q -b trunk
        'precious.txt' | Set-Content -LiteralPath (Join-Path $root '.gitignore')
        git -C $root add .
        git -C $root commit -qm base
        'committed' | Set-Content -LiteralPath (Join-Path $root 'precious.txt')
        git -C $root add -f precious.txt
        git -C $root commit -qm target
        $target = (git -C $root rev-parse HEAD).Trim()
        git -C $root rm -q precious.txt
        git -C $root commit -qm removal
        'precious edit' | Set-Content -LiteralPath (Join-Path $root 'precious.txt')
        Assert-Result -Name 'ignored obstruction is protected' -Condition (-not (Test-GitDiscardSafe -Directory $root -IncludeUntracked:$false -ResetTarget $target)) -FailureMessage 'reset could delete ignored work'
        Assert-Result -Name 'cleanup preserves ignored work' -Condition (-not (Test-GitDiscardSafe -Directory $root -IncludeUntracked)) -FailureMessage 'cleanup could delete ignored work'
        'new work' | Set-Content -LiteralPath (Join-Path $root 'untracked.txt')
        Assert-Result -Name 'guard defaults protect untracked work' -Condition (-not (Test-GitDiscardSafe -Directory $root)) -FailureMessage 'new discard callers could delete untracked work by default'
        Assert-Result -Name 'cleanup preserves untracked work' -Condition (-not (Test-GitDiscardSafe -Directory $root -IncludeUntracked)) -FailureMessage 'cleanup could delete untracked work'
        Assert-Result -Name 'precious content survives' -Condition ((Get-Content -LiteralPath (Join-Path $root 'precious.txt') -Raw).Trim() -eq 'precious edit') -FailureMessage 'ignored content lost'
    }
    $results += Run-Test -Name 'Shared guard fails closed when git cannot read the checkout' -Body {
        Assert-Result -Name 'missing checkout is unsafe' -Condition (-not (Test-GitDiscardSafe -Directory (Join-Path $fixture 'missing'))) -FailureMessage 'status failure passed'
    }
} finally { Remove-Item -LiteralPath $fixture -Recurse -Force }
if (@($results | Where-Object { -not $_ }).Count) { exit 1 }
Write-Host "ALL TESTS PASSED ($($results.Count) tests)"
