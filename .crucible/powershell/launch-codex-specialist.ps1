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

    # Reviewer phases only: enforce the structured review-verdict schema on Codex's final message.
    [switch]$ReviewSchema,

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
    param([string]$Candidate)
    if (-not [string]::IsNullOrWhiteSpace($Candidate)) {
        if (-not (Test-Path -LiteralPath $Candidate)) {
            throw "ProjectRoot path does not exist: $Candidate"
        }
        return (Resolve-Path -LiteralPath $Candidate).Path
    }
    return (Get-Location).Path
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

function Invoke-CodexExec {
    param(
        [string[]]$CodexArgs,
        [string]$Prompt,
        [string]$TranscriptPath
    )
    if (-not (Get-Command "codex" -ErrorAction SilentlyContinue)) {
        return [PSCustomObject]@{ ExitCode = 127; Output = "'codex' was not found on PATH." }
    }
    $allArgs = @("exec") + $CodexArgs + @($Prompt)
    $previous = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        # codex exec reads stdin IN ADDITION to the prompt arg and blocks on EOF. When this
        # launcher runs with an inherited open stdin (the normal orchestrator/tool context),
        # codex hangs forever on "Reading additional input from stdin...". Piping $null hands
        # codex an immediately-closed stdin so it proceeds from the prompt arg alone. Required
        # to prevent the hang; do not remove.
        $output = $null | & codex @allArgs 2>&1 | Out-String
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previous
    }
    if (-not [string]::IsNullOrWhiteSpace($TranscriptPath)) {
        [System.IO.File]::WriteAllText($TranscriptPath, $output, (New-Object System.Text.UTF8Encoding($false)))
    }
    return [PSCustomObject]@{ ExitCode = $exitCode; Output = $output }
}

$REPO_ROOT = Resolve-ProjectRoot -Candidate $ProjectRoot

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
Write-Host ("  model: " + $Model + "  |  access: danger-full-access  |  workdir: " + $WorkingDir)
if ($useSchema) { Write-Host "  review verdict schema: enforced" }

$result = Invoke-CodexExec -CodexArgs $codexArgs -Prompt $PromptText -TranscriptPath $transcriptPath

# --- Classification: SUCCESS vs LAUNCH_FAILED ---
$infra = Test-InfraFailure -Text $result.Output
$lastMsg = ""
if (Test-Path -LiteralPath $lastMsgPath) {
    $lastMsg = (Get-Content -LiteralPath $lastMsgPath -Raw -ErrorAction SilentlyContinue)
    if ($null -eq $lastMsg) { $lastMsg = "" }
}

$failReason = ""
if ($result.ExitCode -eq 127) {
    $failReason = "codex not found on PATH"
} elseif ($null -ne $infra) {
    $failReason = "infrastructure failure (marker: $infra)"
} elseif ($result.ExitCode -ne 0) {
    $failReason = "non-zero exit code ($($result.ExitCode))"
} elseif ([string]::IsNullOrWhiteSpace($lastMsg)) {
    $failReason = "no final message captured (--output-last-message empty)"
} elseif ($useSchema) {
    $verdictOk = $false
    try {
        $parsed = $lastMsg | ConvertFrom-Json
        if ($null -ne $parsed -and $parsed.PSObject.Properties["verdict"]) {
            $v = [string]$parsed.verdict
            if ($v -eq "APPROVED" -or $v -eq "CHANGES_REQUESTED") { $verdictOk = $true }
        }
    } catch {
        $verdictOk = $false
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
