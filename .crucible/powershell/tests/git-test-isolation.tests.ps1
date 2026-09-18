$ErrorActionPreference = "Stop"
$REPO_ROOT = (Resolve-Path -Path "$PSScriptRoot/../..").Path
. (Join-Path $PSScriptRoot '_harness.ps1')

# Fixture repos git-init into TEMP and inherit the DEVELOPER'S global git config,
# so without isolation the suite's behaviour is a property of the machine rather
# than of the repository. These tests assert the isolation BEHAVIOURALLY - by
# making git perform the conversion that used to warn - rather than by reading
# back the config keys _harness.ps1 just wrote, which would only prove that a
# file exists and would pass even if git ignored it.

$results = @()
$tempRoot = New-TestFixtureRoot -NameHint "gitiso"

function New-FixtureRepo {
    param([Parameter(Mandatory=$true)][string]$Name)
    $path = Join-Path $tempRoot $Name
    New-Item -ItemType Directory -Path $path -Force | Out-Null
    $null = Invoke-ExternalCommand -Command { git -C $path init --quiet }
    return $path
}

# Exact LF bytes. Set-Content emits CRLF under PowerShell 5.1, so the conversion
# under test would never be requested and every case below would pass vacuously.
function Write-LfFile {
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)][string]$Content
    )
    [System.IO.File]::WriteAllText($Path, $Content, (New-Object System.Text.UTF8Encoding($false)))
}

# The cases at the bottom of this file load _harness.ps1 in child PROCESSES. The hazard
# they cover is between processes - run-all-tests.ps1 exports CRUCIBLE_TEST_ROOT, so up
# to eight children resolve one gitconfig path - and re-invoking the function in this
# process would exercise a single writer and prove nothing about any of it.
$PS_HOST = (Get-Process -Id $PID).Path
$HARNESS_PATH = Join-Path $PSScriptRoot "_harness.ps1"

# The bytes Initialize-GitTestIsolation publishes, held here as a literal. Reading them
# back from $env:GIT_CONFIG_GLOBAL instead would compare the function against itself, so
# a truncated or doubled file would match whatever produced it and every byte-exactness
# assertion below would pass vacuously.
$EXPECTED_CONFIG = (@(
    "[core]",
    "`tautocrlf = false",
    "`tsafecrlf = false",
    "[user]",
    "`tname = Crucible Test",
    "`temail = test@crucible.invalid",
    "[merge]",
    "`tautoedit = no",
    "[init]",
    "`tdefaultBranch = master"
) -join "`n") + "`n"

# Not Get-TestRunRoot: these cases need a root that starts empty and that no other test
# file is sharing. The real one already holds this run's gitconfig, and eight children
# writing into it would be the very collision under test. These sit under this file's own
# fixture root, which is inside the run root without being it - item 88 moved the fixture
# root there, and that changed where these live without changing what they are.
function New-IsolatedRunRoot {
    param([Parameter(Mandatory=$true)][string]$Name)
    $path = Join-Path $tempRoot ("root-" + $Name)
    New-Item -ItemType Directory -Path $path -Force | Out-Null
    return $path
}

function New-HarnessLoaderScript {
    param([Parameter(Mandatory=$true)][string]$Path)
    Write-LfFile -Path $Path -Content (
        ". `"$HARNESS_PATH`"`n" +
        "Write-Host (`"CONFIG=`" + `$env:GIT_CONFIG_GLOBAL)`n" +
        "Write-Host (`"ROOT=`" + `$env:CRUCIBLE_TEST_ROOT)`n" +
        "exit 0`n")
}

# CRUCIBLE_TEST_ROOT is overridden on the child's environment block rather than by
# assigning to $env: here. This process is itself running inside a run root, and
# reassigning the variable would move its own fixtures out from under it for the rest
# of the file.
function Start-HarnessLoad {
    param(
        [Parameter(Mandatory=$true)][string]$ScriptPath,
        [string]$TestRoot
    )
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $PS_HOST
    $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$ScriptPath`""
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    if ([string]::IsNullOrEmpty($TestRoot)) {
        [void]$psi.EnvironmentVariables.Remove("CRUCIBLE_TEST_ROOT")
    } else {
        $psi.EnvironmentVariables["CRUCIBLE_TEST_ROOT"] = $TestRoot
    }
    $p = New-Object System.Diagnostics.Process
    $p.StartInfo = $psi
    [void]$p.Start()
    return $p
}

# Both pipes are drained before the wait. A child that fills a redirected pipe blocks on
# the write, and a parent that waited first would deadlock against it. The loader script
# emits two lines, so reading the streams in sequence is safe here.
function Complete-HarnessLoad {
    param([Parameter(Mandatory=$true)]$Process)
    $out = $Process.StandardOutput.ReadToEnd()
    $err = $Process.StandardError.ReadToEnd()
    $Process.WaitForExit()
    return [pscustomobject]@{ ExitCode = $Process.ExitCode; Output = ($out + $err) }
}

try {
    $results += Run-Test -Name "Harness points git at an isolated global config" -Body {
        Assert-Result -Name "GIT_CONFIG_GLOBAL is set" `
            -Condition (-not [string]::IsNullOrWhiteSpace($env:GIT_CONFIG_GLOBAL)) `
            -FailureMessage "_harness.ps1 did not set GIT_CONFIG_GLOBAL"
        Assert-Result -Name "the isolated config exists on disk" `
            -Condition (Test-Path -LiteralPath $env:GIT_CONFIG_GLOBAL) `
            -FailureMessage ("GIT_CONFIG_GLOBAL points at a missing file: " + $env:GIT_CONFIG_GLOBAL)
    }

    $results += Run-Test -Name "Staging an LF file in a fixture repo produces no CRLF warning" -Body {
        $repo = New-FixtureRepo -Name "lf-add"
        Write-LfFile -Path (Join-Path $repo "script.sh") -Content "#!/bin/sh`necho hi`n"
        $add = Invoke-ExternalCommand -Command { git -C $repo add script.sh }
        Assert-Result -Name "git add exits 0" -Condition ($add.ExitCode -eq 0) -FailureMessage ("git add failed: " + $add.Output)
        Assert-Result -Name "no CRLF replacement warning" `
            -Condition ($add.Output -notmatch 'will be replaced by CRLF') `
            -FailureMessage ("git add warned: " + $add.Output)
    }

    $results += Run-Test -Name "A committed shell script checks back out as LF, not CRLF" -Body {
        $repo = New-FixtureRepo -Name "checkout-lf"
        $script = Join-Path $repo "hook.sh"
        Write-LfFile -Path $script -Content "#!/bin/sh`nexit 0`n"
        $null = Invoke-ExternalCommand -Command { git -C $repo add hook.sh }
        $null = Invoke-ExternalCommand -Command { git -C $repo commit -q -m "add hook" }
        Remove-Item -LiteralPath $script -Force
        $co = Invoke-ExternalCommand -Command { git -C $repo checkout -- hook.sh }
        Assert-Result -Name "checkout exits 0" -Condition ($co.ExitCode -eq 0) -FailureMessage ("git checkout failed: " + $co.Output)
        # The warning is only ever about the working copy - the index was never at
        # risk - so the working copy is the only place the defect is observable.
        $bytes = [System.IO.File]::ReadAllBytes($script)
        Assert-Result -Name "working copy has no CR bytes" `
            -Condition (-not ($bytes -contains 13)) `
            -FailureMessage "checked-out shell script contains CR; a Linux runner would reject the shebang"
    }

    $results += Run-Test -Name "A repo-local override still beats the isolated global" -Body {
        $repo = New-FixtureRepo -Name "local-wins"
        $null = Invoke-ExternalCommand -Command { git -C $repo config core.autocrlf true }
        $read = Invoke-ExternalCommand -Command { git -C $repo config core.autocrlf }
        # Load-bearing: init-project-core.tests.ps1 sets core.autocrlf=true locally and
        # asserts the scaffolded .gitattributes suppresses the warning anyway. If the
        # isolation ever outranked local config, that test would pass for the wrong
        # reason - the attributes would no longer be what silences it.
        Assert-Result -Name "local value wins" -Condition ($read.Output.Trim() -eq "true") `
            -FailureMessage ("expected local core.autocrlf=true to win, got: " + $read.Output)
    }

    $results += Run-Test -Name "A fixture repo can commit without a local identity" -Body {
        $repo = New-FixtureRepo -Name "identity"
        Write-LfFile -Path (Join-Path $repo "a.txt") -Content "hello`n"
        $null = Invoke-ExternalCommand -Command { git -C $repo add a.txt }
        $commit = Invoke-ExternalCommand -Command { git -C $repo commit -q -m "no local identity" }
        # Without user.* in the isolated config this fails outright with "Please tell
        # me who you are", because the developer's global identity is out of scope.
        Assert-Result -Name "commit exits 0" -Condition ($commit.ExitCode -eq 0) -FailureMessage ("git commit failed: " + $commit.Output)
        $author = Invoke-ExternalCommand -Command { git -C $repo log -1 --format=%an }
        Assert-Result -Name "author comes from the isolated config" `
            -Condition ($author.Output.Trim() -eq "Crucible Test") `
            -FailureMessage ("expected author 'Crucible Test', got: " + $author.Output)
    }

    $results += Run-Test -Name "The default branch name is pinned, not inherited" -Body {
        $repo = New-FixtureRepo -Name "default-branch"
        Write-LfFile -Path (Join-Path $repo "a.txt") -Content "hello`n"
        $null = Invoke-ExternalCommand -Command { git -C $repo add a.txt }
        $null = Invoke-ExternalCommand -Command { git -C $repo commit -q -m "first" }
        $branch = Invoke-ExternalCommand -Command { git -C $repo rev-parse --abbrev-ref HEAD }
        # A developer whose global sets init.defaultBranch=main would otherwise get a
        # different branch here than CI does, for tests that git init without -b.
        Assert-Result -Name "branch is master" -Condition ($branch.Output.Trim() -eq "master") `
            -FailureMessage ("expected pinned default branch 'master', got: " + $branch.Output)
    }

    $results += Run-Test -Name "Fixture merges cannot block on an editor" -Body {
        $repo = New-FixtureRepo -Name "autoedit"
        $read = Invoke-ExternalCommand -Command { git -C $repo config merge.autoedit }
        # Asserted as configuration rather than behaviour on purpose: provoking the
        # editor would require a real merge that hangs, which is untestable without
        # a timeout. The key is pinned so it is not dropped from the config as noise.
        Assert-Result -Name "merge.autoedit is no" -Condition ($read.Output.Trim() -eq "no") `
            -FailureMessage ("expected merge.autoedit=no, got: " + $read.Output)
    }
    # Pinned here because this is the file where the trap surfaced: three assertions
    # above pass -FailureMessage from a command that succeeds silently. Both facts are
    # asserted separately, because the distinction most likely to be lost by a future
    # edit is that allowing "" does NOT make the parameter optional.
    $results += Run-Test -Name "Assert-Result accepts an empty failure message" -Body {
        $threw = $false
        try { Assert-Result -Name "inner" -Condition $true -FailureMessage "" } catch { $threw = $true }
        Assert-Result -Name "empty message binds" -Condition (-not $threw) `
            -FailureMessage "a passing assertion threw because its FailureMessage was empty"

        $omitted = $false
        try { Assert-Result -Name "inner" -Condition $true } catch { $omitted = $true }
        Assert-Result -Name "omitting the argument is still an error" -Condition $omitted `
            -FailureMessage "FailureMessage stopped being mandatory"
    }

    # The reported failure, made deterministic. crucible.tests.ps1 died after 1.82s on
    # "the process cannot access the file ... because it is being used by another
    # process", which is what an unconditional WriteAllText gets when a sibling has the
    # destination open. Holding it open on purpose turns that race into a certainty.
    $results += Run-Test -Name "A harness load survives a gitconfig another process holds open" -Body {
        $root = New-IsolatedRunRoot -Name "locked"
        $configPath = Join-Path $root "gitconfig"
        Write-LfFile -Path $configPath -Content $EXPECTED_CONFIG

        $handle = [System.IO.File]::Open($configPath, [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
        try {
            # The statement the function used to run, executed here against the same
            # handle. Without it this case would show that the new code passes without
            # ever establishing that the old code would not, which is the only reason
            # the case is worth its runtime.
            $unconditionalWriteThrew = $false
            try {
                [System.IO.File]::WriteAllText($configPath, $EXPECTED_CONFIG, (New-Object System.Text.UTF8Encoding($false)))
            } catch {
                $unconditionalWriteThrew = $true
            }
            Assert-Result -Name "the unconditional write still fails against a held file" `
                -Condition $unconditionalWriteThrew `
                -FailureMessage "WriteAllText succeeded against a FileShare.None handle, so this case proves nothing"

            $script = Join-Path $root "load.ps1"
            New-HarnessLoaderScript -Path $script
            $r = Complete-HarnessLoad -Process (Start-HarnessLoad -ScriptPath $script -TestRoot $root)
            Assert-Result -Name "the harness loads anyway" -Condition ($r.ExitCode -eq 0) `
                -FailureMessage ("a harness load failed against a held gitconfig: " + $r.Output)
            Assert-Result -Name "and reports no sharing violation" `
                -Condition ($r.Output -notmatch 'being used by another process') `
                -FailureMessage ("the sharing violation is back: " + $r.Output)
        } finally {
            $handle.Dispose()
        }
    }

    # One writer per shared config is the fix, so a load that finds one must leave it
    # alone. The sentinel is a git comment, which git ignores and an overwrite does not.
    $results += Run-Test -Name "A later harness load does not rewrite a config already in the root" -Body {
        $root = New-IsolatedRunRoot -Name "no-rewrite"
        $configPath = Join-Path $root "gitconfig"
        $sentinel = "# placed by the test; git ignores it and an overwrite does not`n"
        Write-LfFile -Path $configPath -Content ($sentinel + $EXPECTED_CONFIG)

        $script = Join-Path $root "load.ps1"
        New-HarnessLoaderScript -Path $script
        $r = Complete-HarnessLoad -Process (Start-HarnessLoad -ScriptPath $script -TestRoot $root)
        Assert-Result -Name "the load succeeds" -Condition ($r.ExitCode -eq 0) `
            -FailureMessage ("harness load failed: " + $r.Output)
        # Asserted as the exact path, not merely as non-empty: the child inherits this
        # process's GIT_CONFIG_GLOBAL through its environment block, so a function that
        # stopped setting the variable would leave a plausible value behind.
        Assert-Result -Name "it points at the config that was already there" `
            -Condition ($r.Output -match ([regex]::Escape("CONFIG=" + $configPath))) `
            -FailureMessage ("expected GIT_CONFIG_GLOBAL=" + $configPath + ", got: " + $r.Output)
        Assert-Result -Name "the existing bytes are untouched" `
            -Condition ([System.IO.File]::ReadAllText($configPath) -ceq ($sentinel + $EXPECTED_CONFIG)) `
            -FailureMessage "the harness overwrote a gitconfig that was already in the run root"
    }

    # Eight because that is the runner's ThrottleLimit ceiling, and the root starts empty
    # so every one of them reaches the write rather than short-circuiting on it. This is
    # the collision as it actually happened: eight WriteAllText calls truncating one
    # destination, rarely enough that the failure read as a flake in whichever test drew
    # the short straw.
    $results += Run-Test -Name "Eight concurrent harness loads share one run root without colliding" -Body {
        $root = New-IsolatedRunRoot -Name "concurrent"
        $script = Join-Path $root "load.ps1"
        New-HarnessLoaderScript -Path $script

        $procs = @()
        for ($i = 0; $i -lt 8; $i++) {
            $procs += Start-HarnessLoad -ScriptPath $script -TestRoot $root
        }
        $loads = @($procs | ForEach-Object { Complete-HarnessLoad -Process $_ })

        $failed = @($loads | Where-Object { $_.ExitCode -ne 0 })
        Assert-Result -Name "all eight loads succeed" -Condition ($failed.Count -eq 0) `
            -FailureMessage ([string]$failed.Count + " of 8 concurrent loads failed: " + (($failed | ForEach-Object { $_.Output }) -join " | "))

        $configPath = Join-Path $root "gitconfig"
        Assert-Result -Name "the published config is byte-exact" `
            -Condition ([System.IO.File]::ReadAllText($configPath) -ceq $EXPECTED_CONFIG) `
            -FailureMessage "the shared config is not the canonical content: a concurrent write truncated or doubled it"

        $strays = @(Get-ChildItem -LiteralPath $root -Filter "gitconfig.stage-*" -ErrorAction SilentlyContinue)
        Assert-Result -Name "no staging files survive the publish" -Condition ($strays.Count -eq 0) `
            -FailureMessage ([string]$strays.Count + " staging file(s) were left in the run root")
    }

    # The pid and the guid in the staging name are what keep eight simultaneous loads off
    # one temporary file, and the concurrent case above cannot prove it: those eight can
    # serialise by luck and pass with a fixed name, which is exactly what a mutation to a
    # fixed name did. So this holds open the name the staging path collapses to when the
    # suffix is dropped, alongside a stray left behind by a killed run, and requires the
    # load to be undisturbed by either.
    $results += Run-Test -Name "A staging file another process holds open does not disturb a load" -Body {
        $root = New-IsolatedRunRoot -Name "held-stage"
        $collapsed = Join-Path $root "gitconfig.stage"
        Write-LfFile -Path $collapsed -Content "held open by this test"
        Write-LfFile -Path (Join-Path $root "gitconfig.stage-999999-dead") -Content "left behind by a killed run"

        $handle = [System.IO.File]::Open($collapsed, [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
        try {
            $script = Join-Path $root "load.ps1"
            New-HarnessLoaderScript -Path $script
            $r = Complete-HarnessLoad -Process (Start-HarnessLoad -ScriptPath $script -TestRoot $root)
            Assert-Result -Name "the load succeeds" -Condition ($r.ExitCode -eq 0) `
                -FailureMessage ("a staging file held by another process stopped a harness load: " + $r.Output)
            Assert-Result -Name "and publishes a config of its own" `
                -Condition ([System.IO.File]::ReadAllText((Join-Path $root "gitconfig")) -ceq $EXPECTED_CONFIG) `
                -FailureMessage "the load did not publish the canonical config"
        } finally {
            $handle.Dispose()
        }
    }

    # Every test file in this directory is runnable on its own, so the function cannot
    # depend on a runner having materialised the config ahead of it. With no
    # CRUCIBLE_TEST_ROOT in the environment the child builds its own root, which is the
    # one case where it really is the only writer.
    $results += Run-Test -Name "A harness load with no runner present builds its own root and config" -Body {
        $work = New-IsolatedRunRoot -Name "standalone"
        $script = Join-Path $work "load.ps1"
        New-HarnessLoaderScript -Path $script
        $r = Complete-HarnessLoad -Process (Start-HarnessLoad -ScriptPath $script)

        Assert-Result -Name "the standalone load succeeds" -Condition ($r.ExitCode -eq 0) `
            -FailureMessage ("a harness load without a runner failed: " + $r.Output)

        $ownRoot = $null
        if ($r.Output -match 'ROOT=(.+)') { $ownRoot = $Matches[1].Trim() }
        try {
            Assert-Result -Name "it made a root of its own" `
                -Condition ((-not [string]::IsNullOrWhiteSpace($ownRoot)) -and $ownRoot -ne $work) `
                -FailureMessage ("expected a freshly created run root, got: " + $r.Output)

            $ownConfig = $null
            if ($r.Output -match 'CONFIG=(.+)') { $ownConfig = $Matches[1].Trim() }
            Assert-Result -Name "the config lives inside that root" `
                -Condition ((-not [string]::IsNullOrWhiteSpace($ownConfig)) -and $ownConfig -eq (Join-Path $ownRoot "gitconfig")) `
                -FailureMessage ("expected the config under the new root, got: " + $r.Output)
            Assert-Result -Name "and holds the canonical bytes" `
                -Condition ((Test-Path -LiteralPath $ownConfig -PathType Leaf) -and ([System.IO.File]::ReadAllText($ownConfig) -ceq $EXPECTED_CONFIG)) `
                -FailureMessage "a standalone load did not produce the canonical config"
        } finally {
            # A standalone test file has no finally of its own, so nothing else will
            # collect this. Left behind it would be reported orphaned only once the pid
            # was reused or dead, which is a slow way to litter TEMP.
            if ((-not [string]::IsNullOrWhiteSpace($ownRoot)) -and (Test-Path -LiteralPath $ownRoot)) {
                Remove-Item -LiteralPath $ownRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    # The publish can only fail for a reason other than losing the race if something is
    # already occupying the name, and a directory is the reachable way to arrange that.
    # The branch matters out of proportion to how likely it is: swallowing the failure
    # would set GIT_CONFIG_GLOBAL to a path git cannot read as a config, which hands the
    # whole suite back to the global config of whoever is running it - silently, and
    # looking exactly like isolation.
    $results += Run-Test -Name "A publish that lands nothing fails loudly instead of pointing at nothing" -Body {
        $root = New-IsolatedRunRoot -Name "blocked"
        $configPath = Join-Path $root "gitconfig"
        New-Item -ItemType Directory -Path $configPath -Force | Out-Null

        $script = Join-Path $root "load.ps1"
        New-HarnessLoaderScript -Path $script
        $r = Complete-HarnessLoad -Process (Start-HarnessLoad -ScriptPath $script -TestRoot $root)

        Assert-Result -Name "the load fails" -Condition ($r.ExitCode -ne 0) `
            -FailureMessage ("a load whose publish landed nothing reported success: " + $r.Output)
        Assert-Result -Name "it does not announce a config it never wrote" `
            -Condition ($r.Output -notmatch 'CONFIG=') `
            -FailureMessage ("GIT_CONFIG_GLOBAL was set despite the publish failing: " + $r.Output)
        $strays = @(Get-ChildItem -LiteralPath $root -Filter "gitconfig.stage-*" -ErrorAction SilentlyContinue)
        Assert-Result -Name "the staging file is cleaned up on the way out" -Condition ($strays.Count -eq 0) `
            -FailureMessage ([string]$strays.Count + " staging file(s) survived a failed publish")
    }
} finally {    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

if ($results -contains $false) {
    Write-Host "`nSOME TESTS FAILED" -ForegroundColor Red
    exit 1
}

Write-Host ("`nALL TESTS PASSED (" + $results.Count + " tests)") -ForegroundColor Green
exit 0