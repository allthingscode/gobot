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
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("crucible-gitiso-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

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