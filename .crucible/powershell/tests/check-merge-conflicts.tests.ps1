$ErrorActionPreference = "Stop"
$REPO_ROOT = (Resolve-Path -Path "$PSScriptRoot/../..").Path
. (Join-Path $PSScriptRoot '_harness.ps1')
. (Join-Path $REPO_ROOT "powershell/lib/platform.ps1")
$CHECK_SCRIPT = Join-Path $REPO_ROOT "powershell/check-merge-conflicts.ps1"

$results = @()










function Test-GitInitMainSupported {
    $versionText = Invoke-ExternalCommand -AsLines { git --version }
    if ($versionText -notmatch '(\d+)\.(\d+)') { return $false }
    $major = [int]$matches[1]
    $minor = [int]$matches[2]
    return ($major -gt 2 -or ($major -eq 2 -and $minor -ge 28))
}

function Write-TestConfig {
    param([string]$ProjectRoot, [string]$SessionPath = ".crucible/session")
    $configDir = Join-Path $ProjectRoot ".crucible"
    New-Item -ItemType Directory -Path $configDir -Force | Out-Null
    @(
        "project: MergeConflictTest",
        "paths:",
        "  backlog: .crucible/backlog",
        "  session: $SessionPath",
        "  workspaces: .crucible/.agent-workspaces",
        "  prompts: .crucible/prompts"
    ) | Set-Content -LiteralPath (Join-Path $configDir "config.yaml") -Encoding UTF8
}

function Initialize-Repo {
    param([string]$ProjectRoot, [string]$Branch = "master", [string]$SessionPath = ".crucible/session")
    New-Item -ItemType Directory -Path $ProjectRoot -Force | Out-Null
    Push-Location $ProjectRoot
    try {
        if ($Branch -eq "main") {
            git init -b main --quiet
        } else {
            git init --quiet
        }
        git config user.name "Test"
        git config user.email "test@example.com"
        git config commit.gpgSign false
        Write-TestConfig -ProjectRoot $ProjectRoot -SessionPath $SessionPath
        Set-Content -LiteralPath "README.md" -Value "# merge test" -Encoding UTF8
        Set-Content -LiteralPath "app.txt" -Value "base" -Encoding UTF8
        git add README.md app.txt .crucible/config.yaml
        git commit -m "init" --quiet
    } finally {
        Pop-Location
    }
}

function Invoke-MergeCheck {
    param([string]$ProjectRoot, [string]$TaskId)
    Push-Location $ProjectRoot
    try {
        return Invoke-ExternalCommand {
            & (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $CHECK_SCRIPT -TaskId $TaskId -ProjectRoot $ProjectRoot
        }
    } finally {
        Pop-Location
    }
}

$tempRoot = New-TestFixtureRoot -NameHint "merge-conflicts-test"
$mainSupported = Test-GitInitMainSupported

try {
    # A successful exit alone missed alias roots falsely reported as No-Code Closure.
    # The alias must exist inside the child process that invokes the real gate.
    foreach ($primaryMode in @('unset', 'configured')) {
    foreach ($rootMode in @('native', 'explicit alias', 'explicit one-letter', 'default alias')) {
        $results += Run-Test -Name "Merge gate runs and refuses dirty work through $rootMode root ($primaryMode primary)" -Body {
            $projectRoot = Join-Path $tempRoot ($primaryMode + '-' + $rootMode.Replace(' ', '-'))
            $taskId = 'C-MERGE-ALIAS'
            Initialize-Repo -ProjectRoot $projectRoot -Branch 'main'
            if ($primaryMode -eq 'configured') {
                $configPath = Join-Path $projectRoot '.crucible/config.yaml'
                $config = [IO.File]::ReadAllText($configPath).Replace('project: MergeConflictTest', "project:`n  default_branch: main")
                [IO.File]::WriteAllText($configPath, $config, [Text.UTF8Encoding]::new($false))
                git -C $projectRoot add .crucible/config.yaml
                git -C $projectRoot commit -m 'configure primary branch' --quiet
            }
            git -C $projectRoot checkout -b "task/$taskId" --quiet
            Set-Content -LiteralPath (Join-Path $projectRoot 'feature.txt') -Value 'task change' -Encoding UTF8
            git -C $projectRoot add feature.txt
            git -C $projectRoot commit -m 'task change' --quiet
            git -C $projectRoot checkout main --quiet
            Assert-Result -Name 'fixture has no remote' -Condition (@(Invoke-ExternalCommand -AsLines { git -C $projectRoot remote }).Count -eq 0) -FailureMessage 'fixture must stay local'
            git -C $projectRoot show-ref --verify --quiet "refs/heads/task/$taskId"
            Assert-Result -Name 'task ref exists natively' -Condition ($LASTEXITCODE -eq 0) -FailureMessage 'fixture must contain the task branch'
            $headBefore = (Invoke-ExternalCommand -AsLines { git -C $projectRoot rev-parse HEAD }).Trim()
            $quotedRoot = $projectRoot.Replace("'", "''")
            $quotedScript = $CHECK_SCRIPT.Replace("'", "''")
            $quotedHarness = (Join-Path $PSScriptRoot '_harness.ps1').Replace("'", "''")
            $quotedParent = (Split-Path -Parent $projectRoot).Replace("'", "''")
            $quotedLeaf = (Split-Path -Leaf $projectRoot).Replace("'", "''")
            $rootArgument = switch ($rootMode) {
                'native' { "-ProjectRoot '$quotedRoot'" }
                'explicit alias' { "-ProjectRoot 'Rev329:\$quotedLeaf'" }
                'explicit one-letter' { "-ProjectRoot (`$letter + ':/')" }
                'default alias' { '' }
            }
            $child = @"
`$ErrorActionPreference = 'Stop'
New-PSDrive -Name Rev329 -PSProvider FileSystem -Root '$quotedParent' | Out-Null
. '$quotedHarness'
if ('$rootMode' -eq 'explicit one-letter') {
    `$letter = New-TestPSDriveLetter -Root '$quotedRoot'
    if (-not `$letter) { 'TEST-DRIVE-UNAVAILABLE'; exit 0 }
}
Set-Location -LiteralPath 'Rev329:\$quotedLeaf'
& '$quotedScript' -TaskId '$taskId' $rootArgument
exit `$LASTEXITCODE
"@
            $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($child))
            $res = Invoke-ExternalCommand { & (Get-PwshCommand) -NoProfile -NonInteractive -EncodedCommand $encoded }
            $output = $res.Output -join "`n"
            Skip-TestForPSDriveExhaustion -Output $output
            Assert-Result -Name 'actual clean simulation' -Condition ($res.ExitCode -eq 0 -and $output -match 'CLEAN MERGE SIMULATED' -and $output -notmatch 'No-Code Closure|cannot change to') -FailureMessage "expected a real merge, got exit $($res.ExitCode): $output"
            Assert-Result -Name 'head unchanged' -Condition ((Invoke-ExternalCommand -AsLines { git -C $projectRoot rev-parse HEAD }).Trim() -eq $headBefore) -FailureMessage 'simulation moved HEAD'
            git -C $projectRoot rev-parse -q --verify MERGE_HEAD *> $null
            Assert-Result -Name 'merge aborted' -Condition ($LASTEXITCODE -ne 0) -FailureMessage 'MERGE_HEAD remains'
            Assert-Result -Name 'clean tracked tree' -Condition (@(Invoke-ExternalCommand -AsLines { git -C $projectRoot status --porcelain --untracked-files=no }).Count -eq 0) -FailureMessage 'simulation changed tracked files'
            Assert-Result -Name 'task file absent' -Condition (-not (Test-Path -LiteralPath (Join-Path $projectRoot 'feature.txt'))) -FailureMessage 'task file remains'
            Set-Content -LiteralPath (Join-Path $projectRoot 'app.txt') -Value 'human edit' -Encoding UTF8
            $res = Invoke-ExternalCommand { & (Get-PwshCommand) -NoProfile -NonInteractive -EncodedCommand $encoded }
            $output = $res.Output -join "`n"
            Skip-TestForPSDriveExhaustion -Output $output
            Assert-Result -Name 'dirty refusal is exit 2' -Condition ($res.ExitCode -eq 2 -and $output -match 'uncommitted changes' -and $output -match 'app\.txt') -FailureMessage "expected refusal, got exit $($res.ExitCode): $output"
            Assert-Result -Name 'dirty edit preserved' -Condition ((Get-Content -LiteralPath (Join-Path $projectRoot 'app.txt') -Raw).Trim() -eq 'human edit') -FailureMessage 'human edit changed'
        }
    }
    }

    foreach ($failureMode in @('not a repository', 'corrupt task ref', 'malformed task ref', 'diagnostic exit 1', 'launch exception')) {
        $results += Run-Test -Name "Merge gate refuses show-ref failure: $failureMode (I11)" -Body {
            $projectRoot = Join-Path $tempRoot ($failureMode.Replace(' ', '-'))
            Initialize-Repo -ProjectRoot $projectRoot -Branch 'main'
            Assert-Result 'fixture has no remote' (@(Invoke-ExternalCommand -AsLines { git -C $projectRoot remote }).Count -eq 0) 'fixture must stay local'
            $taskId = 'C-MERGE-QUERY'
            $queryRoot = $projectRoot
            if ($failureMode -eq 'not a repository') {
                $queryRoot = Join-Path $tempRoot 'plain-directory'
                New-Item -ItemType Directory -Path $queryRoot | Out-Null
            } elseif ($failureMode -in @('corrupt task ref', 'malformed task ref')) {
                $refDir = Join-Path $projectRoot '.git/refs/heads/task'
                New-Item -ItemType Directory -Path $refDir | Out-Null
                $ref = if ($failureMode -eq 'corrupt task ref') { '1' * 40 } else { 'broken ref' }
                [IO.File]::WriteAllText((Join-Path $refDir $taskId), $ref + "`n", [Text.UTF8Encoding]::new($false))
            }
            $double = switch ($failureMode) {
                'diagnostic exit 1' { "function git { Write-Error 'inert query error'; `$global:LASTEXITCODE = 1 }" }
                'launch exception' { "function git { throw 'inert launch failure' }" }
                default { '' }
            }
            $quotedRoot = $queryRoot.Replace("'", "''")
            $quotedScript = $CHECK_SCRIPT.Replace("'", "''")
            $child = @"
`$ErrorActionPreference = 'Stop'
$double
try { & '$quotedScript' -TaskId '$taskId' -ProjectRoot '$quotedRoot' } catch { Write-Output 'OUTER CATCH SWALLOWED REFUSAL'; exit 0 }
exit `$LASTEXITCODE
"@
            $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($child))
            $res = Invoke-ExternalCommand { & (Get-PwshCommand) -NoProfile -NonInteractive -EncodedCommand $encoded }
            $output = $res.Output -join "`n"
            Assert-Result 'query failure refuses unconditionally' ($res.ExitCode -eq 2 -and $output -match 'Could not query task branch' -and $output -notmatch 'No-Code Closure|CLEAN MERGE SIMULATED|OUTER CATCH') "expected exit 2, got $($res.ExitCode): $output"
        }
    }

    $results += Run-Test -Name "Clean merge simulation passes" -Body {
        $projectRoot = Join-Path $tempRoot "clean"
        $taskId = "C-MERGE-CLEAN"
        Initialize-Repo -ProjectRoot $projectRoot
        Push-Location $projectRoot
        try {
            git checkout -b "task/$taskId" --quiet
            Set-Content -LiteralPath "feature.txt" -Value "task change" -Encoding UTF8
            git add feature.txt
            git commit -m "task change" --quiet
            git checkout master --quiet
        } finally {
            Pop-Location
        }

        $res = Invoke-MergeCheck -ProjectRoot $projectRoot -TaskId $taskId
        $output = $res.Output -join "`n"
        Assert-Result -Name "exit code" -Condition ($res.ExitCode -eq 0) -FailureMessage "expected 0, got $($res.ExitCode). Output:`n$output"
        Assert-Result -Name "no report" -Condition (-not (Test-Path (Join-Path $projectRoot ".crucible/session/$taskId/conflict_report.json"))) -FailureMessage "clean merge wrote a conflict report"
    }

    # Item 179: the simulation used to end with reset --hard, which erased an unstaged edit in a
    # file the task never touched.
    $results += Run-Test -Name "Merge simulation refuses a dirty checkout and leaves its edits alone" -Body {
        $projectRoot = Join-Path $tempRoot "dirty"
        $taskId = "C-MERGE-DIRTY"
        Initialize-Repo -ProjectRoot $projectRoot
        Push-Location $projectRoot
        try {
            git checkout -b "task/$taskId" --quiet
            Set-Content -LiteralPath "feature.txt" -Value "task change" -Encoding UTF8
            git add feature.txt
            git commit -m "task change" --quiet
            git checkout master --quiet
            Set-Content -LiteralPath "app.txt" -Value "human work in progress" -Encoding UTF8
        } finally {
            Pop-Location
        }

        $res = Invoke-MergeCheck -ProjectRoot $projectRoot -TaskId $taskId
        $output = $res.Output -join "`n"
        Assert-Result -Name "refused" -Condition ($res.ExitCode -eq 2 -and $output -match "uncommitted changes" -and $output -match "app\.txt") -FailureMessage "expected exit 2 naming app.txt, got $($res.ExitCode). Output:`n$output"
        $kept = (Get-Content -LiteralPath (Join-Path $projectRoot "app.txt") -Raw).Trim()
        Assert-Result -Name "edit kept" -Condition ($kept -eq "human work in progress") -FailureMessage "the unstaged edit was changed to '$kept'"
    }

    $results += Run-Test -Name "Clean merge simulation leaves no merge, task file or lost untracked file behind" -Body {
        $projectRoot = Join-Path $tempRoot "clean-undo"
        $taskId = "C-MERGE-UNDO"
        Initialize-Repo -ProjectRoot $projectRoot
        Push-Location $projectRoot
        try {
            git checkout -b "task/$taskId" --quiet
            Set-Content -LiteralPath "feature.txt" -Value "task change" -Encoding UTF8
            git add feature.txt
            git commit -m "task change" --quiet
            git checkout master --quiet
            Set-Content -LiteralPath "notes.txt" -Value "untracked notes" -Encoding UTF8
            $headBefore = (Invoke-ExternalCommand -AsLines { git rev-parse HEAD }).Trim()
        } finally {
            Pop-Location
        }

        $res = Invoke-MergeCheck -ProjectRoot $projectRoot -TaskId $taskId
        $output = $res.Output -join "`n"
        Assert-Result -Name "exit code" -Condition ($res.ExitCode -eq 0) -FailureMessage "expected 0, got $($res.ExitCode). Output:`n$output"
        Push-Location $projectRoot
        try {
            git rev-parse -q --verify MERGE_HEAD *> $null
            Assert-Result -Name "no merge in progress" -Condition ($LASTEXITCODE -ne 0) -FailureMessage "MERGE_HEAD is still set after the simulation"
            Assert-Result -Name "head unchanged" -Condition ((Invoke-ExternalCommand -AsLines { git rev-parse HEAD }).Trim() -eq $headBefore) -FailureMessage "HEAD moved"
            Assert-Result -Name "tracked tree clean" -Condition (@(Invoke-ExternalCommand -AsLines { git status --porcelain --untracked-files=no }).Count -eq 0) -FailureMessage ("tree not clean: " + ((Invoke-ExternalCommand -AsLines { git status --porcelain }) -join "; "))
        } finally {
            Pop-Location
        }
        Assert-Result -Name "task file gone" -Condition (-not (Test-Path (Join-Path $projectRoot "feature.txt"))) -FailureMessage "the task's file was left in the checkout"
        Assert-Result -Name "untracked file kept" -Condition (Test-Path (Join-Path $projectRoot "notes.txt")) -FailureMessage "the untracked file was removed"
    }

    $results += Run-Test -Name "Merge simulation runs from different CWD using -ProjectRoot" -Body {
        $projectRoot = Join-Path $tempRoot "diff-cwd"
        $taskId = "C-MERGE-DIFF-CWD"
        Initialize-Repo -ProjectRoot $projectRoot
        Push-Location $projectRoot
        try {
            git checkout -b "task/$taskId" --quiet
            Set-Content -LiteralPath "feature.txt" -Value "task change" -Encoding UTF8
            git add feature.txt
            git commit -m "task change" --quiet
            git checkout master --quiet
        } finally {
            Pop-Location
        }

        Push-Location $tempRoot
        try {
            $res = Invoke-ExternalCommand {
                & (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $CHECK_SCRIPT -TaskId $taskId -ProjectRoot $projectRoot
            }
        } finally {
            Pop-Location
        }

        $output = $res.Output -join "`n"
        Assert-Result -Name "exit code" -Condition ($res.ExitCode -eq 0) -FailureMessage "expected 0, got $($res.ExitCode). Output:`n$output"
    }

    $results += Run-Test -Name "Conflict detected and report written" -Body {
        $projectRoot = Join-Path $tempRoot "conflict"
        $taskId = "C-MERGE-CONFLICT"
        Initialize-Repo -ProjectRoot $projectRoot
        Push-Location $projectRoot
        try {
            git checkout -b "task/$taskId" --quiet
            Set-Content -LiteralPath "app.txt" -Value "task edit" -Encoding UTF8
            git add app.txt
            git commit -m "task edit" --quiet
            git checkout master --quiet
            Set-Content -LiteralPath "app.txt" -Value "main edit" -Encoding UTF8
            git add app.txt
            git commit -m "main edit" --quiet
        } finally {
            Pop-Location
        }

        $res = Invoke-MergeCheck -ProjectRoot $projectRoot -TaskId $taskId
        $output = $res.Output -join "`n"
        $reportPath = Join-Path $projectRoot ".crucible/session/$taskId/conflict_report.json"
        Assert-Result -Name "exit code" -Condition ($res.ExitCode -eq 1) -FailureMessage "expected 1, got $($res.ExitCode). Output:`n$output"
        Assert-Result -Name "report exists" -Condition (Test-Path $reportPath) -FailureMessage "report not found at $reportPath"
        $report = Get-Content -LiteralPath $reportPath -Raw -Encoding UTF8
        Assert-Result -Name "report names file" -Condition ($report -match "app.txt") -FailureMessage "report did not include app.txt. Content:`n$report"
    }

    $results += Run-Test -Name "Works on main-default repo" -Body {
        if (-not $mainSupported) {
            Write-Host "SKIPPED: git init -b requires git >= 2.28" -ForegroundColor Yellow
            return
        }
        $projectRoot = Join-Path $tempRoot "main-default"
        $taskId = "C-MERGE-MAIN"
        Initialize-Repo -ProjectRoot $projectRoot -Branch "main"
        Push-Location $projectRoot
        try {
            git checkout -b "task/$taskId" --quiet
            Set-Content -LiteralPath "main-feature.txt" -Value "task change" -Encoding UTF8
            git add main-feature.txt
            git commit -m "task change" --quiet
            git checkout main --quiet
        } finally {
            Pop-Location
        }

        $res = Invoke-MergeCheck -ProjectRoot $projectRoot -TaskId $taskId
        $output = $res.Output -join "`n"
        Assert-Result -Name "exit code" -Condition ($res.ExitCode -eq 0) -FailureMessage "expected 0, got $($res.ExitCode). Output:`n$output"
    }

    $results += Run-Test -Name "No-remote case does not fail pull step" -Body {
        $projectRoot = Join-Path $tempRoot "no-remote"
        $taskId = "C-MERGE-NOREMOTE"
        Initialize-Repo -ProjectRoot $projectRoot
        Push-Location $projectRoot
        try {
            git checkout -b "task/$taskId" --quiet
            Set-Content -LiteralPath "local-only.txt" -Value "task change" -Encoding UTF8
            git add local-only.txt
            git commit -m "task change" --quiet
            git checkout master --quiet
        } finally {
            Pop-Location
        }

        $res = Invoke-MergeCheck -ProjectRoot $projectRoot -TaskId $taskId
        $output = $res.Output -join "`n"
        Assert-Result -Name "exit code" -Condition ($res.ExitCode -eq 0) -FailureMessage "expected 0, got $($res.ExitCode). Output:`n$output"
        Assert-Result -Name "no origin message" -Condition ($output -match "No origin remote configured") -FailureMessage "expected explicit no-origin message. Output:`n$output"
    }

    $results += Run-Test -Name "Missing task branch returns clean exit code" -Body {
        $projectRoot = Join-Path $tempRoot "missing-branch"
        $taskId = "C-MERGE-MISSING"
        Initialize-Repo -ProjectRoot $projectRoot
        # Do NOT create the task/C-MERGE-MISSING branch

        $res = Invoke-MergeCheck -ProjectRoot $projectRoot -TaskId $taskId
        $output = $res.Output -join "`n"
        Assert-Result -Name "exit code" -Condition ($res.ExitCode -eq 0) -FailureMessage "expected 0, got $($res.ExitCode). Output:`n$output"
        Assert-Result -Name "clean message" -Condition ($output -match "No task branch") -FailureMessage "expected no-task-branch message. Output:`n$output"
    }

    $results += Run-Test -Name "Missing task branch closes despite a broken unrelated ref" -Body {
        $projectRoot = Join-Path $tempRoot 'missing-with-unrelated-broken-ref'
        Initialize-Repo -ProjectRoot $projectRoot -Branch 'main'
        Assert-Result 'fixture has no remote' (@(Invoke-ExternalCommand -AsLines { git -C $projectRoot remote }).Count -eq 0) 'fixture must stay local'
        $refDir = Join-Path $projectRoot '.git/refs/heads/zz'
        New-Item -ItemType Directory -Path $refDir | Out-Null
        [IO.File]::WriteAllText((Join-Path $refDir 'other'), "broken ref`n", [Text.UTF8Encoding]::new($false))
        $probe = Invoke-ExternalCommand { git -C $projectRoot show-ref --quiet }
        Assert-Result 'unscoped probe fails' ($probe.ExitCode -eq 128 -and ($probe.Output -join "`n") -match 'bad ref refs/heads/zz/other') 'fixture must break an unrelated ref query'

        $res = Invoke-MergeCheck -ProjectRoot $projectRoot -TaskId 'C-MERGE-MISSING'
        $output = $res.Output -join "`n"
        Assert-Result 'genuine missing ref closes' ($res.ExitCode -eq 0 -and $output -match 'No-Code Closure' -and $output -notmatch 'Could not query|CLEAN MERGE SIMULATED') "expected closure exit 0, got $($res.ExitCode): $output"
    }

    $results += Run-Test -Name "Missing configured primary refuses before No-Code Closure under an outer catch (I11)" -Body {
        $projectRoot = Join-Path $tempRoot 'missing-configured-primary'
        Initialize-Repo -ProjectRoot $projectRoot -Branch 'main'
        Assert-Result 'fixture has no remote' (@(Invoke-ExternalCommand -AsLines { git -C $projectRoot remote }).Count -eq 0) 'fixture must stay local'
        $configPath = Join-Path $projectRoot '.crucible/config.yaml'
        $config = [IO.File]::ReadAllText($configPath).Replace('project: MergeConflictTest', "project:`n  default_branch: nosuch")
        [IO.File]::WriteAllText($configPath, $config, [Text.UTF8Encoding]::new($false))
        git -C $projectRoot add .crucible/config.yaml
        git -C $projectRoot commit -m 'configure missing primary branch' --quiet
        $headBefore = (Invoke-ExternalCommand -AsLines { git -C $projectRoot rev-parse HEAD }).Trim()
        $quotedRoot = $projectRoot.Replace("'", "''")
        $quotedScript = $CHECK_SCRIPT.Replace("'", "''")
        $child = @"
`$ErrorActionPreference = 'Stop'
try { & '$quotedScript' -TaskId 'C-MERGE-MISSING' -ProjectRoot '$quotedRoot' } catch { Write-Output 'OUTER CATCH SWALLOWED REFUSAL'; exit 0 }
exit `$LASTEXITCODE
"@
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($child))
        $res = Invoke-ExternalCommand { & (Get-PwshCommand) -NoProfile -NonInteractive -EncodedCommand $encoded }
        $output = $res.Output -join "`n"
        Assert-Result 'configured primary failure refuses unconditionally' ($res.ExitCode -eq 1 -and $output -match 'Error: .*project.default_branch.*nosuch.*no such branch' -and $output -notmatch 'No-Code Closure|CLEAN MERGE SIMULATED|OUTER CATCH') "expected refusal exit 1, got $($res.ExitCode): $output"
        Assert-Result 'head unchanged' ((Invoke-ExternalCommand -AsLines { git -C $projectRoot rev-parse HEAD }).Trim() -eq $headBefore) 'refusal moved HEAD'
        Assert-Result 'tracked tree unchanged' (@(Invoke-ExternalCommand -AsLines { git -C $projectRoot status --porcelain --untracked-files=no }).Count -eq 0) 'refusal changed tracked files'
    }

    $results += Run-Test -Name "Honors configured session path" -Body {
        $projectRoot = Join-Path $tempRoot "custom-session"
        $taskId = "C-MERGE-CUSTOM"
        Initialize-Repo -ProjectRoot $projectRoot -SessionPath ".custom-session"
        Push-Location $projectRoot
        try {
            git checkout -b "task/$taskId" --quiet
            Set-Content -LiteralPath "app.txt" -Value "task edit" -Encoding UTF8
            git add app.txt
            git commit -m "task edit" --quiet
            git checkout master --quiet
            Set-Content -LiteralPath "app.txt" -Value "main edit" -Encoding UTF8
            git add app.txt
            git commit -m "main edit" --quiet
        } finally {
            Pop-Location
        }

        $res = Invoke-MergeCheck -ProjectRoot $projectRoot -TaskId $taskId
        $output = $res.Output -join "`n"
        $configuredReport = Join-Path $projectRoot ".custom-session/$taskId/conflict_report.json"
        $defaultReport = Join-Path $projectRoot ".crucible/session/$taskId/conflict_report.json"
        Assert-Result -Name "exit code" -Condition ($res.ExitCode -eq 1) -FailureMessage "expected 1, got $($res.ExitCode). Output:`n$output"
        Assert-Result -Name "configured report exists" -Condition (Test-Path $configuredReport) -FailureMessage "report not found at $configuredReport"
        Assert-Result -Name "default report absent" -Condition (-not (Test-Path $defaultReport)) -FailureMessage "report was written to default session path"
    }
} finally {
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

if ($results -contains $false) {
    Write-Host "`nSOME TESTS FAILED" -ForegroundColor Red
    exit 1
}

Write-Host ("`nALL TESTS PASSED (" + $results.Count + " tests)") -ForegroundColor Green
exit 0
