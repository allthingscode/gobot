. (Join-Path $PSScriptRoot "normalized-hash.ps1")

function Get-InstallManifest {
    param([string]$FrameworkRoot = "")

    if ([string]::IsNullOrWhiteSpace($FrameworkRoot)) {
        $FrameworkRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "../..")).Path
    } elseif (Test-Path -LiteralPath $FrameworkRoot) {
        $FrameworkRoot = (Resolve-Path -LiteralPath $FrameworkRoot).Path
    }

    $manifestPath = Join-Path $FrameworkRoot "install-manifest.json"
    if (-not (Test-Path -LiteralPath $manifestPath)) {
        throw "Install manifest not found at $manifestPath"
    }

    $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($property in "scaffold_source", "root_files", "copied_dirs", "adopter_owned_excludes") {
        if (-not $manifest.PSObject.Properties[$property]) {
            throw "Install manifest missing required property: $property"
        }
    }
    if ([string]::IsNullOrWhiteSpace([string]$manifest.scaffold_source)) {
        throw "Install manifest scaffold_source must not be empty."
    }
    if (@($manifest.copied_dirs).Count -eq 0) {
        throw "Install manifest copied_dirs must not be empty."
    }
    foreach ($rootFile in @($manifest.root_files)) {
        if ([string]::IsNullOrWhiteSpace([string]$rootFile)) {
            throw "Install manifest root_files must not contain empty entries."
        }
    }
    return $manifest
}

function ConvertTo-ManifestRelativePath {
    param([Parameter(Mandatory=$true)][string]$Path)
    return $Path.Replace("\", "/").TrimStart("/")
}

function Test-FrameworkDevOnlyFile {
    param([string]$Path)
    $normalized = $Path.Replace("\", "/").TrimStart("/")
    $devOnlyPaths = @(
        "powershell/tests/examples-mirror-sync.tests.ps1",
        "powershell/tests/pre-push-hook.tests.ps1",
        "powershell/tests/init-project-core.tests.ps1",
        "powershell/tests/init-project-instructions.tests.ps1",
        "powershell/tests/init-project-config-version.tests.ps1",
        "powershell/tests/update-bundle-core.tests.ps1",
        "powershell/tests/update-bundle-custom-regions.tests.ps1",
        "powershell/tests/update-bundle-rename-prune.tests.ps1",
        "powershell/tests/update-bundle-scope-snapshot.tests.ps1"
    )
    return $devOnlyPaths -contains $normalized
}

function Get-FrameworkOwnedFiles {
    param(
        [string]$FrameworkRoot = "",
        [string]$AtCommit = ""
    )

    if ([string]::IsNullOrWhiteSpace($FrameworkRoot)) {
        $FrameworkRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "../..")).Path
    } else {
        $FrameworkRoot = (Resolve-Path -LiteralPath $FrameworkRoot).Path
    }
    $manifest = Get-InstallManifest -FrameworkRoot $FrameworkRoot
    $roots = @()
    $roots += ConvertTo-ManifestRelativePath -Path ([string]$manifest.scaffold_source)
    $roots += @($manifest.root_files | ForEach-Object { ConvertTo-ManifestRelativePath -Path ([string]$_) })
    $roots += @($manifest.copied_dirs | ForEach-Object { ConvertTo-ManifestRelativePath -Path ([string]$_) })

    if (-not [string]::IsNullOrWhiteSpace($AtCommit)) {
        $files = @()
        foreach ($root in $roots) {
            $treeOutput = @(git -C $FrameworkRoot ls-tree -r --name-only $AtCommit -- $root 2>$null)
            if ($LASTEXITCODE -ne 0) {
                throw "Unable to enumerate install files at commit $AtCommit under $root"
            }
            $files += $treeOutput
        }
        return @($files | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | ForEach-Object { ConvertTo-ManifestRelativePath -Path ([string]$_) } | Where-Object { -not (Test-FrameworkDevOnlyFile -Path $_) } | Sort-Object -Unique)
    }

    $files = @()
    foreach ($root in $roots) {
        $absoluteRoot = Join-Path $FrameworkRoot $root
        if (-not (Test-Path -LiteralPath $absoluteRoot)) {
            continue
        }
        if (Test-Path -LiteralPath $absoluteRoot -PathType Leaf) {
            $resolvedFile = (Resolve-Path -LiteralPath $absoluteRoot).Path
            $relative = $resolvedFile.Substring($FrameworkRoot.Length).TrimStart([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
            $files += ConvertTo-ManifestRelativePath -Path $relative
            continue
        }
        $resolvedRoot = (Resolve-Path -LiteralPath $absoluteRoot).Path
        $files += Get-ChildItem -LiteralPath $resolvedRoot -Force -Recurse -File | Where-Object {
            $rel = $_.FullName.Substring($FrameworkRoot.Length).TrimStart([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
            # Exclude gitignored runtime state that can accumulate under a
            # framework source dir's own nested .crucible/ (e.g. powershell/.crucible/).
            -not (($rel -split '[\\/]') -contains ".crucible")
        } | ForEach-Object {
            $relative = $_.FullName.Substring($FrameworkRoot.Length).TrimStart([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
            ConvertTo-ManifestRelativePath -Path $relative
        }
    }
    return @($files | Where-Object { -not (Test-FrameworkDevOnlyFile -Path $_) } | Sort-Object -Unique)
}

function Convert-FrameworkPathToAdopter {
    param(
        [Parameter(Mandatory=$true)][string]$SourcePath,
        [Parameter(Mandatory=$true)]$Manifest
    )

    $source = ConvertTo-ManifestRelativePath -Path $SourcePath
    $scaffold = (ConvertTo-ManifestRelativePath -Path ([string]$Manifest.scaffold_source)).TrimEnd("/")
    if ($source -eq $scaffold) {
        return ""
    }
    if ($source.StartsWith($scaffold + "/", [System.StringComparison]::OrdinalIgnoreCase)) {
        return $source.Substring($scaffold.Length + 1)
    }

    foreach ($rootFile in @($Manifest.root_files)) {
        $normalizedFile = ConvertTo-ManifestRelativePath -Path ([string]$rootFile)
        if ($source -eq $normalizedFile) {
            return $source
        }
    }

    foreach ($dir in @($Manifest.copied_dirs)) {
        $normalizedDir = (ConvertTo-ManifestRelativePath -Path ([string]$dir)).TrimEnd("/")
        if ($source -eq $normalizedDir -or $source.StartsWith($normalizedDir + "/", [System.StringComparison]::OrdinalIgnoreCase)) {
            return $source
        }
    }

    throw "Path is not framework-owned according to install manifest: $SourcePath"
}

function Get-AdopterPathsForSource {
    param(
        [Parameter(Mandatory=$true)][string]$SourcePath,
        [Parameter(Mandatory=$true)]$Manifest
    )

    $paths = @()
    $adopterPath = Convert-FrameworkPathToAdopter -SourcePath $SourcePath -Manifest $Manifest
    if (-not [string]::IsNullOrWhiteSpace($adopterPath)) {
        $paths += $adopterPath
    }

    $source = ConvertTo-ManifestRelativePath -Path $SourcePath
    $scaffold = (ConvertTo-ManifestRelativePath -Path ([string]$Manifest.scaffold_source)).TrimEnd("/")
    if ($source.StartsWith($scaffold + "/", [System.StringComparison]::OrdinalIgnoreCase)) {
        $paths += $source
    }

    return @($paths | Sort-Object -Unique)
}

function Test-AdopterOwnedPath {
    param(
        [Parameter(Mandatory=$true)][string]$RelativePath,
        [Parameter(Mandatory=$true)]$Manifest
    )

    $path = ConvertTo-ManifestRelativePath -Path $RelativePath
    foreach ($exclude in @($Manifest.adopter_owned_excludes)) {
        $pattern = ConvertTo-ManifestRelativePath -Path ([string]$exclude)
        if ($pattern.EndsWith("/**")) {
            $prefix = $pattern.Substring(0, $pattern.Length - 3).TrimEnd("/")
            if ($path -eq $prefix -or $path.StartsWith($prefix + "/", [System.StringComparison]::OrdinalIgnoreCase)) {
                return $true
            }
            continue
        }

        if ([System.Management.Automation.WildcardPattern]::Get($pattern, [System.Management.Automation.WildcardOptions]::IgnoreCase).IsMatch($path)) {
            return $true
        }
    }
    return $false
}

function Test-CrucibleGitIgnored {
    param(
        [Parameter(Mandatory=$true)][string]$BundleRoot,
        [Parameter(Mandatory=$true)][string]$RelativePath
    )
    $gitRoot = $null
    $dir = [System.IO.Path]::GetFullPath($BundleRoot)
    while ($null -ne $dir) {
        if (Test-Path -LiteralPath (Join-Path $dir ".git")) {
            $gitRoot = $dir
            break
        }
        $parent = Split-Path -Parent $dir
        if ($parent -eq $dir -or [string]::IsNullOrEmpty($parent)) {
            break
        }
        $dir = $parent
    }
    if ($null -eq $gitRoot) {
        return $false
    }

    $absoluteFilePath = [System.IO.Path]::GetFullPath((Join-Path $BundleRoot $RelativePath))

    if ($absoluteFilePath.StartsWith($gitRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        $relativeToGit = $absoluteFilePath.Substring($gitRoot.Length).TrimStart([System.IO.Path]::DirectorySeparatorChar).TrimStart([System.IO.Path]::AltDirectorySeparatorChar)
        $relativeToGit = $relativeToGit -replace '\\', '/'

        $null = git -C $gitRoot check-ignore --quiet -- $relativeToGit 2>$null
        return ($LASTEXITCODE -eq 0)
    }
    return $false
}

function Test-ScaffoldSnapshotPath {
    param(
        [Parameter(Mandatory=$true)][string]$RelativePath,
        [Parameter(Mandatory=$true)]$Manifest
    )
    $path = ConvertTo-ManifestRelativePath -Path $RelativePath
    $scaffold = (ConvertTo-ManifestRelativePath -Path ([string]$Manifest.scaffold_source)).TrimEnd("/")
    return $path.StartsWith($scaffold + "/", [System.StringComparison]::OrdinalIgnoreCase)
}

$script:ProvenanceManifestVersion = 1

function Get-ProvenanceManifestPath {
    param([Parameter(Mandatory=$true)][string]$BundleRoot)
    return Join-Path $BundleRoot "install-provenance.json"
}

function Get-ProvenanceBundlePaths {
    param(
        [Parameter(Mandatory=$true)][string]$FrameworkRoot,
        [Parameter(Mandatory=$true)]$Manifest,
        [Parameter(Mandatory=$true)][string]$Commit
    )

    $frameworkFiles = @(Get-FrameworkOwnedFiles -FrameworkRoot $FrameworkRoot -AtCommit $Commit)
    $seen = New-Object System.Collections.Generic.HashSet[string] ([System.StringComparer]::OrdinalIgnoreCase)
    $ordered = New-Object System.Collections.Generic.List[object]
    foreach ($source in $frameworkFiles) {
        foreach ($adopterPath in @(Get-AdopterPathsForSource -SourcePath $source -Manifest $Manifest)) {
            if ([string]::IsNullOrWhiteSpace($adopterPath)) { continue }
            $normalized = ConvertTo-ManifestRelativePath -Path $adopterPath
            if (Test-AdopterOwnedPath -RelativePath $normalized -Manifest $Manifest) { continue }
            if ($seen.Add($normalized)) {
                $ordered.Add([pscustomobject]@{ AdopterPath = $normalized; SourcePath = $source }) | Out-Null
            }
        }
    }
    return $ordered.ToArray()
}

function New-ProvenanceManifest {
    param(
        [Parameter(Mandatory=$true)][string]$FrameworkRoot,
        [Parameter(Mandatory=$true)][string]$Commit,
        [Parameter(Mandatory=$false)]$Manifest = $null
    )

    $FrameworkRoot = (Resolve-Path -LiteralPath $FrameworkRoot).Path
    if ($null -eq $Manifest) {
        $Manifest = Get-InstallManifest -FrameworkRoot $FrameworkRoot
    }

    # Cache optimization: git commit contents are immutable. We can cache the generated
    # manifest in the temp directory using a key derived from $FrameworkRoot and $Commit.
    $normRoot = $FrameworkRoot -replace '\\', '/'
    $cacheKey = Get-NormalizedSha256 -Content ($normRoot + "|" + $Commit)
    $cachePath = Join-Path ([System.IO.Path]::GetTempPath()) "crucible-prov-cache-$cacheKey.json"

    if (Test-Path -LiteralPath $cachePath -PathType Leaf) {
        try {
            $cachedJson = Get-Content -LiteralPath $cachePath -Raw -Encoding UTF8
            $cachedManifest = $cachedJson | ConvertFrom-Json
            if ($null -ne $cachedManifest -and $cachedManifest.source_commit -eq $Commit) {
                return $cachedManifest
            }
        } catch {
            # Ignore cache read errors and regenerate
        }
    }

    $files = [ordered]@{}
    foreach ($entry in @(Get-ProvenanceBundlePaths -FrameworkRoot $FrameworkRoot -Manifest $Manifest -Commit $Commit)) {
        $content = Get-GitFileContent -Repo $FrameworkRoot -Commit $Commit -Path $entry.SourcePath
        if ($null -eq $content) { continue }
        $hash = Get-NormalizedSha256 -Content $content
        $baseContent = Get-ContentWithoutCustomRegions -Content $content
        $baseHash = Get-NormalizedSha256 -Content $baseContent
        $files[$entry.AdopterPath] = [pscustomobject]@{
            hash = $hash
            base_hash = $baseHash
        }
    }

    $prov = [pscustomobject]@{
        manifest_version = $script:ProvenanceManifestVersion
        source_commit = $Commit
        files = [pscustomobject]$files
    }

    try {
        $json = $prov | ConvertTo-Json -Depth 10
        [System.IO.File]::WriteAllText($cachePath, $json, [System.Text.UTF8Encoding]::new($false))
    } catch {
        # Ignore cache write errors
    }

    return $prov
}

function Write-ProvenanceManifest {
    param(
        [Parameter(Mandatory=$true)][string]$BundleRoot,
        [Parameter(Mandatory=$true)]$ProvenanceManifest
    )
    $path = Get-ProvenanceManifestPath -BundleRoot $BundleRoot
    $json = $ProvenanceManifest | ConvertTo-Json -Depth 10
    [System.IO.File]::WriteAllText($path, $json, [System.Text.UTF8Encoding]::new($false))
    return $path
}

function Read-ProvenanceManifest {
    param([Parameter(Mandatory=$true)][string]$BundleRoot)
    $path = Get-ProvenanceManifestPath -BundleRoot $BundleRoot
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return $null
    }
    return Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Get-DriftClassification {
    param(
        [Parameter(Mandatory=$true)][string]$BundleRoot,
        [Parameter(Mandatory=$true)]$ProvenanceManifest,
        [Parameter(Mandatory=$true)]$Manifest
    )

    $BundleRoot = (Resolve-Path -LiteralPath $BundleRoot).Path
    $results = [ordered]@{
        pristine = New-Object System.Collections.Generic.List[string]
        customized = New-Object System.Collections.Generic.List[string]
        "adopter-added" = New-Object System.Collections.Generic.List[string]
        "framework-removed" = New-Object System.Collections.Generic.List[string]
    }

    $manifestPaths = New-Object System.Collections.Generic.HashSet[string] ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($property in $ProvenanceManifest.files.PSObject.Properties) {
        $relPath = ConvertTo-ManifestRelativePath -Path $property.Name
        [void]$manifestPaths.Add($relPath)
        $absolute = Join-Path $BundleRoot $relPath
        $workingHash = Get-FileNormalizedHash -Path $absolute
        if ($null -eq $workingHash) {
            $results["framework-removed"].Add($relPath) | Out-Null
            continue
        }
        
        $manifestHash = [string]$property.Value.hash
        $manifestBaseHash = if ($property.Value.base_hash) { [string]$property.Value.base_hash } else { $manifestHash }
        
        $workingHashBase = Get-FileNormalizedHash -Path $absolute -WithoutCustomRegions
        
        if ($workingHash -eq $manifestHash) {
            $results["pristine"].Add($relPath) | Out-Null
        } elseif ($workingHashBase -eq $manifestBaseHash) {
            $results["pristine"].Add($relPath) | Out-Null
        } else {
            $results["customized"].Add($relPath) | Out-Null
        }
    }

    $scanRoots = @($Manifest.copied_dirs | ForEach-Object { (ConvertTo-ManifestRelativePath -Path ([string]$_)).TrimEnd("/") })
    $scanRoots += @($Manifest.root_files | ForEach-Object { ConvertTo-ManifestRelativePath -Path ([string]$_) })
    foreach ($root in $scanRoots) {
        $absoluteRoot = Join-Path $BundleRoot $root
        if (-not (Test-Path -LiteralPath $absoluteRoot)) { continue }
        if (Test-Path -LiteralPath $absoluteRoot -PathType Leaf) {
            if ($root -eq "install-provenance.json") { continue }
            if (-not $manifestPaths.Contains($root)) {
                if (-not (Test-AdopterOwnedPath -RelativePath $root -Manifest $Manifest)) {
                    if (-not (Test-ScaffoldSnapshotPath -RelativePath $root -Manifest $Manifest)) {
                        if (Test-CrucibleGitIgnored -BundleRoot $BundleRoot -RelativePath $root) { continue }
                    }
                    $results["adopter-added"].Add($root) | Out-Null
                }
            }
            continue
        }
        foreach ($file in Get-ChildItem -LiteralPath $absoluteRoot -Recurse -File -Force) {
            $rel = ConvertTo-ManifestRelativePath -Path ($file.FullName.Substring($BundleRoot.Length))
            if ($rel -eq "install-provenance.json") { continue }
            if ($manifestPaths.Contains($rel)) { continue }
            if (Test-AdopterOwnedPath -RelativePath $rel -Manifest $Manifest) { continue }
            if (-not (Test-ScaffoldSnapshotPath -RelativePath $rel -Manifest $Manifest)) {
                if (Test-CrucibleGitIgnored -BundleRoot $BundleRoot -RelativePath $rel) { continue }
            }
            $results["adopter-added"].Add($rel) | Out-Null
        }
    }

    foreach ($key in @($results.Keys)) {
        $sorted = @($results[$key] | Sort-Object -Unique)
        $results[$key] = $sorted
    }
    return $results
}
