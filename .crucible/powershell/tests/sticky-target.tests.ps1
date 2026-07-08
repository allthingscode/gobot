# Verifies Resolve-StickyTarget (factory-lib.ps1): a per-task specialist target chosen once
# via an explicit -Target persists across later phase -Init calls that omit -Target, so the
# emitted [NEXT SESSION COMMAND]/[RECOMMENDED MODEL] stays on the chosen specialist.

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$REPO_ROOT = (Resolve-Path -Path "$PSScriptRoot/../..").Path
. (Join-Path $PSScriptRoot '_harness.ps1')
. (Join-Path $REPO_ROOT "powershell/factory-lib.ps1")

$results = @()
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("crucible-sticky-target-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

function New-CaseDir {
    $d = Join-Path $tempRoot ([guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $d -Force | Out-Null
    return $d
}

try {
    $results += Run-Test -Name "explicit target is persisted and returned" -Body {
        $sd = New-CaseDir
        $r = Resolve-StickyTarget -TaskId "C-1" -SessionDir $sd -Target "codex" -Explicit $true
        Assert-Result -Name "returns codex" -Condition ($r -eq "codex") -FailureMessage "got $r"
        $stateFile = Join-Path $sd "C-1/target.txt"
        Assert-Result -Name "file written" -Condition (Test-Path -LiteralPath $stateFile) -FailureMessage "target.txt missing"
        Assert-Result -Name "file content" -Condition (((Get-Content -LiteralPath $stateFile -Raw).Trim()) -eq "codex") -FailureMessage "bad content"
    }

    $results += Run-Test -Name "omitted target reloads the stored value" -Body {
        $sd = New-CaseDir
        Resolve-StickyTarget -TaskId "C-2" -SessionDir $sd -Target "codex" -Explicit $true | Out-Null
        $r = Resolve-StickyTarget -TaskId "C-2" -SessionDir $sd -Target "agent" -Explicit $false
        Assert-Result -Name "reloaded codex" -Condition ($r -eq "codex") -FailureMessage "got $r"
    }

    $results += Run-Test -Name "omitted target with no stored value returns the passed-in default" -Body {
        $sd = New-CaseDir
        $r = Resolve-StickyTarget -TaskId "C-3" -SessionDir $sd -Target "agent" -Explicit $false
        Assert-Result -Name "returns agent" -Condition ($r -eq "agent") -FailureMessage "got $r"
    }

    $results += Run-Test -Name "explicit target overwrites a previously stored value" -Body {
        $sd = New-CaseDir
        Resolve-StickyTarget -TaskId "C-4" -SessionDir $sd -Target "codex" -Explicit $true | Out-Null
        $r = Resolve-StickyTarget -TaskId "C-4" -SessionDir $sd -Target "claude" -Explicit $true
        Assert-Result -Name "returns claude" -Condition ($r -eq "claude") -FailureMessage "got $r"
        $stored = (Get-Content -LiteralPath (Join-Path $sd "C-4/target.txt") -Raw).Trim()
        Assert-Result -Name "stored claude" -Condition ($stored -eq "claude") -FailureMessage "got $stored"
    }

    $results += Run-Test -Name "empty TaskId is a no-op passthrough" -Body {
        $sd = New-CaseDir
        $r = Resolve-StickyTarget -TaskId "" -SessionDir $sd -Target "codex" -Explicit $true
        Assert-Result -Name "returns codex" -Condition ($r -eq "codex") -FailureMessage "got $r"
        Assert-Result -Name "nothing written" -Condition (-not (Test-Path -LiteralPath (Join-Path $sd "target.txt"))) -FailureMessage "unexpected file"
    }

    $results += Run-Test -Name "unrecognized stored value is ignored" -Body {
        $sd = New-CaseDir
        New-Item -ItemType Directory -Path (Join-Path $sd "C-5") -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $sd "C-5/target.txt") -Value "bogus" -Encoding UTF8
        $r = Resolve-StickyTarget -TaskId "C-5" -SessionDir $sd -Target "agent" -Explicit $false
        Assert-Result -Name "falls back to agent" -Condition ($r -eq "agent") -FailureMessage "got $r"
    }
} finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

if ($results -contains $false) {
    Write-Host "`nSOME TESTS FAILED" -ForegroundColor Red
    exit 1
}

Write-Host ("`nALL TESTS PASSED (" + $results.Count + " tests)") -ForegroundColor Green
exit 0
