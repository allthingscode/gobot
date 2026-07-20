param(
    [string]$Commit = "",
    [string]$Repo = "",
    [int]$TimeoutMinutes = 20,
    [string]$CrucibleRoot = "",
    [int]$NoRunsGraceMinutes = 2,
    [int]$QueuedGraceMinutes = 15,
    [int]$PollSeconds = 10
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

$noRunsDeadline = (Get-Date).AddMinutes($NoRunsGraceMinutes)
$queuedDeadline = (Get-Date).AddMinutes($QueuedGraceMinutes)
$sawRuns = $false
$sawStarted = $false
$buildDeadline = $null
$lastRuns = @()

while ($true) {
    $runs = Get-RunList -CommitSha $Commit -RepoSlug $Repo
    if ($null -eq $runs) {
        Write-Host "[CI WATCH] SKIPPED (gh unavailable)"
        exit 0
    }
    $lastRuns = @($runs)

    if ($lastRuns.Count -eq 0) {
        # No workflow run is registered for this commit yet. GitHub Actions can take
        # several seconds after a push to create the run, so an initial absence is
        # PENDING, not a verdict: keep polling until a run registers or the grace
        # window elapses. Concluding NO_RUNS on the first empty poll is the push->poll
        # race that lets a require_green_ci gate finalize before CI even exists.
        if (-not $sawRuns -and (Get-Date) -lt $noRunsDeadline) {
            Start-Sleep -Seconds $PollSeconds
            continue
        }
        Write-Host "[CI WATCH] STATUS=NO_RUNS"
        Write-Host ("  commit: " + $Commit)
        exit 3
    }
    $sawRuns = $true

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

    # A run still in queued/requested/waiting/pending has not been picked up by a
    # runner yet. Do NOT charge that queue time to the build timeout (F1): the
    # TimeoutMinutes budget is for a RUNNING build, not for GitHub's dispatch queue.
    # The build clock starts only once a job actually leaves the queue. If nothing
    # leaves the queue within QueuedGraceMinutes, that is a runner-availability
    # stall, reported distinctly as CI_NOT_STARTED (F2) rather than masqueraded as a
    # slow build (PENDING_TIMEOUT), so the caller can tell an infra outage from a
    # genuinely long run.
    $anyStarted = $false
    foreach ($run in $lastRuns) {
        $runStatus = [string]$run.status
        if ($runStatus -ne "queued" -and $runStatus -ne "requested" -and $runStatus -ne "waiting" -and $runStatus -ne "pending") {
            $anyStarted = $true
        }
    }
    if ($anyStarted -and -not $sawStarted) {
        $sawStarted = $true
        $buildDeadline = (Get-Date).AddMinutes($TimeoutMinutes)
    }

    if (-not $sawStarted) {
        if ((Get-Date) -ge $queuedDeadline) {
            Write-Host "[CI WATCH] STATUS=CI_NOT_STARTED"
            Write-Host ("  commit: " + $Commit)
            Write-Host ("  no CI job left the queue within " + $QueuedGraceMinutes + "m - likely a runner-availability outage, not a slow build.")
            if (-not [string]::IsNullOrWhiteSpace($Repo)) {
                Write-Host ("  runs: https://github.com/" + $Repo + "/actions")
            }
            exit 4
        }
    } elseif ((Get-Date) -ge $buildDeadline) {
        Write-Host "[CI WATCH] STATUS=PENDING_TIMEOUT"
        Write-Host ("  commit: " + $Commit)
        if (-not [string]::IsNullOrWhiteSpace($Repo)) {
            Write-Host ("  runs: https://github.com/" + $Repo + "/actions")
        }
        exit 2
    }

    Start-Sleep -Seconds $PollSeconds
}
