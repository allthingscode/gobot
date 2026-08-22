param(
    [string]$Commit = "",
    [string]$Repo = "",
    [int]$TimeoutMinutes = 20,
    [string]$CrucibleRoot = "",
    [int]$NoRunsGraceMinutes = 2,
    [int]$QueuedGraceMinutes = 15,
    [int]$PollSeconds = 10,
    [string]$RequiredJobs = ""
)

$ErrorActionPreference = "Stop"

function Get-CurrentCommit {
    param([string]$Root)
    $args = @()
    if (-not [string]::IsNullOrWhiteSpace($Root)) {
        $args += @("-C", $Root)
    }
    try {
        $sha = & git @args rev-parse HEAD 2>$null
    } catch {
        return ""
    }
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

function Get-OriginRepoIdentity {
    param([string]$Root)
    $args = @()
    if (-not [string]::IsNullOrWhiteSpace($Root)) {
        $args += @("-C", $Root)
    }
    try {
        $url = & git @args remote get-url origin 2>$null
    } catch {
        return $null
    }
    if ($LASTEXITCODE -ne 0) {
        return $null
    }
    $remote = ([string]$url).Trim()
    if ($remote -match '^https?://(?:[^@/:]+@)?([^/:]+)(?::\d+)?/([^/]+)/([^/]+?)(\.git)?/?$') {
        $owner = $Matches[2]
        $name = $Matches[3]
        return [pscustomobject]@{
            Host  = $Matches[1]
            Owner = $owner
            Name  = $name
            Slug  = "$owner/$name"
        }
    }
    if ($remote -match '^git@([^/:]+):([^/]+)/([^/]+?)(\.git)?/?$') {
        $owner = $Matches[2]
        $name = $Matches[3]
        return [pscustomobject]@{
            Host  = $Matches[1]
            Owner = $owner
            Name  = $name
            Slug  = "$owner/$name"
        }
    }
    if ($remote -match '^ssh://(?:[^@/:]+@)?([^/:]+)(?::\d+)?/([^/]+)/([^/]+?)(\.git)?/?$') {
        $owner = $Matches[2]
        $name = $Matches[3]
        return [pscustomobject]@{
            Host  = $Matches[1]
            Owner = $owner
            Name  = $name
            Slug  = "$owner/$name"
        }
    }
    return $null
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

$script:LastGhError = ""

function Get-RunList {
    param(
        [string]$CommitSha,
        [string]$RepoSlug,
        [string]$HostName = "github.com"
    )
    $script:LastGhError = ""
    $repoPrefix = "repos/$RepoSlug"

    # Step 1: Enumerate workflows for the repository.
    # Enumerate workflows then query per-workflow runs: 'gh run list' returned 404 against
    # private repos on 2026-08-17 (transient; 200 again on 2026-08-18). The two-step query
    # worked through both, so it stays.
    $wfArgs = @("api")
    if (-not [string]::IsNullOrWhiteSpace($HostName) -and $HostName -ne "github.com") {
        $wfArgs += @("--hostname", $HostName)
    }
    $wfArgs += "$repoPrefix/actions/workflows"
    $wfResult = Invoke-GhJson -Arguments $wfArgs
    if ($wfResult.ExitCode -ne 0) {
        $script:LastGhError = $wfResult.Output.Trim()
        return $null
    }

    $wfData = $null
    if (-not [string]::IsNullOrWhiteSpace($wfResult.Output)) {
        try {
            $wfData = $wfResult.Output | ConvertFrom-Json
        } catch {
            $script:LastGhError = "Failed to parse workflows JSON: $_"
            return $null
        }
    }
    if ($null -eq $wfData -or $null -eq $wfData.workflows) {
        return ,@()
    }

    $workflows = @($wfData.workflows | Where-Object { [string]$_.state -eq "active" })
    if ($workflows.Count -eq 0) {
        return ,@()
    }

    # Step 2: Query runs for each active workflow matching $CommitSha.
    $allRuns = @()
    foreach ($wf in $workflows) {
        $wfId = [string]$wf.id
        $runArgs = @("api")
        if (-not [string]::IsNullOrWhiteSpace($HostName) -and $HostName -ne "github.com") {
            $runArgs += @("--hostname", $HostName)
        }
        $runArgs += "$repoPrefix/actions/workflows/$wfId/runs?head_sha=$CommitSha"
        $runResult = Invoke-GhJson -Arguments $runArgs
        if ($runResult.ExitCode -ne 0) {
            $script:LastGhError = $runResult.Output.Trim()
            return $null
        }

        $runData = $null
        if (-not [string]::IsNullOrWhiteSpace($runResult.Output)) {
            try {
                $runData = $runResult.Output | ConvertFrom-Json
            } catch {
                $script:LastGhError = "Failed to parse workflow runs JSON: $_"
                return $null
            }
        }
        if ($null -ne $runData -and $null -ne $runData.workflow_runs) {
            foreach ($r in @($runData.workflow_runs)) {
                $allRuns += [pscustomobject]@{
                    databaseId = $r.id
                    id         = $r.id
                    status     = $r.status
                    conclusion = $r.conclusion
                    name       = $r.name
                    html_url   = $r.html_url
                }
            }
        }
    }

    return ,@($allRuns)
}

function Write-FailedJobs {
    param(
        [object[]]$Runs,
        [string]$RepoSlug,
        [string]$HostName = "github.com"
    )
    $badConclusions = @("failure", "timed_out", "cancelled")
    $repoPrefix = "repos/$RepoSlug"
    foreach ($run in $Runs) {
        if ($badConclusions -notcontains ([string]$run.conclusion)) {
            continue
        }
        $runId = if ($run.databaseId) { $run.databaseId } else { $run.id }
        $browserUrl = ""
        if (-not [string]::IsNullOrWhiteSpace([string]$run.html_url)) {
            $browserUrl = [string]$run.html_url
        } else {
            $browserHost = if (-not [string]::IsNullOrWhiteSpace($HostName)) { $HostName } else { "github.com" }
            $browserUrl = "https://" + $browserHost + "/" + $RepoSlug + "/actions/runs/" + $runId
        }

        $jobArgs = @("api")
        if (-not [string]::IsNullOrWhiteSpace($HostName) -and $HostName -ne "github.com") {
            $jobArgs += @("--hostname", $HostName)
        }
        $jobArgs += "$repoPrefix/actions/runs/$runId/jobs"
        $view = Invoke-GhJson -Arguments $jobArgs
        if ($view.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($view.Output)) {
            $rawErr = if ($null -ne $view.Output) { $view.Output.Trim() } else { "" }
            $statusMsg = "HTTP error"
            if ($rawErr -match '(HTTP\s+\d+)') {
                $statusMsg = $Matches[1]
            } elseif (-not [string]::IsNullOrWhiteSpace($rawErr)) {
                $statusMsg = $rawErr
            }
            Write-Host ("  run " + $runId + ": job details unavailable (GET actions/runs/" + $runId + "/jobs -> " + $statusMsg + ")")
            Write-Host ("  run " + $runId + ": view in browser: " + $browserUrl)
            continue
        }
        $details = $null
        try {
            $details = $view.Output | ConvertFrom-Json
        } catch {
            Write-Host ("  run " + $runId + ": job details unavailable (jobs response was not valid JSON)")
            Write-Host ("  run " + $runId + ": view in browser: " + $browserUrl)
            continue
        }
        if ($null -ne $details -and $null -ne $details.jobs) {
            foreach ($job in @($details.jobs)) {
                if ($badConclusions -contains ([string]$job.conclusion)) {
                    Write-Host ("  " + $job.name)
                }
            }
        }
    }
}

if (-not (Get-Command "gh" -ErrorAction SilentlyContinue)) {
    Write-Host "[CI WATCH] STATUS=UNAVAILABLE"
    Write-Host "  gh command not found on PATH"
    exit 6
}

$auth = & gh auth status 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host "[CI WATCH] STATUS=UNAVAILABLE"
    $authText = ($auth -join " ").Trim()
    if (-not [string]::IsNullOrWhiteSpace($authText)) {
        Write-Host ("  gh authentication failed: " + $authText)
    } else {
        Write-Host "  gh authentication failed"
    }
    exit 6
}

if ([string]::IsNullOrWhiteSpace($CrucibleRoot)) {
    $CrucibleRoot = (Get-Location).Path
}
if (Test-Path -LiteralPath $CrucibleRoot) {
    $CrucibleRoot = (Resolve-Path -LiteralPath $CrucibleRoot).Path
}

$repoIdentity = $null
if (-not [string]::IsNullOrWhiteSpace($Repo)) {
    $trimmedRepo = $Repo.Trim()
    if ($trimmedRepo -match '^([^/:]+)/([^/]+)/([^/]+)$') {
        $repoIdentity = [pscustomobject]@{
            Host  = $Matches[1]
            Owner = $Matches[2]
            Name  = $Matches[3]
            Slug  = "$($Matches[2])/$($Matches[3])"
        }
    } elseif ($trimmedRepo -match '^([^/]+)/([^/]+)$') {
        $repoIdentity = [pscustomobject]@{
            Host  = "github.com"
            Owner = $Matches[1]
            Name  = $Matches[2]
            Slug  = "$($Matches[1])/$($Matches[2])"
        }
    }
}
if ($null -eq $repoIdentity) {
    $repoIdentity = Get-OriginRepoIdentity -Root $CrucibleRoot
}
if ($null -eq $repoIdentity) {
    Write-Host "[CI WATCH] STATUS=UNAVAILABLE"
    Write-Host ("  could not determine the GitHub repository for " + $CrucibleRoot)
    Write-Host "  pass -Repo <owner>/<name>"
    exit 6
}

if ([string]::IsNullOrWhiteSpace($Commit)) {
    $Commit = Get-CurrentCommit -Root $CrucibleRoot
}
# The head_sha= query matches full SHAs only.
$Commit = Resolve-FullCommitSha -CommitSha $Commit -Root $CrucibleRoot

$noRunsDeadline = (Get-Date).AddMinutes($NoRunsGraceMinutes)
$queuedDeadline = (Get-Date).AddMinutes($QueuedGraceMinutes)
$sawRuns = $false
$sawStarted = $false
$buildDeadline = $null
$lastRuns = @()

while ($true) {
    $runs = Get-RunList -CommitSha $Commit -RepoSlug $repoIdentity.Slug -HostName $repoIdentity.Host
    if ($null -eq $runs) {
        Write-Host "[CI WATCH] STATUS=API_ERROR"
        Write-Host ("  commit: " + $Commit)
        if (-not [string]::IsNullOrWhiteSpace($script:LastGhError)) {
            Write-Host ("  gh query failed: " + $script:LastGhError)
        } else {
            Write-Host "  could not retrieve workflow runs from GitHub API"
        }
        exit 6
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
            Write-FailedJobs -Runs $lastRuns -RepoSlug $repoIdentity.Slug -HostName $repoIdentity.Host
            exit 1
        }

        if (-not [string]::IsNullOrWhiteSpace($RequiredJobs)) {
            $requiredList = @($RequiredJobs.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" })
            if ($requiredList.Count -gt 0) {
                $observedJobs = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
                $repoPrefix = "repos/" + $repoIdentity.Slug
                foreach ($run in $lastRuns) {
                    $runId = if ($run.databaseId) { $run.databaseId } else { $run.id }
                    $jobArgs = @("api")
                    if (-not [string]::IsNullOrWhiteSpace($repoIdentity.Host) -and $repoIdentity.Host -ne "github.com") {
                        $jobArgs += @("--hostname", $repoIdentity.Host)
                    }
                    $jobArgs += "$repoPrefix/actions/runs/$runId/jobs"
                    $view = Invoke-GhJson -Arguments $jobArgs
                    if ($view.ExitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace($view.Output)) {
                        try {
                            $details = $view.Output | ConvertFrom-Json
                            foreach ($job in @($details.jobs)) {
                                if (-not [string]::IsNullOrWhiteSpace($job.name)) {
                                    [void]$observedJobs.Add(([string]$job.name).Trim())
                                }
                            }
                        } catch {}
                    }
                }
                $missingRequired = @()
                foreach ($req in $requiredList) {
                    if (-not $observedJobs.Contains($req)) {
                        $missingRequired += $req
                    }
                }
                if ($missingRequired.Count -gt 0) {
                    Write-Host "[CI WATCH] STATUS=MISSING_REQUIRED_JOBS"
                    Write-Host ("  commit: " + $Commit)
                    Write-Host ("  missing required jobs: " + ($missingRequired -join ", "))
                    exit 5
                }
            }
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
            $browserHost = if (-not [string]::IsNullOrWhiteSpace($repoIdentity.Host)) { $repoIdentity.Host } else { "github.com" }
            Write-Host ("  runs: https://" + $browserHost + "/" + $repoIdentity.Slug + "/actions")
            exit 4
        }
    } elseif ((Get-Date) -ge $buildDeadline) {
        Write-Host "[CI WATCH] STATUS=PENDING_TIMEOUT"
        Write-Host ("  commit: " + $Commit)
        $browserHost = if (-not [string]::IsNullOrWhiteSpace($repoIdentity.Host)) { $repoIdentity.Host } else { "github.com" }
        Write-Host ("  runs: https://" + $browserHost + "/" + $repoIdentity.Slug + "/actions")
        exit 2
    }

    Start-Sleep -Seconds $PollSeconds
}
