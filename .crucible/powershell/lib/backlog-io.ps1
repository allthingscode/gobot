Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Get-BacklogItemPathForTaskProjectRoot below needs Get-ConfiguredPath. crucible-lib.ps1
# loads config-helpers.ps1 first, so this normally does nothing; it exists so a caller
# that dot-sources this file on its own gets a working function rather than a missing one.
if (-not (Test-Path -LiteralPath Function:Get-ConfiguredPath)) {
    . (Join-Path $PSScriptRoot "config-helpers.ps1")
}

# TODO item 197: standalone restore callers also need the validator's shell resolver.
if (-not (Test-Path -LiteralPath Function:Get-PwshCommand)) {
    . (Join-Path $PSScriptRoot "platform.ps1")
}

if (-not (Test-Path variable:script:HeldBacklogLocks)) {
    $script:HeldBacklogLocks = @{}
}

function Get-BacklogLockFilePath {
    param([Parameter(Mandatory=$true)][string]$BacklogPath)

    if (Test-Path -LiteralPath $BacklogPath) {
        $resolved = (Resolve-FilesystemPath -Path (Resolve-Path -LiteralPath $BacklogPath))
    } else {
        $parent = Split-Path -Parent $BacklogPath
        if ($parent -and (Test-Path -LiteralPath $parent)) {
            $resolved = Join-Path (Resolve-FilesystemPath -Path (Resolve-Path -LiteralPath $parent)) (Split-Path -Leaf $BacklogPath)
        } else {
            $resolved = Resolve-FilesystemPath -Path $BacklogPath
        }
    }
    return "$resolved.lock"
}

function Invoke-WithBacklogLock {
    param(
        [Parameter(Mandatory=$true)][string]$BacklogPath,
        [Parameter(Mandatory=$true)][scriptblock]$ScriptBlock,
        [int]$TimeoutSeconds = 10
    )

    if ([string]::IsNullOrWhiteSpace($BacklogPath)) {
        throw "BacklogPath parameter cannot be empty."
    }

    $lockPath = Get-BacklogLockFilePath -BacklogPath $BacklogPath
    $normLockPath = $lockPath.ToLowerInvariant()

    # Process-local re-entrancy check
    if ($script:HeldBacklogLocks.ContainsKey($normLockPath) -and $script:HeldBacklogLocks[$normLockPath] -gt 0) {
        $script:HeldBacklogLocks[$normLockPath] = $script:HeldBacklogLocks[$normLockPath] + 1
        try {
            return & $ScriptBlock
        } finally {
            $script:HeldBacklogLocks[$normLockPath] = $script:HeldBacklogLocks[$normLockPath] - 1
            if ($script:HeldBacklogLocks[$normLockPath] -eq 0) {
                $script:HeldBacklogLocks.Remove($normLockPath)
            }
        }
    }

    # The open handle is the lock, held for the whole write, as in Invoke-FileLock. A dead
    # holder's handle is closed by the OS and DeleteOnClose frees the path, so no waiter
    # judges a lock stale and deletes it; that guess let two waiters both enter. Item 224.
    $startTime = [System.DateTime]::UtcNow
    $fileStream = $null
    while ($null -eq $fileStream) {
        try {
            $fileStream = New-Object System.IO.FileStream(
                (Resolve-FilesystemPath -Path $lockPath),
                [System.IO.FileMode]::OpenOrCreate,
                [System.IO.FileAccess]::ReadWrite,
                [System.IO.FileShare]::None,
                1,
                [System.IO.FileOptions]::DeleteOnClose
            )
        } catch [System.IO.IOException] {
            # As in Invoke-FileLock, only a sharing violation is another holder. A missing
            # directory or bad path cannot be waited out, so it refuses now, naming the lock.
            $ioError = $_.Exception
            while ($null -ne $ioError.InnerException) { $ioError = $ioError.InnerException }
            $nativeCode = $ioError.HResult -band 0xFFFF
            $isContention = ($IsWindows -and $nativeCode -in @(32, 33)) -or
                ($IsLinux -and $nativeCode -eq 11) -or ($IsMacOS -and $nativeCode -eq 35)
            if (-not $isContention) {
                throw [System.IO.IOException]::new("Cannot acquire BACKLOG.md lock at " + $lockPath + ": " + $ioError.Message, $ioError)
            }
            if (([System.DateTime]::UtcNow - $startTime).TotalSeconds -ge $TimeoutSeconds) {
                throw "Timed out waiting to acquire BACKLOG.md lock at $lockPath (timeout ${TimeoutSeconds}s)"
            }
            Start-Sleep -Milliseconds 100
        }
    }

    $script:HeldBacklogLocks[$normLockPath] = 1
    try {
        return & $ScriptBlock
    } finally {
        $script:HeldBacklogLocks.Remove($normLockPath)
        $fileStream.Dispose()
    }
}

# TODO item 190: keep both legal spec filename forms in one place; callers choose
# directory order and whether archived subdirectories belong in their search.
function Get-BacklogSpecFiles {
    param(
        [Parameter(Mandatory = $true)][string]$Task,
        [Parameter(Mandatory = $true)][string]$Directory,
        [switch]$Recurse
    )

    foreach ($pattern in @(($Task + "_*.md"), ($Task + ".md"))) {
        Get-ChildItem -LiteralPath $Directory -File -Filter $pattern -Recurse:$Recurse -ErrorAction SilentlyContinue
    }
}

# Findings use the same exact filename forms as specs. All research-directory readers
# return every match in ordinal filename order, independent of mtimes. Item 257, I8/I13.
function Get-ResearchFindingsArtifact {
    param(
        [Parameter(Mandatory = $true)][string]$TaskId,
        [Parameter(Mandatory = $true)][string]$ResearchDirectory
    )

    $files = @(Get-BacklogSpecFiles -Task $TaskId -Directory $ResearchDirectory)
    $names = [string[]]@($files | ForEach-Object { $_.Name })
    [Array]::Sort($names, [StringComparer]::Ordinal)
    foreach ($name in $names) {
        $files | Where-Object { $_.Name -ceq $name }
    }
}

# The one matcher of a BACKLOG.md or ARCHIVED.md row by task ID: the first cell is the ID
# or a link whose text is the ID (item 227). Find, edit and delete all ask it. Item 245.
function Test-BacklogTaskRow {
    param(
        [AllowEmptyString()][string]$Line,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$TaskId
    )

    $escaped = [regex]::Escape($TaskId)
    return ($Line -match ('^\s*\|\s*(?:' + $escaped + '|\[' + $escaped + '\]\([^|]*\))\s*\|'))
}

# Resolve a spec from a task id, preferring active over loose over archived.
# Keep this shared lookup independent of gate orchestration. Item 14.
function Get-BacklogItemPathForTaskProjectRoot {
    param(
        [Parameter(Mandatory = $true)][string]$Task,
        [string]$ProjectRoot = ""
    )

    $typeDir = if ($Task -match "^F-") {
        "features"
    } elseif ($Task -match "^B-") {
        "bugs"
    } elseif ($Task -match "^C-") {
        "chores"
    } else {
        ""
    }

    $typeDirs = if ([string]::IsNullOrWhiteSpace($typeDir)) {
        @("features", "bugs", "chores")
    } else {
        @($typeDir)
    }

    $backlogDir = Get-ConfiguredPath -Key "backlog" -ProjectRoot $ProjectRoot
    foreach ($dir in $typeDirs) {
        foreach ($sub in @(($dir + "/active"), $dir, ($dir + "/archived"))) {
            $searchPath = Join-Path $backlogDir $sub
            $recurse = $sub.EndsWith("/archived")
            $match = Get-BacklogSpecFiles -Task $Task -Directory $searchPath -Recurse:$recurse | Select-Object -First 1
            if ($null -ne $match) {
                return $match.FullName
            }
        }
    }

    return ""
}

function Get-BacklogSpecStatus {
    param(
        [Parameter(Mandatory = $true)][string]$Task,
        [string]$ProjectRoot = ""
    )

    # The spec's frontmatter is the artifact; BACKLOG.md is an index rendered from it.
    # Returns $null when no spec exists at all, which is what lets a caller tell
    # "no such task" apart from "task exists and its status is blank".
    $specPath = Get-BacklogItemPathForTaskProjectRoot -Task $Task -ProjectRoot $ProjectRoot
    if ([string]::IsNullOrWhiteSpace($specPath) -or -not (Test-Path -LiteralPath $specPath)) {
        return $null
    }

    foreach ($line in (Get-Content -LiteralPath $specPath -Head 30 -Encoding UTF8)) {
        if ($line -match '^\s*status:\s*"?([^"#]+?)"?\s*$') {
            return $matches[1].Trim()
        }
    }

    return ""
}

function Get-BacklogTaskStatus {
    param(
        [Parameter(Mandatory = $true)][string]$Task,
        [string]$ProjectRoot = "",
        [string]$BacklogDir = ""
    )

    # Shared status resolver for dependency checks and concurrent-Groomer exclusions.
    # Spec first, index second: archived specs can exist without a BACKLOG.md row. Item 54.
    $specStatus = Get-BacklogSpecStatus -Task $Task -ProjectRoot $ProjectRoot
    if ($null -ne $specStatus) {
        return @{ Found = $true; Status = $specStatus; Source = "its spec file"; Searched = @("its spec file") }
    }

    if ([string]::IsNullOrWhiteSpace($BacklogDir)) {
        $BacklogDir = Get-ConfiguredPath -Key "backlog" -ProjectRoot $ProjectRoot
    }

    $searched = @("its spec file")
    foreach ($name in @("BACKLOG.md", "ARCHIVED.md")) {
        $indexPath = Join-Path $BacklogDir $name
        if (-not (Test-Path $indexPath)) { continue }
        $searched += $name

        $statusColumnIndex = -1
        foreach ($line in (Get-Content -Path $indexPath -Encoding UTF8)) {
            if ($line -match '^\|\s*ID\s*\|') {
                $headerCols = ($line -split '\|' | ForEach-Object { $_.Trim() }) | Where-Object { $_ -ne "" }
                $statusColumnIndex = [Array]::IndexOf($headerCols, "Status")
                continue
            }
            if ($line -match '^\|\s*[-: ]+\|') { continue }

            if (Test-BacklogTaskRow -Line $line -TaskId $Task) {
                $rowCols = ($line -split '\|' | ForEach-Object { $_.Trim() }) | Where-Object { $_ -ne "" }
                $status = if ($statusColumnIndex -ge 0 -and $statusColumnIndex -lt $rowCols.Count) {
                    $rowCols[$statusColumnIndex]
                } elseif ($rowCols.Count -gt 0) {
                    $rowCols[$rowCols.Count - 1]
                } else {
                    ""
                }
                return @{ Found = $true; Status = $status; Source = $name; Searched = $searched }
            }
        }
    }

    return @{ Found = $false; Status = ""; Source = ""; Searched = $searched }
}

function Test-BacklogTaskTerminal {
    param($Status)

    if ($null -eq $Status) { return $false }
    $normalized = ([string]$Status).Trim().ToLowerInvariant()
    return ($normalized -eq "production" -or $normalized -eq "resolved")
}

# TODO item 197: restoration owns the active row and frontmatter edits.
function Restore-BacklogTask {
    param(
        [Parameter(Mandatory=$true)][string]$TaskId,
        [string]$ProjectRoot = "",
        [string]$ActiveStatus = "In Progress"
    )
    $resolvedProjectRoot = Resolve-ConfigProjectRoot -ProjectRoot $ProjectRoot

    $backlogDir = Get-ConfiguredPath -Key "backlog" -ProjectRoot $resolvedProjectRoot
    $backlogPath = Join-Path $backlogDir "BACKLOG.md"
    if (-not (Test-Path -LiteralPath $backlogPath)) { return }

    # Find the spec (either in archived/ or active/)
    $typeDirs = @("features", "bugs", "chores")
    $specPath = ""
    $type = ""
    $isArchived = $false
    foreach ($dir in $typeDirs) {
        $archivedMatch = Get-BacklogSpecFiles -Task $TaskId -Directory (Join-Path $backlogDir ($dir + "/archived")) | Select-Object -First 1
        if ($null -ne $archivedMatch) {
            $specPath = $archivedMatch.FullName
            $type = $dir
            $isArchived = $true
            break
        }
        $activeMatch = Get-BacklogSpecFiles -Task $TaskId -Directory (Join-Path $backlogDir ($dir + "/active")) | Select-Object -First 1
        if ($null -ne $activeMatch) {
            $specPath = $activeMatch.FullName
            $type = $dir
            $isArchived = $false
            break
        }
    }

    if ([string]::IsNullOrEmpty($specPath)) { return }

    $fileName = Split-Path -Leaf $specPath
    $activeDir = Join-Path $backlogDir "$type/active"
    if (-not (Test-Path $activeDir)) {
        New-Item -ItemType Directory -Path $activeDir -Force | Out-Null
    }
    $activeSpecPath = Join-Path $activeDir $fileName
    if ($isArchived) {
        Move-Item -LiteralPath $specPath -Destination $activeSpecPath -Force
    }

    # Restore frontmatter status
    $archiveLibPath = Join-Path $PSScriptRoot "archive-task.ps1"
    if (-not (Get-Command "Set-BacklogSpecFrontmatterStatus" -ErrorAction SilentlyContinue)) {
        if (Test-Path -LiteralPath $archiveLibPath) { . $archiveLibPath }
    }
    if (Get-Command "Set-BacklogSpecFrontmatterStatus" -ErrorAction SilentlyContinue) {
        Set-BacklogSpecFrontmatterStatus -Path $activeSpecPath -Status $ActiveStatus
    }

    # Restore and normalize BACKLOG.md row
    $relativeActive = "$type/active/$fileName".Replace("\", "/")
    $relativeArchived = "$type/archived/$fileName".Replace("\", "/")

    Invoke-WithBacklogLock -BacklogPath $backlogPath -ScriptBlock {
        $rawLines = [System.IO.File]::ReadAllLines((Resolve-FilesystemPath -Path $backlogPath), [System.Text.Encoding]::UTF8)
        $lines = [System.Collections.Generic.List[string]]::new()
        foreach ($line in $rawLines) { [void]$lines.Add($line) }

        # 1. Find and extract every row whose ID cell is TaskId. A row that only mentions
        # the ID in another cell belongs to another task and stays. Item 245.
        $matchingIndexes = @()
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if (Test-BacklogTaskRow -Line $lines[$i] -TaskId $TaskId) {
                $matchingIndexes += $i
            }
        }
        $matchingRow = ""
        if ($matchingIndexes.Count -gt 0) {
            $matchingRow = $lines[$matchingIndexes[0]]
            for ($d = $matchingIndexes.Count - 1; $d -ge 0; $d--) {
                $lines.RemoveAt($matchingIndexes[$d])
            }
        } else {
            $matchingRow = "| [$TaskId]($relativeActive) | P2 | $ActiveStatus | $TaskId | Operator |"
        }

        # 2. Drop a bespoke ## Production Items section once this task's row has left it and
        # it holds no other task's row. Other completed tasks may still be listed there, so
        # the section is never removed while it has data rows. Item 181.
        for ($i = $lines.Count - 1; $i -ge 0; $i--) {
            if ($lines[$i] -match '^\s*##\s+Production\s+Items') {
                $removeCount = 1
                $tableLines = 0
                $hasSeparator = $false
                while (($i + $removeCount) -lt $lines.Count -and $lines[$i + $removeCount] -notmatch '^\s*##\s+') {
                    $sectionLine = $lines[$i + $removeCount]
                    if ($sectionLine -match '^\s*\|?\s*:?-{3,}') { $hasSeparator = $true }
                    elseif ($sectionLine -match '^\s*\|') { $tableLines++ }
                    $removeCount++
                }
                $dataRows = if ($hasSeparator) { $tableLines - 1 } else { $tableLines }
                if ($dataRows -le 0) {
                    for ($r = 0; $r -lt $removeCount; $r++) {
                        $lines.RemoveAt($i)
                    }
                }
            }
        }

        # 3. Update row link: convert /archived/ link to /active/ link
        $matchingRow = $matchingRow -replace '/archived/', '/active/'
        if (-not $matchingRow.Contains("]($relativeActive)")) {
            $matchingRow = $matchingRow -replace '\]\([^)]*' + [regex]::Escape($TaskId) + '[^)]*\)', "]($relativeActive)"
        }

        # 4. Re-insert row under correct active section (after table separator)
        $targetHeader = switch ($type) {
            "features" { "## Features" }
            "bugs"     { "## Bugs" }
            "chores"   { "## Chores" }
            default    { "## Features" }
        }

        $mainIdx = -1
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i].Trim() -eq $targetHeader -or $lines[$i].Trim() -eq "## Active Items") {
                $insertIdx = $i + 1
                while ($insertIdx -lt $lines.Count -and ($lines[$insertIdx] -match '^\s*\|' -or [string]::IsNullOrWhiteSpace($lines[$insertIdx]))) {
                    if ($lines[$insertIdx] -match '^\s*\|') {
                        $insertIdx++
                        if ($insertIdx -lt $lines.Count -and $lines[$insertIdx] -match '^\s*\|?\s*:?-{3,}:?\s*') {
                            $insertIdx++
                        }
                        break
                    }
                    $insertIdx++
                }
                $lines.Insert($insertIdx, $matchingRow)
                $mainIdx = $insertIdx
                break
            }
        }
        if ($mainIdx -lt 0) {
            [void]$lines.Add($matchingRow)
            $mainIdx = $lines.Count - 1
        }

        $lineArray = [string[]]$lines.ToArray()
        if (-not (Get-Command "Get-MarkdownTableStatusColumn" -ErrorAction SilentlyContinue)) {
            if (Test-Path -LiteralPath $archiveLibPath) { . $archiveLibPath }
        }
        if (Get-Command "Get-MarkdownTableStatusColumn" -ErrorAction SilentlyContinue) {
            $statusColumn = Get-MarkdownTableStatusColumn -Lines $lineArray -RowIndex $mainIdx
            if ($statusColumn -ge 0) {
                $cells = [System.Collections.Generic.List[string]]::new()
                foreach ($cell in $lines[$mainIdx].Trim().Trim("|").Split("|")) {
                    [void]$cells.Add($cell.Trim())
                }
                if ($statusColumn -lt $cells.Count) {
                    $cells[$statusColumn] = $ActiveStatus
                    $lines[$mainIdx] = "| " + (($cells.ToArray()) -join " | ") + " |"
                }
            }
        }

        [System.IO.File]::WriteAllText((Resolve-FilesystemPath -Path $backlogPath), (($lines.ToArray()) -join [Environment]::NewLine) + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($false))
    }

    # Reconcile Priority-Summary and validate
    $validateScript = Join-Path (Split-Path -Parent $PSScriptRoot) "validate-backlog.ps1"
    if (Test-Path $validateScript) {
        & (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $validateScript -FixSummary -ProjectRoot $resolvedProjectRoot | Out-Null
    }
}


function Set-ArchivedBacklogTaskAbandoned {
    # TODO item 197: the legacy archive already exists; only its status and row change.
    param(
        [Parameter(Mandatory=$true)][string]$TaskId,
        [Parameter(Mandatory=$true)][string]$BacklogDir,
        [Parameter(Mandatory=$true)][string]$BacklogPath
    )

    # If it was already archived (legacy flow), set frontmatter and BACKLOG.md row to Abandoned
    $typeDirs = @("features", "bugs", "chores")
    foreach ($dir in $typeDirs) {
        $archivedMatch = Get-BacklogSpecFiles -Task $TaskId -Directory (Join-Path $backlogDir ($dir + "/archived")) | Select-Object -First 1
        if ($null -ne $archivedMatch) {
            $archiveLibPath = Join-Path $PSScriptRoot "archive-task.ps1"
            if (-not (Get-Command "Set-BacklogSpecFrontmatterStatus" -ErrorAction SilentlyContinue)) {
                if (Test-Path -LiteralPath $archiveLibPath) { . $archiveLibPath }
            }
            if (Get-Command "Set-BacklogSpecFrontmatterStatus" -ErrorAction SilentlyContinue) {
                Set-BacklogSpecFrontmatterStatus -Path $archivedMatch.FullName -Status "Abandoned"
            }
            $relativeArchived = "$dir/archived/$($archivedMatch.Name)"
            $archivedLink = $relativeArchived.Replace("\", "/")
            if (-not (Get-Command "Get-MarkdownTableStatusColumn" -ErrorAction SilentlyContinue)) {
                if (Test-Path -LiteralPath $archiveLibPath) { . $archiveLibPath }
            }
            # Read, edit and write under one lock so a row another run changes
            # in between is not overwritten. Item 183.
            Invoke-WithBacklogLock -BacklogPath $backlogPath -ScriptBlock {
                $lines = [System.Collections.Generic.List[string]]::new()
                foreach ($line in [System.IO.File]::ReadAllLines((Resolve-FilesystemPath -Path $backlogPath), [System.Text.Encoding]::UTF8)) {
                    [void]$lines.Add($line)
                }
                $rowIndex = -1
                for ($i = 0; $i -lt $lines.Count; $i++) {
                    if ($lines[$i].Contains("]($archivedLink)")) {
                        $rowIndex = $i
                        break
                    }
                }
                if ($rowIndex -lt 0) { return }
                $statusColumn = Get-MarkdownTableStatusColumn -Lines ([string[]]$lines.ToArray()) -RowIndex $rowIndex
                if ($statusColumn -lt 0) { return }
                $cells = [System.Collections.Generic.List[string]]::new()
                foreach ($cell in $lines[$rowIndex].Trim().Trim("|").Split("|")) {
                    [void]$cells.Add($cell.Trim())
                }
                if ($statusColumn -ge $cells.Count) { return }
                $cells[$statusColumn] = "Abandoned"
                $lines[$rowIndex] = "| " + (($cells.ToArray()) -join " | ") + " |"
                [System.IO.File]::WriteAllText((Resolve-FilesystemPath -Path $backlogPath), (($lines.ToArray()) -join [Environment]::NewLine) + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($false))
            }
            break
        }
    }
}

function Get-TaskFinalizationDetails {
    param(
        [Parameter(Mandatory=$true)][string]$TaskId,
        [string]$ProjectRoot = ""
    )

    $backlogDir = Get-ConfiguredPath -Key "backlog" -ProjectRoot $ProjectRoot
    $backlogPath = Join-Path $backlogDir "BACKLOG.md"

    $result = [ordered]@{
        IsFinalized = $false
        BacklogStatus = ""
        SpecExistsInActive = $false
        SpecPathInActive = ""
        SpecExistsInArchived = $false
        SpecPathInArchived = ""
        SpecStatusMatches = $false
        Error = ""
    }

    if (-not (Test-Path -LiteralPath $backlogPath)) {
        $result.Error = "BACKLOG.md not found at $backlogPath"
        return [pscustomobject]$result
    }

    # Load archive-task helper if not loaded
    $archiveLibPath = Join-Path $PSScriptRoot "archive-task.ps1"
    if (-not (Get-Command "Get-MarkdownTableStatusColumn" -ErrorAction SilentlyContinue)) {
        if (Test-Path -LiteralPath $archiveLibPath) {
            . $archiveLibPath
        } else {
            throw "archive-task helper not found at $archiveLibPath"
        }
    }

    # 1. Search spec paths first
    $typeDirs = @("features", "bugs", "chores")
    foreach ($dir in $typeDirs) {
        $activeMatch = Get-BacklogSpecFiles -Task $TaskId -Directory (Join-Path $backlogDir ($dir + "/active")) | Select-Object -First 1
        if ($null -ne $activeMatch) {
            $result.SpecExistsInActive = $true
            $result.SpecPathInActive = $activeMatch.FullName
        }

        $archivedMatch = Get-BacklogSpecFiles -Task $TaskId -Directory (Join-Path $backlogDir ($dir + "/archived")) | Select-Object -First 1
        if ($null -ne $archivedMatch) {
            $result.SpecExistsInArchived = $true
            $result.SpecPathInArchived = $archivedMatch.FullName
        }
    }

    # Item 227: match only the complete ID cell, not prefix IDs or other columns.
    # 2. Parse BACKLOG.md to find status of TaskId (ignoring Priority Summary table rows)
    $lines = [System.IO.File]::ReadAllLines((Resolve-FilesystemPath -Path $backlogPath), [System.Text.Encoding]::UTF8)
    $taskRowIndex = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if (Test-BacklogTaskRow -Line $lines[$i] -TaskId $TaskId) {
            $taskRowIndex = $i
            break
        }
    }

    if ($taskRowIndex -lt 0) {
        $result.Error = "TaskId $TaskId not found in BACKLOG.md item tables."
        return [pscustomobject]$result
    }

    # Locate Status column index using table header helper
    $statusColIndex = Get-MarkdownTableStatusColumn -Lines ([string[]]$lines) -RowIndex $taskRowIndex
    if ($statusColIndex -ge 0) {
        $cells = @($lines[$taskRowIndex].Trim().Trim("|").Split("|") | ForEach-Object { $_.Trim() })
        if ($cells.Count -gt $statusColIndex) {
            $result.BacklogStatus = $cells[$statusColIndex]
        }
    }

    if ([string]::IsNullOrEmpty($result.BacklogStatus)) {
        $result.Error = "Unable to determine Status for task $TaskId in BACKLOG.md"
        return [pscustomobject]$result
    }

    # 3. Check frontmatter status matches and status is terminal
    $isTerminalStatus = ($result.BacklogStatus -ieq "Production" -or $result.BacklogStatus -ieq "Resolved")

    $specToRead = if ($result.SpecExistsInArchived) { $result.SpecPathInArchived } else { $result.SpecPathInActive }
    $specStatus = ""
    if (-not [string]::IsNullOrEmpty($specToRead) -and (Test-Path -LiteralPath $specToRead)) {
        $fmStr = [string](Get-Content -LiteralPath $specToRead -Head 15 -Encoding UTF8)
        if ($fmStr -match 'status:\s*["'']?([^"''\s\r\n]+)"?') {
            $specStatus = $matches[1]
        }
    }

    $result.SpecStatusMatches = ($specStatus -ieq $result.BacklogStatus)
    $result.IsFinalized = ($isTerminalStatus -and $result.SpecExistsInArchived -and -not $result.SpecExistsInActive -and $result.SpecStatusMatches)

    return [pscustomobject]$result
}

function Invoke-HumanGateBacklogFinalization {
    # TODO item 197: archival owns finalization; the gate
    # decides whether a failure stops the push, event logging and session exit.
    param(
        [Parameter(Mandatory=$true)][string]$TaskId,
        [Parameter(Mandatory=$true)][string]$ProjectRoot,
        [Parameter(Mandatory=$true)][string]$BacklogPath,
        [Parameter(Mandatory=$true)][bool]$HasTaskBranch,
        [string]$SourcePhase = "deployment"
    )

    $finalizationOk = $true
    if (-not (Test-Path -LiteralPath $backlogPath)) {
        # A missing backlog cannot show the task was finalized; fail closed. Item 287, I11.
        Write-Host "[D44] ERROR: BACKLOG.md is missing at $backlogPath, so $TaskId cannot be finalized. Restore BACKLOG.md with an exact row for $TaskId, then re-run the gate with -GateOutcome accepted." -ForegroundColor Red
        $finalizationOk = $false
    } else {
        $backlogContent = Get-Content -LiteralPath $backlogPath -Raw -Encoding UTF8
        $hasExactRow = @($backlogContent -split "`r?`n" | Where-Object { Test-BacklogTaskRow -Line $_ -TaskId $TaskId }).Count -gt 0
        if (-not $hasExactRow) {
            # Fail closed like the deployment-to-done gate: an ID only in prose or as a prefix of
            # another row cannot show the task was finalized. Item 285, I8.
            Write-Host ("[D44] ERROR: BACKLOG.md has no exact row for $TaskId. A row must start with | $TaskId | or | [$TaskId](spec path) |. Repair the row in BACKLOG.md, then re-run the gate with -GateOutcome accepted.") -ForegroundColor Red
            $finalizationOk = $false
        } else {
            $finalization = Get-TaskFinalizationDetails -TaskId $TaskId -ProjectRoot $ProjectRoot
            if (-not $finalization.IsFinalized) {
                # The expected path, not a recovery: the deployment prompt forbids the Operator
                # from finalizing, so the gate is the only finalizer (TODO item 132).
                Write-Host "`n[D44] Finalizing task $TaskId at the human gate: archiving its spec and updating BACKLOG.md." -ForegroundColor Cyan

                # Locate active spec
                $activeSpecPath = Get-BacklogItemPathForTaskProjectRoot -Task $TaskId -ProjectRoot $ProjectRoot
                if ([string]::IsNullOrEmpty($activeSpecPath) -or -not (Test-Path -LiteralPath $activeSpecPath)) {
                    Write-Host "[D44] ERROR: Active spec path not found for task $TaskId. Auto-finalization failed." -ForegroundColor Red
                    $finalizationOk = $false
                } elseif ($activeSpecPath -match '(?i)[/\\]archived[/\\]') {
                    Write-Host "[D44] INFO: Task spec for $TaskId is already archived at $activeSpecPath." -ForegroundColor Green
                } else {
                    # Load archive-task helper
                    $archiveLibPath = Join-Path $PSScriptRoot "archive-task.ps1"
                    if (-not (Get-Command "Invoke-BacklogTaskArchive" -ErrorAction SilentlyContinue)) {
                        if (Test-Path -LiteralPath $archiveLibPath) {
                            . $archiveLibPath
                        } else {
                            throw "archive-task helper not found at $archiveLibPath"
                        }
                    }

                    # Perform archival
                    try {
                        $archiveParams = @{
                            BacklogPath = $backlogPath
                            SpecPath = $activeSpecPath
                        }
                        if ($SourcePhase -eq "grooming") {
                            $archiveParams["Status"] = "Resolved"
                        } else {
                            # No branch means nothing was built, so the task is closed without
                            # a deploy. A branch means the gate merged it before calling this.
                            $archiveParams["ShippedCode"] = $hasTaskBranch
                        }
                        $archiveResult = Invoke-BacklogTaskArchive @archiveParams
                        Write-Host ("[D44] SUCCESS: Auto-archived task as {0} (status {1}): {2}" -f $archiveResult.Type, $archiveResult.Status, $archiveResult.ArchivedRelPath) -ForegroundColor Green
                    } catch {
                        Write-Host ("[D44] ERROR: Archival failed for task $TaskId. Error: " + $_.Exception.Message) -ForegroundColor Red
                        $finalizationOk = $false
                    }

                    # Re-verify after archiving
                    if ($finalizationOk) {
                        $reverify = Get-TaskFinalizationDetails -TaskId $TaskId -ProjectRoot $ProjectRoot
                        if (-not $reverify.IsFinalized) {
                            Write-Host "[D44] ERROR: Task $TaskId is still not finalized after archival attempt. Details: $($reverify | ConvertTo-Json -Compress)" -ForegroundColor Red
                            $finalizationOk = $false
                        }
                    }
                }
            }
        }
    }

    if (-not $finalizationOk) {
        Write-Host "[D44] STOP: Auto-finalization failed for $TaskId; refusing to push. The merge remains LOCAL only. Run archive-task.ps1 for $TaskId, then re-run the gate with -GateOutcome accepted." -ForegroundColor Red
    }
    return $finalizationOk
}

function Invoke-AbandonedBacklogTaskArchive {
    # TODO item 197: keep active archival and legacy status repair in their backlog libraries.
    param(
        [Parameter(Mandatory=$true)][string]$TaskId,
        [Parameter(Mandatory=$true)][string]$ProjectRoot
    )

    # Archive the abandoned task as Abandoned
    $backlogDir = Get-ConfiguredPath -Key "backlog" -ProjectRoot $ProjectRoot
    $backlogPath = Join-Path $backlogDir "BACKLOG.md"
    if (Test-Path -LiteralPath $backlogPath) {
        $activeSpecPath = Get-BacklogItemPathForTaskProjectRoot -Task $TaskId -ProjectRoot $ProjectRoot
        if (-not [string]::IsNullOrEmpty($activeSpecPath) -and (Test-Path -LiteralPath $activeSpecPath) -and ($activeSpecPath -match '(?i)[/\\]active[/\\]')) {
            $archiveLibPath = Join-Path $PSScriptRoot "archive-task.ps1"
            if (-not (Get-Command "Invoke-BacklogTaskArchive" -ErrorAction SilentlyContinue)) {
                if (Test-Path -LiteralPath $archiveLibPath) { . $archiveLibPath }
            }
            if (Get-Command "Invoke-BacklogTaskArchive" -ErrorAction SilentlyContinue) {
                try {
                    $archiveResult = Invoke-BacklogTaskArchive -BacklogPath $backlogPath -SpecPath $activeSpecPath -Status "Abandoned"
                    Write-Host ("[D57] SUCCESS: Auto-archived abandoned task as $($archiveResult.Type) (status Abandoned): $($archiveResult.ArchivedRelPath)") -ForegroundColor Green
                } catch {
                    Write-Host ("[D57] WARNING: Failed to archive abandoned task: " + $_.Exception.Message) -ForegroundColor Yellow
                }
            }
        } else {
            Set-ArchivedBacklogTaskAbandoned -TaskId $TaskId -BacklogDir $backlogDir -BacklogPath $backlogPath
        }
    }
}
