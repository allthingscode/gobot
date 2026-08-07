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
    param([string]$ScriptPath)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $output = & (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $ScriptPath 2>&1
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prev
    }
    return [PSCustomObject]@{ ExitCode = $code; Output = ($output -join "`n") }
}

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("crucible-install-hooks-test-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

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
