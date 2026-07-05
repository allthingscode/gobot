param(
    [string]$Commit = "",
    [string]$Repo = "",
    [int]$TimeoutMinutes = 20,
    [string]$CrucibleRoot = ""
)

$ErrorActionPreference = "Stop"

function Get-CurrentCommit {
    param([string]$Root)
    $args = @()
    if (-not [string]::IsNullOrWhiteSpace($Root)) {
        $args += @("-C", $Root)
    }
    $sha = & git @args rev-parse HEAD 2>$null
    if ($LASTEXITCODE -ne 0) {
        return ""
    }
    return ([string]$sha).Trim()
}

function Resolve-FullCommitSha {
    param(
        [string]$CommitSha,
        [string]$Root
    )
    if ([string]::IsNullOrWhiteSpace($CommitSha)) {
        return $CommitSha
    }

    $args = @()
    if (-not [string]::IsNullOrWhiteSpace($Root)) {
        $args += @("-C", $Root)
    }
    try {
        $fullSha = & git @args rev-parse --verify ($CommitSha + "^{commit}") 2>$null
    } catch {
        return $CommitSha
    }
    if ($LASTEXITCODE -ne 0) {
        return $CommitSha
    }
    $fullSha = ([string]$fullSha).Trim()
    if ($fullSha -match '^[0-9a-fA-F]{40}$') {
        return $fullSha
    }
    return $CommitSha
}

function Get-OriginGithubSlug {
    param([string]$Root)
    $args = @()
    if (-not [string]::IsNullOrWhiteSpace($Root)) {
        $args += @("-C", $Root)
    }
    $url = & git @args remote get-url origin 2>$null
    if ($LASTEXITCODE -ne 0) {
        return ""
    }
    $remote = ([string]$url).Trim()
    if ($remote -match '^git@github\.com:([^/]+/[^/]+?)(\.git)?$') {
        return $Matches[1]
    }
    if ($remote -match '^https://github\.com/([^/]+/[^/]+?)(\.git)?/?$') {
        return $Matches[1]
    }
    return ""
}

function Invoke-GhJson {
    param([string[]]$Arguments)
    $output = & gh @Arguments 2>&1
    $exitCode = $LASTEXITCODE
    return [pscustomobject]@{
        ExitCode = $exitCode
        Output = ($output -join "`n")
    }
}

function Get-RunList {
    param(
        [string]$CommitSha,
        [string]$RepoSlug
    )
    $args = @("run", "list", "--commit", $CommitSha, "--json", "databaseId,status,conclusion")
    if (-not [string]::IsNullOrWhiteSpace($RepoSlug)) {
        $args += @("-R", $RepoSlug)
    }
    $result = Invoke-GhJson -Arguments $args
    if ($result.ExitCode -ne 0) {
        return $null
    }
    # Return $null ONLY for gh failure above. Normalize parsed runs to a real
    # array and return it via the unary comma so PowerShell does not unroll an
    # empty result to $null on assignment. Cross-platform hazard: pwsh emits
    # nothing for "[]" (assignment yields $null) while Windows PS 5.1 returns
    # "[]" as a single array object; branching on $null -eq $parsed normalizes
    # both to count 0, so the caller correctly reports NO_RUNS (not SKIP/timeout).
    $parsed = $null
    if (-not [string]::IsNullOrWhiteSpace($result.Output)) {
        $parsed = $result.Output | ConvertFrom-Json
    }
    if ($null -eq $parsed) {
        return ,@()
    }
    return ,@($parsed)
}

function Write-FailedJobs {
    param(
        [object[]]$Runs,
        [string]$RepoSlug
    )
    $badConclusions = @("failure", "timed_out", "cancelled")
    foreach ($run in $Runs) {
        if ($badConclusions -notcontains ([string]$run.conclusion)) {
            continue
        }
        $args = @("run", "view", ([string]$run.databaseId), "--json", "jobs")
        if (-not [string]::IsNullOrWhiteSpace($RepoSlug)) {
            $args += @("-R", $RepoSlug)
        }
        $view = Invoke-GhJson -Arguments $args
        if ($view.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($view.Output)) {
            Write-Host ("  run " + $run.databaseId + ": failed job details unavailable")
            continue
        }
        $details = $view.Output | ConvertFrom-Json
        foreach ($job in @($details.jobs)) {
            if ($badConclusions -contains ([string]$job.conclusion)) {
                Write-Host ("  " + $job.name)
            }
        }
    }
}

if (-not (Get-Command "gh" -ErrorAction SilentlyContinue)) {
    Write-Host "[CI WATCH] SKIPPED (gh unavailable)"
    exit 0
}

$auth = & gh auth status 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host "[CI WATCH] SKIPPED (gh unavailable)"
    exit 0
}

if ([string]::IsNullOrWhiteSpace($CrucibleRoot)) {
    $CrucibleRoot = (Get-Location).Path
}
if (Test-Path -LiteralPath $CrucibleRoot) {
    $CrucibleRoot = (Resolve-Path -LiteralPath $CrucibleRoot).Path
}

if ([string]::IsNullOrWhiteSpace($Commit)) {
    $Commit = Get-CurrentCommit -Root $CrucibleRoot
}
# gh run list --commit matches full SHAs only.
$Commit = Resolve-FullCommitSha -CommitSha $Commit -Root $CrucibleRoot
if ([string]::IsNullOrWhiteSpace($Repo)) {
    $Repo = Get-OriginGithubSlug -Root $CrucibleRoot
}

$deadline = (Get-Date).AddMinutes($TimeoutMinutes)
$lastRuns = @()

while ($true) {
    $runs = Get-RunList -CommitSha $Commit -RepoSlug $Repo
    if ($null -eq $runs) {
        Write-Host "[CI WATCH] SKIPPED (gh unavailable)"
        exit 0
    }
    $lastRuns = @($runs)

    if ($lastRuns.Count -eq 0) {
        Write-Host "[CI WATCH] STATUS=NO_RUNS"
        Write-Host ("  commit: " + $Commit)
        exit 3
    }

    $allCompleted = $true
    foreach ($run in $lastRuns) {
        if ([string]$run.status -ne "completed") {
            $allCompleted = $false
        }
    }

    if ($allCompleted) {
        $badConclusions = @("failure", "timed_out", "cancelled")
        $hasRed = $false
        foreach ($run in $lastRuns) {
            if ($badConclusions -contains ([string]$run.conclusion)) {
                $hasRed = $true
            }
        }
        if ($hasRed) {
            Write-Host "[CI WATCH] STATUS=RED"
            Write-Host ("  commit: " + $Commit)
            Write-Host "  failed jobs:"
            Write-FailedJobs -Runs $lastRuns -RepoSlug $Repo
            exit 1
        }

        Write-Host "[CI WATCH] STATUS=GREEN"
        Write-Host ("  commit: " + $Commit)
        exit 0
    }

    if ((Get-Date) -ge $deadline) {
        Write-Host "[CI WATCH] STATUS=PENDING_TIMEOUT"
        Write-Host ("  commit: " + $Commit)
        if (-not [string]::IsNullOrWhiteSpace($Repo)) {
            Write-Host ("  runs: https://github.com/" + $Repo + "/actions")
        }
        exit 2
    }

    Start-Sleep -Seconds 10
}
