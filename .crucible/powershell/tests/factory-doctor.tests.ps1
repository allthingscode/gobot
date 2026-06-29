$ErrorActionPreference = "Stop"
$REPO_ROOT = (Resolve-Path -Path "$PSScriptRoot/../..").Path
. (Join-Path $PSScriptRoot '_harness.ps1')
. (Join-Path $REPO_ROOT "powershell/lib/platform.ps1")
$DOCTOR_SCRIPT = Join-Path $REPO_ROOT "powershell/factory-doctor.ps1"

$results = @()










function Write-DoctorFixture {
    param([string]$ProjectRoot)
    New-Item -ItemType Directory -Path (Join-Path $ProjectRoot ".crucible") -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $ProjectRoot "scripts/hooks") -Force | Out-Null

    @(
        'crucible_root: ".crucible"',
        'crucible_version: "test"',
        'crucible_install_commit: "test"',
        '',
        'project:',
        '  name: "Doctor Test"',
        '  description: "Synthetic doctor fixture."',
        '  default_branch: "main"',
        '',
        'paths:',
        '  backlog: .crucible/backlog',
        '  session: .crucible/session',
        '  workspaces: .crucible/.agent-workspaces',
        '  prompts: .crucible/prompts',
        '',
        'verification:',
        '  quick:',
        '    - name: test',
        "      command: " + (Get-PwshCommand) + " -NoProfile -Command `"exit 0`""
    ) | Set-Content -LiteralPath (Join-Path $ProjectRoot ".crucible/config.yaml") -Encoding UTF8

    @(
        '#!/bin/sh',
        'exit 0'
    ) | Set-Content -LiteralPath (Join-Path $ProjectRoot "scripts/hooks/pre-commit") -Encoding UTF8
}

function Write-FakeGh {
    param([string]$BinDir)

    New-Item -ItemType Directory -Path $BinDir -Force | Out-Null
    if (Test-PlatformIsWindows) {
        @'
@echo off
if "%1"=="auth" (
  if "%2"=="status" (
    echo You are not logged into any GitHub hosts. 1>&2
    exit /b 1
  )
)
echo fake gh
exit /b 0
'@ | Set-Content -LiteralPath (Join-Path $BinDir "gh.cmd") -Encoding ASCII
    } else {
        # A .cmd stub is invisible to PATH lookup on Linux/macOS, so the gh tests
        # would silently fall through to the host's real gh (or none). Write a real
        # executable 'gh' so the stub is exercised hermetically on every platform.
        $ghPath = Join-Path $BinDir "gh"
        (@'
#!/usr/bin/env bash
if [ "$1" = "auth" ] && [ "$2" = "status" ]; then
  echo "You are not logged into any GitHub hosts." 1>&2
  exit 1
fi
echo "fake gh"
exit 0
'@ -replace "`r`n", "`n") | Set-Content -LiteralPath $ghPath -Encoding ASCII
        & chmod "+x" $ghPath
    }
}

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("crucible-factory-doctor-test-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

try {
    $results += Run-Test -Name "Doctor emits structured results" -Body {
        $projectRoot = Join-Path $tempRoot "project"
        Write-DoctorFixture -ProjectRoot $projectRoot

        $res = Invoke-ExternalCommand {
            & (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $DOCTOR_SCRIPT -ProjectRoot $projectRoot
        }
        $output = $res.Output -join "`n"

        Assert-Result -Name "readiness header" -Condition ($output -match "\[DOCTOR\] Factory Readiness Check") -FailureMessage "doctor did not emit the readiness header. Output:`n$output"
        Assert-Result -Name "pass section" -Condition ($output -match "PASS \(") -FailureMessage "doctor did not emit a PASS section. Output:`n$output"
        Assert-Result -Name "warn section" -Condition ($output -match "WARN \(") -FailureMessage "doctor did not emit a WARN section. Output:`n$output"
        Assert-Result -Name "fail section" -Condition ($output -match "FAIL \(") -FailureMessage "doctor did not emit a FAIL section. Output:`n$output"
        Assert-Result -Name "at least one pass" -Condition ($output -match "PASS \([1-9]") -FailureMessage "doctor emitted no passing checks. Output:`n$output"
        Assert-Result -Name "result line" -Condition ($output -match "\[DOCTOR\] Result:") -FailureMessage "doctor did not run to completion. Output:`n$output"
        Assert-Result -Name "adopter mode" -Condition ($output -match "Mode: adopter") -FailureMessage "doctor did not detect adopter mode for a project with .crucible/config.yaml. Output:`n$output"
        Assert-Result -Name "valid adopter install is ready" -Condition ($output -match "\[DOCTOR\] Result: READY") -FailureMessage "valid adopter fixture should be READY. Output:`n$output"
    }

    $results += Run-Test -Name "Adopter without framework toolchain is READY (no Go required)" -Body {
        $projectRoot = Join-Path $tempRoot "python-project"
        New-Item -ItemType Directory -Path (Join-Path $projectRoot ".crucible") -Force | Out-Null
        @(
            'crucible_root: ".crucible"',
            'project:',
            '  name: "Py"',
            '  default_branch: "main"',
            'verification:',
            '  quick:',
            '    - name: test',
            '      command: pytest -q'
        ) | Set-Content -LiteralPath (Join-Path $projectRoot ".crucible/config.yaml") -Encoding UTF8

        $res = Invoke-ExternalCommand {
            & (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $DOCTOR_SCRIPT -ProjectRoot $projectRoot
        }
        $output = $res.Output -join "`n"

        Assert-Result -Name "python adopter is ready" -Condition ($output -match "\[DOCTOR\] Result: READY") -FailureMessage "a non-Go adopter project should be READY without the Go toolchain. Output:`n$output"
        Assert-Result -Name "no Go critical check" -Condition (-not ($output -match "\[go\.(cli|version)\]")) -FailureMessage "adopter mode should not run the framework Go toolchain check. Output:`n$output"
        Assert-Result -Name "no golangci critical check" -Condition (-not ($output -match "\[golangci-lint")) -FailureMessage "adopter mode should not run the framework golangci-lint check. Output:`n$output"
    }

    $results += Run-Test -Name "Doctor reports unauthenticated gh as advisory, stays READY" -Body {
        $projectRoot = Join-Path $tempRoot "unauth-project"
        $binDir = Join-Path $tempRoot "fake-bin"
        Write-DoctorFixture -ProjectRoot $projectRoot
        Write-FakeGh -BinDir $binDir

        $originalPath = $env:PATH
        try {
            $env:PATH = $binDir + [System.IO.Path]::PathSeparator + $originalPath
            $res = Invoke-ExternalCommand {
                & (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $DOCTOR_SCRIPT -ProjectRoot $projectRoot
            }
        } finally {
            $env:PATH = $originalPath
        }
        $output = $res.Output -join "`n"

        Assert-Result -Name "readiness header after gh failure" -Condition ($output -match "\[DOCTOR\] Factory Readiness Check") -FailureMessage "doctor aborted before reporting. Output:`n$output"
        Assert-Result -Name "gh auth surfaced" -Condition ($output -match "\[gh\.auth\].*not authenticated") -FailureMessage "doctor did not surface the gh auth state. Output:`n$output"
        Assert-Result -Name "gh auth is advisory, not blocking" -Condition ($output -match "\[DOCTOR\] Result: READY") -FailureMessage "unauthenticated gh must not block an adopter install. Output:`n$output"
    }

    $results += Run-Test -Name "Doctor reports missing gh as advisory, stays READY" -Body {
        $projectRoot = Join-Path $tempRoot "no-gh-project"
        Write-DoctorFixture -ProjectRoot $projectRoot

        # Make gh unresolvable without disturbing the PowerShell host. The two OSes
        # need different tactics: on Windows gh has its own dir, so drop only PATH
        # entries that contain a gh executable (System32 + host stay put); on Linux gh
        # and pwsh share /usr/bin, so expose just a host symlink in a clean dir instead.
        $originalPath = $env:PATH
        if (Test-PlatformIsWindows) {
            $sep = [System.IO.Path]::PathSeparator
            $ghNames = @("gh.exe", "gh.cmd", "gh.bat", "gh")
            $scopedPath = (($originalPath.Split($sep) | Where-Object {
                $d = $_
                ($d -ne "") -and -not ($ghNames | Where-Object {
                    Test-Path -LiteralPath (Join-Path $d $_) -ErrorAction SilentlyContinue
                })
            }) -join $sep)
        } else {
            $cleanBin = Join-Path $tempRoot ("hostbin-" + [guid]::NewGuid().ToString("N"))
            New-Item -ItemType Directory -Path $cleanBin -Force | Out-Null
            # Expose the tools doctor invokes (git/go/sh + the host) but NOT gh, so it runs
            # to completion with gh genuinely absent.
            foreach ($tool in @((Get-PwshCommand), "git", "go", "sh")) {
                $resolved = Get-Command $tool -ErrorAction SilentlyContinue
                if ($resolved) {
                    New-Item -ItemType SymbolicLink -Path (Join-Path $cleanBin $tool) -Target $resolved.Source | Out-Null
                }
            }
            $scopedPath = $cleanBin
        }

        try {
            $env:PATH = $scopedPath
            $res = Invoke-ExternalCommand {
                & (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $DOCTOR_SCRIPT -ProjectRoot $projectRoot
            }
        } finally {
            $env:PATH = $originalPath
        }
        $output = $res.Output -join "`n"

        Assert-Result -Name "gh absence surfaced" -Condition ($output -match "\[gh\.cli\].*not installed") -FailureMessage "doctor did not surface that gh is absent. Output:`n$output"
        Assert-Result -Name "no gh.auth when gh absent" -Condition (-not ($output -match "\[gh\.auth\]")) -FailureMessage "doctor should not emit a gh.auth result when gh is absent. Output:`n$output"
        Assert-Result -Name "missing gh is advisory, not blocking" -Condition ($output -match "\[DOCTOR\] Result: READY") -FailureMessage "absent gh must not block an adopter install. Output:`n$output"
    }

    $results += Run-Test -Name "Doctor degrades gracefully when git is absent" -Body {
        $projectRoot = Join-Path $tempRoot "no-git-project"
        Write-DoctorFixture -ProjectRoot $projectRoot

        # git is used to read core.hooksPath; a missing git must degrade to a structured
        # advisory, never crash the run. Same per-OS scoping as the gh case, excluding git.
        $originalPath = $env:PATH
        if (Test-PlatformIsWindows) {
            $sep = [System.IO.Path]::PathSeparator
            $gitNames = @("git.exe", "git.cmd", "git.bat", "git")
            $scopedPath = (($originalPath.Split($sep) | Where-Object {
                $d = $_
                ($d -ne "") -and -not ($gitNames | Where-Object {
                    Test-Path -LiteralPath (Join-Path $d $_) -ErrorAction SilentlyContinue
                })
            }) -join $sep)
        } else {
            $cleanBin = Join-Path $tempRoot ("nogit-" + [guid]::NewGuid().ToString("N"))
            New-Item -ItemType Directory -Path $cleanBin -Force | Out-Null
            foreach ($tool in @((Get-PwshCommand), "go", "sh", "gh")) {
                $resolved = Get-Command $tool -ErrorAction SilentlyContinue
                if ($resolved) {
                    New-Item -ItemType SymbolicLink -Path (Join-Path $cleanBin $tool) -Target $resolved.Source | Out-Null
                }
            }
            $scopedPath = $cleanBin
        }

        try {
            $env:PATH = $scopedPath
            $res = Invoke-ExternalCommand {
                & (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $DOCTOR_SCRIPT -ProjectRoot $projectRoot
            }
        } finally {
            $env:PATH = $originalPath
        }
        $output = $res.Output -join "`n"

        Assert-Result -Name "doctor did not crash without git" -Condition ($output -match "\[DOCTOR\] Factory Readiness Check") -FailureMessage "doctor produced no readiness output when git was absent. Output:`n$output"
        Assert-Result -Name "git absence surfaced" -Condition ($output -match "\[git\.cli\]") -FailureMessage "doctor did not surface that git is absent. Output:`n$output"
        Assert-Result -Name "missing git is advisory, not blocking" -Condition ($output -match "\[DOCTOR\] Result: READY") -FailureMessage "absent git should degrade to advisory, not block. Output:`n$output"
    }

    # Hermetic git fixture acting as the framework source. The staleness check
    # must not depend on the ambient repo: in an adopter, $REPO_ROOT is the
    # .crucible bundle dir (no .git, no `main`), so leaning on it makes these
    # tests pass only in the framework repo. A throwaway repo makes them portable.
    function Initialize-FrameworkFixture {
        param([string]$Path, [int]$Commits = 3)
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
        Push-Location $Path
        try {
            git init -b main --quiet
            git config user.name "Test"
            git config user.email "test@example.com"
            git config commit.gpgSign false
            $shas = @()
            for ($i = 1; $i -le $Commits; $i++) {
                git commit --allow-empty -m "commit $i" --quiet
                $shas += (git rev-parse HEAD).Trim()
            }
            return [pscustomobject]@{ Head = $shas[-1]; OlderCommit = $shas[0] }
        } finally {
            Pop-Location
        }
    }

    $gitSupportsInitB = $true
    $gitProbe = Join-Path $tempRoot "git-initb-probe"
    New-Item -ItemType Directory -Path $gitProbe -Force | Out-Null
    Push-Location $gitProbe
    try { git init -b main --quiet 2>$null; if ($LASTEXITCODE -ne 0) { $gitSupportsInitB = $false } } finally { Pop-Location }

    $results += Run-Test -Name "Doctor reports Codex CLI as advisory, never blocks READY" -Body {
        $projectRoot = Join-Path $tempRoot "codex-probe-project"
        Write-DoctorFixture -ProjectRoot $projectRoot

        $res = Invoke-ExternalCommand {
            & (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $DOCTOR_SCRIPT -ProjectRoot $projectRoot
        }
        $output = $res.Output -join "`n"

        Assert-Result -Name "codex.cli check present" -Condition ($output -match "\[codex\.cli\]") -FailureMessage "doctor did not emit a codex.cli check. Output:`n$output"
        Assert-Result -Name "codex.cli is advisory only" -Condition (-not ($output -match "\[codex\.cli\].*severity: critical")) -FailureMessage "codex.cli must never be critical. Output:`n$output"
        Assert-Result -Name "codex absence/presence does not block" -Condition ($output -match "\[DOCTOR\] Result: READY") -FailureMessage "codex probe must not flip readiness. Output:`n$output"
    }

    $results += Run-Test -Name "Doctor checks for bundle staleness and warns when lagging HEAD" -Body {
        if (-not $gitSupportsInitB) { Write-Host "SKIPPED: git init -b requires git >= 2.28" -ForegroundColor Yellow; return }
        $projectRoot = Join-Path $tempRoot "stale-project"
        New-Item -ItemType Directory -Path (Join-Path $projectRoot ".crucible") -Force | Out-Null

        $fwPath = Join-Path $tempRoot "fw-stale"
        $fw = Initialize-FrameworkFixture -Path $fwPath

        @(
            'crucible_root: ".crucible"',
            'crucible_version: "1.0.0"',
            "crucible_install_commit: `"$($fw.OlderCommit)`"",
            'project:',
            '  name: "Stale App"',
            '  default_branch: "main"',
            'paths:',
            '  backlog: .crucible/backlog',
            '  session: .crucible/session',
            '  workspaces: .crucible/.agent-workspaces',
            '  prompts: .crucible/prompts',
            'verification:',
            '  quick:',
            '    - name: test',
            '      command: cmd /c exit 0'
        ) | Set-Content -LiteralPath (Join-Path $projectRoot ".crucible/config.yaml") -Encoding UTF8

        $oldDevRoot = $env:CRUCIBLE_DEV_ROOT
        $env:CRUCIBLE_DEV_ROOT = $fwPath
        try {
            $res = Invoke-ExternalCommand {
                & (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $DOCTOR_SCRIPT -ProjectRoot $projectRoot
            }
        } finally {
            $env:CRUCIBLE_DEV_ROOT = $oldDevRoot
        }
        $output = $res.Output -join "`n"

        Assert-Result -Name "staleness check warn status" -Condition ($output -match "\[bundle\.staleness\].*lags framework HEAD") -FailureMessage "doctor did not warn about staleness. Output:`n$output"
    }

    $results += Run-Test -Name "Doctor checks for bundle staleness and stays silent when up-to-date" -Body {
        if (-not $gitSupportsInitB) { Write-Host "SKIPPED: git init -b requires git >= 2.28" -ForegroundColor Yellow; return }
        $projectRoot = Join-Path $tempRoot "current-project"
        New-Item -ItemType Directory -Path (Join-Path $projectRoot ".crucible") -Force | Out-Null

        $fwPath = Join-Path $tempRoot "fw-current"
        $fw = Initialize-FrameworkFixture -Path $fwPath

        @(
            'crucible_root: ".crucible"',
            'crucible_version: "1.0.0"',
            "crucible_install_commit: `"$($fw.Head)`"",
            'project:',
            '  name: "Current App"',
            '  default_branch: "main"',
            'paths:',
            '  backlog: .crucible/backlog',
            '  session: .crucible/session',
            '  workspaces: .crucible/.agent-workspaces',
            '  prompts: .crucible/prompts',
            'verification:',
            '  quick:',
            '    - name: test',
            '      command: cmd /c exit 0'
        ) | Set-Content -LiteralPath (Join-Path $projectRoot ".crucible/config.yaml") -Encoding UTF8

        $oldDevRoot = $env:CRUCIBLE_DEV_ROOT
        $env:CRUCIBLE_DEV_ROOT = $fwPath
        try {
            $res = Invoke-ExternalCommand {
                & (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $DOCTOR_SCRIPT -ProjectRoot $projectRoot
            }
        } finally {
            $env:CRUCIBLE_DEV_ROOT = $oldDevRoot
        }
        $output = $res.Output -join "`n"

        Assert-Result -Name "staleness check pass status" -Condition ($output -match "\[bundle\.staleness\].*up-to-date") -FailureMessage "doctor did not pass staleness when up-to-date. Output:`n$output"
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
