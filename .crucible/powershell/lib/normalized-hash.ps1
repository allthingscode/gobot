function ConvertTo-NormalizedRelativeSlashPath {
    param([Parameter(Mandatory=$true)][string]$Path)
    return $Path.Replace("\", "/").TrimStart("/")
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

function Get-ContentWithoutCustomRegions {
    param([string]$Content)
    if ([string]::IsNullOrEmpty($Content)) { return $Content }
    $regex = '(?im)^([^\r\n]*>>>\s*CRUCIBLE-CUSTOM[^\r\n]*\r?\n)(?s:.*?)(^[^\r\n]*<<<\s*CRUCIBLE-CUSTOM[^\r\n]*)'
    return [regex]::Replace($Content, $regex, '$1$2')
}

function Merge-CustomRegions {
    param(
        [string]$AdopterContent,
        [string]$FrameworkContent
    )
    if ([string]::IsNullOrEmpty($AdopterContent)) { return $FrameworkContent }
    if ([string]::IsNullOrEmpty($FrameworkContent)) { return $FrameworkContent }

    $regex = '(?im)^([^\r\n]*>>>\s*CRUCIBLE-CUSTOM[^\r\n]*\r?\n)(?s:.*?)(^[^\r\n]*<<<\s*CRUCIBLE-CUSTOM[^\r\n]*)'
    $adopterMatches = [regex]::Matches($AdopterContent, $regex)
    
    if ($adopterMatches.Count -eq 0) {
        return $FrameworkContent
    }
    
    $frameworkMatches = [regex]::Matches($FrameworkContent, $regex)
    
    if ($adopterMatches.Count -eq $frameworkMatches.Count) {
        $result = ""
        $lastIdx = 0
        for ($i = 0; $i -lt $frameworkMatches.Count; $i++) {
            $fMatch = $frameworkMatches[$i]
            $aMatch = $adopterMatches[$i]
            
            $result += $FrameworkContent.Substring($lastIdx, $fMatch.Index - $lastIdx)
            $result += $aMatch.Value
            $lastIdx = $fMatch.Index + $fMatch.Length
        }
        $result += $FrameworkContent.Substring($lastIdx)
        return $result
    }
    
    return $FrameworkContent
}

function Get-FileNormalizedHash {
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [switch]$WithoutCustomRegions
    )
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    $content = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    if ($WithoutCustomRegions) {
        $content = Get-ContentWithoutCustomRegions -Content $content
    }
    return Get-NormalizedSha256 -Content $content
}

function Get-GitFileContent {
    param(
        [Parameter(Mandatory=$true)][string]$Repo,
        [Parameter(Mandatory=$true)][string]$Commit,
        [Parameter(Mandatory=$true)][string]$Path
    )

    $object = $Commit + ":" + (ConvertTo-NormalizedRelativeSlashPath -Path $Path)

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
        [Parameter(Mandatory=$true)][string]$Path,
        [switch]$WithoutCustomRegions
    )
    $content = Get-GitFileContent -Repo $Repo -Commit $Commit -Path $Path
    if ($null -eq $content) { return $null }
    if ($WithoutCustomRegions) {
        $content = Get-ContentWithoutCustomRegions -Content $content
    }
    return Get-NormalizedSha256 -Content $content
}
