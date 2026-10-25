$ErrorActionPreference = 'Stop'
$REPO_ROOT = (Resolve-Path "$PSScriptRoot/../..").Path
. (Join-Path $PSScriptRoot '_harness.ps1')
. (Join-Path $REPO_ROOT 'powershell/crucible-lib.ps1')
$results = @()
$tempRoot = New-TestFixtureRoot -NameHint 'handoff-root-relative'
$utf8 = [Text.UTF8Encoding]::new($false)
$project = Join-Path $tempRoot 'project'
$worktree = Join-Path $project 'workspaces/implementation-F-325'
New-Item -ItemType Directory -Path $worktree, (Join-Path $project '.crucible/backlog') -Force | Out-Null
[IO.File]::WriteAllText((Join-Path $project '.crucible/backlog/BACKLOG.md'), '| F-325 | Ready | Missing artifact |', $utf8)

$generatorText = Get-Content -LiteralPath (Join-Path $REPO_ROOT 'powershell/new-handoff.ps1') -Raw
$start = $generatorText.IndexOf('$resolvedWtPath =')
$end = $generatorText.IndexOf('$resolvedArtifacts = $normalizedArtifacts', $start)
$generatorCode = [scriptblock]::Create($generatorText.Substring($start, $end - $start))
$gatesText = Get-Content -LiteralPath (Join-Path $REPO_ROOT 'powershell/lib/crucible-gates-handoff.ps1') -Raw
$start = $gatesText.IndexOf('$normalizedArtifacts =', $gatesText.IndexOf('function Normalize-CrucibleInputState'))
$end = $gatesText.IndexOf('$originalArtifacts =', $start)
$gateCode = [scriptblock]::Create($gatesText.Substring($start, $end - $start))

try {
    $results += Run-Test 'Generator refuses an ordinary missing artifact with exit 2' {
        $outputPath = Join-Path $project 'missing-relative.json'
        $run = Invoke-ExternalCommand {
            & (Get-PwshCommand) -NoProfile -NonInteractive -File (Join-Path $REPO_ROOT 'powershell/new-handoff.ps1') -ProjectRoot $project -TaskId F-325 -Source grooming -Target implementation -Reason 'missing artifact' -Artifacts 'missing/x.md' -FileAffinity Docs/ -PromptVersion implementation_prompt-v21 -OutputPath $outputPath
        }
        $output = $run.Output -join "`n"
        Assert-Result 'missing relative artifact exits 2' ($run.ExitCode -eq 2) $output
        Assert-Result 'missing relative artifact diagnostic' ($output -match 'Artifacts entry does not exist' -and $output.Contains('[missing/x.md]')) $output
        Assert-Result 'missing relative artifact writes no handoff' (-not (Test-Path -LiteralPath $outputPath)) $outputPath
    }

    $results += Run-Test 'Generator missing-artifact diagnostic uses provider paths through a PowerShell drive' {
        $diagnosticWorktree = Join-Path $project '.crucible/.agent-workspaces/implementation-F-325'
        New-Item -ItemType Directory -Path $diagnosticWorktree -Force | Out-Null
        $generatorLiteral = (Join-Path $REPO_ROOT 'powershell/new-handoff.ps1').Replace("'", "''")
        $tempLiteral = $tempRoot.Replace("'", "''")
        $outputPath = Join-Path $project 'missing-drive.json'
        $outputLiteral = $outputPath.Replace("'", "''")
        # A child owns the drive and the generator's unconditional exit 2.
        $code = @"
`$ErrorView = 'NormalView'
New-PSDrive -Name Item325 -PSProvider FileSystem -Root '$tempLiteral' | Out-Null
& '$generatorLiteral' -ProjectRoot 'Item325:\project' -TaskId F-325 -Source grooming -Target implementation -Reason 'missing artifact' -Artifacts 'missing/x.md' -FileAffinity Docs/ -PromptVersion implementation_prompt-v21 -OutputPath '$outputLiteral'
exit `$LASTEXITCODE
"@
        $run = Invoke-ExternalCommand { & (Get-PwshCommand) -NoProfile -NonInteractive -Command $code }
        $output = $run.Output -join "`n"
        Assert-Result 'drive invocation refuses with exit 2' ($run.ExitCode -eq 2) $output
        Assert-Result 'drive invocation reports missing artifact' ($output.Contains('-Artifacts entry does not exist') -and $output.Contains('[missing/x.md]')) $output
        Assert-Result 'diagnostic names worktree disk path' ($output.Contains('implementation worktree (' + $diagnosticWorktree + ')')) $output
        Assert-Result 'diagnostic names project disk path' ($output.Contains('project root (' + $project + ')')) $output
        Assert-Result 'drive refusal writes no handoff' (-not (Test-Path -LiteralPath $outputPath)) $outputPath
    }

    foreach ($separator in @('/', '\')) {
        $artifact = $separator + 'crucible-item325-' + [guid]::NewGuid().ToString('N') + $separator + 'x.md'
        $expected = $artifact.Replace('\', '/')
        $results += Run-Test ("Missing root-relative caller parity: " + $separator) {
            if (-not $IsWindows) { Skip-Test 'Root-relative Windows artifacts require Windows.' }
            Assert-Result 'fixture is missing' (-not (Test-Path -LiteralPath $artifact)) $artifact
            $generatorResult = @(& {
                $REPO_ROOT = $project
                $wtPath = $worktree
                $resolvedArtifacts = @($artifact)
                . $generatorCode
                $normalizedArtifacts
            })
            $gateResult = @(& {
                $repoRoot = $project
                $wtPath = $worktree
                $handoff = [pscustomobject]@{ artifacts = @($artifact) }
                . $gateCode
                $normalizedArtifacts
            })
            Assert-Result 'generator preserves outside root' ($generatorResult.Count -eq 1 -and $generatorResult[0] -ceq $expected) ($generatorResult -join '|')
            Assert-Result 'gate preserves outside root' ($gateResult.Count -eq 1 -and $gateResult[0] -ceq $expected) ($gateResult -join '|')
        }

        $results += Run-Test ("Missing root-relative generator refusal exits 2: " + $separator) {
            if (-not $IsWindows) { Skip-Test 'Root-relative Windows artifacts require Windows.' }
            $outputPath = Join-Path $project 'refused.json'
            $generator = Join-Path $REPO_ROOT 'powershell/new-handoff.ps1'
            $run = Invoke-ExternalCommand {
                & (Get-PwshCommand) -NoProfile -NonInteractive -File $generator -ProjectRoot $project -TaskId F-325 -Source grooming -Target implementation -Reason 'missing artifact' -Artifacts $artifact -FileAffinity Docs/ -PromptVersion implementation_prompt-v21 -OutputPath $outputPath
            }
            $output = $run.Output -join "`n"
            Assert-Result 'generator refuses with exit 2' ($run.ExitCode -eq 2) $output
            Assert-Result 'missing-artifact diagnostic' ($output -match 'Artifacts entry does not exist' -and $output.Contains('[' + $expected + ']')) $output
            Assert-Result 'no containment exception' ($output -notmatch 'Cannot test path containment') $output
            Assert-Result 'refusal writes no handoff' (-not (Test-Path -LiteralPath $outputPath)) $outputPath
        }

        $results += Run-Test ("Missing root-relative runtime gate refusal cannot be caught: " + $separator) {
            if (-not $IsWindows) { Skip-Test 'Root-relative Windows artifacts require Windows.' }
            $libLiteral = (Join-Path $REPO_ROOT 'powershell/crucible-lib.ps1').Replace("'", "''")
            $projectLiteral = $project.Replace("'", "''")
            $handoffPath = Join-Path $project 'input.json'
            [IO.File]::WriteAllText($handoffPath, '{"task_id":"F-325","artifacts":["' + $expected + '"]}', $utf8)
            $handoffLiteral = $handoffPath.Replace("'", "''")
            $code = @"
`$ErrorActionPreference = 'Stop'
`$Quiet = `$true
. '$libLiteral'
Set-Location -LiteralPath '$projectLiteral'
`$ctx = @{
    RepoRoot = '$projectLiteral'
    WorkspacesDir = Join-Path '$projectLiteral' 'workspaces'
    SessionDir = Join-Path '$projectLiteral' '.crucible/session'
    FrameworkPowerShell = Split-Path -Parent '$libLiteral'
    LogFile = Join-Path '$projectLiteral' '$([guid]::NewGuid().ToString('N')).jsonl'
    CircuitBreakerHistoryFile = Join-Path '$projectLiteral' 'breakers.jsonl'
    Recover = `$false
    TaskId = 'F-325'
    Handoff = [pscustomobject]@{ task_id = 'F-325'; source_phase = 'grooming'; target_phase = 'implementation'; reason = 'missing artifact'; artifacts = @('$artifact'); cumulative_handoff_count = 0 }
    LatestHandoff = Get-Item -LiteralPath '$handoffLiteral'
}
try {
    Normalize-CrucibleInputState -Context `$ctx
    Invoke-CrucibleRuntimeValidation -Context `$ctx
} catch { Write-Output ('REFUSAL_CAUGHT: ' + `$_) }
Write-Output 'REFUSAL_RETURNED'
"@
            $run = Invoke-ExternalCommand { & (Get-PwshCommand) -NoProfile -NonInteractive -Command $code }
            $output = $run.Output -join "`n"
            Assert-Result 'runtime gate refuses with exit 2' ($run.ExitCode -eq 2) $output
            Assert-Result 'artifact integrity diagnostic' ($output -match 'Artifact integrity gate failed' -and $output.Contains($expected)) $output
            Assert-Result 'gate refusal cannot return or be caught' ($output -notmatch 'REFUSAL_CAUGHT|REFUSAL_RETURNED|Cannot test path containment') $output
        }

        $results += Run-Test ("Missing root-relative containment uses the PowerShell filesystem drive: " + $separator) {
            if (-not $IsWindows) { Skip-Test 'Root-relative Windows artifacts require Windows.' }
            New-PSDrive -Name Item325 -PSProvider FileSystem -Root $tempRoot | Out-Null
            Push-Location 'Item325:\'
            try {
                $inputPath = $separator + 'project' + $separator + 'workspaces' + $separator + 'implementation-F-325' + $separator + 'missing.md'
                $actual = @(Normalize-HandoffArtifactPaths -Artifacts @($inputPath) -WorktreePath $worktree -ProjectRoot $project)
                Assert-Result 'missing contained artifact uses filesystem resolution' ($actual.Count -eq 1 -and $actual[0] -ceq 'missing.md') ($actual -join '|')
                [IO.File]::WriteAllText((Join-Path $worktree 'existing.md'), 'fixture', $utf8)
                $existing = $inputPath.Replace('missing.md', 'existing.md')
                $actual = @(Normalize-HandoffArtifactPaths -Artifacts @($existing) -WorktreePath $worktree -ProjectRoot $project)
                Assert-Result 'existing root-relative artifact agrees' ($actual.Count -eq 1 -and $actual[0] -ceq 'existing.md') ($actual -join '|')
            } finally {
                Pop-Location
                Remove-PSDrive Item325
            }
        }
    }
} finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force
}
Write-TestFileSummary -Results $results
