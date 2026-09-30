# Tests that an adopter's own git hooks run under Crucible's core.hooksPath when
# hooks.project_dir names them. Item 150.
#
# Installing Crucible points core.hooksPath at .crucible/scripts/hooks, which shadowed
# gobot's tracked scripts/hooks from the day the bundle was installed: golangci-lint,
# go test -race and govulncheck stopped running and nothing said so. Every case here
# drives a real git commit or push through the installed hooks, because the question is
# which hook git actually runs, and no reading of the hook text answers that.

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$REPO_ROOT = (Resolve-Path -Path "$PSScriptRoot/../..").Path
. (Join-Path $PSScriptRoot '_harness.ps1')
. (Join-Path $REPO_ROOT "powershell/lib/platform.ps1")
Initialize-GitTestIsolation

$results = @()
$utf8 = New-Object System.Text.UTF8Encoding($false)

function Write-LfFile {
    param([string]$Path, [string]$Text)
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [System.IO.File]::WriteAllText($Path, $Text.Replace("`r`n", "`n"), $script:utf8)
}

function Invoke-RepoGit {
    param([string]$Repo, [string[]]$GitArgs)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $out = & git -C $Repo @GitArgs 2>&1
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prev
    }
    return [pscustomobject]@{ ExitCode = $code; Output = (@($out) -join "`n") }
}

# Each project hook records that it ran, and what it was given, under .git so the
# records never show up as changes to commit.
$recordingPreCommit = @'
#!/bin/sh
echo "project pre-commit ran" > .git/chain-pre-commit
exit 0
'@
$failingPreCommit = @'
#!/bin/sh
echo "project pre-commit ran" > .git/chain-pre-commit
echo "project pre-commit says no" >&2
exit 3
'@
$recordingCommitMsg = @'
#!/bin/sh
if [ -f "$1" ]; then
    echo "message file: $(head -n 1 "$1")" > .git/chain-commit-msg
else
    echo "no message file: $1" > .git/chain-commit-msg
fi
exit 0
'@
$recordingPrePush = @'
#!/bin/sh
echo "args: $1 $2" > .git/chain-pre-push
cat >> .git/chain-pre-push
exit 0
'@
$failingPrePush = @'
#!/bin/sh
echo "args: $1 $2" > .git/chain-pre-push
cat >> .git/chain-pre-push
exit 5
'@

$tempRoot = New-TestFixtureRoot -NameHint "project-hook-chaining"
try {
    $app = Join-Path $tempRoot "app"
    $remote = Join-Path $tempRoot "remote.git"
    New-Item -ItemType Directory -Path $app -Force | Out-Null
    & git init --quiet --bare $remote | Out-Null
    & git init --quiet $app | Out-Null
    Write-LfFile -Path (Join-Path $app "README.md") -Text "# App`n"
    $null = Invoke-RepoGit -Repo $app -GitArgs @("add", "README.md")
    $null = Invoke-RepoGit -Repo $app -GitArgs @("commit", "--quiet", "-m", "initial")

    $init = Invoke-ExternalCommand {
        & (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File (Join-Path $REPO_ROOT "powershell/init-project.ps1") -ProjectRoot $app -ProjectName "App" -Quiet
    }
    if ($init.ExitCode -ne 0) { throw ("init-project failed: " + ($init.Output -join "`n")) }
    $hooksPath = (Invoke-RepoGit -Repo $app -GitArgs @("config", "--get", "core.hooksPath")).Output.Trim()
    if ($hooksPath -ne ".crucible/scripts/hooks") { throw ("init-project did not install hooks; core.hooksPath is '" + $hooksPath + "'") }

    # The project hooks are tracked the way gobot tracks its own, and a failing
    # pre-commit is in place from the start so an unset setting that ran it would block.
    Write-LfFile -Path (Join-Path $app "scripts/hooks/pre-commit") -Text $failingPreCommit
    Write-LfFile -Path (Join-Path $app "scripts/hooks/pre-push") -Text $failingPrePush
    $null = Invoke-RepoGit -Repo $app -GitArgs @("add", "-A")
    $base = Invoke-RepoGit -Repo $app -GitArgs @("commit", "--quiet", "-m", "install crucible")
    if ($base.ExitCode -ne 0) { throw ("baseline commit failed: " + $base.Output) }
    $null = Invoke-RepoGit -Repo $app -GitArgs @("remote", "add", "origin", $remote)
    $gitDir = Join-Path $app ".git"
    $configPath = Join-Path $app ".crucible/config.yaml"

    $results += Run-Test -Name "Unset hooks.project_dir runs no project hook at commit or push" -Body {
        Write-LfFile -Path (Join-Path $app "a.txt") -Text "one`n"
        $null = Invoke-RepoGit -Repo $app -GitArgs @("add", "a.txt")
        $c = Invoke-RepoGit -Repo $app -GitArgs @("commit", "-m", "unset commit")
        Assert-Result -Name "commit succeeds" -Condition ($c.ExitCode -eq 0) -FailureMessage ("the failing project pre-commit ran without being configured: " + $c.Output)
        Assert-Result -Name "project pre-commit did not run" -Condition (-not (Test-Path -LiteralPath (Join-Path $gitDir "chain-pre-commit"))) -FailureMessage "the project pre-commit ran with hooks.project_dir unset"

        $p = Invoke-RepoGit -Repo $app -GitArgs @("push", "--quiet", "origin", "HEAD:refs/heads/main")
        Assert-Result -Name "push succeeds" -Condition ($p.ExitCode -eq 0) -FailureMessage ("the failing project pre-push ran without being configured: " + $p.Output)
        Assert-Result -Name "project pre-push did not run" -Condition (-not (Test-Path -LiteralPath (Join-Path $gitDir "chain-pre-push"))) -FailureMessage "the project pre-push ran with hooks.project_dir unset"
        Assert-Result -Name "adopter pre-push still says nothing was verified" -Condition ($p.Output -match "nothing was verified") -FailureMessage ("expected the unchained adopter message, got: " + $p.Output)
    }

    # From here on the setting is on. It is committed like any other config change.
    $configText = [System.IO.File]::ReadAllText($configPath)
    Write-LfFile -Path $configPath -Text ($configText.TrimEnd() + "`n`nhooks:`n  project_dir: scripts/hooks`n")

    $results += Run-Test -Name "A failing project pre-commit blocks the commit" -Body {
        $null = Invoke-RepoGit -Repo $app -GitArgs @("add", "-A")
        $c = Invoke-RepoGit -Repo $app -GitArgs @("commit", "-m", "blocked commit")
        Assert-Result -Name "commit fails" -Condition ($c.ExitCode -ne 0) -FailureMessage ("the failing project pre-commit did not block: " + $c.Output)
        Assert-Result -Name "project pre-commit ran" -Condition (Test-Path -LiteralPath (Join-Path $gitDir "chain-pre-commit")) -FailureMessage ("the project pre-commit never ran: " + $c.Output)
        Assert-Result -Name "the failure names the project hook" -Condition ($c.Output -match "project hook .*pre-commit failed \(exit 3\)") -FailureMessage ("expected the chained failure and its exit code, got: " + $c.Output)
        Assert-Result -Name "the project hook's own output shows" -Condition ($c.Output -match "project pre-commit says no") -FailureMessage ("the project hook's stderr was lost: " + $c.Output)
    }

    $results += Run-Test -Name "A passing project pre-commit and commit-msg run and let the commit through" -Body {
        Remove-Item -LiteralPath (Join-Path $gitDir "chain-pre-commit") -Force -ErrorAction SilentlyContinue
        Write-LfFile -Path (Join-Path $app "scripts/hooks/pre-commit") -Text $recordingPreCommit
        Write-LfFile -Path (Join-Path $app "scripts/hooks/commit-msg") -Text $recordingCommitMsg
        $null = Invoke-RepoGit -Repo $app -GitArgs @("add", "-A")
        $c = Invoke-RepoGit -Repo $app -GitArgs @("commit", "-m", "chained commit subject")
        Assert-Result -Name "commit succeeds" -Condition ($c.ExitCode -eq 0) -FailureMessage ("a passing project hook blocked the commit: " + $c.Output)
        Assert-Result -Name "project pre-commit ran" -Condition (Test-Path -LiteralPath (Join-Path $gitDir "chain-pre-commit")) -FailureMessage ("the project pre-commit never ran: " + $c.Output)
        $msgRecord = Join-Path $gitDir "chain-commit-msg"
        Assert-Result -Name "project commit-msg ran" -Condition (Test-Path -LiteralPath $msgRecord) -FailureMessage ("the project commit-msg never ran: " + $c.Output)
        if (Test-Path -LiteralPath $msgRecord) {
            $recorded = [System.IO.File]::ReadAllText($msgRecord)
            Assert-Result -Name "commit-msg got the message file" -Condition ($recorded -match "message file: chained commit subject") -FailureMessage ("the project commit-msg did not get the message file as its argument: " + $recorded)
        }
    }

    $results += Run-Test -Name "A failing project pre-push blocks the push and gets git's arguments and refs" -Body {
        $before = (Invoke-RepoGit -Repo $remote -GitArgs @("rev-parse", "refs/heads/main")).Output.Trim()
        $local = (Invoke-RepoGit -Repo $app -GitArgs @("rev-parse", "HEAD")).Output.Trim()
        $p = Invoke-RepoGit -Repo $app -GitArgs @("push", "origin", "HEAD:refs/heads/main")
        $after = (Invoke-RepoGit -Repo $remote -GitArgs @("rev-parse", "refs/heads/main")).Output.Trim()
        Assert-Result -Name "push fails" -Condition ($p.ExitCode -ne 0) -FailureMessage ("the failing project pre-push did not block: " + $p.Output)
        Assert-Result -Name "remote unchanged" -Condition ($before -eq $after) -FailureMessage "the remote moved despite a failing pre-push"
        Assert-Result -Name "the failure names the project hook" -Condition ($p.Output -match "project hook .*pre-push failed \(exit 5\)") -FailureMessage ("expected the chained failure and its exit code, got: " + $p.Output)
        $record = Join-Path $gitDir "chain-pre-push"
        Assert-Result -Name "project pre-push ran" -Condition (Test-Path -LiteralPath $record) -FailureMessage ("the project pre-push never ran: " + $p.Output)
        if (Test-Path -LiteralPath $record) {
            $recorded = [System.IO.File]::ReadAllText($record)
            Assert-Result -Name "pre-push got the remote name" -Condition ($recorded -match "args: origin ") -FailureMessage ("the project pre-push did not get git's arguments: " + $recorded)
            Assert-Result -Name "pre-push got the ref line" -Condition ($recorded -match ("(?m)^\S+ " + $local + " refs/heads/main " + $before)) -FailureMessage ("the project pre-push did not get the push refs on stdin: " + $recorded)
        }
    }

    $results += Run-Test -Name "A passing project pre-push lets the push through and says so" -Body {
        Write-LfFile -Path (Join-Path $app "scripts/hooks/pre-push") -Text $recordingPrePush
        $null = Invoke-RepoGit -Repo $app -GitArgs @("add", "-A")
        $null = Invoke-RepoGit -Repo $app -GitArgs @("commit", "--quiet", "-m", "passing pre-push")
        $local = (Invoke-RepoGit -Repo $app -GitArgs @("rev-parse", "HEAD")).Output.Trim()
        $p = Invoke-RepoGit -Repo $app -GitArgs @("push", "origin", "HEAD:refs/heads/main")
        $after = (Invoke-RepoGit -Repo $remote -GitArgs @("rev-parse", "refs/heads/main")).Output.Trim()
        Assert-Result -Name "push succeeds" -Condition ($p.ExitCode -eq 0) -FailureMessage ("a passing project pre-push blocked the push: " + $p.Output)
        Assert-Result -Name "remote moved" -Condition ($after -eq $local) -FailureMessage "the push reported success but the remote did not move"
        Assert-Result -Name "reports the project hook passed" -Condition ($p.Output -match "the project's pre-push hook passed") -FailureMessage ("expected the chained success line, got: " + $p.Output)
    }

    $results += Run-Test -Name "An unusable hooks.project_dir fails the commit instead of skipping the project hook" -Body {
        $configText = [System.IO.File]::ReadAllText($configPath)
        Write-LfFile -Path $configPath -Text ($configText.Replace("project_dir: scripts/hooks", "project_dir: scripts/no-such-hooks"))
        Write-LfFile -Path (Join-Path $app "b.txt") -Text "two`n"
        $null = Invoke-RepoGit -Repo $app -GitArgs @("add", "b.txt")
        $c = Invoke-RepoGit -Repo $app -GitArgs @("commit", "-m", "bad setting")
        Assert-Result -Name "commit fails" -Condition ($c.ExitCode -ne 0) -FailureMessage ("a missing project hooks directory was skipped silently: " + $c.Output)
        Assert-Result -Name "says why" -Condition ($c.Output -match "does not exist: scripts/no-such-hooks") -FailureMessage ("expected the missing-directory reason, got: " + $c.Output)
    }
}
finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-TestFileSummary -Results $results
