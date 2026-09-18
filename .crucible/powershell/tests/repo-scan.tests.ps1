# Tests for powershell/lib/repo-scan.ps1.
#
# Get-RepoScannableFile exists so that a check which reads source files asks git what is in the
# repository instead of walking the filesystem, because a filesystem walk from the repository
# root also finds an agent's git worktree - a full second checkout - and lints it as production
# code. Item 87. That specific hazard is pinned in framework-gitignore.tests.ps1, against this
# repository's real .gitignore bytes; what is pinned here is the behaviour of the enumeration
# itself, on fixtures that carry their own ignore rules and so mean the same thing inside an
# adopter bundle.
#
# The two flags are the load-bearing part and each has its own case below. Dropping --others
# makes the enumeration blind to a file that exists but has never been git add-ed, which turns
# a lint into one that stops reading brand-new code; dropping --exclude-standard makes it read
# everything .gitignore excludes, which is the bug this helper was written to remove. Neither
# omission changes the result on a clean tree, so neither would be noticed without these.

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$REPO_ROOT = (Resolve-Path -Path "$PSScriptRoot/../..").Path
. (Join-Path $PSScriptRoot '_harness.ps1')
. (Join-Path $REPO_ROOT "powershell/lib/platform.ps1")
. (Join-Path $REPO_ROOT "powershell/lib/repo-scan.ps1")

$results = @()
$utf8 = New-Object System.Text.UTF8Encoding($false)

# A committed repository with one tracked file, so every case below has something the
# enumeration is expected to return. An assertion that a file is absent means nothing on its
# own - an enumeration returning nothing at all satisfies it - so the tracked file is the half
# that makes the absences load-bearing, and each case asserts on it.
function New-ScanFixture {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$IgnoreContent
    )
    $utf8Local = New-Object System.Text.UTF8Encoding($false)
    New-Item -ItemType Directory -Path (Join-Path $Path "powershell/lib") -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $Path ".gitignore"), $IgnoreContent, $utf8Local)
    [System.IO.File]::WriteAllText((Join-Path $Path "powershell/lib/ordinary.ps1"), "# ordinary`n", $utf8Local)

    $null = Invoke-Git @("init", "--quiet", $Path)
    # Same reason framework-gitignore.tests.ps1 pins it: left at the Windows default of true,
    # a path rule differing only in case still matches, so a case-sensitivity mistake passes
    # here and fails on Linux CI. The question worth asking is whether the rule holds on the
    # strictest filesystem.
    $null = Invoke-Git @("config", "core.ignorecase", "false") -Directory $Path
    $null = Invoke-Git @("add", "-A") -Directory $Path
    $null = Invoke-Git @("commit", "--quiet", "-m", "fixture") -Directory $Path
    return $Path
}

function Get-RelativeScanPath {
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Entry)
    return @($Entry | ForEach-Object { $_.RelativePath })
}

$tempRoot = New-TestFixtureRoot -NameHint "repo-scan"

try {
    $results += Run-Test -Name "An untracked file that no rule ignores is still scanned" -Body {
        # --others. A lint that only reads what is already committed goes quiet exactly when it
        # matters most: while the author is still writing the file. Nothing else in this suite
        # would notice the flag being dropped, because on a clean tree every source file is
        # tracked and the two enumerations agree.
        $repo = New-ScanFixture -Path (Join-Path $tempRoot "others") -IgnoreContent ""
        [System.IO.File]::WriteAllText((Join-Path $repo "powershell/lib/brand-new.ps1"), "# never added`n", $utf8)

        $found = Get-RelativeScanPath -Entry @(Get-RepoScannableFile -RepoRoot $repo -Extension ".ps1")
        Assert-Result -Name "the tracked file is scanned" -Condition ($found -contains "powershell/lib/ordinary.ps1") -FailureMessage (
            "the enumeration did not return the fixture's committed file, so this case is measuring nothing: " + ($found -join ", "))
        Assert-Result -Name "the untracked file is scanned" -Condition ($found -contains "powershell/lib/brand-new.ps1") -FailureMessage (
            "a file that exists but has never been git add-ed was not enumerated, so every check built on this " +
            "helper would stop reading new code until somebody staged it: " + ($found -join ", "))
    }

    $results += Run-Test -Name "A file under an ignored path is not scanned" -Body {
        # --exclude-standard, and the whole point of asking git: .gitignore becomes the one
        # definition of what a scan skips. Without the flag, --others returns every ignored
        # file and the helper is worse than the hand-written prefix list it replaced.
        $repo = New-ScanFixture -Path (Join-Path $tempRoot "ignored") -IgnoreContent "/.private/`n"
        New-Item -ItemType Directory -Path (Join-Path $repo ".private") -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $repo ".private/scratch.ps1"), "git status 2>&1`n", $utf8)

        $found = Get-RelativeScanPath -Entry @(Get-RepoScannableFile -RepoRoot $repo -Extension ".ps1")
        Assert-Result -Name "the tracked file is scanned" -Condition ($found -contains "powershell/lib/ordinary.ps1") -FailureMessage (
            "the enumeration returned nothing to speak of, so the absence below proves nothing: " + ($found -join ", "))
        Assert-Result -Name "the ignored file is not scanned" -Condition (-not ($found -contains ".private/scratch.ps1")) -FailureMessage (
            "an ignored file was enumerated, so .gitignore is not deciding what this helper reads: " + ($found -join ", "))
    }

    $results += Run-Test -Name "A nested repository is not returned as though it were a file" -Body {
        # git reports a nested repository it declined to enter as a single entry with a trailing
        # slash. It is a directory, and a caller that applied no extension filter would be
        # handed it as a file and try to read it. The fixture leaves it unignored on purpose:
        # this is about the shape of what git returns, not about whether a rule hides it.
        $repo = New-ScanFixture -Path (Join-Path $tempRoot "nested") -IgnoreContent ""
        $nested = Join-Path $repo "vendored"
        New-Item -ItemType Directory -Path $nested -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $nested "inner.ps1"), "# inner`n", $utf8)
        $null = Invoke-Git @("init", "--quiet", $nested)
        $null = Invoke-Git @("add", "-A") -Directory $nested
        $null = Invoke-Git @("commit", "--quiet", "-m", "inner") -Directory $nested

        $found = Get-RelativeScanPath -Entry @(Get-RepoScannableFile -RepoRoot $repo)
        Assert-Result -Name "the tracked file is scanned" -Condition ($found -contains "powershell/lib/ordinary.ps1") -FailureMessage (
            "the enumeration returned nothing to speak of: " + ($found -join ", "))
        Assert-Result -Name "no entry is a directory" -Condition (@($found | Where-Object { $_.EndsWith("/") }).Count -eq 0) -FailureMessage (
            "a directory entry was returned as a file, and a caller would try to read it: " + ($found -join ", "))
        Assert-Result -Name "the nested repository's own file is not reached" -Condition (-not ($found -contains "vendored/inner.ps1")) -FailureMessage (
            "git descended into a nested repository, which is the assumption the agent-worktree exclusion rests on: " + ($found -join ", "))

        # The case that makes dropping the trailing-slash filter detectable, and it took a
        # surviving mutation to notice it was missing. Deleting that filter leaves every
        # assertion above green, because the existence filter further down removes a directory
        # entry too - but it removes it one step too late. The two sit on opposite sides of the
        # emptiness check, and that is the whole difference: in a repository whose only content
        # is a nested repository, git returns a single directory entry, the trailing-slash
        # filter drops it before the check, and the check throws because there is genuinely
        # nothing to scan. Without that filter the entry survives the check - which now sees a
        # non-empty list and says nothing - and is removed afterwards, handing the caller an
        # empty list. Every check built on it then passes having read no files at all.
        $onlyNested = Join-Path $tempRoot "only-nested"
        New-Item -ItemType Directory -Path $onlyNested -Force | Out-Null
        $null = Invoke-Git @("init", "--quiet", $onlyNested)
        $inner = Join-Path $onlyNested "inner-repo"
        New-Item -ItemType Directory -Path $inner -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $inner "only.ps1"), "# only`n", $utf8)
        $null = Invoke-Git @("init", "--quiet", $inner)
        $null = Invoke-Git @("add", "-A") -Directory $inner
        $null = Invoke-Git @("commit", "--quiet", "-m", "inner") -Directory $inner

        $listedOnly = @((Invoke-Git @("ls-files", "--cached", "--others", "--exclude-standard") -Directory $onlyNested).Lines)
        Assert-Result -Name "git reports the nested repository as a directory entry" -Condition (@($listedOnly | Where-Object { $_ -eq "inner-repo/" }).Count -eq 1) -FailureMessage (
            "the fixture did not produce the single directory entry this case is about, so the assertion below is " +
            "not measuring it: " + ($listedOnly -join ", "))

        $threwOnlyNested = $false
        try { $null = @(Get-RepoScannableFile -RepoRoot $onlyNested) } catch { $threwOnlyNested = $true }
        Assert-Result -Name "a repository holding only a nested repository throws" -Condition ($threwOnlyNested) -FailureMessage (
            "git reported nothing but a directory entry, and the helper returned a list instead of throwing. A caller " +
            "would scan zero files and report itself clean.")
    }

    $results += Run-Test -Name "A file staged but deleted from disk is not handed to a caller" -Body {
        # It is still an index entry, so git lists it; opening it throws. Deleting a source
        # file without staging the deletion is an ordinary thing to do mid-edit, and it should
        # not turn every scan-based check in the suite into a file-not-found crash.
        $repo = New-ScanFixture -Path (Join-Path $tempRoot "deleted") -IgnoreContent ""
        $doomed = Join-Path $repo "powershell/lib/doomed.ps1"
        [System.IO.File]::WriteAllText($doomed, "# about to go`n", $utf8)
        $null = Invoke-Git @("add", "-A") -Directory $repo
        $null = Invoke-Git @("commit", "--quiet", "-m", "add doomed") -Directory $repo
        Remove-Item -LiteralPath $doomed -Force

        $indexed = @((Invoke-Git @("ls-files", "--cached") -Directory $repo).Lines)
        Assert-Result -Name "git still lists the deleted file" -Condition (@($indexed | Where-Object { $_ -match 'doomed\.ps1' }).Count -eq 1) -FailureMessage (
            "the fixture did not produce an index entry without a file, so the assertion below is not measuring the case it names: " + ($indexed -join ", "))

        $found = Get-RelativeScanPath -Entry @(Get-RepoScannableFile -RepoRoot $repo -Extension ".ps1")
        Assert-Result -Name "the tracked file is scanned" -Condition ($found -contains "powershell/lib/ordinary.ps1") -FailureMessage (
            "the enumeration returned nothing to speak of: " + ($found -join ", "))
        Assert-Result -Name "the deleted file is not returned" -Condition (-not ($found -contains "powershell/lib/doomed.ps1")) -FailureMessage (
            "a path with no file behind it was returned, and the caller's next Get-Content throws: " + ($found -join ", "))
    }

    $results += Run-Test -Name "A root git cannot enumerate throws rather than reporting nothing" -Body {
        # The failure mode this helper is most likely to hide. Every caller asserts on the
        # violations it finds, so an enumeration that quietly returned an empty list would
        # report each of them clean - a scan over no files finds no problems. Throwing is the
        # only answer that cannot be mistaken for a pass.
        $notARepo = Join-Path $tempRoot "not-a-repo"
        New-Item -ItemType Directory -Path $notARepo -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $notARepo "lonely.ps1"), "# no repo here`n", $utf8)

        $threw = $false
        try { $null = @(Get-RepoScannableFile -RepoRoot $notARepo) } catch { $threw = $true }
        Assert-Result -Name "a directory outside any repository throws" -Condition ($threw) -FailureMessage (
            "Get-RepoScannableFile returned instead of throwing for a directory git knows nothing about, so a " +
            "mis-resolved root would report every check clean")

        # Deleting the RepoRoot guard from the helper leaves the throw itself intact, which a
        # mutation proved: Resolve-Path fails on a path that is not there, and a RepoRoot that
        # is a file rather than a directory reaches the exit-code throw instead. So what the
        # guard is actually worth is the message - a caller told which helper rejected its root,
        # rather than a bare "cannot find path" from a line they did not write. That is the
        # property asserted, because it is the one the guard is the only source of.
        $missing = Join-Path $tempRoot "does-not-exist"
        $threwMissing = $false
        $missingMessage = ""
        try { $null = @(Get-RepoScannableFile -RepoRoot $missing) } catch { $threwMissing = $true; $missingMessage = $_.Exception.Message }
        Assert-Result -Name "a path that is not a directory throws" -Condition ($threwMissing) -FailureMessage (
            "Get-RepoScannableFile accepted a RepoRoot that does not exist")
        Assert-Result -Name "the rejection names the helper rather than surfacing a raw path error" -Condition ($missingMessage -match 'Get-RepoScannableFile') -FailureMessage (
            "the error a caller sees does not name Get-RepoScannableFile, so a bad root reads as an unexplained " +
            "failure somewhere inside the helper: " + $missingMessage)

        $emptyRepo = Join-Path $tempRoot "empty-repo"
        New-Item -ItemType Directory -Path $emptyRepo -Force | Out-Null
        $null = Invoke-Git @("init", "--quiet", $emptyRepo)
        $threwEmpty = $false
        try { $null = @(Get-RepoScannableFile -RepoRoot $emptyRepo) } catch { $threwEmpty = $true }
        Assert-Result -Name "a repository holding no files at all throws" -Condition ($threwEmpty) -FailureMessage (
            "a repository git reports as holding nothing produced an empty list rather than a throw; that is a " +
            "broken premise, not a clean result")
    }

    $results += Run-Test -Name "Callers can scope a scan without restating what gitignore covers" -Body {
        # IncludePrefix and ExcludePrefix are for scope - what a rule is about - and are kept
        # separate from the ignore handling above so that the two never get confused. The
        # distinction is why native-stderr-idiom.tests.ps1 could drop three of its five
        # exclusions and keep two: three were restating .gitignore, two are decisions.
        $repo = New-ScanFixture -Path (Join-Path $tempRoot "scoped") -IgnoreContent ""
        New-Item -ItemType Directory -Path (Join-Path $repo "powershell/tests") -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $repo "docs") -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $repo "powershell/tests/a.tests.ps1"), "# test`n", $utf8)
        [System.IO.File]::WriteAllText((Join-Path $repo "docs/notes.md"), "# notes`n", $utf8)
        [System.IO.File]::WriteAllText((Join-Path $repo "docs/helper.ps1"), "# doc helper`n", $utf8)

        $scoped = Get-RelativeScanPath -Entry @(Get-RepoScannableFile -RepoRoot $repo -Extension ".ps1" -IncludePrefix "powershell" -ExcludePrefix "powershell/tests")
        Assert-Result -Name "IncludePrefix keeps what it names" -Condition ($scoped -contains "powershell/lib/ordinary.ps1") -FailureMessage (
            "IncludePrefix powershell dropped a file under powershell/: " + ($scoped -join ", "))
        Assert-Result -Name "IncludePrefix excludes what it does not name" -Condition (-not ($scoped -contains "docs/helper.ps1")) -FailureMessage (
            "IncludePrefix powershell returned a file outside powershell/: " + ($scoped -join ", "))
        Assert-Result -Name "ExcludePrefix removes a subdirectory of an included one" -Condition (-not ($scoped -contains "powershell/tests/a.tests.ps1")) -FailureMessage (
            "ExcludePrefix powershell/tests did not remove a file under it: " + ($scoped -join ", "))
        Assert-Result -Name "Extension filters by extension" -Condition (-not ($scoped -contains "docs/notes.md")) -FailureMessage (
            "a .md file survived an Extension filter of .ps1: " + ($scoped -join ", "))

        # A prefix must match on a path boundary. Without that, excluding "powershell/test"
        # would silently also drop "powershell/tests/", and excluding "doc" would drop "docs/".
        $boundary = Get-RelativeScanPath -Entry @(Get-RepoScannableFile -RepoRoot $repo -Extension ".ps1" -ExcludePrefix "doc")
        Assert-Result -Name "a prefix does not match a partial directory name" -Condition ($boundary -contains "docs/helper.ps1") -FailureMessage (
            "ExcludePrefix doc removed a file under docs/, so prefixes match on characters rather than path segments: " + ($boundary -join ", "))
    }

    $results += Run-Test -Name "No test in this suite walks the repository root recursively" -Body {
        # The shape that caused item 87, pinned so the next one fails here rather than in a
        # confusing 96/97 with the evidence already deleted. A walk rooted at a named
        # subdirectory is a different and much narrower risk and is not flagged.
        #
        # This is a text scan and an evadable one: assigning $REPO_ROOT to another variable
        # first defeats it. It is worth having anyway because it catches the exact shape that
        # has already happened once, and because its failure message names the helper to use -
        # which a reviewer noticing the pattern by eye would have to know to say. It is not a
        # substitute for the cases above, which are what actually establish the behaviour.
        # The (?<!\w) matters more than it looks. Without it the pattern matches the -Path
        # inside `Join-Path $REPO_ROOT $dir`, which is the ordinary, correct way to root a walk
        # at a named subdirectory - the first draft reported six such lines across four files
        # as offenders. The two lookaheads let -Path and -Recurse appear in either order.
        $rootVariable = '\$(?:REPO_ROOT|RepoRoot|repoRoot)\b'
        $pattern = 'Get-ChildItem(?=[^\r\n]*(?<!\w)-Path\s+' + $rootVariable + ')(?=[^\r\n]*-Recurse)[^\r\n]*'

        # Positive control. Without it, a pattern that had stopped matching anything - a
        # renamed parameter, an escaping slip - would report the whole suite clean forever.
        #
        # Assembled rather than written out, because this file is one of the files scanned
        # below and a literal known-bad line here would be reported as an offender in itself.
        $sample = 'Get-ChildItem -Path ' + '$' + 'REPO_ROOT -Filter "*.ps1" -Recurse -File'
        Assert-Result -Name "the pattern matches the shape it is written for" -Condition ($sample -match $pattern) -FailureMessage (
            "the detection pattern no longer matches a known-bad line, so the scan below cannot fail: " + $pattern)

        # And the other half: the pattern must not match a walk rooted at a subdirectory, or
        # it would report most of this suite and get deleted rather than fixed.
        $legitimate = 'Get-ChildItem -Path (Join-Path ' + '$' + 'REPO_ROOT "powershell") -Filter "*.ps1" -File -Recurse'
        Assert-Result -Name "the pattern ignores a walk rooted at a subdirectory" -Condition (-not ($legitimate -match $pattern)) -FailureMessage (
            "the detection pattern flags Join-Path walks, which are the ordinary way to scope a scan: " + $pattern)

        $scanned = 0
        $offenders = @()
        foreach ($testFile in @(Get-ChildItem -LiteralPath $PSScriptRoot -Filter "*.ps1" -File)) {
            $scanned++
            $text = [System.IO.File]::ReadAllText($testFile.FullName)
            foreach ($match in [regex]::Matches($text, $pattern)) {
                $offenders += ($testFile.Name + ": " + $match.Value.Trim())
            }
        }
        Assert-Result -Name "the suite was read" -Condition ($scanned -ge 50) -FailureMessage (
            "read " + $scanned + " files from " + $PSScriptRoot + "; the suite is far larger than that, so this " +
            "scan is not looking where it thinks it is")
        Assert-Result -Name "no recursive walk is rooted at the repository root" -Condition ($offenders.Count -eq 0) -FailureMessage (
            "these walk the whole repository from its root, which includes any agent worktree under " +
            ".claude/worktrees/ and lints a second copy of this suite as production code. Use " +
            "Get-RepoScannableFile from powershell/lib/repo-scan.ps1 instead: " + ($offenders -join "; "))
    }
} finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

$failed = @($results | Where-Object { -not $_ }).Count
if ($failed -gt 0) {
    Write-Host ("`n$failed repo-scan test(s) failed.") -ForegroundColor Red
    exit 1
}
Write-Host "`nAll repo-scan tests passed." -ForegroundColor Green
exit 0
