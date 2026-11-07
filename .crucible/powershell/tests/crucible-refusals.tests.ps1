# Item 261 phases 1, 2, 3a and 3b: refusals run inside a caller's catch under Stop.
# Invoked scripts return a nonzero LASTEXITCODE; dot-sourced libraries terminate
# the hosting script. Neither boundary permits a catch to swallow the refusal.
# Dependency stubs select otherwise difficult failure paths; the boundary code is
# copied unchanged. Existing gate and runner suites cover the real dependencies.
param([string[]]$Kind = @())

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
    foreach ($pair in @(
        @('affinity', 'Required helper script not found'),
        @('merge', 'Required helper script not found'),
        @('doctor-crucible-lib', 'Required helper script not found'),
        @('doctor-platform', 'Required helper script not found'),
        @('doctor-gitignore-conformance', 'Required helper script not found'),
        @('doctor-line-ending-conformance', 'Required helper script not found'),
        @('status-helper', 'Required helper script not found'),
        @('status-state', 'Session state file not found'),
        @('status-backlog', 'Backlog file not found'),
        @('status-manifest', 'MANIFEST_FAILURE'),
        @('docs-empty', 'BUDGET_TIERS is empty'),
        @('docs-ceiling', 'has no entry in BUDGET_CEILINGS'),
        @('docs-block', 'returned no block'),
        @('mirror-manifest', 'MANIFEST_FAILURE'),
        @('mirror-catch', 'git ls-files --others failed'),
        @('bundle-catch', 'FrameworkSource must be a git repository'),
        @('backlog-config-helpers', 'Required helper script not found'),
        @('backlog-archive-task', 'Required helper script not found'),
        @('backlog-project-root', 'Required helper script not found'),
        @('dev-log', 'File not found'),
        @('launcher-project', 'path does not exist'),
        @('clear-project', 'path does not exist'),
        @('state-project', 'path does not exist'),
        @('research-project', 'path does not exist'),
        @('test-runner', 'RUNNER_FAILURE'),
        @('linux-gate', 'STAMP_FAILURE'),
        @('linux-command', 'WSL not found')
    )) { @{ Kind = 'remaining-command'; Name = $pair[0]; Expected = $pair[1] } }
    foreach ($name in @('Invoke-CircuitBreakerGates', 'Resolve-CrucibleInputHandoff',
        'Restore-MisplacedHandoff', 'Read-CrucibleHandoffContext', 'Invoke-HandoffPreflightValidation',
        'Normalize-CrucibleInputState', 'Invoke-HumanGate', 'Complete-CrucibleSourceSession',
        'Invoke-CrucibleRuntimeValidation', 'Invoke-CrucibleScopeGates', 'Test-CompletionArtifactGate',
        'Invoke-RepositoryIntegrityGates', 'Resolve-CrucibleTransition', 'New-CruciblePromptText',
        'Write-CruciblePromptOutput', 'Initialize-CrucibleTargetSession', 'Write-CrucibleCiStatusBanner',
        'Start-CrucibleTargetSessionLog')) {
        @{ Kind = 'remaining-library'; Name = $name; Expected = 'Required key' }
    }
    foreach ($name in @('doctor', 'status', 'health', 'affinity', 'backlog', 'dev-log', 'init-backlog', 'handoff-validator', 'preflight-validator')) {
        @{ Kind = 'remaining-caller'; Name = $name; Expected = 'CHILD_FAILURE|exit 7|exited 7|validation failed' }
    }
    foreach ($name in @('action', 'accept', 'integrity', 'merge')) {
        @{ Kind = 'remaining-helper'; Name = $name; Expected = 'HELPER_FAILURE' }
    }
    @{ Kind = 'remaining-restore'; Name = 'validator'; Expected = 'Could not update backlog.*Backlog validation exited 7' }
    foreach ($name in @('analyze', 'health', 'agents', 'launcher-bundle', 'validator-config', 'handoff-config')) {
        @{ Kind = 'remaining-config'; Name = $name; Expected = 'CONFIG_FAILURE|crucible_root value is empty|Cannot qualify a filesystem path' }
    }
    foreach ($name in @('init', 'update')) {
        @{ Kind = 'remaining-agent-caller'; Name = $name; Expected = 'generation exited 7' }
    }
    foreach ($pair in @(
        @('backlog-dir', 'Backlog directory not found'),
        @('backlog-file', 'BACKLOG.md not found'),
        @('validator-missing', 'Validator not found'),
        @('validator-exit', 'Schema validation failed'),
        @('rebaseline-extra', 'takes no other handoff fields'),
        @('rebaseline-base', 'needs -BaseCommit'),
        @('rebaseline-empty', 'No active handoff'),
        @('rebaseline-commit', 'does not name a commit'),
        @('rebaseline-same', 'already based on'),
        @('rebaseline-ancestor', 'does not descend'),
        @('rebaseline-collision', 'already exists'),
        @('commit', 'does not name a commit'),
        @('suspicious', 'reads as'),
        @('artifacts', 'Artifacts entry contains a quote'),
        @('affinity', 'FileAffinity entry contains a quote'),
        @('scope', 'is not covered by')
    )) { @{ Kind = 'handoff'; Name = $pair[0]; Expected = $pair[1] } }
    foreach ($pair in @(
        @('helper', 'Required helper script not found'),
        @('terminal', 'Cannot derive a terminal status'),
        @('frontmatter', 'missing YAML frontmatter'),
        @('row', 'does not contain active spec row'),
        @('collision', 'Archived spec already exists'),
        @('rollback', 'ARCHIVE_SUMMARY_FAILURE')
    )) { @{ Kind = 'archive'; Name = $pair[0]; Expected = $pair[1] } }
    foreach ($name in @('cli', 'merge', 'reject', 'research-runner')) {
        @{ Kind = 'handoff-caller'; Name = $name; Expected = 'HANDOFF_FAILURE|handoff.*refused|handoff generation failed' }
    }
    foreach ($name in @('completion', 'restore', 'legacy-abandon', 'accept')) {
        @{ Kind = 'archive-gate'; Name = $name; Expected = 'ARCHIVE_FAILURE|missing YAML frontmatter|Auto-finalization failed' }
    }
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
if ($Kind.Count -gt 0) { $cases = @($cases | Where-Object { $_.Kind -in $Kind }) }

try {
    foreach ($case in $cases) {
        $results += Run-Test -Name ("I11 " + $case.Kind + ': ' + $case.Name) -Body {
            $root = Join-Path $tempRoot ($case.Kind + '-' + $case.Name)
            $lib = Join-Path $root 'lib'
            New-Item -ItemType Directory -Path $lib -Force | Out-Null
            $setup = ''
            $call = ''
            switch ($case.Kind) {
                'remaining-command' {
                    # Dependencies select the real script boundary without launching
                    # tools, WSL, installers or specialist runtimes.
                    Copy-TestRunnerLibraries -Destination $lib
                    Write-FixtureText (Join-Path $lib 'config-helpers.ps1') @'
function Resolve-FilesystemPath { param($Path) $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path) }
function Resolve-ConfigProjectRoot { $PSScriptRoot }
function Get-ConfiguredPath { param($Key) Join-Path (Split-Path $PSScriptRoot) $Key }
'@
                    $name = $case.Name
                    $script = switch -Regex ($name) {
                        '^affinity' { 'check-file-affinity'; break }
                        '^merge' { 'check-merge-conflicts'; break }
                        '^doctor-' { 'crucible-doctor'; break }
                        '^status-' { 'crucible-status'; break }
                        '^docs-' { 'gates/check-generated-docs'; break }
                        '^mirror-' { 'sync-example-mirror'; break }
                        '^bundle-' { 'update-bundle'; break }
                        '^backlog-' { 'validate-backlog'; break }
                        '^dev-log' { 'validate-dev-log'; break }
                        '^launcher-' { 'launch-codex-specialist'; break }
                        '^clear-' { 'clear-session-state'; break }
                        '^state-' { 'update-session-state'; break }
                        '^research-' { 'record-research-gate'; break }
                        '^test-runner' { 'run-all-tests'; break }
                        '^linux-gate' { 'gates/check-linux-leg'; break }
                        '^linux-command' { 'scripts/test-linux'; break }
                    }
                    $target = Join-Path $root ($script + '.ps1')
                    New-Item -ItemType Directory (Split-Path $target) -Force | Out-Null
                    $original = if ($name -eq 'linux-command') { Join-Path $source '../scripts/test-linux.ps1' } else { Join-Path $source ($script + '.ps1') }
                    Copy-Item -LiteralPath $original -Destination $target
                    $extra = ''
                    switch -Regex ($name) {
                        '^affinity' { Remove-Item (Join-Path $lib 'config-helpers.ps1') -Force; $extra = '-TaskId F-261 -Affinity src/' }
                        '^merge' { $extra = '-TaskId F-261' }
                        '^doctor-' {
                            Write-FixtureText (Join-Path $root 'crucible-lib.ps1') ''
                            foreach ($helper in @('platform', 'gitignore-conformance', 'line-ending-conformance')) { Write-FixtureText (Join-Path $lib ($helper + '.ps1')) '' }
                            $missing = $name.Substring(7)
                            $path = if ($missing -eq 'crucible-lib') { Join-Path $root 'crucible-lib.ps1' } else { Join-Path $lib ($missing + '.ps1') }
                            Remove-Item $path -Force
                        }
                        '^status-' {
                            Write-FixtureText (Join-Path $lib 'backlog-io.ps1') ''
                            if ($name -eq 'status-helper') { Remove-Item (Join-Path $lib 'config-helpers.ps1') -Force }
                            if ($name -eq 'status-backlog') { Write-FixtureText (Join-Path $root 'session/global/session_state.json') '{"tasks":{}}' }
                            if ($name -eq 'status-manifest') {
                                Write-FixtureText (Join-Path $lib 'install-manifest.ps1') "function Get-InstallManifest { throw 'MANIFEST_FAILURE' }"
                                $extra = '-Drift'
                            }
                        }
                        '^docs-' {
                            Write-FixtureText (Join-Path $root 'powershell/crucible-lib.ps1') @'
function Get-BudgetTierList { if ($scenario -eq 'docs-empty') { @() } else { 'low' } }
function Get-BudgetCeilings { if ($scenario -eq 'docs-ceiling') { @{} } else { @{ low = 1 } } }
'@
                            Write-FixtureText (Join-Path $root 'powershell/lib/instruction-blocks.ps1') 'function Get-CrucibleBlock { @{} }'
                            # The gate derives its repo root two levels above itself.
                            $target = Join-Path $root 'powershell/gates/check-generated-docs.ps1'
                            New-Item -ItemType Directory (Split-Path $target) -Force | Out-Null
                            Copy-Item -LiteralPath $original -Destination $target
                            $region = if ($name -eq 'docs-block') { 'instruction-block-agents' } else { 'budget-tier-ceilings' }
                            $doc = if ($name -eq 'docs-block') { 'agent-instructions.md' } else { 'policy.md' }
                            Write-FixtureText (Join-Path $root ('docs/' + $doc)) "<!-- crucible:generated $region -->`n<!-- crucible:end $region -->`n"
                        }
                        '^mirror-' {
                            Copy-Item (Join-Path $lib 'config-helpers.ps1') (Join-Path $lib 'config-saved.ps1')
                            Write-FixtureText (Join-Path $root 'powershell/lib/config-helpers.ps1') ([IO.File]::ReadAllText((Join-Path $lib 'config-saved.ps1')))
                            Write-FixtureText (Join-Path $root 'powershell/lib/platform.ps1') 'function Invoke-Git { [pscustomobject]@{ ExitCode = 7; Lines = @() } }'
                            $manifestStub = if ($name -eq 'mirror-manifest') { "function Get-InstallManifest { throw 'MANIFEST_FAILURE' }" } else { "function Get-InstallManifest { @{} }; function Get-InstallSourceRoot { 'powershell' }" }
                            Write-FixtureText (Join-Path $root 'powershell/lib/install-manifest.ps1') $manifestStub
                            # SCRIPT_ROOT is the parent of the script directory.
                            $target = Join-Path $root 'powershell/sync-example-mirror.ps1'
                            Copy-Item -LiteralPath $original -Destination $target
                        }
                        '^bundle-' { $extra = '-FrameworkSource $PSScriptRoot -AdopterRoot $PSScriptRoot -Mode auto-safe' }
                        '^backlog-' {
                            Write-FixtureText (Join-Path $lib 'backlog-io.ps1') ''
                            Write-FixtureText (Join-Path $lib 'crucible-command.ps1') ''
                            Write-FixtureText (Join-Path $lib 'worktree.ps1') ''
                            foreach ($helper in @('config-helpers', 'archive-task', 'project-root')) { Write-FixtureText (Join-Path $lib ($helper + '.ps1')) '' }
                            Remove-Item (Join-Path $lib ($name.Substring(8) + '.ps1')) -Force
                            $extra = '-BacklogPath ./BACKLOG.md'
                        }
                        '^dev-log' { $extra = '-FileToPublish ./missing.md' }
                        '^launcher-' {
                            Copy-Item (Join-Path $source 'lib/config-helpers.ps1') $lib -Force
                            $extra = '-ProjectRoot ./missing'
                        }
                        '^(clear|state|research)-project' {
                            Copy-Item (Join-Path $source 'lib/config-helpers.ps1') $lib -Force
                            $extra = switch ($name) {
                                'clear-project' { '-Specialist implementation -ProjectRoot ./missing' }
                                'state-project' { '-Specialist implementation -UpdateJson invalid -ProjectRoot ./missing' }
                                'research-project' { '-TaskId F-261 -Reason fixture -ProjectRoot ./missing' }
                            }
                        }
                        '^test-runner' { Write-FixtureText (Join-Path $root 'tests/_harness.ps1') "throw 'RUNNER_FAILURE'" }
                        '^linux-gate' {
                            Write-FixtureText (Join-Path $lib 'platform.ps1') 'function Invoke-Git { [pscustomobject]@{ ExitCode = 0; Lines = @($PSScriptRoot) } }'
                            Write-FixtureText (Join-Path $lib 'linux-leg-stamp.ps1') "throw 'STAMP_FAILURE'"
                        }
                        '^linux-command' { $setup = 'function Get-Command { $null }' }
                    }
                    $setup += "`n`$scenario = '$name'"
                    $escaped = $target.Replace("'", "''")
                    $call = "& '$escaped' $extra"
                }
                'remaining-library' {
                    Copy-TestRunnerLibraries -Destination $lib
                    $setup = ". './lib/crucible-gates.ps1'`n. './lib/session-output.ps1'"
                    $call = $case.Name + ' -Context @{}'
                    if ($case.Name -in @('Resolve-CrucibleInputHandoff', 'Restore-MisplacedHandoff', 'Read-CrucibleHandoffContext')) {
                        # Readers remain reusable. Exercise the consuming command's
                        # real trap with their real context failure, under caller Stop.
                        $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $source 'crucible.ps1'), [ref]$null, [ref]$null)
                        $boundary = ($ast.EndBlock.Traps | ForEach-Object { $_.Extent.Text }) -join "`n"
                        Write-FixtureText (Join-Path $root 'reader-command.ps1') ($setup + "`n" + $boundary + "`n" + $call)
                        $setup = ''
                        $call = "& './reader-command.ps1'"
                    }
                }
                'remaining-caller' {
                    $name = $case.Name
                    if ($name -in @('doctor', 'status', 'health')) {
                        Copy-Item (Join-Path $source 'crucible.ps1') $root
                        foreach ($helper in @('config-helpers', 'instruction-blocks', 'language-presets')) { Write-FixtureText (Join-Path $lib ($helper + '.ps1')) '' }
                        Write-FixtureText (Join-Path $lib 'project-root.ps1') 'function Resolve-CrucibleProjectRoot { Split-Path $PSScriptRoot }'
                        Write-FixtureText (Join-Path $root 'crucible-lib.ps1') @'
function Get-ConfiguredPath { param($Key) Join-Path $PSScriptRoot $Key }
function Get-BudgetCeilings { @{} }
function Resolve-StickyTarget { 'agent' }
'@
                        $invoke = "& './crucible.ps1' -$name -Quiet"
                        $childScript = 'crucible-' + $name + '.ps1'
                    } else {
                        # Execute the production invocation and its immediate guard,
                        # preserving their AST extents. Surrounding setup is unrelated
                        # to this caller's child-status contract.
                        $path = switch ($name) { 'init-backlog' { 'init-project.ps1' }; 'handoff-validator' { 'new-handoff.ps1' }; 'preflight-validator' { 'lib/crucible-gates-handoff.ps1' }; default { 'lib/crucible-gates.ps1' } }
                        $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $source $path), [ref]$null, [ref]$null)
                        $needle = switch ($name) {
                            'affinity' { '& $affinityScript' }
                            'backlog' { '& (Get-RunningPowerShellCommand) -NoProfile -File (Resolve-FilesystemPath -Path "$FRAMEWORK_POWERSHELL/validate-backlog.ps1")' }
                            'dev-log' { '& "$FRAMEWORK_POWERSHELL/validate-dev-log.ps1"' }
                            'init-backlog' { '& (Join-Path $PSScriptRoot "validate-backlog.ps1")' }
                            'handoff-validator' { '& (Get-RunningPowerShellCommand) -NoProfile -File (Resolve-FilesystemPath -Path $validatorPath)' }
                            'preflight-validator' { '& $preflightScript' }
                        }
                        $node = $ast.Find({ param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.Extent.Text.StartsWith($needle) }, $true)
                        if ($null -eq $node) { throw "Caller invocation not found: $name" }
                        while ($null -ne $node.Parent -and $node.Parent -isnot [Management.Automation.Language.StatementBlockAst] -and $node.Parent -isnot [Management.Automation.Language.NamedBlockAst]) { $node = $node.Parent }
                        if ($null -eq $node.Parent) { throw "Caller statement block not found: $name" }
                        $statements = @($node.Parent.Statements)
                        $index = [array]::IndexOf($statements, $node)
                        $start = $index
                        if ($index -gt 0 -and $statements[$index - 1].Extent.Text -match 'global:LASTEXITCODE = 0') { $start-- }
                        $end = $index
                        while ($end + 1 -lt $statements.Count -and $statements[$end + 1].Extent.Text -match '^if \(\$LASTEXITCODE -ne 0') { $end++ }
                        if ($name -eq 'preflight-validator') {
                            while ($end -lt $statements.Count -and $statements[$end].Extent.Text -notmatch '^if \(\$preflightExit -ne 0 -or') { $end++ }
                            if ($end -eq $statements.Count) { throw 'Preflight status guard not found' }
                        }
                        $body = ($statements[$start..$end] | ForEach-Object { $_.Extent.Text }) -join "`n"
                        # init-project owns a command trap around its sample install;
                        # the gate callers refuse inside their immediate status guard.
                        if ($name -eq 'init-backlog') { $body = $ast.EndBlock.Traps[0].Extent.Text + "`n" + $body }
                        if ($name -eq 'handoff-validator') { $body = $ast.EndBlock.Traps[0].Extent.Text + "`n" + $body }
                        Write-FixtureText (Join-Path $root 'boundary.ps1') $body
                        $invoke = "& './boundary.ps1'"
                        $childScript = switch ($name) { 'affinity' { 'check-file-affinity.ps1' }; 'dev-log' { 'validate-dev-log.ps1' }; { $_ -in @('handoff-validator', 'preflight-validator') } { 'validate-handoff.ps1' }; default { 'validate-backlog.ps1' } }
                    }
                    Write-FixtureText (Join-Path $root $childScript) @'
param($TaskId, $Affinity, $ProjectRoot, $FileToPublish, $BacklogPath, $HandoffFile, $SchemaPath, [switch]$Quiet, [switch]$FixSummary, [switch]$Health, [switch]$Cleanup, [switch]$Force)
if ($scenario -eq 'failure') { [Console]::Error.WriteLine('CHILD_FAILURE'); exit 7 }
if ($HandoffFile) { '{"ok":true}' }
# Intentionally leave status untouched to verify caller initialization.
'@
                    if ($name -in @('affinity', 'dev-log', 'preflight-validator')) {
                        $childAst = [Management.Automation.Language.Parser]::ParseFile((Join-Path $source $childScript), [ref]$null, [ref]$null)
                        $stubPath = Join-Path $root $childScript
                        $stub = [IO.File]::ReadAllText($stubPath)
                        $stub = $stub.Replace("if (`$scenario -eq 'failure') { [Console]::Error.WriteLine('CHILD_FAILURE'); exit 7 }", $childAst.EndBlock.Traps[0].Extent.Text + "`nif (`$scenario -eq 'failure') { throw 'CHILD_FAILURE' }")
                        Write-FixtureText $stubPath $stub
                    }
                    if ($name -in @('backlog', 'handoff-validator')) {
                        $stubPath = Join-Path $root $childScript
                        Write-FixtureText $stubPath ([IO.File]::ReadAllText($stubPath).Replace('$scenario', '$env:CRUCIBLE_REFUSAL_SCENARIO'))
                    }
                    $setup = @"
Set-StrictMode -Version Latest
. '$source/lib/platform.ps1'
function Resolve-FilesystemPath { param(`$Path) `$Path }
function Write-Quiet {}
function Write-EventLog { Write-Host 'EVENT_AFTER_FAILURE' }
function Write-WedgeReport {}
function Get-RecoveryProjectRoot { `$PSScriptRoot }
`$FRAMEWORK_POWERSHELL = `$PSScriptRoot
`$affinityScript = Join-Path `$PSScriptRoot 'check-file-affinity.ps1'
`$handoff = [pscustomobject]@{ task_id = 'F-261'; file_affinity = @('src/'); source_phase = 'deployment'; target_phase = 'done'; cumulative_handoff_count = 1 }
`$Quiet = `$true
`$repoRoot = `$PSScriptRoot
`$LOG_FILE = 'unused'; `$CB_HISTORY_FILE = 'unused'
`$backlogFilePath = 'unused'; `$validateQuiet = `$true; `$devLogPath = 'unused'
`$validatorPath = Join-Path `$PSScriptRoot 'validate-handoff.ps1'
`$preflightScript = `$validatorPath
`$tempPath = 'unused'; `$SchemaPath = 'unused'; `$handoffFile = 'unused'
`$Context = @{ RepoRoot = `$PSScriptRoot }
`$scenario = 'success'
`$env:CRUCIBLE_REFUSAL_SCENARIO = 'success'
`$global:LASTEXITCODE = 7
$invoke
if (`$LASTEXITCODE -ne 0) { throw 'SUCCESS_STATUS_STALE' }
Write-Host 'CALLER_SUCCESS'
`$scenario = 'failure'
`$env:CRUCIBLE_REFUSAL_SCENARIO = 'failure'
"@
                    $call = $invoke
                }
                'remaining-helper' {
                    Copy-TestRunnerLibraries -Destination $lib
                    $setup = @'
. './lib/crucible-gates.ps1'
function Write-BlockedTaskRecord { throw 'UNEXPECTED_BLOCKED_WRITER' }
function Get-ConfiguredPrimaryBranch { throw 'HELPER_FAILURE: primary branch' }
function Get-ConfiguredPath { throw 'HELPER_FAILURE: backlog path' }
function Get-CrucibleFrameworkStatusChanges { @() }
function Write-EventLog {}
function Write-Quiet {}
function Write-CheckNotRun { throw 'HELPER_FAILURE: skipped-check record' }
function Test-GitDiscardSafe { $true }
function Invoke-GitChecked { $global:LASTEXITCODE = 1 }
'@
                    $call = if ($case.Name -eq 'action') {
                        'Invoke-HumanGateAction -TaskId F-261 -Outcome accepted -LogFile unused -CircuitBreakerHistoryFile unused'
                    } elseif ($case.Name -eq 'integrity') {
                        'Assert-CrucibleFrameworkIntegrity -Context @{ FrameworkIntegrityBaseline = $null; TaskId = "F-261"; SessionDir = $PSScriptRoot; LogFile = "unused"; CircuitBreakerHistoryFile = "unused" }'
                    } elseif ($case.Name -eq 'merge') {
                        'Invoke-HumanGateMerge -TaskId F-261 -PrimaryBranch main -ProjectRoot $PSScriptRoot -LogFile unused -CircuitBreakerHistoryFile unused -DecisionRecordPath unused'
                    } else {
                        'Invoke-HumanGateAcceptRedirect -TaskId F-261 -Outcome accepted -LogFile unused -CircuitBreakerHistoryFile unused -ProjectRoot $PSScriptRoot -PrimaryBranch main -SourcePhase grooming'
                    }
                }
                'remaining-restore' {
                    Copy-TestRunnerLibraries -Destination $lib
                    Write-FixtureText (Join-Path $root 'features/active/F-261.md') "---`nstatus: Ready`n---`nfixture`n"
                    Write-FixtureText (Join-Path $root 'BACKLOG.md') "| ID | Priority | Status | Title |`n|---|---|---|---|`n| [F-261](features/active/F-261.md) | P2 | Ready | Fixture |`n"
                    Write-FixtureText (Join-Path $root 'validate-backlog.ps1') 'exit 0'
                    Write-FixtureText (Join-Path $root 'new-handoff.ps1') "Write-Host 'NEW_HANDOFF_AFTER_FAILURE'; exit 0"
                    $setup = @'
Set-StrictMode -Version Latest
. './lib/crucible-gates.ps1'
. './lib/archive-task.ps1'
function Get-ConfiguredPath { $PSScriptRoot }
function Resolve-ConfigProjectRoot { $PSScriptRoot }
function Write-Quiet {}
function Assert-HumanGateReworkAvailable {}
function Test-GitDiscardSafe { $true }
function Invoke-GitChecked {}
function Invoke-Git { [pscustomobject]@{ ExitCode = 1; Raw = ''; Lines = @() } }
function Get-HumanGateRejectUnwind { @{ CurrentHead = 'head'; ParentList = @(); HeadIsTaskMerge = $false; UnwindTarget = '' } }
function git { $global:LASTEXITCODE = 1 }
$global:LASTEXITCODE = 7
Restore-BacklogTask -TaskId F-261 -ProjectRoot $PSScriptRoot
if ($LASTEXITCODE -ne 0) { throw 'SUCCESS_STATUS_STALE' }
Write-Host 'CALLER_SUCCESS'
[IO.File]::WriteAllText((Join-Path $PSScriptRoot 'validate-backlog.ps1'), "Write-Host 'ROW_F261_INVALID'; exit 7")
'@
                    $call = 'Invoke-HumanGateRejectAbandon -TaskId F-261 -Outcome rejected -ProjectRoot $PSScriptRoot -PrimaryBranch main'
                }
                'remaining-config' {
                    Copy-TestRunnerLibraries -Destination $lib
                    $script = switch ($case.Name) { 'analyze' { 'analyze-evals' }; 'health' { 'crucible-health' }; 'agents' { 'sync-claude-agents' }; 'validator-config' { 'validate-config' }; 'handoff-config' { 'validate-handoff' }; default { 'launch-codex-specialist' } }
                    Copy-Item (Join-Path $source ($script + '.ps1')) $root
                    $config = [IO.File]::ReadAllText((Join-Path $lib 'config-helpers.ps1'))
                    if ($case.Name -eq 'agents') {
                        $config += "`nfunction Get-ClaudeLevel { throw 'CONFIG_FAILURE: model level' }`n"
                    } elseif ($case.Name -ne 'launcher-bundle') {
                        $config += "`nfunction Get-ConfiguredPath { throw 'CONFIG_FAILURE: session path' }`n"
                    }
                    Write-FixtureText (Join-Path $lib 'config-helpers.ps1') $config
                    Write-FixtureText (Join-Path $root 'crucible-lib.ps1') ". (Join-Path `$PSScriptRoot 'lib/config-helpers.ps1')"
                    if ($case.Name -eq 'validator-config') { $setup = "`$env:ITEM261_CONFIG = 'fixture'" }
                    if ($case.Name -eq 'handoff-config') {
                        Write-FixtureText (Join-Path $root 'handoff.json') '{"generated_by":"new-handoff.ps1","tool_version":"1.0.0"}'
                        Write-FixtureText (Join-Path $root 'schema.json') '{}'
                    }
                    $extra = switch ($case.Name) {
                        'health' { '-ProjectRoot $PSScriptRoot -Health' }
                        'agents' { '-ProjectRoot $PSScriptRoot' }
                        'launcher-bundle' { "-ProjectRoot `$PSScriptRoot -CrucibleRoot ''" }
                        'validator-config' { '-ConfigPath Env:ITEM261_CONFIG' }
                        'handoff-config' { '-HandoffFile ./handoff.json -SchemaPath ./schema.json' }
                        default { '' }
                    }
                    $call = "& './$script.ps1' $extra"
                }
                'remaining-agent-caller' {
                    $script = if ($case.Name -eq 'init') { 'init-project.ps1' } else { 'update-bundle.ps1' }
                    $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $source $script), [ref]$null, [ref]$null)
                    $node = $ast.Find({ param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.Extent.Text.StartsWith('& $agentSync') }, $true)
                    if ($case.Name -eq 'init') {
                        while ($node -isnot [Management.Automation.Language.IfStatementAst] -or $node.Extent.Text -notmatch '^if \(Test-Path') { $node = $node.Parent }
                        $body = $ast.EndBlock.Traps[0].Extent.Text + "`n" + $node.Extent.Text
                    } else {
                        while ($node -isnot [Management.Automation.Language.TryStatementAst]) { $node = $node.Parent }
                        $body = $node.Extent.Text
                    }
                    Write-FixtureText (Join-Path $root 'boundary.ps1') $body
                    Write-FixtureText (Join-Path $root 'powershell/lib/claude-agents.ps1') 'function Get-ClaudeAgentDrift { @() }'
                    Write-FixtureText (Join-Path $root 'sync-claude-agents.ps1') @'
param($ProjectRoot)
if ($scenario -eq 'failure') { exit 7 }
'@
                    $setup = @'
Set-StrictMode -Version Latest
$agentSync = Join-Path $PSScriptRoot 'sync-claude-agents.ps1'
$adopterCrucibleRoot = $PSScriptRoot
$adopterRootResolved = $PSScriptRoot
$resolvedProjectRoot = $PSScriptRoot
$Quiet = $false
$scenario = 'success'
$global:LASTEXITCODE = 7
& './boundary.ps1'
if ($LASTEXITCODE -ne 0) { throw 'SUCCESS_STATUS_STALE' }
Write-Host 'CALLER_SUCCESS'
$scenario = 'failure'
'@
                    $call = "& './boundary.ps1'"
                    if ($case.Name -eq 'update') { $call += "; `$global:LASTEXITCODE = 0" }
                }
                'handoff' {
                    Copy-Item -LiteralPath (Join-Path $source 'new-handoff.ps1') -Destination $root
                    Write-FixtureText (Join-Path $lib 'project-root.ps1') 'function Resolve-CrucibleProjectRoot { param($ProjectRoot) $ProjectRoot }'
                    Write-FixtureText (Join-Path $root 'crucible-lib.ps1') @'
function Get-ConfiguredPath { param($Key) Join-Path $REPO_ROOT $Key }
function Get-RunningPowerShellCommand { (Get-Process -Id $PID).Path }
function Test-BacklogTaskRow { $true }
function Resolve-FilesystemPath { param($Path) $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path) }
function Sort-HandoffFiles { param($Files) $Files }
function Get-SpecBudgetTier { '' }
function Get-ConfiguredPrimaryBranch { 'main' }
function Resolve-ImplementationWorktreePath { Join-Path $REPO_ROOT 'worktree' }
function Normalize-HandoffArtifactPaths { param($Artifacts) $Artifacts }
function Get-BacklogItemPathForTaskProjectRoot { Join-Path $REPO_ROOT 'spec.md' }
function Get-SpecFrontmatterAffinity { 'src/' }
function Get-AffinityWidening { if ($scenario -eq 'scope') { 'outside/' } else { @() } }
function ConvertTo-AsciiSafeText { param($Text) $Text }
function Get-UtcFileTimestamp { 'fixture' }
function Get-UtcTimestamp { 'fixture' }
function git {
    $global:LASTEXITCODE = 0
    $argsText = $args -join ' '
    if ($argsText -match 'merge-base') {
        if ($scenario -eq 'rebaseline-ancestor') { $global:LASTEXITCODE = 1 }
    } elseif ($argsText -match 'show-ref|rev-parse main') {
        $global:LASTEXITCODE = 7
    } elseif ($scenario -in @('commit', 'rebaseline-commit')) {
        $global:LASTEXITCODE = 1
    } else { 'new-base' }
}
'@
                    Write-FixtureText (Join-Path $root 'backlog/BACKLOG.md') '| F-261 | Ready |'
                    Write-FixtureText (Join-Path $root 'spec.md') 'fixture'
                    Write-FixtureText (Join-Path $root '.git') 'fixture marker'
                    Write-FixtureText (Join-Path $root 'validate-handoff.ps1') @'
param($HandoffFile, $SchemaPath)
if ($env:CRUCIBLE_REFUSAL_SCENARIO -eq 'validator-exit') { 'INVALID_HANDOFF'; exit 7 }
exit 0
'@
                    $extra = switch ($case.Name) {
                        'backlog-dir' { Remove-Item (Join-Path $root 'backlog') -Recurse -Force }
                        'backlog-file' { Remove-Item (Join-Path $root 'backlog/BACKLOG.md') -Force }
                        'validator-missing' { Remove-Item (Join-Path $root 'validate-handoff.ps1') -Force }
                        'commit' { '-CommitHash invalid' }
                        'suspicious' { '-SuspiciousContent none' }
                        'artifacts' { '-Artifacts "''quoted''"' }
                        'affinity' { '-FileAffinity "''quoted''"' }
                        default { '' }
                    }
                    if ($case.Name.StartsWith('rebaseline-')) {
                        $oldBase = if ($case.Name -eq 'rebaseline-same') { 'new-base' } else { 'old-base' }
                        if ($case.Name -ne 'rebaseline-empty') {
                            Write-FixtureText (Join-Path $root 'session/handoffs/F-261-old.json') ('{"source_phase":"deployment","target_phase":"done","base_commit":"' + $oldBase + '","cumulative_handoff_count":3}')
                        }
                        $extra = '-Rebaseline -BaseCommit fixture'
                        if ($case.Name -eq 'rebaseline-extra') { $extra += ' -Artifacts extra' }
                        if ($case.Name -eq 'rebaseline-base') { $extra = '-Rebaseline' }
                        if ($case.Name -eq 'rebaseline-collision') { Write-FixtureText (Join-Path $root 'output.json') 'existing' }
                    } else {
                        $extra = '-Source grooming -Target implementation -Reason fixture ' + $extra
                    }
                    $setup = "`$scenario = '$($case.Name)'`n`$env:CRUCIBLE_REFUSAL_SCENARIO = '$($case.Name)'"
                    $call = "& './new-handoff.ps1' -TaskId F-261 -ProjectRoot `$PSScriptRoot -OutputPath './output.json' $extra"
                }
                'archive' {
                    Copy-TestRunnerLibraries -Destination $lib
                    Copy-Item -LiteralPath (Join-Path $source 'archive-task.ps1') -Destination $root
                    Write-FixtureText (Join-Path $root 'backlog/features/active/F-261.md') "---`nitem_id: F-261`ntype: feature`nstatus: Ready`npriority: P1`n---`n"
                    Write-FixtureText (Join-Path $root 'backlog/BACKLOG.md') "| ID | Status |`n|---|---|`n| [F-261](features/active/F-261.md) | Ready |`n"
                    switch ($case.Name) {
                        'helper' { Remove-Item (Join-Path $lib 'archive-task.ps1') -Force }
                        'frontmatter' { Write-FixtureText (Join-Path $root 'backlog/features/active/F-261.md') 'no frontmatter' }
                        'row' { Write-FixtureText (Join-Path $root 'backlog/BACKLOG.md') 'no row' }
                        'collision' { Write-FixtureText (Join-Path $root 'backlog/features/archived/F-261.md') 'existing' }
                        'rollback' {
                            # Keep the real archive and rollback, injecting only its final write failure.
                            $archiveLib = Join-Path $lib 'archive-task.ps1'
                            Write-FixtureText $archiveLib ([IO.File]::ReadAllText($archiveLib) + "`nfunction Update-BacklogPrioritySummary { throw 'ARCHIVE_SUMMARY_FAILURE' }`n")
                        }
                    }
                    $call = "& './archive-task.ps1' -BacklogPath './backlog/BACKLOG.md' -SpecPath './backlog/features/active/F-261.md'"
                    if ($case.Name -ne 'terminal') { $call += ' -Status Resolved' }
                }
                'handoff-caller' {
                    Copy-TestRunnerLibraries -Destination $lib
                    Write-FixtureText (Join-Path $root 'new-handoff.ps1') @'
# No success exit deliberately: exercise the caller's reset under StrictMode.
if ($handoffExit -ne 0) { [Console]::Error.WriteLine('HANDOFF_FAILURE'); exit $handoffExit }
'@
                    Write-FixtureText (Join-Path $root 'backlog/BACKLOG.md') '| F-261 | Ready |'
                    Write-FixtureText (Join-Path $root 'F-261-decision.json') '{}'
                    $setup = @'
Set-StrictMode -Version Latest
. './lib/crucible-gates.ps1'
function Write-BlockedTaskRecord { throw 'UNEXPECTED_BLOCKED_WRITER' }
function Write-Quiet {}
function Write-EventLog {}
function Test-GitDiscardSafe { $true }
function Invoke-GitChecked {
    param($Command)
    $global:LASTEXITCODE = if ($Command.ToString() -match 'merge --no-ff|show-ref') { 1 } else { 0 }
}
function Invoke-Git { [pscustomobject]@{ ExitCode = 1; Lines = @() } }
function Get-ConfiguredPath { param($Key) Join-Path $PSScriptRoot $Key }
function Resolve-ImplementationWorktreePath { Join-Path $PSScriptRoot 'worktree' }
function Resolve-ConfigProjectRoot { $PSScriptRoot }
function Get-HumanGateRejectUnwind { @{ CurrentHead = 'head'; ParentList = @(); HeadIsTaskMerge = $false; UnwindTarget = '' } }
function Assert-HumanGateReworkAvailable {}
function Restore-BacklogTask {}
function Restore-ImplementationWorktree {}
function Test-BacklogTaskRow { $true }
function Get-ConfiguredPrimaryBranch { 'main' }
$handoffExit = 7
'@
                    # Success and failure share the unchanged production caller. Success runs
                    # first under StrictMode, with stale status 7 supplied by the fixture.
                    $invoke = switch ($case.Name) {
                        'research-runner' {
                            $generatorAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $source 'new-handoff.ps1'), [ref]$null, [ref]$null)
                            Write-FixtureText (Join-Path $root '.crucible/powershell/new-handoff.ps1') ($generatorAst.ParamBlock.Extent.Text + "`n" + [IO.File]::ReadAllText((Join-Path $root 'new-handoff.ps1')))
                            Write-FixtureText (Join-Path $root '.crucible/config.yaml') "project: fixture`n"
                            New-Item -ItemType Directory -Path (Join-Path $root '.crucible/session/F-261/research') -Force | Out-Null
                            $recordScript = (Join-Path $source 'record-research-gate.ps1').Replace("'", "''")
                            $setup += "`n& '$recordScript' -TaskId F-261 -Reason fixture -Approved B-261 -ProjectRoot `$PSScriptRoot"
                            "& './.crucible/session/F-261/research/gate-handoff.ps1'"
                        }
                        'merge' { "Invoke-HumanGateMerge -TaskId F-261 -PrimaryBranch main -ProjectRoot `$PSScriptRoot -LogFile unused -CircuitBreakerHistoryFile unused -DecisionRecordPath './F-261-decision.json'" }
                        'reject' { "Invoke-HumanGateRejectAbandon -TaskId F-261 -Outcome rejected -PrimaryBranch main -ProjectRoot `$PSScriptRoot" }
                        'cli' {
                            Copy-Item (Join-Path $source 'crucible.ps1') $root
                            Write-FixtureText (Join-Path $root 'crucible-lib.ps1') ''
                            Write-FixtureText (Join-Path $lib 'config-helpers.ps1') 'function Get-ConfiguredCrucibleRootValue { "" }'
                            Write-FixtureText (Join-Path $lib 'project-root.ps1') 'function Resolve-CrucibleProjectRoot { param($ProjectRoot) $ProjectRoot }'
                            "& './crucible.ps1' -NewHandoff -TaskId F-261 -HandoffSource grooming -HandoffTarget implementation -HandoffReason fixture -ProjectRoot `$PSScriptRoot -Quiet"
                        }
                    }
                    $call = @"
`$handoffExit = 0
`$global:LASTEXITCODE = 7
$invoke
$(if ($case.Name -in @('cli', 'research-runner')) { "if (`$LASTEXITCODE -ne 0) { throw 'SUCCESS_STATUS_STALE' }" })
Write-Host 'CALLER_SUCCESS'
Set-Content -LiteralPath './F-261-decision.json' -Value '{}'
`$handoffExit = 7
$invoke
"@
                }
                'archive-gate' {
                    Copy-TestRunnerLibraries -Destination $lib
                    Write-FixtureText (Join-Path $root 'active/F-261.md') 'no frontmatter'
                    Write-FixtureText (Join-Path $root 'global/gate_decisions/F-261-fixture.json') '{"outcome":"accepted"}'
                    $setup = @'
. './lib/crucible-gates.ps1'
. './lib/archive-task.ps1'
function Write-Quiet {}
function Get-ConfiguredPrimaryBranch { 'main' }
function Resolve-ConfigProjectRoot { $PSScriptRoot }
function Get-ConfiguredPath { $PSScriptRoot }
function Get-BacklogItemPathForTaskProjectRoot { Join-Path $PSScriptRoot 'active/F-261.md' }
function Test-DeploymentReworkReentry { $false }
function Get-PipelineValidTransitions { @{ grooming = @('done') } }
function Get-TaskFinalizationDetails { @{ IsFinalized = $false } }
function Invoke-BacklogTaskArchive { throw 'ARCHIVE_FAILURE' }
function Test-GitDiscardSafe { $true }
function Invoke-GitChecked {}
function Get-HumanGateRejectUnwind { @{ CurrentHead = 'head'; ParentList = @(); HeadIsTaskMerge = $false; UnwindTarget = '' } }
function Assert-HumanGateReworkAvailable {}
function Restore-BacklogTask { Set-BacklogSpecFrontmatterStatus -Path './active/F-261.md' -Status 'In Progress' }
function Invoke-AbandonedBacklogTaskArchive { Set-BacklogSpecFrontmatterStatus -Path './active/F-261.md' -Status Abandoned }
function Invoke-HumanGateBacklogFinalization { $false }
function Write-EventLog {}
function git { $global:LASTEXITCODE = 1 }
$context = @{
    Handoff = [pscustomobject]@{ task_id = 'F-261'; source_phase = 'grooming'; target_phase = 'done' }
    IsBootstrap = $false; SessionDir = $PSScriptRoot; HandoffDir = ''; FrameworkPowerShell = $PSScriptRoot
    NextCrucibleCommand = ''; Quiet = $true; LogFile = 'unused'; CircuitBreakerHistoryFile = 'unused'; RepoRoot = $PSScriptRoot
}
'@
                    $call = if ($case.Name -eq 'completion') { 'Resolve-CrucibleTransition -Context $context' } elseif ($case.Name -eq 'accept') {
                        'Invoke-HumanGateAcceptRedirect -TaskId F-261 -Outcome accepted -SourcePhase grooming -PrimaryBranch main -ProjectRoot $PSScriptRoot -LogFile unused -CircuitBreakerHistoryFile unused'
                    } else {
                        $outcome = if ($case.Name -eq 'restore') { 'rejected' } else { 'abandoned' }
                        "Invoke-HumanGateRejectAbandon -TaskId F-261 -Outcome $outcome -PrimaryBranch main -ProjectRoot `$PSScriptRoot"
                    }
                }
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
                        'blocked' { 'Write-BlockedTaskRecord -ProjectRoot $PSScriptRoot -TaskId F-261 -CircuitBreaker fixture -AttemptCount 1 -LastPhase implementation -Summary fixture -BacklogDir (Join-Path $PSScriptRoot "backlog") -FrameworkPowerShell $PSScriptRoot' }
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
function Get-RunningPowerShellCommand { (Get-Process -Id $PID).Path }
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
            $isCommand = $case.Kind -in @('bootstrap', 'entry', 'research', 'runner', 'init', 'hooks', 'state', 'handoff', 'archive', 'remaining-command', 'remaining-caller', 'remaining-config', 'remaining-agent-caller') -or ($case.Kind -eq 'handoff-caller' -and $case.Name -in @('cli', 'research-runner'))
            if ($case.Kind -eq 'remaining-library' -and $case.Name -in @('Resolve-CrucibleInputHandoff', 'Restore-MisplacedHandoff', 'Read-CrucibleHandoffContext')) { $isCommand = $true }
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
            $advisory = ($case.Kind -eq 'state-caller' -and $case.Name -in @('human', 'blocked')) -or ($case.Kind -eq 'remaining-agent-caller' -and $case.Name -eq 'update')
            if ($advisory) {
                Assert-Result 'advisory caller continues' ($res.ExitCode -eq 0 -and $res.Output -match 'CALLER_CONTINUED') $evidence
                Assert-Result 'advisory failure is reported' ($res.Output -match $case.Expected) $evidence
                if ($case.Kind -eq 'remaining-agent-caller') {
                    Assert-Result 'advisory caller success works under StrictMode' ($res.Output -match 'CALLER_SUCCESS') $evidence
                }
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
            if ($case.Kind -in @('handoff-caller', 'remaining-caller', 'remaining-restore', 'remaining-agent-caller')) {
                Assert-Result 'caller success works under StrictMode' ($res.Output -match 'CALLER_SUCCESS') $evidence
            }
            if ($case.Kind -eq 'remaining-restore') {
                Assert-Result 'restore retains validator row diagnostic' ($diagnostic -match 'ROW_F261_INVALID') $evidence
                Assert-Result 'failed validation prevents rework handoff' ($res.Output -notmatch 'NEW_HANDOFF_AFTER_FAILURE') $evidence
            }
            if ($case.Kind -eq 'remaining-caller' -and $case.Name -in @('affinity', 'dev-log', 'preflight-validator')) {
                Assert-Result 'crash produces no finding or breaker event' ($res.Output -notmatch 'EVENT_AFTER_FAILURE|File affinity overlap detected|PII/secrets') $evidence
                Assert-Result 'caller names internal crash on stderr' ($diagnostic -match '(check-file-affinity|validate-dev-log|validate-handoff)\.ps1 crashed or failed internally') $evidence
                Assert-Result 'crash has distinct exit code' ($res.ExitCode -eq 2) $evidence
            }
            if ($case.Kind -eq 'remaining-command' -and $case.Name -eq 'dev-log') {
                Write-FixtureText (Join-Path $root 'publish.md') 'A public release note.'
                Write-FixtureText $child @'
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$global:LASTEXITCODE = 7
& (Join-Path $PSScriptRoot 'validate-dev-log.ps1') -FileToPublish (Join-Path $PSScriptRoot 'publish.md')
exit $LASTEXITCODE
'@
                $success = Invoke-ExternalCommand { & $pwshCmd -NoProfile -File $child 2>$stderr }
                Assert-Result 'dev log success clears stale status under StrictMode' ($success.ExitCode -eq 0) ($success.Output + [IO.File]::ReadAllText($stderr))
            }
            if ($case.Kind -eq 'handoff' -and $case.Name -in @('validator-missing', 'validator-exit')) {
                Assert-Result 'failed validation removes temporary output' (-not (Test-Path (Join-Path $root 'output.json.tmp'))) $evidence
            }
            if ($case.Kind -eq 'archive' -and $case.Name -eq 'rollback') {
                Assert-Result 'rollback restores active spec and row' (([IO.File]::ReadAllText((Join-Path $root 'backlog/features/active/F-261.md')) -match 'status: Ready') -and ([IO.File]::ReadAllText((Join-Path $root 'backlog/BACKLOG.md')) -match '/active/') -and -not (Test-Path (Join-Path $root 'backlog/features/archived/F-261.md'))) $evidence
            }
            if ($case.Kind -eq 'handoff' -and $case.Name -eq 'validator-exit') {
                # Both command success paths must reset status, even when a native
                # probe or embedding caller left a nonzero value under StrictMode.
                foreach ($mode in @('transition', 'rebaseline')) {
                    if ($mode -eq 'rebaseline') {
                        Write-FixtureText (Join-Path $root 'session/handoffs/F-261-old.json') '{"source_phase":"deployment","target_phase":"done","base_commit":"old-base","cumulative_handoff_count":3}'
                        Remove-Item (Join-Path $root 'output.json') -Force
                    }
                    $successCall = if ($mode -eq 'transition') {
                        "& './new-handoff.ps1' -TaskId F-261 -Source grooming -Target implementation -Reason fixture -ProjectRoot `$PSScriptRoot -OutputPath './output.json'"
                    } else {
                        "& './new-handoff.ps1' -TaskId F-261 -Rebaseline -BaseCommit fixture -ProjectRoot `$PSScriptRoot -OutputPath './output.json'"
                    }
                    Write-FixtureText $child @"
`$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Set-Location `$PSScriptRoot
`$scenario = 'success'
`$env:CRUCIBLE_REFUSAL_SCENARIO = 'success'
`$global:LASTEXITCODE = 7
$successCall
exit `$LASTEXITCODE
"@
                    $success = Invoke-ExternalCommand { & $pwshCmd -NoProfile -File $child 2>$stderr }
                    Assert-Result "$mode succeeds under StrictMode" ($success.ExitCode -eq 0) ($success.Output + [IO.File]::ReadAllText($stderr))
                }
            }
            if ($case.Kind -eq 'archive' -and $case.Name -eq 'terminal') {
                Write-FixtureText $child @'
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Set-Location $PSScriptRoot
$global:LASTEXITCODE = 7
& './archive-task.ps1' -BacklogPath './backlog/BACKLOG.md' -SpecPath './backlog/features/active/F-261.md' -Status Resolved
exit $LASTEXITCODE
'@
                $success = Invoke-ExternalCommand { & $pwshCmd -NoProfile -File $child 2>$stderr }
                Assert-Result 'archive succeeds under StrictMode with stale status' ($success.ExitCode -eq 0) ($success.Output + [IO.File]::ReadAllText($stderr))
            }
            if ($case.Kind -eq 'state' -and $case.Name -eq 'update') {
                Assert-Result 'failed update releases its lock' (-not (Test-Path -LiteralPath (Join-Path $root 'session/global/session_state.lock'))) $evidence
            }
        }
    }
} finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force
}
Write-TestFileSummary -Results $results
