function Get-HandoffTextForSecurityScan {
    param($HandoffObj)

    $parts = @()
    foreach ($propertyName in @("reason", "summary", "notes", "suspicious_content")) {
        if ($HandoffObj.PSObject.Properties[$propertyName] -and $null -ne $HandoffObj.$propertyName) {
            $parts += [string]$HandoffObj.$propertyName
        }
    }
    foreach ($propertyName in @("artifacts", "file_affinity", "reviewer_checks_passed")) {
        if ($HandoffObj.PSObject.Properties[$propertyName] -and $null -ne $HandoffObj.$propertyName) {
            $parts += @($HandoffObj.$propertyName | ForEach-Object { [string]$_ })
        }
    }
    return ($parts -join "`n")
}

function Get-HandoffDedupeKey {
    param($HandoffObj)
    if ($null -eq $HandoffObj) { return $null }
    # legacy compat read of pre-rename event log / handoff
    $sourceVal = if ($HandoffObj.PSObject.Properties["source_phase"]) { $HandoffObj.source_phase } else { $HandoffObj.source_specialist }
    # legacy compat read of pre-rename event log / handoff
    $targetVal = if ($HandoffObj.PSObject.Properties["target_phase"]) { $HandoffObj.target_phase } else { $HandoffObj.target_specialist }

    if ([string]::IsNullOrWhiteSpace([string]$HandoffObj.task_id) -or
        [string]::IsNullOrWhiteSpace([string]$sourceVal) -or
        [string]::IsNullOrWhiteSpace([string]$targetVal)) {
        return $null
    }
    $retry = 0
    $strikes = 0
    $rebase = 0
    if ($HandoffObj.PSObject.Properties["handoff_retry_count"] -and $null -ne $HandoffObj.handoff_retry_count) {
        $retry = [int]$HandoffObj.handoff_retry_count
    }
    if ($HandoffObj.PSObject.Properties["review_strike_count"] -and $null -ne $HandoffObj.review_strike_count) {
        $strikes = [int]$HandoffObj.review_strike_count
    }
    if ($HandoffObj.PSObject.Properties["rebase_count"] -and $null -ne $HandoffObj.rebase_count) {
        $rebase = [int]$HandoffObj.rebase_count
    }
    $task = ([string]$HandoffObj.task_id).Trim().ToLowerInvariant()
    $source = ([string]$sourceVal).Trim().ToLowerInvariant()
    $target = ([string]$targetVal).Trim().ToLowerInvariant()
    return ("{0}|{1}|{2}|{3}|{4}|{5}" -f $task, $source, $target, $strikes, $rebase, $retry)
}

function Get-HandoffTimestampFromFileName {
    param([Parameter(Mandatory=$true)][string]$Name)
    if ($Name -match '^[A-Z]-[0-9]+-([0-9]{8}T[0-9]{6}Z)\.json$') {
        try {
            return [datetime]::ParseExact(
                $Matches[1],
                "yyyyMMddTHHmmssZ",
                [System.Globalization.CultureInfo]::InvariantCulture,
                [System.Globalization.DateTimeStyles]::AssumeUniversal
            ).ToUniversalTime()
        } catch {
            return [datetime]::MinValue
        }
    }
    return [datetime]::MinValue
}

function Get-CanonicalWinnerForKey {
    param(
        [Parameter(Mandatory=$true)][string]$TaskId,
        [Parameter(Mandatory=$true)][string]$HandoffDir,
        [Parameter(Mandatory=$true)][string]$Key
    )

    $files = @(Get-ChildItem -Path $HandoffDir -Filter ($TaskId + "-*.json") -ErrorAction SilentlyContinue)
    $active = @()
    foreach ($file in $files) {
        try {
            $obj = Get-Content -Path $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($obj.PSObject.Properties["superseded"] -and $obj.superseded -eq $true) { continue }
            $objKey = Get-HandoffDedupeKey -HandoffObj $obj
            if ($objKey -eq $Key) {
                $active += [PSCustomObject]@{
                    File = $file
                    Obj  = $obj
                    Ts   = Get-HandoffTimestampFromFileName -Name $file.Name
                }
            }
        } catch {
            continue
        }
    }
    if ($active.Count -eq 0) { return $null }
    return @($active | Sort-Object @{ Expression = { $_.Ts }; Descending = $true }, @{ Expression = { $_.File.Name }; Descending = $true })[0]
}

function Mark-DuplicateHandoffsAsSuperseded {
    param(
        [Parameter(Mandatory=$true)][string]$TaskId,
        [Parameter(Mandatory=$true)][string]$HandoffDir
    )

    $taskFiles = @(Get-ChildItem -Path $HandoffDir -Filter ($TaskId + "-*.json") -ErrorAction SilentlyContinue)
    if ($taskFiles.Count -lt 2) { return }

    $records = @()
    foreach ($file in $taskFiles) {
        try {
            $obj = Get-Content -Path $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
            $key = Get-HandoffDedupeKey -HandoffObj $obj
            if (-not [string]::IsNullOrEmpty($key)) {
                $records += [PSCustomObject]@{
                    File = $file
                    Obj  = $obj
                    Key  = $key
                    Ts   = Get-HandoffTimestampFromFileName -Name $file.Name
                }
            }
        } catch {
            Write-Quiet ("[HANDOFF] Warning: Could not parse handoff for dedupe check: " + $file.Name) -ForegroundColor Yellow
        }
    }

    if ($records.Count -lt 2) { return }

    $now = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    $activeRecords = @($records | Where-Object { -not ($_.Obj.PSObject.Properties["superseded"] -and $_.Obj.superseded -eq $true) })
    $groups = $activeRecords | Group-Object -Property Key
    $duplicateCandidateCount = 0
    $supersedeOps = 0
    foreach ($group in $groups) {
        if ($group.Count -le 1) { continue }
        $duplicateCandidateCount += $group.Count
        $sorted = @($group.Group | Sort-Object @{ Expression = { $_.Ts }; Descending = $true }, @{ Expression = { $_.File.Name }; Descending = $true })
        $winner = $sorted[0]
        $winnerFileName = $winner.File.Name

        for ($i = 1; $i -lt $sorted.Count; $i++) {
            $loser = $sorted[$i]
            $canonicalWinner = Get-CanonicalWinnerForKey -TaskId $TaskId -HandoffDir $HandoffDir -Key $group.Name
            if ($null -eq $canonicalWinner) { continue }
            $winnerFileName = $canonicalWinner.File.Name
            if ($loser.File.Name -eq $winnerFileName) { continue }

            try {
                $loserObj = Get-Content -Path $loser.File.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
            } catch {
                continue
            }
            $alreadySuperseded = ($loserObj.PSObject.Properties["superseded"] -and $loserObj.superseded -eq $true -and $loserObj.PSObject.Properties["superseded_by"] -and $loserObj.superseded_by -eq $winnerFileName)
            if ($alreadySuperseded) { continue }

            $loserObj | Add-Member -MemberType NoteProperty -Name superseded -Value $true -Force
            $loserObj | Add-Member -MemberType NoteProperty -Name superseded_by -Value $winnerFileName -Force
            $loserObj | Add-Member -MemberType NoteProperty -Name superseded_at -Value $now -Force
            $loserObj | Add-Member -MemberType NoteProperty -Name superseded_reason -Value "deterministic_duplicate_transition" -Force
            $loserObj | ConvertTo-Json -Depth 12 | Set-Content -Path $loser.File.FullName -Encoding UTF8

            Write-EventLog -Event "degraded" -TaskId $TaskId -Specialist "factory" -Outcome "warned" -Notes ("Superseded duplicate handoff: " + $loser.File.Name + " -> " + $winnerFileName)
            Write-Quiet ("[HANDOFF] Superseded duplicate: " + $loser.File.Name + " -> " + $winnerFileName) -ForegroundColor Yellow
            $supersedeOps++
        }
    }

    if ($duplicateCandidateCount -gt 0) {
        Write-EventLog -Event "degraded" -TaskId $TaskId -Specialist "factory" -Outcome "warned" -Notes ("Duplicate candidates: " + $duplicateCandidateCount + "; supersede operations: " + $supersedeOps)
    }
}
