# Item 261 phase 1: each refusal runs inside a .ps1 caller's catch under Stop.
# Invoked scripts return a nonzero LASTEXITCODE; dot-sourced libraries terminate
# the hosting script. Neither boundary permits a catch to swallow the refusal.
# Dependency stubs select otherwise difficult failure paths; the boundary code is
# copied unchanged. Existing gate and runner suites cover the real dependencies.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_harness.ps1')
$source = Join-Path $PSScriptRoot '..'
$pwshCmd = (Get-Process -Id $PID).Path
$tempRoot = New-TestFixtureRoot -NameHint 'refusals-261'
$results = @()

function Write-FixtureText {
    param([string]$Path, [string]$Text)
    New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force | Out-Null
    [IO.File]::WriteAllText($Path, $Text.Replace("`r`n", "`n"), [Text.UTF8Encoding]::new($false))
}

$helpers = @('config-helpers', 'task-checklist', 'time', 'crucible-context', 'event-log',
    'blocked', 'handoff', 'worktree', 'pipeline-dag', 'crucible-gates', 'session-output', 'task-rewind')
$cases = @(
    foreach ($helper in $helpers) {
        @{ Kind = 'bootstrap'; Name = $helper; Expected = ('Required helper script not found at .*' + $helper + '\.ps1') }
    }
    foreach ($helper in @('config-helpers', 'instruction-blocks', 'language-presets', 'project-root')) {
        @{ Kind = 'entry'; Name = $helper; Expected = ('Required helper script not found at .*' + $helper + '\.ps1') }
    }
    @{ Kind = 'research'; Name = 'invalid-id'; Expected = 'is not a backlog item ID' }
    @{ Kind = 'research'; Name = 'empty'; Expected = 'decision cannot be empty' }
    @{ Kind = 'research'; Name = 'missing-session'; Expected = 'No research session directory' }
    @{ Kind = 'gate'; Name = 'outcome'; Expected = 'Unrecognized gate outcome' }
    @{ Kind = 'gate'; Name = 'not-run'; Expected = 'Context.SessionDir is missing' }
    @{ Kind = 'gate'; Name = 'missing-spec'; Expected = 'Active spec path not found' }
    @{ Kind = 'gate'; Name = 'missing-archive'; Expected = 'archive-task helper not found' }
    foreach ($pair in @(
        @('project', '-ProjectRoot path does not exist'),
        @('commit', 'does not name a commit'),
        @('worktree-add', 'Could not create a worktree'),
        @('worktree-missing', 'Worktree missing'),
        @('branch-mismatch', 'Worktree branch mismatch'),
        @('baseline', 'Could not determine encoding baseline'),
        @('encoding', 'Check failed: Encoding guard \(BOM/mojibake\)'),
        @('whitespace', 'Check failed: Encoding guard \(whitespace\)'),
        @('command', 'Check failed: fixture check'),
        @('host-gate', 'Invalid verification host_gate'),
        @('hooks-config', 'Check failed: Project pre-push hook'),
        @('hook-interpreter', 'Check failed: Project pre-push hook'),
        @('hook-exit', 'Check failed: Project pre-push hook'),
        @('no-checks', 'configures no verification.full checks')
    )) { @{ Kind = 'runner'; Name = $pair[0]; Expected = $pair[1] } }
)

try {
    foreach ($case in $cases) {
        $results += Run-Test -Name ("I11 " + $case.Kind + ': ' + $case.Name) -Body {
            $root = Join-Path $tempRoot ($case.Kind + '-' + $case.Name)
            $lib = Join-Path $root 'lib'
            New-Item -ItemType Directory -Path $lib -Force | Out-Null
            $setup = ''
            $call = ''
            switch ($case.Kind) {
                'bootstrap' {
                    Copy-Item -LiteralPath (Join-Path $source 'crucible-lib.ps1') -Destination $root
                    # Only bootstrap existence checks execute; empty dependencies keep
                    # an earlier transitive import from masking the selected check.
                    foreach ($name in @($helpers) + @('file-lock', 'crucible-command', 'platform')) {
                        if ($name -ne $case.Name) { Write-FixtureText (Join-Path $lib ($name + '.ps1')) '' }
                    }
                    $call = "& './crucible-lib.ps1'"
                }
                'entry' {
                    Copy-Item -LiteralPath (Join-Path $source 'crucible.ps1') -Destination $root
                    foreach ($name in @('config-helpers', 'instruction-blocks', 'language-presets', 'project-root')) {
                        if ($name -ne $case.Name) { Write-FixtureText (Join-Path $lib ($name + '.ps1')) '' }
                    }
                    $call = "& './crucible.ps1'"
                }
                'research' {
                    Copy-TestRunnerLibraries -Destination $lib
                    Copy-Item -LiteralPath (Join-Path $source 'record-research-gate.ps1') -Destination $root
                    Write-FixtureText (Join-Path $root '.crucible/config.yaml') "project: fixture`n"
                    $extra = switch ($case.Name) {
                        'invalid-id' { '-Approved invalid' }
                        'missing-session' { '-Approved B-261' }
                        default { '' }
                    }
                    $call = "& './record-research-gate.ps1' -TaskId R-261 -Reason fixture -ProjectRoot `$PSScriptRoot $extra"
                }
                'gate' {
                    Copy-TestRunnerLibraries -Destination $lib
                    $setup = @'
. './lib/crucible-gates.ps1'
function Get-ConfiguredPrimaryBranch { 'fixture-primary' }
function Resolve-ConfigProjectRoot { $PSScriptRoot }
'@
                    $call = switch ($case.Name) {
                        'outcome' { "Invoke-HumanGateAction -TaskId F-261 -Outcome typo -ProjectRoot `$PSScriptRoot -LogFile unused -CircuitBreakerHistoryFile unused" }
                        'not-run' { 'Get-GateNotRunSessionDir -Context @{}' }
                        default {
                            Remove-Item -LiteralPath (Join-Path $lib 'archive-task.ps1')
                            Write-FixtureText (Join-Path $root 'session/global/gate_decisions/F-261-fixture.json') '{"outcome":"accepted"}'
                            if ($case.Name -eq 'missing-archive') { Write-FixtureText (Join-Path $root 'active/F-261.md') 'fixture' }
                            $setup += @'

function Test-DeploymentReworkReentry { $false }
function Get-PipelineValidTransitions { @{ grooming = @('done') } }
function Write-Quiet {}
function Get-TaskFinalizationDetails { @{ IsFinalized = $false } }
function Get-ConfiguredPath { $PSScriptRoot }
function Get-BacklogItemPathForTaskProjectRoot { Join-Path $PSScriptRoot 'active/F-261.md' }
$context = @{
    Handoff = [pscustomobject]@{ task_id = 'F-261'; source_phase = 'grooming'; target_phase = 'done' }
    IsBootstrap = $false; SessionDir = (Join-Path $PSScriptRoot 'session'); HandoffDir = ''
    FrameworkPowerShell = $PSScriptRoot; NextCrucibleCommand = ''; Quiet = $true
    LogFile = 'unused'; CircuitBreakerHistoryFile = 'unused'; RepoRoot = $PSScriptRoot
}
'@
                            'Resolve-CrucibleTransition -Context $context'
                        }
                    }
                }
                'runner' {
                    Copy-Item -LiteralPath (Join-Path $source 'run-isolated-checks.ps1') -Destination $root
                    # Deterministic config/native results select each command boundary
                    # error without starting worktrees, tools, or external services.
                    Write-FixtureText (Join-Path $lib 'checks-not-run.ps1') @'
function Clear-ChecksNotRun {}
function Write-CheckNotRun {}
function Get-ChecksNotRun { @() }
'@
                    Write-FixtureText (Join-Path $lib 'config-helpers.ps1') @'
function Resolve-FilesystemPath { param([string]$Path) $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path) }
function Get-ConfigCommitState { @{ Status = 'committed'; Content = 'fixture' } }
function Get-ConfiguredPath { param($Key) [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../data')) }
function Get-ConfiguredPrimaryBranch { 'fixture-primary' }
function Get-VerificationCheckIdentityErrors { @() }
function Get-VerificationChecks {
    if ($scenario -eq 'no-checks') { return @() }
    $command = if ($scenario -eq 'command') { '$global:LASTEXITCODE = 7' } else { '$global:LASTEXITCODE = 0' }
    $gate = if ($scenario -eq 'host-gate') { 'invalid-condition' } else { '' }
    [pscustomobject]@{ Name = 'fixture check'; Command = $command; HostGate = $gate; AlternativeRunner = '' }
}
function Get-ConfiguredProjectHooksDir {
    param($ProjectRoot)
    if ($scenario -eq 'hooks-config') { throw 'fixture hooks config error' }
    Join-Path $ProjectRoot 'hooks'
}
'@
                    Write-FixtureText (Join-Path $lib 'platform.ps1') @'
function Test-PlatformIsWindows { $IsWindows }
function Invoke-Git {
    param($Directory, [Parameter(ValueFromRemainingArguments=$true)]$GitArgs)
    $command = $GitArgs -join ' '
    $code = 0; $raw = ''; $lines = @()
    if ($command -match '^rev-parse --verify') {
        $raw = 'fixture-sha'; if ($scenario -eq 'commit') { $code = 1 }
    } elseif ($command -match '^worktree add') { $code = 1
    } elseif ($command -match '^rev-parse --abbrev-ref') {
        $raw = if ($scenario -eq 'branch-mismatch') { 'task/wrong-261' } else { 'task/F-261' }
    } elseif ($command -match '^merge-base') {
        $raw = 'fixture-base'; if ($scenario -eq 'baseline') { $code = 1 }
    } elseif ($command -match '^diff --check') {
        if ($scenario -eq 'whitespace') { $code = 1 }
    } elseif ($command -match '^diff' -and $scenario -eq 'encoding') { $lines = @('bad.md') }
    [pscustomobject]@{ ExitCode = $code; Raw = $raw; Lines = $lines }
}
'@
                    New-Item -ItemType Directory -Path (Join-Path $root 'data/implementation-F-261') -Force | Out-Null
                    if ($case.Name -eq 'worktree-missing') { Remove-Item -LiteralPath (Join-Path $root 'data/implementation-F-261') }
                    Write-FixtureText (Join-Path $root 'data/implementation-F-261/bad.md') 'fixture'
                    # bad.md creates its parent; remove it again for the missing case.
                    if ($case.Name -eq 'worktree-missing') { Remove-Item -LiteralPath (Join-Path $root 'data/implementation-F-261') -Recurse }
                    Write-FixtureText (Join-Path $root 'gates/check-mojibake.ps1') 'exit 7'
                    $interpreter = if ($case.Name -eq 'hook-interpreter') { 'missing-interpreter-261' } else { 'pwsh' }
                    Write-FixtureText (Join-Path $root 'data/implementation-F-261/hooks/pre-push') ("#!" + $interpreter + "`nexit 7`n")
                    if ($case.Name -eq 'worktree-missing') { Remove-Item -LiteralPath (Join-Path $root 'data/implementation-F-261') -Recurse }
                    $setup = "`$scenario = '$($case.Name)'"
                    $extra = if ($case.Name -in @('commit', 'worktree-add')) { '-Commit fixture' } else { '' }
                    $project = if ($case.Name -eq 'project') { "(Join-Path `$PSScriptRoot 'missing')" } else { '$PSScriptRoot' }
                    $call = "& './run-isolated-checks.ps1' -TaskId F-261 -ProjectRoot $project $extra"
                }
            }
            $child = Join-Path $root 'caller.ps1'
            $isCommand = $case.Kind -in @('bootstrap', 'entry', 'research', 'runner')
            # A .ps1 caller may continue after & script.ps1. Record the status
            # immediately and propagate it to the child process's own exit.
            $afterCall = if ($isCommand) {
                @'
$observedExit = $LASTEXITCODE
Write-Host "CALLER_LASTEXITCODE=$observedExit"
Write-Host 'CALLER_CONTINUED'
exit $observedExit
'@
            } else { "Write-Host 'CALLER_CONTINUED'" }
            Write-FixtureText $child @"
`$ErrorActionPreference = 'Stop'
Set-Location -LiteralPath `$PSScriptRoot
$setup
`$global:LASTEXITCODE = 0
try {
    $call
} catch { Write-Host 'CALLER_CAUGHT' }
$afterCall
"@
            $stderr = Join-Path $root 'stderr.txt'
            $res = Invoke-ExternalCommand { & $pwshCmd -NoProfile -File $child 2>$stderr }
            $diagnostic = [IO.File]::ReadAllText($stderr)
            $evidence = "exit=$($res.ExitCode)`n$($res.Output)`n$diagnostic"
            Assert-Result 'caller cannot catch the refusal' ($res.Output -notmatch 'CALLER_CAUGHT') $evidence
            if ($isCommand) {
                Assert-Result 'caller observes nonzero LASTEXITCODE' ($res.Output -match 'CALLER_LASTEXITCODE=(-?\d+)' -and [int]$Matches[1] -ne 0) $evidence
            } else {
                Assert-Result 'library refusal prevents continuation' ($res.Output -notmatch 'CALLER_CONTINUED') $evidence
            }
            Assert-Result 'child process exits nonzero' ($res.ExitCode -ne 0) $evidence
            Assert-Result 'refusal identifies the selected path on stderr' ($diagnostic -match $case.Expected) $evidence
        }
    }
} finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force
}
Write-TestFileSummary -Results $results
