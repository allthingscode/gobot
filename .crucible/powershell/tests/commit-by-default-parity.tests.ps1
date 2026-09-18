# Tests that every page restating the commit-by-default bundle list agrees with
# Get-CommitByDefaultPath, the function that declares it.
#
# The comment over that function called itself the "single source of truth for the prose in
# init-project.ps1, lib/instruction-blocks.ps1 and docs/git-policy.md". It was not one, and
# it did not even name every copy: adding standards/ for item 67 took seven hand edits, four
# of them to files the comment never mentions. There turned out to be nine copies, not seven -
# the undeclared-page sweep at the bottom of this file found the ninth. Nothing compared any
# copy to the function, so by the time this test was written five of the nine had already
# drifted, including BOTH tables that carry a Commit column: each omitted standards/, and so
# told adopters nothing about committing the audit scorecards item 67 exists to keep. Item 74.
#
# The list is not merely descriptive. Get-BundleCommittablePath expands it into real files and
# Test-GitignoreConformance checks those files and no others, so a list that drifts does not
# only misinform an adopter - it decides what the doctor looks at.
#
# The parity rule is exact equality, in both directions: a surface must name every entry the
# function returns, and anything it names beyond them has to be declared below with a reason.
# A surface allowed to omit an entry is not a category this file supports, because every one
# of these surfaces exists to tell somebody what to commit and an omission is the whole defect.

$ErrorActionPreference = "Stop"
$REPO_ROOT = (Resolve-Path -Path "$PSScriptRoot/../..").Path
. (Join-Path $PSScriptRoot '_harness.ps1')
. (Join-Path $REPO_ROOT "powershell/lib/gitignore-conformance.ps1")

$results = @()

# Four extractor kinds rather than one clever pattern, because the nine surfaces genuinely do
# not share a form: markdown bullets with and without a .crucible/ prefix, two tables with a
# Commit column, console output from a PowerShell script, and an ASCII tree with per-line
# prose comments. Keeping the difference visible here is more honest than a regex broad
# enough to read all of them, which would also be broad enough to read prose as a path.
#
# Every kind reads the FIRST backticked token on a list line and stops. A pattern that took
# every backticked token in the region instead read the descriptions: bootstrap.md explains
# agent-instructions/ by naming `AGENTS.md`, `CLAUDE.md` and `GEMINI.md`, and standards/ by
# naming `scorecard-TEMPLATE.md`, none of which is a bundle entry the page is listing.
function ConvertTo-BundleEntry {
    param([Parameter(Mandatory=$true)][AllowEmptyString()][string]$Token)
    $value = $Token.Trim()
    $value = $value -replace '^\{\{crucible_root\}\}/', ''
    $value = $value -replace '^\.crucible/', ''
    return $value.TrimEnd('/')
}

function Get-SurfaceEntry {
    param(
        [Parameter(Mandatory=$true)][string]$Kind,
        [Parameter(Mandatory=$true)][AllowEmptyString()][string]$Region
    )
    $found = @()
    switch ($Kind) {
        "bullet" {
            foreach ($match in [regex]::Matches($Region, '(?m)^\s*-\s+`([^`]+)`')) {
                $found += (ConvertTo-BundleEntry -Token $match.Groups[1].Value)
            }
        }
        "table-row" {
            foreach ($match in [regex]::Matches($Region, '(?m)^\|\s*`([^`]+)`')) {
                $found += (ConvertTo-BundleEntry -Token $match.Groups[1].Value)
            }
        }
        "console-bullet" {
            # One Write-Info per line, and the last line crams five directories onto a single
            # comma-separated run - which is exactly the shape that makes a hand-kept copy easy
            # to under-edit. A trailing parenthetical is prose, not an entry.
            foreach ($match in [regex]::Matches($Region, '(?m)^\s*Write-Info\s+"\s*-\s*([^"]+)"')) {
                foreach ($piece in ($match.Groups[1].Value -split ',')) {
                    $cleaned = ($piece -replace '\(.*$', '').Trim()
                    if ([string]::IsNullOrWhiteSpace($cleaned)) { continue }
                    $found += (ConvertTo-BundleEntry -Token $cleaned)
                }
            }
        }
        "tree" {
            # Depth two only. The backlog/ subtree below it names spec directories, not bundle
            # entries, and reading those would report drift that is not there.
            foreach ($match in [regex]::Matches($Region, '(?m)^\|\s{3}[|`]-- (\S+)')) {
                $found += (ConvertTo-BundleEntry -Token $match.Groups[1].Value)
            }
        }
        default { throw ("unknown extractor kind: " + $Kind) }
    }
    return @($found | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
}

function Get-SurfaceRegion {
    param(
        [Parameter(Mandatory=$true)][string]$Text,
        [Parameter(Mandatory=$true)][string]$Start,
        [Parameter(Mandatory=$false)][string]$End
    )
    $startMatch = [regex]::Match($Text, $Start)
    if (-not $startMatch.Success) { return $null }
    $rest = $Text.Substring($startMatch.Index + $startMatch.Length)
    if (-not [string]::IsNullOrWhiteSpace($End)) {
        $endMatch = [regex]::Match($rest, $End)
        if ($endMatch.Success) { $rest = $rest.Substring(0, $endMatch.Index) }
    }
    return $rest
}

# Every page that restates the list. "Extra" is for entries a surface names on purpose that
# the function does not return - a page describing the whole installed bundle legitimately
# names backlog/, which is installed but not commit-by-default. Each one needs a reason,
# because an undeclared extra and a deliberate one look identical in a diff.
$surfaces = @(
    @{
        Name  = "docs/git-policy.md"
        Path  = "docs/git-policy.md"
        Kind  = "bullet"
        Start = '(?m)^## Commit By Default\s*$'
        End   = '(?m)^## '
        Extra = @{}
    },
    @{
        Name  = "docs/agent-instructions.md"
        Path  = "docs/agent-instructions.md"
        Kind  = "bullet"
        Start = '(?m)^Commit durable Crucible files:\s*$'
        End   = '(?m)^Do not commit runtime data:'
        Extra = @{}
    },
    @{
        Name  = "powershell/lib/instruction-blocks.ps1"
        Path  = "powershell/lib/instruction-blocks.ps1"
        Kind  = "bullet"
        Start = '(?m)^Commit durable Crucible files:\s*$'
        End   = '(?m)^Do not commit runtime data:'
        Extra = @{}
    },
    @{
        Name  = "templates/project/.crucible/README.md"
        Path  = "templates/project/.crucible/README.md"
        Kind  = "bullet"
        Start = '(?m)^## Commit By Default\s*$'
        End   = '(?m)^## '
        Extra = @{}
    },
    @{
        Name  = "powershell/init-project.ps1 (scaffold summary)"
        Path  = "powershell/init-project.ps1"
        Kind  = "console-bullet"
        Start = '(?m)^\s*Write-Info\s+"Committed by default'
        End   = '(?m)^\s*Write-Info\s+""'
        Extra = @{}
    },
    @{
        Name  = "docs/bootstrap.md (What Gets Installed)"
        Path  = "docs/bootstrap.md"
        Kind  = "bullet"
        Start = '(?m)^## What Gets Installed\s*$'
        End   = '(?m)^## '
        Extra = @{
            "backlog" = "the section lists what a complete install contains, and backlog/ is installed; whether to commit it is git-policy.md subject matter, not this page's"
        }
    },
    @{
        Name  = "docs/get-started.md (project tree)"
        Path  = "docs/get-started.md"
        Kind  = "tree"
        Start = '(?m)^my-api/\s*$'
        End   = '(?m)^```'
        Extra = @{
            "backlog" = "the tree shows the installed layout, which includes backlog/"
        }
    },
    @{
        Name  = "docs/get-started.md (directory table)"
        Path  = "docs/get-started.md"
        Kind  = "table-row"
        Start = '(?m)^## What each `\.crucible/` directory holds\s*$'
        End   = '(?m)^---\s*$'
        Extra = @{
            "backlog"           = "the table carries a Commit? column and covers the not-committed directories too"
            "session"           = "runtime state, listed so the table answers the question for every directory"
            ".agent-workspaces" = "runtime state, listed so the table answers the question for every directory"
            "locks"             = "runtime state, listed so the table answers the question for every directory"
        }
    },
    @{
        # A ninth copy, found by the undeclared-page sweep below rather than by item 74, which
        # counted seven. It is the second table with a Commit column and it had drifted the
        # same way the first one had.
        Name  = "docs/config-reference.md (commit table)"
        Path  = "docs/config-reference.md"
        Kind  = "table-row"
        Start = '(?m)^## What to commit vs\. ignore\s*$'
        End   = '(?m)^---\s*$'
        Extra = @{
            "backlog"           = "the table carries a Commit column and covers the not-committed directories too"
            "session"           = "runtime state, listed so the table answers the question for every directory"
            ".agent-workspaces" = "runtime state, listed so the table answers the question for every directory"
            "locks"             = "runtime state, listed so the table answers the question for every directory"
            "research"          = "generated artifacts, listed so the table answers the question for every directory"
            "dev-logs"          = "generated artifacts, listed so the table answers the question for every directory"
        }
    }
)

$results += Run-Test -Name "Every page restating the commit-by-default list agrees with the function" -Body {
    $declared = @(Get-CommitByDefaultPath)
    Assert-Result -Name "the function returned a list" -Condition ($declared.Count -ge 1) -FailureMessage "Get-CommitByDefaultPath returned nothing, so every comparison below would be against an empty set"

    # A surface removed from the table above is a surface that stops being checked, and the
    # diff that removes one looks like the diff that fixes one. Pinning the count means
    # deleting a surface to make this pass has to be an explicit edit to a number.
    Assert-Result -Name "every known surface is still listed" -Condition ($surfaces.Count -eq 9) -FailureMessage ("this file knows about " + $surfaces.Count + " surfaces; it was written against 9. Add the new one, or say here why one went away")

    $mismatched = @()
    foreach ($surface in $surfaces) {
        $full = Join-Path $REPO_ROOT $surface.Path
        Assert-Result -Name ("found " + $surface.Name) -Condition (Test-Path -LiteralPath $full -PathType Leaf) -FailureMessage ($surface.Path + " does not exist, so its parity check below would silently decide nothing")

        $text = Get-Content -LiteralPath $full -Raw -Encoding UTF8
        $region = Get-SurfaceRegion -Text $text -Start $surface.Start -End $surface.End
        Assert-Result -Name ("located the list in " + $surface.Name) -Condition ($null -ne $region) -FailureMessage ("the anchor '" + $surface.Start + "' matched nothing in " + $surface.Path + ", so an empty extraction below would be blamed on the page instead of on this test")

        $actual = @(Get-SurfaceEntry -Kind $surface.Kind -Region $region)
        $expected = @(@($declared) + @($surface.Extra.Keys) | Sort-Object -Unique)

        $missing = @($expected | Where-Object { $actual -notcontains $_ })
        $unexpected = @($actual | Where-Object { $expected -notcontains $_ })
        if ($missing.Count -gt 0 -or $unexpected.Count -gt 0) {
            $detail = $surface.Name + ":"
            if ($missing.Count -gt 0) { $detail += " states nothing about [" + ($missing -join ", ") + "]" }
            if ($unexpected.Count -gt 0) { $detail += " names [" + ($unexpected -join ", ") + "] which the function does not return and no reason here covers" }
            $mismatched += $detail
        }
    }

    Assert-Result -Name "no page disagrees with the function" -Condition ($mismatched.Count -eq 0) -FailureMessage ("Get-CommitByDefaultPath and the prose have drifted. " + ($mismatched -join " | "))
}

# The declared-extra machinery is the one part of the parity check that can rot into an
# always-true branch: if every Extra map empties out, a surface could start naming anything
# and the reason-keyed exemption would never be exercised again.
#
# Only this aggregate is needed, unlike the exclusion map at the bottom of the file, which item
# 82 had to calibrate per entry. Each Extra key is already exercised individually by the parity
# test above: the key joins $expected, so a surface that stops naming it reports it as missing
# and fails. A stale Extra cannot sit there scoring zero the way a stale exclusion could.
$results += Run-Test -Name "The declared-extra exemption is still carrying weight" -Body {
    $withExtras = @($surfaces | Where-Object { $_.Extra.Count -gt 0 })
    Assert-Result -Name "some surface declares an extra" -Condition ($withExtras.Count -ge 1) -FailureMessage "no surface declares an extra entry any more, so the exemption path in the parity test above is dead code that still looks like a guard"

    $unexplained = @()
    foreach ($surface in $withExtras) {
        foreach ($key in $surface.Extra.Keys) {
            if ([string]::IsNullOrWhiteSpace($surface.Extra[$key])) { $unexplained += ($surface.Name + " -> " + $key) }
        }
    }
    Assert-Result -Name "every extra carries a reason" -Condition ($unexplained.Count -eq 0) -FailureMessage ("these extras are exempted with no reason written down: " + ($unexplained -join "; "))

    # An extra the function has since started returning is a stale exemption, and a stale
    # exemption silently widens what the surface is allowed to say.
    $declared = @(Get-CommitByDefaultPath)
    $stale = @()
    foreach ($surface in $withExtras) {
        foreach ($key in $surface.Extra.Keys) {
            if ($declared -contains $key) { $stale += ($surface.Name + " -> " + $key) }
        }
    }
    Assert-Result -Name "no extra names something the function now returns" -Condition ($stale.Count -eq 0) -FailureMessage ("these are exempted as extras but the function returns them, so the exemption should go: " + ($stale -join "; "))
}

# Set parity alone is a weak statement about the two surfaces that render a verdict per row.
# A table row saying "No" against a commit-by-default directory carries the whole list and
# still tells the adopter the opposite of what the function means. The two tables put the
# verdict in different columns, which is why the column index is per-table rather than
# assumed: reading the wrong cell would compare a prose description against "Yes" and report
# every row as wrong, or - worse, if the description happened to be the word - as right.
$verdictTables = @(
    @{ Name = "docs/get-started.md";    Path = "docs/get-started.md";    Start = '(?m)^## What each `\.crucible/` directory holds\s*$'; Column = 3 },
    @{ Name = "docs/config-reference.md"; Path = "docs/config-reference.md"; Start = '(?m)^## What to commit vs\. ignore\s*$';        Column = 2 }
)

$results += Run-Test -Name "Both commit tables vote Yes on everything committed by default" -Body {
    $declared = @(Get-CommitByDefaultPath)
    $wrong = @()
    foreach ($table in $verdictTables) {
        $text = Get-Content -LiteralPath (Join-Path $REPO_ROOT $table.Path) -Raw -Encoding UTF8
        $region = Get-SurfaceRegion -Text $text -Start $table.Start -End '(?m)^---\s*$'
        Assert-Result -Name ("located the table in " + $table.Name) -Condition ($null -ne $region) -FailureMessage ("the heading moved in " + $table.Path + ", so the row check below would read nothing")

        $verdicts = @{}
        foreach ($line in ($region -split "`r?`n")) {
            if ($line -notmatch '^\|') { continue }
            $cells = @($line.Trim().Trim('|') -split '\|' | ForEach-Object { $_.Trim() })
            if ($cells.Count -lt $table.Column) { continue }
            if ($cells[0] -notmatch '^`([^`]+)`$') { continue }
            $verdicts[(ConvertTo-BundleEntry -Token $matches[1])] = $cells[$table.Column - 1]
        }
        Assert-Result -Name ("rows were parsed in " + $table.Name) -Condition ($verdicts.Count -ge 1) -FailureMessage ("no row matched in " + $table.Path + ", so the verdict check below is vacuous")

        # A table that lists only entries it happens to agree with would pass the loop below
        # without ever comparing anything, so require it to have an opinion on most of them.
        $covered = @($declared | Where-Object { $verdicts.ContainsKey($_) })
        Assert-Result -Name ("the table has an opinion on the list in " + $table.Name) -Condition ($covered.Count -ge 6) -FailureMessage ($table.Path + " has rows for only " + $covered.Count + " of the " + $declared.Count + " committed entries, so its verdicts decide almost nothing")

        foreach ($entry in $covered) {
            if ($verdicts[$entry] -ne "Yes") { $wrong += ($table.Name + ": " + $entry + " = " + $verdicts[$entry]) }
        }
    }
    Assert-Result -Name "no committed directory is marked otherwise" -Condition ($wrong.Count -eq 0) -FailureMessage ("a commit table contradicts Get-CommitByDefaultPath on: " + ($wrong -join ", "))
}

# The parity test knows about nine copies. Nothing stopped a tenth, which is how the nine came
# to exist. Default-deny: a page that enumerates the bundle is a surface until somebody writes
# down why it is not.
#
# The discriminator is structure, not vocabulary. Counting how many of the twelve names a file
# mentions anywhere does not work - updating.md, operating-manual.md and config-reference.md
# all mention seven or eight of them in ordinary prose, and the one of those three that IS a
# surface scored no higher than the two that are not. What every real restatement has and no
# prose page has is a run of list lines whose LEADING token is a bundle entry. A bullet that
# opens with a sentence and mentions `powershell/` halfway through is prose; six such lines
# stacked together is a list of the bundle.
# Named with a reason rather than pattern-excluded, so an exclusion is a decision on the
# record instead of a gap in a glob.
#
# Every entry here is calibrated individually: an exclusion that no scanned file reaches fails
# the suite and names itself. It used to be one aggregate assertion - "at least one exemption
# was hit" - and item 82 measured what that bought. Two of the four entries scored a flat zero
# and the aggregate passed anyway, carried entirely by the other two, so half the map was a
# comment that looked like a guard.
$NOT_SURFACES = @{
    "README.md"                               = "the source repository's own layout, not the adopter bundle's commit policy; it names templates/ and examples/, which never ship"
    "ROADMAP.md"                              = "an abbreviated illustration of the self-contained-bundle commitment, framed as an example rather than as a complete list"
    "powershell/lib/gitignore-conformance.ps1" = "the declaring function itself"
}

# Design records, kept as written. A proposal enumerates the bundle to reason about it - the
# rename proposal has a per-directory line-count table - and correcting one to match today's
# list would falsify the record of what was true when the decision was made. Same rule TODO
# item 51 applies to historical documents.
#
# docs/audits/ had the same reason written against it and was deleted by item 82 instead of
# kept: no scorecard has ever enumerated the list, so the entry excused nothing. The reason was
# sound and is not lost - it is the answer whoever writes the first enumerating audit will
# need, and the sweep will ask them for it by failing. An exemption is earned by something
# tripping the threshold, not granted in advance.
$NOT_SURFACE_PREFIXES = @{
    "docs/proposals/" = "design records: a proposal describes the tree as it was when the decision was taken"
}

# Strip whatever punctuation the line leads with - a bullet, a table pipe, an ASCII tree elbow,
# or the opening quote of a string literal - then read the first token. Nothing in the class can
# appear inside an entry, so `.gitignore` and `.agent-workspaces` survive it intact.
#
# The quote characters were missing until item 82 and that is not a detail. The one file that
# most certainly restates the list - the declaring function's own, twelve quoted literals in a
# row - scored zero, because the opening quote blocked the token. The sweep could read markdown
# bullets and table rows and nothing else, so a .ps1 that restated the list was invisible to it
# by construction.
#
# The trailing lookahead is what makes that widening safe rather than merely broader. The
# capture stops at the first slash, so without it twelve lines of `"powershell/tests/..."` -
# install-manifest.ps1's dev-only file list - all read as the entry `powershell` and that file
# reports as an undeclared tenth surface. An entry counts only when it is the whole path
# element: followed by a quote, a backtick, whitespace or end of line, never by more path.
# Measured: with the lookahead, install-manifest.ps1 scores 0 and the declaring function
# scores 12.
#
# There is no separate optional backtick after the class, though an earlier form of this
# pattern carried one. The backtick is a class member, so the class already eats any run of
# them and an optional backtick after it can only ever match empty - it was unreachable
# rather than untested, which is why deleting it changes no score.
$LEADING_ENTRY = '^[\s|*+`''"-]*((?:\.crucible/|\{\{crucible_root\}\}/)?[A-Za-z0-9_.\-]+/?)(?![A-Za-z0-9_.\-/])'

function Measure-EnumerationRun {
    param(
        [Parameter(Mandatory=$true)][string]$Text,
        [Parameter(Mandatory=$true)][string[]]$Entry,
        [Parameter(Mandatory=$true)][string]$Pattern
    )
    $lines = @($Text -split "`r?`n")
    $isEntryLine = New-Object bool[] $lines.Count
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $match = [regex]::Match($lines[$i], $Pattern)
        if (-not $match.Success) { continue }
        $isEntryLine[$i] = ($Entry -contains (ConvertTo-BundleEntry -Token $match.Groups[1].Value))
    }
    # A sliding window rather than a whole-file count, so a page that names three entries in one
    # section and three in another - which is prose - does not read as a list.
    $window = 12
    $best = 0
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $count = 0
        for ($j = $i; $j -lt [Math]::Min($i + $window, $lines.Count); $j++) {
            if ($isEntryLine[$j]) { $count++ }
        }
        if ($count -gt $best) { $best = $count }
    }
    return $best
}

# Takes its root, its candidates and both exclusion maps as arguments rather than reading the
# repository directly, so the calibration below can run the identical code over a fixture tree
# whose answers are known. Without that the per-entry check has no test of its own: every real
# exclusion is live today, so a run that reported nothing stale would be indistinguishable from
# one that had lost the ability to report it. Deleting the seeding loop - the line that makes an
# unreached entry visible as a zero rather than as an absence - would have survived the suite.
function Invoke-UndeclaredPageSweep {
    param(
        [Parameter(Mandatory=$true)][string]$Root,
        [Parameter(Mandatory=$true)][AllowEmptyCollection()][System.IO.FileInfo[]]$Candidate,
        [Parameter(Mandatory=$true)][AllowEmptyCollection()][string[]]$SurfacePath,
        [Parameter(Mandatory=$true)][string[]]$Declared,
        [Parameter(Mandatory=$true)][hashtable]$NotSurface,
        [Parameter(Mandatory=$true)][hashtable]$NotSurfacePrefix
    )
    $undeclared = @()
    # One counter per exclusion, seeded with every declared key so an entry that is never
    # reached is visible as a zero rather than as an absence. A hashtable keyed by prefix and by
    # path together is safe: a prefix ends in a slash and a relative path to a scanned file
    # never does, so the two key spaces cannot collide.
    $hits = @{}
    foreach ($key in $NotSurface.Keys) { $hits[$key] = 0 }
    foreach ($key in $NotSurfacePrefix.Keys) { $hits[$key] = 0 }
    $scanned = 0
    foreach ($file in ($Candidate | Sort-Object FullName -Unique)) {
        $relative = ($file.FullName.Substring($Root.Length).TrimStart('\', '/')) -replace '\\', '/'
        if ($SurfacePath -contains $relative) { continue }
        $scanned++
        $text = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8
        if ([string]::IsNullOrWhiteSpace($text)) { continue }

        # Six entry-leading lines inside a twelve-line window. Every real surface clears it with
        # room to spare; the tightest is the template README at eleven of twelve.
        $run = Measure-EnumerationRun -Text $text -Entry $Declared -Pattern $LEADING_ENTRY
        if ($run -lt 6) { continue }

        $prefixKey = $null
        foreach ($prefix in $NotSurfacePrefix.Keys) {
            if ($relative.StartsWith($prefix)) { $prefixKey = $prefix; break }
        }
        if ($null -ne $prefixKey) { $hits[$prefixKey]++; continue }
        if ($NotSurface.ContainsKey($relative)) { $hits[$relative]++; continue }
        $undeclared += ($relative + " (a run of " + $run + " bundle entries)")
    }
    return @{
        Undeclared = @($undeclared)
        Stale      = @($hits.Keys | Where-Object { $hits[$_] -eq 0 } | Sort-Object)
        Scanned    = $scanned
    }
}

function Get-RepositoryCandidate {
    $found = @()
    foreach ($dir in @("docs", "sops", "prompts", "personas", "schemas", "templates")) {
        $found += @(Get-ChildItem -Path (Join-Path $REPO_ROOT $dir) -File -Recurse |
            Where-Object { $_.Extension -in @(".md", ".json", ".yaml", ".yml") })
    }
    $found += @(Get-ChildItem -Path (Join-Path $REPO_ROOT "powershell") -Filter "*.ps1" -File -Recurse |
        Where-Object { $_.FullName -notmatch '[\\/]tests[\\/]' })
    foreach ($rootDoc in @("README.md", "ROADMAP.md", "CONTRIBUTING.md")) {
        $found += @(Get-Item -LiteralPath (Join-Path $REPO_ROOT $rootDoc))
    }
    return @($found)
}

$results += Run-Test -Name "No undeclared page enumerates the commit-by-default list" -Body {
    $declared = @(Get-CommitByDefaultPath)
    $surfacePaths = @($surfaces | ForEach-Object { $_.Path } | Sort-Object -Unique)

    $candidates = @(Get-RepositoryCandidate)
    Assert-Result -Name "candidate files were found" -Condition ($candidates.Count -ge 20) -FailureMessage ("only " + $candidates.Count + " files to scan, so a clean result below would mean the sweep read nothing")

    # Before scanning anything, prove the sweep can see a list at all. A pattern that matched
    # nothing, or a threshold set above what a real enumeration reaches, would report the tree
    # clean forever - and the nine known surfaces are exactly the fixtures that settle it.
    #
    # This runs FIRST on purpose. It was written last and placed last, where the mutation that
    # breaks the pattern never reached it: the scan below finds nothing, so no exempted file
    # trips the threshold, so the calibration assertion throws and the run ends two assertions
    # early. The mutation still died, which is what made it look tested. It was not - the
    # assertion written to catch it had never once executed, which is the same defect item 71
    # found in its own battery. An assertion downstream of another assertion's failure is not
    # a guard, it is a comment.
    #
    # Eight surface files carry nine surfaces, and the bar is six of them rather than all
    # eight, because init-project.ps1 scores zero: its restatement is console output, which
    # this pattern cannot reach at all. That is a known and recorded limit, not slack - it is
    # already a checked surface, so what goes unguarded is only a *tenth* surface written in
    # the same form.
    $sawSurfaces = 0
    foreach ($surfacePath in $surfacePaths) {
        $text = Get-Content -LiteralPath (Join-Path $REPO_ROOT $surfacePath) -Raw -Encoding UTF8
        if ((Measure-EnumerationRun -Text $text -Entry $declared -Pattern $LEADING_ENTRY) -ge 6) { $sawSurfaces++ }
    }
    Assert-Result -Name "the sweep can see a known surface" -Condition ($sawSurfaces -ge 6) -FailureMessage ("the sweep recognised only " + $sawSurfaces + " of the " + $surfacePaths.Count + " pages already known to restate the list, so its verdict on everything else would mean nothing")

    $sweep = Invoke-UndeclaredPageSweep -Root $REPO_ROOT -Candidate $candidates -SurfacePath $surfacePaths -Declared $declared -NotSurface $NOT_SURFACES -NotSurfacePrefix $NOT_SURFACE_PREFIXES

    Assert-Result -Name "files outside the known surfaces were scanned" -Condition ($sweep.Scanned -ge 20) -FailureMessage ("only " + $sweep.Scanned + " non-surface files were read, so the sweep proves little")

    # Per entry, not in aggregate. The aggregate form of this assertion passed for months while
    # half the map scored zero, because two live entries are enough to satisfy "at least one".
    # An exclusion nothing reaches is either a file that stopped enumerating the list, in which
    # case delete it, or a pattern that cannot see the file it names, which is the defect item
    # 82 was filed for.
    Assert-Result -Name "every exclusion was exercised" -Condition ($sweep.Stale.Count -eq 0) -FailureMessage ("these exclusions were never reached by the sweep, so each one excuses nothing and is not calibrated against anything: " + ($sweep.Stale -join "; "))

    Assert-Result -Name "no undeclared page enumerates the list" -Condition ($sweep.Undeclared.Count -eq 0) -FailureMessage ("these enumerate the commit-by-default list but are neither a checked surface nor an exempted file: " + ($sweep.Undeclared -join "; "))

    # The sweep credits a hit to the prefix map before the path map, and nothing about that order
    # is principled - it is a tie-break invented for a case that does not exist. Rather than
    # promote it to a precedence rule nobody asked for, keep the two maps disjoint, so a path
    # exclusion under an excluded prefix is a failure here instead of a silently unreachable
    # counter that reports itself stale while the file it names is excused anyway.
    $overlapping = @()
    foreach ($path in $NOT_SURFACES.Keys) {
        foreach ($prefix in $NOT_SURFACE_PREFIXES.Keys) {
            if ($path.StartsWith($prefix)) { $overlapping += ($path + " is already covered by the prefix " + $prefix) }
        }
    }
    Assert-Result -Name "the two exclusion maps are disjoint" -Condition ($overlapping.Count -eq 0) -FailureMessage ("an exclusion listed in both maps can only ever be credited to one of them, which leaves the other reporting stale for a file that is in fact excused: " + ($overlapping -join "; "))
}

# The assertion above reports what the repository happens to contain, and today the repository
# contains no stale exclusion - which is the point of the item, and also the reason that
# assertion proves nothing about itself. Run the same function over a tree built to contain one.
$results += Run-Test -Name "An exclusion the sweep never reaches is reported by name" -Body {
    $declared = @(Get-CommitByDefaultPath)
    $root = Join-Path (Get-TestRunRoot) ("sweep-calibration-" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $root "records") -Force | Out-Null
    try {
        # Every quote form the leading class admits gets its own fixture file, because a class
        # member no file exercises is a member nothing can prove is needed: markdown bullets,
        # double-quoted literals and single-quoted literals. The declaring function happens to
        # use double quotes, so without the third file the single quote in the class could be
        # deleted and the whole suite would stay green.
        $bullets = (@("# a page") + @($declared | ForEach-Object { "- ``$_``" })) -join "`n"
        $literals = (@("`$x = @(") + @($declared | ForEach-Object { '    "' + $_ + '",' }) + @(")")) -join "`n"
        $singles = (@("`$y = @(") + @($declared | ForEach-Object { "    '" + $_ + "'," }) + @(")")) -join "`n"

        Set-Content -LiteralPath (Join-Path $root "enumerates.md") -Value $bullets -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $root "prose.md") -Value "Nothing here lists the bundle.`nIt just mentions powershell/ in a sentence." -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $root "records/in-quotes.ps1") -Value $literals -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $root "in-single-quotes.ps1") -Value $singles -Encoding UTF8

        $candidates = @(Get-ChildItem -Path $root -File -Recurse)
        Assert-Result -Name "the fixture tree was built" -Condition ($candidates.Count -eq 4) -FailureMessage ("expected 4 fixture files, found " + $candidates.Count + ", so the verdicts below would be about a different tree")

        $notSurface = @{
            "enumerates.md"       = "reached: this file does enumerate the list"
            "in-single-quotes.ps1" = "reached: single-quoted literals, the one quote form no real file uses"
            "prose.md"            = "unreached: this file does not enumerate the list, so the exclusion excuses nothing"
        }
        $notSurfacePrefix = @{
            "records/" = "reached: the quoted-literal file lives here"
            "absent/"  = "unreached: no candidate is under this prefix"
        }

        $sweep = Invoke-UndeclaredPageSweep -Root $root -Candidate $candidates -SurfacePath @() -Declared $declared -NotSurface $notSurface -NotSurfacePrefix $notSurfacePrefix

        Assert-Result -Name "all four fixture files were scanned" -Condition ($sweep.Scanned -eq 4) -FailureMessage ("the sweep read " + $sweep.Scanned + " of 4 fixture files")
        Assert-Result -Name "nothing in the fixture is undeclared" -Condition ($sweep.Undeclared.Count -eq 0) -FailureMessage ("every enumerating fixture is excluded, so nothing should be reported undeclared, but got: " + ($sweep.Undeclared -join "; "))

        # The whole point: two exclusions are live and two are not, and the aggregate form of
        # this check - "at least one was hit" - would pass on exactly this input.
        Assert-Result -Name "the unreached path exclusion is named" -Condition ($sweep.Stale -contains "prose.md") -FailureMessage ("prose.md does not enumerate the list, so its exclusion is stale and should have been reported; stale set was [" + ($sweep.Stale -join ", ") + "]")
        Assert-Result -Name "the unreached prefix exclusion is named" -Condition ($sweep.Stale -contains "absent/") -FailureMessage ("no candidate lives under absent/, so its exclusion is stale and should have been reported; stale set was [" + ($sweep.Stale -join ", ") + "]")
        Assert-Result -Name "the reached path exclusion is not named" -Condition ($sweep.Stale -notcontains "enumerates.md") -FailureMessage "enumerates.md does enumerate the list and was excluded for it, so reporting it stale would make every live exclusion a false alarm"
        Assert-Result -Name "the reached prefix exclusion is not named" -Condition ($sweep.Stale -notcontains "records/") -FailureMessage "the quoted-literal file under records/ enumerates the list, so that prefix was reached and must not be reported stale"
        Assert-Result -Name "the single-quoted enumeration was read" -Condition ($sweep.Stale -notcontains "in-single-quotes.ps1") -FailureMessage "a list written as single-quoted literals enumerates the bundle just as plainly as one written in double quotes; reporting its exclusion stale means the leading class stopped admitting the single quote"
        Assert-Result -Name "exactly the two unreached exclusions are named" -Condition ($sweep.Stale.Count -eq 2) -FailureMessage ("expected exactly 2 stale exclusions, got " + $sweep.Stale.Count + ": [" + ($sweep.Stale -join ", ") + "]")
    } finally {
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
}

$failed = @($results | Where-Object { -not $_ }).Count
if ($failed -gt 0) {
    Write-Host ("`n$failed commit-by-default parity test(s) failed.") -ForegroundColor Red
    exit 1
}
Write-Host "`nAll commit-by-default parity tests passed." -ForegroundColor Green
exit 0
