<#
.SYNOPSIS
    Launch a Codex specialist for a single Crucible pipeline phase, with full access and
    hardened verdict capture.

.DESCRIPTION
    This is the Crucible-blessed way to run Codex as a specialist under another orchestrator
    (for example, a Claude Code parent driving the factory loop). It wraps `codex exec` with
    the dogfood-validated full-access posture and treats infrastructure failures as DISTINCT
    from review verdicts, so a dead Codex runtime can never masquerade as a CHANGES_REQUESTED.

    It deliberately does NOT use the codex plugin's `task` runtime / `codex-rescue` subagent:
    that path hardcodes a read-only/workspace-write sandbox and routes through the app-server
    broker, which shells out to `codex-windows-sandbox-setup.exe` (absent on Windows) and fails
    every command. `codex exec -s danger-full-access` is the reliable full-access path.

.NOTES
    The authoritative specialist output remains the handoff JSON the Codex session writes plus
    its `factory.ps1 -Init` run. This launcher's last-message + transcript capture is the
    orchestrator's sanity check that real work happened before any verdict is trusted.
#>
param(
    [Parameter(Mandatory = $false)]
    [string]$TaskId = "",

    [Parameter(Mandatory = $false)]
    # Keep synchronized with $script:FACTORY_PHASES in factory-lib.ps1.
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

    # Harness-safe file-sourced alternative to -PromptText; avoids -File argv re-tokenization of multi-line/flag-bearing prompts.
    [Parameter(Mandatory = $false)]
    [string]$PromptFile = "",

    # Reviewer phases only: enforce the structured review-verdict schema on Codex's final message.
    [switch]$ReviewSchema,

    # Bypass the pre-dispatch clean-tree provenance guard (dispatch onto a dirty tree deliberately).
    [switch]$AllowDirtyTree,

    # Optional reasoning effort (none|minimal|low|medium|high|xhigh), applied via -c model_reasoning_effort.
    [Parameter(Mandatory = $false)]
    [ValidateSet("", "none", "minimal", "low", "medium", "high", "xhigh")]
    [string]$Effort = "",

    # Run only a cheap connectivity/runtime smoke check and exit. Catches a broken Codex runtime
    # BEFORE a real phase runs (the false-CHANGES_REQUESTED failure mode).
    [switch]$Preflight,

    [Parameter(Mandatory = $false)]
    [string]$ProjectRoot = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Infrastructure-failure markers. If any appears in Codex stdout/stderr, the run is a LAUNCH
# FAILURE (broken runtime / auth), never a specialist verdict.
$script:InfraMarkers = @(
    "orchestrator_helper_launch_failed",
    "program not found",
    "codex-windows-sandbox-setup",
    "not logged in",
    "please run codex login",
    "unauthorized",
    "error sending request",
    "command not found"
)

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
        [string]$PhaseValue,
        [string]$CrucibleRootValue,
        [bool]$RequireJsonVerdict
    )
    $promptPath = "$CrucibleRootValue/session/$TaskIdValue/$PhaseValue/prompt.md"
    $lines = @(
        "$RoleLabel`: $TaskIdValue - read and follow all instructions in $promptPath",
        "",
        "You are a Crucible pipeline specialist running under an orchestrator. Follow your SOP",
        "checkpoint mandate: append '### CHECKPOINT [brief summary]' to your task.md after each",
        "major phase. Do not write the final handoff until all required task checklist items are",
        "complete. You are not alone in the codebase; do not revert unrelated edits.",
        "",
        "After writing handoff JSON, run:",
        "  pwsh -File `"$CrucibleRootValue/powershell/factory.ps1`" -Init -TaskId $TaskIdValue -Quiet",
        "(use powershell.exe on Windows). Report the factory output. Do not spawn successor agents."
    )
    if ($RequireJsonVerdict) {
        $lines += ""
        $lines += "Your FINAL message must be ONLY the JSON review verdict object conforming to the"
        $lines += "supplied output schema (verdict, summary, findings) - no prose around it."
    }
    return ($lines -join "`n")
}

function Test-InfraFailure {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    $lower = $Text.ToLowerInvariant()
    foreach ($marker in $script:InfraMarkers) {
        if ($lower.Contains($marker)) { return $marker }
    }
    return $null
}

function Invoke-GitStdout {
    param(
        [string]$Directory,
        [string[]]$GitArgs
    )
    if (-not (Get-Command "git" -ErrorAction SilentlyContinue)) {
        return [PSCustomObject]@{ ExitCode = 127; Output = "" }
    }
    $allArgs = @("-C", $Directory) + $GitArgs
    $previous = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $output = & git @allArgs 2>$null
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previous
    }
    return [PSCustomObject]@{ ExitCode = $exitCode; Output = ($output -join "`n") }
}

function Test-GitWorkTree {
    param([string]$Directory)
    $res = Invoke-GitStdout -Directory $Directory -GitArgs @("rev-parse", "--is-inside-work-tree")
    return (($res.ExitCode -eq 0) -and ($res.Output.Trim() -eq "true"))
}

function Get-GitPorcelainStatus {
    param([string]$Directory)
    return Invoke-GitStdout -Directory $Directory -GitArgs @("status", "--porcelain")
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
    $ErrorActionPreference = "Continue"
    try {
        # Feed the prompt on STDIN, never as a positional argument. Windows PowerShell 5.1's
        # native-argument quoting does not escape interior double-quotes, so a prompt passed as an
        # arg is silently split at each embedded quote (e.g. a -PromptText override with "quoted"
        # tokens) and codex's parser rejects the fragments; long prompts also blow the ~32K Windows
        # command-line ceiling. codex exec reads its prompt from stdin when no positional PROMPT is
        # given. Piping the string hands codex the full prompt followed by an immediate EOF, so it
        # neither mis-parses the prompt nor hangs on "Reading additional input from stdin...".
        $output = $Prompt | & codex @allArgs 2>&1 | Out-String
        $exitCode = $LASTEXITCODE
    } finally {
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

# -CrucibleRoot is Join-Path'd onto the repo root AND embedded RELATIVELY in the bootstrap
# prompt (.crucible/session/...). An absolute value breaks both and previously surfaced only
# as an opaque "New-Item : The given path's format is not supported". Relativize an absolute
# path that lives under the repo root; otherwise fail up front with a clear message.
if ([System.IO.Path]::IsPathRooted($CrucibleRoot)) {
    $resolvedCrucibleRoot = $CrucibleRoot
    try { $resolvedCrucibleRoot = (Resolve-Path -LiteralPath $CrucibleRoot -ErrorAction Stop).Path } catch { }
    $repoPrefix = $REPO_ROOT.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
    if ($resolvedCrucibleRoot.StartsWith($repoPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        $CrucibleRoot = $resolvedCrucibleRoot.Substring($repoPrefix.Length)
    } else {
        Write-Host ("[CODEX] Error: -CrucibleRoot must be relative to the repo root (e.g. '.crucible'), not an absolute path outside it: " + $CrucibleRoot) -ForegroundColor Red
        exit 2
    }
}

if ([string]::IsNullOrWhiteSpace($Model)) {
    Write-Host "[CODEX] Error: -Model is required (use the [RECOMMENDED MODEL] value from factory.ps1 -Init -Target codex)." -ForegroundColor Red
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
if ([string]::IsNullOrWhiteSpace($TaskId)) {
    Write-Host "[CODEX] Error: -TaskId is required for a specialist phase launch." -ForegroundColor Red
    exit 2
}
if ([string]::IsNullOrWhiteSpace($Phase)) {
    Write-Host "[CODEX] Error: -Phase is required for a specialist phase launch." -ForegroundColor Red
    exit 2
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

if ($AllowDirtyTree) {
    Write-Host "[CODEX] Notice: pre-dispatch tree check overridden by -AllowDirtyTree." -ForegroundColor Yellow
} elseif (-not (Test-GitWorkTree -Directory $WorkingDir)) {
    Write-Host "[CODEX] Note: WorkingDir is not a git work tree; skipping pre-dispatch tree check."
} else {
    $gitStatus = Get-GitPorcelainStatus -Directory $WorkingDir
    if ($gitStatus.ExitCode -ne 0) {
        Write-Host "[CODEX] Note: WorkingDir is not a git work tree; skipping pre-dispatch tree check."
    } elseif (-not [string]::IsNullOrWhiteSpace($gitStatus.Output)) {
        Write-Host ("[CODEX] Error: pre-dispatch tree check failed. The working tree at " + $WorkingDir + " holds uncommitted changes the specialist did not author.") -ForegroundColor Red
        foreach ($line in ($gitStatus.Output -split "`n")) {
            if (-not [string]::IsNullOrWhiteSpace($line)) {
                Write-Host ("  " + $line)
            }
        }
        Write-Host "Establish provenance first: commit or stash the changes, or pass -AllowDirtyTree to dispatch onto this tree deliberately (you then own its provenance)." -ForegroundColor Yellow
        exit 2
    }
}

if ([string]::IsNullOrWhiteSpace($Role)) {
    $Role = Get-RoleForPhase -PhaseName $Phase
}

$sessionDir = Join-Path $REPO_ROOT (Join-Path $CrucibleRoot (Join-Path "session" (Join-Path $TaskId $Phase)))
if (-not (Test-Path -LiteralPath $sessionDir)) {
    New-Item -ItemType Directory -Path $sessionDir -Force | Out-Null
}
$lastMsgPath   = Join-Path $sessionDir "codex-last-message.txt"
$transcriptPath = Join-Path $sessionDir "codex-transcript.txt"
if (Test-Path -LiteralPath $lastMsgPath) { Remove-Item -LiteralPath $lastMsgPath -Force }

$useSchema = $false
if ($ReviewSchema) {
    if (-not (Test-Path -LiteralPath $schemaPath)) {
        Write-Host ("[CODEX] Error: -ReviewSchema set but schema not found at " + $schemaPath) -ForegroundColor Red
        exit 2
    }
    $useSchema = $true
}

if (-not [string]::IsNullOrWhiteSpace($PromptText) -and -not [string]::IsNullOrWhiteSpace($PromptFile)) {
    Write-Host "[CODEX] Error: -PromptText and -PromptFile are mutually exclusive." -ForegroundColor Red
    exit 2
}
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
}

if ([string]::IsNullOrWhiteSpace($PromptText)) {
    $PromptText = New-BootstrapPrompt -RoleLabel $Role -TaskIdValue $TaskId -PhaseValue $Phase `
        -CrucibleRootValue $CrucibleRoot -RequireJsonVerdict $useSchema
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
Write-Host ("[CODEX SPECIALIST] Launching " + $Role + " for " + $TaskId + " (" + $Phase + ")") -ForegroundColor Cyan
$rootSource = if ([string]::IsNullOrWhiteSpace($ProjectRoot)) { "derived from script location" } else { "from -ProjectRoot" }
Write-Host ("  project root: " + $REPO_ROOT + "  (" + $rootSource + ")")
Write-Host ("  model: " + $Model + "  |  access: danger-full-access  |  workdir: " + $WorkingDir)
if ($useSchema) { Write-Host "  review verdict schema: enforced" }

$result = Invoke-CodexExec -CodexArgs $codexArgs -Prompt $PromptText -TranscriptPath $transcriptPath

if (-not (Test-Path -LiteralPath $sessionDir)) {
    New-Item -ItemType Directory -Path $sessionDir -Force | Out-Null
}

# --- Classification: SUCCESS vs LAUNCH_FAILED ---
# A codex exec run that exits 0 AND captures a final message succeeded: codex's own auth/runtime
# failures exit non-zero and write no last-message. The infra-marker scan is therefore consulted
# only to ENRICH the reason on an already-failed run (exit != 0), never as an independent trigger
# over a 0-exit run. Broad markers ("unauthorized", "command not found", "program not found")
# occur routinely in the agent's own captured tool output (test names, log lines, source it read)
# and scanning a full transcript would false-positive a successful phase as LAUNCH_FAILED.
$lastMsg = ""
if (Test-Path -LiteralPath $lastMsgPath) {
    $lastMsg = (Get-Content -LiteralPath $lastMsgPath -Raw -ErrorAction SilentlyContinue)
    if ($null -eq $lastMsg) { $lastMsg = "" }
}

$failReason = ""
if ($result.ExitCode -eq 127) {
    $failReason = "codex not found on PATH"
} elseif ($result.ExitCode -ne 0) {
    $marker = Test-InfraFailure -Text $result.Output
    if ($null -ne $marker) {
        $failReason = "infrastructure failure (exit $($result.ExitCode), marker: $marker)"
    } else {
        $failReason = "non-zero exit code ($($result.ExitCode))"
    }
} elseif ($useSchema) {
    $verdictOk = $false
    if (-not [string]::IsNullOrWhiteSpace($lastMsg)) {
        try {
            $parsed = $lastMsg | ConvertFrom-Json
            if ($null -ne $parsed -and $parsed.PSObject.Properties["verdict"]) {
                $v = [string]$parsed.verdict
                if ($v -eq "APPROVED" -or $v -eq "CHANGES_REQUESTED") { $verdictOk = $true }
            }
        } catch {
            $verdictOk = $false
        }
    }
    if (-not $verdictOk) {
        $failReason = "final message is not a valid review verdict (verdict not APPROVED/CHANGES_REQUESTED)"
    }
}

Write-Host ""
if ([string]::IsNullOrWhiteSpace($failReason)) {
    Write-Host "[CODEX SPECIALIST] STATUS=SUCCESS" -ForegroundColor Green
    Write-Host ("  exit code: " + $result.ExitCode)
    Write-Host ("  last message: " + $lastMsgPath)
    Write-Host ("  transcript: " + $transcriptPath)
    Write-Host ""
    Write-Host "  The Codex run completed. Now verify the handoff JSON + task.md checkpoints"
    Write-Host "  per the orchestrator SOP before trusting any verdict."
    exit 0
} else {
    Write-Host "[CODEX SPECIALIST] STATUS=LAUNCH_FAILED" -ForegroundColor Red
    Write-Host ("  reason: " + $failReason)
    Write-Host ("  exit code: " + $result.ExitCode)
    Write-Host ("  transcript: " + $transcriptPath)
    Write-Host ""
    Write-Host "  This is an INFRASTRUCTURE failure, NOT a review verdict. Do not record it as"
    Write-Host "  CHANGES_REQUESTED. Re-run launch-codex-specialist.ps1 -Preflight, fix the"
    Write-Host "  runtime/auth, then re-dispatch; or escalate to the human."
    exit 1
}
