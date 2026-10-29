if (-not (Get-Command Resolve-FilesystemPath -ErrorAction SilentlyContinue)) { . (Join-Path $PSScriptRoot "config-helpers.ps1") }

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

    $Repo = Resolve-FilesystemPath -Path $Repo
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

# One cat-file process per commit, with byte-framed replies. Reading a reply before
# sending the next request bounds pipe use even for blobs larger than the pipe buffer.
# Do not cache here: callers own the commit/path set and its lifetime.
function Start-GitFileContentProcess {
    param([Parameter(Mandatory=$true)][Diagnostics.ProcessStartInfo]$StartInfo)
    return [Diagnostics.Process]::Start($StartInfo)
}

function Get-GitFileContents {
    param(
        [Parameter(Mandatory=$true)][string]$Repo,
        [Parameter(Mandatory=$true)][string]$Commit,
        [Parameter(Mandatory=$true)][AllowEmptyCollection()][string[]]$Paths
    )
    $contents = [System.Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
    if ($Paths.Count -eq 0) { return ,$contents }
    $psi = [Diagnostics.ProcessStartInfo]::new('git')
    foreach ($argument in @('-C', (Resolve-FilesystemPath -Path $Repo), 'cat-file', '--batch')) {
        $psi.ArgumentList.Add($argument)
    }
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardInputEncoding = [Text.UTF8Encoding]::new($false)
    $proc = Start-GitFileContentProcess -StartInfo $psi
    try {
        $stderr = $proc.StandardError.ReadToEndAsync()
        $stream = $proc.StandardOutput.BaseStream
        foreach ($path in ($Paths | Select-Object -Unique)) {
            $spec = $Commit + ':' + (ConvertTo-NormalizedRelativeSlashPath -Path $path)
            if ($spec -match '[\r\n]') { throw 'Git batch object names must fit on one line.' }
            # The git protocol uses LF even when StreamWriter defaults to CRLF.
            $proc.StandardInput.Write($spec + "`n")
            $proc.StandardInput.Flush()
            $header = [Text.StringBuilder]::new()
            while (($b = $stream.ReadByte()) -ne 10) {
                if ($b -lt 0) { throw 'Git batch output ended before its header.' }
                [void]$header.Append([char]$b)
            }
            if ($header.ToString().EndsWith(' missing')) {
                $contents[$path] = $null
                continue
            }
            if ($header.ToString() -notmatch '^[0-9a-f]+ (\S+) ([0-9]+)$') {
                throw "Unexpected git batch header: $header"
            }
            $isBlob = $Matches[1] -eq 'blob'
            $bytes = [byte[]]::new([int]$Matches[2])
            $offset = 0
            while ($offset -lt $bytes.Length) {
                $count = $stream.Read($bytes, $offset, $bytes.Length - $offset)
                if ($count -eq 0) { throw 'Git batch output ended inside a blob.' }
                $offset += $count
            }
            if ($stream.ReadByte() -ne 10) { throw 'Git batch blob delimiter is missing.' }
            if (-not $isBlob) {
                $contents[$path] = $null
                continue
            }
            $reader = [IO.StreamReader]::new([IO.MemoryStream]::new($bytes), [Text.Encoding]::UTF8, $true)
            try { $contents[$path] = $reader.ReadToEnd() } finally { $reader.Dispose() }
        }
        $proc.StandardInput.Close()
        $proc.WaitForExit()
        if ($proc.ExitCode -ne 0) { throw ("git cat-file exited with code " + $proc.ExitCode) }
    } catch {
        $failure = $_
        # Closing/killing also releases the asynchronous stderr reader after a
        # broken input pipe or truncated output. Include git's diagnostic.
        if (-not $proc.HasExited) { $proc.Kill($true) }
        $proc.WaitForExit()
        $detail = $stderr.GetAwaiter().GetResult()
        throw ("git cat-file batch failed: " + $failure.Exception.Message + "`n" + $detail)
    } finally {
        if (-not $proc.HasExited) { $proc.Kill($true) }
        $proc.Dispose()
    }
    return ,$contents
}

function Get-GitFileNormalizedHashes {
    param(
        [Parameter(Mandatory=$true)][string]$Repo,
        [Parameter(Mandatory=$true)][string]$Commit,
        [Parameter(Mandatory=$true)][AllowEmptyCollection()][string[]]$Paths
    )
    $contents = Get-GitFileContents -Repo $Repo -Commit $Commit -Paths $Paths
    $hashes = [System.Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
    foreach ($path in $contents.Keys) {
        $content = $contents[$path]
        $hashes[$path] = [pscustomobject]@{
            Hash = if ($null -eq $content) { $null } else { Get-NormalizedSha256 -Content $content }
            BaseHash = if ($null -eq $content) { $null } else { Get-NormalizedSha256 -Content (Get-ContentWithoutCustomRegions -Content $content) }
        }
    }
    return ,$hashes
}
