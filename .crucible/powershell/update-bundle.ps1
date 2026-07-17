param(
    [Parameter(Mandatory=$true)][string]$FrameworkSource,
    [Parameter(Mandatory=$false)][string]$AdopterRoot = (Get-Location).Path,
    [Parameter(Mandatory=$false)][switch]$DryRun,
    [Parameter(Mandatory=$false)][ValidateSet("interactive", "auto-safe", "report-only")][string]$Mode = "interactive",
    [Parameter(Mandatory=$false)][switch]$Prune,
    [Parameter(Mandatory=$false)][switch]$Restamp
)

$ErrorActionPreference = "Stop"

function ConvertTo-RelativeSlashPath {
    param([Parameter(Mandatory=$true)][string]$Path)
    return $Path.Replace("\", "/").TrimStart("/")
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
        $content = $content.TrimEnd() + "`r`n" + $Key + ': ' + $escaped + "`r`n"
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
    foreach ($category in @("no-op", "safe-overwrite", "needs-merge", "add", "review-removal")) {
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
    $manifest = Get-InstallManifest -FrameworkRoot $frameworkRoot

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
            if ($null -ne $provManifest -and $null -ne $provManifest.files -and $null -ne $provManifest.files.$adopterPath) {
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
            $hHeadBase = Get-GitFileNormalizedHash -Repo $frameworkRoot -Commit $frameworkHead -Path $sourcePath -WithoutCustomRegions

            # 1. If not present at framework HEAD
            if ($null -eq $hHead) {
                if ($null -ne $hAdopter) {
                    if ($null -ne $hManifestBase -and $hAdopterBase -ne $hManifestBase) {
                        Add-ClassifiedItem -Results $results -Category "needs-merge" -SourcePath $sourcePath -AdopterPath $adopterPath
                    } else {
                        Add-ClassifiedItem -Results $results -Category "review-removal" -SourcePath $sourcePath -AdopterPath $adopterPath
                    }
                }
                continue
            }
            
            # 2. If not present on the adopter
            if ($null -eq $hAdopter) {
                Add-ClassifiedItem -Results $results -Category "add" -SourcePath $sourcePath -AdopterPath $adopterPath
                continue
            }
            
            # 3. If present on both:
            if ($hAdopter -eq $hHead) {
                Add-ClassifiedItem -Results $results -Category "no-op" -SourcePath $sourcePath -AdopterPath $adopterPath
                continue
            }
            
            # If the adopter only modified the file inside the custom regions (or didn't modify it at all):
            if ($null -ne $hManifestBase -and $hAdopterBase -eq $hManifestBase) {
                if ($hManifest -ne $hHead) {
                    Add-ClassifiedItem -Results $results -Category "safe-overwrite" -SourcePath $sourcePath -AdopterPath $adopterPath
                } else {
                    Add-ClassifiedItem -Results $results -Category "no-op" -SourcePath $sourcePath -AdopterPath $adopterPath
                }
                continue
            }
            
            # If the adopter has modified the file outside the custom regions (or there is no manifest base):
            if ($hManifest -eq $hHead) {
                Add-ClassifiedItem -Results $results -Category "no-op" -SourcePath $sourcePath -AdopterPath $adopterPath
            } else {
                Add-ClassifiedItem -Results $results -Category "needs-merge" -SourcePath $sourcePath -AdopterPath $adopterPath
            }
        }
    }

    # Build the set of expected adopter-relative paths that should exist (framework-owned at HEAD)
    $expected = New-Object System.Collections.Generic.HashSet[string] ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($src in $headFiles) {
        foreach ($ap in @(Get-AdopterPathsForSource -SourcePath $src -Manifest $manifest)) {
            if (-not [string]::IsNullOrWhiteSpace($ap)) {
                [void]$expected.Add((ConvertTo-RelativeSlashPath -Path $ap))
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
            Add-ClassifiedItem -Results $results -Category "review-removal" -SourcePath "" -AdopterPath $rel
            [void]$classifiedAdopterPaths.Add($rel)
        }
    }

    $sessionDir = Join-Path $adopterCrucibleRoot "session"
    if (-not (Test-Path -LiteralPath $sessionDir)) {
        New-Item -ItemType Directory -Path $sessionDir -Force | Out-Null
    }
    $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $logPath = Join-Path $sessionDir ("update-bundle-" + $timestamp + ".log")
    $reportLines = @()
    foreach ($category in @("no-op", "safe-overwrite", "needs-merge", "add", "review-removal")) {
        $reportLines += ("{0}: {1}" -f $category, $results[$category].Count)
        $reportLines += @($results[$category].ToArray() | ForEach-Object { "  " + $_.AdopterPath })
    }
    [System.IO.File]::WriteAllText($logPath, (($reportLines -join "`r`n") + "`r`n"), [System.Text.UTF8Encoding]::new($false))

    Write-Report -Results $results
    Write-Host ("Log: " + $logPath)

    $effectiveDryRun = ($DryRun -or $Mode -eq "report-only")
    $applyItems = @($results["safe-overwrite"].ToArray() + $results["add"].ToArray())
    $shouldApply = $false
    if (-not $effectiveDryRun -and $applyItems.Count -gt 0) {
        if ($Mode -eq "auto-safe") {
            $shouldApply = $true
        } elseif ($Mode -eq "interactive") {
            $answer = Read-Host ("Apply " + $applyItems.Count + " safe/add update(s)? [y/N]")
            $shouldApply = ($answer -match '^(?i)y(es)?$')
        }
    }

    $appliedCount = 0
    $skippedCount = 0
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
        if ($skippedCount -gt 0) {
            Write-Host ("Skipped " + $skippedCount + " item(s) with a missing framework source (likely renamed upstream; their current names are applied separately).") -ForegroundColor Yellow
        }
    }

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
        foreach ($item in $pruneItems) {
            $pathToDelete = Join-Path $adopterCrucibleRoot $item.AdopterPath
            if (Test-Path -LiteralPath $pathToDelete -PathType Leaf) {
                Remove-Item -LiteralPath $pathToDelete -Force
                $prunedCount++
            }
        }
        Write-Host ("Pruned " + $prunedCount + " obsolete file(s).")
    }

    $shouldRestamp = $false
    if ($shouldApply -or $shouldPrune) {
        $remainingRemovals = $results["review-removal"].Count
        if ($shouldPrune) {
            $remainingRemovals -= $prunedCount
        }
        if ($results["needs-merge"].Count -eq 0 -and $remainingRemovals -eq 0) {
            $shouldRestamp = $true
        }
    } elseif ($Restamp -and -not $effectiveDryRun) {
        # No content delta to apply or prune, but -Restamp was requested: advance the
        # provenance only when the bundle is genuinely all-no-op. Any safe-overwrite,
        # add, needs-merge, or review-removal item means content is NOT current, so
        # stamping HEAD would lie about what is installed - refuse and tell the caller
        # to run a normal update first.
        $pendingWork = $results["safe-overwrite"].Count + $results["add"].Count + $results["needs-merge"].Count + $results["review-removal"].Count
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
