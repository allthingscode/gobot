# Validates BACKLOG.md consistency with actual backlog files
# Check 1: Counts and item IDs match Priority Summary table
# Check 2 (Orphaned Files): Catch when a .md file exists in active directories but has no entry in BACKLOG.md
# Check 3 (Broken Links): Catch when BACKLOG.md has a table entry pointing to a missing file
# Check 4 (Archived Status): Repair stale archived frontmatter when BACKLOG.md is already terminal;
#                            otherwise catch archived files with incorrect or missing frontmatter status
# Check 5 (Stub Convention): Catch Pattern C drift — BACKLOG.md Status='Stub' rows whose spec
#                            frontmatter doesn't say status='Stub' (mislabeled stub), and active specs
#                            with status='Stub' that aren't listed as Stub in BACKLOG.md (orphan stub).
# Returns exit code 0 if consistent, non-zero if inconsistencies found

param(
    [switch]$FixSummary,
    [string]$BacklogPath = "",
    [switch]$Quiet,
    [string]$ProjectRoot = ""
)

$ErrorActionPreference = "Stop"
$errors = @()

function Write-Quiet {
    param(
        [Parameter(Mandatory=$true)][string]$Message,
        [string]$ForegroundColor = "White"
    )
    if (-not $Quiet) {
        Write-Host $Message -ForegroundColor $ForegroundColor
    }
}

function Normalize-ItemList {
    param([string]$Raw)
    if (-not $Raw) { return @() }
    $trimmed = $Raw.Trim()
    if ($trimmed -eq "-" -or $trimmed -eq "") { return @() }
    return @($trimmed -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" } | Sort-Object -Unique)
}

# Dot-source config helpers
$helpersPath = Join-Path $PSScriptRoot "lib/config-helpers.ps1"
if (-not (Test-Path -LiteralPath $helpersPath)) {
    throw "Required helper script not found at $helpersPath; your Crucible bundle is incomplete. Please see docs/updating.md to sync your bundle from the source repository."
}
. $helpersPath
$archiveHelpersPath = Join-Path $PSScriptRoot "lib/archive-task.ps1"
if (-not (Test-Path -LiteralPath $archiveHelpersPath)) {
    throw "Required helper script not found at $archiveHelpersPath; your Crucible bundle is incomplete. Please see docs/updating.md to sync your bundle from the source repository."
}
. $archiveHelpersPath

if ([string]::IsNullOrWhiteSpace($BacklogPath)) {
    $backlogDir = Get-ConfiguredPath -Key "backlog" -ProjectRoot $ProjectRoot
    $BacklogPath = Join-Path $backlogDir "BACKLOG.md"
} else {
    $backlogDir = Split-Path -Parent $BacklogPath
}

if (Test-Path $backlogDir) {
    $backlogDir = (Resolve-Path $backlogDir).Path
}
if (Test-Path $BacklogPath) {
    $BacklogPath = (Resolve-Path $BacklogPath).Path
}

try {
    Write-Quiet "=== BACKLOG VALIDATION START ==="
    Write-Quiet "Backlog Path: $BacklogPath"

    # Parse BACKLOG.md
    if (-not (Test-Path -LiteralPath $BacklogPath)) { throw "Backlog file not found at $BacklogPath" }
    $content = Get-Content -LiteralPath $BacklogPath -Encoding UTF8
    if (-not $content) { throw "Backlog file content is null" }
    $contentArray = [string[]]$content

    # Check for mojibake markers (D43)
    $markers = @(
        ([string]([char]0x00C3)),                                              # mojibake capital A-tilde
        ([string]([char]0x00C2)),                                              # mojibake capital A-circumflex
        ([string]::Concat([char]0x00E2, [char]0x2020, [char]0x2019)),          # mojibake capital A-circumflex?'
        ([string]::Concat([char]0x00E2, [char]0x20AC, [char]0x201D)),          # mojibake capital A-circumflex?"
        ([string]::Concat([char]0x00E2, [char]0x20AC, [char]0x201C)),          # mojibake capital A-circumflex?"
        ([string]::Concat([char]0x00E2, [char]0x20AC, [char]0x0153)),          # mojibake capital A-circumflex??
        ([string]::Concat([char]0x00E2, [char]0x20AC, [char]0x2122))           # mojibake capital A-circumflex??
    )
    $mojibakeHits = @()
    for ($i = 0; $i -lt $contentArray.Count; $i++) {
        $line = $contentArray[$i]
        foreach ($marker in $markers) {
            if ($line.Contains($marker)) {
                $lineNumber = $i + 1
                $mojibakeHits += "Line ${lineNumber}: '$($line.Trim())' (contains marker '$marker')"
                break
            }
        }
    }
    if ($mojibakeHits.Count -gt 0) {
        $errors += "Mojibake detected in BACKLOG.md:`n  " + ($mojibakeHits -join "`n  ")
    }

    $archivedBacklogStatuses = @{}
    for ($i = 0; $i -lt $contentArray.Count; $i++) {
        if ($contentArray[$i] -notmatch '^\s*\|') { continue }
        $statusColumn = Get-MarkdownTableStatusColumn -Lines $contentArray -RowIndex $i
        if ($statusColumn -lt 0) { continue }
        $linkMatches = [regex]::Matches($contentArray[$i], '\]\(((features|bugs|chores)/archived/[^)]+\.md)\)')
        if ($linkMatches.Count -eq 0) { continue }

        $cells = @($contentArray[$i].Trim().Trim("|").Split("|") | ForEach-Object { $_.Trim() })
        if ($statusColumn -ge $cells.Count) { continue }
        $rowStatus = $cells[$statusColumn]
        foreach ($m in $linkMatches) {
            $archivedBacklogStatuses[$m.Groups[1].Value] = $rowStatus
        }
    }

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

    Write-Quiet "Initialized simple variables"

    # Scan active directories to get actual counts
    $activeDirs = @(
        @{ Path = Join-Path $backlogDir "features/active"; Type = "features" },
        @{ Path = Join-Path $backlogDir "bugs/active"; Type = "bugs" },
        @{ Path = Join-Path $backlogDir "chores/active"; Type = "chores" }
    )

    foreach ($dirInfo in $activeDirs) {
        $dir = $dirInfo.Path
        $type = $dirInfo.Type
        Write-Quiet "Scanning $type directory ($dir)..."
        if (Test-Path $dir) {
            $files = @(Get-ChildItem -Path $dir -Filter "*.md")
            if ($files) {
                Write-Quiet "Found $($files.Count) $type files"
                foreach ($file in $files) {
                    try {
                        $frontmatter = Get-Content -Path $file.FullName -Head 10
                        if ($frontmatter) {
                            $frontmatterStr = [string]$frontmatter
                            $priority = "P2" # default
                            if ($frontmatterStr -match 'priority:\s*"?([P][0123])"?') {
                                $priority = $matches[1]
                            }

                            $itemId = $null
                            if ($frontmatterStr -match 'item_id:\s*"?([^"\s\r\n]+)"?') {
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
                                $relPath = $file.FullName -replace [regex]::Escape($backlogDir + [System.IO.Path]::DirectorySeparatorChar), ''
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
    # Scan the entire document for markdown links into the backlog tree. This is layout-agnostic
    # so it works with both the unified `## Active Items` table (the scaffolded template) and the
    # legacy per-type `## **Features**` / `## **Bugs**` / `## **Chores**` sections. HTML comments
    # are skipped so template/example links inside `<!-- ... -->` do not produce false positives.
    Write-Quiet "Scanning BACKLOG.md for broken links..."
    $reportedLinks = @{}
    foreach ($line in $content) {
        if ($line -match '^\s*<!--') { continue }
        $linkMatches = [regex]::Matches($line, '\]\(([^)]+\.md)\)')
        foreach ($m in $linkMatches) {
            $link = $m.Groups[1].Value
            if ($link -notmatch '^(features|bugs|chores)/') { continue }
            if ($reportedLinks.ContainsKey($link)) { continue }
            $targetPath = Join-Path $backlogDir ($link -replace '/', [System.IO.Path]::DirectorySeparatorChar)
            if (-not (Test-Path -LiteralPath $targetPath)) {
                $errors += "Broken link: BACKLOG.md references $link but file does not exist"
                $reportedLinks[$link] = $true
            }
        }
    }

    # Check C: Archived Files Status Validation
    Write-Quiet "Validating archived files have correct frontmatter status..."
    $archivedDirs = @(
        (Join-Path $backlogDir "features/archived"),
        (Join-Path $backlogDir "bugs/archived"),
        (Join-Path $backlogDir "chores/archived")
    )
    foreach ($dir in $archivedDirs) {
        if (Test-Path $dir) {
            $archivedFiles = Get-ChildItem -Path $dir -Filter "*.md"
            foreach ($file in $archivedFiles) {
                $frontmatter = Get-Content -Path $file.FullName -Head 20
                $frontmatterStr = [string]$frontmatter
                $relPath = $file.FullName -replace [regex]::Escape($backlogDir + [System.IO.Path]::DirectorySeparatorChar), ''
                $relPath = $relPath -replace '\\', '/'
                if ($frontmatter -and $frontmatterStr -match 'status:\s*"?([^"\r\n]+)"?') {
                    $status = $matches[1].Trim()
                    if ($status -eq "Production" -or $status -eq "Resolved" -or $status -eq "Abandoned") {
                        continue
                    }

                    $backlogStatus = $null
                    if ($archivedBacklogStatuses.ContainsKey($relPath)) {
                        $backlogStatus = [string]$archivedBacklogStatuses[$relPath]
                    }
                    if ($backlogStatus -eq "Production" -or $backlogStatus -eq "Resolved" -or $backlogStatus -eq "Abandoned") {
                        Set-BacklogSpecFrontmatterStatus -Path $file.FullName -Status $backlogStatus
                        Write-Quiet "Repaired archived spec status: $relPath frontmatter '$status' -> '$backlogStatus'" "Yellow"
                        continue
                    }

                    $errors += "Archived file has incorrect status: $relPath has status '$status' (expected 'Production', 'Resolved', or 'Abandoned')"
                } else {
                    $errors += "Archived file has missing status frontmatter: $relPath"
                }
            }
        }
    }

    # Check D: Pattern C stub-row convention
    # Enforces the rule documented in sops/reviewer.md (Pattern C Checklist):
    #   "Every new stub row has: item_id, title, type, priority, status: Stub,
    #    and a link to its spec file. Every stub row in BACKLOG.md has a
    #    corresponding spec file in backlog/{type}/active/."
    # This check catches two specific drifts that the broken-links scan alone misses:
    #   (a) BACKLOG.md row says Status=Stub but the spec frontmatter says something else (mislabeled stub)
    #   (b) Spec frontmatter says status=Stub but BACKLOG.md row doesn't say Status=Stub (orphan stub spec)
    # The third drift — BACKLOG.md row says Status=Stub but the spec file doesn't exist — is already caught
    # by Check B (Broken Links), so we just skip those rows here to avoid duplicate errors.
    Write-Quiet "Validating Pattern C stub-row convention..."

    # Locate the ## Active Items section, then find its header row to discover the Status column index.
    $activeItemsIdx = -1
    for ($i = 0; $i -lt $content.Count; $i++) {
        if ($content[$i] -match '^##\s+Active Items\b') { $activeItemsIdx = $i; break }
    }

    $stubLinksFromBacklog = @{}
    if ($activeItemsIdx -ge 0) {
        $headerIdx = -1
        for ($i = $activeItemsIdx + 1; $i -lt $content.Count; $i++) {
            $line = $content[$i]
            if ($line -match '^##\s') { break }
            if ($line -match '^\s*\|') { $headerIdx = $i; break }
        }

        if ($headerIdx -ge 0) {
            $headerCells = @(($content[$headerIdx] -split '\|') | ForEach-Object { $_.Trim() })
            $statusIdx = -1
            for ($c = 0; $c -lt $headerCells.Count; $c++) {
                if ($headerCells[$c] -ieq 'Status') { $statusIdx = $c; break }
            }

            if ($statusIdx -ge 0) {
                for ($i = $headerIdx + 1; $i -lt $content.Count; $i++) {
                    $line = $content[$i]
                    if ($line -match '^##\s') { break }
                    if ($line -match '^\s*<!--') { continue }
                    if ($line -notmatch '^\s*\|') { continue }
                    if ($line -match '^\s*\|[\s\-:|]+\|\s*$') { continue }

                    $cells = @(($line -split '\|') | ForEach-Object { $_.Trim() })
                    if ($cells.Count -le $statusIdx) { continue }
                    if ($cells[$statusIdx] -ine 'Stub') { continue }
                    if ($line -notmatch '\]\(([^)]+\.md)\)') { continue }

                    $link = $matches[1]
                    if ($link -notmatch '^(features|bugs|chores)/') { continue }
                    $stubLinksFromBacklog[$link] = $true

                    $targetPath = Join-Path $backlogDir ($link -replace '/', [System.IO.Path]::DirectorySeparatorChar)
                    if (-not (Test-Path -LiteralPath $targetPath)) { continue } # already reported by Check B

                    $fmStr = [string](Get-Content -LiteralPath $targetPath -Head 15)
                    $specStatus = $null
                    if ($fmStr -match 'status:\s*"?([^"\s\r\n]+)"?') { $specStatus = $matches[1] }
                    if ($specStatus -ine 'Stub') {
                        $errors += "Stub-row convention: BACKLOG.md row $link has Status='Stub' but spec frontmatter status is '$specStatus' (expected 'Stub')"
                    }
                }
            }
        }
    }

    # Reverse direction: scan active spec files and flag any with status=Stub that aren't listed as Stub in BACKLOG.md.
    foreach ($dirInfo in $activeDirs) {
        $dir = $dirInfo.Path
        if (-not (Test-Path $dir)) { continue }
        foreach ($file in @(Get-ChildItem -Path $dir -Filter "*.md")) {
            $fmStr = [string](Get-Content -LiteralPath $file.FullName -Head 15)
            if ($fmStr -notmatch 'status:\s*"?Stub"?') { continue }
            $relPath = $file.FullName -replace [regex]::Escape($backlogDir + [System.IO.Path]::DirectorySeparatorChar), ''
            $relPath = $relPath -replace '\\', '/'
            if (-not $stubLinksFromBacklog.ContainsKey($relPath)) {
                $errors += "Stub-row convention: spec $relPath has frontmatter status='Stub' but BACKLOG.md does not list it with Status='Stub'"
            }
        }
    }

    # Calculate expected totals
    $expectedP0 = $actualP0_features + $actualP0_bugs + $actualP0_chores
    $expectedP1 = $actualP1_features + $actualP1_bugs + $actualP1_chores
    $expectedP2 = $actualP2_features + $actualP2_bugs + $actualP2_chores
    $expectedP3 = $actualP3_features + $actualP3_bugs + $actualP3_chores

    Write-Quiet "Actual counts - P0: $expectedP0, P1: $expectedP1, P2: $expectedP2, P3: $expectedP3"

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

    Write-Quiet "BACKLOG.md counts - P0: $actualP0, P1: $actualP1, P2: $actualP2, P3: $actualP3"

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
        Write-Quiet "Auto-fixing Priority Summary in BACKLOG.md..."
        
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
        $oldText = ($content -join "`n")
        $newText = ($newContent -join "`n")
        if ($oldText -ne $newText) {
            [System.IO.File]::WriteAllText($BacklogPath, $newText + "`n", (New-Object System.Text.UTF8Encoding $false))
            Write-Quiet "BACKLOG.md updated successfully."
        } else {
            Write-Quiet "BACKLOG.md Priority Summary already current; no changes written."
        }
        $errors = @($errors | Where-Object { $_ -notlike '*count mismatch*' -and $_ -notlike '*items mismatch*' })
    }

    if ($errors.Count -gt 0) {
        Write-Host "BACKLOG VALIDATION FAILED:"
        $errors | ForEach-Object { Write-Host "  - $_" }
        exit 2
    } else {
        Write-Quiet "BACKLOG VALIDATION PASSED - All counts are consistent"
        exit 0
    }
} catch {
    Write-Host "BACKLOG VALIDATION ERROR: $_"
    exit 2
}
