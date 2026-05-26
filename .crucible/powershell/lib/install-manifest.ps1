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
        return @($files | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | ForEach-Object { ConvertTo-ManifestRelativePath -Path ([string]$_) } | Sort-Object -Unique)
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
        $files += Get-ChildItem -LiteralPath $resolvedRoot -Force -Recurse -File | ForEach-Object {
            $relative = $_.FullName.Substring($FrameworkRoot.Length).TrimStart([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
            ConvertTo-ManifestRelativePath -Path $relative
        }
    }
    return @($files | Sort-Object -Unique)
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
