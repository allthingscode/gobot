param(
    [Parameter(Mandatory=$true)][string]$FrameworkSource,
    [Parameter(Mandatory=$false)][string]$AdopterRoot = (Get-Location).Path,
    [Parameter(Mandatory=$false)][switch]$DryRun,
    [Parameter(Mandatory=$false)][ValidateSet("interactive", "auto-safe", "report-only")][string]$Mode = "interactive",
    [Parameter(Mandatory=$false)][switch]$Prune
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

function Get-NormalizedSha256 {
    param([AllowNull()][string]$Content)
    if ($null -eq $Content) { return $null }
    $normalized = ($Content -replace "`r`n", "`n").TrimEnd("`n")
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($normalized)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ([System.BitConverter]::ToString($sha.ComputeHash($bytes))).Replace("-", "").ToLowerInvariant()
    } finally {
        $sha.Dispose()
    }
}

function Get-FileNormalizedHash {
    param([Parameter(Mandatory=$true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    return Get-NormalizedSha256 -Content (Get-Content -LiteralPath $Path -Raw -Encoding UTF8)
}

function Get-GitFileContent {
    param(
        [Parameter(Mandatory=$true)][string]$Repo,
        [Parameter(Mandatory=$true)][string]$Commit,
        [Parameter(Mandatory=$true)][string]$Path
    )
    $object = $Commit + ":" + (ConvertTo-RelativeSlashPath -Path $Path)
    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $null = git -C $Repo cat-file -e $object 2>$null
        if ($LASTEXITCODE -ne 0) {
            return $null
        }
    } finally {
        $ErrorActionPreference = $previousPreference
    }

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = "git"
    $psi.Arguments = "-C ""$Repo"" show ""$object"""
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $psi.StandardOutputEncoding = [System.Text.UTF8Encoding]::new($false)

    try {
        $proc = [System.Diagnostics.Process]::Start($psi)
        $output = $proc.StandardOutput.ReadToEnd()
        $proc.WaitForExit()
        if ($proc.ExitCode -ne 0) {
            return $null
        }
        return $output
    } catch {
        return $null
    }
}

function Get-GitFileNormalizedHash {
    param(
        [Parameter(Mandatory=$true)][string]$Repo,
        [Parameter(Mandatory=$true)][string]$Commit,
        [Parameter(Mandatory=$true)][string]$Path
    )
    return Get-NormalizedSha256 -Content (Get-GitFileContent -Repo $Repo -Commit $Commit -Path $Path)
}

function Test-CrucibleGitIgnored {
    param(
        [Parameter(Mandatory=$true)][string]$AdopterRoot,
        [Parameter(Mandatory=$true)][string]$RelativePath
    )
    $gitDir = Join-Path $AdopterRoot ".git"
    if (-not (Test-Path -LiteralPath $gitDir)) {
        return $false
    }
    $checkPath = ".crucible/" + (ConvertTo-RelativeSlashPath -Path $RelativePath)
    $null = git -C $AdopterRoot check-ignore --quiet -- $checkPath 2>$null
    return ($LASTEXITCODE -eq 0)
}

function Test-ScaffoldSnapshotPath {
    param(
        [Parameter(Mandatory=$true)][string]$RelativePath,
        [Parameter(Mandatory=$true)]$Manifest
    )
    $path = ConvertTo-RelativeSlashPath -Path $RelativePath
    $scaffold = (ConvertTo-RelativeSlashPath -Path ([string]$Manifest.scaffold_source)).TrimEnd("/")
    return $path.StartsWith($scaffold + "/", [System.StringComparison]::OrdinalIgnoreCase)
}

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
    Copy-Item -LiteralPath $source -Destination $destination -Force
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

    $baselineFiles = @(Get-FrameworkOwnedFiles -FrameworkRoot $frameworkRoot -AtCommit $baselineCommit)
    $headFiles = @(Get-FrameworkOwnedFiles -FrameworkRoot $frameworkRoot -AtCommit $frameworkHead)
    $sourcePaths = @($baselineFiles + $headFiles | Sort-Object -Unique)
    $results = New-ClassificationResult

    foreach ($sourcePath in $sourcePaths) {
        foreach ($adopterPath in @(Get-AdopterPathsForSource -SourcePath $sourcePath -Manifest $manifest)) {
            if ([string]::IsNullOrWhiteSpace($adopterPath)) { continue }
            if (Test-AdopterOwnedPath -RelativePath $adopterPath -Manifest $manifest) { continue }
            if (-not (Test-ScaffoldSnapshotPath -RelativePath $adopterPath -Manifest $manifest)) {
                if (Test-CrucibleGitIgnored -AdopterRoot $adopterRootResolved -RelativePath $adopterPath) { continue }
            }

            $adopterFile = Join-Path $adopterCrucibleRoot $adopterPath
            $hAdopter = Get-FileNormalizedHash -Path $adopterFile
            $hBaseline = Get-GitFileNormalizedHash -Repo $frameworkRoot -Commit $baselineCommit -Path $sourcePath
            $hHead = Get-GitFileNormalizedHash -Repo $frameworkRoot -Commit $frameworkHead -Path $sourcePath

            if ($null -eq $hHead) {
                if ($null -ne $hAdopter) {
                    Add-ClassifiedItem -Results $results -Category "review-removal" -SourcePath $sourcePath -AdopterPath $adopterPath
                }
                continue
            }
            if ($null -eq $hAdopter) {
                Add-ClassifiedItem -Results $results -Category "add" -SourcePath $sourcePath -AdopterPath $adopterPath
                continue
            }
            if ($hAdopter -eq $hHead) {
                Add-ClassifiedItem -Results $results -Category "no-op" -SourcePath $sourcePath -AdopterPath $adopterPath
                continue
            }
            if ($null -eq $hBaseline) {
                Add-ClassifiedItem -Results $results -Category "needs-merge" -SourcePath $sourcePath -AdopterPath $adopterPath
                continue
            }
            if ($hAdopter -eq $hBaseline -and $hBaseline -ne $hHead) {
                Add-ClassifiedItem -Results $results -Category "safe-overwrite" -SourcePath $sourcePath -AdopterPath $adopterPath
                continue
            }
            Add-ClassifiedItem -Results $results -Category "needs-merge" -SourcePath $sourcePath -AdopterPath $adopterPath
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
                if (Test-CrucibleGitIgnored -AdopterRoot $adopterRootResolved -RelativePath $rel) { continue }
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
    $reportLines | Out-File -LiteralPath $logPath -Encoding UTF8

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
    if ($shouldApply) {
        foreach ($item in $applyItems) {
            Copy-FrameworkFileToAdopter -FrameworkRoot $frameworkRoot -AdopterCrucibleRoot $adopterCrucibleRoot -Item $item
            $appliedCount++
        }
        Write-Host ("Applied " + $appliedCount + " update(s).")
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

    if ($shouldApply -or $shouldPrune) {
        $remainingRemovals = $results["review-removal"].Count
        if ($shouldPrune) {
            $remainingRemovals -= $prunedCount
        }
        if ($results["needs-merge"].Count -eq 0 -and $remainingRemovals -eq 0) {
            Write-ConfigScalar -ConfigPath $configPath -Key "crucible_install_commit" -Value $frameworkHead
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
