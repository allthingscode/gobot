# Item 261 phases 1 and 2: each refusal runs inside a .ps1 caller's catch under Stop.
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
    foreach ($helper in @('instruction-blocks', 'language-presets', 'config-helpers', 'install-manifest')) {
        @{ Kind = 'init'; Name = "helper-$helper"; Expected = ('Required helper script not found at .*' + $helper + '\.ps1') }
    }
    foreach ($pair in @(
        @('stamp-missing', 'Cannot stamp Crucible metadata'),
        @('stamp-existing', 'already has Crucible version metadata'),
        @('copy-overwrite', 'overwrite scaffold-managed files'),
        @('template-missing', 'project template not found'),
        @('template-incomplete', 'incomplete or corrupt'),
        @('installed', 'installed Crucible bundle already exists'),
        @('root-missing', 'Install manifest root file not found'),
        @('root-overwrite', 'overwrite framework-managed files'),
        @('config-missing', 'expected config file was not created'),
        @('sample-missing', 'Sample task template not found'),
        @('sample-overwrite', 'overwrite existing sample task'),
        @('hooks-missing', 'cannot activate git hooks'),
        @('hooks-exit', 'Installed hook activation failed'),
        @('manifest-missing', 'Install manifest not found'),
        @('manifest-property', 'missing required property'),
        @('manifest-scaffold', 'scaffold_source must not be empty'),
        @('manifest-dirs', 'copied_dirs must not be empty'),
        @('manifest-root', 'root_files must not contain empty entries')
    )) { @{ Kind = 'init'; Name = $pair[0]; Expected = $pair[1] } }
    foreach ($name in @('clear', 'recovery', 'completion', 'human', 'blocked')) {
        @{ Kind = 'state-caller'; Name = $name; Expected = $(if ($name -eq 'clear') { 'RAW_STATE_FAILURE' } else { 'exit 7|exited 7' }) }
    }
    @{ Kind = 'hooks'; Name = 'repository'; Expected = 'Not a git repository' }
    @{ Kind = 'hooks'; Name = 'directory'; Expected = 'Hooks directory not found' }
    foreach ($pair in @(
        @('input', 'Either -UpdateJson or -UpdateJsonFile'),
        @('helper', 'Required helper script not found'),
        @('lock', 'Lock timeout'),
        @('update', 'Failed to update session state')
    )) { @{ Kind = 'state'; Name = $pair[0]; Expected = $pair[1] } }
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
                'init' {
                    $framework = Join-Path $root 'source'
                    $scripts = Join-Path $framework 'powershell'
                    $lib = Join-Path $scripts 'lib'
                    New-Item -ItemType Directory -Path $lib -Force | Out-Null
                    Copy-Item -LiteralPath (Join-Path $source 'init-project.ps1') -Destination $scripts
                    # Keep the command body unchanged; small dependencies select its
                    # refusal sites without copying/installing a real bundle.
                    Write-FixtureText (Join-Path $lib 'instruction-blocks.ps1') ''
                    Write-FixtureText (Join-Path $lib 'language-presets.ps1') ''
                    Write-FixtureText (Join-Path $lib 'crucible-command.ps1') "function New-CrucibleCommand { 'fixture command' }"
                    Write-FixtureText (Join-Path $lib 'config-helpers.ps1') @'
function Resolve-FilesystemPath { param($Path) $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path) }
function Test-PathWithinDirectory { $false }
function Get-ConfigBlockValue { $null }
function ConvertTo-ConfigScalar { param($Value) $Value }
function Get-ConfiguredPath { Join-Path $ProjectRoot 'backlog' }
function git { $global:LASTEXITCODE = 0; 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' }
'@
                    Write-FixtureText (Join-Path $lib 'install-manifest.ps1') @'
function Get-InstallManifest { [pscustomobject]@{ copied_dirs = @(); root_files = @('root.txt') } }
function Test-ScaffoldTemplateComplete { @{ IsComplete = ($scenario -ne 'template-incomplete'); IsAuthoritative = $true; OnDiskCount = 0; ExpectedCount = 1; MissingFiles = @('fixture') } }
function Test-NestedCrucibleRuntimePath { $false }
function Test-FrameworkDevOnlyFile { $false }
'@
                    $template = Join-Path $framework 'templates/project/.crucible'
                    Write-FixtureText (Join-Path $template 'config.yaml') "project: fixture`n"
                    Write-FixtureText (Join-Path $framework 'root.txt') 'fixture'
                    Write-FixtureText (Join-Path $framework 'VERSION') '1.0.0'
                    $project = Join-Path $root 'project'
                    New-Item -ItemType Directory -Path $project -Force | Out-Null
                    $extra = ''
                    switch ($case.Name) {
                        'template-missing' { Remove-Item -LiteralPath $template -Recurse -Force }
                        'stamp-missing' { $extra = '-StampVersionOnly' }
                        'stamp-existing' {
                            Write-FixtureText (Join-Path $project '.crucible/config.yaml') 'crucible_version: 1.0.0'
                            $extra = '-StampVersionOnly'
                        }
                        'copy-overwrite' {
                            Write-FixtureText (Join-Path $template 'existing.txt') 'source'
                            Write-FixtureText (Join-Path $project '.crucible/existing.txt') 'target'
                        }
                        'installed' { Write-FixtureText (Join-Path $project '.crucible/config.yaml') 'project: fixture' }
                        'root-missing' { Remove-Item -LiteralPath (Join-Path $framework 'root.txt') }
                        'root-overwrite' { Write-FixtureText (Join-Path $project '.crucible/root.txt') 'target' }
                        'config-missing' { Remove-Item -LiteralPath (Join-Path $template 'config.yaml') }
                        'sample-missing' { $extra = '-WithSampleTask' }
                        'sample-overwrite' {
                            Write-FixtureText (Join-Path $framework 'templates/sample-task/F-001_Hello_World.md') 'fixture'
                            Write-FixtureText (Join-Path $project 'backlog/features/active/F-001_Hello_World.md') 'target'
                            $extra = '-WithSampleTask'
                        }
                        'hooks-exit' {
                            Write-FixtureText (Join-Path $project '.git') 'fixture marker'
                            Write-FixtureText (Join-Path $template 'powershell/install-hooks.ps1') 'exit 7'
                        }
                        'hooks-missing' { Write-FixtureText (Join-Path $project '.git') 'fixture marker' }
                    }
                    if ($case.Name.StartsWith('helper-')) {
                        Remove-Item -LiteralPath (Join-Path $lib ($case.Name.Substring(7) + '.ps1'))
                    } elseif ($case.Name.StartsWith('manifest-')) {
                        Copy-Item -LiteralPath (Join-Path $source 'lib/install-manifest.ps1') -Destination $lib -Force
                        Copy-Item -LiteralPath (Join-Path $source 'lib/normalized-hash.ps1') -Destination $lib
                        $manifest = switch ($case.Name) {
                            'manifest-property' { '{}' }
                            'manifest-scaffold' { '{"scaffold_source":"","root_files":[],"copied_dirs":["powershell"],"adopter_owned_excludes":[]}' }
                            'manifest-dirs' { '{"scaffold_source":"templates","root_files":[],"copied_dirs":[],"adopter_owned_excludes":[]}' }
                            'manifest-root' { '{"scaffold_source":"templates","root_files":[""],"copied_dirs":["powershell"],"adopter_owned_excludes":[]}' }
                        }
                        if ($null -ne $manifest) { Write-FixtureText (Join-Path $framework 'install-manifest.json') $manifest }
                    }
                    $setup = "`$scenario = '$($case.Name)'"
                    $call = "& './source/powershell/init-project.ps1' -ProjectRoot (Join-Path `$PSScriptRoot 'project') -DefaultBranch main -Quiet $extra"
                }
                'state-caller' {
                    Copy-TestRunnerLibraries -Destination $lib
                    Write-FixtureText (Join-Path $root 'update-session-state.ps1') @'
[Console]::Error.WriteLine('RAW_STATE_FAILURE')
exit 7
'@
                    $setup = @'
. './lib/crucible-gates.ps1'
. './lib/time.ps1'
. './lib/blocked.ps1'
function ConvertTo-AsciiSafeText { param($Text) $Text }
function Get-InjectionMatches { ,@() }
$script:CRUCIBLE_PHASES = @('deployment')
function Write-Quiet { param($Message, $ForegroundColor) Write-Host $Message }
function Write-EventLog { Write-Host 'EVENT_AFTER_UPDATE' }
function Get-ConfiguredPath { Join-Path $PSScriptRoot 'session' }
function Resolve-CrucibleProjectRoot { $PSScriptRoot }
function Resolve-ConfigProjectRoot { $PSScriptRoot }
function Move-TaskHandoffsToArchive { @() }
function Test-DeploymentReworkReentry { $false }
function Get-PipelineValidTransitions { @{ deployment = @('done') } }
$handoff = [pscustomobject]@{ task_id = 'F-261'; source_phase = 'deployment'; target_phase = 'done'; reason = 'fixture' }
$context = @{
    Handoff = $handoff; IsBootstrap = $false; SessionDir = (Join-Path $PSScriptRoot 'session')
    HandoffDir = ''; FrameworkPowerShell = $PSScriptRoot; NextCrucibleCommand = ''; Quiet = $false
    LogFile = 'unused'; CircuitBreakerHistoryFile = 'unused'; RepoRoot = $PSScriptRoot
    Recover = $true; TaskId = 'F-261'; LatestHandoff = (Get-Item './handoff.json')
}
'@
                    Write-FixtureText (Join-Path $root 'handoff.json') '{}'
                    $call = switch ($case.Name) {
                        'clear' {
                            Copy-Item -LiteralPath (Join-Path $source 'clear-session-state.ps1') -Destination $root
                            "& './clear-session-state.ps1' -Specialist implementation -ProjectRoot `$PSScriptRoot"
                        }
                        'completion' { 'Resolve-CrucibleTransition -Context $context' }
                        'recovery' {
                            Write-FixtureText (Join-Path $root 'session/F-261/done/task.md') 'fixture'
                            'Normalize-CrucibleInputState -Context $context'
                        }
                        'human' { 'Invoke-HumanGateAcceptArchival -TaskId F-261 -ProjectRoot $PSScriptRoot' }
                        'blocked' { 'Write-BlockedTaskRecord -TaskId F-261 -CircuitBreaker fixture -AttemptCount 1 -LastPhase implementation -Summary fixture -BacklogDir (Join-Path $PSScriptRoot "backlog") -FrameworkPowerShell $PSScriptRoot' }
                    }
                }
                'hooks' {
                    # Two nested levels prevent the real checkout's .git from
                    # satisfying either of the installer's repository checks.
                    $scripts = Join-Path $root 'repo/powershell'
                    New-Item -ItemType Directory -Path $scripts -Force | Out-Null
                    Copy-Item -LiteralPath (Join-Path $source 'install-hooks.ps1') -Destination $scripts
                    if ($case.Name -eq 'directory') { Write-FixtureText (Join-Path $root 'repo/.git') 'fixture marker' }
                    $call = "& './repo/powershell/install-hooks.ps1' -Quiet"
                }
                'state' {
                    Copy-Item -LiteralPath (Join-Path $source 'update-session-state.ps1') -Destination $root
                    Write-FixtureText (Join-Path $lib 'config-helpers.ps1') @'
function Get-ConfiguredPath { Join-Path $PSScriptRoot '../session' }
'@
                    Write-FixtureText (Join-Path $lib 'project-root.ps1') 'function Resolve-CrucibleProjectRoot { $PSScriptRoot }'
                    Write-FixtureText (Join-Path $lib 'time.ps1') ''
                    if ($case.Name -eq 'helper') { Remove-Item -LiteralPath (Join-Path $lib 'config-helpers.ps1') }
                    if ($case.Name -eq 'lock') { Write-FixtureText (Join-Path $root 'session/global/session_state.lock') 'fixture lock' }
                    $extra = if ($case.Name -eq 'input') { '' } else { "-UpdateJson 'invalid-json'" }
                    $call = "& './update-session-state.ps1' -Specialist implementation $extra"
                }
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
            $isCommand = $case.Kind -in @('bootstrap', 'entry', 'research', 'runner', 'init', 'hooks', 'state')
            # A .ps1 caller may continue after & script.ps1. Record the status
            # immediately and propagate it to the child process's own exit.
            $afterCall = if ($isCommand) {
                @'
$observedExit = $LASTEXITCODE
Write-Host "CALLER_LASTEXITCODE=$observedExit"
Write-Host 'CALLER_CONTINUED'
exit $observedExit
'@
            } else { "[Console]::Error.WriteLine('CONSOLE_RESTORED'); Write-Host 'CALLER_CONTINUED'" }
            Write-FixtureText $child @"
`$ErrorActionPreference = 'Stop'
Set-Location -LiteralPath `$PSScriptRoot
$setup
`$global:LASTEXITCODE = 0
try {
    $call
} catch { Write-Host ('CALLER_CAUGHT: ' + `$_.Exception.Message) }
$afterCall
"@
            $stderr = Join-Path $root 'stderr.txt'
            $clearCommand = $case.Kind -eq 'state-caller' -and $case.Name -eq 'clear'
            $hookInitCommand = $case.Kind -eq 'init' -and $case.Name -eq 'hooks-exit'
            $res = if ($clearCommand) {
                # Exercise pwsh -File itself: a wrapper that explicitly propagates
                # LASTEXITCODE would hide clear-session-state's missing exit.
                Invoke-ExternalCommand { & $pwshCmd -NoProfile -File (Join-Path $root 'clear-session-state.ps1') -Specialist implementation -ProjectRoot $root 2>$stderr }
            } elseif ($hookInitCommand) {
                Invoke-ExternalCommand { & $pwshCmd -NoProfile -File (Join-Path $root 'source/powershell/init-project.ps1') -ProjectRoot (Join-Path $root 'project') -DefaultBranch main 2>$stderr }
            } else {
                Invoke-ExternalCommand { & $pwshCmd -NoProfile -File $child 2>$stderr }
            }
            $diagnostic = [IO.File]::ReadAllText($stderr)
            $evidence = "exit=$($res.ExitCode)`n$($res.Output)`n$diagnostic"
            $advisory = $case.Kind -eq 'state-caller' -and $case.Name -in @('human', 'blocked')
            if ($advisory) {
                Assert-Result 'advisory caller continues' ($res.ExitCode -eq 0 -and $res.Output -match 'CALLER_CONTINUED') $evidence
                Assert-Result 'advisory failure is reported' ($res.Output -match $case.Expected) $evidence
                if ($case.Name -eq 'blocked') {
                    Assert-Result 'raw console diagnostic suppressed' ($diagnostic -notmatch 'RAW_STATE_FAILURE') $evidence
                    Assert-Result 'console error writer restored' ($diagnostic -match 'CONSOLE_RESTORED') $evidence
                    Assert-Result 'blocked record survives' (@(Get-ChildItem (Join-Path $root 'backlog/blocked') -Filter '*.json').Count -eq 1) $evidence
                }
                return
            }
            Assert-Result 'caller cannot catch the refusal' ($res.Output -notmatch 'CALLER_CAUGHT') $evidence
            if ($clearCommand -or $hookInitCommand) {
                # The process exit below is the command's public result.
            } elseif ($isCommand) {
                Assert-Result 'caller observes nonzero LASTEXITCODE' ($res.Output -match 'CALLER_LASTEXITCODE=(-?\d+)' -and [int]$Matches[1] -ne 0) $evidence
            } else {
                Assert-Result 'library refusal prevents continuation' ($res.Output -notmatch 'CALLER_CONTINUED') $evidence
            }
            Assert-Result 'child process exits nonzero' ($res.ExitCode -ne 0) $evidence
            if ($hookInitCommand) {
                Assert-Result 'no scaffold success after hook failure' ($res.Output -notmatch 'Project scaffold installed') $evidence
            }
            if ($case.Kind -eq 'state-caller') {
                Assert-Result 'no success or event after failed update' ($res.Output -notmatch 'Pipeline Complete|EVENT_AFTER_UPDATE') $evidence
            }
            Assert-Result 'refusal identifies the selected path on stderr' ($diagnostic -match $case.Expected) $evidence
            if ($case.Kind -eq 'state' -and $case.Name -eq 'update') {
                Assert-Result 'failed update releases its lock' (-not (Test-Path -LiteralPath (Join-Path $root 'session/global/session_state.lock'))) $evidence
            }
        }
    }
} finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force
}
Write-TestFileSummary -Results $results
