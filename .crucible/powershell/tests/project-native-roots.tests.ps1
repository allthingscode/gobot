$ErrorActionPreference = 'Stop'
$frameworkRoot = (Resolve-Path "$PSScriptRoot/../..").Path
. (Join-Path $PSScriptRoot '_harness.ps1')
. (Join-Path $frameworkRoot 'powershell/lib/config-helpers.ps1')
. (Join-Path $frameworkRoot 'powershell/lib/project-root.ps1')
$results = @()
$root = New-TestFixtureRoot -NameHint 'project-native-roots'
$utf8 = [Text.UTF8Encoding]::new($false)
function Write-RootFixtureFile($Path, $Content) {
    New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force | Out-Null
    [IO.File]::WriteAllText($Path, $Content, $utf8)
}
try {
    $project = Join-Path $root 'project'
    $config = [IO.File]::ReadAllText((Join-Path $frameworkRoot 'templates/project/.crucible/config.yaml'))
    $config = $config.Replace('replace-with-project-quick-test-command', 'Write-Output inert').Replace('replace-with-project-full-test-command', 'Write-Output inert')
    Write-RootFixtureFile (Join-Path $project '.crucible/config.yaml') $config
    foreach ($dir in @('docs', 'prompts', 'personas', 'schemas', 'sops', 'powershell', 'backlog')) {
        New-Item -ItemType Directory -Path (Join-Path $project ".crucible/$dir") -Force | Out-Null
    }
    & git -C $project init -b main --quiet
    & git -C $project config user.name Test
    & git -C $project config user.email test@example.com
    & git -C $project config commit.gpgSign false
    & git -C $project remote add origin https://github.com/inert/project.git
    & git -C $project add .
    & git -C $project commit -m fixture --quiet
    $worktree = Join-Path $project '.crucible/.agent-workspaces/implementation-T-334'
    & git -C $project worktree add -b task/T-334 $worktree --quiet
    New-PSDrive -Name Item334 -PSProvider FileSystem -Root $root | Out-Null
    $aliasDrive = @('D'..'Z' | Where-Object { -not (Get-PSDrive $_ -ErrorAction SilentlyContinue) })[0]
    New-PSDrive -Name $aliasDrive -PSProvider FileSystem -Root $root | Out-Null
    $runner = Join-Path $root 'caller.ps1'
    Write-RootFixtureFile $runner @'
param($Framework, $Fixture, $Spelling, $Caller, $AliasDrive)
$ErrorActionPreference = 'Stop'
$global:LASTEXITCODE = 0
$env:CRUCIBLE_DEV_ROOT = ''
$env:CRUCIBLE_FRAMEWORK_DIR = ''
New-PSDrive -Name Item334 -PSProvider FileSystem -Root $Fixture | Out-Null
New-PSDrive -Name $AliasDrive -PSProvider FileSystem -Root $Fixture | Out-Null
Set-Location Item334:/
function gh {
    $global:LASTEXITCODE = 0
    if ($args[0] -eq 'auth') { return }
    if ($args[-1] -match 'actions/workflows$') { return '{"workflows":[{"id":1,"state":"active"}]}' }
    if ($args[-1] -match '/runs') { return '{"workflow_runs":[{"id":1,"status":"completed","conclusion":"success"}]}' }
    throw 'Unexpected offline gh invocation'
}
$scriptPath = Join-Path $Framework ('powershell/' + $Caller + '.ps1')
switch ($Caller) {
    'run-isolated-checks' { & $scriptPath -ProjectRoot $Spelling -TaskId T-334 -Mode quick }
    'commit-checks' {
        & (Join-Path $Framework 'powershell/run-isolated-checks.ps1') -ProjectRoot $Spelling -TaskId C-334 -Mode quick -Commit HEAD
    }
    'crucible-doctor' { & $scriptPath -ProjectRoot $Spelling }
    'crucible-health' {
        . $scriptPath -ProjectRoot $Spelling
        if ($REPO_ROOT -cne (Join-Path $Fixture 'project')) { throw "Health retained $REPO_ROOT" }
        Write-Output 'HEALTH ROOT NATIVE'
    }
    'validate-config' { & $scriptPath -ConfigPath (Join-Path $Spelling '.crucible/config.yaml') }
    'watch-adopter-ci' { & $scriptPath -CrucibleRoot $Spelling -PollSeconds 1 -NoRunsGraceMinutes 0 }
    'default-checks' {
        Set-Location Item334:/project
        & (Join-Path $Framework 'powershell/run-isolated-checks.ps1') -TaskId T-334 -Mode quick
    }
    'missing-doctor' { & (Join-Path $Framework 'powershell/crucible-doctor.ps1') -ProjectRoot Item334:/absent }
    'missing-health' { & (Join-Path $Framework 'powershell/crucible-health.ps1') -ProjectRoot Item334:/absent }
    'missing-config' { & (Join-Path $Framework 'powershell/validate-config.ps1') -ConfigPath Item334:/absent }
    'invalid-commit' {
        & (Join-Path $Framework 'powershell/watch-adopter-ci.ps1') -CrucibleRoot $Spelling -Commit invalid -Repo inert/project
    }
}
exit $LASTEXITCODE
'@
    # Local config commands must be inert, regardless of the scaffold's current toolchain.
    $checkConfig = "project:`n  default_branch: main`nverification:`n  quick:`n    - name: local marker`n      command: Write-Output 'ITEM334 CHECK RAN'`n"
    [IO.File]::WriteAllText((Join-Path $project '.crucible/config.yaml'), $checkConfig, $utf8)
    foreach ($variant in @('native', 'alias', 'letter', 'relative', 'slash', 'backslash')) {
        $results += Run-Test "Project owners return native roots: $variant" {
            if ($variant -in @('slash', 'backslash') -and -not $IsWindows) { Skip-Test 'Windows root-relative paths require a filesystem drive.' }
            Push-Location Item334:/
            try {
                $spelling = switch ($variant) { native { $project } alias { 'Item334:/project' } letter { $aliasDrive + ':/project' } relative { 'project' } slash { '/project' } backslash { '\project' } }
                Assert-Result 'existing config root' ((Resolve-ConfigProjectRoot $spelling) -ceq $project) $spelling
                Assert-Result 'always config root' ((Resolve-ConfigProjectRoot $spelling -PathResolution Always) -ceq $project) $spelling
                Assert-Result 'None preserves spelling' ((Resolve-ConfigProjectRoot $spelling -PathResolution None) -ceq $spelling) $spelling
                Assert-Result 'explicit project root' ((Resolve-CrucibleProjectRoot $spelling "$project/.crucible/powershell") -ceq $project) $spelling
                Assert-Result 'derived project root' ((Resolve-CrucibleProjectRoot '' (Join-Path $spelling '.crucible/powershell')) -ceq $project) $spelling
            } finally { Pop-Location }
        }
        foreach ($caller in @('run-isolated-checks', 'commit-checks', 'crucible-doctor', 'crucible-health', 'validate-config', 'watch-adopter-ci')) {
            $results += Run-Test "Native caller $caller root: $variant" {
                if ($variant -in @('slash', 'backslash') -and -not $IsWindows) { Skip-Test 'Windows root-relative paths require a filesystem drive.' }
                $spelling = switch ($variant) { native { $project } alias { 'Item334:/project' } letter { $aliasDrive + ':/project' } relative { 'project' } slash { '/project' } backslash { '\project' } }
                $isValidation = $caller -in @('validate-config', 'crucible-doctor')
                [IO.File]::WriteAllText((Join-Path $project '.crucible/config.yaml'), $(if ($isValidation) { $config } else { $checkConfig }), $utf8)
                $res = Invoke-ExternalCommand { & pwsh -NoProfile -NonInteractive -File $runner $frameworkRoot $root $spelling $caller $aliasDrive }
                $output = $res.Output -join "`n"
                $expected = switch ($caller) {
                    'run-isolated-checks' { 'ITEM334 CHECK RAN' }
                    'commit-checks' { 'ITEM334 CHECK RAN' }
                    'crucible-doctor' { 'Repository: ' + $project }
                    'crucible-health' { 'HEALTH ROOT NATIVE' }
                    'validate-config' { 'CONFIG VALIDATION PASSED' }
                    'watch-adopter-ci' { 'STATUS=GREEN' }
                }
                Assert-Result 'caller completed' ($res.ExitCode -eq 0 -and $output.Contains($expected)) $output
                Assert-Result 'commit worktree removed' (@(& git -C $project worktree list --porcelain | Where-Object { $_ -match 'checks-C-334' }).Count -eq 0) 'temporary worktree retained'
            }
        }
    }
    $results += Run-Test 'Default roots select the alias CWD project and keep missing spelling' {
        Push-Location Item334:/project
        try {
            $REPO_ROOT = ''
            Assert-Result 'config CWD' ((Resolve-ConfigProjectRoot) -ceq $project) 'alias retained'
            $REPO_ROOT = 'Item334:/project'
            Assert-Result 'config REPO_ROOT default' ((Resolve-ConfigProjectRoot) -ceq $project) 'alias retained'
            Assert-Result 'None REPO_ROOT default' ((Resolve-ConfigProjectRoot -PathResolution None) -ceq $REPO_ROOT) 'spelling changed'
            Assert-Result 'project CWD' ((Resolve-CrucibleProjectRoot '' (Join-Path $frameworkRoot 'powershell')) -ceq $project) 'wrong project'
            Assert-Result 'missing config spelling' ((Resolve-ConfigProjectRoot 'Item334:/absent') -ceq 'Item334:/absent') 'missing spelling changed'
        } finally { Pop-Location }
        [IO.File]::WriteAllText((Join-Path $project '.crucible/config.yaml'), $checkConfig, $utf8)
        $res = Invoke-ExternalCommand { & pwsh -NoProfile -NonInteractive -File $runner $frameworkRoot $root 'Item334:/project' default-checks $aliasDrive }
        Assert-Result 'default caller ran' ($res.ExitCode -eq 0 -and ($res.Output -join "`n") -match 'ITEM334 CHECK RAN') ($res.Output -join "`n")
    }
    foreach ($caller in @('run-isolated-checks', 'commit-checks')) {
        $results += Run-Test "Configured root-relative workspaces: $caller" {
            if (-not $IsWindows) { Skip-Test 'Windows root-relative paths require a filesystem drive.' }
            $aliasConfig = $checkConfig + "paths:`n  workspaces: /project/.crucible/.agent-workspaces`n"
            [IO.File]::WriteAllText((Join-Path $project '.crucible/config.yaml'), $aliasConfig, $utf8)
            $res = Invoke-ExternalCommand { & pwsh -NoProfile -NonInteractive -File $runner $frameworkRoot $root $project $caller $aliasDrive }
            Assert-Result 'configured worktree ran' ($res.ExitCode -eq 0 -and ($res.Output -join "`n") -match 'ITEM334 CHECK RAN') ($res.Output -join "`n")
            Assert-Result 'detached worktree removed' (@(& git -C $project worktree list --porcelain | Where-Object { $_ -match 'checks-C-334' }).Count -eq 0) 'temporary worktree retained'
        }
    }
    foreach ($refusal in @('missing-doctor', 'missing-health', 'missing-config', 'invalid-commit')) {
        $results += Run-Test "Native root caller refuses: $refusal" {
            $res = Invoke-ExternalCommand { & pwsh -NoProfile -NonInteractive -File $runner $frameworkRoot $root 'Item334:/project' $refusal $aliasDrive }
            $expectedExit = switch ($refusal) { missing-config { 2 } invalid-commit { 7 } default { 1 } }
            Assert-Result 'refusal exit' ($res.ExitCode -eq $expectedExit) ($res.Output -join "`n")
        }
    }
} finally {
    if (Get-PSDrive Item334 -ErrorAction SilentlyContinue) { Remove-PSDrive Item334 }
    if ($aliasDrive -and (Get-PSDrive $aliasDrive -ErrorAction SilentlyContinue)) { Remove-PSDrive $aliasDrive }
    if (Test-Path -LiteralPath $project) { & git -C $project worktree remove --force $worktree 2>$null }
    Remove-Item -LiteralPath $root -Recurse -Force
}
Write-TestFileSummary -Results $results
