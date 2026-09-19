param(
    [Parameter(Mandatory=$true)][string]$FrameworkSource,
    [Parameter(Mandatory=$false)][string]$AdopterRoot = (Get-Location).Path,
    [Parameter(Mandatory=$false)][switch]$DryRun,
    [Parameter(Mandatory=$false)][ValidateSet("interactive", "auto-safe", "report-only")][string]$Mode = "interactive",
    [Parameter(Mandatory=$false)][switch]$Prune,
    [Parameter(Mandatory=$false)][switch]$Restamp
)

$ErrorActionPreference = "Stop"

# Retention for the per-run report written to session/update-bundle/. A normal update writes
# two logs - the dry run and the apply - so twenty is roughly the last ten updates, which is
# further back than anyone has ever needed to look and still a bounded directory.
$UpdateLogRetentionCount = 20

function ConvertTo-RelativeSlashPath {
    param([Parameter(Mandatory=$true)][string]$Path)
    return $Path.Replace("\", "/").TrimStart("/")
}

# A path is superseded only when the framework says where it went AND the destination is
# actually shipping in this update. Trusting the map alone would retire a file on the word
# of a manifest entry whose replacement failed to materialise, turning a bad rename record
# into silent data loss; requiring the destination in $Expected makes the map a claim the
# update itself has to corroborate.
function Test-SupersededRename {
    param(
        [Parameter(Mandatory=$true)][string]$RelativePath,
        [Parameter(Mandatory=$true)][hashtable]$RenameMap,
        [Parameter(Mandatory=$true)]$Expected
    )
    $normalized = ConvertTo-RelativeSlashPath -Path $RelativePath
    if (-not $RenameMap.ContainsKey($normalized)) {
        return $false
    }
    return $Expected.Contains((ConvertTo-RelativeSlashPath -Path $RenameMap[$normalized]))
}

function Read-ConfigScalar {
    param(
        [Parameter(Mandatory=$true)][string]$ConfigPath,
        [Parameter(Mandatory=$true)][string]$Key
    )
    $content = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8
    if ($content -match ('(?m)^' + [regex]::Escape($Key) + ':\s*["'']?([^"''\r\n]+)["'']?\s*$')) {
        return $Matches[1].Trim()
    }
    return ""
}

function Write-ConfigScalar {
    param(
        [Parameter(Mandatory=$true)][string]$ConfigPath,
        [Parameter(Mandatory=$true)][string]$Key,
        [Parameter(Mandatory=$true)][string]$Value
    )
    $escaped = '"' + $Value.Replace("\", "\\").Replace('"', '\"') + '"'
    $content = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8
    if ($content -match ('(?m)^' + [regex]::Escape($Key) + ':')) {
        $content = $content -replace ('(?m)^' + [regex]::Escape($Key) + ': .+$'), ($Key + ': ' + $escaped)
    } else {
        $content = $content.TrimEnd() + "`n" + $Key + ': ' + $escaped + "`n"
    }
    [System.IO.File]::WriteAllText($ConfigPath, $content, [System.Text.UTF8Encoding]::new($false))
}

. (Join-Path (Split-Path -Parent $PSCommandPath) "lib/normalized-hash.ps1")

function New-ClassificationResult {
    return [ordered]@{
        "no-op" = New-Object System.Collections.Generic.List[object]
        "safe-overwrite" = New-Object System.Collections.Generic.List[object]
        "needs-merge" = New-Object System.Collections.Generic.List[object]
        "add" = New-Object System.Collections.Generic.List[object]
        "retired" = New-Object System.Collections.Generic.List[object]
        "review-removal" = New-Object System.Collections.Generic.List[object]
    }
}

function Add-ClassifiedItem {
    param(
        [Parameter(Mandatory=$true)]$Results,
        [Parameter(Mandatory=$true)][string]$Category,
        [Parameter(Mandatory=$true)][AllowEmptyString()][string]$SourcePath,
        [Parameter(Mandatory=$true)][string]$AdopterPath
    )
    $Results[$Category].Add([pscustomobject]@{
        SourcePath = $SourcePath
        AdopterPath = $AdopterPath
    }) | Out-Null
}

function Write-Report {
    param([Parameter(Mandatory=$true)]$Results)
    foreach ($category in @("no-op", "safe-overwrite", "needs-merge", "add", "retired", "review-removal")) {
        Write-Host ("{0,-16} {1}" -f ($category + ":"), $Results[$category].Count)
        foreach ($item in $Results[$category].ToArray()) {
            Write-Host ("  " + $item.AdopterPath)
        }
    }
    if ($Results["needs-merge"].Count -gt 0) {
        Write-Host ""
        Write-Host "Files needing manual merge:" -ForegroundColor Yellow
        foreach ($item in $Results["needs-merge"].ToArray()) {
            Write-Host ("  git -C <adopter> diff -- .crucible/" + $item.AdopterPath)
            Write-Host ("  git -C <framework> diff <baseline>..HEAD -- " + $item.SourcePath)
        }
    }
}

function Write-ScaffoldNotice {
    # Instantiated scaffold content is the only part of the bundle an adopter may
    # decline, and the only signal that it is declinable. It fires on preview runs
    # too: the documented workflow previews before applying, so the preview is
    # where the adopter first sees the path.
    param(
        [Parameter(Mandatory=$true)][AllowEmptyCollection()][string[]]$Instantiated,
        [Parameter(Mandatory=$true)][AllowEmptyCollection()][string[]]$Recreated,
        [Parameter(Mandatory=$true)][bool]$Applied
    )
    $optOut = @(
        "To decline a scaffold file, delete it AND add its path to your .gitignore;",
        "Crucible will not recreate an ignored path. Deleting alone is not an opt-out."
    )
    if ($Instantiated.Count -gt 0) {
        $verb = if ($Applied) { "Instantiated" } else { "Would instantiate" }
        Write-Host ""
        Write-Host ($verb + " " + $Instantiated.Count + " scaffold file(s) into your bundle:") -ForegroundColor Cyan
        foreach ($path in $Instantiated) { Write-Host ("  .crucible/" + $path) }
        Write-Host "Scaffold content is seed material and is opt-in."
        foreach ($line in $optOut) { Write-Host $line }
    }
    if ($Recreated.Count -gt 0) {
        $verb = if ($Applied) { "Recreated" } else { "Would recreate" }
        Write-Host ""
        Write-Host ($verb + " " + $Recreated.Count + " scaffold file(s) that are missing from your bundle:") -ForegroundColor Yellow
        foreach ($path in $Recreated) { Write-Host ("  .crucible/" + $path) }
        Write-Host "These were shipped at your recorded baseline, so a deletion is the likely cause."
        foreach ($line in $optOut) { Write-Host $line }
    }
}

function Remove-EmptiedBundleDirectory {
    param(
        [Parameter(Mandatory=$true)][AllowEmptyCollection()][string[]]$Candidates,
        [Parameter(Mandatory=$true)][string]$BundleRoot
    )
    # Pruning the last file out of a directory leaves the directory advertising a
    # part of the bundle Crucible no longer ships. Git cannot flag it, since it
    # tracks files and not directories. Walk up from each pruned file's parent,
    # stopping at the first level that still holds something and never at or above
    # the bundle root.
    $rootFull = [System.IO.Path]::GetFullPath($BundleRoot).TrimEnd([System.IO.Path]::DirectorySeparatorChar)
    $removed = 0
    $ordered = @($Candidates | Select-Object -Unique | Sort-Object -Property Length -Descending)
    foreach ($candidate in $ordered) {
        $current = $candidate
        while (-not [string]::IsNullOrEmpty($current)) {
            $currentFull = [System.IO.Path]::GetFullPath($current).TrimEnd([System.IO.Path]::DirectorySeparatorChar)
            # Containment also covers the root itself: rootFull never starts with
            # rootFull + separator, so the walk stops there without a second check.
            if (-not $currentFull.StartsWith($rootFull + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) { break }
            if (-not (Test-Path -LiteralPath $currentFull -PathType Container)) {
                $current = Split-Path -Path $currentFull -Parent
                continue
            }
            # -Force so a directory holding only hidden files counts as non-empty.
            if (@(Get-ChildItem -LiteralPath $currentFull -Force).Count -ne 0) { break }
            Remove-Item -LiteralPath $currentFull -Force
            $removed++
            $current = Split-Path -Path $currentFull -Parent
        }
    }
    return $removed
}

function Copy-FrameworkFileToAdopter {
    param(
        [Parameter(Mandatory=$true)][string]$FrameworkRoot,
        [Parameter(Mandatory=$true)][string]$AdopterCrucibleRoot,
        [Parameter(Mandatory=$true)]$Item
    )
    $source = Join-Path $FrameworkRoot $Item.SourcePath
    $destination = Join-Path $AdopterCrucibleRoot $Item.AdopterPath
    $destinationDir = Split-Path -Parent $destination
    if (-not (Test-Path -LiteralPath $destinationDir)) {
        New-Item -ItemType Directory -Path $destinationDir -Force | Out-Null
    }
    if (Test-Path -LiteralPath $destination -PathType Leaf) {
        $adopterContent = Get-Content -LiteralPath $destination -Raw -Encoding UTF8
        $frameworkContent = Get-Content -LiteralPath $source -Raw -Encoding UTF8
        $mergedContent = Merge-CustomRegions -AdopterContent $adopterContent -FrameworkContent $frameworkContent
        [System.IO.File]::WriteAllText($destination, $mergedContent, [System.Text.UTF8Encoding]::new($false))
    } else {
        Copy-Item -LiteralPath $source -Destination $destination -Force
    }
}

function Invoke-UpdateBundle {
    $frameworkRoot = (Resolve-Path -LiteralPath $FrameworkSource).Path
    $adopterRootResolved = (Resolve-Path -LiteralPath $AdopterRoot).Path
    $adopterCrucibleRoot = Join-Path $adopterRootResolved ".crucible"
    $configPath = Join-Path $adopterCrucibleRoot "config.yaml"

    $null = git -C $frameworkRoot rev-parse --show-toplevel 2>$null
    if ($LASTEXITCODE -ne 0) {
        throw "FrameworkSource must be a git repository: $frameworkRoot"
    }
    $frameworkStatus = @(git -C $frameworkRoot status --porcelain 2>$null)
    if ($LASTEXITCODE -ne 0) {
        throw "Could not inspect framework source git status: $frameworkRoot"
    }
    if ($frameworkStatus.Count -gt 0) {
        throw "FrameworkSource must be clean before updating adopters: $frameworkRoot"
    }
    $frameworkHead = ((git -C $frameworkRoot rev-parse HEAD) | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or -not ($frameworkHead -match '^[0-9a-f]{40}$')) {
        throw "Could not resolve framework HEAD in $frameworkRoot"
    }
    if (-not (Test-Path -LiteralPath $configPath)) {
        throw "AdopterRoot must contain .crucible/config.yaml: $adopterRootResolved"
    }

    $scriptRoot = Split-Path -Parent $PSCommandPath
    . (Join-Path $scriptRoot "lib/install-manifest.ps1")
    . (Join-Path $scriptRoot "lib/update-classification.ps1")
    $manifest = Get-InstallManifest -FrameworkRoot $frameworkRoot
    $renameMap = Get-SupersededRenameMap -Manifest $manifest

    $baselineCommit = Read-ConfigScalar -ConfigPath $configPath -Key "crucible_install_commit"
    if (-not ($baselineCommit -match '^[0-9a-f]{40}$')) {
        throw "Missing crucible_install_commit in .crucible/config.yaml. Run init-project.ps1 -StampVersionOnly once from a Crucible source checkout."
    }

    $provManifest = Read-ProvenanceManifest -BundleRoot $adopterCrucibleRoot
    if ($null -eq $provManifest) {
        Write-Host "No provenance manifest found. Backfilling from $baselineCommit..." -ForegroundColor Yellow
        $provManifest = New-ProvenanceManifest -FrameworkRoot $frameworkRoot -Commit $baselineCommit -Manifest $manifest
    }

    $baselineFiles = @(Get-FrameworkOwnedFiles -FrameworkRoot $frameworkRoot -AtCommit $baselineCommit)
    $headFiles = @(Get-FrameworkOwnedFiles -FrameworkRoot $frameworkRoot -AtCommit $frameworkHead)
    $sourcePaths = @($baselineFiles + $headFiles | Sort-Object -Unique)
    $results = New-ClassificationResult
    $instantiatedScaffold = @()
    $recreatedScaffold = @()

    # Build the set of expected adopter-relative paths that should exist (framework-owned at HEAD)
    $expected = New-Object System.Collections.Generic.HashSet[string] ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($src in $headFiles) {
        foreach ($ap in @(Get-AdopterPathsForSource -SourcePath $src -Manifest $manifest)) {
            if (-not [string]::IsNullOrWhiteSpace($ap)) {
                [void]$expected.Add((ConvertTo-RelativeSlashPath -Path $ap))
            }
        }
    }

    foreach ($sourcePath in $sourcePaths) {
        foreach ($adopterPath in @(Get-AdopterPathsForSource -SourcePath $sourcePath -Manifest $manifest)) {
            if ([string]::IsNullOrWhiteSpace($adopterPath)) { continue }
            if (Test-AdopterOwnedPath -RelativePath $adopterPath -Manifest $manifest) { continue }
            if (-not (Test-ScaffoldSnapshotPath -RelativePath $adopterPath -Manifest $manifest)) {
                if (Test-CrucibleGitIgnored -BundleRoot $adopterCrucibleRoot -RelativePath $adopterPath) { continue }
            }

            $adopterFile = Join-Path $adopterCrucibleRoot $adopterPath
            $hAdopter = Get-FileNormalizedHash -Path $adopterFile
            $hAdopterBase = Get-FileNormalizedHash -Path $adopterFile -WithoutCustomRegions
            
            $hManifest = $null
            $hManifestBase = $null
            $inProvenance = ($null -ne $provManifest -and $null -ne $provManifest.files -and $null -ne $provManifest.files.$adopterPath)
            if ($inProvenance) {
                $hManifest = $provManifest.files.$adopterPath.hash
                if ($provManifest.files.$adopterPath.base_hash) {
                    $hManifestBase = $provManifest.files.$adopterPath.base_hash
                }
            }
            if ($null -eq $hManifest) {
                $hManifest = Get-GitFileNormalizedHash -Repo $frameworkRoot -Commit $baselineCommit -Path $sourcePath
            }
            if ($null -eq $hManifestBase) {
                $hManifestBase = Get-GitFileNormalizedHash -Repo $frameworkRoot -Commit $baselineCommit -Path $sourcePath -WithoutCustomRegions
            }

            $hHead = Get-GitFileNormalizedHash -Repo $frameworkRoot -Commit $frameworkHead -Path $sourcePath

            # Every git lookup and manifest predicate is resolved here; the lattice
            # itself is a pure function in lib/update-classification.ps1, so that
            # update-classification.tests.ps1 can reach every branch in milliseconds
            # instead of by installing a framework into a throwaway repo.
            #
            # The two predicates below were previously evaluated inside the branches that
            # needed them. Both are cheap - a HashSet lookup and a manifest string match -
            # and hoisting them still removed work per pair, because $hHeadBase was
            # computed on this line and never read by any branch.
            $verdict = Get-BundleFileClassification `
                -HeadHash $hHead `
                -AdopterHash $hAdopter `
                -AdopterBaseHash $hAdopterBase `
                -BaselineHash $hManifest `
                -BaselineBaseHash $hManifestBase `
                -IsExpectedPath ($expected.Contains((ConvertTo-RelativeSlashPath -Path $adopterPath))) `
                -InProvenance $inProvenance `
                -SourceIsScaffoldSnapshot (Test-ScaffoldSnapshotPath -RelativePath $sourcePath -Manifest $manifest) `
                -AdopterIsScaffoldSnapshot (Test-ScaffoldSnapshotPath -RelativePath $adopterPath -Manifest $manifest) `
                -IsSupersededRename (Test-SupersededRename -RelativePath $adopterPath -RenameMap $renameMap -Expected $expected)

            if ($verdict.Category -eq "skip") {
                continue
            }

            Add-ClassifiedItem -Results $results -Category $verdict.Category -SourcePath $sourcePath -AdopterPath $adopterPath

            if ($verdict.ScaffoldAction -eq "recreated") {
                $recreatedScaffold += (ConvertTo-RelativeSlashPath -Path $adopterPath)
            } elseif ($verdict.ScaffoldAction -eq "instantiated") {
                $instantiatedScaffold += (ConvertTo-RelativeSlashPath -Path $adopterPath)
            }
        }
    }

    $classifiedAdopterPaths = New-Object System.Collections.Generic.HashSet[string] ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($category in $results.Keys) {
        foreach ($item in $results[$category]) {
            [void]$classifiedAdopterPaths.Add((ConvertTo-RelativeSlashPath -Path $item.AdopterPath))
        }
    }

    $scanRoots = @($manifest.copied_dirs | ForEach-Object { ($_ -replace '\\','/').TrimEnd('/') })
    foreach ($root in $scanRoots) {
        $abs = Join-Path $adopterCrucibleRoot $root
        if (-not (Test-Path -LiteralPath $abs)) { continue }
        foreach ($f in Get-ChildItem -LiteralPath $abs -Recurse -File -Force) {
            $rel = ConvertTo-RelativeSlashPath -Path ($f.FullName.Substring($adopterCrucibleRoot.Length))
            if ($expected.Contains($rel)) { continue }
            if ($classifiedAdopterPaths.Contains($rel)) { continue }
            if (Test-AdopterOwnedPath -RelativePath $rel -Manifest $manifest) { continue }
            if (-not (Test-ScaffoldSnapshotPath -RelativePath $rel -Manifest $manifest)) {
                if (Test-CrucibleGitIgnored -BundleRoot $adopterCrucibleRoot -RelativePath $rel) { continue }
            }
            $orphanCategory = if (Test-SupersededRename -RelativePath $rel -RenameMap $renameMap -Expected $expected) {
                "retired"
            } else {
                "review-removal"
            }
            Add-ClassifiedItem -Results $results -Category $orphanCategory -SourcePath "" -AdopterPath $rel
            [void]$classifiedAdopterPaths.Add($rel)
        }
    }

    $sessionDir = Join-Path $adopterCrucibleRoot "session"
    $logDir = Join-Path $sessionDir "update-bundle"
    if (-not (Test-Path -LiteralPath $logDir)) {
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    }

    # These logs used to land in the root of session/, alongside the per-task directories an
    # operator lists to orient, and nothing pruned them - one adopter had accumulated 172.
    # Move rather than delete, so the retention sweep below stays the only thing that ever
    # removes a log and the newest survivors are chosen by one rule instead of two.
    $migratedLogs = 0
    foreach ($legacy in @(Get-ChildItem -LiteralPath $sessionDir -Filter "update-bundle-*.log" -File -Force -ErrorAction SilentlyContinue)) {
        $destination = Join-Path $logDir ($legacy.Name -replace '^update-bundle-', '')
        if (Test-Path -LiteralPath $destination) {
            Remove-Item -LiteralPath $legacy.FullName -Force
        } else {
            Move-Item -LiteralPath $legacy.FullName -Destination $destination -Force
        }
        $migratedLogs++
    }

    $timestamp = (Get-Date).ToUniversalTime().ToString("yyyyMMdd-HHmmss", [System.Globalization.CultureInfo]::InvariantCulture)
    $logPath = Join-Path $logDir ($timestamp + ".log")
    $reportLines = @()
    foreach ($category in @("no-op", "safe-overwrite", "needs-merge", "add", "retired", "review-removal")) {
        $reportLines += ("{0}: {1}" -f $category, $results[$category].Count)
        $reportLines += @($results[$category].ToArray() | ForEach-Object { "  " + $_.AdopterPath })
    }
    [System.IO.File]::WriteAllText($logPath, (($reportLines -join "`r`n") + "`r`n"), [System.Text.UTF8Encoding]::new($false))

    # Names are UTC yyyyMMdd-HHmmss, so sorting by name is sorting by age, and the log just
    # written is always newest. Counting it in the retention keeps the directory at exactly
    # $UpdateLogRetentionCount rather than one more than whatever the rule claims.
    $removedLogs = 0
    $keptLogs = @(Get-ChildItem -LiteralPath $logDir -Filter "*.log" -File -Force | Sort-Object -Property Name -Descending)
    foreach ($stale in @($keptLogs | Select-Object -Skip $UpdateLogRetentionCount)) {
        Remove-Item -LiteralPath $stale.FullName -Force
        $removedLogs++
    }

    Write-Report -Results $results
    Write-Host ("Log: " + $logPath)
    if ($migratedLogs -gt 0) {
        Write-Host ("Moved {0} update log(s) out of session/ into session/update-bundle/." -f $migratedLogs)
    }
    if ($removedLogs -gt 0) {
        Write-Host ("Removed {0} update log(s) beyond the newest {1}." -f $removedLogs, $UpdateLogRetentionCount)
    }

    $effectiveDryRun = ($DryRun -or $Mode -eq "report-only")
    $applyItems = @($results["safe-overwrite"].ToArray() + $results["add"].ToArray())
    # Retirements ride the apply decision rather than the -Prune decision. -Prune is opt-in
    # and asks a separate question, so routing renames through it would make every rename a
    # bundle an adopter cannot bring current in one non-interactive command.
    $retireItems = @($results["retired"].ToArray())
    $shouldApply = $false
    if (-not $effectiveDryRun -and ($applyItems.Count + $retireItems.Count) -gt 0) {
        if ($Mode -eq "auto-safe") {
            $shouldApply = $true
        } elseif ($Mode -eq "interactive") {
            $prompt = if ($retireItems.Count -gt 0) {
                "Apply " + $applyItems.Count + " safe/add update(s) and retire " + $retireItems.Count + " superseded file(s)? [y/N]"
            } else {
                "Apply " + $applyItems.Count + " safe/add update(s)? [y/N]"
            }
            $answer = Read-Host $prompt
            $shouldApply = ($answer -match '^(?i)y(es)?$')
        }
    }

    $appliedCount = 0
    $skippedCount = 0
    $retiredCount = 0
    if ($shouldApply) {
        foreach ($item in $applyItems) {
            # Guard against an apply item whose framework source no longer exists on
            # disk - e.g. a path that survives only in the baseline commit's file list
            # because it was renamed/recased upstream. Skip it (with a warning) rather
            # than letting one missing source abort the whole bundle update; the file's
            # current name is handled as its own add/safe-overwrite item.
            $sourceFull = Join-Path $frameworkRoot $item.SourcePath
            if (-not (Test-Path -LiteralPath $sourceFull -PathType Leaf)) {
                Write-Host ("  [skip] framework source missing (renamed upstream?): " + $item.SourcePath) -ForegroundColor Yellow
                $skippedCount++
                continue
            }
            Copy-FrameworkFileToAdopter -FrameworkRoot $frameworkRoot -AdopterCrucibleRoot $adopterCrucibleRoot -Item $item
            $appliedCount++
        }
        Write-Host ("Applied " + $appliedCount + " update(s).")
        $emptiedByRetire = @()
        foreach ($item in $retireItems) {
            $relPath = ConvertTo-RelativeSlashPath -Path $item.AdopterPath
            # A path that something at HEAD still claims is not dead, whatever the map says.
            if ($expected.Contains($relPath)) { continue }
            $pathToDelete = Join-Path $adopterCrucibleRoot $item.AdopterPath
            if (Test-Path -LiteralPath $pathToDelete -PathType Leaf) {
                Remove-Item -LiteralPath $pathToDelete -Force
                $retiredCount++
                $emptiedByRetire += (Split-Path -Path $pathToDelete -Parent)
            }
        }
        if ($retiredCount -gt 0) {
            $removedByRetire = Remove-EmptiedBundleDirectory -Candidates $emptiedByRetire -BundleRoot $adopterCrucibleRoot
            Write-Host ("Retired " + $retiredCount + " superseded file(s) whose replacement shipped in this update.")
            if ($removedByRetire -gt 0) {
                Write-Host ("Removed " + $removedByRetire + " directory/directories left empty by the retirement.")
            }
        }
        if ($skippedCount -gt 0) {
            Write-Host ("Skipped " + $skippedCount + " item(s) with a missing framework source (likely renamed upstream; their current names are applied separately).") -ForegroundColor Yellow
        }
    }

    Write-ScaffoldNotice `
        -Instantiated @($instantiatedScaffold | Sort-Object -Unique) `
        -Recreated @($recreatedScaffold | Sort-Object -Unique) `
        -Applied $shouldApply

    $pruneItems = @($results["review-removal"].ToArray())
    $shouldPrune = $false
    if ($Prune -and -not $effectiveDryRun -and $pruneItems.Count -gt 0) {
        if ($Mode -eq "auto-safe") {
            $shouldPrune = $true
        } elseif ($Mode -eq "interactive") {
            $answer = Read-Host ("Prune " + $pruneItems.Count + " obsolete framework file(s)? [y/N]")
            $shouldPrune = ($answer -match '^(?i)y(es)?$')
        }
    }

    $prunedCount = 0
    if ($shouldPrune) {
        $emptiedParents = @()
        foreach ($item in $pruneItems) {
            $relPath = ConvertTo-RelativeSlashPath -Path $item.AdopterPath
            if ($expected.Contains($relPath)) {
                continue
            }
            $pathToDelete = Join-Path $adopterCrucibleRoot $item.AdopterPath
            if (Test-Path -LiteralPath $pathToDelete -PathType Leaf) {
                Remove-Item -LiteralPath $pathToDelete -Force
                $prunedCount++
                $emptiedParents += (Split-Path -Path $pathToDelete -Parent)
            }
        }
        $removedDirs = Remove-EmptiedBundleDirectory -Candidates $emptiedParents -BundleRoot $adopterCrucibleRoot
        Write-Host ("Pruned " + $prunedCount + " obsolete file(s).")
        if ($removedDirs -gt 0) {
            Write-Host ("Removed " + $removedDirs + " directory/directories left empty by the prune.")
        }
    }

    # Activate adopter hooks through the copy now on disk, not this checkout's
    # installer. install-hooks.ps1 derives framework vs adopter from its own
    # location, so the source script would set hooksPath on the framework repo.
    # Classification fixtures do not ship the installer; a live bundle does, and
    # a live apply copies powershell/ before this runs. Missing file: skip, do
    # not throw, and do not set core.hooksPath here.
    # Apply/prune was item 109. A clone of a current bundle classifies all-no-op
    # (restamp-only is that plus -Restamp); hooksPath is local config, so those
    # runs must heal too. Preview still does not. A bundle with pending work
    # that was not applied is not current; it is not this heal.
    $pendingWork = $results["safe-overwrite"].Count + $results["add"].Count + $results["needs-merge"].Count + $results["retired"].Count + $results["review-removal"].Count
    $isAllNoOp = ($pendingWork -eq 0)
    if (-not $effectiveDryRun -and ($shouldApply -or $shouldPrune -or $isAllNoOp)) {
        $hookInstaller = Join-Path $adopterCrucibleRoot "powershell/install-hooks.ps1"
        if ((Test-Path -LiteralPath (Join-Path $adopterRootResolved ".git")) -and
            (Test-Path -LiteralPath $hookInstaller -PathType Leaf)) {
            $null = & $hookInstaller
        }
    }

    if ($appliedCount -gt 0 -or $prunedCount -gt 0 -or $retiredCount -gt 0) {
        $isGitRepo = $false
        $checkDir = $adopterRootResolved
        while (-not [string]::IsNullOrEmpty($checkDir)) {
            if (Test-Path -LiteralPath (Join-Path $checkDir ".git")) {
                $isGitRepo = $true
                break
            }
            $parent = Split-Path -Parent $checkDir
            if ($parent -eq $checkDir -or [string]::IsNullOrEmpty($parent)) { break }
            $checkDir = $parent
        }
        if ($isGitRepo) {
            $old7 = if ($baselineCommit -and $baselineCommit.Length -ge 7) { $baselineCommit.Substring(0, 7) } else { "old" }
            $new7 = if ($frameworkHead -and $frameworkHead.Length -ge 7) { $frameworkHead.Substring(0, 7) } else { "new" }
            Write-Host "NEXT STEP (required): commit this bundle update in the adopter repo before running crucible.ps1."
            Write-Host "  git add .crucible"
            Write-Host ("  git commit -m `"chore(crucible): update adopter bundle " + $old7 + " -> " + $new7 + "`"")
            Write-Host "The framework-integrity circuit breaker treats uncommitted .crucible/ changes as a"
            Write-Host "specialist modifying framework-owned files and will hard-stop crucible.ps1 -Init with exit 2."
        }
    }

    $shouldRestamp = $false
    if ($shouldApply -or $shouldPrune) {
        $remainingRemovals = $results["review-removal"].Count
        if ($shouldPrune) {
            $remainingRemovals -= $prunedCount
        }
        $remainingRetired = $retireItems.Count - $retiredCount
        if ($results["needs-merge"].Count -eq 0 -and $remainingRemovals -eq 0 -and $remainingRetired -eq 0) {
            $shouldRestamp = $true
        }
    } elseif ($Restamp -and -not $effectiveDryRun) {
        # No content delta to apply or prune, but -Restamp was requested: advance the
        # provenance only when the bundle is genuinely all-no-op. Any safe-overwrite,
        # add, needs-merge, or review-removal item means content is NOT current, so
        # stamping HEAD would lie about what is installed - refuse and tell the caller
        # to run a normal update first.
        if ($pendingWork -eq 0) {
            $shouldRestamp = $true
            Write-Host "Re-stamping bundle provenance to framework HEAD (content already current)." -ForegroundColor Cyan
        } else {
            Write-Host ("Cannot -Restamp: " + $pendingWork + " file(s) still need apply/prune/merge. Run a normal update first.") -ForegroundColor Yellow
        }
    }

    if ($shouldRestamp) {
        Write-ConfigScalar -ConfigPath $configPath -Key "crucible_install_commit" -Value $frameworkHead
        $versionFile = Join-Path $frameworkRoot "VERSION"
        if (Test-Path -LiteralPath $versionFile -PathType Leaf) {
            $version = (Get-Content -LiteralPath $versionFile -Raw).Trim()
            Write-ConfigScalar -ConfigPath $configPath -Key "crucible_version" -Value $version
        }
        try {
            $provenance = New-ProvenanceManifest -FrameworkRoot $frameworkRoot -Commit $frameworkHead -Manifest $manifest
            $null = Write-ProvenanceManifest -BundleRoot $adopterCrucibleRoot -ProvenanceManifest $provenance
        } catch {
            Write-Host ("Warning: could not write provenance manifest: " + $_.Exception.Message) -ForegroundColor Yellow
        }
    }

    if ($results["needs-merge"].Count -gt 0) {
        return 2
    }
    return 0
}

try {
    $exitCode = Invoke-UpdateBundle
    exit $exitCode
} catch {
    Write-Host $_.Exception.Message -ForegroundColor Red
    exit 1
}
