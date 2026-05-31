function Get-BacklogTerminalStatus {
    param([Parameter(Mandatory=$true)][string]$Type)

    $normalized = $Type.Trim().ToLowerInvariant()
    if ($normalized -eq "features" -or $normalized -eq "feature") { return "Production" }
    if ($normalized -eq "bugs" -or $normalized -eq "bug") { return "Resolved" }
    if ($normalized -eq "chores" -or $normalized -eq "chore") { return "Resolved" }
    throw "Unsupported backlog item type: $Type"
}

function Set-BacklogSpecFrontmatterStatus {
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)][string]$Status
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Spec file not found: $Path"
    }

    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($line in [System.IO.File]::ReadAllLines($Path)) {
        [void]$lines.Add($line)
    }

    if ($lines.Count -eq 0 -or $lines[0] -ne "---") {
        throw "Spec file is missing YAML frontmatter delimiter: $Path"
    }

    $frontmatterEnd = -1
    for ($i = 1; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -eq "---") {
            $frontmatterEnd = $i
            break
        }
    }
    if ($frontmatterEnd -lt 0) {
        throw "Spec file frontmatter is not closed: $Path"
    }

    $statusLine = -1
    for ($i = 1; $i -lt $frontmatterEnd; $i++) {
        if ($lines[$i] -match '^\s*status\s*:') {
            $statusLine = $i
            break
        }
    }

    $replacement = ('status: "' + $Status + '"')
    if ($statusLine -ge 0) {
        $lines[$statusLine] = $replacement
    } else {
        $insertAt = 1
        for ($i = 1; $i -lt $frontmatterEnd; $i++) {
            if ($lines[$i] -match '^\s*type\s*:') {
                $insertAt = $i + 1
                break
            }
        }
        $lines.Insert($insertAt, $replacement)
    }

    [System.IO.File]::WriteAllText($Path, (($lines.ToArray()) -join [Environment]::NewLine) + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($false))
}

function Get-MarkdownTableStatusColumn {
    param(
        [string[]]$Lines,
        [Parameter(Mandatory=$true)][int]$RowIndex
    )

    for ($i = $RowIndex - 1; $i -ge 0; $i--) {
        $line = $Lines[$i]
        if ($line -notmatch '^\s*\|') { return -1 }
        if ($line -notmatch '^\s*\|?\s*:?-{3,}:?\s*(\|\s*:?-{3,}:?\s*)+\|?\s*$') { continue }

        $headerIndex = $i - 1
        if ($headerIndex -lt 0) { return -1 }

        $headerLine = $Lines[$headerIndex]
        if ($headerLine -notmatch '^\s*\|') { return -1 }
        if ($headerLine -match '^\s*\|?\s*:?-{3,}:?\s*(\|\s*:?-{3,}:?\s*)+\|?\s*$') { return -1 }

        $cells = @($headerLine.Trim().Trim("|").Split("|") | ForEach-Object { $_.Trim() })
        for ($j = 0; $j -lt $cells.Count; $j++) {
            if ($cells[$j] -eq "Status") { return $j }
        }
        return -1
    }
    return -1
}

function Update-BacklogArchiveRow {
    param(
        [Parameter(Mandatory=$true)][string]$BacklogPath,
        [Parameter(Mandatory=$true)][string]$ActiveRelPath,
        [Parameter(Mandatory=$true)][string]$ArchivedRelPath,
        [Parameter(Mandatory=$true)][string]$Status
    )

    if (-not (Test-Path -LiteralPath $BacklogPath -PathType Leaf)) {
        throw "Backlog file not found: $BacklogPath"
    }

    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($line in [System.IO.File]::ReadAllLines($BacklogPath)) {
        [void]$lines.Add($line)
    }

    $activeLink = $ActiveRelPath.Replace("\", "/")
    $archivedLink = $ArchivedRelPath.Replace("\", "/")
    $rowIndex = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i].Contains("]($activeLink)")) {
            $rowIndex = $i
            break
        }
    }
    if ($rowIndex -lt 0) {
        throw "BACKLOG.md does not contain active spec link: $activeLink"
    }

    $lineArray = [string[]]$lines.ToArray()
    $statusColumn = Get-MarkdownTableStatusColumn -Lines $lineArray -RowIndex $rowIndex
    if ($statusColumn -lt 0) {
        throw "Unable to locate Status column for BACKLOG.md row: $activeLink"
    }

    $row = $lines[$rowIndex].Replace("]($activeLink)", "]($archivedLink)")
    $cells = [System.Collections.Generic.List[string]]::new()
    foreach ($cell in $row.Trim().Trim("|").Split("|")) {
        [void]$cells.Add($cell.Trim())
    }
    if ($statusColumn -ge $cells.Count) {
        throw "Status column index is outside BACKLOG.md row: $activeLink"
    }
    $cells[$statusColumn] = $Status
    $lines[$rowIndex] = "| " + (($cells.ToArray()) -join " | ") + " |"

    [System.IO.File]::WriteAllText($BacklogPath, (($lines.ToArray()) -join [Environment]::NewLine) + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($false))
}

function Invoke-BacklogTaskArchive {
    param(
        [Parameter(Mandatory=$true)][string]$BacklogPath,
        [Parameter(Mandatory=$true)][string]$SpecPath
    )

    $resolvedBacklog = (Resolve-Path -LiteralPath $BacklogPath).Path
    $resolvedBacklogDir = (Resolve-Path -LiteralPath (Split-Path -Parent $resolvedBacklog)).Path
    $specMatches = @(Resolve-Path -Path $SpecPath)
    if ($specMatches.Count -ne 1) {
        throw "SpecPath must resolve to exactly one spec file; found $($specMatches.Count): $SpecPath"
    }
    $resolvedSpec = $specMatches[0].Path

    if (-not $resolvedSpec.StartsWith($resolvedBacklogDir, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Spec path is not under backlog directory: $resolvedSpec"
    }

    $relativeSpec = $resolvedSpec.Substring($resolvedBacklogDir.Length).TrimStart([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
    $relativeSpec = $relativeSpec.Replace("\", "/")
    if ($relativeSpec -notmatch '^(features|bugs|chores)/active/[^/]+\.md$') {
        throw "Spec path must be an active feature, bug, or chore markdown file: $relativeSpec"
    }

    $type = $Matches[1]
    $terminalStatus = Get-BacklogTerminalStatus -Type $type
    $archivedRelPath = $relativeSpec -replace '/active/', '/archived/'
    $archivedPath = Join-Path $resolvedBacklogDir ($archivedRelPath -replace '/', [System.IO.Path]::DirectorySeparatorChar)
    $archiveDir = Split-Path -Parent $archivedPath
    if (-not (Test-Path -LiteralPath $archiveDir)) {
        New-Item -ItemType Directory -Path $archiveDir -Force | Out-Null
    }
    if (Test-Path -LiteralPath $archivedPath) {
        throw "Archived spec already exists: $archivedPath"
    }

    Move-Item -LiteralPath $resolvedSpec -Destination $archivedPath
    try {
        Set-BacklogSpecFrontmatterStatus -Path $archivedPath -Status $terminalStatus
        Update-BacklogArchiveRow -BacklogPath $resolvedBacklog -ActiveRelPath $relativeSpec -ArchivedRelPath $archivedRelPath -Status $terminalStatus
    } catch {
        if ((Test-Path -LiteralPath $archivedPath) -and -not (Test-Path -LiteralPath $resolvedSpec)) {
            Move-Item -LiteralPath $archivedPath -Destination $resolvedSpec
        }
        throw
    }

    return [pscustomobject]@{
        Type = $type
        Status = $terminalStatus
        ArchivedPath = $archivedPath
        ArchivedRelPath = $archivedRelPath
    }
}
