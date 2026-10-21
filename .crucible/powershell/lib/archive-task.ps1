if (-not (Get-Command "Invoke-WithBacklogLock" -ErrorAction SilentlyContinue)) {
    $backlogIoPath = Join-Path $PSScriptRoot "backlog-io.ps1"
    if (Test-Path -LiteralPath $backlogIoPath) {
        . $backlogIoPath
    }
}

function Get-BacklogTerminalStatus {
    # Production means code merged to the main branch; Resolved means closed without
    # a deploy. Use ShippedCode, since features, bugs and chores can all ship code. Item 62.
    param([Parameter(Mandatory=$true)][bool]$ShippedCode)

    if ($ShippedCode) { return "Production" }
    return "Resolved"
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
    foreach ($line in [System.IO.File]::ReadAllLines($Path, [System.Text.Encoding]::UTF8)) {
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
        if ($line -match '^\s*##\s+') { return -1 }
        if ($line -match '^\s*\|?\s*:?-{3,}:?\s*(\|\s*:?-{3,}:?\s*)+\|?\s*$') {
            $headerIdx = $i - 1
            if ($headerIdx -ge 0 -and $Lines[$headerIdx] -match '^\s*\|') {
                $cells = @($Lines[$headerIdx].Trim().Trim("|").Split("|") | ForEach-Object { $_.Trim() })
                for ($j = 0; $j -lt $cells.Count; $j++) {
                    if ($cells[$j] -ieq "Status") { return $j }
                }
            }
            return -1
        }
        if ($line -match '^\s*\|') {
            $cells = @($line.Trim().Trim("|").Split("|") | ForEach-Object { $_.Trim() })
            for ($j = 0; $j -lt $cells.Count; $j++) {
                if ($cells[$j] -ieq "Status") { return $j }
            }
        }
    }
    return -1
}

function Get-BacklogArchiveRow {
    param(
        [string[]]$Lines,
        [Parameter(Mandatory=$true)][string]$BacklogPath,
        [Parameter(Mandatory=$true)][string]$ActiveRelPath,
        [string]$ItemId
    )

    $activeLink = $ActiveRelPath.Replace("\", "/")
    $rowIndex = -1
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        if ($Lines[$i].Contains("]($activeLink)")) {
            $rowIndex = $i
            break
        }
    }
    # Item 227: both ID fallbacks must match the complete first cell, which is what the
    # row matcher in backlog-io.ps1 checks. Item 245.
    if ($rowIndex -lt 0 -and -not [string]::IsNullOrEmpty($ItemId)) {
        for ($i = 0; $i -lt $Lines.Count; $i++) {
            if (Test-BacklogTaskRow -Line $Lines[$i] -TaskId $ItemId) {
                $rowIndex = $i
                break
            }
        }
    }
    if ($rowIndex -lt 0) {
        $fileName = Split-Path -Leaf $ActiveRelPath
        $taskIdFromFile = ($fileName -replace '_.*$', '') -replace '\.md$', ''
        for ($i = 0; $i -lt $Lines.Count; $i++) {
            if (Test-BacklogTaskRow -Line $Lines[$i] -TaskId $taskIdFromFile) {
                $rowIndex = $i
                break
            }
        }
    }
    if ($rowIndex -lt 0) {
        throw "BACKLOG.md does not contain active spec row: $activeLink in $BacklogPath"
    }

    $statusColumn = Get-MarkdownTableStatusColumn -Lines $Lines -RowIndex $rowIndex
    if ($statusColumn -lt 0) {
        throw "Unable to locate Status column for BACKLOG.md row: $activeLink in $BacklogPath"
    }
    $cells = @($Lines[$rowIndex].Trim().Trim("|").Split("|"))
    if ($statusColumn -ge $cells.Count) {
        throw "Status column index is outside BACKLOG.md row: $activeLink in $BacklogPath"
    }
    return [pscustomobject]@{ RowIndex = $rowIndex; StatusColumn = $statusColumn }
}

function Update-BacklogArchiveRow {
    param(
        [Parameter(Mandatory=$true)][string]$BacklogPath,
        [Parameter(Mandatory=$true)][string]$ActiveRelPath,
        [Parameter(Mandatory=$true)][string]$ArchivedRelPath,
        [Parameter(Mandatory=$true)][string]$Status,
        [string]$ItemId
    )

    Invoke-WithBacklogLock -BacklogPath $BacklogPath -ScriptBlock {
        if (-not (Test-Path -LiteralPath $BacklogPath -PathType Leaf)) {
            throw "Backlog file not found: $BacklogPath"
        }

        $lines = [System.Collections.Generic.List[string]]::new()
        foreach ($line in [System.IO.File]::ReadAllLines($BacklogPath, [System.Text.Encoding]::UTF8)) {
            [void]$lines.Add($line)
        }
        $archiveRow = Get-BacklogArchiveRow -Lines $lines.ToArray() -BacklogPath $BacklogPath -ActiveRelPath $ActiveRelPath -ItemId $ItemId
        $activeLink = $ActiveRelPath.Replace("\", "/")
        $archivedLink = $ArchivedRelPath.Replace("\", "/")
        $row = $lines[$archiveRow.RowIndex].Replace("]($activeLink)", "]($archivedLink)")
        $cells = [System.Collections.Generic.List[string]]::new()
        foreach ($cell in $row.Trim().Trim("|").Split("|")) {
            [void]$cells.Add($cell.Trim())
        }
        $cells[$archiveRow.StatusColumn] = $Status
        $lines[$archiveRow.RowIndex] = "| " + (($cells.ToArray()) -join " | ") + " |"

        [System.IO.File]::WriteAllText($BacklogPath, (($lines.ToArray()) -join [Environment]::NewLine) + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($false))
    }
}

function Update-BacklogPrioritySummary {
    param(
        [Parameter(Mandatory=$true)][string]$BacklogPath,
        [Parameter(Mandatory=$true)][string]$ItemId,
        [string]$Priority
    )

    Invoke-WithBacklogLock -BacklogPath $BacklogPath -ScriptBlock {
        if (-not (Test-Path -LiteralPath $BacklogPath -PathType Leaf)) {
            throw "Backlog file not found: $BacklogPath"
        }

        $lines = [System.Collections.Generic.List[string]]::new()
        foreach ($line in [System.IO.File]::ReadAllLines($BacklogPath, [System.Text.Encoding]::UTF8)) {
            [void]$lines.Add($line)
        }

        # If priority is not provided, try to find which priority bucket in the file contains ItemId
        $detectedPriority = $Priority
        if ([string]::IsNullOrEmpty($detectedPriority)) {
            for ($i = 0; $i -lt $lines.Count; $i++) {
                $line = $lines[$i]
                if ($line -match '^\s*\|\s*\*\*(P[0-3])\*\*\s*\|') {
                    $p = $Matches[1]
                    $parts = $line -split '\|'
                    if ($parts.Length -ge 4) {
                        $itemIds = @($parts[3].Trim().Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" })
                        if ($itemIds -contains $ItemId) {
                            $detectedPriority = $p
                            break
                        }
                    }
                }
            }
        }

        if ([string]::IsNullOrEmpty($detectedPriority)) {
            # ItemId not found in any priority bucket, nothing to do (idempotent/safe)
            return
        }

        # Now update the specific priority line in $lines
        $modified = $false
        for ($i = 0; $i -lt $lines.Count; $i++) {
            $line = $lines[$i]
            if ($line -match "^\s*\|\s*\*\*$detectedPriority\*\*\s*\|") {
                $parts = $line -split '\|'
                if ($parts.Length -ge 4) {
                    # Split item IDs
                    $itemIds = [System.Collections.Generic.List[string]]::new()
                    foreach ($id in ($parts[3].Trim().Split(','))) {
                        $trimmedId = $id.Trim()
                        if ($trimmedId -ne "" -and $trimmedId -ne "-") {
                            [void]$itemIds.Add($trimmedId)
                        }
                    }

                    if ($itemIds -contains $ItemId) {
                        [void]$itemIds.Remove($ItemId)
                        # Sort remaining items for consistency with validate-backlog
                        $sortedItems = @($itemIds.ToArray() | Sort-Object)
                        $newCount = $sortedItems.Count
                        $newItemsText = if ($newCount -gt 0) { $sortedItems -join ", " } else { "-" }

                        $lines[$i] = "| **$detectedPriority** | $newCount | $newItemsText |"
                        $modified = $true
                    }
                }
                break
            }
        }

        # Update Status Overview if we modified the priority bucket
        if ($modified) {
            # Let's count total active items across all P0-P3 lines in the newly updated $lines array
            $totalActive = 0
            for ($i = 0; $i -lt $lines.Count; $i++) {
                $line = $lines[$i]
                if ($line -match '^\s*\|\s*\*\*(P[0-3])\*\*\s*\|') {
                    $parts = $line -split '\|'
                    if ($parts.Length -ge 3) {
                        $countVal = 0
                        if ([int]::TryParse($parts[2].Trim(), [ref]$countVal)) {
                            $totalActive += $countVal
                        }
                    }
                }
            }

            # Replace the Status Overview line: **Status Overview**: <total> active items.
            for ($i = 0; $i -lt $lines.Count; $i++) {
                if ($lines[$i] -match '^\*\*Status Overview\*\*:') {
                    $lines[$i] = "**Status Overview**: $totalActive active items."
                    break
                }
            }

            # Write back to file as UTF-8 no-BOM
            [System.IO.File]::WriteAllText($BacklogPath, (($lines.ToArray()) -join [Environment]::NewLine) + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($false))
        }
    }
}

function Invoke-BacklogTaskArchive {
    param(
        [Parameter(Mandatory=$true)][string]$BacklogPath,
        [Parameter(Mandatory=$true)][string]$SpecPath,
        [ValidateSet("Production","Resolved","Abandoned")][string]$Status,
        # Whether this task merged code. Every caller that does not pass -Status binds this
        # explicitly, because neither default is safe: assuming no would record a shipped fix
        # as closed without a deploy, and assuming yes would claim a deploy that never
        # happened. Left unbound the archive refuses rather than picks one.
        [switch]$ShippedCode
    )

    $hasShippedCode = $PSBoundParameters.ContainsKey("ShippedCode")
    return Invoke-WithBacklogLock -BacklogPath $BacklogPath -ScriptBlock {
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
        $terminalStatus = $Status
        if ([string]::IsNullOrEmpty($terminalStatus)) {
            # Check if the active spec's frontmatter status is already a terminal value ("Production" or "Resolved")
            $specLines = [System.IO.File]::ReadAllLines($resolvedSpec, [System.Text.Encoding]::UTF8)
            $frontmatterEnd = -1
            if ($specLines.Count -gt 0 -and $specLines[0] -eq "---") {
                for ($i = 1; $i -lt $specLines.Count; $i++) {
                    if ($specLines[$i] -eq "---") {
                        $frontmatterEnd = $i
                        break
                    }
                }
            }
            if ($frontmatterEnd -gt 0) {
                $specStatus = ""
                for ($i = 1; $i -lt $frontmatterEnd; $i++) {
                    if ($specLines[$i] -match '^\s*status\s*:\s*["'']?([^"''\s\r\n]+)"?') {
                        $specStatus = $Matches[1]
                        break
                    }
                }
                if ($specStatus -eq "Production" -or $specStatus -eq "Resolved") {
                    $terminalStatus = $specStatus
                }
            }
        }
        if ([string]::IsNullOrEmpty($terminalStatus)) {
            if (-not $hasShippedCode) {
                throw ("Cannot derive a terminal status for " + $relativeSpec + ". Pass -Status explicitly, or pass -ShippedCode (true or false) to state whether this task merged code. The item type is not evidence of whether it deployed.")
            }
            $terminalStatus = Get-BacklogTerminalStatus -ShippedCode ([bool]$ShippedCode)
        }

        # Read item_id and priority from active spec frontmatter before moving
        $itemId = $null
        $priority = $null
        if (Test-Path -LiteralPath $resolvedSpec) {
            $specLines = [System.IO.File]::ReadAllLines($resolvedSpec, [System.Text.Encoding]::UTF8)
            $frontmatterEnd = -1
            if ($specLines.Count -gt 0 -and $specLines[0] -eq "---") {
                for ($i = 1; $i -lt $specLines.Count; $i++) {
                    if ($specLines[$i] -eq "---") {
                        $frontmatterEnd = $i
                        break
                    }
                }
            }
            if ($frontmatterEnd -gt 0) {
                for ($i = 1; $i -lt $frontmatterEnd; $i++) {
                    $line = $specLines[$i]
                    if ($line -match '^\s*item_id\s*:\s*["'']?([^"''\s\r\n]+)"?') {
                        $itemId = $Matches[1]
                    }
                    elseif ($line -match '^\s*priority\s*:\s*["'']?([P][0-3])"?') {
                        $priority = $Matches[1]
                    }
                }
            }
        }

        if ([string]::IsNullOrEmpty($itemId)) {
            $fileName = Split-Path -Leaf $resolvedSpec
            $itemId = ($fileName -replace '_.*$', '') -replace '\.md$', ''
        }

        $archivedRelPath = $relativeSpec -replace '/active/', '/archived/'
        $archivedPath = Join-Path $resolvedBacklogDir ($archivedRelPath -replace '/', [System.IO.Path]::DirectorySeparatorChar)
        $archiveDir = Split-Path -Parent $archivedPath
        if (Test-Path -LiteralPath $archivedPath) {
            throw "Archived spec already exists: $archivedPath"
        }

        # TODO item 191: validate before mutation and preserve bytes, since a move back
        # alone leaves terminal frontmatter and a late failure leaves an archived link.
        $backlogLines = [System.IO.File]::ReadAllLines($resolvedBacklog, [System.Text.Encoding]::UTF8)
        Get-BacklogArchiveRow -Lines $backlogLines -BacklogPath $resolvedBacklog -ActiveRelPath $relativeSpec -ItemId $itemId | Out-Null
        $originalSpec = [System.IO.File]::ReadAllBytes($resolvedSpec)
        $originalBacklog = [System.IO.File]::ReadAllBytes($resolvedBacklog)
        try {
            if (-not (Test-Path -LiteralPath $archiveDir)) {
                New-Item -ItemType Directory -Path $archiveDir -Force -ErrorAction Stop | Out-Null
            }
            Move-Item -LiteralPath $resolvedSpec -Destination $archivedPath -ErrorAction Stop
            Set-BacklogSpecFrontmatterStatus -Path $archivedPath -Status $terminalStatus
            Update-BacklogArchiveRow -BacklogPath $resolvedBacklog -ActiveRelPath $relativeSpec -ArchivedRelPath $archivedRelPath -Status $terminalStatus -ItemId $itemId
            Update-BacklogPrioritySummary -BacklogPath $resolvedBacklog -ItemId $itemId -Priority $priority
        } catch {
            try {
                if ((Test-Path -LiteralPath $archivedPath) -and -not (Test-Path -LiteralPath $resolvedSpec)) {
                    Move-Item -LiteralPath $archivedPath -Destination $resolvedSpec -ErrorAction Stop
                }
                [System.IO.File]::WriteAllBytes($resolvedSpec, $originalSpec)
            } finally {
                [System.IO.File]::WriteAllBytes($resolvedBacklog, $originalBacklog)
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
}
