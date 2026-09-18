# Tests that every bundle file a prompt, SOP or persona tells a specialist to read is a
# file a fresh install actually materializes.
#
# The deployment prompt and SOP both said to draft the dev log "using
# `.crucible/dev-logs/TEMPLATE.md`". No such file shipped, and no such file was ever
# created at runtime either, so the Operator improvised a format - which is the failure
# mode a template exists to prevent. Found by TODO item 53's Pass 29 and filed as item 57.
#
# The default here is deliberately "must ship". A path that is genuinely produced at
# runtime has to be named in $runtimeCreatedPaths below, which makes each exemption a
# decision somebody wrote down rather than a gap nothing looked for.

$ErrorActionPreference = "Stop"
$REPO_ROOT = (Resolve-Path -Path "$PSScriptRoot/../..").Path
. (Join-Path $PSScriptRoot '_harness.ps1')
. (Join-Path $REPO_ROOT "powershell/lib/install-manifest.ps1")

$results = @()

# Directories the pipeline creates and fills as it runs. A document may name a path under
# these because it will exist by the time the document is read.
$runtimeDirs = @("session", ".agent-workspaces", "locks", "backlog")

# Individual paths that do not ship and are not under a runtime directory. Each entry
# needs a reason and, where it is a defect rather than a design choice, an item number.
$runtimeCreatedPaths = @{
    # The Operator appends the first entry, which creates the file. Named individually
    # rather than exempting dev-logs/ wholesale, because a directory-wide exemption there
    # is exactly what would have hidden item 57.
    "dev-logs/UNPUBLISHED_LOGS.md" = "created by the Operator appending the first entry"
}

$results += Run-Test -Name "Documented bundle paths exist in a fresh install" -Body {
    $manifest = Get-InstallManifest -FrameworkRoot $REPO_ROOT
    $installed = New-Object System.Collections.Generic.HashSet[string] ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($source in @(Get-FrameworkOwnedFiles -FrameworkRoot $REPO_ROOT)) {
        foreach ($adopterPath in @(Get-AdopterPathsForSource -SourcePath $source -Manifest $manifest)) {
            if ([string]::IsNullOrWhiteSpace($adopterPath)) { continue }
            [void]$installed.Add($adopterPath)
        }
    }
    Assert-Result -Name "install file set was built" -Condition ($installed.Count -gt 0) -FailureMessage "the install manifest yielded no files, so every path below would look missing or the scan would be vacuous"

    $docDirs = @("prompts", "sops", "personas")
    $docFiles = @()
    foreach ($docDir in $docDirs) {
        $docFiles += @(Get-ChildItem -Path (Join-Path $REPO_ROOT $docDir) -Filter "*.md" -File -Recurse)
    }
    Assert-Result -Name "instruction documents were found" -Condition ($docFiles.Count -ge 1) -FailureMessage ("no *.md under " + ($docDirs -join ", ") + ", so the scan below would report clean without reading anything")

    $missing = @()
    $checked = 0
    foreach ($docFile in $docFiles) {
        $text = Get-Content -LiteralPath $docFile.FullName -Raw -Encoding UTF8
        # Not anchored on backticks. sops/registry.md wraps a whole trigger sentence in
        # one pair (`Follow the procedure in .crucible/sops/health-check.md`), so a
        # backtick-adjacent pattern reads right past every SOP the registry names.
        foreach ($match in [regex]::Matches($text, '\.crucible/([A-Za-z0-9_./{}<>*-]+)')) {
            $relative = $match.Groups[1].Value.TrimEnd('.', ',', ';', ':', ')')

            # A path with a placeholder in it names a family, not a file. The three
            # spellings all appear: {task_id}, <YYYYMMDD> and a bare glob.
            if ($relative.IndexOfAny([char[]]@('{', '<', '*')) -ge 0) { continue }
            # A trailing slash names the directory, not a file to read.
            if ($relative.EndsWith("/")) { continue }
            if ($runtimeDirs -contains ($relative -split "/")[0]) { continue }
            if ($runtimeCreatedPaths.ContainsKey($relative)) { continue }

            $checked++
            if (-not $installed.Contains($relative)) {
                $missing += ($docFile.Name + " -> .crucible/" + $relative)
            }
        }
    }

    Assert-Result -Name "documented paths were actually checked" -Condition ($checked -gt 0) -FailureMessage "no concrete bundle paths survived filtering, so the assertion below proves nothing"
    Assert-Result -Name "every documented bundle path ships" -Condition ($missing.Count -eq 0) -FailureMessage ("these documents name bundle files that no install materializes: " + (($missing | Sort-Object -Unique) -join "; "))
}

# The scan above only sees paths written with the .crucible/ prefix. A dev-only file is
# just as unreachable when a shipping document names it repo-relative, which is how the
# framework audit SOP and its scorecard refer to each other now that neither ships. This
# checks the other direction: no document an adopter receives may name a file it will not.
$results += Run-Test -Name "Shipping documents do not name dev-only files" -Body {
    # docs/ was missing from this list until item 81. Every mirrored document under it -
    # 23 files, policy.md and operating-manual.md among them - went unscanned, which is why
    # five unqualified references to dev-only gates survived here while this test was green.
    # The scan was scoped to the three directories that were already clean, so it could only
    # ever confirm what was already known. Item 80's mechanic, on the documentation side.
    $docDirs = @("docs", "prompts", "sops", "personas")
    $docFiles = @()
    foreach ($docDir in $docDirs) {
        $docFiles += @(Get-ChildItem -Path (Join-Path $REPO_ROOT $docDir) -Filter "*.md" -File -Recurse)
    }
    Assert-Result -Name "instruction documents were found" -Condition ($docFiles.Count -ge 1) -FailureMessage ("no *.md under " + ($docDirs -join ", ") + ", so the scan below would report clean without reading anything")

    # Anchored on the framework's own top-level directories and a file extension, so
    # prose about a directory does not register as a path.
    $pathPattern = '(?:\.crucible/)?((?:docs|sops|prompts|personas|powershell|schemas|scripts|templates)/[A-Za-z0-9_./-]+\.[A-Za-z0-9]+)'

    # A shipping document may name a dev-only file when it says, on that line, that the
    # thing is the framework repo's own. That is a real need: the operating manual documents
    # how Crucible is developed as well as how it is used, and the alternative is deleting
    # true statements. The marker is prose rather than an exemption list on purpose - item
    # 81 requires this mapping to be derived from Test-FrameworkDevOnlyFile, and a second
    # hand-kept list of allowed pairs is exactly the thing that falls behind the first.
    #
    # Asymmetric, and deliberately so. A file moving ONTO the dev-only list makes every
    # unmarked mention fail here, which is the direction that misleads an adopter. A file
    # moving OFF it leaves a marker that is merely redundant, not wrong, and no check below
    # catches that - a stale-marker scan would have to flag every line that says "framework
    # repo" while naming a file that ships, which is ordinary correct prose.
    $frameworkScopeMarker = 'framework repo'

    # The path pattern above only sees a reference that carries its directory. Both defects
    # item 81 was filed about write the gate as a bare `check-assertion-deletion.ps1`, so a
    # path-only scan reported clean on the very lines that prompted it. Basenames are derived
    # from the tree rather than listed: every file the install enumerator can see, partitioned
    # by Test-FrameworkDevOnlyFile, which keeps this in step with the list by construction.
    #
    # A basename shared with a shipping file is dropped rather than guessed at. Naming
    # `platform.ps1` is unambiguous only while one file is called that, and a false positive
    # here would push an author toward deleting a true sentence.
    $shippingBasenames = New-Object System.Collections.Generic.HashSet[string] ([System.StringComparer]::OrdinalIgnoreCase)
    $devOnlyBasenames = New-Object System.Collections.Generic.HashSet[string] ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($tracked in @(git -C $REPO_ROOT ls-files)) {
        if ([string]::IsNullOrWhiteSpace($tracked)) { continue }
        $leaf = [System.IO.Path]::GetFileName($tracked)
        if (Test-FrameworkDevOnlyFile -Path $tracked) { [void]$devOnlyBasenames.Add($leaf) }
        else { [void]$shippingBasenames.Add($leaf) }
    }
    $ambiguous = @($devOnlyBasenames | Where-Object { $shippingBasenames.Contains($_) })
    foreach ($name in $ambiguous) { [void]$devOnlyBasenames.Remove($name) }
    Assert-Result -Name "dev-only basenames were derived" -Condition ($devOnlyBasenames.Count -gt 0) -FailureMessage "no unambiguous dev-only basename came out of the tree, so the bare-filename scan below would read every document as clean"

    $offenders = @()
    $devOnlyDocsSeen = 0
    # Counted per scan, not pooled. A single total lets either scan cover for the other
    # having gone dead, which is the trap the scorecard test below this one already warns
    # about - and pooling them is exactly the mistake that warning describes. Deleting the
    # basename scan outright left a pooled count above zero and the whole test green.
    $pathMarked = 0
    $basenameMarked = 0
    foreach ($docFile in $docFiles) {
        $docRelative = ($docFile.FullName.Substring($REPO_ROOT.Length).TrimStart('\', '/')) -replace '\\', '/'
        # A dev-only document may name dev-only files; that is the point of it.
        if (Test-FrameworkDevOnlyFile -Path $docRelative) { $devOnlyDocsSeen++; continue }

        foreach ($line in (Get-Content -LiteralPath $docFile.FullName -Encoding UTF8)) {
            $isMarked = $line -match $frameworkScopeMarker
            $seenOnLine = New-Object System.Collections.Generic.HashSet[string] ([System.StringComparer]::OrdinalIgnoreCase)
            foreach ($match in [regex]::Matches($line, $pathPattern)) {
                $referenced = $match.Groups[1].Value.TrimEnd('.', ',', ';', ':', ')')
                if ($referenced.IndexOfAny([char[]]@('{', '<', '*')) -ge 0) { continue }
                [void]$seenOnLine.Add([System.IO.Path]::GetFileName($referenced))
                if (-not (Test-FrameworkDevOnlyFile -Path $referenced)) { continue }
                if ($isMarked) { $pathMarked++; continue }
                $offenders += ($docRelative + " -> " + $referenced)
            }
            # Backtick-quoted so prose that merely says the gate's name in passing does not
            # register; a document telling a reader to run something writes it as code.
            foreach ($match in [regex]::Matches($line, '`([A-Za-z0-9_.-]+\.(?:ps1|sh|go|md))`')) {
                $leaf = $match.Groups[1].Value
                # Already accounted for as a full path on this same line.
                if ($seenOnLine.Contains($leaf)) { continue }
                if (-not $devOnlyBasenames.Contains($leaf)) { continue }
                if ($isMarked) { $basenameMarked++; continue }
                $offenders += ($docRelative + " -> " + $leaf)
            }
        }
    }

    Assert-Result -Name "the dev-only exclusion was exercised" -Condition ($devOnlyDocsSeen -gt 0) -FailureMessage "no document under prompts, sops or personas is dev-only, so this test cannot distinguish a working check from a broken Test-FrameworkDevOnlyFile"
    # Without this, deleting every framework-scoped mention would read as success, and so
    # would a $frameworkScopeMarker that stopped matching anything - the marker branch would
    # be dead and nothing would say so.
    Assert-Result -Name "the path scan reached a marked dev-only mention" -Condition ($pathMarked -gt 0) -FailureMessage "no shipping document names a dev-only file by a directory-bearing path on a line marked as the framework repo's own, so the path scan's marker branch is dead and this test cannot tell a working marker from a broken one"
    Assert-Result -Name "the basename scan reached a marked dev-only mention" -Condition ($basenameMarked -gt 0) -FailureMessage "no shipping document names a dev-only file by a bare backticked filename on a marked line, so the basename scan is matching nothing. Deleting that scan entirely leaves this test green without it, which is how it would rot unnoticed - the two references item 81 was filed about are both bare filenames."
    Assert-Result -Name "no shipping document names a dev-only file" -Condition ($offenders.Count -eq 0) -FailureMessage ("these documents ship but name files that do not, and do not say on the same line that the file is the framework repo's own: " + (($offenders | Sort-Object -Unique) -join "; "))
}

# An exemption that outlives the gap it described turns back into the silent default this
# file exists to prevent, so a listed path that has started shipping must be removed.
$results += Run-Test -Name "Known-unshipped exemptions are still unshipped" -Body {
    $manifest = Get-InstallManifest -FrameworkRoot $REPO_ROOT
    $installed = New-Object System.Collections.Generic.HashSet[string] ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($source in @(Get-FrameworkOwnedFiles -FrameworkRoot $REPO_ROOT)) {
        foreach ($adopterPath in @(Get-AdopterPathsForSource -SourcePath $source -Manifest $manifest)) {
            if ([string]::IsNullOrWhiteSpace($adopterPath)) { continue }
            [void]$installed.Add($adopterPath)
        }
    }

    $stale = @($runtimeCreatedPaths.Keys | Where-Object { $installed.Contains($_) } | Sort-Object)
    Assert-Result -Name "no exemption covers a path that now ships" -Condition ($stale.Count -eq 0) -FailureMessage ("these paths ship now and should be removed from `$runtimeCreatedPaths: " + ($stale -join ", "))
}

# The template item 57 was filed about, named specifically. The scan above would also
# catch its removal, but only while some document still references it; this fails if the
# reference and the file disappear together.
$results += Run-Test -Name "The dev log entry template ships" -Body {
    $manifest = Get-InstallManifest -FrameworkRoot $REPO_ROOT
    $adopterPaths = @(Get-AdopterPathsForSource -SourcePath "templates/dev-log-entry.md" -Manifest $manifest)
    Assert-Result -Name "template is framework-owned" -Condition ($adopterPaths -contains "templates/dev-log-entry.md") -FailureMessage "templates/dev-log-entry.md is not installed by the manifest"
    Assert-Result -Name "template exists" -Condition (Test-Path -LiteralPath (Join-Path $REPO_ROOT "templates/dev-log-entry.md") -PathType Leaf) -FailureMessage "templates/dev-log-entry.md is missing"

    # validate-dev-log.ps1 rejects any published log mentioning the bundle directory. A
    # template carrying one would hand the Operator a guaranteed validation failure.
    $template = Get-Content -LiteralPath (Join-Path $REPO_ROOT "templates/dev-log-entry.md") -Raw -Encoding UTF8
    Assert-Result -Name "template survives the dev log validator" -Condition ($template -notmatch '\.crucible') -FailureMessage "templates/dev-log-entry.md names the bundle directory, which validate-dev-log.ps1 rejects"
}

# The two scans above ask whether a documented path ships. Neither asks whether git will
# keep it. An adopter authors their own audit scorecard rather than receiving one, and the
# SOP told them to put it at `.crucible/research/scorecard-{project}.md` - a directory the
# bundle's own .gitignore excludes. Every adopter's audit standard was therefore untracked:
# never reviewed, and gone on the next clone with nothing left to say what it used to
# require. The first scan skips placeholder paths by design, so nothing looked at this one.
# Found by TODO item 67.
$results += Run-Test -Name "A documented scorecard is not at a path the bundle ignores" -Body {
    $ignoreTemplate = Join-Path $REPO_ROOT "templates/project/.crucible/gitignore"
    Assert-Result -Name "the scaffold ignore file was found" -Condition (Test-Path -LiteralPath $ignoreTemplate -PathType Leaf) -FailureMessage "no scaffold gitignore at templates/project/.crucible/gitignore, so the check below decides nothing"

    # Only the two declaration sites count: the `**Scorecard:**` line a specialist reads to
    # find the file, and the scorecard's row in the SOP's Inputs Required table. Prose
    # elsewhere names the old location on purpose, to say it has to move. An earlier draft
    # scanned every mention and allowlisted that one path instead, which switched the check
    # off for the exact path it exists to catch: reverting either declaration to
    # `research/` passed. Scan what declares, not what mentions.
    $headerPattern = '(?m)^\s*\*\*Scorecard:\*\*[^\r\n]*?\.crucible/([A-Za-z0-9_./{}<>*-]+\.md)'
    $rowPattern = '(?m)^\s*\|\s*Scorecard\s*\|[^\r\n]*?\.crucible/([A-Za-z0-9_./{}<>*-]+\.md)'

    $docDirs = @("prompts", "sops", "personas", "docs")
    $declared = New-Object System.Collections.Generic.HashSet[string] ([System.StringComparer]::OrdinalIgnoreCase)
    $headerHits = 0
    $rowHits = 0
    foreach ($docDir in $docDirs) {
        foreach ($docFile in @(Get-ChildItem -Path (Join-Path $REPO_ROOT $docDir) -Filter "*.md" -File -Recurse)) {
            $docRelative = ($docFile.FullName.Substring($REPO_ROOT.Length).TrimStart('\', '/')) -replace '\\', '/'
            if (Test-FrameworkDevOnlyFile -Path $docRelative) { continue }
            $text = Get-Content -LiteralPath $docFile.FullName -Raw -Encoding UTF8
            foreach ($match in [regex]::Matches($text, $headerPattern)) {
                $headerHits++
                [void]$declared.Add($match.Groups[1].Value)
            }
            foreach ($match in [regex]::Matches($text, $rowPattern)) {
                $rowHits++
                [void]$declared.Add($match.Groups[1].Value)
            }
        }
    }

    # One assertion per pattern rather than one count over both: a pattern that has stopped
    # matching reports the same clean result as a document that declares a tracked path,
    # and a shared count would let the surviving pattern cover for the broken one.
    Assert-Result -Name "a scorecard header declaration was found" -Condition ($headerHits -ge 1) -FailureMessage "no shipping document carries a **Scorecard:** line naming a bundle path, so the header pattern proves nothing"
    Assert-Result -Name "a scorecard input-table row was found" -Condition ($rowHits -ge 1) -FailureMessage "no shipping document carries a Scorecard row in an Inputs Required table, so the row pattern proves nothing"

    # Ask git rather than reimplementing its pattern rules. `/research/` excludes the
    # directory itself, and git does not descend into an excluded directory - which is why
    # a `!research/scorecard-*.md` negation could never have rescued the old location.
    $probe = New-TestFixtureRoot -NameHint "scorecard-ignore"
    try {
        $null = git -C $probe init --quiet 2>$null
        Copy-Item -LiteralPath $ignoreTemplate -Destination (Join-Path $probe ".gitignore") -Force

        $ignored = @()
        $errored = @()
        foreach ($relative in @($declared | Sort-Object)) {
            # try/catch, because $ErrorActionPreference = "Stop" at the top of this file
            # turns anything git writes to stderr into a terminating error. Without it the
            # exit-code check below is unreachable and only looks like a guard.
            $exit = $null
            try {
                $null = git -C $probe check-ignore --no-index -q -- $relative 2>$null
                $exit = $LASTEXITCODE
            } catch {
                $exit = "threw: " + $_.Exception.Message
            }
            # 0 = ignored, 1 = not ignored, anything else is git failing to answer, which
            # would otherwise read as "not ignored" and pass.
            if ($exit -eq 0) { $ignored += $relative }
            elseif ($exit -ne 1) { $errored += ($relative + " (" + $exit + ")") }
        }

        Assert-Result -Name "git answered for every declared path" -Condition ($errored.Count -eq 0) -FailureMessage ("git check-ignore could not decide these paths: " + ($errored -join "; "))
        Assert-Result -Name "no declared scorecard sits in an ignored directory" -Condition ($ignored.Count -eq 0) -FailureMessage ("the bundle's own .gitignore excludes these declared scorecard paths, so an adopter's audit standard would never be committed: " + ($ignored -join ", "))
    } finally {
        Remove-Item -LiteralPath $probe -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# The two scans above ask whether a documented BUNDLE path ships. Nine framework documents
# told a reader to go read `OPERATING_MANUAL.md`, a file that has never existed under any
# name, in this repository or any bundle. Four of the nine were inside docs/ itself - out of
# scope for every scan above, which reads only prompts/, sops/ and personas/ - and the rest
# carried no `.crucible/` prefix for the .crucible/-anchored scan above to see, or were bare
# basenames the dev-only scan's own machinery reads for a different question. "A document
# names a file that does not exist" is strictly larger than "a documented bundle path does
# not ship", and this test asks the larger question: does the file a document names exist at
# all, in the repository or the install set, regardless of directory or prefix spelling.
# Item 98.
#
# Unit of reference: a backtick-quoted token that names a file - either a path carrying one
# of the framework's own top-level directories, with or without the `.crucible/` prefix a
# bundle path needs, or a bare filename with a recognized extension. Backtick-quoting is the
# same precedent the dev-only basename scan above already relies on ("a document telling a
# reader to run something writes it as code"); prose that mentions a filename with no
# backticks is not a claim the file exists and is not scanned. A first draft without that
# restriction, scanning docs/ for any word shaped like a filename, matched illustrative
# examples, adopter-facing prose and sample tool output at a rate that would have forced
# either an exemption list too long to be credible or a loosened pattern that stopped finding
# anything - backtick-quoting is what keeps the false-positive rate reviewable.
$results += Run-Test -Name "Documented file references resolve to a real file" -Body {
    $manifest = Get-InstallManifest -FrameworkRoot $REPO_ROOT
    $installed = New-Object System.Collections.Generic.HashSet[string] ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($source in @(Get-FrameworkOwnedFiles -FrameworkRoot $REPO_ROOT)) {
        foreach ($adopterPath in @(Get-AdopterPathsForSource -SourcePath $source -Manifest $manifest)) {
            if ([string]::IsNullOrWhiteSpace($adopterPath)) { continue }
            [void]$installed.Add($adopterPath)
        }
    }

    # Case-sensitive here, unlike $installed above. $installed stays OrdinalIgnoreCase because
    # the rest of this file already treats a materialized bundle that way. The repository is
    # not: git is case-sensitive, and `OPERATING_MANUAL.md` / `operating-manual.md` are two
    # different strings to it even setting case aside (`_` is not `-`). A case-insensitive
    # repo check would call a same-case-different-spelling reference resolved when git would
    # not, which is exactly the class of defect this test exists to catch.
    $tracked = @(git -C $REPO_ROOT ls-files)
    $trackedPaths = New-Object System.Collections.Generic.HashSet[string] ([System.StringComparer]::Ordinal)
    $trackedBasenames = New-Object System.Collections.Generic.HashSet[string] ([System.StringComparer]::Ordinal)
    foreach ($t in $tracked) {
        if ([string]::IsNullOrWhiteSpace($t)) { continue }
        $rel = $t -replace '\\', '/'
        [void]$trackedPaths.Add($rel)
        [void]$trackedBasenames.Add([System.IO.Path]::GetFileName($rel))
    }
    $installedBasenames = New-Object System.Collections.Generic.HashSet[string] ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($i in $installed) { [void]$installedBasenames.Add([System.IO.Path]::GetFileName($i)) }

    $docDirs = @("docs", "prompts", "sops", "personas")
    $docFiles = @()
    foreach ($docDir in $docDirs) {
        $docFiles += @(Get-ChildItem -Path (Join-Path $REPO_ROOT $docDir) -Filter "*.md" -File -Recurse)
    }
    Assert-Result -Name "instruction documents were found for reference resolution" -Condition ($docFiles.Count -ge 1) -FailureMessage ("no *.md under " + ($docDirs -join ", ") + ", so the scan below would report clean without reading anything")

    # Pass 1: a runtime-created file is named throughout these documents by a full path under
    # one of $runtimeDirs, and by a bare basename everywhere else - `task.md`, `prompt.md`,
    # `session_state.json` and the rest are real filenames, just never repo or bundle ones.
    # Deriving the allowed basenames from the full-path mentions, rather than hand-listing
    # them, keeps this in step with $runtimeDirs by construction instead of by memory - the
    # same reasoning the dev-only basename scan above applies to $devOnlyBasenames.
    $runtimeBasenames = New-Object System.Collections.Generic.HashSet[string] ([System.StringComparer]::Ordinal)
    foreach ($key in $runtimeCreatedPaths.Keys) { [void]$runtimeBasenames.Add(($key -split '/')[-1]) }
    $runtimeDirAlternation = ($runtimeDirs | ForEach-Object { [regex]::Escape($_) }) -join '|'
    $runtimePathPattern = '(?:\.crucible/)?((?:' + $runtimeDirAlternation + ')/[A-Za-z0-9_./{}<>*-]+)'
    foreach ($docFile in $docFiles) {
        $text = Get-Content -LiteralPath $docFile.FullName -Raw -Encoding UTF8
        foreach ($match in [regex]::Matches($text, $runtimePathPattern)) {
            $relative = $match.Groups[1].Value.TrimEnd('.', ',', ';', ':', ')')
            if ($relative.EndsWith("/")) { continue }
            $leaf = ($relative -split '/')[-1]
            if ($leaf.IndexOfAny([char[]]@('{', '<', '*')) -ge 0) { continue }
            if ($leaf -notmatch '\.[A-Za-z0-9]+$') { continue }
            [void]$runtimeBasenames.Add($leaf)
        }
    }
    Assert-Result -Name "runtime basenames were derived from a full path" -Condition ($runtimeBasenames.Count -gt $runtimeCreatedPaths.Count) -FailureMessage "no full-path mention under a runtime directory yielded a basename, so the derived allowlist below is only the hand-listed exemptions and this pass is dead"

    # Exemptions below are default-deny: a reference that resolves against neither the
    # repository nor the install set fails unless it is named here, with a reason, exactly as
    # $runtimeCreatedPaths works above. Each was hand-reviewed against item 98's own warning
    # that a quiet scan proves nothing - loosening the pattern to stop finding these was
    # rejected in favour of naming why each one is not the defect this test exists to catch.
    $unresolvablePathExemptions = @{
        # docs/git-policy.md quotes a sample gate line to show what its output looks like;
        # the filenames inside that sample are illustration, not a claim this repository has
        # them.
        "scripts/build.sh" = "sample gate output shown as an illustration in docs/git-policy.md, not a real path"
        # prompts/verification_prompt.md's shortcut runs inside the ADOPTER project's own
        # worktree (`.crucible/.agent-workspaces/implementation-{task_id}`), not this
        # repository. scripts/ here names a convention an adopter's own project may or may
        # not have, the same way `go mod tidy` two lines earlier names a Go convention.
        "scripts/ci_check.sh" = "adopter project's own worktree script, not a Crucible path"
    }
    $unresolvableBasenameExemptions = @{
        # The real files are timestamped - `{task_id}-{timestamp}.json` per
        # docs/handoff-protocol.md - so "handoff.json" never exists as a literal filename by
        # design. It names the artifact's kind, not a path any document expects a reader to
        # open.
        "handoff.json" = "generic name for the timestamped handoff file; no literal handoff.json is ever created"
        # Written to the bundle root by the installer/updater (Get-ProvenanceManifestPath in
        # install-manifest.ps1), never by anything this repository ships, so it can never
        # appear in $trackedPaths or $installed - the same shape of gap $runtimeCreatedPaths
        # exists to name above, for a file at the bundle root rather than under a runtime dir.
        "install-provenance.json" = "written by the installer/updater at the bundle root; the framework repo never contains a copy of its own bundle's provenance file"
        # sops/health-check.md names it to say not to use it. A sentence documenting that a
        # file is deprecated is not an instruction to go read it - the opposite of the defect
        # item 98 is about, a mandatory-toned pointer to a file that cannot be found.
        "ARCHIVED.md" = "named to say it is deprecated and must not be used, not read"
        # docs/get-started.md illustrates reading a version field from an adopter's own
        # Node.js manifest. package.json is never a Crucible path under any of $docDirs.
        "package.json" = "illustrative example of an adopter project's own file, not a Crucible path"
        # docs/operating-manual.md's own filename-convention example, marked "(e.g. ...)" - a
        # fictional backlog id chosen to demonstrate the pattern, never a real spec.
        "F-042_Add_Rate_Limiting.md" = "fictional example backlog filename demonstrating the naming convention, never a real spec"
    }

    $pathExemptionsUsed = New-Object System.Collections.Generic.HashSet[string] ([System.StringComparer]::OrdinalIgnoreCase)
    $basenameExemptionsUsed = New-Object System.Collections.Generic.HashSet[string] ([System.StringComparer]::OrdinalIgnoreCase)

    # Pass 2: a path carrying one of the framework's own top-level directories, with or
    # without the `.crucible/` prefix a bundle path needs - so `docs/operating-manual.md` and
    # `.crucible/docs/operating-manual.md` are the same claim, checked the same way. The
    # extension list is closed rather than the generic `\.[A-Za-z0-9]+` for the reason a first
    # draft of this scan found the hard way: docs/bootstrap.md's
    # `[...](../templates/project/.crucible)` matched `.crucible` itself as though it were a
    # three-letter extension on a file named `.crucible`, which is a directory link, not a
    # file reference.
    $fullPathPattern = '(?:\.crucible/)?((?:docs|sops|prompts|personas|powershell|schemas|scripts|templates)/[A-Za-z0-9_./{}<>*-]+\.(?:ps1|sh|go|md|json|yaml|yml))'
    $pathChecked = 0
    $unresolvedPaths = @()
    foreach ($docFile in $docFiles) {
        $docRelative = ($docFile.FullName.Substring($REPO_ROOT.Length).TrimStart('\', '/')) -replace '\\', '/'
        if (Test-FrameworkDevOnlyFile -Path $docRelative) { continue }
        $text = Get-Content -LiteralPath $docFile.FullName -Raw -Encoding UTF8
        foreach ($match in [regex]::Matches($text, $fullPathPattern)) {
            $relative = $match.Groups[1].Value.TrimEnd('.', ',', ';', ':', ')')
            if ($relative.IndexOfAny([char[]]@('{', '<', '*')) -ge 0) { continue }
            if ($relative.EndsWith("/")) { continue }
            $pathChecked++
            if ($trackedPaths.Contains($relative) -or $installed.Contains($relative)) { continue }
            if ($unresolvablePathExemptions.ContainsKey($relative)) { [void]$pathExemptionsUsed.Add($relative); continue }
            $unresolvedPaths += ($docRelative + " -> " + $relative)
        }
    }
    Assert-Result -Name "documented file paths were checked for existence" -Condition ($pathChecked -gt 0) -FailureMessage "no directory-prefixed path survived filtering, so the assertion below proves nothing"
    Assert-Result -Name "every documented file path resolves to the repository or the install set" -Condition ($unresolvedPaths.Count -eq 0) -FailureMessage ("these documents name files that exist neither in this repository nor in any install, and are unresolvable rather than silently skipped: " + (($unresolvedPaths | Sort-Object -Unique) -join "; "))

    # Pass 3: a bare backtick-quoted filename with no directory at all - the form eight of
    # item 98's nine references used, none of them inside a directory the scan above reads.
    # This is the same pattern the dev-only basename scan above already reads, pointed at a
    # different question: that scan asks "is this file dev-only"; this one asks "does a file
    # by this name exist anywhere a reader could reach it" - the repository, the install set,
    # or a runtime artifact pass 1 derived above. json/yaml/yml are included in the extension
    # list here though the dev-only scan does not carry them, because a bare reference to a
    # state or config file (`session_state.json`, `config.yaml`) makes exactly the same claim
    # of existence as a bare reference to a script or a doc, and excluding those extensions
    # would silently narrow this test's unit of reference rather than decide it.
    $basenamePattern = '`([A-Za-z0-9_.-]+\.(?:ps1|sh|go|md|json|yaml|yml))`'
    $basenameChecked = 0
    $unresolvedBasenames = @()
    foreach ($docFile in $docFiles) {
        $docRelative = ($docFile.FullName.Substring($REPO_ROOT.Length).TrimStart('\', '/')) -replace '\\', '/'
        if (Test-FrameworkDevOnlyFile -Path $docRelative) { continue }
        $lineNum = 0
        foreach ($line in (Get-Content -LiteralPath $docFile.FullName -Encoding UTF8)) {
            $lineNum++
            foreach ($match in [regex]::Matches($line, $basenamePattern)) {
                $leaf = $match.Groups[1].Value
                $basenameChecked++
                if ($trackedBasenames.Contains($leaf)) { continue }
                if ($installedBasenames.Contains($leaf)) { continue }
                if ($runtimeBasenames.Contains($leaf)) { continue }
                if ($unresolvableBasenameExemptions.ContainsKey($leaf)) { [void]$basenameExemptionsUsed.Add($leaf); continue }
                $unresolvedBasenames += ($docRelative + ":" + $lineNum + " -> " + $leaf)
            }
        }
    }
    Assert-Result -Name "bare backtick-quoted filenames were checked for existence" -Condition ($basenameChecked -gt 0) -FailureMessage "no bare backtick-quoted filename survived filtering, so the assertion below proves nothing"
    # Not pooled with the path count above. Item 98's own defect is proof this matters: eight
    # of the nine references were bare basenames inside directories the path scan above does
    # not even read (docs/), and the ninth was a bare basename inside a directory the path
    # scan DOES read but still could not see, for want of the `.crucible/` prefix it requires.
    # A shared counter would let either pass cover for the other going dead, which is the same
    # trap the scorecard test's own comment above warns about, and deleting either pass
    # outright must not read as this test staying clean.
    Assert-Result -Name "every documented bare filename resolves to the repository, the install set or a runtime artifact" -Condition ($unresolvedBasenames.Count -eq 0) -FailureMessage ("these documents name bare files that resolve nowhere, and are unresolvable rather than silently skipped: " + (($unresolvedBasenames | Sort-Object -Unique) -join "; "))

    $stalePathExemptions = @($unresolvablePathExemptions.Keys | Where-Object { -not $pathExemptionsUsed.Contains($_) })
    Assert-Result -Name "no path-reference exemption has stopped being needed" -Condition ($stalePathExemptions.Count -eq 0) -FailureMessage ("these exemptions no longer match any unresolved reference and should be removed: " + ($stalePathExemptions -join ", "))
    $staleBasenameExemptions = @($unresolvableBasenameExemptions.Keys | Where-Object { -not $basenameExemptionsUsed.Contains($_) })
    Assert-Result -Name "no basename-reference exemption has stopped being needed" -Condition ($staleBasenameExemptions.Count -eq 0) -FailureMessage ("these exemptions no longer match any unresolved reference and should be removed: " + ($staleBasenameExemptions -join ", "))
}

$failed = @($results | Where-Object { -not $_ }).Count
if ($failed -gt 0) {
    Write-Host ("`n$failed documented-paths-ship test(s) failed.") -ForegroundColor Red
    exit 1
}
Write-Host "`nAll documented-paths-ship tests passed." -ForegroundColor Green
exit 0
