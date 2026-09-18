$ErrorActionPreference = "Stop"
$REPO_ROOT = (Resolve-Path -Path "$PSScriptRoot/../..").Path
. (Join-Path $PSScriptRoot '_harness.ps1')
. (Join-Path $REPO_ROOT "powershell/lib/platform.ps1")
$DOCTOR_SCRIPT = Join-Path $REPO_ROOT "powershell/crucible-doctor.ps1"

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

$tempRoot = New-TestFixtureRoot -NameHint "crucible-doctor-test"

try {
    $results += Run-Test -Name "Doctor emits structured results" -Body {
        $projectRoot = Join-Path $tempRoot "project"
        Write-DoctorFixture -ProjectRoot $projectRoot

        $res = Invoke-ExternalCommand {
            & (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $DOCTOR_SCRIPT -ProjectRoot $projectRoot
        }
        $output = $res.Output -join "`n"

        Assert-Result -Name "readiness header" -Condition ($output -match "\[DOCTOR\] Crucible Readiness Check") -FailureMessage "doctor did not emit the readiness header. Output:`n$output"
        Assert-Result -Name "pass section" -Condition ($output -match "PASS \(") -FailureMessage "doctor did not emit a PASS section. Output:`n$output"
        Assert-Result -Name "warn section" -Condition ($output -match "WARN \(") -FailureMessage "doctor did not emit a WARN section. Output:`n$output"
        Assert-Result -Name "fail section" -Condition ($output -match "FAIL \(") -FailureMessage "doctor did not emit a FAIL section. Output:`n$output"
        Assert-Result -Name "at least one pass" -Condition ($output -match "PASS \([1-9]") -FailureMessage "doctor emitted no passing checks. Output:`n$output"
        Assert-Result -Name "result line" -Condition ($output -match "\[DOCTOR\] Result:") -FailureMessage "doctor did not run to completion. Output:`n$output"
        Assert-Result -Name "adopter mode" -Condition ($output -match "Mode: adopter") -FailureMessage "doctor did not detect adopter mode for a project with .crucible/config.yaml. Output:`n$output"
        Assert-Result -Name "valid adopter install is ready" -Condition ($output -match "\[DOCTOR\] Result: READY") -FailureMessage "valid adopter fixture should be READY. Output:`n$output"

        # TODO item 100: crucible.required-scripts is structured, machine-readable output
        # nothing named in any test, so item 51b's factory.required-scripts -> this rename
        # could have gone through with a typo and nothing would have failed. This repo's
        # own powershell/ directory genuinely has every required script, so the pass branch
        # is real doctor output rather than a source-text guess.
        Assert-Result -Name "required-scripts check ID present on pass" -Condition ($output -match "\[crucible\.required-scripts\]") -FailureMessage "doctor did not emit the crucible.required-scripts check. Output:`n$output"
        # Asserted as membership of the PASS section, not by the detail sentence beside the
        # id. The section a check lands in is the contract; the sentence is a message, and
        # pinning it would make the suite refuse a reworded detail line for no gain. See
        # CONTRIBUTING.md, "Which output strings are contracts".
        $lines = @($output -split "\r?\n")
        $passStart = -1
        $warnStart = -1
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($passStart -lt 0 -and $lines[$i] -match "^PASS \(") { $passStart = $i }
            if ($passStart -ge 0 -and $warnStart -lt 0 -and $lines[$i] -match "^WARN \(") { $warnStart = $i }
        }
        Assert-Result -Name "the PASS section was bracketed" -Condition ($passStart -ge 0 -and $warnStart -gt $passStart) -FailureMessage "could not bracket the doctor's PASS section, so the membership assertion below would prove nothing. Output:`n$output"
        $passSection = ($lines[$passStart..($warnStart - 1)]) -join "`n"
        Assert-Result -Name "required-scripts is listed under PASS when every script is present" -Condition ($passSection -match "\[crucible\.required-scripts\]") -FailureMessage "crucible.required-scripts did not appear in the doctor's PASS section. Output:`n$output"
    }

    $results += Run-Test -Name "Doctor's required-scripts check fails and blocks readiness when a sibling script is missing" -Body {
        # required-scripts resolves each path with Join-Path $PSScriptRoot $scriptName inside
        # crucible-doctor.ps1 itself (line ~505), i.e. relative to the doctor script's own
        # directory, not -ProjectRoot. So the fail branch cannot be reached by pointing a
        # normal fixture at the real doctor; it needs a doctor copy missing one of its own
        # required siblings. Copying the whole powershell/ tree (lib/ included) is what makes
        # this real doctor output instead of a source-text assertion: crucible-lib.ps1 and its
        # dot-sourced chain must resolve for the doctor to run at all.
        $isolatedRoot = Join-Path $tempRoot "isolated-doctor"
        New-Item -ItemType Directory -Path $isolatedRoot -Force | Out-Null
        $sourceDir = Join-Path $REPO_ROOT "powershell"
        foreach ($file in @(Get-ChildItem -LiteralPath $sourceDir -Filter "*.ps1" -File)) {
            Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $isolatedRoot $file.Name)
        }
        Copy-Item -LiteralPath (Join-Path $sourceDir "lib") -Destination (Join-Path $isolatedRoot "lib") -Recurse

        $missingScript = "validate-backlog.ps1"
        Remove-Item -LiteralPath (Join-Path $isolatedRoot $missingScript) -Force

        $projectRoot = Join-Path $tempRoot "isolated-doctor-project"
        Write-DoctorFixture -ProjectRoot $projectRoot

        $isolatedDoctorScript = Join-Path $isolatedRoot "crucible-doctor.ps1"
        $res = Invoke-ExternalCommand {
            & (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $isolatedDoctorScript -ProjectRoot $projectRoot
        }
        $output = $res.Output -join "`n"

        $missingPattern = "\[crucible\.required-scripts\] Missing required script\(s\): " + [regex]::Escape($missingScript)
        Assert-Result -Name "required-scripts check fails when a sibling script is missing" -Condition ($output -match $missingPattern) -FailureMessage "doctor did not report the missing required script under its check ID. Output:`n$output"
        Assert-Result -Name "missing required script blocks readiness" -Condition ($output -match "\[DOCTOR\] Result: NOT READY") -FailureMessage "a missing required script must be a critical failure. Output:`n$output"
    }

    $results += Run-Test -Name "Doctor's -Check identifier literals match the known set" -Body {
        # Item 100 asks whether every -Check identifier in this file is equally unpinned as
        # crucible.required-scripts was. Answer: partially - a handful (gh.cli, gh.auth,
        # go.cli/version, git.cli, codex.cli, bundle.staleness) are incidentally matched by
        # other assertions above, but most are not, and none is asserted as a deliberate,
        # complete inventory anywhere.
        #
        # This is a source-text assertion, not real doctor output, and that is a deliberate
        # fallback rather than the preferred shape: exercising every one of these live would
        # mean reproducing missing-tool, missing-git, stale-bundle and gitignore/line-ending
        # violation environments across BOTH framework and adopter mode inside one test, which
        # is most of this file's fixture matrix duplicated a second time just to enumerate
        # strings. A complete inventory of the literals is cheaper and just as effective
        # against the failure item 100 is about: a rename that only a human reading the
        # console would notice. One assertion per literal would also work but cost one test
        # per ID for no extra safety over asserting the whole set at once.
        $source = Get-Content -LiteralPath $DOCTOR_SCRIPT -Raw

        $staticIds = New-Object System.Collections.Generic.List[string]
        foreach ($m in [regex]::Matches($source, '-Check\s+"([^"]+)"')) {
            $staticIds.Add($m.Groups[1].Value) | Out-Null
        }
        $dynamicPrefixes = New-Object System.Collections.Generic.List[string]
        foreach ($m in [regex]::Matches($source, '-Check\s+\("([^"]+)"\s*\+')) {
            $dynamicPrefixes.Add($m.Groups[1].Value) | Out-Null
        }

        $actualStatic = @($staticIds | Sort-Object -Unique)
        $actualDynamic = @($dynamicPrefixes | Sort-Object -Unique)

        Assert-Result -Name "at least one -Check literal was found" -Condition ($actualStatic.Count -gt 0) -FailureMessage "regex extraction found zero -Check string literals; the pattern is broken, not the source"

        # crucible.required-scripts is deliberately in this list too: the assertions above
        # pin its behavior, this one pins that its name has not silently changed underneath
        # them, which a behavior-only assertion cannot see if the check ID and its detail
        # text were renamed together in a way that still matches a loose detail-text regex.
        $expectedStatic = @(
            "bundle.root",
            "bundle.staleness",
            "codex.cli",
            "config.parse",
            "crucible.required-scripts",
            "gh.auth",
            "gh.cli",
            "git.cli",
            "gitignore.conformance",
            "go.cli",
            "go.version",
            "golangci-lint.cli",
            "golangci-lint.version",
            "hooks.pre-commit",
            "lineendings.conformance",
            "powershell.runtime",
            "verification.tools"
        )
        $expectedDynamic = @("verification.tool.")

        $missingStatic = @($expectedStatic | Where-Object { -not ($actualStatic -ccontains $_) })
        $extraStatic = @($actualStatic | Where-Object { -not ($expectedStatic -ccontains $_) })
        Assert-Result -Name "static check-ID set matches the recorded inventory" -Condition ($missingStatic.Count -eq 0 -and $extraStatic.Count -eq 0) -FailureMessage ("check-ID literals changed. missing: [" + ($missingStatic -join ", ") + "] extra: [" + ($extraStatic -join ", ") + "]. If this is a deliberate rename or addition, update the expected list in this test alongside it.")

        $missingDynamic = @($expectedDynamic | Where-Object { -not ($actualDynamic -ccontains $_) })
        $extraDynamic = @($actualDynamic | Where-Object { -not ($expectedDynamic -ccontains $_) })
        Assert-Result -Name "dynamic check-ID prefix set matches the recorded inventory" -Condition ($missingDynamic.Count -eq 0 -and $extraDynamic.Count -eq 0) -FailureMessage ("dynamic check-ID prefix changed. missing: [" + ($missingDynamic -join ", ") + "] extra: [" + ($extraDynamic -join ", ") + "]")
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

    $results += Run-Test -Name "Doctor survives folded-scalar verification command (no illegal-path crash)" -Body {
        $projectRoot = Join-Path $tempRoot "folded-scalar-project"
        New-Item -ItemType Directory -Path (Join-Path $projectRoot ".crucible") -Force | Out-Null
        @(
            'crucible_root: ".crucible"',
            'project:',
            '  name: "Folded"',
            '  default_branch: "main"',
            'verification:',
            '  full:',
            '    - name: scoped coverage',
            '      command: >-',
            '        go test -cover -mod=readonly',
            '        ./internal/...'
        ) | Set-Content -LiteralPath (Join-Path $projectRoot ".crucible/config.yaml") -Encoding UTF8

        $res = Invoke-ExternalCommand {
            & (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $DOCTOR_SCRIPT -ProjectRoot $projectRoot
        }
        $output = $res.Output -join "`n"

        Assert-Result -Name "no illegal-path crash" -Condition (-not ($output -match "Illegal characters in path")) -FailureMessage "folded-scalar command crashed the doctor. Output:`n$output"
        Assert-Result -Name "ran to completion" -Condition ($output -match "\[DOCTOR\] Result:") -FailureMessage "doctor did not complete with a folded-scalar command. Output:`n$output"
        Assert-Result -Name "block-scalar indicator not treated as a tool" -Condition (-not ($output -match "verification\.tool\.[>|]")) -FailureMessage "the YAML block-scalar indicator was misparsed as a verification tool. Output:`n$output"
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

        Assert-Result -Name "readiness header after gh failure" -Condition ($output -match "\[DOCTOR\] Crucible Readiness Check") -FailureMessage "doctor aborted before reporting. Output:`n$output"
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

        Assert-Result -Name "doctor did not crash without git" -Condition ($output -match "\[DOCTOR\] Crucible Readiness Check") -FailureMessage "doctor produced no readiness output when git was absent. Output:`n$output"
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
