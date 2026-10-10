param(
    [Parameter(Mandatory = $true)]
    [string]$TaskId,
    [ValidateSet("quick", "full", "test")]
    [string]$Mode = "full",
    [Parameter(Mandatory = $false)]
    [string]$ProjectRoot = ""
)

$ErrorActionPreference = "Stop"
$OutputEncoding = [System.Text.Encoding]::UTF8
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

. (Join-Path $PSScriptRoot "lib/platform.ps1")

if ([string]::IsNullOrWhiteSpace($ProjectRoot)) {
    $ProjectRoot = (Get-Location).Path
} else {
    if (-not (Test-Path -LiteralPath $ProjectRoot)) {
        Write-Error ("-ProjectRoot path does not exist: {0}" -f $ProjectRoot)
    }
    $ProjectRoot = (Resolve-Path -LiteralPath $ProjectRoot).Path
}

$worktreeRoot = Join-Path $ProjectRoot ".crucible/.agent-workspaces"
$worktree = Join-Path $worktreeRoot ("implementation-" + $TaskId)
if (-not (Test-Path -LiteralPath $worktree)) {
    Write-Error ("Worktree missing: {0}" -f $worktree)
}
$worktree = (Resolve-Path -LiteralPath $worktree).Path

$branchRes = Invoke-Git -Directory $worktree rev-parse --abbrev-ref HEAD
$branch = $branchRes.Raw.Trim()
$expectedBranch = "task/$TaskId"
if ($branchRes.ExitCode -ne 0 -or $branch -ne $expectedBranch) {
    Write-Error ("Worktree branch mismatch. Expected '{0}', found '{1}'." -f $expectedBranch, $branch)
}

$configPath = Join-Path $ProjectRoot ".crucible/config.yaml"
if (-not (Test-Path -LiteralPath $configPath)) {
    Write-Error ("Configuration file not found: {0}" -f $configPath)
}

# Parse config.yaml for verification commands manually to avoid external module dependencies
$lines = Get-Content -LiteralPath $configPath -Encoding UTF8
$commands = @()
$inVerification = $false
$inMode = $false
$inConfigCheck = $false
$currentName = ""
$configCheckName = ""
$configCheckCommand = ""

# Map "test" mode to "quick" if the framework calls it with "test" for backward compatibility
$targetMode = if ($Mode -eq "test") { "quick" } else { $Mode }

# Read a YAML block scalar (| literal or > folded) whose header line is at index
# $HeaderIndex. Adopters commonly write a multi-statement verification command as a
# folded scalar (`command: >-`) for readability; the inline regex only captured the
# `>-` indicator, so Invoke-Expression later choked on a bare `>`. Returns the joined
# body plus NextIndex (first line NOT consumed). Folded joins content lines with
# spaces (blank line -> newline); literal joins with newlines. Chomping indicators
# are accepted; the trailing newline is irrelevant to Invoke-Expression.
function Read-BlockScalar {
    param(
        [string[]]$Lines,
        [int]$HeaderIndex,
        [string]$Indicator,
        [int]$KeyIndent
    )
    $folded = $Indicator.StartsWith(">")
    $bodyLines = New-Object System.Collections.Generic.List[string]
    $blockIndent = -1
    $i = $HeaderIndex + 1
    while ($i -lt $Lines.Count) {
        $line = $Lines[$i]
        if ($line -match "^\s*$") {
            $bodyLines.Add("")
            $i++
            continue
        }
        $indent = ($line -replace "^(\s*).*$", '$1').Length
        if ($indent -le $KeyIndent) { break }
        if ($blockIndent -lt 0) { $blockIndent = $indent }
        if ($line.Length -ge $blockIndent) {
            $bodyLines.Add($line.Substring($blockIndent))
        } else {
            $bodyLines.Add($line.TrimStart())
        }
        $i++
    }
    while ($bodyLines.Count -gt 0 -and $bodyLines[$bodyLines.Count - 1] -eq "") {
        $bodyLines.RemoveAt($bodyLines.Count - 1)
    }
    if ($folded) {
        $value = ""
        foreach ($b in $bodyLines) {
            if ($b -eq "") { $value += "`n" }
            elseif ($value -eq "" -or $value.EndsWith("`n")) { $value += $b }
            else { $value += " " + $b }
        }
    } else {
        $value = ($bodyLines -join "`n")
    }
    return @{ Value = $value; NextIndex = $i }
}

for ($idx = 0; $idx -lt $lines.Count; $idx++) {
    $line = $lines[$idx]
    if ($line -match "^verification:\s*$") {
        $inVerification = $true
        continue
    }
    if ($inVerification -and $line -match "^[a-zA-Z]") {
        $inVerification = $false
    }
    if (-not $inVerification) { continue }

    if ($line -match "^\s{2}${targetMode}:\s*$") {
        $inMode = $true
        $inConfigCheck = $false
        continue
    }
    if ($line -match "^\s{2}config_check:\s*$") {
        $inConfigCheck = $true
        $inMode = $false
        continue
    }
    if (($inMode -or $inConfigCheck) -and $line -match "^\s{2}[a-zA-Z]") {
        $inMode = $false
        $inConfigCheck = $false
    }
    if ($inMode) {
        if ($line -match "^\s{4}-\s*name:\s*(.+?)\s*$") {
            $currentName = $Matches[1].Trim("`"' ")
        }
        if ($line -match "^(\s{6})command:\s*(.+?)\s*$") {
            $keyIndent = $Matches[1].Length
            $rawVal = $Matches[2].Trim()
            if ($rawVal -match "^[|>][+-]?\d*$") {
                $bs = Read-BlockScalar -Lines $lines -HeaderIndex $idx -Indicator $rawVal -KeyIndent $keyIndent
                $commands += @{ Name = $currentName; Command = $bs.Value }
                $idx = $bs.NextIndex - 1
            } else {
                $commands += @{ Name = $currentName; Command = $rawVal.Trim("`"' ") }
            }
            $currentName = ""
        }
    }
    if ($inConfigCheck) {
        if ($line -match "^\s{4}name:\s*(.+?)\s*$") {
            $configCheckName = $Matches[1].Trim("`"' ")
        }
        if ($line -match "^(\s{4})command:\s*(.+?)\s*$") {
            $keyIndent = $Matches[1].Length
            $rawVal = $Matches[2].Trim()
            if ($rawVal -match "^[|>][+-]?\d*$") {
                $bs = Read-BlockScalar -Lines $lines -HeaderIndex $idx -Indicator $rawVal -KeyIndent $keyIndent
                $configCheckCommand = $bs.Value
                $idx = $bs.NextIndex - 1
            } else {
                $configCheckCommand = $rawVal.Trim("`"' ")
            }
        }
    }
}

if ($targetMode -eq "full" -and $configCheckName -and $configCheckCommand) {
    $commands += @{
        Name = $configCheckName
        Command = $configCheckCommand
    }
}


function Invoke-Check {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$CommandString
    )
    Write-Host ("==> {0}" -f $Name)
    # Execute the string as a command line
    Invoke-Expression $CommandString
    if ($LASTEXITCODE -ne 0) {
        # Emit a stable stdout marker before throwing. The orchestrator parses this line
        # to name the failing check; child-process error rendering differs across
        # hosts, so relying on
        # the thrown error text is not portable.
        Write-Host ("Check failed: {0}" -f $Name)
        throw ("Check failed: {0}" -f $Name)
    }
}

# Encoding guard (runs in every mode, before config commands and regardless of whether
# any are defined). A specialist can commit a UTF-8 BOM, mojibake, or introduced
# whitespace into an adopter deliverable that the config verification commands (build,
# vet, doc-lint) do not catch; without this the corruption survives to human review and
# costs a review strike. Scan only the files this task changed, so the gate stays fast
# and never flags pre-existing debt. Determine the branch fork point to diff against.
$defaultBranch = $null
foreach ($candidate in @("main", "master")) {
    $candRes = Invoke-Git -Directory $worktree rev-parse --verify --quiet ("refs/heads/" + $candidate)
    if ($candRes.ExitCode -eq 0) { $defaultBranch = $candidate; break }
}
$base = $null
if ($defaultBranch) {
    $mergeBaseRes = Invoke-Git -Directory $worktree merge-base HEAD $defaultBranch
    if ($mergeBaseRes.ExitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace($mergeBaseRes.Raw)) {
        $base = $mergeBaseRes.Raw.Trim()
    }
}

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
if ($scanFiles.Count -gt 0 -and (Test-Path -LiteralPath $mojibakeScript)) {
    $host_exe = (Get-Process -Id $PID).Path
    & $host_exe -NoProfile -ExecutionPolicy Bypass -File $mojibakeScript @scanFiles
    if ($LASTEXITCODE -ne 0) {
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
    $git = Get-Command git -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -ne $git) {
        $gitRoot = Split-Path -Parent (Split-Path -Parent $git.Source)
        foreach ($rel in @("usr/bin/$name.exe", "bin/$name.exe")) {
            $candidate = Join-Path $gitRoot $rel
            if (Test-Path -LiteralPath $candidate) { return $candidate }
        }
    }
    return $null
}

# The project's own pre-push hook, when hooks.project_dir names one, runs in full mode
# against the task branch. Nothing else runs it before the Human Gate, so a check it
# makes first failed at the push, after the work was accepted. Item 172.
function Invoke-ProjectPrePushHook {
    . (Join-Path $PSScriptRoot "lib/config-helpers.ps1")
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
    $previousFlag = $env:CRUCIBLE_PRE_PUSH_PREFLIGHT
    $env:CRUCIBLE_PRE_PUSH_PREFLIGHT = "1"
    Push-Location $worktree
    try {
        # Empty stdin: there are no refs being pushed, and a hook reading them must not block.
        $null | & $interpreter $hook @hookArgs
        $hookExit = $LASTEXITCODE
    } finally {
        Pop-Location
        $env:CRUCIBLE_PRE_PUSH_PREFLIGHT = $previousFlag
    }
    if ($hookExit -ne 0) {
        Write-Host ("The project's pre-push hook exits {0} on task/{1}, so the push after the Human Gate would be refused." -f $hookExit, $TaskId)
        Write-Host ("Check failed: {0}" -f $checkName)
        throw ("Check failed: {0}" -f $checkName)
    }
}

if ($commands.Count -eq 0) {
    Write-Host "No commands found for verification mode '${targetMode}'. Skipping checks." -ForegroundColor Yellow
}

Push-Location $worktree
try {
    foreach ($cmd in $commands) {
        Invoke-Check -Name $cmd.Name -CommandString $cmd.Command
    }
} finally {
    Pop-Location
}

if ($targetMode -eq "full") {
    Invoke-ProjectPrePushHook
}
