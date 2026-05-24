# Validates BACKLOG.md consistency with actual backlog files
# Check 1: Counts and item IDs match Priority Summary table
# Check 2 (Orphaned Files): Catch when a .md file exists in active directories but has no entry in BACKLOG.md
# Check 3 (Broken Links): Catch when BACKLOG.md has a table entry pointing to a missing file
# Check 4 (Archived Status): Catch when archived files have incorrect frontmatter status (not "Production" or "Resolved")
# Returns exit code 0 if consistent, non-zero if inconsistencies found

param(
    [switch]$FixSummary,
    [string]$BacklogPath = ".crucible\\backlog\BACKLOG.md"
)

$ErrorActionPreference = "Stop"
$errors = @()

function Normalize-ItemList {
    param([string]$Raw)
    if (-not $Raw) { return @() }
    $trimmed = $Raw.Trim()
    if ($trimmed -eq "-" -or $trimmed -eq "") { return @() }
    return @($trimmed -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" } | Sort-Object -Unique)
}

try {
    Write-Host "=== BACKLOG VALIDATION START ==="
    Write-Host "Backlog Path: $BacklogPath"

    # Parse BACKLOG.md
    if (-not (Test-Path $BacklogPath)) { throw "Backlog file not found at $BacklogPath" }
    $content = Get-Content -Path $BacklogPath
    if (-not $content) { throw "Backlog file content is null" }

    # Initialize actual counts using simple variables
    $actualP0_features = 0
    $actualP0_bugs = 0
    $actualP0_chores = 0
    $actualP1_features = 0
    $actualP1_bugs = 0
    $actualP1_chores = 0
    $actualP2_features = 0
    $actualP2_bugs = 0
    $actualP2_chores = 0
    $actualP3_features = 0
    $actualP3_bugs = 0
    $actualP3_chores = 0

    $activeItems = @()
    $priorityItems = @{
        "P0" = @()
        "P1" = @()
        "P2" = @()
        "P3" = @()
    }

    Write-Host "Initialized simple variables"

    # Scan active directories to get actual counts
    $activeDirs = @(
        @{ Path = ".crucible\\backlog\features\active"; Type = "features" },
        @{ Path = ".crucible\\backlog\bugs\active"; Type = "bugs" },
        @{ Path = ".crucible\\backlog\chores\active"; Type = "chores" }
    )

    foreach ($dirInfo in $activeDirs) {
        $dir = $dirInfo.Path
        $type = $dirInfo.Type
        Write-Host "Scanning $type directory ($dir)..."
        if (Test-Path $dir) {
            $files = @(Get-ChildItem -Path $dir -Filter "*.md")
            if ($files) {
                Write-Host "Found $($files.Count) $type files"
                foreach ($file in $files) {
                    try {
                        $frontmatter = Get-Content -Path $file.FullName -Head 10
                        if ($frontmatter) {
                            $frontmatterStr = [string]$frontmatter
                            $priority = "P2" # default
                            if ($frontmatterStr -match 'priority[:]\s*"?([P][0123])"?') {
                                $priority = $matches[1]
                            }

                            $itemId = $null
                            if ($frontmatterStr -match 'item_id[:]\s*"?([^"\s\r\n]+)"?') {
                                $itemId = $matches[1]
                            } else {
                                $errors += "Missing or invalid item_id in frontmatter of active file: $($file.Name)"
                                continue
                            }

                            # Assert that filename ID matches item_id
                            $filenameId = ($file.Name -replace '_.*$', '') -replace '\.md$', ''
                            if ($itemId -ne $filenameId) {
                                $errors += "Filename ID mismatch: file '$($file.Name)' prefix '$filenameId' does not match frontmatter item_id '$itemId'"
                            }

                            if ($priority -eq "P0") {
                                if ($type -eq "features") { $actualP0_features++ }
                                elseif ($type -eq "bugs") { $actualP0_bugs++ }
                                elseif ($type -eq "chores") { $actualP0_chores++ }
                            }
                            elseif ($priority -eq "P1") {
                                if ($type -eq "features") { $actualP1_features++ }
                                elseif ($type -eq "bugs") { $actualP1_bugs++ }
                                elseif ($type -eq "chores") { $actualP1_chores++ }
                            }
                            elseif ($priority -eq "P2") {
                                if ($type -eq "features") { $actualP2_features++ }
                                elseif ($type -eq "bugs") { $actualP2_bugs++ }
                                elseif ($type -eq "chores") { $actualP2_chores++ }
                            }
                            elseif ($priority -eq "P3") {
                                if ($type -eq "features") { $actualP3_features++ }
                                elseif ($type -eq "bugs") { $actualP3_bugs++ }
                                elseif ($type -eq "chores") { $actualP3_chores++ }
                            }

                            # Check A: Orphaned Files
                            $activeItems += $itemId
                            $priorityItems[$priority] += $itemId
                            $matchFound = $false
                            foreach ($cLine in $content) {
                                if ($cLine -match "\b$itemId\b") {
                                    $matchFound = $true
                                    break
                                }
                            }
                            if (-not $matchFound) {
                                $relPath = $file.FullName -replace '.*\.crucible\\\backlog\\', ''
                                $relPath = $relPath -replace '\\', '/'
                                $errors += "Orphaned file: $relPath has no entry in BACKLOG.md"
                            }
                        }
                    } catch {
                        Write-Host ("    ERROR processing file {0}: {1}" -f $file.Name, $_)
                        throw
                    }
                }
            }
        }
    }

    # Check B: Broken Links
    Write-Host "Scanning BACKLOG.md for broken links..."
    $inTable = $false
    foreach ($line in $content) {
        if ($line -match '^## \*\*(Features|Bugs|Chores)\*\*') {
            $inTable = $true
            continue
        }
        if ($inTable -and $line -match '^---') {
            $inTable = $false
            continue
        }
        if ($inTable -and $line -match '^## ') {
            $inTable = $false
            continue
        }
        
        if ($inTable -and $line -match '^\s*\|') {
            if ($line -match '\|\s*-+\s*\|') { continue }
            if ($line -match '\|\s*ID\s*\|\s*Title\s*\|') { continue }
            
            if ($line -match '\]\(([^)]+\.md)\)') {
                $link = $matches[1]
                $targetPath = Join-Path ".crucible\\backlog" $link.Replace('/', '\')
                if (-not (Test-Path $targetPath)) {
                    $errors += "Broken link: BACKLOG.md references $link but file does not exist"
                }
            }
        }
    }

    # Check C: Archived Files Status Validation
    Write-Host "Validating archived files have correct frontmatter status..."
    $archivedDirs = @(
        ".crucible\\backlog\features\archived",
        ".crucible\\backlog\bugs\archived",
        ".crucible\\backlog\chores\archived"
    )
    foreach ($dir in $archivedDirs) {
        if (Test-Path $dir) {
            $archivedFiles = Get-ChildItem -Path $dir -Filter "*.md"
            foreach ($file in $archivedFiles) {
                $frontmatter = Get-Content -Path $file.FullName -Head 10
                $frontmatterStr = [string]$frontmatter
                if ($frontmatter -and $frontmatterStr -match 'status[:]\s*"?([^"\s\r\n]+)"?') {
                    $status = $matches[1]
                    if ($status -ne "Production" -and $status -ne "Resolved" -and $status -ne "Abandoned") {
                        $relPath = $file.FullName -replace '.*\.crucible\\\backlog\\', ''
                        $relPath = $relPath -replace '\\', '/'
                        $errors += "Archived file has incorrect status: $relPath has status '$status' (expected 'Production' or 'Resolved')"
                    }
                }
            }
        }
    }

    # Calculate expected totals
    $expectedP0 = $actualP0_features + $actualP0_bugs + $actualP0_chores
    $expectedP1 = $actualP1_features + $actualP1_bugs + $actualP1_chores
    $expectedP2 = $actualP2_features + $actualP2_bugs + $actualP2_chores
    $expectedP3 = $actualP3_features + $actualP3_bugs + $actualP3_chores

    Write-Host "Actual counts - P0: $expectedP0, P1: $expectedP1, P2: $expectedP2, P3: $expectedP3"

    # Extract Priority Summary counts from BACKLOG.md (only within the Priority Summary section)
    $priorityLines = @()
    $inPriority = $false
    foreach ($line in $content) {
        if ($line -match '^##\s*Priority Summary') {
            $inPriority = $true
            continue
        }
        if ($inPriority) {
            if ($line -match '^#+\s') { break }
            if ($line -match '\|\s*\*\*P[0-3]\*\*\s*\|') {
                $priorityLines += $line
            }
        }
    }

    $actualP0 = 0
    $actualP1 = 0
    $actualP2 = 0
    $actualP3 = 0
    $summaryItems = @{
        "P0" = @()
        "P1" = @()
        "P2" = @()
        "P3" = @()
    }
    $val = 0

    foreach ($line in $priorityLines) {
        if (-not $line) { continue }
        if ($line -like '*| **P0** |*') {
            $parts = $line -split '\|'
            if ($parts -and $parts.Length -ge 4) {
                $countStr = $parts[2].Trim()
                if ($countStr -and [int]::TryParse($countStr, [ref]$val)) {
                    $actualP0 = $val
                }
                $summaryItems["P0"] = Normalize-ItemList $parts[3]
            }
        }
        elseif ($line -like '*| **P1** |*') {
            $parts = $line -split '\|'
            if ($parts -and $parts.Length -ge 4) {
                $countStr = $parts[2].Trim()
                if ($countStr -and [int]::TryParse($countStr, [ref]$val)) {
                    $actualP1 = $val
                }
                $summaryItems["P1"] = Normalize-ItemList $parts[3]
            }
        }
        elseif ($line -like '*| **P2** |*') {
            $parts = $line -split '\|'
            if ($parts -and $parts.Length -ge 4) {
                $countStr = $parts[2].Trim()
                if ($countStr -and [int]::TryParse($countStr, [ref]$val)) {
                    $actualP2 = $val
                }
                $summaryItems["P2"] = Normalize-ItemList $parts[3]
            }
        }
        elseif ($line -like '*| **P3** |*') {
            $parts = $line -split '\|'
            if ($parts -and $parts.Length -ge 4) {
                $countStr = $parts[2].Trim()
                if ($countStr -and [int]::TryParse($countStr, [ref]$val)) {
                    $actualP3 = $val
                }
                $summaryItems["P3"] = Normalize-ItemList $parts[3]
            }
        }
    }

    Write-Host "BACKLOG.md counts - P0: $actualP0, P1: $actualP1, P2: $actualP2, P3: $actualP3"

    # Validate Priority Summary counts
    $needsFix = $false
    if ($actualP0 -ne $expectedP0) {
        $errors += "P0 count mismatch: BACKLOG.md says $($actualP0), actual count is $($expectedP0)"
        $needsFix = $true
    }
    if ($actualP1 -ne $expectedP1) {
        $errors += "P1 count mismatch: BACKLOG.md says $($actualP1), actual count is $($expectedP1)"
        $needsFix = $true
    }
    if ($actualP2 -ne $expectedP2) {
        $errors += "P2 count mismatch: BACKLOG.md says $($actualP2), actual count is $($expectedP2)"
        $needsFix = $true
    }
    if ($actualP3 -ne $expectedP3) {
        $errors += "P3 count mismatch: BACKLOG.md says $($actualP3), actual count is $($expectedP3)"
        $needsFix = $true
    }

    foreach ($priority in @("P0","P1","P2","P3")) {
        $expectedItems = @($priorityItems[$priority] | Sort-Object -Unique)
        $actualItems = @($summaryItems[$priority])
        $expectedJoined = if ($expectedItems.Count -gt 0) { $expectedItems -join ", " } else { "-" }
        $actualJoined = if ($actualItems.Count -gt 0) { $actualItems -join ", " } else { "-" }
        if ($expectedJoined -ne $actualJoined) {
            $errors += "$priority items mismatch: BACKLOG.md says '$actualJoined', actual active items are '$expectedJoined'"
            $needsFix = $true
        }
    }

    if ($needsFix -and $FixSummary) {
        Write-Host "Auto-fixing Priority Summary in BACKLOG.md..."
        
        $newContent = @()
        foreach ($line in $content) {
            if ($line -match '^\s*\|\s*\*\*P0\*\*\s*\|') {
                $p0Items = @($priorityItems["P0"] | Sort-Object -Unique)
                $p0Text = if ($p0Items.Count -gt 0) { $p0Items -join ", " } else { "-" }
                $newContent += "| **P0** | $expectedP0 | $p0Text |"
            }
            elseif ($line -match '^\s*\|\s*\*\*P1\*\*\s*\|') {
                $p1Items = @($priorityItems["P1"] | Sort-Object -Unique)
                $p1Text = if ($p1Items.Count -gt 0) { $p1Items -join ", " } else { "-" }
                $newContent += "| **P1** | $expectedP1 | $p1Text |"
            }
            elseif ($line -match '^\s*\|\s*\*\*P2\*\*\s*\|') {
                $p2Items = @($priorityItems["P2"] | Sort-Object -Unique)
                $p2Text = if ($p2Items.Count -gt 0) { $p2Items -join ", " } else { "-" }
                $newContent += "| **P2** | $expectedP2 | $p2Text |"
            }
            elseif ($line -match '^\s*\|\s*\*\*P3\*\*\s*\|') {
                $p3Items = @($priorityItems["P3"] | Sort-Object -Unique)
                $p3Text = if ($p3Items.Count -gt 0) { $p3Items -join ", " } else { "-" }
                $newContent += "| **P3** | $expectedP3 | $p3Text |"
            }
            elseif ($line -match '^\*\*Status Overview\*\*:') {
                $total = $expectedP0 + $expectedP1 + $expectedP2 + $expectedP3
                $newContent += "**Status Overview**: $total active items."
            }
            else {
                $newContent += $line
            }
        }
        $newContent | Set-Content -Path $BacklogPath
        Write-Host "BACKLOG.md updated successfully."
        $errors = @($errors | Where-Object { $_ -notlike '*count mismatch*' -and $_ -notlike '*items mismatch*' })
    }

    if ($errors.Count -gt 0) {
        Write-Host "BACKLOG VALIDATION FAILED:"
        $errors | ForEach-Object { Write-Host "  - $_" }
        exit 2
    } else {
        Write-Host "BACKLOG VALIDATION PASSED - All counts are consistent"
        exit 0
    }
} catch {
    Write-Host "BACKLOG VALIDATION ERROR: $_"
    exit 2
}
