$ErrorActionPreference = "Stop"
$REPO_ROOT = (Resolve-Path -Path "$PSScriptRoot/../..").Path
. (Join-Path $PSScriptRoot '_harness.ps1')
. (Join-Path $REPO_ROOT "powershell/lib/gitignore-conformance.ps1")

# These tests pin the behaviour of `git check-ignore` itself, not just our parsing.
# Three of its properties are counter-intuitive and each one silently defeats the
# check if it is dropped: --no-index (tracked files are otherwise exempt), the `!`
# filter (a printed negation means NOT ignored), and the two different path bases
# in a single -v output line.

$results = @()

function New-ConformanceFixture {
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [string[]]$RootIgnore = @(),
        [string[]]$BundleIgnore = @("/session/", "/backlog/", "/docs/local-notes.md"),
        [switch]$NoGit
    )

    $bundle = Join-Path $Path ".crucible"
    foreach ($dir in @("agent-instructions", "docs/orchestrators", "powershell/lib", "session")) {
        New-Item -ItemType Directory -Path (Join-Path $bundle $dir) -Force | Out-Null
    }

    Set-Content -LiteralPath (Join-Path $bundle "config.yaml") -Value 'crucible_root: ".crucible"' -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $bundle "README.md") -Value "# Bundle" -Encoding UTF8
    foreach ($name in @("AGENTS.md", "CLAUDE.md", "GEMINI.md")) {
        Set-Content -LiteralPath (Join-Path $bundle ("agent-instructions/" + $name)) -Value "snippet" -Encoding UTF8
    }
    Set-Content -LiteralPath (Join-Path $bundle "docs/orchestrators/claude.md") -Value "guide" -Encoding UTF8
    # Under docs/ so it IS in the commit-by-default set, but excluded by the bundle's
    # own .gitignore. Without this the bundle-internal assertions pass vacuously.
    Set-Content -LiteralPath (Join-Path $bundle "docs/local-notes.md") -Value "local" -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $bundle "powershell/lib/factory.ps1") -Value "# runtime" -Encoding UTF8
    # Runtime state the bundle's own .gitignore is supposed to exclude.
    Set-Content -LiteralPath (Join-Path $bundle "session/notes.md") -Value "scratch" -Encoding UTF8

    ($BundleIgnore -join "`n") | Set-Content -LiteralPath (Join-Path $bundle ".gitignore") -Encoding UTF8
    if ($RootIgnore.Count -gt 0) {
        ($RootIgnore -join "`n") | Set-Content -LiteralPath (Join-Path $Path ".gitignore") -Encoding UTF8
    }

    if (-not $NoGit) {
        $null = Invoke-Git @("init", "--quiet", $Path)
        $null = Invoke-Git @("config", "user.email", "test@example.com") -Directory $Path
        $null = Invoke-Git @("config", "user.name", "Conformance Test") -Directory $Path
    }
    return $bundle
}

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("crucible-gitignore-conformance-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

try {
    $results += Run-Test -Name "Unanchored root pattern is reported against bundle files" -Body {
        $project = Join-Path $tempRoot "unanchored"
        $bundle = New-ConformanceFixture -Path $project -RootIgnore @("CLAUDE.md", "GEMINI.md", "AGENTS.md")

        $report = Test-GitignoreConformance -ProjectRoot $project -BundleRoot $bundle
        $paths = @($report.Violations | ForEach-Object { $_.Path })

        Assert-Result -Name "status ok" -Condition ($report.Status -eq "ok") -FailureMessage "expected ok, got '$($report.Status)': $($report.Reason)"
        foreach ($name in @("AGENTS.md", "CLAUDE.md", "GEMINI.md")) {
            Assert-Result -Name "$name caught" -Condition ($paths -contains ".crucible/agent-instructions/$name") -FailureMessage "$name not reported: $($paths -join ', ')"
        }
        Assert-Result -Name "unrelated bundle files untouched" -Condition (-not ($paths -contains ".crucible/README.md")) -FailureMessage "README.md matches no pattern and must not be reported: $($paths -join ', ')"

        # On a case-insensitive filesystem `CLAUDE.md` also swallows
        # docs/orchestrators/claude.md, which is why an adopter that hit this bug
        # needed a separate negation for it. Assert the real behaviour on each
        # platform rather than a count that only holds on one of them.
        $ignoreCase = (Invoke-Git @("config", "core.ignorecase") -Directory $project).Raw.Trim()
        $orchestrator = ".crucible/docs/orchestrators/claude.md"
        if ($ignoreCase -eq "true") {
            Assert-Result -Name "case-insensitive collision caught" -Condition ($paths -contains $orchestrator) -FailureMessage "core.ignorecase=true should also match $orchestrator : $($paths -join ', ')"
            Assert-Result -Name "four violations" -Condition (@($report.Violations).Count -eq 4) -FailureMessage "expected 4 violations under core.ignorecase=true, got $(@($report.Violations).Count): $($paths -join ', ')"
        } else {
            Assert-Result -Name "no case collision" -Condition (-not ($paths -contains $orchestrator)) -FailureMessage "core.ignorecase=$ignoreCase should not match $orchestrator : $($paths -join ', ')"
            Assert-Result -Name "three violations" -Condition (@($report.Violations).Count -eq 3) -FailureMessage "expected 3 violations under core.ignorecase=$ignoreCase, got $(@($report.Violations).Count): $($paths -join ', ')"
        }

        # The finding must name the offending rule, or the adopter cannot act on it.
        $agents = @($report.Violations | Where-Object { $_.Path -eq ".crucible/agent-instructions/AGENTS.md" })[0]
        Assert-Result -Name "names the source file" -Condition ($agents.Source -eq ".gitignore") -FailureMessage "expected source '.gitignore', got '$($agents.Source)'"
        Assert-Result -Name "names the line" -Condition ($agents.Line -eq 3) -FailureMessage "expected line 3, got $($agents.Line)"
        Assert-Result -Name "names the pattern" -Condition ($agents.Pattern -eq "AGENTS.md") -FailureMessage "expected pattern 'AGENTS.md', got '$($agents.Pattern)'"
    }

    $results += Run-Test -Name "Anchoring the pattern to the repo root clears the finding" -Body {
        $project = Join-Path $tempRoot "anchored"
        $bundle = New-ConformanceFixture -Path $project -RootIgnore @("/CLAUDE.md", "/GEMINI.md", "/AGENTS.md")

        $report = Test-GitignoreConformance -ProjectRoot $project -BundleRoot $bundle
        Assert-Result -Name "no violations" -Condition (@($report.Violations).Count -eq 0) -FailureMessage "anchored patterns must not match bundle files, got: $(@($report.Violations | ForEach-Object { $_.Path }) -join ', ')"
        Assert-Result -Name "files were actually checked" -Condition ($report.Checked -gt 0) -FailureMessage "a pass with 0 files checked is vacuous"
    }

    $results += Run-Test -Name "The bundle's own ignore rules are not violations" -Body {
        $project = Join-Path $tempRoot "bundle-rules"
        $bundle = New-ConformanceFixture -Path $project

        $report = Test-GitignoreConformance -ProjectRoot $project -BundleRoot $bundle
        Assert-Result -Name "clean" -Condition (@($report.Violations).Count -eq 0) -FailureMessage "bundle-internal rules must not be reported, got: $(@($report.Violations | ForEach-Object { $_.Source }) -join ', ')"

        # session/ is ignored by .crucible/.gitignore and is deliberately outside the
        # commit-by-default set, so it must never be submitted in the first place.
        $candidates = Get-BundleCommittablePath -ProjectRoot $project -BundleRoot $bundle
        Assert-Result -Name "runtime state not checked" -Condition (-not (@($candidates) -contains ".crucible/session/notes.md")) -FailureMessage "runtime state must not be in the commit-by-default set"
        Assert-Result -Name "committable files are checked" -Condition (@($candidates) -contains ".crucible/agent-instructions/AGENTS.md") -FailureMessage "agent-instructions must be in the commit-by-default set: $(@($candidates) -join ', ')"

        # The "clean" assertion above is only load-bearing if a bundle-internal rule
        # actually matched something that was submitted.
        Assert-Result -Name "bundle-ignored file was submitted" -Condition (@($candidates) -contains ".crucible/docs/local-notes.md") -FailureMessage "fixture no longer exercises a bundle-internal match; the clean assertion would be vacuous"
        $rawInternal = Invoke-Git @("check-ignore", "-v", "--no-index", "--", ".crucible/docs/local-notes.md") -Directory $project
        Assert-Result -Name "bundle rule really matched it" -Condition ($rawInternal.Raw -match [regex]::Escape(".crucible/.gitignore")) -FailureMessage "expected the bundle .gitignore to be the matching source; got: $($rawInternal.Raw)"
    }

    $results += Run-Test -Name "A negated pattern is not reported as a violation" -Body {
        $project = Join-Path $tempRoot "negated"
        # check-ignore -v PRINTS the negation line and exits 0, but the path is NOT
        # ignored. Counting printed lines would flag the adopter's own workaround.
        $bundle = New-ConformanceFixture -Path $project -RootIgnore @(
            "CLAUDE.md",
            "!.crucible/agent-instructions/CLAUDE.md"
        )

        $report = Test-GitignoreConformance -ProjectRoot $project -BundleRoot $bundle
        $paths = @($report.Violations | ForEach-Object { $_.Path })
        Assert-Result -Name "negation cleared the file" -Condition (-not ($paths -contains ".crucible/agent-instructions/CLAUDE.md")) -FailureMessage "a negated path must not be a violation: $($paths -join ', ')"

        # Proof the negation line really is emitted, so the filter is load-bearing
        # rather than incidentally unreachable.
        $raw = Invoke-Git @("check-ignore", "-v", "--no-index", "--", ".crucible/agent-instructions/CLAUDE.md") -Directory $project
        Assert-Result -Name "git does print the negation" -Condition ($raw.Raw -match '!\.crucible/agent-instructions/CLAUDE\.md') -FailureMessage "expected git to print the negation line; got: $($raw.Raw)"
    }

    $results += Run-Test -Name "A tracked file is still reported (--no-index is load-bearing)" -Body {
        $project = Join-Path $tempRoot "tracked"
        $bundle = New-ConformanceFixture -Path $project -RootIgnore @("AGENTS.md")

        # Committing the file makes the default check-ignore exempt it and return a
        # silent, falsely clean exit 1. This is the trap the check must not fall into.
        $null = Invoke-Git @("add", "-f", ".crucible/agent-instructions/AGENTS.md") -Directory $project
        $null = Invoke-Git @("commit", "--quiet", "-m", "track the file") -Directory $project

        $indexAware = Invoke-Git @("check-ignore", "-v", "--", ".crucible/agent-instructions/AGENTS.md") -Directory $project
        Assert-Result -Name "index-aware form is falsely clean" -Condition ($indexAware.ExitCode -eq 1) -FailureMessage "premise broken: check-ignore without --no-index should have exempted the tracked file, got exit $($indexAware.ExitCode)"

        $report = Test-GitignoreConformance -ProjectRoot $project -BundleRoot $bundle
        $paths = @($report.Violations | ForEach-Object { $_.Path })
        Assert-Result -Name "still reported" -Condition ($paths -contains ".crucible/agent-instructions/AGENTS.md") -FailureMessage "a tracked-but-ignored file must still be reported: $($paths -join ', ')"
    }

    $results += Run-Test -Name "A bundle below the repo root is classified by the right base" -Body {
        # check-ignore -v prints the source relative to the git top-level but the
        # path relative to the working directory. When the project root is not the
        # repo root those bases differ, and a naive join misfiles the bundle's own
        # rules as external violations.
        $repo = Join-Path $tempRoot "nested-repo"
        $project = Join-Path $repo "app"
        New-Item -ItemType Directory -Path $project -Force | Out-Null
        $bundle = New-ConformanceFixture -Path $project -NoGit
        $null = Invoke-Git @("init", "--quiet", $repo)
        $null = Invoke-Git @("config", "user.email", "test@example.com") -Directory $repo
        $null = Invoke-Git @("config", "user.name", "Conformance Test") -Directory $repo

        $report = Test-GitignoreConformance -ProjectRoot $project -BundleRoot $bundle
        Assert-Result -Name "status ok" -Condition ($report.Status -eq "ok") -FailureMessage "expected ok, got '$($report.Status)': $($report.Reason)"
        Assert-Result -Name "bundle rules stay internal" -Condition (@($report.Violations).Count -eq 0) -FailureMessage "nested bundle rules were misfiled as external: $(@($report.Violations | ForEach-Object { $_.Source }) -join ', ')"
    }

    $results += Run-Test -Name "Outside a git work tree the check skips rather than passing" -Body {
        $project = Join-Path $tempRoot "no-git"
        $bundle = New-ConformanceFixture -Path $project -RootIgnore @("AGENTS.md") -NoGit

        $report = Test-GitignoreConformance -ProjectRoot $project -BundleRoot $bundle
        Assert-Result -Name "skipped" -Condition ($report.Status -eq "skipped") -FailureMessage "expected skipped outside a work tree, got '$($report.Status)'"
        Assert-Result -Name "reason given" -Condition (-not [string]::IsNullOrWhiteSpace($report.Reason)) -FailureMessage "a skip must say why"
    }

    $results += Run-Test -Name "Detail formatting names the rule and caps the list" -Body {
        $violations = @()
        foreach ($i in 1..7) {
            $violations += [PSCustomObject]@{ Path = ".crucible/docs/d$i.md"; Source = ".gitignore"; Line = $i; Pattern = "docs" }
        }
        $detail = Format-GitignoreConformanceDetail -Violations $violations -MaxShown 5
        Assert-Result -Name "self-diagnosing" -Condition ($detail -match '\.gitignore:1:docs -> \.crucible/docs/d1\.md') -FailureMessage "detail must name source:line:pattern -> path; got: $detail"
        Assert-Result -Name "caps the list" -Condition ($detail -match 'and 2 more') -FailureMessage "detail must cap long lists; got: $detail"
    }

    # A formatter is a pure projection: empty input has an obvious answer. In
    # Windows PowerShell 5.1 a Mandatory collection parameter rejects @(), so
    # without AllowEmptyCollection the clean case throws and every caller has to
    # guard the call. AllowEmptyCollection must not make the parameter optional -
    # omitting it entirely is still a caller error, so that is pinned too.
    $results += Run-Test -Name "Detail formatting accepts a clean result" -Body {
        $detail = $null
        $threw = $false
        try { $detail = Format-GitignoreConformanceDetail -Violations @() } catch { $threw = $true }
        Assert-Result -Name "empty input binds" -Condition (-not $threw) -FailureMessage "formatting an empty violation list must not throw"
        Assert-Result -Name "empty input formats to empty" -Condition ($detail -eq "") -FailureMessage "expected an empty string for no violations; got: $detail"

        $stillMandatory = $false
        try { $null = Format-GitignoreConformanceDetail -MaxShown 5 -ErrorAction Stop } catch { $stillMandatory = $true }
        Assert-Result -Name "omitting the argument is still an error" -Condition $stillMandatory -FailureMessage "AllowEmptyCollection must permit @() without making the parameter optional"
    }

    $results += Run-Test -Name "Doctor surfaces the finding as advisory, not a readiness failure" -Body {
        $project = Join-Path $tempRoot "doctor"
        $null = New-ConformanceFixture -Path $project -RootIgnore @("AGENTS.md")

        $res = Invoke-ExternalCommand {
            & (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File (Join-Path $REPO_ROOT "powershell/factory-doctor.ps1") -ProjectRoot $project
        }
        $output = $res.Output -join "`n"

        Assert-Result -Name "check runs" -Condition ($output -match 'gitignore\.conformance') -FailureMessage "doctor did not run the conformance check. Output:`n$output"
        Assert-Result -Name "names the offending rule" -Condition ($output -match '\.gitignore:1:AGENTS\.md -> \.crucible/agent-instructions/AGENTS\.md') -FailureMessage "doctor did not surface a self-diagnosing finding. Output:`n$output"
        # docs/git-policy.md calls the commit-by-default list a recommendation, so a
        # deliberate override must not read as NOT READY.
        Assert-Result -Name "advisory only" -Condition ($output -match '\[DOCTOR\] Result: READY') -FailureMessage "an ignore-rule finding must not block readiness. Output:`n$output"
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
