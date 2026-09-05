$ErrorActionPreference = "Stop"
$REPO_ROOT = (Resolve-Path -Path "$PSScriptRoot/../..").Path
. (Join-Path $PSScriptRoot '_harness.ps1')
. (Join-Path $REPO_ROOT "powershell/lib/line-ending-conformance.ps1")

# These tests pin the behaviour of `git ls-files --eol` itself, not just our parsing.
# Three of its properties are counter-intuitive and each one silently defeats the
# check if it is dropped: a declared eol=crlf file is i/lf (so the INDEX field is the
# only one that may be consulted), the attr/ column contains spaces (so the path binds
# on the tab), and a CRLF blob inside the bundle still reports i/crlf (so only the
# path filter excludes it).

$results = @()

# Set-Content and Out-File rewrite line endings under PowerShell 5.1, which would
# quietly defeat every CRLF and mixed fixture below. Write the exact bytes instead.
function Write-RawFile {
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)][string]$Content
    )
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [System.IO.File]::WriteAllText($Path, $Content, [System.Text.UTF8Encoding]::new($false))
}

function New-EolFixture {
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [switch]$NoGit,
        [switch]$NoCommit
    )

    $bundle = Join-Path $Path ".crucible"
    New-Item -ItemType Directory -Path $bundle -Force | Out-Null
    Write-RawFile -Path (Join-Path $bundle "config.yaml") -Content "crucible_root: `".crucible`"`n"

    if ($NoGit) { return $bundle }

    $null = Invoke-Git @("init", "--quiet", $Path)
    # Load-bearing. On a machine with core.autocrlf=true git normalizes an accidental
    # CRLF file to i/lf on `git add`, and every fixture below would silently stop
    # reproducing the defect while still reporting PASSED.
    $null = Invoke-Git @("config", "core.autocrlf", "false") -Directory $Path
    $null = Invoke-Git @("config", "user.email", "test@example.com") -Directory $Path
    $null = Invoke-Git @("config", "user.name", "Eol Test") -Directory $Path
    if (-not $NoCommit) {
        $null = Invoke-Git @("add", "-A") -Directory $Path
    }
    return $bundle
}

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("crucible-line-ending-conformance-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

try {
    $results += Run-Test -Name "A repo that stores LF everywhere reports no violations" -Body {
        $project = Join-Path $tempRoot "clean"
        $bundle = New-EolFixture -Path $project -NoCommit
        Write-RawFile -Path (Join-Path $project "clean.txt") -Content "a`nb`n"
        Write-RawFile -Path (Join-Path $project "src/also-clean.sh") -Content "#!/bin/sh`necho hi`n"
        $null = Invoke-Git @("add", "-A") -Directory $project

        $report = Test-LineEndingConformance -ProjectRoot $project -BundleRoot $bundle
        Assert-Result -Name "status ok" -Condition ($report.Status -eq "ok") -FailureMessage "expected ok, got '$($report.Status)': $($report.Reason)"
        Assert-Result -Name "no violations" -Condition (@($report.Violations).Count -eq 0) -FailureMessage "expected none, got: $(@($report.Violations | ForEach-Object { $_.Path }) -join ', ')"
        # A pass with 0 files checked is vacuous - the same shape of bug this
        # framework already shipped once in check-mojibake.ps1.
        Assert-Result -Name "files were actually checked" -Condition ($report.Checked -eq 2) -FailureMessage "expected 2 tracked files outside the bundle, got $($report.Checked)"
    }

    $results += Run-Test -Name "An accidental CRLF file is reported" -Body {
        $project = Join-Path $tempRoot "accidental"
        $bundle = New-EolFixture -Path $project -NoCommit
        Write-RawFile -Path (Join-Path $project "Makefile") -Content "all:`r`n`techo hi`r`n"
        Write-RawFile -Path (Join-Path $project "clean.txt") -Content "a`nb`n"
        $null = Invoke-Git @("add", "-A") -Directory $project

        $report = Test-LineEndingConformance -ProjectRoot $project -BundleRoot $bundle
        $paths = @($report.Violations | ForEach-Object { $_.Path })
        Assert-Result -Name "status ok" -Condition ($report.Status -eq "ok") -FailureMessage "expected ok, got '$($report.Status)': $($report.Reason)"
        Assert-Result -Name "CRLF file reported" -Condition ($paths -contains "Makefile") -FailureMessage "Makefile not reported: $($paths -join ', ')"
        Assert-Result -Name "clean file not reported" -Condition (-not ($paths -contains "clean.txt")) -FailureMessage "an LF file must not be reported: $($paths -join ', ')"

        $finding = @($report.Violations | Where-Object { $_.Path -eq "Makefile" })[0]
        Assert-Result -Name "names how it is wrong" -Condition ($finding.IndexEol -eq "crlf") -FailureMessage "expected IndexEol 'crlf', got '$($finding.IndexEol)'"
    }

    $results += Run-Test -Name "A mixed-ending file is reported" -Body {
        $project = Join-Path $tempRoot "mixed"
        $bundle = New-EolFixture -Path $project -NoCommit
        Write-RawFile -Path (Join-Path $project "mixed.txt") -Content "a`r`nb`nc`r`n"
        $null = Invoke-Git @("add", "-A") -Directory $project

        # Proof git really classifies this as mixed, so the assertion below is
        # testing our rule rather than an accidental crlf classification.
        $raw = Invoke-Git @("ls-files", "--eol", "--", "mixed.txt") -Directory $project
        Assert-Result -Name "git reports i/mixed" -Condition ($raw.Raw -match 'i/mixed') -FailureMessage "premise broken: expected i/mixed, got: $($raw.Raw)"

        $report = Test-LineEndingConformance -ProjectRoot $project -BundleRoot $bundle
        $finding = @($report.Violations | Where-Object { $_.Path -eq "mixed.txt" })[0]
        Assert-Result -Name "mixed reported" -Condition ($null -ne $finding) -FailureMessage "mixed.txt not reported: $(@($report.Violations | ForEach-Object { $_.Path }) -join ', ')"
        Assert-Result -Name "reported as mixed" -Condition ($finding.IndexEol -eq "mixed") -FailureMessage "expected IndexEol 'mixed', got '$($finding.IndexEol)'"
    }

    $results += Run-Test -Name "A declared eol=crlf file is NOT reported" -Body {
        # This is the assertion that keeps a future "just check the attr column" or
        # "check the worktree field too" refactor honest. Deliberate CRLF is LF in the
        # index by definition, which is the entire reason no allowlist is needed.
        $project = Join-Path $tempRoot "deliberate"
        $bundle = New-EolFixture -Path $project -NoCommit
        Write-RawFile -Path (Join-Path $project ".gitattributes") -Content "deliberate.bat text eol=crlf`n"
        Write-RawFile -Path (Join-Path $project "deliberate.bat") -Content "@echo off`r`necho hi`r`n"
        $null = Invoke-Git @("add", "-A") -Directory $project

        $raw = Invoke-Git @("ls-files", "--eol", "--", "deliberate.bat") -Directory $project
        Assert-Result -Name "git stores it as i/lf w/crlf" -Condition ($raw.Raw -match 'i/lf\s+w/crlf') -FailureMessage "premise broken: expected 'i/lf w/crlf', got: $($raw.Raw)"

        $report = Test-LineEndingConformance -ProjectRoot $project -BundleRoot $bundle
        $paths = @($report.Violations | ForEach-Object { $_.Path })
        Assert-Result -Name "not reported" -Condition (-not ($paths -contains "deliberate.bat")) -FailureMessage "a deliberate eol=crlf file must never be reported: $($paths -join ', ')"
        Assert-Result -Name "no violations at all" -Condition (@($report.Violations).Count -eq 0) -FailureMessage "expected a clean report, got: $($paths -join ', ')"
    }

    $results += Run-Test -Name "A binary file is NOT reported" -Body {
        $project = Join-Path $tempRoot "binary"
        $bundle = New-EolFixture -Path $project -NoCommit
        [System.IO.File]::WriteAllBytes((Join-Path $project "blob.bin"), [byte[]]@(0, 1, 2, 13, 10, 0, 255))
        $null = Invoke-Git @("add", "-A") -Directory $project

        # The eol token here is `-text`, which is why the parser uses \S+ and not \w+.
        # A \w+ pattern fails to match this line and turns the whole check into an error.
        $raw = Invoke-Git @("ls-files", "--eol", "--", "blob.bin") -Directory $project
        Assert-Result -Name "git reports i/-text" -Condition ($raw.Raw -match 'i/-text') -FailureMessage "premise broken: expected i/-text, got: $($raw.Raw)"

        $report = Test-LineEndingConformance -ProjectRoot $project -BundleRoot $bundle
        Assert-Result -Name "status ok" -Condition ($report.Status -eq "ok") -FailureMessage "a `-text` line must parse, not error: '$($report.Status)': $($report.Reason)"
        Assert-Result -Name "not reported" -Condition (@($report.Violations).Count -eq 0) -FailureMessage "binaries must not be reported: $(@($report.Violations | ForEach-Object { $_.Path }) -join ', ')"
    }

    $results += Run-Test -Name "A CRLF file inside the bundle is NOT reported" -Body {
        # A CRLF blob under the bundle still reports i/crlf, so the eol field does not
        # exclude it - only the path filter does. A finding there is a broken bundle,
        # a different defect, and would be noise in an adopter-facing advisory.
        $project = Join-Path $tempRoot "in-bundle"
        $bundle = New-EolFixture -Path $project -NoCommit
        Write-RawFile -Path (Join-Path $bundle "docs/inside.md") -Content "a`r`nb`r`n"
        Write-RawFile -Path (Join-Path $project "outside.txt") -Content "a`nb`n"
        $null = Invoke-Git @("add", "-A") -Directory $project

        $raw = Invoke-Git @("ls-files", "--eol", "--", ".crucible/docs/inside.md") -Directory $project
        Assert-Result -Name "git does report it as i/crlf" -Condition ($raw.Raw -match 'i/crlf') -FailureMessage "premise broken; the path filter would be vacuous. Got: $($raw.Raw)"

        $report = Test-LineEndingConformance -ProjectRoot $project -BundleRoot $bundle
        $paths = @($report.Violations | ForEach-Object { $_.Path })
        Assert-Result -Name "bundle file excluded" -Condition (-not ($paths -contains ".crucible/docs/inside.md")) -FailureMessage "a bundle-internal file must not be reported: $($paths -join ', ')"
        Assert-Result -Name "no violations" -Condition (@($report.Violations).Count -eq 0) -FailureMessage "expected clean, got: $($paths -join ', ')"
        # The bundle's own files must also not inflate the denominator, or the pass
        # message would claim to have checked files it deliberately skipped.
        Assert-Result -Name "bundle files not counted" -Condition ($report.Checked -eq 1) -FailureMessage "expected 1 file outside the bundle, got $($report.Checked)"
    }

    $results += Run-Test -Name "Outside a git work tree the check skips rather than passing" -Body {
        $project = Join-Path $tempRoot "no-git"
        $bundle = New-EolFixture -Path $project -NoGit
        Write-RawFile -Path (Join-Path $project "accidental.txt") -Content "a`r`nb`r`n"

        $report = Test-LineEndingConformance -ProjectRoot $project -BundleRoot $bundle
        Assert-Result -Name "skipped" -Condition ($report.Status -eq "skipped") -FailureMessage "expected skipped outside a work tree, got '$($report.Status)'"
        Assert-Result -Name "no violations" -Condition (@($report.Violations).Count -eq 0) -FailureMessage "a skip must not carry findings"
        Assert-Result -Name "reason given" -Condition (-not [string]::IsNullOrWhiteSpace($report.Reason)) -FailureMessage "a skip must say why"
    }

    $results += Run-Test -Name "A repo with nothing tracked outside the bundle skips" -Body {
        # Otherwise the pass message reads "All 0 tracked files ... store LF", which is
        # a clean verdict on an empty set - the vacuous-pass shape again.
        $project = Join-Path $tempRoot "bundle-only"
        $bundle = New-EolFixture -Path $project -NoCommit
        $null = Invoke-Git @("add", "-A") -Directory $project

        $report = Test-LineEndingConformance -ProjectRoot $project -BundleRoot $bundle
        Assert-Result -Name "skipped" -Condition ($report.Status -eq "skipped") -FailureMessage "expected skipped with nothing outside the bundle, got '$($report.Status)': $($report.Reason)"
        Assert-Result -Name "reason given" -Condition (-not [string]::IsNullOrWhiteSpace($report.Reason)) -FailureMessage "a skip must say why"
    }

    $results += Run-Test -Name "Detail formatting names the files and caps the list" -Body {
        $violations = @()
        foreach ($i in 1..7) {
            $violations += [PSCustomObject]@{ Path = "scripts/s$i.sh"; IndexEol = "crlf" }
        }
        $detail = Format-LineEndingConformanceDetail -Violations $violations -MaxShown 5
        Assert-Result -Name "self-diagnosing" -Condition ($detail -match 'scripts/s1\.sh \(crlf\)') -FailureMessage "detail must name path and how it is wrong; got: $detail"
        Assert-Result -Name "caps the list" -Condition ($detail -match 'and 2 more') -FailureMessage "detail must cap long lists; got: $detail"
    }

    # A formatter is a pure projection: empty input has an obvious answer. In Windows
    # PowerShell 5.1 a Mandatory collection parameter rejects @(), and here the clean
    # case is the COMMON case, so without AllowEmptyCollection the check throws on
    # every healthy repo. That defect was already paid for once in
    # gitignore-conformance.ps1 and must not be reintroduced. AllowEmptyCollection
    # must not make the parameter optional - omitting it is still a caller error.
    $results += Run-Test -Name "Detail formatting accepts a clean result" -Body {
        $detail = $null
        $threw = $false
        try {
            $detail = Format-LineEndingConformanceDetail -Violations @()
        } catch {
            $threw = $true
        }
        Assert-Result -Name "empty collection accepted" -Condition (-not $threw) -FailureMessage "the clean case must not throw; AllowEmptyCollection is missing"
        Assert-Result -Name "empty detail" -Condition ($detail -eq "") -FailureMessage "expected an empty string, got: '$detail'"

        $omitted = $false
        try {
            $null = Format-LineEndingConformanceDetail
        } catch {
            $omitted = $true
        }
        Assert-Result -Name "still mandatory" -Condition $omitted -FailureMessage "omitting -Violations entirely must remain a caller error"
    }

    $results += Run-Test -Name "Doctor surfaces the finding as advisory, not a readiness failure" -Body {
        $project = Join-Path $tempRoot "doctor"
        $bundle = New-EolFixture -Path $project -NoCommit
        Write-RawFile -Path (Join-Path $project "Makefile") -Content "all:`r`n`techo hi`r`n"
        $null = Invoke-Git @("add", "-A") -Directory $project

        $res = Invoke-ExternalCommand {
            & (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File (Join-Path $REPO_ROOT "powershell/factory-doctor.ps1") -ProjectRoot $project
        }
        $output = $res.Output -join "`n"

        Assert-Result -Name "check runs" -Condition ($output -match 'lineendings\.conformance') -FailureMessage "doctor did not run the line-ending check. Output:`n$output"
        Assert-Result -Name "names the offending file" -Condition ($output -match 'Makefile \(crlf\)') -FailureMessage "doctor did not surface a self-diagnosing finding. Output:`n$output"
        # The remediation is outside Crucible's boundary, and the message must say so
        # rather than leaving the adopter wondering why the tool that found it did not
        # fix it. This sentence is the reason the check is advisory at all.
        Assert-Result -Name "states the boundary" -Condition ($output -match 'Crucible will not write this file for you') -FailureMessage "the remediation must explain why Crucible does not fix it. Output:`n$output"
        # This is a pre-existing condition of the adopter's repo, not something a
        # Crucible task introduced; it must never block a task.
        Assert-Result -Name "advisory only" -Condition ($output -match '\[DOCTOR\] Result: READY') -FailureMessage "a line-ending finding must not block readiness. Output:`n$output"
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
