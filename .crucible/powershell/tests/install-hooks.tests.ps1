# Tests for install-hooks.ps1 (sets git core.hooksPath for framework and adopter repos).
# The script derives the repo root from its own $PSScriptRoot, so each case stages a
# copy of the real script inside a throwaway git repo and asserts the resulting config.

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$REPO_ROOT = (Resolve-Path -Path "$PSScriptRoot/../..").Path
. (Join-Path $PSScriptRoot '_harness.ps1')
. (Join-Path $REPO_ROOT "powershell/lib/platform.ps1")
$SCRIPT_SRC = Join-Path $REPO_ROOT "powershell/install-hooks.ps1"

$results = @()







function Invoke-StagedScript {
    param(
        [string]$ScriptPath,
        [string[]]$ArgumentList = @()
    )
    $prev = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $output = & (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $ScriptPath @ArgumentList 2>&1
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prev
    }
    return [PSCustomObject]@{ ExitCode = $code; Output = ($output -join "`n") }
}

$tempRoot = New-TestFixtureRoot -NameHint "install-hooks-test"

try {
    $results += Run-Test -Name "Framework mode sets core.hooksPath to scripts/hooks" -Body {
        $repo = Join-Path $tempRoot "fw"
        git init -q $repo | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $repo "powershell") -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $repo "scripts/hooks") -Force | Out-Null
        Copy-Item $SCRIPT_SRC (Join-Path $repo "powershell/install-hooks.ps1") -Force

        $r = Invoke-StagedScript -ScriptPath (Join-Path $repo "powershell/install-hooks.ps1")
        Assert-Result -Name "exit 0" -Condition ($r.ExitCode -eq 0) -FailureMessage ("expected exit 0, got " + $r.ExitCode + ": " + $r.Output)
        $configured = (git -C $repo config --get core.hooksPath)
        Assert-Result -Name "hooksPath" -Condition ($configured -eq "scripts/hooks") -FailureMessage ("expected scripts/hooks, got '" + $configured + "'")
        Assert-Result -Name "prints Success" -Condition ($r.Output -match "Success: Set git core.hooksPath") -FailureMessage ("expected the Success line on a non-Quiet run, got: " + $r.Output)
    }

    $results += Run-Test -Name "Adopter mode sets core.hooksPath to .crucible/scripts/hooks" -Body {
        $repo = Join-Path $tempRoot "app"
        git init -q $repo | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $repo ".crucible/powershell") -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $repo ".crucible/scripts/hooks") -Force | Out-Null
        Copy-Item $SCRIPT_SRC (Join-Path $repo ".crucible/powershell/install-hooks.ps1") -Force

        $r = Invoke-StagedScript -ScriptPath (Join-Path $repo ".crucible/powershell/install-hooks.ps1")
        Assert-Result -Name "exit 0" -Condition ($r.ExitCode -eq 0) -FailureMessage ("expected exit 0, got " + $r.ExitCode + ": " + $r.Output)
        $configured = (git -C $repo config --get core.hooksPath)
        Assert-Result -Name "hooksPath" -Condition ($configured -eq ".crucible/scripts/hooks") -FailureMessage ("expected .crucible/scripts/hooks, got '" + $configured + "'")
    }

    $results += Run-Test -Name "Marks hooks executable on Unix (gates would silently skip otherwise)" -Body {
        $repo = Join-Path $tempRoot "execbit"
        git init -q $repo | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $repo "powershell") -Force | Out-Null
        $hooksDir = Join-Path $repo "scripts/hooks"
        New-Item -ItemType Directory -Path $hooksDir -Force | Out-Null
        Copy-Item $SCRIPT_SRC (Join-Path $repo "powershell/install-hooks.ps1") -Force

        # Simulate a hook committed on Windows (no executable bit, mode 100644).
        $hookFile = Join-Path $hooksDir "pre-commit"
        Set-Content -LiteralPath $hookFile -Value "#!/bin/sh`nexit 0`n" -NoNewline
        if (-not (Test-PlatformIsWindows)) {
            & chmod "644" $hookFile
        }

        $r = Invoke-StagedScript -ScriptPath (Join-Path $repo "powershell/install-hooks.ps1")
        Assert-Result -Name "exit 0" -Condition ($r.ExitCode -eq 0) -FailureMessage ("expected exit 0, got " + $r.ExitCode + ": " + $r.Output)

        if (Test-PlatformIsWindows) {
            # NTFS has no executable bit; nothing to assert beyond a clean run.
            Assert-Result -Name "windows no-op" -Condition $true -FailureMessage "unreachable"
        } else {
            & test -x $hookFile
            Assert-Result -Name "hook is executable" -Condition ($LASTEXITCODE -eq 0) -FailureMessage "expected pre-commit hook to be executable after install-hooks on Unix"
        }
    }

    $results += Run-Test -Name "Reports hooks in .git/hooks that core.hooksPath now shadows" -Body {
        # Setting core.hooksPath shadows .git/hooks rather than emptying it, so a hook
        # installed the old way stays on disk, stops running, and reads as coverage.
        # The framework repo carried exactly this: a pre-commit referencing
        # check-policy-drift.ps1, a gate deleted months earlier.
        $repo = Join-Path $tempRoot "shadowed"
        git init -q $repo | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $repo "powershell") -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $repo "scripts/hooks") -Force | Out-Null
        Copy-Item $SCRIPT_SRC (Join-Path $repo "powershell/install-hooks.ps1") -Force

        $gitHooks = Join-Path $repo ".git/hooks"
        New-Item -ItemType Directory -Path $gitHooks -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $gitHooks "pre-commit") -Value "#!/bin/sh`nexit 0`n" -NoNewline
        Set-Content -LiteralPath (Join-Path $gitHooks "pre-push") -Value "#!/bin/sh`nexit 0`n" -NoNewline
        # Ships with every git init and is inert by name; must not be reported.
        Set-Content -LiteralPath (Join-Path $gitHooks "commit-msg.sample") -Value "#!/bin/sh`nexit 0`n" -NoNewline

        $r = Invoke-StagedScript -ScriptPath (Join-Path $repo "powershell/install-hooks.ps1")
        Assert-Result -Name "exit 0" -Condition ($r.ExitCode -eq 0) -FailureMessage ("expected exit 0, got " + $r.ExitCode + ": " + $r.Output)
        Assert-Result -Name "counts the shadowed hooks" -Condition ($r.Output -match "2 hook file\(s\)") -FailureMessage ("expected a count of 2 shadowed hooks, got: " + $r.Output)
        Assert-Result -Name "names pre-commit" -Condition ($r.Output -match "(?m)^\s+- pre-commit\s*$") -FailureMessage ("expected pre-commit to be named, got: " + $r.Output)
        Assert-Result -Name "names pre-push" -Condition ($r.Output -match "(?m)^\s+- pre-push\s*$") -FailureMessage ("expected pre-push to be named, got: " + $r.Output)
        Assert-Result -Name "does not report the .sample file" -Condition ($r.Output -notmatch "commit-msg\.sample") -FailureMessage ("a .sample file was reported as shadowed: " + $r.Output)
        Assert-Result -Name "leaves the shadowed hooks in place" `
            -Condition ((Test-Path -LiteralPath (Join-Path $gitHooks "pre-commit")) -and (Test-Path -LiteralPath (Join-Path $gitHooks "pre-push"))) `
            -FailureMessage "install-hooks deleted a hook it only had standing to report"
    }

    $results += Run-Test -Name "Says nothing when .git/hooks holds only samples" -Body {
        # Guards the warning against firing on the normal case, which is what would
        # train a reader to ignore it.
        $repo = Join-Path $tempRoot "nothingshadowed"
        git init -q $repo | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $repo "powershell") -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $repo "scripts/hooks") -Force | Out-Null
        Copy-Item $SCRIPT_SRC (Join-Path $repo "powershell/install-hooks.ps1") -Force

        $gitHooks = Join-Path $repo ".git/hooks"
        Get-ChildItem -LiteralPath $gitHooks -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -notlike "*.sample" } |
            Remove-Item -Force -ErrorAction SilentlyContinue

        $r = Invoke-StagedScript -ScriptPath (Join-Path $repo "powershell/install-hooks.ps1")
        Assert-Result -Name "exit 0" -Condition ($r.ExitCode -eq 0) -FailureMessage ("expected exit 0, got " + $r.ExitCode + ": " + $r.Output)
        Assert-Result -Name "no shadowed-hook warning" -Condition ($r.Output -notmatch "shadowed by core.hooksPath") -FailureMessage ("expected no warning on a clean repo, got: " + $r.Output)
    }

    $results += Run-Test -Name "Quiet suppresses host messages and still sets hooksPath" -Body {
        $repo = Join-Path $tempRoot "quiet"
        git init -q $repo | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $repo "powershell") -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $repo "scripts/hooks") -Force | Out-Null
        Copy-Item $SCRIPT_SRC (Join-Path $repo "powershell/install-hooks.ps1") -Force

        $gitHooks = Join-Path $repo ".git/hooks"
        New-Item -ItemType Directory -Path $gitHooks -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $gitHooks "pre-commit") -Value "#!/bin/sh`nexit 0`n" -NoNewline

        $r = Invoke-StagedScript -ScriptPath (Join-Path $repo "powershell/install-hooks.ps1") -ArgumentList @("-Quiet")
        Assert-Result -Name "exit 0" -Condition ($r.ExitCode -eq 0) -FailureMessage ("expected exit 0, got " + $r.ExitCode + ": " + $r.Output)
        $configured = (git -C $repo config --get core.hooksPath)
        Assert-Result -Name "hooksPath" -Condition ($configured -eq "scripts/hooks") -FailureMessage ("expected scripts/hooks, got '" + $configured + "'")
        Assert-Result -Name "no Success line" -Condition ($r.Output -notmatch "Success: Set git core.hooksPath") -FailureMessage ("Quiet still printed Success: " + $r.Output)
        Assert-Result -Name "no shadowed-hook warning" -Condition ($r.Output -notmatch "shadowed by core.hooksPath") -FailureMessage ("Quiet still printed the shadowed-hook warning: " + $r.Output)
        Assert-Result -Name "leaves the adopter hook in place" -Condition (Test-Path -LiteralPath (Join-Path $gitHooks "pre-commit")) -FailureMessage "Quiet install deleted a hook it only had standing to report"
    }

    $results += Run-Test -Name "Throws when no .git is present" -Body {
        $repo = Join-Path $tempRoot "nogit"
        New-Item -ItemType Directory -Path (Join-Path $repo "powershell") -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $repo "scripts/hooks") -Force | Out-Null
        Copy-Item $SCRIPT_SRC (Join-Path $repo "powershell/install-hooks.ps1") -Force

        $r = Invoke-StagedScript -ScriptPath (Join-Path $repo "powershell/install-hooks.ps1")
        Assert-Result -Name "nonzero exit" -Condition ($r.ExitCode -ne 0) -FailureMessage "expected failure when no .git directory exists"
        Assert-Result -Name "message" -Condition ($r.Output -match "Not a git repository") -FailureMessage ("expected 'Not a git repository', got: " + $r.Output)
    }

    $results += Run-Test -Name "Throws when hooks directory is missing" -Body {
        $repo = Join-Path $tempRoot "nohooks"
        git init -q $repo | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $repo "powershell") -Force | Out-Null
        Copy-Item $SCRIPT_SRC (Join-Path $repo "powershell/install-hooks.ps1") -Force

        $r = Invoke-StagedScript -ScriptPath (Join-Path $repo "powershell/install-hooks.ps1")
        Assert-Result -Name "nonzero exit" -Condition ($r.ExitCode -ne 0) -FailureMessage "expected failure when hooks dir is absent"
        Assert-Result -Name "message" -Condition ($r.Output -match "Hooks directory not found") -FailureMessage ("expected 'Hooks directory not found', got: " + $r.Output)
    }
}
finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

if ($results -contains $false) {
    Write-Host "`nSOME TESTS FAILED" -ForegroundColor Red
    exit 1
}

Write-Host ("`nALL TESTS PASSED (" + $results.Count + " tests)") -ForegroundColor Green
exit 0
