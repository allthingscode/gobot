param(
    [Parameter(Mandatory = $true)]
    [string]$TaskId,
    [ValidateSet("quick", "full", "test")]
    [string]$Mode = "full",
    [Parameter(Mandatory = $false)]
    [string]$ProjectRoot = "",
    [Parameter(Mandatory = $false)]
    [string]$Commit = ""
)

$ErrorActionPreference = "Stop"
$OutputEncoding = [System.Text.Encoding]::UTF8
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

. (Join-Path $PSScriptRoot "lib/platform.ps1")
. (Join-Path $PSScriptRoot "lib/config-helpers.ps1")
. (Join-Path $PSScriptRoot "lib/checks-not-run.ps1")

if ([string]::IsNullOrWhiteSpace($ProjectRoot)) {
    $ProjectRoot = Resolve-ConfigProjectRoot
} else {
    if (-not (Test-Path -LiteralPath $ProjectRoot)) {
        Write-Error ("-ProjectRoot path does not exist: {0}" -f $ProjectRoot)
    }
    $ProjectRoot = (Resolve-Path -LiteralPath $ProjectRoot).Path
}

# Item 188: lookup and detached checks share the configured workspaces root.
$worktreeRoot = Get-ConfiguredPath -Key "workspaces" -ProjectRoot $ProjectRoot
$commitWorktree = $null
function Remove-CommitWorktree {
    if ($null -eq $commitWorktree) { return }
    Set-Location -LiteralPath $ProjectRoot
    $rmRes = Invoke-Git -Directory $ProjectRoot worktree remove --force $commitWorktree
    if ($rmRes.ExitCode -ne 0) {
        Write-Warning ("Could not remove the temporary worktree {0}: {1}" -f $commitWorktree, $rmRes.Raw)
    }
}
# A trap covers the whole script, including lines before this one, so it tests the variable
# rather than calling the function before it exists.
trap { if ($null -ne $commitWorktree) { Remove-CommitWorktree }; break }
if (-not [string]::IsNullOrWhiteSpace($Commit)) {
    # Research tasks have no implementation worktree or task branch. -Commit runs
    # configured checks in a detached throwaway worktree so their artifacts never
    # touch the main checkout. Item 173.
    $commitRes = Invoke-Git -Directory $ProjectRoot rev-parse --verify --quiet ($Commit + "^{commit}")
    if ($commitRes.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($commitRes.Raw)) {
        Write-Error ("-Commit '{0}' does not name a commit in {1}." -f $Commit, $ProjectRoot)
    }
    $commitSha = $commitRes.Raw.Trim()
    $stamp = [datetime]::UtcNow.ToString("yyyyMMddTHHmmssfffZ", [System.Globalization.CultureInfo]::InvariantCulture)
    $commitWorktree = Join-Path $worktreeRoot ("checks-" + $TaskId + "-" + $stamp)
    $addRes = Invoke-Git -Directory $ProjectRoot worktree add --detach $commitWorktree $commitSha
    if ($addRes.ExitCode -ne 0) {
        Write-Error ("Could not create a worktree at {0} for {1}: {2}" -f $commitWorktree, $commitSha, $addRes.Raw)
    }
    $worktree = (Resolve-Path -LiteralPath $commitWorktree).Path
    Write-Host ("Running the configured checks for {0} at {1} in a temporary worktree: {2}" -f $TaskId, $commitSha, $worktree)
} else {
    $worktree = Join-Path $worktreeRoot ("implementation-" + $TaskId)
    if (-not (Test-Path -LiteralPath $worktree)) {
        Write-Error ("Worktree missing: {0}. A task with no implementation worktree (research, for example) passes -Commit <rev> instead." -f $worktree)
    }
    $worktree = (Resolve-Path -LiteralPath $worktree).Path

    $branchRes = Invoke-Git -Directory $worktree rev-parse --abbrev-ref HEAD
    $branch = $branchRes.Raw.Trim()
    $expectedBranch = "task/$TaskId"
    if ($branchRes.ExitCode -ne 0 -or $branch -ne $expectedBranch) {
        Write-Error ("Worktree branch mismatch. Expected '{0}', found '{1}'." -f $expectedBranch, $branch)
    }
}


$configPath = Join-Path $ProjectRoot ".crucible/config.yaml"
if (-not (Test-Path -LiteralPath $configPath)) {
    Write-Error ("Configuration file not found: {0}" -f $configPath)
}

# Map "test" mode to "quick" if the framework calls it with "test" for backward compatibility
$targetMode = if ($Mode -eq "test") { "quick" } else { $Mode }

# Item 245: the checks block has one reader, shared with validate-config.ps1 and crucible-doctor.ps1.
$configContent = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8
$identityErrors = @(Get-VerificationCheckIdentityErrors -Content $configContent)
if ($identityErrors.Count -gt 0) {
    [Console]::Error.WriteLine(($identityErrors -join "`n"))
    exit 2
}
$commands = @(Get-VerificationChecks -Content $configContent -Mode $targetMode)

# A not-run line clears only when its own check executes, so a quick run or an early failure
# keeps a skip that a full run or another step recorded. Item 258.
$sessionRoot = Get-ConfiguredPath -Key "session" -ProjectRoot $ProjectRoot


function Invoke-Check {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$CommandString
    )
    Write-Host ("==> {0}" -f $Name)
    # Execute the string as a command line
    $global:LASTEXITCODE = 0
    Invoke-Expression $CommandString
    $checkExit = $LASTEXITCODE
    # A nonzero command exit is still an executed check. A launch/parse error throws
    # above, retaining its previous skip instead of claiming that it ran.
    Clear-ChecksNotRun -SessionDir $sessionRoot -TaskId $TaskId -Source "isolated checks" -Check $Name
    Write-Host ("    exit code: {0}" -f $checkExit)
    if ($checkExit -ne 0) {
        # Emit a stable stdout marker before throwing. The orchestrator parses this line
        # to name the failing check; child-process error rendering differs across
        # hosts, so relying on
        # the thrown error text is not portable.
        Write-Host ("Check failed: {0}" -f $Name)
        throw ("Check failed: {0}" -f $Name)
    }
}

function Get-HostGateReason {
    param([string]$Condition)
    if ([string]::IsNullOrWhiteSpace($Condition)) { return $null }
    if ($Condition -match '^os=(windows|linux|macos)$') {
        $actual = if (Test-PlatformIsWindows) { "windows" } elseif ($IsMacOS) { "macos" } else { "linux" }
        if ($actual -ne $Matches[1]) { return "requires OS $($Matches[1]); host is $actual" }
        return $null
    }
    if ($Condition -match '^command=([A-Za-z0-9_.+-]+)$') {
        if ($null -eq (Get-Command $Matches[1] -CommandType Application -ErrorAction SilentlyContinue)) { return "requires command '$($Matches[1])' on PATH" }
        return $null
    }
    if ($Condition -match '^env=([A-Za-z_][A-Za-z0-9_]*)$') {
        $envName = $Matches[1]
        if ([string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($envName))) { return "requires environment variable '$envName'" }
        return $null
    }
    if ($Condition -eq 'cgo') {
        $go = Get-Command go -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -ne $go) {
            $cgoEnabled = (& $go.Source env CGO_ENABLED 2>$null | Select-Object -First 1)
            $compiler = (& $go.Source env CC 2>$null | Select-Object -First 1)
            if ($LASTEXITCODE -eq 0 -and $cgoEnabled -eq '1' -and $null -ne (Get-Command $compiler -CommandType Application -ErrorAction SilentlyContinue)) { return $null }
        }
        return "requires cgo (CGO_ENABLED=1 and Go on PATH)"
    }
    throw "Invalid verification host_gate '$Condition'. Use cgo, os=windows|linux|macos, command=<name>, or env=<name>."
}

# Encoding guard (runs in every mode, before config commands and regardless of whether
# any are defined). A specialist can commit a UTF-8 BOM, mojibake, or introduced
# whitespace into an adopter deliverable that the config verification commands (build,
# vet, doc-lint) do not catch; without this the corruption survives to human review and
# costs a review strike. Scan only the files this task changed, so the gate stays fast
# and never flags pre-existing debt. Determine the branch fork point to diff against.
# Keep the encoding baseline aligned with the scope check. Item 225.
$defaultBranch = Get-ConfiguredPrimaryBranch -ProjectRoot $worktree
$mergeBaseRes = Invoke-Git -Directory $worktree merge-base HEAD $defaultBranch
if ($mergeBaseRes.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($mergeBaseRes.Raw)) {
    throw "Could not determine encoding baseline against '$defaultBranch'."
}
$base = $mergeBaseRes.Raw.Trim()

$changedRel = New-Object System.Collections.Generic.List[string]
if ($base) {
    foreach ($f in (Invoke-Git -Directory $worktree diff --name-only --diff-filter=d $base HEAD).Lines) {
        if ($f) { $changedRel.Add($f) }
    }
}
foreach ($f in (Invoke-Git -Directory $worktree diff --name-only --diff-filter=d HEAD).Lines) {
    if ($f) { $changedRel.Add($f) }
}
foreach ($f in (Invoke-Git -Directory $worktree diff --name-only --cached --diff-filter=d).Lines) {
    if ($f) { $changedRel.Add($f) }
}

$scanFiles = @()
foreach ($rel in ($changedRel | Sort-Object -Unique)) {
    if ($rel -match '\.(md|ps1)$') {
        $abs = Join-Path $worktree $rel
        if (Test-Path -LiteralPath $abs) { $scanFiles += $abs }
    }
}

$mojibakeScript = Join-Path $PSScriptRoot "gates/check-mojibake.ps1"
if (-not (Test-Path -LiteralPath $mojibakeScript)) {
    $mojibakeScript = Join-Path $PSScriptRoot "tests/check-mojibake.ps1"
}
if ($scanFiles.Count -gt 0 -and -not (Test-Path -LiteralPath $mojibakeScript)) {
    Write-Host "NOT RUN: Encoding guard (BOM/mojibake) - check-mojibake.ps1 not found" -ForegroundColor Yellow
    Write-CheckNotRun -SessionDir $sessionRoot -TaskId $TaskId -Source "isolated checks" -Check "Encoding guard (BOM/mojibake)" -Reason ("check-mojibake.ps1 not found at " + $mojibakeScript)
} elseif ($scanFiles.Count -gt 0) {
    $host_exe = (Get-Process -Id $PID).Path
    & $host_exe -NoProfile -ExecutionPolicy Bypass -File $mojibakeScript @scanFiles
    $mojibakeExit = $LASTEXITCODE
    Clear-ChecksNotRun -SessionDir $sessionRoot -TaskId $TaskId -Source "isolated checks" -Check "Encoding guard (BOM/mojibake)"
    if ($mojibakeExit -ne 0) {
        Write-Host "Check failed: Encoding guard (BOM/mojibake)"
        throw "Check failed: Encoding guard (BOM/mojibake)"
    }
}
# Introduced-whitespace check over the task's own diff (trailing whitespace, blank line
# at EOF, space-before-tab). Only meaningful when the fork point is known.
if ($base) {
    $diffCheck = Invoke-Git -Directory $worktree diff --check $base HEAD
    if ($diffCheck.ExitCode -ne 0) {
        Write-Host "Check failed: Encoding guard (whitespace)"
        throw "Check failed: Encoding guard (whitespace)"
    }
}

# Cross-platform advisory. Isolated checks run only on THIS host's OS. When the adopter's CI
# runs a multi-OS matrix, OS-divergent behavior (filesystem error text, path separators, line
# endings, case sensitivity) can pass here yet fail on origin CI - exactly the class of failure
# the gate's origin-CI watch exists to catch. Surface the gap so a green local run is not
# mistaken for cross-platform coverage.
$hostOsFamily = if (Test-PlatformIsWindows) { "windows" } else { "linux" }
$ciOsFamilies = New-Object System.Collections.Generic.List[string]
$workflowDir = Join-Path $ProjectRoot ".github/workflows"
if (Test-Path -LiteralPath $workflowDir) {
    $sawWindows = $false; $sawLinux = $false; $sawMac = $false
    foreach ($wf in (Get-ChildItem -LiteralPath $workflowDir -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -in ".yml", ".yaml" })) {
        $wfText = Get-Content -LiteralPath $wf.FullName -Raw -ErrorAction SilentlyContinue
        if ($null -eq $wfText) { continue }
        if ($wfText -match "(?i)windows-") { $sawWindows = $true }
        if ($wfText -match "(?i)ubuntu-") { $sawLinux = $true }
        if ($wfText -match "(?i)macos-") { $sawMac = $true }
    }
    if ($sawWindows) { $ciOsFamilies.Add("windows") }
    if ($sawLinux) { $ciOsFamilies.Add("linux") }
    if ($sawMac) { $ciOsFamilies.Add("macos") }
}
$uncoveredOs = @($ciOsFamilies | Where-Object { $_ -ne $hostOsFamily })
if ($uncoveredOs.Count -gt 0) {
    Write-Host ""
    Write-Host ("[cross-platform] Isolated checks ran on this host ({0}) ONLY. Your CI matrix also targets: {1}." -f $hostOsFamily, ($uncoveredOs -join ", ")) -ForegroundColor Yellow
    Write-Host "[cross-platform] OS-divergent behavior (filesystem error text, path separators, line endings, case sensitivity) can pass here yet fail on origin CI. Assert such behavior platform-independently; origin CI (the gate's CI-watch) is the authoritative cross-platform signal." -ForegroundColor Yellow
}

function Resolve-HookInterpreter {
    param([Parameter(Mandatory = $true)][string]$HookPath)
    $first = (Get-Content -LiteralPath $HookPath -TotalCount 1 -Encoding UTF8)
    $name = "sh"
    if ($null -ne $first -and $first.StartsWith("#!")) {
        $words = @($first.Substring(2).Trim() -split '\s+' | Where-Object { $_ })
        if ($words.Count -gt 0) {
            $name = Split-Path -Leaf $words[0]
            if ($name -eq "env" -and $words.Count -gt 1) { $name = $words[1] }
        }
    }
    $cmd = Get-Command $name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -ne $cmd) { return $cmd.Source }
    # Git for Windows runs hooks with its own sh, which is often not on PATH.
    $gitRoot = Get-GitForWindowsRoot
    if ($null -ne $gitRoot) {
        foreach ($rel in @("usr/bin/$name.exe", "bin/$name.exe")) {
            $candidate = Join-Path $gitRoot $rel
            if (Test-Path -LiteralPath $candidate) { return $candidate }
        }
    }
    return $null
}

function Get-GitForWindowsRoot {
    $git = Get-Command git -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $git) { return $null }
    return (Split-Path -Parent (Split-Path -Parent $git.Source))
}

# Git prepends its tool directories to PATH for hooks; include them when invoking
# Git's sh so project hooks can find sed, awk and grep. Item 176.
function Get-GitHookToolPath {
    param([Parameter(Mandatory = $true)][string]$Interpreter)
    $gitRoot = Get-GitForWindowsRoot
    if ($null -eq $gitRoot) { return $null }
    $prefix = $gitRoot.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
    if (-not $Interpreter.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) { return $null }
    $dirs = @("usr/bin", "mingw64/bin", "bin") | ForEach-Object { Join-Path $gitRoot $_ } | Where-Object { Test-Path -LiteralPath $_ }
    return ((@($dirs) + @($env:PATH)) -join [System.IO.Path]::PathSeparator)
}

# Run the configured project pre-push hook in full mode against the task branch
# before the Human Gate so acceptance includes its checks. Item 172.
function Invoke-ProjectPrePushHook {
    . (Join-Path $PSScriptRoot "lib/config-helpers.ps1")
. (Join-Path $PSScriptRoot "lib/checks-not-run.ps1")
    $checkName = "Project pre-push hook"
    try {
        $hooksDir = Get-ConfiguredProjectHooksDir -ProjectRoot $ProjectRoot
    } catch {
        Write-Host ("hooks.project_dir is unusable, so the project's pre-push hook cannot run: " + $_.Exception.Message)
        Write-Host ("Check failed: {0}" -f $checkName)
        throw ("Check failed: {0}" -f $checkName)
    }
    if ([string]::IsNullOrWhiteSpace($hooksDir)) { return }
    $relDir = [System.IO.Path]::GetRelativePath($ProjectRoot, $hooksDir)
    $hook = Join-Path (Join-Path $worktree $relDir) "pre-push"
    if (-not (Test-Path -LiteralPath $hook -PathType Leaf)) {
        Write-Host ("No project pre-push hook in {0} on task/{1}; nothing to run." -f $relDir.Replace('\', '/'), $TaskId)
        return
    }
    $interpreter = Resolve-HookInterpreter -HookPath $hook
    if ($null -eq $interpreter) {
        Write-Host ("The interpreter on the first line of {0} was not found, so the hook cannot run." -f $hook)
        Write-Host ("Check failed: {0}" -f $checkName)
        throw ("Check failed: {0}" -f $checkName)
    }
    Write-Host ("==> {0} ({1})" -f $checkName, (Join-Path $relDir "pre-push").Replace('\', '/'))
    $hookArgs = @("origin")
    $urlRes = Invoke-Git -Directory $worktree remote get-url origin
    if ($urlRes.ExitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace($urlRes.Raw)) { $hookArgs += $urlRes.Raw.Trim() }
    $psi = [System.Diagnostics.ProcessStartInfo]::new($interpreter)
    $psi.ArgumentList.Add($hook)
    foreach ($a in $hookArgs) { $psi.ArgumentList.Add($a) }
    $psi.WorkingDirectory = $worktree
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.Environment["CRUCIBLE_PRE_PUSH_PREFLIGHT"] = "1"
    $hookPath = Get-GitHookToolPath -Interpreter $interpreter
    if ($null -ne $hookPath) { $psi.Environment["PATH"] = $hookPath }
    $proc = [System.Diagnostics.Process]::Start($psi)
    # Empty stdin, closed at once: no refs are being pushed, and a hook reading them must not
    # block. Piping $null instead races the hook's exit and fails with a broken pipe on Linux.
    $proc.StandardInput.Close()
    $proc.WaitForExit()
    $hookExit = $proc.ExitCode
    $proc.Dispose()
    Clear-ChecksNotRun -SessionDir $sessionRoot -TaskId $TaskId -Source "isolated checks" -Check $checkName
    if ($hookExit -ne 0) {
        Write-Host ("The project's pre-push hook exits {0} on task/{1}, so the push after the Human Gate would be refused." -f $hookExit, $TaskId)
        Write-Host ("Check failed: {0}" -f $checkName)
        throw ("Check failed: {0}" -f $checkName)
    }
}

# A mode with no checks is reported, not passed (I12). Item 256 may make it a refusal.
$modeCheck = "verification." + $targetMode + " checks"
if ($commands.Count -eq 0) {
    Write-Host "NOT RUN: No commands found for verification mode '${targetMode}'. Skipping checks." -ForegroundColor Yellow
    Write-CheckNotRun -SessionDir $sessionRoot -TaskId $TaskId -Source "isolated checks" -Check $modeCheck -Reason ("config.yaml configures no verification." + $targetMode + " checks, so none ran")
} else {
    Clear-ChecksNotRun -SessionDir $sessionRoot -TaskId $TaskId -Source "isolated checks" -Check $modeCheck
}

Push-Location $worktree
try {
    foreach ($cmd in $commands) {
        $reason = Get-HostGateReason -Condition $cmd.HostGate
        if ($null -ne $reason -and -not [string]::IsNullOrWhiteSpace($cmd.AlternativeRunner)) {
            Write-Host ("==> {0} (alternative runner: {1})" -f $cmd.Name, $cmd.AlternativeRunner)
            Invoke-Check -Name $cmd.Name -CommandString $cmd.AlternativeRunner
        } elseif ($null -ne $reason) {
            Write-Host ("NOT RUN: {0} - {1}" -f $cmd.Name, $reason) -ForegroundColor Yellow
            Write-CheckNotRun -SessionDir $sessionRoot -TaskId $TaskId -Source "isolated checks" -Check $cmd.Name -Reason $reason
        } else {
            Invoke-Check -Name $cmd.Name -CommandString $cmd.Command
        }
    }
} finally {
    Pop-Location
}

if ($null -ne $commitWorktree) {
    if ($targetMode -eq "full") {
        Write-Host "The project pre-push hook checks a branch push, so it does not run for -Commit."
        try {
            $commitHooksDir = Get-ConfiguredProjectHooksDir -ProjectRoot $ProjectRoot
        } catch {
            $commitHooksDir = ""
            Write-CheckNotRun -SessionDir $sessionRoot -TaskId $TaskId -Source "isolated checks" -Check "Project pre-push hook" -Reason ("hooks.project_dir is unusable: " + $_.Exception.Message)
        }
        if (-not [string]::IsNullOrWhiteSpace($commitHooksDir)) {
            $commitHook = Join-Path (Join-Path $worktree ([System.IO.Path]::GetRelativePath($ProjectRoot, $commitHooksDir))) "pre-push"
            if (Test-Path -LiteralPath $commitHook -PathType Leaf) {
                Write-CheckNotRun -SessionDir $sessionRoot -TaskId $TaskId -Source "isolated checks" -Check "Project pre-push hook" -Reason "-Commit runs the checks in a detached worktree and the hook checks a branch push"
            }
        }
    }
    Remove-CommitWorktree
} elseif ($targetMode -eq "full") {
    Invoke-ProjectPrePushHook
}

$recordedNotRun = @(Get-ChecksNotRun -SessionDir $sessionRoot -TaskId $TaskId)
if ($recordedNotRun.Count -gt 0) {
    Write-Host ("Checks not run for {0}, recorded in {1}. They are not passes:" -f $TaskId, (Get-ChecksNotRunPath -SessionDir $sessionRoot -TaskId $TaskId)) -ForegroundColor Yellow
    foreach ($line in $recordedNotRun) { Write-Host ("  - " + $line) -ForegroundColor Yellow }
}
