# Cross-review regressions for item 284. Extract only declarations/expressions from the
# launcher: never invoke an agent CLI. Commands run against inert copies of real params.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$REPO_ROOT = (Resolve-Path "$PSScriptRoot/../..").Path
$sourceRoot = $REPO_ROOT
. (Join-Path $PSScriptRoot '_harness.ps1')
. (Join-Path $sourceRoot 'powershell/lib/platform.ps1')
. (Join-Path $sourceRoot 'powershell/lib/crucible-command.ps1')
. (Join-Path $sourceRoot 'powershell/lib/codex-launch-outcome.ps1')
$results = @()
$utf8 = [Text.UTF8Encoding]::new($false)
$tempRoot = New-TestFixtureRoot -NameHint 'item284 review'

function Read-ReviewAst {
    param([string]$RelativePath)
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $sourceRoot $RelativePath), [ref]$tokens, [ref]$errors)
    if ($errors.Count -gt 0) { throw ($errors | Out-String) }
    return $ast
}

function Get-ReviewAssignment {
    param($Ast, [string]$Name)
    $matches = @($Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -ceq ('$' + $Name) }, $true))
    if ($matches.Count -ne 1) { throw "Expected one assignment to $Name, found $($matches.Count)" }
    return $matches[0]
}

try {
    $launcher = Read-ReviewAst 'powershell/launch-codex-specialist.ps1'
    $session = Read-ReviewAst 'powershell/lib/session-output.ps1'
    $bootstrap = @($launcher.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'New-BootstrapPrompt' }, $true))
    if ($bootstrap.Count -ne 1) { throw 'Missing bootstrap prompt function' }
    . ([scriptblock]::Create($bootstrap[0].Extent.Text))
    $captureRoot = Join-Path $tempRoot 'bundle with spaces'
    $null = New-Item -ItemType Directory -Path (Join-Path $captureRoot 'powershell') -Force
    foreach ($script in @('crucible.ps1', 'run-isolated-checks.ps1', 'check-merge-conflicts.ps1')) {
        $ast = Read-ReviewAst ('powershell/' + $script)
        $body = $ast.ParamBlock.Extent.Text + "`nWrite-Output ('task=' + `$TaskId)`nWrite-Output ('root=' + `$ProjectRoot)`nWrite-Output ('host7plus=' + (`$PSVersionTable.PSVersion.Major -ge 7))`n"
        [IO.File]::WriteAllText((Join-Path $captureRoot ('powershell/' + $script)), $body, $utf8)
    }
    $TaskId = 'F-284'
    $handoff = [pscustomobject]@{ task_id = $TaskId }
    $REPO_ROOT = Join-Path $tempRoot "project O'Brien"
    $crucibleDir = $captureRoot
    $resolvedCrucibleRoot = $captureRoot
    $pwshCmd = Get-PwshCommand
    $sites = [ordered]@{
        'Codex handoff' = Get-ReviewAssignment $launcher 'advanceCommand'
        'ADVANCE_INCOMPLETE recovery' = Get-ReviewAssignment $launcher 'recoveryCommand'
        'task.md isolated checks' = Get-ReviewAssignment $session 'isolatedChecksCommand'
        'task.md merge simulation' = Get-ReviewAssignment $session 'mergeSimulationCommand'
    }
    $legacy = if (Test-PlatformIsWindows) { Get-Command powershell.exe -ErrorAction SilentlyContinue } else { $null }
    $launcherCases = @{ WindowsPowerShell = 0 }
    $siteIndex = 0
    foreach ($siteName in $sites.Keys) {
        $siteIndex++
        $results += Run-Test -Name ($siteName + ' runs under Bash and pwsh') -Body {
            $REPO_ROOT = Join-Path $tempRoot @("project O'Brien", 'recovery$HOME', 'cash$HOME', 'back`tick')[$siteIndex - 1]
            $line = & ([scriptblock]::Create($sites[$siteName].Right.Extent.Text))
            if ($siteName -eq 'Codex handoff') {
                $prompt = New-BootstrapPrompt -RoleLabel Architect -TaskIdValue $TaskId -PromptPath 'prompt.md' -AdvanceCommand $line -RequireJsonVerdict $false
                $promptLines = @($prompt -split "`r?`n")
                $marker = [array]::IndexOf($promptLines, 'After writing handoff JSON, run:')
                if ($marker -lt 0) { throw 'Missing Codex handoff instruction' }
                $line = $promptLines[$marker + 1].Trim()
            } elseif ($siteName -eq 'ADVANCE_INCOMPLETE recovery') {
                $now = [datetime]::UtcNow
                $outcome = Get-CodexLaunchOutcome -Evidence @{
                    ExitCode = 0; Output = ''; LastMessage = ''; UseSchema = $false; Adhoc = $false
                    Phase = 'verification'; SinceUtc = $now.AddMinutes(-1)
                    LogEvents = @([pscustomobject]@{ Event = 'session_end'; Phase = 'verification'; Outcome = 'success'; Notes = 'Handoff to deployment'; TimestampUtc = $now })
                    TranscriptPath = 'transcript.txt'; LastMessagePath = 'last-message.txt'
                    RecoveryCommand = $line; InvokeError = ''; ReadErrors = @{}
                }
                Assert-Result 'actual incomplete-advance outcome supplies recovery advice' ($outcome.Status -ceq 'ADVANCE_INCOMPLETE') ($outcome | Out-String)
                $line = $outcome.Advice[-1].Trim()
            } else {
                # Render the actual checklist hashtable, then extract its executable line.
                $isolatedChecksCommand = $line; $mergeSimulationCommand = $line
                $lists = & ([scriptblock]::Create((Get-ReviewAssignment $session 'taskLists').Right.Extent.Text))
                $phase = if ($siteName -eq 'task.md isolated checks') { 'verification' } else { 'deployment' }
                $prefix = if ($phase -eq 'verification') { '- [ ] Run isolated checks: ' } else { '- [ ] Run merge simulation: ' }
                $line = @($lists[$phase] -split "`n" | Where-Object { $_.StartsWith($prefix) })[0].Substring($prefix.Length)
            }
            $bashDriver = Join-Path $tempRoot ("site-$siteIndex.sh")
            $psDriver = Join-Path $tempRoot ("site-$siteIndex.ps1")
            [IO.File]::WriteAllText($bashDriver, ($line + "`n"), $utf8)
            [IO.File]::WriteAllText($psDriver, ($line + "`n"), $utf8)
            $bash = Get-TestBash
            $bashRun = Invoke-ExternalCommand { & $bash $bashDriver }
            $psRun = Invoke-ExternalCommand { & (Get-PwshCommand) -NoProfile -File $psDriver }
            if ($null -ne $legacy) {
                $legacyRun = Invoke-ExternalCommand { & $legacy.Source -NoProfile -ExecutionPolicy Bypass -File $psDriver }
            }
            $expected = "task=$TaskId`nroot=$REPO_ROOT`nhost7plus=True"
            Assert-Result 'Bash runs the printed command and preserves binding' ($bashRun.ExitCode -eq 0 -and ($bashRun.Output.Trim() -replace "`r`n", "`n") -ceq $expected) ($line + ' => ' + $bashRun.Output)
            Assert-Result 'pwsh runs the printed command and preserves binding' ($psRun.ExitCode -eq 0 -and ($psRun.Output.Trim() -replace "`r`n", "`n") -ceq $expected) ($line + ' => ' + $psRun.Output)
            if ($null -ne $legacy) {
                Assert-Result 'a Windows PowerShell agent shell starts a PowerShell 7 runtime' ($legacyRun.ExitCode -eq 0 -and ($legacyRun.Output.Trim() -replace "`r`n", "`n") -ceq $expected) ($line + ' => ' + $legacyRun.Output)
                $launcherCases.WindowsPowerShell++
            }
            Assert-Result 'command selects pwsh rather than the agent shell host' ($line.StartsWith('pwsh ') -and $line.Contains(' -File ')) $line
        }
    }

    $results += Run-Test -Name 'Windows PowerShell launcher coverage matches the platform' -Body {
        $expectedCases = if (Test-PlatformIsWindows) { $sites.Count } else { 0 }
        $probeResult = if ($null -eq $legacy) { 'not found ($null)' } else { $legacy.Source }
        Assert-Result 'every Windows launcher case executes on Windows only' ($launcherCases.WindowsPowerShell -eq $expectedCases) ("Expected $expectedCases Windows PowerShell launcher cases, executed $($launcherCases.WindowsPowerShell); powershell.exe probe: $probeResult")
        if (-not (Test-PlatformIsWindows)) {
            Skip-Test -Reason 'Windows PowerShell launcher checks require Windows; the powershell.exe probe is disabled on this platform.'
        }
    }

    # Keep each shell/value pair in its own Run-Test so the old refusal fails every
    # binding assertion by name. Base64 reports the actual UTF-8 parameter bytes.
    $captureAst = Read-ReviewAst 'powershell/crucible.ps1'
    [IO.File]::WriteAllText((Join-Path $captureRoot 'powershell/capture.ps1'), ($captureAst.ParamBlock.Extent.Text + "`n[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(`$ProjectRoot))`n"), $utf8)
    $backslashValues = @("O'Brien\", "O'Brien\\", "O'Brien\\\", "path\O'Brien\", ("O" + [char]0x2019 + 'Brien\'))
    $shells = @('Bash', 'pwsh', 'Windows PowerShell')
    $backslashCases = @{ WindowsPowerShell = 0 }
    $valueIndex = 0
    foreach ($value in $backslashValues) {
        $valueIndex++
        foreach ($shell in $shells) {
            $results += Run-Test -Name ("Shell-neutral trailing backslash value $valueIndex binds under $shell") -Body {
                if ($shell -eq 'Windows PowerShell') {
                    if (-not (Test-PlatformIsWindows)) {
                        Skip-Test -Reason 'Windows PowerShell trailing-backslash checks require Windows; the powershell.exe probe is disabled on this platform.'
                    }
                    Assert-Result 'Windows PowerShell trailing-backslash launcher is available' ($null -ne $legacy) 'powershell.exe probe: not found ($null)'
                }
                $line = New-CrucibleCommand -Script 'powershell/capture.ps1' -BundleRoot $captureRoot -CrucibleRoot $captureRoot -Parameters ([ordered]@{ ProjectRoot = $value }) -Transport ShellNeutral
                $driver = Join-Path $tempRoot ('trailing-backslash-' + $valueIndex + $(if ($shell -eq 'Bash') { '.sh' } else { '.ps1' }))
                [IO.File]::WriteAllText($driver, ($line + "`n"), $utf8)
                $run = switch ($shell) {
                    'Bash' { Invoke-ExternalCommand { & (Get-TestBash) $driver } }
                    'pwsh' { Invoke-ExternalCommand { & (Get-PwshCommand) -NoProfile -File $driver } }
                    # A prompt has no file encoding. EncodedCommand preserves the
                    # typographic apostrophe without a BOM in the driver file.
                    default {
                        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($line))
                        Invoke-ExternalCommand { & $legacy.Source -NoProfile -ExecutionPolicy Bypass -EncodedCommand $encoded }
                    }
                }
                Assert-Result ("$shell delivers trailing backslash value $valueIndex byte for byte") ($run.ExitCode -eq 0 -and $run.Output.Trim() -ceq [Convert]::ToBase64String($utf8.GetBytes($value))) ($line + ' => exit ' + $run.ExitCode + ': ' + $run.Output)
                if ($shell -eq 'Windows PowerShell') { $backslashCases.WindowsPowerShell++ }
            }
        }
    }

    $results += Run-Test -Name 'Windows PowerShell trailing-backslash coverage matches the platform' -Body {
        $expectedCases = if (Test-PlatformIsWindows) { $backslashValues.Count } else { 0 }
        $probeResult = if ($null -eq $legacy) { 'not found ($null)' } else { $legacy.Source }
        Assert-Result 'every Windows trailing-backslash case executes on Windows only' ($backslashCases.WindowsPowerShell -eq $expectedCases) ("Expected $expectedCases Windows PowerShell trailing-backslash cases, executed $($backslashCases.WindowsPowerShell); powershell.exe probe: $probeResult")
        if (-not (Test-PlatformIsWindows)) {
            Skip-Test -Reason 'Windows PowerShell trailing-backslash coverage requires Windows; the powershell.exe probe is disabled on this platform.'
        }
    }

    $results += Run-Test -Name 'Shell-neutral trailing backslashes that cannot use segments refuse safely' -Body {
        $failures = @()
        $values = @("O'Brien \", " O'Brien\", "'O'Brien\", ".O'Brien\", "~O'Brien\", "@O'Brien\")
        foreach ($value in $values) {
            $line = New-CrucibleCommand -Script 'powershell/crucible.ps1' -Parameters ([ordered]@{ ProjectRoot = $value }) -CrucibleRoot $captureRoot -Transport ShellNeutral
            $message = ''
            try { $null = New-CrucibleCommand -Script 'powershell/crucible.ps1' -Parameters ([ordered]@{ ProjectRoot = $value }) -CrucibleRoot $captureRoot -Transport ShellNeutral -Strict } catch { $message = $_.Exception.Message }
            $expectedReason = if ($value -match '\s') {
                'shell-neutral -File cannot carry whitespace and a trailing backslash on older launching PowerShell hosts.'
            } else {
                'the value combines quotes with a trailing backslash and does not start with a letter, digit, underscore or slash; no shared Bash/PowerShell literal is available.'
            }
            Assert-Result ("closing-backslash refusal explains the unsupported shape: $value") ($message -ceq ('New-CrucibleCommand: ' + $expectedReason) -and $line -ceq ('# (command unavailable: ' + $expectedReason + ')')) ($line + '; strict=' + $message)
            $driver = Join-Path $tempRoot 'closing-backslash.sh'
            [IO.File]::WriteAllText($driver, ($line + "`n"), $utf8)
            $bash = Get-TestBash
            $run = Invoke-ExternalCommand { & $bash $driver }
            if (-not $line.StartsWith('# (command unavailable: ') -or -not $message.StartsWith('New-CrucibleCommand:') -or $run.ExitCode -ne 0 -or $run.Output.Trim() -ne '') {
                $failures += ($value + ' => ' + $line + '; strict=' + $message + '; Bash=' + $run.Output)
            }
        }
        Assert-Result 'all closing-backslash neighbours print a strict-capable, executable unavailable comment' ($failures.Count -eq 0) ($failures -join "`n")
        # An interior single backslash with an apostrophe needs no new refusal.
        $value = "O'Brien\child"
        $line = New-CrucibleCommand -Script 'powershell/crucible.ps1' -Parameters ([ordered]@{ TaskId = $TaskId; ProjectRoot = $value }) -CrucibleRoot $captureRoot -Transport ShellNeutral -Strict
        foreach ($extension in @('sh', 'ps1')) {
            $driver = Join-Path $tempRoot ('interior-backslash.' + $extension)
            [IO.File]::WriteAllText($driver, ($line + "`n"), $utf8)
            $run = if ($extension -eq 'sh') { Invoke-ExternalCommand { & $bash $driver } } else { Invoke-ExternalCommand { & (Get-PwshCommand) -NoProfile -File $driver } }
            Assert-Result 'interior backslash still binds in both shells' ($run.ExitCode -eq 0 -and ($run.Output.Trim() -replace "`r`n", "`n") -ceq "task=$TaskId`nroot=$value`nhost7plus=True") ($line + ' => ' + $run.Output)
        }
    }

    $results += Run-Test -Name 'Shell-neutral values and script paths retain native-passing refusals' -Body {
        # Item 290 carries a mixed value that starts bare (crucible-command.tests.ps1); one
        # that starts with a quote or a space still has no shared literal.
        foreach ($value in @('', 'say "approved"', 'C:\work dir\', "'O'Brien' `$HOME", " O'Brien \\share")) {
            $line = New-CrucibleCommand -Script 'powershell/crucible.ps1' -Parameters ([ordered]@{ ProjectRoot = $value }) -CrucibleRoot $captureRoot -Transport ShellNeutral
            Assert-Result 'unsafe native value prints unavailable note' ($line.StartsWith('# (command unavailable: ')) $line
            $reason = ''
            try { $null = New-CrucibleCommand -Script 'powershell/crucible.ps1' -Parameters ([ordered]@{ ProjectRoot = $value }) -CrucibleRoot $captureRoot -Transport ShellNeutral -Strict } catch { $reason = $_.Exception.Message }
            Assert-Result 'strict refusal throws' ($reason.StartsWith('New-CrucibleCommand:')) $reason
        }
        $line = New-CrucibleCommand -Script 'powershell/crucible.ps1' -CrucibleRoot 'bundle "quoted"' -Transport ShellNeutral
        Assert-Result 'unsafe native script path prints unavailable note' ($line.StartsWith('# (command unavailable: ')) $line
        $line = New-CrucibleCommand -Script 'powershell/crucible.ps1' -CrucibleRoot $captureRoot -Transport ShellNeutral -Invoker 'powershell.exe -File'
        Assert-Result 'shell-neutral host cannot be overridden to 5.1' ($line.StartsWith('# (command unavailable: ')) $line
    }

    $results += Run-Test -Name 'Direct commands refuse the quoted stop-parsing token' -Body {
        $line = New-CrucibleCommand -Script 'powershell/crucible.ps1' -CrucibleRoot $captureRoot -Parameters ([ordered]@{ TaskId = '--%'; ProjectRoot = 'w' })
        Assert-Result 'stop-parsing token prints unavailable note' ($line.StartsWith('# (command unavailable: ') -and $line.Contains('stop-parsing')) $line
        $message = ''
        try { $null = New-CrucibleCommand -Script 'powershell/crucible.ps1' -CrucibleRoot $captureRoot -Parameters ([ordered]@{ TaskId = '--%' }) -Strict } catch { $message = $_.Exception.Message }
        Assert-Result 'strict stop-parsing refusal throws' ($message.Contains('stop-parsing')) $message
        $line = New-CrucibleCommand -Script 'powershell/new-handoff.ps1' -CrucibleRoot $captureRoot -Parameters ([ordered]@{ HumanApproved = @('C-1', '--%') })
        Assert-Result 'array element also refuses stop-parsing' ($line.StartsWith('# (command unavailable: ') -and $line.Contains('stop-parsing')) $line
    }

    $results += Run-Test -Name 'When-to-use names the PowerShell 7+ prompt floor on all platforms' -Body {
        $doc = [IO.File]::ReadAllText((Join-Path $sourceRoot 'docs/when-to-use.md'))
        Assert-Result 'runtime and prompt floor agree' ($doc.Contains('PowerShell 7+ prompt') -and $doc.Contains('Windows, Linux and macOS') -and -not $doc.Contains('5.1 on Windows')) $doc
    }

    $results += Run-Test -Name 'Instruction-block prose describes the direct prompt' -Body {
        $doc = [IO.File]::ReadAllText((Join-Path $sourceRoot 'docs/agent-instructions.md'))
        Assert-Result 'doc describes a direct call at a PowerShell 7+ prompt' ($doc.Contains('writes a direct script invocation') -and $doc.Contains('PowerShell 7+ prompt') -and -not $doc.Contains('writes this block with `pwsh`')) $doc
    }
    $results += Run-Test -Name 'Instruction blocks do not forward a dead invoker' -Body {
        $ast = Read-ReviewAst 'powershell/lib/instruction-blocks.ps1'
        $call = Get-ReviewAssignment $ast 'initCommand'
        Assert-Result 'unused host override is not passed to the builder' (-not $call.Extent.Text.Contains('-Invoker')) $call.Extent.Text
    }
} finally {
    $resolved = [IO.Path]::GetFullPath($tempRoot)
    $allowed = [IO.Path]::GetFullPath((Get-TestRunRoot)).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    if (-not $resolved.StartsWith($allowed, [StringComparison]::OrdinalIgnoreCase)) { throw "Fixture escaped the test root: $resolved" }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
Write-TestFileSummary -Results $results
