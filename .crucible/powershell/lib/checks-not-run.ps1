# I12's one reporting point (docs/policy.md section 8): a pipeline check that did not run is
# recorded here by the step that skipped it, and every receiving surface reads it back from
# here: the Reviewer's prompt, run-isolated-checks.ps1's closing list and the Human Gate menu.
# Each new line is "[<source> v2] <check>: <reason>", with "\" and ":" in the check name escaped so
# the first unescaped ": " ends it. A writer replaces or clears only its own (source, check)
# line, under the task's lock (I5), and publishes the file by rename. Item 258.

. (Join-Path $PSScriptRoot "file-lock.ps1")

$script:ChecksNotRunLegacySource = "isolated checks"

function Get-ChecksNotRunPath {
    param(
        [Parameter(Mandatory = $true)][string]$SessionDir,
        [Parameter(Mandatory = $true)][string]$TaskId
    )
    $path = Join-Path (Join-Path (Join-Path $SessionDir $TaskId) "verification") "checks-not-run.txt"
    # [IO.File] resolves a relative path against the process directory, not the PowerShell location.
    return $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($path)
}

function Read-ChecksNotRunFile {
    # Internal read: callers hold the record lock for the entire operation.
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return @() }
    return @([System.IO.File]::ReadAllLines($Path, [System.Text.UTF8Encoding]::new($false)) |
        ForEach-Object { $_.TrimStart([char]0xFEFF) } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}

function Get-ChecksNotRun {
    param(
        [Parameter(Mandatory = $true)][string]$SessionDir,
        [Parameter(Mandatory = $true)][string]$TaskId
    )
    $path = Get-ChecksNotRunPath -SessionDir $SessionDir -TaskId $TaskId
    if (-not (Test-Path -LiteralPath (Split-Path -Parent $path) -PathType Container)) { return @() }
    # ReadAllLines does not share deletion on Windows. Use the writer's lock so no
    # reader can hold the destination open while a writer renames or removes it.
    return @(Invoke-FileLock -LockPath ($path + ".lock") -ScriptBlock {
        Read-ChecksNotRunFile -Path $path
    })
}

function ConvertTo-ChecksNotRunName {
    param([Parameter(Mandatory = $true)][string]$Check)
    return $Check.Replace("\", "\\").Replace(":", "\:")
}

function Test-ChecksNotRunLineOwned {
    param(
        [Parameter(Mandatory = $true)][string]$Line,
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Check
    )
    # Exact: an escaped name has no unescaped ":", so "lint" never owns "lint\: go".
    if ($Line.StartsWith("[" + $Source + " v2] " + (ConvertTo-ChecksNotRunName -Check $Check) + ": ", [System.StringComparison]::Ordinal)) { return $true }
    # Pre-escaping lines have no provable boundary when more than one ': ' occurs.
    # Only retire a legacy line with a single possible delimiter and a literal name;
    # otherwise preserve its history, even when it resembles a modern escaped name.
    if ($Check.Contains(":") -or $Check.Contains("\") -or $Line.Contains("\")) { return $false }
    if ([regex]::Matches($Line, ': ').Count -ne 1) { return $false }
    if ($Line.StartsWith("[" + $Source + "] " + $Check + ": ", [System.StringComparison]::Ordinal)) { return $true }
    return ($Source -eq $script:ChecksNotRunLegacySource -and
        -not $Line.StartsWith("[", [System.StringComparison]::Ordinal) -and
        $Line.StartsWith($Check + ": ", [System.StringComparison]::Ordinal))
}

function Update-ChecksNotRunRecord {
    # The whole read, change and publish runs under the task's exclusive lock.
    param(
        [Parameter(Mandatory = $true)][string]$SessionDir,
        [Parameter(Mandatory = $true)][string]$TaskId,
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Check,
        [AllowEmptyString()][string]$NewLine = ""
    )
    $path = Get-ChecksNotRunPath -SessionDir $SessionDir -TaskId $TaskId
    $dir = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    Invoke-FileLock -LockPath ($path + ".lock") -TimeoutMessage "[CHECKS NOT RUN] Waiting for the record's lock." -ScriptBlock {
        $current = @(Read-ChecksNotRunFile -Path $path)
        $kept = @($current | Where-Object { -not (Test-ChecksNotRunLineOwned -Line $_ -Source $Source -Check $Check) })
        if (-not [string]::IsNullOrEmpty($NewLine)) { $kept = @($kept + $NewLine) }
        if ($kept.Count -eq $current.Count -and [string]::IsNullOrEmpty($NewLine)) { return }
        if ($kept.Count -eq 0) {
            if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
            return
        }
        $temp = $path + "." + [System.Guid]::NewGuid().ToString("N") + ".tmp"
        try {
            [System.IO.File]::WriteAllText($temp, (($kept -join "`n") + "`n"), [System.Text.UTF8Encoding]::new($false))
            [System.IO.File]::Move($temp, $path, $true)
        } finally {
            if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force }
        }
    }
}

function Write-CheckNotRun {
    param(
        [Parameter(Mandatory = $true)][string]$SessionDir,
        [Parameter(Mandatory = $true)][string]$TaskId,
        [Parameter(Mandatory = $true)][ValidatePattern('^[a-z][a-z ]*[a-z]$')][string]$Source,
        [Parameter(Mandatory = $true)][string]$Check,
        [Parameter(Mandatory = $true)][string]$Reason
    )
    $flatCheck = ($Check -replace '[\r\n]+', ' ').Trim()
    $flatReason = ($Reason -replace '[\r\n]+', ' ').Trim()
    if ([string]::IsNullOrWhiteSpace($flatCheck) -or [string]::IsNullOrWhiteSpace($flatReason)) {
        throw "A check that did not run needs a name and a reason (source '$Source')."
    }
    Update-ChecksNotRunRecord -SessionDir $SessionDir -TaskId $TaskId -Source $Source -Check $flatCheck `
        -NewLine ("[" + $Source + " v2] " + (ConvertTo-ChecksNotRunName -Check $flatCheck) + ": " + $flatReason)
}

function Clear-ChecksNotRun {
    # Call only after the named check has executed; a skip stays recorded until then.
    param(
        [Parameter(Mandatory = $true)][string]$SessionDir,
        [Parameter(Mandatory = $true)][string]$TaskId,
        [Parameter(Mandatory = $true)][ValidatePattern('^[a-z][a-z ]*[a-z]$')][string]$Source,
        [Parameter(Mandatory = $true)][string]$Check
    )
    if (-not (Test-Path -LiteralPath (Get-ChecksNotRunPath -SessionDir $SessionDir -TaskId $TaskId) -PathType Leaf)) { return }
    Update-ChecksNotRunRecord -SessionDir $SessionDir -TaskId $TaskId -Source $Source -Check (($Check -replace '[\r\n]+', ' ').Trim())
}

function Format-ChecksNotRunSection {
    # The Reviewer prompt's copy of the record; empty when every check ran.
    param(
        [Parameter(Mandatory = $true)][string]$SessionDir,
        [Parameter(Mandatory = $true)][string]$TaskId
    )
    $lines = @(Get-ChecksNotRun -SessionDir $SessionDir -TaskId $TaskId)
    if ($lines.Count -eq 0) { return "" }
    return "## Checks Not Run`n`n" +
        "These pipeline checks did not run for this task. They are not passes. List every one under ``### Checks Not Run`` in the review report and in the deployment handoff reason:`n`n" +
        (($lines | ForEach-Object { "- " + $_ }) -join "`n") + "`n`n" +
        "Recorded in " + (Get-ChecksNotRunPath -SessionDir $SessionDir -TaskId $TaskId) + "."
}
