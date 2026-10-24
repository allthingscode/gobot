<#
.SYNOPSIS
    Launch a Codex specialist for a single Crucible pipeline phase, with full access and
    hardened verdict capture.

.DESCRIPTION
    This is the Crucible-blessed way to run Codex as a specialist under another orchestrator
    (for example, a Claude Code parent driving the Crucible loop). It wraps `codex exec` with
    the dogfood-validated full-access posture and treats infrastructure failures as DISTINCT
    from review verdicts, so a dead Codex runtime can never masquerade as a CHANGES_REQUESTED.

    It deliberately does NOT use the codex plugin's `task` runtime / `codex-rescue` subagent:
    that path hardcodes a read-only/workspace-write sandbox and routes through the app-server
    broker, which shells out to `codex-windows-sandbox-setup.exe` (absent on Windows) and fails
    every command. `codex exec -s danger-full-access` is the reliable full-access path.

.NOTES
    The authoritative specialist output remains the handoff JSON the Codex session writes plus
    its `crucible.ps1 -Init` run. This launcher's last-message + transcript capture is the
    orchestrator's sanity check that real work happened before any verdict is trusted.
#>
param(
    [Parameter(Mandatory = $false)]
    [string]$TaskId = "",

    [Parameter(Mandatory = $false)]
    # Keep synchronized with $script:CRUCIBLE_PHASES in crucible-lib.ps1.
    [ValidateSet("research", "grooming", "implementation", "verification", "deployment")]
    [string]$Phase = "",

    [Parameter(Mandatory = $false)]
    [string]$Model = "",

    # Directory Codex executes in (codex -C). Defaults to the project root. Pass the task
    # worktree (.crucible/.agent-workspaces/<phase>-<taskid>) for implementation/verification.
    [Parameter(Mandatory = $false)]
    [string]$WorkingDir = "",

    [Parameter(Mandatory = $false)]
    [string]$CrucibleRoot = ".crucible",

    # Override the auto-derived specialist role label (Researcher/Groomer/Architect/Reviewer/Operator).
    [Parameter(Mandatory = $false)]
    [string]$Role = "",

    # Override the auto-assembled bootstrap prompt entirely.
    [Parameter(Mandatory = $false)]
    [string]$PromptText = "",

    # Harness-safe file-sourced alternative to -PromptText; avoids -File argv re-tokenization of
    # multi-line/flag-bearing prompts. Supplying this makes -TaskId/-Phase optional: the session
    # is then named after the prompt file (.crucible/session/adhoc/<basename>/).
    [Parameter(Mandatory = $false)]
    [string]$PromptFile = "",

    # Reviewer phases only: enforce the structured review-verdict schema on Codex's final message.
    [switch]$ReviewSchema,

    # Bypass the pre-dispatch clean-tree provenance guard (dispatch onto a dirty tree deliberately).
    [switch]$AllowDirtyTree,

    # Optional reasoning effort (none|minimal|low|medium|high|xhigh|max), applied via -c model_reasoning_effort.
    [Parameter(Mandatory = $false)]
    [ValidateSet("", "none", "minimal", "low", "medium", "high", "xhigh", "max")]
    [string]$Effort = "",

    # Run only a cheap connectivity/runtime smoke check and exit. Catches a broken Codex runtime
    # BEFORE a real phase runs (the false-CHANGES_REQUESTED failure mode).
    [switch]$Preflight,

    [Parameter(Mandatory = $false)]
    [string]$ProjectRoot = ""
)

Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot "lib/config-helpers.ps1")
. (Join-Path $PSScriptRoot "lib/codex-launch-outcome.ps1")
. (Join-Path $PSScriptRoot "lib/crucible-command.ps1")
$ErrorActionPreference = "Stop"

function Resolve-ProjectRoot {
    param([string]$Candidate, [string]$ScriptDir)
    if (-not [string]::IsNullOrWhiteSpace($Candidate)) {
        if (-not (Test-Path -LiteralPath $Candidate)) {
            throw "ProjectRoot path does not exist: $Candidate"
        }
        return (Resolve-Path -LiteralPath $Candidate).Path
    }
    # Derive the project root from THIS script's location, never the caller's cwd. The
    # launcher ships to adopters at <root>/.crucible/powershell/ and lives in the framework
    # repo at <root>/powershell/, so $PSScriptRoot names the target repo unambiguously no
    # matter where the orchestrator invoked us from. Defaulting to cwd silently dispatched a
    # phase against the wrong repo when the orchestrator ran from a different checkout.
    $parent = Split-Path -Path $ScriptDir -Parent
    if ((Split-Path -Path $parent -Leaf) -eq ".crucible") {
        $parent = Split-Path -Path $parent -Parent
    }
    return (Resolve-Path -LiteralPath $parent).Path
}

function Get-RoleForPhase {
    param([string]$PhaseName)
    switch ($PhaseName) {
        "research"       { return "Researcher" }
        "grooming"       { return "Groomer" }
        "implementation" { return "Architect" }
        "verification"   { return "Reviewer" }
        "deployment"     { return "Operator" }
        default          { return "Specialist" }
    }
}

function New-BootstrapPrompt {
    param(
        [string]$RoleLabel,
        [string]$TaskIdValue,
        [string]$PromptPath,
        [string]$AdvanceCommand,
        [bool]$RequireJsonVerdict
    )
    $lines = @(
        "$RoleLabel`: $TaskIdValue - read and follow all instructions in $PromptPath",
        "",
        "You are a Crucible pipeline specialist running under an orchestrator. Follow your SOP",
        "checkpoint mandate: append '### CHECKPOINT [brief summary]' to your task.md after each",
        "major phase. Do not write the final handoff until all required task checklist items are",
        "complete. You are not alone in the codebase; do not revert unrelated edits.",
        "",
        "After writing handoff JSON, run:",
        ("  " + $AdvanceCommand),
        "That command can run for several minutes (an approved review re-runs the full project",
        "checks) and prints nothing under -Quiet. Wait until the process itself has exited before",
        "you end your session; ending early kills it and leaves the next phase unprepared.",
        "Report the Crucible output. Do not spawn successor agents."
    )
    if ($RequireJsonVerdict) {
        $lines += ""
        $lines += "Your FINAL message must be ONLY the JSON review verdict object conforming to the"
        $lines += "supplied output schema (verdict, summary, findings) - no prose around it."
    }
    return ($lines -join "`n")
}

$platformLib = Join-Path $PSScriptRoot "lib/platform.ps1"
if (-not (Test-Path -LiteralPath $platformLib)) {
    $platformLib = Join-Path (Split-Path -Parent $PSScriptRoot) "powershell/lib/platform.ps1"
}
if (Test-Path -LiteralPath $platformLib) {
    . $platformLib
}
if (-not (Get-Command "Invoke-Git" -ErrorAction SilentlyContinue)) {
    function Invoke-Git {
        [CmdletBinding()]
        param(
            [Parameter(Position=0, ValueFromRemainingArguments=$true)]
            [object[]]$GitArgs = @(),
            [Alias("Repo")]
            [string]$Directory = ""
        )
        $flattenedArgs = @()
        foreach ($arg in $GitArgs) {
            if ($arg -is [System.Collections.IEnumerable] -and $arg -isnot [string]) {
                foreach ($sub in $arg) { $flattenedArgs += [string]$sub }
            } else {
                $flattenedArgs += [string]$arg
            }
        }
        $allArgs = @()
        if (-not [string]::IsNullOrWhiteSpace($Directory)) { $allArgs += @("-C", $Directory) }
        if ($flattenedArgs.Count -gt 0) { $allArgs += $flattenedArgs }
        $prevEAP = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            $rawOutput = @(& git @allArgs 2>$null)
            $exitCode = if ($null -ne $LASTEXITCODE) { [int]$LASTEXITCODE } else { 0 }
        } finally {
            $ErrorActionPreference = $prevEAP
        }
        $lines = [string[]]@($rawOutput | ForEach-Object { [string]$_ })
        return [PSCustomObject]@{ ExitCode = $exitCode; Lines = $lines; Raw = ($lines -join "`n") }
    }
}

function Test-GitWorkTree {
    param([string]$Directory)
    $res = Invoke-Git -Directory $Directory rev-parse --is-inside-work-tree
    return (($res.ExitCode -eq 0) -and ($res.Raw.Trim() -eq "true"))
}

function Get-GitPorcelainStatus {
    param([string]$Directory)
    $res = Invoke-Git -Directory $Directory status --porcelain
    return [PSCustomObject]@{ ExitCode = $res.ExitCode; Output = $res.Raw }
}

# Names HEAD plus the exact content of every tracked and unignored file, staged or not,
# without touching the real index. Item 237.
function Get-TreeFingerprint {
    param([string]$Directory)
    $index = Join-Path ([System.IO.Path]::GetTempPath()) ("crucible-tree-" + [guid]::NewGuid().ToString("N"))
    $prevIndex = $env:GIT_INDEX_FILE
    try {
        $head = Invoke-Git -Directory $Directory rev-parse --verify HEAD
        $headSha = if ($head.ExitCode -eq 0) { $head.Raw.Trim() } else { "none" }
        # Starting from a copy of the real index keeps its stat cache, so unchanged files are not rehashed.
        $realIndex = Invoke-Git -Directory $Directory rev-parse --path-format=absolute --git-path index
        $env:GIT_INDEX_FILE = $index
        if ($realIndex.ExitCode -eq 0 -and (Test-Path -LiteralPath $realIndex.Raw.Trim())) {
            Copy-Item -LiteralPath $realIndex.Raw.Trim() -Destination $index -Force
        } else {
            $read = if ($head.ExitCode -eq 0) { Invoke-Git -Directory $Directory read-tree HEAD } else { Invoke-Git -Directory $Directory read-tree --empty }
            if ($read.ExitCode -ne 0) { return $null }
        }
        if ((Invoke-Git -Directory $Directory add --all).ExitCode -ne 0) { return $null }
        $tree = Invoke-Git -Directory $Directory write-tree
        if ($tree.ExitCode -ne 0) { return $null }
        return ("head " + $headSha + " tree " + $tree.Raw.Trim())
    } finally {
        if ($null -eq $prevIndex) { Remove-Item Env:GIT_INDEX_FILE -ErrorAction SilentlyContinue } else { $env:GIT_INDEX_FILE = $prevIndex }
        Remove-Item -LiteralPath $index -Force -ErrorAction SilentlyContinue
    }
}

function Read-TreeRecord {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $record = @{}
    foreach ($line in @(Get-Content -LiteralPath $Path -Encoding UTF8)) {
        if ($line -match '^([a-z_]+): (.*)$') { $record[$Matches[1]] = $Matches[2] }
    }
    return $record
}

function Invoke-CodexExec {
    param(
        [string[]]$CodexArgs,
        [string]$Prompt,
        [string]$TranscriptPath
    )
    if (-not (Get-Command "codex" -ErrorAction SilentlyContinue)) {
        return [PSCustomObject]@{ ExitCode = 127; Output = "'codex' was not found on PATH." }
    }
    $allArgs = @("exec") + $CodexArgs
    $previous = $ErrorActionPreference
    $previousOutputEncoding = [Console]::OutputEncoding
    $ErrorActionPreference = "Continue"
    try {
        # Feed the prompt on STDIN, never as a positional argument. Windows PowerShell 5.1's
        # native-argument quoting does not escape interior double-quotes, so a prompt passed as an
        # arg is silently split at each embedded quote (e.g. a -PromptText override with "quoted"
        # tokens) and codex's parser rejects the fragments; long prompts also blow the ~32K Windows
        # command-line ceiling. codex exec reads its prompt from stdin when no positional PROMPT is
        # given. Piping the string hands codex the full prompt followed by an immediate EOF, so it
        # neither mis-parses the prompt nor hangs on "Reading additional input from stdin...".
        # Item 211: hidden Windows hosts can default to OEM decoding; Codex emits UTF-8.
        [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
        $output = $Prompt | & codex @allArgs 2>&1 | Out-String
        $exitCode = $LASTEXITCODE
    } finally {
        [Console]::OutputEncoding = $previousOutputEncoding
        $ErrorActionPreference = $previous
    }
    if (-not [string]::IsNullOrWhiteSpace($TranscriptPath)) {
        try {
            $transcriptDir = Split-Path -Parent $TranscriptPath
            if (-not [string]::IsNullOrWhiteSpace($transcriptDir) -and -not (Test-Path -LiteralPath $transcriptDir)) {
                New-Item -ItemType Directory -Path $transcriptDir -Force | Out-Null
            }
            [System.IO.File]::WriteAllText($TranscriptPath, $output, (New-Object System.Text.UTF8Encoding($false)))
        } catch {
            Write-Warning ("Could not write Codex transcript to " + $TranscriptPath + ": " + $_.Exception.Message)
        }
    }
    return [PSCustomObject]@{ ExitCode = $exitCode; Output = $output }
}

$REPO_ROOT = Resolve-ProjectRoot -Candidate $ProjectRoot -ScriptDir $PSScriptRoot

# -CrucibleRoot is joined onto the repo root, so relativize absolute paths within
# that root and reject paths outside it before filesystem operations.
if ([System.IO.Path]::IsPathRooted($CrucibleRoot)) {
    $resolvedCrucibleRoot = $CrucibleRoot
    try { $resolvedCrucibleRoot = (Resolve-Path -LiteralPath $CrucibleRoot -ErrorAction Stop).Path } catch { }
    $relativeCrucibleRoot = $null
    try { $relativeCrucibleRoot = Get-PathRelativeToDirectory -Path $resolvedCrucibleRoot -Directory $REPO_ROOT } catch { }
    if (-not [string]::IsNullOrEmpty($relativeCrucibleRoot)) {
        $CrucibleRoot = $relativeCrucibleRoot
    } else {
        Write-Host ("[CODEX] Error: -CrucibleRoot must be relative to the repo root (e.g. '.crucible'), not an absolute path outside it: " + $CrucibleRoot) -ForegroundColor Red
        exit 2
    }
}

if ([string]::IsNullOrWhiteSpace($Model)) {
    Write-Host ("[CODEX] Error: -Model is required (use the [RECOMMENDED LEVEL] pair from " + (New-CrucibleCommand -Script "powershell/crucible.ps1" -Parameters ([ordered]@{ Init = $true; Target = "codex" }) -Reference) + ": its model as -Model, its effort as -Effort).") -ForegroundColor Red
    exit 2
}

$schemaPath = Join-Path $PSScriptRoot "lib/codex-review-verdict.schema.json"

# --- Preflight mode: cheap runtime smoke ---
if ($Preflight) {
    $token = "CRUCIBLE_OK"
    $preArgs = @("-s", "danger-full-access", "--skip-git-repo-check", "-m", $Model)
    $result = Invoke-CodexExec -CodexArgs $preArgs -Prompt "Respond with exactly: $token" -TranscriptPath ""
    $infra = Test-InfraFailure -Text $result.Output
    $pass = ($result.ExitCode -eq 0) -and ($null -eq $infra) -and ($result.Output -match $token)
    Write-Host ""
    if ($pass) {
        Write-Host "[CODEX PREFLIGHT] PASS" -ForegroundColor Green
        Write-Host ("  model: " + $Model)
        Write-Host ("  Codex runtime is reachable and full-access exec works.")
        exit 0
    } else {
        $reason = if ($result.ExitCode -eq 127) { "codex not on PATH" }
                  elseif ($null -ne $infra) { "infra marker: $infra" }
                  elseif ($result.ExitCode -ne 0) { "exit code $($result.ExitCode)" }
                  else { "expected token '$token' not found in output" }
        Write-Host "[CODEX PREFLIGHT] FAIL" -ForegroundColor Red
        Write-Host ("  reason: " + $reason)
        Write-Host ("  Do NOT dispatch a Codex specialist until this passes; a dead runtime")
        Write-Host ("  produces a false verdict. Try: codex login; or check the sandbox helper.")
        if (-not [string]::IsNullOrWhiteSpace($result.Output)) {
            Write-Host ("  output: " + ($result.Output.Trim() -replace "\s+", " ").Substring(0, [Math]::Min(300, ($result.Output.Trim() -replace "\s+", " ").Length)))
        }
        exit 1
    }
}

# --- Specialist phase mode ---

# Resolve the prompt source BEFORE validating -TaskId/-Phase. On the -PromptFile path those two
# select no content at all - New-BootstrapPrompt is never reached, so no spec, handoff or backlog
# entry is read by way of them - and their only remaining job is to name the session directory.
# The prompt file's own base name can do that, which is what lets work with no task ID (the
# framework's own TODO items) be dispatched without inventing a task ID to satisfy an argument.
if (-not [string]::IsNullOrWhiteSpace($PromptText) -and -not [string]::IsNullOrWhiteSpace($PromptFile)) {
    Write-Host "[CODEX] Error: -PromptText and -PromptFile are mutually exclusive." -ForegroundColor Red
    exit 2
}
$adhocLabel = ""
if (-not [string]::IsNullOrWhiteSpace($PromptFile)) {
    if (-not (Test-Path -LiteralPath $PromptFile)) {
        Write-Host ("[CODEX] Error: -PromptFile path does not exist: " + $PromptFile) -ForegroundColor Red
        exit 2
    }
    $resolvedPromptFile = (Resolve-Path -LiteralPath $PromptFile).Path
    $fileContent = [System.IO.File]::ReadAllText($resolvedPromptFile)
    if ([string]::IsNullOrWhiteSpace($fileContent)) {
        Write-Host ("[CODEX] Error: -PromptFile is empty: " + $PromptFile) -ForegroundColor Red
        exit 2
    }
    $PromptText = $fileContent
    $adhocLabel = [System.IO.Path]::GetFileNameWithoutExtension($resolvedPromptFile)
}

# -TaskId and -Phase remain required on the bootstrap path, where they do select content. They
# are optional on the -PromptFile path, but all-or-nothing: supplying one without the other
# would name a session directory (session/<id>/ or session//<phase>/) in a shape nothing else
# in Crucible writes or reads.
$usingAdhocSession = $false
if (-not [string]::IsNullOrWhiteSpace($PromptFile) -and [string]::IsNullOrWhiteSpace($TaskId) -and [string]::IsNullOrWhiteSpace($Phase)) {
    if ([string]::IsNullOrWhiteSpace($adhocLabel)) {
        Write-Host ("[CODEX] Error: cannot derive a session name from -PromptFile: " + $PromptFile) -ForegroundColor Red
        Write-Host "Give the prompt file a base name, or pass -TaskId and -Phase explicitly." -ForegroundColor Yellow
        exit 2
    }
    $usingAdhocSession = $true
} else {
    $adhocHint = "Omit both -TaskId and -Phase only when -PromptFile supplies the prompt; the session is then named after that file."
    if ([string]::IsNullOrWhiteSpace($TaskId)) {
        Write-Host "[CODEX] Error: -TaskId is required for a specialist phase launch." -ForegroundColor Red
        Write-Host $adhocHint -ForegroundColor Yellow
        exit 2
    }
    if ([string]::IsNullOrWhiteSpace($Phase)) {
        Write-Host "[CODEX] Error: -Phase is required for a specialist phase launch." -ForegroundColor Red
        Write-Host $adhocHint -ForegroundColor Yellow
        exit 2
    }
}

$crucibleDir = Resolve-CrucibleBundleRoot -ProjectRoot $REPO_ROOT -CrucibleRoot $CrucibleRoot
# Item 188: prompts, launch artifacts and completion detection use the same session root.
$sessionRoot = Get-ConfiguredPath -Key "session" -ProjectRoot $REPO_ROOT
$rootSource = if ([string]::IsNullOrWhiteSpace($ProjectRoot)) { "derived from script location" } else { "from -ProjectRoot" }

# The bootstrap prompt names the phase prompt by absolute path: the specialist runs in
# -WorkingDir, and a worktree holds no copy of the gitignored session dir, so a relative
# path sent it searching (or reading another repo's prompt). Refuse before creating any
# session dir when the prompt is not under the resolved root - usually a missing -ProjectRoot.
$bootstrapPromptPath = ""
if ([string]::IsNullOrWhiteSpace($PromptText)) {
    $bootstrapPromptPath = Join-Path $sessionRoot (Join-Path $TaskId (Join-Path $Phase "prompt.md"))
    if (-not (Test-Path -LiteralPath $bootstrapPromptPath)) {
        Write-Host ("[CODEX] Error: phase prompt not found: " + $bootstrapPromptPath) -ForegroundColor Red
        Write-Host ("  project root: " + $REPO_ROOT + "  (" + $rootSource + ")")
        Write-Host ("Run " + (New-CrucibleCommand -Script "powershell/crucible.ps1" -Transport PowerShell -Parameters ([ordered]@{ Init = $true; TaskId = $TaskId; ProjectRoot = "<adopter root>" }) -CrucibleRoot $CrucibleRoot) + " first, and pass that same -ProjectRoot here.") -ForegroundColor Yellow
        exit 2
    }
}

if ([string]::IsNullOrWhiteSpace($WorkingDir)) {
    $WorkingDir = $REPO_ROOT
} else {
    if (-not (Test-Path -LiteralPath $WorkingDir)) {
        Write-Host ("[CODEX] Error: -WorkingDir path does not exist: " + $WorkingDir) -ForegroundColor Red
        exit 2
    }
    $WorkingDir = (Resolve-Path -LiteralPath $WorkingDir).Path
}

if ($Phase -eq "deployment") {
    if (-not [string]::IsNullOrWhiteSpace($WorkingDir) -and $WorkingDir -ne $REPO_ROOT) {
        Write-Host ("[CODEX] Notice: Deployment phase forces WorkingDir to main repo root (" + $REPO_ROOT + "); ignoring passed WorkingDir (" + $WorkingDir + ").") -ForegroundColor Yellow
    }
    $WorkingDir = $REPO_ROOT
}

if ([string]::IsNullOrWhiteSpace($Role)) {
    $Role = Get-RoleForPhase -PhaseName $Phase
}

# Ad-hoc sessions nest under session/adhoc/ rather than sitting at session/<name>/ so they
# cannot collide with a task's own directory. crucible-health treats a top-level
# session/<F|B|C>-<n>/ dir as a task session and archives it once the backlog says that task is
# finished, and it deletes scratchpads and prompts at session/<phase-name>/. A prompt file named
# `F-001.md` or `implementation.md` would otherwise land in either line of fire; session/adhoc/
# matches neither.
if ($usingAdhocSession) {
    $sessionDir = Join-Path $sessionRoot (Join-Path "adhoc" $adhocLabel)
} else {
    $sessionDir = Join-Path $sessionRoot (Join-Path $TaskId $Phase)
}
$treeRecordPath = Join-Path $sessionDir "codex-tree-state.txt"

# A specialist that stops to escalate or hits a usage limit leaves its own work uncommitted.
# Each run records the tree it left, so a re-dispatch of the same session continues that
# work while any other uncommitted change still blocks. Item 237.
if ($AllowDirtyTree) {
    Write-Host "[CODEX] Notice: pre-dispatch tree check overridden by -AllowDirtyTree." -ForegroundColor Yellow
} elseif (-not (Test-GitWorkTree -Directory $WorkingDir)) {
    Write-Host "[CODEX] Note: WorkingDir is not a git work tree; skipping pre-dispatch tree check."
} else {
    $gitStatus = Get-GitPorcelainStatus -Directory $WorkingDir
    if ($gitStatus.ExitCode -ne 0) {
        Write-Host "[CODEX] Note: WorkingDir is not a git work tree; skipping pre-dispatch tree check."
    } elseif (-not [string]::IsNullOrWhiteSpace($gitStatus.Output)) {
        $treeRecord = Read-TreeRecord -Path $treeRecordPath
        $fingerprint = Get-TreeFingerprint -Directory $WorkingDir
        $recordMatches = ($null -ne $treeRecord) -and ($null -ne $fingerprint) -and
            ($treeRecord["working_dir"] -eq $WorkingDir) -and ($treeRecord["fingerprint"] -eq $fingerprint)
        if ($recordMatches) {
            Write-Host ("[CODEX] Notice: continuing the uncommitted work the previous run in this session left (recorded " + $treeRecord["recorded"] + ").") -ForegroundColor Yellow
        } else {
            if ($null -eq $treeRecord) {
                $why = "holds uncommitted changes that no earlier specialist run in this session left."
            } else {
                $why = "holds uncommitted changes that differ from what the previous run in this session left (recorded " + $treeRecord["recorded"] + "), so something else changed the tree since."
            }
            Write-Host ("[CODEX] Error: pre-dispatch tree check failed. The working tree at " + $WorkingDir + " " + $why) -ForegroundColor Red
            foreach ($line in ($gitStatus.Output -split "`n")) {
                if (-not [string]::IsNullOrWhiteSpace($line)) {
                    Write-Host ("  " + $line)
                }
            }
            Write-Host "Establish provenance first: commit or stash the changes, or pass -AllowDirtyTree to dispatch onto this tree deliberately (you then own its provenance)." -ForegroundColor Yellow
            exit 2
        }
    }
}
if (-not (Test-Path -LiteralPath $sessionDir)) {
    New-Item -ItemType Directory -Path $sessionDir -Force | Out-Null
}
$lastMsgPath   = Join-Path $sessionDir "codex-last-message.txt"
$transcriptPath = Join-Path $sessionDir "codex-transcript.txt"
$statusPath = Join-Path $sessionDir "codex-launch-status.txt"
if (Test-Path -LiteralPath $lastMsgPath) { Remove-Item -LiteralPath $lastMsgPath -Force }

$useSchema = $false
if ($ReviewSchema) {
    if (-not (Test-Path -LiteralPath $schemaPath)) {
        Write-Host ("[CODEX] Error: -ReviewSchema set but schema not found at " + $schemaPath) -ForegroundColor Red
        exit 2
    }
    $useSchema = $true
}

if (-not [string]::IsNullOrWhiteSpace($bootstrapPromptPath)) {
    # Built, not interpolated: a root such as C:/cash$root must reach the specialist as
    # written, in the script path and in -ProjectRoot alike. Item 247.
    $advanceCommand = New-CrucibleCommand -Script "powershell/crucible.ps1" -Transport ShellNeutral -Parameters ([ordered]@{ Init = $true; TaskId = $TaskId; ProjectRoot = $REPO_ROOT; Quiet = $true }) -CrucibleRoot $crucibleDir
    $PromptText = New-BootstrapPrompt -RoleLabel $Role -TaskIdValue $TaskId -PromptPath $bootstrapPromptPath `
        -AdvanceCommand $advanceCommand -RequireJsonVerdict $useSchema
}

$codexArgs = @(
    "-s", "danger-full-access",
    "--skip-git-repo-check",
    "-C", $WorkingDir,
    "-m", $Model,
    "--output-last-message", $lastMsgPath
)
if ($useSchema) { $codexArgs += @("--output-schema", $schemaPath) }
if (-not [string]::IsNullOrWhiteSpace($Effort)) {
    $codexArgs += @("-c", ("model_reasoning_effort=`"" + $Effort + "`""))
}

Write-Host ""
$launchTarget = if ($usingAdhocSession) { $adhocLabel + " (ad-hoc prompt)" } else { $TaskId + " (" + $Phase + ")" }
Write-Host ("[CODEX SPECIALIST] Launching " + $Role + " for " + $launchTarget) -ForegroundColor Cyan
Write-Host ("  project root: " + $REPO_ROOT + "  (" + $rootSource + ")")
if ([string]::IsNullOrWhiteSpace($Effort)) {
    Write-Host ("  level: " + $Model + " at Codex's own default effort  |  access: danger-full-access  |  workdir: " + $WorkingDir)
    Write-Host "  [WARN] No -Effort, so this is not a Crucible level. A level is a model and an effort together: pass the [RECOMMENDED LEVEL] pair." -ForegroundColor Yellow
} else {
    Write-Host ("  level: " + $Model + " at " + $Effort + " effort  |  access: danger-full-access  |  workdir: " + $WorkingDir)
}
if ($useSchema) { Write-Host "  review verdict schema: enforced" }

# Event timestamps carry whole seconds; back off one so an event in the launch second counts.
$launchStartUtc = [datetime]::UtcNow.AddSeconds(-1)
$statusEffort = if ([string]::IsNullOrWhiteSpace($Effort)) { "Codex's own default effort" } else { $Effort + " effort" }
# An ad hoc run has no task to advance, so it has no recovery command.
$recoveryCommand = if ([string]::IsNullOrWhiteSpace($TaskId)) { "" } else {
    New-CrucibleCommand -Script "powershell/crucible.ps1" -Transport ShellNeutral -Parameters ([ordered]@{ Init = $true; TaskId = $TaskId; ProjectRoot = $REPO_ROOT }) -CrucibleRoot $crucibleDir
}
Write-CodexLaunchStatus -StatusPath $statusPath -Record (Get-CodexLaunchOutcome -Evidence @{ Running = $true; Level = ($Model + " at " + $statusEffort) })

# From here to the exit, every outcome is decided by Get-CodexLaunchOutcome and written by
# Write-CodexLaunchStatus (lib/codex-launch-outcome.ps1), and nothing may throw past them:
# a failure to run codex or to read a piece of evidence is evidence too. Item 246.
$evidence = @{
    ExitCode        = $null
    Output          = ""
    LastMessage     = ""
    UseSchema       = $useSchema
    Adhoc           = $usingAdhocSession
    Phase           = $Phase
    LogEvents       = @()
    SinceUtc        = $launchStartUtc
    TranscriptPath  = $transcriptPath
    LastMessagePath = $lastMsgPath
    RecoveryCommand = $recoveryCommand
    InvokeError     = ""
    ReadErrors      = @{}
}
try {
    try {
        $result = Invoke-CodexExec -CodexArgs $codexArgs -Prompt $PromptText -TranscriptPath $transcriptPath
        $evidence.ExitCode = $result.ExitCode
        $evidence.Output = [string]$result.Output
    } catch {
        $evidence.InvokeError = $_.Exception.Message
    }

    # The tree record only lets a re-dispatch continue this run's work; failing to write it must
    # not cost the run its STATUS.
    try {
        if (Test-GitWorkTree -Directory $WorkingDir) {
            $leftFingerprint = Get-TreeFingerprint -Directory $WorkingDir
            if ($null -ne $leftFingerprint) {
                if (-not (Test-Path -LiteralPath $sessionDir)) { New-Item -ItemType Directory -Path $sessionDir -Force | Out-Null }
                $recordStamp = [datetime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ", [System.Globalization.CultureInfo]::InvariantCulture)
                $recordLines = @(("working_dir: " + $WorkingDir), ("fingerprint: " + $leftFingerprint), ("recorded: " + $recordStamp))
                [System.IO.File]::WriteAllText($treeRecordPath, (($recordLines -join "`n") + "`n"), (New-Object System.Text.UTF8Encoding($false)))
            }
        }
    } catch {
        Write-Warning ("Could not record the tree this run left at " + $treeRecordPath + ": " + $_.Exception.Message)
    }

    try {
        if (Test-Path -LiteralPath $lastMsgPath) {
            $lastMsg = Get-Content -LiteralPath $lastMsgPath -Raw -Encoding UTF8 -ErrorAction Stop
            if ($null -ne $lastMsg) { $evidence.LastMessage = [string]$lastMsg }
        }
    } catch {
        $evidence.ReadErrors["last message"] = $_.Exception.Message
    }
    if (-not $usingAdhocSession) {
        try {
            $evidence.LogEvents = Read-CodexLaunchLogEvents -LogPath (Join-Path $sessionRoot (Join-Path $TaskId "pipeline.log.jsonl")) -TaskIdValue $TaskId
        } catch {
            $evidence.ReadErrors["pipeline log"] = $_.Exception.Message
        }
    }
    $outcome = Get-CodexLaunchOutcome -Evidence $evidence
} catch {
    $outcome = New-CodexLaunchUnclassifiedRecord -Evidence $evidence -Reason $_.Exception.Message
}
Write-CodexLaunchStatus -StatusPath $statusPath -Record $outcome
exit $outcome.ExitCode
