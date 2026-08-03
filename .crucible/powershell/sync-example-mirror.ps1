$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$REPO_ROOT = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "..")).Path
. (Join-Path $REPO_ROOT "powershell/lib/install-manifest.ps1")

$MIRROR = "examples/gobot/.crucible"

function Invoke-GitLines {
    param([string[]]$GitArgs)
    Push-Location $REPO_ROOT
    try {
        $previous = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        try {
            $output = @(git @GitArgs 2>$null)
            $exitCode = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $previous
        }
    } finally {
        Pop-Location
    }
    return [PSCustomObject]@{ ExitCode = $exitCode; Output = $output }
}

function Get-TrackedMirrorRelative {
    param([string]$Dir)
    $result = Invoke-GitLines -GitArgs @("ls-files", "--", $Dir)
    if ($result.ExitCode -ne 0) {
        throw "git ls-files failed for $Dir"
    }

    $prefix = $Dir.TrimEnd("/") + "/"
    return @($result.Output | ForEach-Object {
        $path = [string]$_
        if (-not [string]::IsNullOrWhiteSpace($path)) {
            $rel = $path -replace ("^" + [regex]::Escape($prefix)), ""
            if ($Dir.StartsWith($MIRROR, [System.StringComparison]::OrdinalIgnoreCase)) {
                $canonicalDir = $Dir.Substring($MIRROR.Length).TrimStart("/")
                $repoRel = "$canonicalDir/$rel"
            } else {
                $repoRel = "$Dir/$rel"
            }
            $repoRel = $repoRel -replace "//", "/"
            if (-not (Test-FrameworkDevOnlyFile -Path $repoRel)) {
                $rel
            }
        }
    } | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
}

function Remove-MirrorFile {
    param([string]$RepoRelativePath)
    $result = Invoke-GitLines -GitArgs @("rm", "-f", "--", $RepoRelativePath)
    if ($result.ExitCode -eq 0) {
        return
    }

    $tracked = Invoke-GitLines -GitArgs @("ls-files", "--error-unmatch", "--", $RepoRelativePath)
    if ($tracked.ExitCode -eq 0) {
        throw "git rm failed for tracked file $RepoRelativePath"
    }

    $absolutePath = Join-Path $REPO_ROOT $RepoRelativePath
    if (Test-Path -LiteralPath $absolutePath) {
        Remove-Item -LiteralPath $absolutePath -Force
        return
    }

    throw "git rm failed for $RepoRelativePath"
}

try {
    foreach ($dir in @(Get-MirrorStructuralDirs)) {
        $canonicalRel = @(Get-TrackedMirrorRelative -Dir $dir)
        $mirrorDir = "$MIRROR/$dir"
        $mirrorRel = @(Get-TrackedMirrorRelative -Dir $mirrorDir)

        $copied = 0
        foreach ($rel in $canonicalRel) {
            $sourcePath = Join-Path $REPO_ROOT (Join-Path $dir $rel)
            $destinationPath = Join-Path $REPO_ROOT (Join-Path $mirrorDir $rel)
            $destinationDir = Split-Path -Parent $destinationPath
            if (-not [string]::IsNullOrWhiteSpace($destinationDir) -and -not (Test-Path -LiteralPath $destinationDir)) {
                New-Item -ItemType Directory -Path $destinationDir -Force | Out-Null
            }
            [System.IO.File]::Copy($sourcePath, $destinationPath, $true)
            $copied++
        }

        $pruned = 0
        foreach ($rel in $mirrorRel) {
            if ($canonicalRel -notcontains $rel) {
                $mirrorPath = "$mirrorDir/$rel"
                Remove-MirrorFile -RepoRelativePath $mirrorPath
                $pruned++
            }
        }

        $addResult = Invoke-GitLines -GitArgs @("add", "-f", "--", $mirrorDir)
        if ($addResult.ExitCode -ne 0) {
            throw "git add failed for $mirrorDir"
        }

        Write-Host ("$dir`: copied=$copied pruned=$pruned")
    }
    Write-Host ("Mirror sync complete: " + $MIRROR)
    exit 0
} catch {
    Write-Host ("Mirror sync failed: " + $_) -ForegroundColor Red
    exit 1
}
