$ErrorActionPreference = "Stop"
$REPO_ROOT = (Resolve-Path -Path "$PSScriptRoot/../..").Path
. (Join-Path $PSScriptRoot '_harness.ps1')
. (Join-Path $REPO_ROOT "powershell/lib/platform.ps1")
$LAUNCHER = Join-Path $REPO_ROOT "powershell/launch-codex-specialist.ps1"

$results = @()

# Writes a fake `codex` onto PATH whose behavior is driven by the CODEX_FAKE_MODE env var.
# Both OS wrappers delegate to a shared pwsh impl so arg parsing is identical and robust.
function Write-FakeCodex {
    param([string]$BinDir)
    New-Item -ItemType Directory -Path $BinDir -Force | Out-Null
    $impl = Join-Path $BinDir "codex-impl.ps1"
    (@'
$mode = $env:CODEX_FAKE_MODE
if ([string]::IsNullOrWhiteSpace($mode)) { $mode = "success" }
$outFile = ""
for ($i = 0; $i -lt $args.Count; $i++) {
    if ($args[$i] -eq "--output-last-message" -and ($i + 1) -lt $args.Count) { $outFile = $args[$i + 1] }
}
$enc = New-Object System.Text.UTF8Encoding($false)
Write-Output ("ARGS: " + ($args -join " "))
switch ($mode) {
    "infra" {
        [Console]::Error.WriteLine("orchestrator_helper_launch_failed: program not found")
        exit 1
    }
    "empty" {
        Write-Output "fake codex ran CRUCIBLE_OK"
        if ($outFile) { [System.IO.File]::WriteAllText($outFile, "", $enc) }
        exit 0
    }
    "badverdict" {
        Write-Output "fake codex ran CRUCIBLE_OK"
        if ($outFile) { [System.IO.File]::WriteAllText($outFile, "this is not a verdict", $enc) }
        exit 0
    }
    "markerok" {
        # Exit 0 with a valid final message but emit infra-marker words in the transcript,
        # mimicking real agent tool output (a Go test name, a 'dashboard: unauthorized' log
        # line). Must classify SUCCESS: the marker scan must not fire on a 0-exit run.
        Write-Output "test PASS: Is transient error unauthorized"
        Write-Output "dashboard: unauthorized access attempt logged; command not found in old path"
        Write-Output "fake codex transcript CRUCIBLE_OK"
        if ($outFile) { [System.IO.File]::WriteAllText($outFile, '{"verdict":"APPROVED","summary":"ok","findings":[]}', $enc) }
        exit 0
    }
    "vanishrestore" {
        # Mimic a full-access codex run that deletes the gitignored session dir before the
        # launcher writes its transcript. The launcher must recreate the dir, write the
        # transcript, and still classify SUCCESS (non-schema exit-0). No last-message restore
        # is needed - a missing last message is informational for a non-schema phase.
        Write-Output "fake codex transcript CRUCIBLE_OK"
        if ($outFile) {
            $sessionDir = Split-Path -Parent $outFile
            [System.IO.File]::WriteAllText($outFile, '{"verdict":"APPROVED","summary":"ok","findings":[]}', $enc)
            Remove-Item -LiteralPath $sessionDir -Recurse -Force
        }
        exit 0
    }
    "echostdin" {
        # Capture the prompt exactly as codex would receive it on stdin, so a test can prove the
        # launcher feeds the prompt via stdin (not argv) and that embedded quotes survive intact.
        $stdin = [Console]::In.ReadToEnd()
        Write-Output ("STDIN_BEGIN>>>" + $stdin + "<<<STDIN_END")
        if ($outFile) { [System.IO.File]::WriteAllText($outFile, '{"verdict":"APPROVED","summary":"ok","findings":[]}', $enc) }
        exit 0
    }
    "statusprobe" {
        # Report the launch status file as the launcher left it while codex runs.
        $statusFile = Join-Path (Split-Path -Parent $outFile) "codex-launch-status.txt"
        $statusText = if (Test-Path -LiteralPath $statusFile) { [System.IO.File]::ReadAllText($statusFile) } else { "<missing>" }
        Write-Output ("STATUS_DURING_BEGIN>>>" + $statusText + "<<<STATUS_DURING_END")
        if ($outFile) { [System.IO.File]::WriteAllText($outFile, '{"verdict":"APPROVED","summary":"ok","findings":[]}', $enc) }
        exit 0
    }
    "stdinprobe" {
        # Mimic real codex reading stdin: report whether stdin reaches EOF promptly.
        # If the launcher closes codex stdin (the fix), EOF is immediate -> STDIN_EOF.
        # If stdin is left open (the bug), the async read does not complete -> STDIN_OPEN.
        $t = [Console]::In.ReadToEndAsync()
        if ($t.Wait(3000)) { Write-Output "CRUCIBLE_OK STDIN_EOF" } else { Write-Output "CRUCIBLE_OK STDIN_OPEN" }
        if ($outFile) { [System.IO.File]::WriteAllText($outFile, '{"verdict":"APPROVED","summary":"ok","findings":[]}', $enc) }
        exit 0
    }
    { $_ -in @("halfadvance", "fulladvance") } {
        # Mimic the specialist's crucible.ps1 -Init in the task's pipeline log. halfadvance is
        # the run Codex killed mid-advance: the phase ended, the next one never started.
        $phaseDir = Split-Path -Parent $outFile
        $phaseName = Split-Path -Leaf $phaseDir
        $taskDir = Split-Path -Parent $phaseDir
        $taskName = Split-Path -Leaf $taskDir
        $ts = [datetime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ", [System.Globalization.CultureInfo]::InvariantCulture)
        $events = @('{"event":"session_end","task_id":"' + $taskName + '","phase":"' + $phaseName + '","timestamp":"' + $ts + '","outcome":"success","notes":"Handoff to deployment"}')
        if ($mode -eq "fulladvance") {
            $events += '{"event":"session_start","task_id":"' + $taskName + '","phase":"deployment","timestamp":"' + $ts + '"}'
        }
        [System.IO.File]::AppendAllText((Join-Path $taskDir "pipeline.log.jsonl"), (($events -join "`n") + "`n"), $enc)
        Write-Output "fake codex transcript CRUCIBLE_OK"
        if ($outFile) { [System.IO.File]::WriteAllText($outFile, "Approved. Handoff created for deployment.", $enc) }
        exit 0
    }
    default {
        Write-Output "fake codex transcript CRUCIBLE_OK"
        if ($outFile) { [System.IO.File]::WriteAllText($outFile, '{"verdict":"APPROVED","summary":"ok","findings":[]}', $enc) }
        exit 0
    }
}
'@ -replace "`r`n", "`n") | Set-Content -LiteralPath $impl -Encoding ASCII

    if (Test-PlatformIsWindows) {
        $hostCmd = (Get-PwshCommand)
        @(
            '@echo off',
            ('"' + $hostCmd + '" -NoProfile -ExecutionPolicy Bypass -File "%~dp0codex-impl.ps1" %*'),
            'exit /b %errorlevel%'
        ) | Set-Content -LiteralPath (Join-Path $BinDir "codex.cmd") -Encoding ASCII
    } else {
        $codexPath = Join-Path $BinDir "codex"
        $hostCmd = (Get-PwshCommand)
        (@"
#!/usr/bin/env bash
exec $hostCmd -NoProfile -ExecutionPolicy Bypass -File "`$(dirname "`$0")/codex-impl.ps1" "`$@"
"@ -replace "`r`n", "`n") | Set-Content -LiteralPath $codexPath -Encoding ASCII
        & chmod "+x" $codexPath
    }
}

function Invoke-Launcher {
    param([string[]]$LauncherArgs, [string]$Mode, [string]$BinDir)
    $originalPath = $env:PATH
    $originalMode = $env:CODEX_FAKE_MODE
    try {
        $env:PATH = $BinDir + [System.IO.Path]::PathSeparator + $originalPath
        $env:CODEX_FAKE_MODE = $Mode
        return Invoke-ExternalCommand {
            & (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $LAUNCHER @LauncherArgs
        }
    } finally {
        $env:PATH = $originalPath
        $env:CODEX_FAKE_MODE = $originalMode
    }
}

function Invoke-TestGit {
    param([string]$Directory, [string[]]$GitArgs)
    $previous = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $output = & git -C $Directory @GitArgs 2>$null
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previous
    }
    if ($exitCode -ne 0) {
        throw ("git " + ($GitArgs -join " ") + " failed with exit " + $exitCode + ". Output:`n" + (($output | Out-String).Trim()))
    }
    return $output
}

function New-TestGitProject {
    param([string]$Root)
    New-Item -ItemType Directory -Path (Join-Path $Root ".crucible") -Force | Out-Null
    Invoke-TestGit -Directory $Root -GitArgs @("init") | Out-Null
    Invoke-TestGit -Directory $Root -GitArgs @("config", "user.email", "crucible-test@example.invalid") | Out-Null
    Invoke-TestGit -Directory $Root -GitArgs @("config", "user.name", "Crucible Test") | Out-Null
    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText((Join-Path $Root "README.md"), "clean baseline`n", $enc)
    [System.IO.File]::WriteAllText((Join-Path $Root ".crucible/.keep"), "keep`n", $enc)
    Invoke-TestGit -Directory $Root -GitArgs @("add", ".") | Out-Null
    Invoke-TestGit -Directory $Root -GitArgs @("commit", "-m", "initial") | Out-Null
}

$tempRoot = New-TestFixtureRoot -NameHint "launch-codex-test"
$binDir = Join-Path $tempRoot "fake-bin"
Write-FakeCodex -BinDir $binDir

try {
    $results += Run-Test -Name "Preflight PASS on a healthy runtime" -Body {
        $res = Invoke-Launcher -Mode "success" -BinDir $binDir -LauncherArgs @("-Preflight", "-Model", "gpt-6-sol")
        Assert-Result -Name "preflight pass line" -Condition ($res.Output -match "\[CODEX PREFLIGHT\] PASS") -FailureMessage "expected PASS. Output:`n$($res.Output)"
        Assert-Result -Name "preflight exit 0" -Condition ($res.ExitCode -eq 0) -FailureMessage "expected exit 0, got $($res.ExitCode). Output:`n$($res.Output)"
    }

    $results += Run-Test -Name "Launcher closes codex stdin so codex exec cannot hang on inherited open stdin" -Body {
        # Start the launcher with an explicitly OPEN, never-written stdin. Real codex reads
        # stdin in addition to the prompt arg and blocks on EOF; the launcher must hand codex
        # a closed stdin (the $null pipe) regardless of its own inherited stdin. The fake codex
        # 'stdinprobe' mode records STDIN_EOF (stdin closed promptly) or STDIN_OPEN into the
        # captured transcript. Bounded by the fake's 3s async read, so removal of the fix fails
        # (STDIN_OPEN) rather than hanging the suite.
        $projectRoot = Join-Path $tempRoot "proj-stdin"
        New-Item -ItemType Directory -Path (Join-Path $projectRoot ".crucible") -Force | Out-Null
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = (Get-PwshCommand)
        $psi.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $LAUNCHER + '"' +
            ' -TaskId C-998 -Phase verification -Model gpt-6-sol -PromptText "REVIEW" -ProjectRoot "' + $projectRoot + '"'
        $psi.UseShellExecute = $false
        $psi.RedirectStandardInput = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.EnvironmentVariables["PATH"] = $binDir + [System.IO.Path]::PathSeparator + $env:PATH
        $psi.EnvironmentVariables["CODEX_FAKE_MODE"] = "stdinprobe"
        $proc = [System.Diagnostics.Process]::Start($psi)
        $exited = $false
        try {
            $exited = $proc.WaitForExit(20000)
            if (-not $exited) { try { $proc.Kill() } catch {} }
            [void]$proc.StandardOutput.ReadToEnd()
            [void]$proc.StandardError.ReadToEnd()
        } finally {
            try { $proc.StandardInput.Close() } catch {}
            try { $proc.Dispose() } catch {}
        }
        Assert-Result -Name "launcher exits (no hang)" -Condition $exited -FailureMessage "launcher did not exit; codex stdin left open."
        $transcript = Join-Path $projectRoot ".crucible/session/C-998/verification/codex-transcript.txt"
        Assert-Result -Name "transcript written" -Condition (Test-Path -LiteralPath $transcript) -FailureMessage "expected transcript at $transcript"
        $tx = Get-Content -LiteralPath $transcript -Raw
        Assert-Result -Name "codex received closed stdin (EOF)" -Condition ($tx -match "STDIN_EOF") -FailureMessage "expected STDIN_EOF (launcher must close codex stdin). transcript=$tx"
        Assert-Result -Name "codex stdin not left open" -Condition (-not ($tx -match "STDIN_OPEN")) -FailureMessage "codex stdin was left open. transcript=$tx"
    }

    $results += Run-Test -Name "Preflight FAIL on an infra-broken runtime" -Body {
        $res = Invoke-Launcher -Mode "infra" -BinDir $binDir -LauncherArgs @("-Preflight", "-Model", "gpt-6-sol")
        Assert-Result -Name "preflight fail line" -Condition ($res.Output -match "\[CODEX PREFLIGHT\] FAIL") -FailureMessage "expected FAIL. Output:`n$($res.Output)"
        Assert-Result -Name "infra reason surfaced" -Condition ($res.Output -match "infra marker") -FailureMessage "expected infra marker reason. Output:`n$($res.Output)"
        Assert-Result -Name "preflight exit 1" -Condition ($res.ExitCode -eq 1) -FailureMessage "expected exit 1, got $($res.ExitCode). Output:`n$($res.Output)"
    }

    $results += Run-Test -Name "Preflight FAIL when codex is absent from PATH" -Body {
        # Run with a PATH that has the host but no codex shim.
        $originalPath = $env:PATH
        if (Test-PlatformIsWindows) {
            $sep = [System.IO.Path]::PathSeparator
            $codexNames = @("codex.exe", "codex.cmd", "codex.bat", "codex")
            $scopedPath = (($originalPath.Split($sep) | Where-Object {
                $d = $_
                ($d -ne "") -and -not ($codexNames | Where-Object { Test-Path -LiteralPath (Join-Path $d $_) -ErrorAction SilentlyContinue })
            }) -join $sep)
        } else {
            $cleanBin = Join-Path $tempRoot ("nocodex-" + [guid]::NewGuid().ToString("N"))
            New-Item -ItemType Directory -Path $cleanBin -Force | Out-Null
            $resolved = Get-Command (Get-PwshCommand) -ErrorAction SilentlyContinue
            if ($resolved) { New-Item -ItemType SymbolicLink -Path (Join-Path $cleanBin (Get-PwshCommand)) -Target $resolved.Source | Out-Null }
            $scopedPath = $cleanBin
        }
        try {
            $env:PATH = $scopedPath
            $res = Invoke-ExternalCommand {
                & (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $LAUNCHER -Preflight -Model "gpt-6-sol"
            }
        } finally {
            $env:PATH = $originalPath
        }
        Assert-Result -Name "fail on absent codex" -Condition ($res.Output -match "\[CODEX PREFLIGHT\] FAIL") -FailureMessage "expected FAIL when codex absent. Output:`n$($res.Output)"
        Assert-Result -Name "absent reason" -Condition ($res.Output -match "codex not on PATH") -FailureMessage "expected 'codex not on PATH' reason. Output:`n$($res.Output)"
    }

    $results += Run-Test -Name "Phase launch SUCCESS writes verdict + transcript" -Body {
        $projectRoot = Join-Path $tempRoot "proj-success"
        New-Item -ItemType Directory -Path (Join-Path $projectRoot ".crucible") -Force | Out-Null
        $res = Invoke-Launcher -Mode "success" -BinDir $binDir -LauncherArgs @(
            "-TaskId", "C-999", "-Phase", "verification", "-Model", "gpt-6-sol",
            "-PromptText", "REVIEW THIS TASK", "-ProjectRoot", $projectRoot)
        Assert-Result -Name "status success" -Condition ($res.Output -match "\[CODEX SPECIALIST\] STATUS=SUCCESS") -FailureMessage "expected SUCCESS. Output:`n$($res.Output)"
        Assert-Result -Name "exit 0" -Condition ($res.ExitCode -eq 0) -FailureMessage "expected exit 0, got $($res.ExitCode). Output:`n$($res.Output)"
        $lastMsg = Join-Path $projectRoot ".crucible/session/C-999/verification/codex-last-message.txt"
        $transcript = Join-Path $projectRoot ".crucible/session/C-999/verification/codex-transcript.txt"
        Assert-Result -Name "last message written" -Condition (Test-Path -LiteralPath $lastMsg) -FailureMessage "no last-message file"
        Assert-Result -Name "transcript written" -Condition (Test-Path -LiteralPath $transcript) -FailureMessage "no transcript file"
    }

    # A host shell lost the launcher's stdout in the gobot C-387 run while the launch finished.
    # The status file is the durable copy of the STATUS line. Item 167.
    $results += Run-Test -Name "Launch status file reads RUNNING during the run and the final STATUS after it" -Body {
        $projectRoot = Join-Path $tempRoot "proj-statusfile"
        New-Item -ItemType Directory -Path (Join-Path $projectRoot ".crucible") -Force | Out-Null
        $res = Invoke-Launcher -Mode "statusprobe" -BinDir $binDir -LauncherArgs @(
            "-TaskId", "C-976", "-Phase", "verification", "-Model", "gpt-6-sol", "-Effort", "low",
            "-PromptText", "REVIEW", "-ProjectRoot", $projectRoot)
        $statusFile = Join-Path $projectRoot ".crucible/session/C-976/verification/codex-launch-status.txt"
        $transcript = Get-Content -LiteralPath (Join-Path $projectRoot ".crucible/session/C-976/verification/codex-transcript.txt") -Raw
        $during = ""
        if ($transcript -match "(?s)STATUS_DURING_BEGIN>>>(.*)<<<STATUS_DURING_END") { $during = $Matches[1] }
        Assert-Result -Name "running while codex runs" -Condition ($during.StartsWith("STATUS=RUNNING")) -FailureMessage "expected STATUS=RUNNING while codex ran, saw: $during"
        Assert-Result -Name "running names the launcher process" -Condition ($during -match "launcher_pid: \d+") -FailureMessage "RUNNING does not name the launcher process: $during"
        Assert-Result -Name "running names the level" -Condition ($during.Contains("level: gpt-6-sol at low effort")) -FailureMessage "RUNNING does not name the level: $during"
        $final = [System.IO.File]::ReadAllText($statusFile)
        Assert-Result -Name "final status success" -Condition ($final.StartsWith("STATUS=SUCCESS") -and $final.Contains("exit code: 0")) -FailureMessage "expected STATUS=SUCCESS and exit code 0 after the run, saw: $final"
        Assert-Result -Name "exit 0" -Condition ($res.ExitCode -eq 0) -FailureMessage "expected exit 0, got $($res.ExitCode). Output:`n$($res.Output)"
    }

    $results += Run-Test -Name "Launch status file records LAUNCH_FAILED with its reason" -Body {
        $projectRoot = Join-Path $tempRoot "proj-statusfile-infra"
        New-Item -ItemType Directory -Path (Join-Path $projectRoot ".crucible") -Force | Out-Null
        $res = Invoke-Launcher -Mode "infra" -BinDir $binDir -LauncherArgs @(
            "-TaskId", "C-975", "-Phase", "verification", "-Model", "gpt-6-sol",
            "-PromptText", "REVIEW", "-ProjectRoot", $projectRoot)
        $final = [System.IO.File]::ReadAllText((Join-Path $projectRoot ".crucible/session/C-975/verification/codex-launch-status.txt"))
        Assert-Result -Name "final status launch_failed" -Condition ($final.StartsWith("STATUS=LAUNCH_FAILED") -and $final.Contains("reason: infrastructure failure")) -FailureMessage "expected STATUS=LAUNCH_FAILED with its reason, saw: $final"
        Assert-Result -Name "exit 1" -Condition ($res.ExitCode -eq 1) -FailureMessage "expected exit 1, got $($res.ExitCode)."
    }

    $results += Run-Test -Name "Dirty git tree blocks specialist dispatch without override" -Body {
        $projectRoot = Join-Path $tempRoot "proj-dirty-block"
        New-TestGitProject -Root $projectRoot
        $enc = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText((Join-Path $projectRoot "dirty.txt"), "uncommitted`n", $enc)
        $res = Invoke-Launcher -Mode "success" -BinDir $binDir -LauncherArgs @(
            "-TaskId", "C-980", "-Phase", "verification", "-Model", "gpt-6-sol",
            "-PromptText", "REVIEW", "-ProjectRoot", $projectRoot)
        $transcript = Join-Path $projectRoot ".crucible/session/C-980/verification/codex-transcript.txt"
        Assert-Result -Name "dirty guard exit 2" -Condition ($res.ExitCode -eq 2) -FailureMessage "expected exit 2, got $($res.ExitCode). Output:`n$($res.Output)"
        Assert-Result -Name "dirty guard error" -Condition ($res.Output -match "pre-dispatch tree check failed") -FailureMessage "expected tree-check error. Output:`n$($res.Output)"
        Assert-Result -Name "dirty file surfaced" -Condition ($res.Output -match "dirty\.txt") -FailureMessage "expected porcelain dirty path. Output:`n$($res.Output)"
        Assert-Result -Name "no specialist status" -Condition (-not ($res.Output -match "\[CODEX SPECIALIST\] STATUS=")) -FailureMessage "guard must block before specialist status. Output:`n$($res.Output)"
        Assert-Result -Name "no transcript" -Condition (-not (Test-Path -LiteralPath $transcript)) -FailureMessage "guard must block before transcript is written at $transcript"
    }

    $results += Run-Test -Name "Dirty git tree dispatches with AllowDirtyTree override" -Body {
        $projectRoot = Join-Path $tempRoot "proj-dirty-override"
        New-TestGitProject -Root $projectRoot
        $enc = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText((Join-Path $projectRoot "dirty.txt"), "uncommitted`n", $enc)
        $res = Invoke-Launcher -Mode "success" -BinDir $binDir -LauncherArgs @(
            "-TaskId", "C-979", "-Phase", "verification", "-Model", "gpt-6-sol",
            "-PromptText", "REVIEW", "-ProjectRoot", $projectRoot, "-AllowDirtyTree")
        Assert-Result -Name "override status line" -Condition ($res.Output -match "\[CODEX SPECIALIST\] STATUS=SUCCESS") -FailureMessage "expected SUCCESS with override. Output:`n$($res.Output)"
        Assert-Result -Name "override exit 0" -Condition ($res.ExitCode -eq 0) -FailureMessage "expected exit 0, got $($res.ExitCode). Output:`n$($res.Output)"
    }

    $results += Run-Test -Name "Clean git tree dispatches normally" -Body {
        $projectRoot = Join-Path $tempRoot "proj-clean-git"
        New-TestGitProject -Root $projectRoot
        $res = Invoke-Launcher -Mode "success" -BinDir $binDir -LauncherArgs @(
            "-TaskId", "C-978", "-Phase", "verification", "-Model", "gpt-6-sol",
            "-PromptText", "REVIEW", "-ProjectRoot", $projectRoot)
        Assert-Result -Name "clean status line" -Condition ($res.Output -match "\[CODEX SPECIALIST\] STATUS=SUCCESS") -FailureMessage "expected SUCCESS on clean git tree. Output:`n$($res.Output)"
        Assert-Result -Name "clean exit 0" -Condition ($res.ExitCode -eq 0) -FailureMessage "expected exit 0, got $($res.ExitCode). Output:`n$($res.Output)"
    }

    $results += Run-Test -Name "Non-git WorkingDir skips tree guard and dispatches" -Body {
        $projectRoot = Join-Path $tempRoot "proj-non-git-skip"
        New-Item -ItemType Directory -Path (Join-Path $projectRoot ".crucible") -Force | Out-Null
        $res = Invoke-Launcher -Mode "success" -BinDir $binDir -LauncherArgs @(
            "-TaskId", "C-977", "-Phase", "verification", "-Model", "gpt-6-sol",
            "-PromptText", "REVIEW", "-ProjectRoot", $projectRoot)
        Assert-Result -Name "skip note" -Condition ($res.Output -match "WorkingDir is not a git work tree") -FailureMessage "expected non-git skip note. Output:`n$($res.Output)"
        Assert-Result -Name "non-git status line" -Condition ($res.Output -match "\[CODEX SPECIALIST\] STATUS=SUCCESS") -FailureMessage "expected SUCCESS for non-git WorkingDir. Output:`n$($res.Output)"
        Assert-Result -Name "non-git exit 0" -Condition ($res.ExitCode -eq 0) -FailureMessage "expected exit 0, got $($res.ExitCode). Output:`n$($res.Output)"
    }

    $results += Run-Test -Name "Phase launch SUCCESS when session dir vanishes before transcript write" -Body {
        $projectRoot = Join-Path $tempRoot "proj-vanishrestore"
        New-Item -ItemType Directory -Path (Join-Path $projectRoot ".crucible") -Force | Out-Null
        $res = Invoke-Launcher -Mode "vanishrestore" -BinDir $binDir -LauncherArgs @(
            "-TaskId", "C-981", "-Phase", "verification", "-Model", "gpt-6-sol",
            "-PromptText", "REVIEW", "-ProjectRoot", $projectRoot)
        Assert-Result -Name "status line printed" -Condition ($res.Output -match "\[CODEX SPECIALIST\] STATUS=") -FailureMessage "expected STATUS line after vanished session dir. Output:`n$($res.Output)"
        Assert-Result -Name "status success" -Condition ($res.Output -match "\[CODEX SPECIALIST\] STATUS=SUCCESS") -FailureMessage "expected SUCCESS after vanished session dir. Output:`n$($res.Output)"
        Assert-Result -Name "no unhandled transcript exception" -Condition (-not ($res.Output -match "DirectoryNotFoundException|Could not find a part of the path|Exception calling `"WriteAllText`"")) -FailureMessage "transcript write failure must not abort. Output:`n$($res.Output)"
        Assert-Result -Name "exit 0" -Condition ($res.ExitCode -eq 0) -FailureMessage "expected exit 0, got $($res.ExitCode). Output:`n$($res.Output)"
        $transcript = Join-Path $projectRoot ".crucible/session/C-981/verification/codex-transcript.txt"
        Assert-Result -Name "transcript written after recreation" -Condition (Test-Path -LiteralPath $transcript) -FailureMessage "expected transcript at $transcript. Output:`n$($res.Output)"
    }

    $results += Run-Test -Name "Arg assembly carries full-access flags + model + output capture" -Body {
        $projectRoot = Join-Path $tempRoot "proj-args"
        New-Item -ItemType Directory -Path (Join-Path $projectRoot ".crucible") -Force | Out-Null
        $res = Invoke-Launcher -Mode "success" -BinDir $binDir -LauncherArgs @(
            "-TaskId", "C-998", "-Phase", "verification", "-Model", "gpt-6-sol",
            "-PromptText", "REVIEW", "-ProjectRoot", $projectRoot)
        $transcript = Get-Content -LiteralPath (Join-Path $projectRoot ".crucible/session/C-998/verification/codex-transcript.txt") -Raw
        Assert-Result -Name "danger-full-access" -Condition ($transcript -match "danger-full-access") -FailureMessage "missing -s danger-full-access. Transcript:`n$transcript"
        Assert-Result -Name "skip-git-repo-check" -Condition ($transcript -match "--skip-git-repo-check") -FailureMessage "missing --skip-git-repo-check. Transcript:`n$transcript"
        Assert-Result -Name "model passed" -Condition ($transcript -match "gpt-6-sol") -FailureMessage "missing model. Transcript:`n$transcript"
        Assert-Result -Name "output-last-message passed" -Condition ($transcript -match "--output-last-message") -FailureMessage "missing --output-last-message. Transcript:`n$transcript"
    }

    $results += Run-Test -Name "Phase launch LAUNCH_FAILED on infra failure (never a verdict)" -Body {
        $projectRoot = Join-Path $tempRoot "proj-infra"
        New-Item -ItemType Directory -Path (Join-Path $projectRoot ".crucible") -Force | Out-Null
        $res = Invoke-Launcher -Mode "infra" -BinDir $binDir -LauncherArgs @(
            "-TaskId", "C-997", "-Phase", "verification", "-Model", "gpt-6-sol",
            "-PromptText", "REVIEW", "-ProjectRoot", $projectRoot)
        Assert-Result -Name "status launch_failed" -Condition ($res.Output -match "\[CODEX SPECIALIST\] STATUS=LAUNCH_FAILED") -FailureMessage "expected LAUNCH_FAILED. Output:`n$($res.Output)"
        Assert-Result -Name "infrastructure reason" -Condition ($res.Output -match "infrastructure failure") -FailureMessage "expected infrastructure-failure reason. Output:`n$($res.Output)"
        Assert-Result -Name "not a verdict" -Condition ($res.Output -match "NOT a review verdict") -FailureMessage "expected explicit not-a-verdict guard. Output:`n$($res.Output)"
        Assert-Result -Name "exit 1" -Condition ($res.ExitCode -eq 1) -FailureMessage "expected exit 1, got $($res.ExitCode)."
    }

    $results += Run-Test -Name "Phase launch SUCCESS despite infra-marker words in 0-exit agent output" -Body {
        $projectRoot = Join-Path $tempRoot "proj-markerok"
        New-Item -ItemType Directory -Path (Join-Path $projectRoot ".crucible") -Force | Out-Null
        $res = Invoke-Launcher -Mode "markerok" -BinDir $binDir -LauncherArgs @(
            "-TaskId", "C-992", "-Phase", "research", "-Model", "gpt-6-sol",
            "-PromptText", "RESEARCH", "-ProjectRoot", $projectRoot)
        Assert-Result -Name "marker words do not fail a 0-exit run" -Condition ($res.Output -match "STATUS=SUCCESS") -FailureMessage "0-exit run with marker words in transcript must be SUCCESS. Output:`n$($res.Output)"
        Assert-Result -Name "markerok exit 0" -Condition ($res.ExitCode -eq 0) -FailureMessage "expected exit 0, got $($res.ExitCode). Output:`n$($res.Output)"
    }

    $results += Run-Test -Name "Phase launch SUCCESS on exit 0 with empty final message (non-schema; repo state authoritative)" -Body {
        $projectRoot = Join-Path $tempRoot "proj-empty"
        New-Item -ItemType Directory -Path (Join-Path $projectRoot ".crucible") -Force | Out-Null
        $res = Invoke-Launcher -Mode "empty" -BinDir $binDir -LauncherArgs @(
            "-TaskId", "C-996", "-Phase", "verification", "-Model", "gpt-6-sol",
            "-PromptText", "REVIEW", "-ProjectRoot", $projectRoot)
        Assert-Result -Name "status success empty" -Condition ($res.Output -match "STATUS=SUCCESS") -FailureMessage "expected SUCCESS. Output:`n$($res.Output)"
        Assert-Result -Name "empty exit 0" -Condition ($res.ExitCode -eq 0) -FailureMessage "expected exit 0, got $($res.ExitCode). Output:`n$($res.Output)"
    }

    $results += Run-Test -Name "ReviewSchema accepts a conforming verdict" -Body {
        $projectRoot = Join-Path $tempRoot "proj-schema-ok"
        New-Item -ItemType Directory -Path (Join-Path $projectRoot ".crucible") -Force | Out-Null
        $res = Invoke-Launcher -Mode "success" -BinDir $binDir -LauncherArgs @(
            "-TaskId", "C-995", "-Phase", "verification", "-Model", "gpt-6-sol",
            "-PromptText", "REVIEW", "-ReviewSchema", "-ProjectRoot", $projectRoot)
        Assert-Result -Name "schema success" -Condition ($res.Output -match "STATUS=SUCCESS") -FailureMessage "valid verdict JSON should be SUCCESS. Output:`n$($res.Output)"
        Assert-Result -Name "schema enforced banner" -Condition ($res.Output -match "review verdict schema: enforced") -FailureMessage "expected schema-enforced banner. Output:`n$($res.Output)"
    }

    $results += Run-Test -Name "ReviewSchema rejects a non-verdict final message" -Body {
        $projectRoot = Join-Path $tempRoot "proj-schema-bad"
        New-Item -ItemType Directory -Path (Join-Path $projectRoot ".crucible") -Force | Out-Null
        $res = Invoke-Launcher -Mode "badverdict" -BinDir $binDir -LauncherArgs @(
            "-TaskId", "C-994", "-Phase", "verification", "-Model", "gpt-6-sol",
            "-PromptText", "REVIEW", "-ReviewSchema", "-ProjectRoot", $projectRoot)
        Assert-Result -Name "schema bad launch_failed" -Condition ($res.Output -match "STATUS=LAUNCH_FAILED") -FailureMessage "non-verdict should be LAUNCH_FAILED. Output:`n$($res.Output)"
        Assert-Result -Name "verdict reason" -Condition ($res.Output -match "valid review verdict") -FailureMessage "expected verdict-validation reason. Output:`n$($res.Output)"
    }

    $results += Run-Test -Name "ReviewSchema rejects an empty final message" -Body {
        $projectRoot = Join-Path $tempRoot "proj-schema-empty"
        New-Item -ItemType Directory -Path (Join-Path $projectRoot ".crucible") -Force | Out-Null
        $res = Invoke-Launcher -Mode "empty" -BinDir $binDir -LauncherArgs @(
            "-TaskId", "C-993", "-Phase", "verification", "-Model", "gpt-6-sol",
            "-PromptText", "REVIEW", "-ReviewSchema", "-ProjectRoot", $projectRoot)
        Assert-Result -Name "schema empty launch_failed" -Condition ($res.Output -match "STATUS=LAUNCH_FAILED") -FailureMessage "empty verdict should be LAUNCH_FAILED. Output:`n$($res.Output)"
        Assert-Result -Name "schema empty verdict reason" -Condition ($res.Output -match "valid review verdict") -FailureMessage "expected verdict-validation reason. Output:`n$($res.Output)"
    }

    $results += Run-Test -Name "Default project root derives from script location, not cwd" -Body {
        # Copy the launcher into an adopter-style layout <proj>/.crucible/powershell/ and invoke
        # it WITHOUT -ProjectRoot. The old cwd default resolved the session dir under the caller's
        # cwd, silently dispatching against the wrong repo. The fix must resolve it under <proj>
        # (the repo the script ships in), regardless of the caller's working directory.
        $proj = Join-Path $tempRoot "proj-derived"
        $shipDir = Join-Path $proj ".crucible/powershell"
        New-Item -ItemType Directory -Path $shipDir -Force | Out-Null
        $copied = Join-Path $shipDir "launch-codex-specialist.ps1"
        Copy-Item -LiteralPath $LAUNCHER -Destination $copied -Force
        $originalPath = $env:PATH
        $originalMode = $env:CODEX_FAKE_MODE
        try {
            $env:PATH = $binDir + [System.IO.Path]::PathSeparator + $originalPath
            $env:CODEX_FAKE_MODE = "success"
            $res = Invoke-ExternalCommand {
                & (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $copied `
                    -TaskId "C-991" -Phase "verification" -Model "gpt-6-sol" -PromptText "REVIEW"
            }
        } finally {
            $env:PATH = $originalPath
            $env:CODEX_FAKE_MODE = $originalMode
        }
        Assert-Result -Name "status success" -Condition ($res.Output -match "STATUS=SUCCESS") -FailureMessage "expected SUCCESS. Output:`n$($res.Output)"
        Assert-Result -Name "root derived banner" -Condition ($res.Output -match "derived from script location") -FailureMessage "expected derived-root banner. Output:`n$($res.Output)"
        $sessionUnderProj = Join-Path $proj ".crucible/session/C-991/verification/codex-transcript.txt"
        Assert-Result -Name "session under derived root" -Condition (Test-Path -LiteralPath $sessionUnderProj) -FailureMessage "expected session dir under derived project root at $sessionUnderProj. Output:`n$($res.Output)"
    }

    $results += Run-Test -Name "Prompt is fed on codex stdin, not argv" -Body {
        # Regression: the prompt used to be appended as a positional codex arg. On Windows
        # PowerShell 5.1, native-argument quoting does not escape interior double-quotes, so a
        # prompt containing quotes was split at each quote and codex rejected the fragments
        # ("unexpected argument ... found"), surfacing as a spurious LAUNCH_FAILED. The launcher
        # now pipes the prompt on stdin. This test locks the delivery channel: the prompt body
        # reaches codex on STDIN and never appears in the codex argv. (Exact embedded-quote
        # survival is verified by the live dogfood, not here: this harness passes -PromptText
        # across its own powershell.exe -File hop, which itself strips the quotes before the
        # launcher runs -- the very hazard the stdin fix removes at the launcher->codex boundary.)
        $projectRoot = Join-Path $tempRoot "proj-stdin-prompt"
        New-Item -ItemType Directory -Path (Join-Path $projectRoot ".crucible") -Force | Out-Null
        $res = Invoke-Launcher -Mode "echostdin" -BinDir $binDir -LauncherArgs @(
            "-TaskId", "C-990", "-Phase", "verification", "-Model", "gpt-6-sol",
            "-PromptText", "Verify task (C-990) and mark it now", "-ProjectRoot", $projectRoot)
        Assert-Result -Name "launch succeeds" -Condition ($res.Output -match "STATUS=SUCCESS") -FailureMessage "prompt-on-stdin launch should succeed. Output:`n$($res.Output)"
        $transcript = Get-Content -LiteralPath (Join-Path $projectRoot ".crucible/session/C-990/verification/codex-transcript.txt") -Raw
        Assert-Result -Name "prompt arrived on stdin" -Condition ($transcript -match ([regex]::Escape('STDIN_BEGIN>>>Verify task (C-990) and mark it now'))) -FailureMessage "expected prompt body on stdin. Transcript:`n$transcript"
        $argsLine = ($transcript -split "`n" | Where-Object { $_ -match "^ARGS:" }) -join "`n"
        Assert-Result -Name "prompt not passed as argv" -Condition (-not ($argsLine -match ([regex]::Escape('(C-990)')))) -FailureMessage "prompt text must not appear in codex argv. ARGS:`n$argsLine"
    }

    $results += Run-Test -Name "Missing -Model is rejected" -Body {
        $res = Invoke-Launcher -Mode "success" -BinDir $binDir -LauncherArgs @("-TaskId", "C-993", "-Phase", "verification")
        Assert-Result -Name "model required exit 2" -Condition ($res.ExitCode -eq 2) -FailureMessage "expected exit 2 for missing model, got $($res.ExitCode). Output:`n$($res.Output)"
        Assert-Result -Name "model required message" -Condition ($res.Output -match "-Model is required") -FailureMessage "expected model-required message. Output:`n$($res.Output)"
    }

    $results += Run-Test -Name "Absolute -CrucibleRoot under the repo is relativized (D1)" -Body {
        # Passing an absolute -CrucibleRoot used to produce a malformed Join-Path and a bare
        # 'New-Item : The given path's format is not supported'. When it lives under the repo
        # it must be relativized and the run must proceed normally.
        $projectRoot = Join-Path $tempRoot "proj-crucroot-abs"
        New-Item -ItemType Directory -Path (Join-Path $projectRoot ".crucible") -Force | Out-Null
        $absCrucible = (Resolve-Path -LiteralPath (Join-Path $projectRoot ".crucible")).Path
        $res = Invoke-Launcher -Mode "success" -BinDir $binDir -LauncherArgs @(
            "-TaskId", "C-989", "-Phase", "verification", "-Model", "gpt-6-sol",
            "-PromptText", "REVIEW", "-CrucibleRoot", $absCrucible, "-ProjectRoot", $projectRoot)
        Assert-Result -Name "status success" -Condition ($res.Output -match "STATUS=SUCCESS") -FailureMessage "absolute -CrucibleRoot under repo should be accepted. Output:`n$($res.Output)"
        $sessionUnder = Join-Path $projectRoot ".crucible/session/C-989/verification/codex-transcript.txt"
        Assert-Result -Name "session under relativized root" -Condition (Test-Path -LiteralPath $sessionUnder) -FailureMessage "expected session dir under relativized .crucible at $sessionUnder. Output:`n$($res.Output)"
    }

    $results += Run-Test -Name "Absolute -CrucibleRoot outside the repo is rejected with a clear error (D1)" -Body {
        $projectRoot = Join-Path $tempRoot "proj-crucroot-out"
        New-Item -ItemType Directory -Path (Join-Path $projectRoot ".crucible") -Force | Out-Null
        $outsideCrucible = Join-Path $tempRoot ("outside-" + [guid]::NewGuid().ToString("N"))
        New-Item -ItemType Directory -Path $outsideCrucible -Force | Out-Null
        $res = Invoke-Launcher -Mode "success" -BinDir $binDir -LauncherArgs @(
            "-TaskId", "C-988", "-Phase", "verification", "-Model", "gpt-6-sol",
            "-PromptText", "REVIEW", "-CrucibleRoot", $outsideCrucible, "-ProjectRoot", $projectRoot)
        Assert-Result -Name "exit 2" -Condition ($res.ExitCode -eq 2) -FailureMessage "expected exit 2 for absolute -CrucibleRoot outside repo, got $($res.ExitCode). Output:`n$($res.Output)"
        Assert-Result -Name "clear error" -Condition ($res.Output -match "must be relative to the repo root") -FailureMessage "expected clear relativity error. Output:`n$($res.Output)"
    }

    $results += Run-Test -Name "PromptFile content used verbatim" -Body {
        $projectRoot = Join-Path $tempRoot "proj-promptfile-verbatim"
        New-Item -ItemType Directory -Path (Join-Path $projectRoot ".crucible") -Force | Out-Null
        $promptFilePath = Join-Path $tempRoot "override-prompt.md"
        $promptContent = "Multi-line prompt body`nwith embedded --no-interactive flag`nand `"double-quoted phrase`"."
        [System.IO.File]::WriteAllText($promptFilePath, $promptContent)

        $res = Invoke-Launcher -Mode "echostdin" -BinDir $binDir -LauncherArgs @(
            "-TaskId", "C-987", "-Phase", "verification", "-Model", "gpt-6-sol",
            "-PromptFile", $promptFilePath, "-ProjectRoot", $projectRoot)
        Assert-Result -Name "promptfile launch succeeds" -Condition ($res.Output -match "STATUS=SUCCESS") -FailureMessage "PromptFile launch should succeed. Output:`n$($res.Output)"
        $transcript = Get-Content -LiteralPath (Join-Path $projectRoot ".crucible/session/C-987/verification/codex-transcript.txt") -Raw
        Assert-Result -Name "promptfile contents delivered verbatim on stdin" -Condition ($transcript -match "--no-interactive" -and $transcript -match "double-quoted phrase") -FailureMessage "expected verbatim promptfile contents on stdin. Transcript:`n$transcript"
    }

    $results += Run-Test -Name "Missing PromptFile path exits 2 without codex invocation" -Body {
        $projectRoot = Join-Path $tempRoot "proj-promptfile-missing"
        New-Item -ItemType Directory -Path (Join-Path $projectRoot ".crucible") -Force | Out-Null
        $missingPath = Join-Path $tempRoot "nonexistent-prompt.md"
        $res = Invoke-Launcher -Mode "success" -BinDir $binDir -LauncherArgs @(
            "-TaskId", "C-986", "-Phase", "verification", "-Model", "gpt-6-sol",
            "-PromptFile", $missingPath, "-ProjectRoot", $projectRoot)
        Assert-Result -Name "missing promptfile exit 2" -Condition ($res.ExitCode -eq 2) -FailureMessage "expected exit 2, got $($res.ExitCode). Output:`n$($res.Output)"
        Assert-Result -Name "missing promptfile error message" -Condition ($res.Output -match "-PromptFile path does not exist") -FailureMessage "expected missing promptfile error message. Output:`n$($res.Output)"
    }

    $results += Run-Test -Name "Both -PromptText and -PromptFile exits 2 without codex invocation" -Body {
        $projectRoot = Join-Path $tempRoot "proj-promptfile-both"
        New-Item -ItemType Directory -Path (Join-Path $projectRoot ".crucible") -Force | Out-Null
        $promptFilePath = Join-Path $tempRoot "dummy-prompt.md"
        [System.IO.File]::WriteAllText($promptFilePath, "some prompt")
        $res = Invoke-Launcher -Mode "success" -BinDir $binDir -LauncherArgs @(
            "-TaskId", "C-985", "-Phase", "verification", "-Model", "gpt-6-sol",
            "-PromptText", "text prompt", "-PromptFile", $promptFilePath, "-ProjectRoot", $projectRoot)
        Assert-Result -Name "both prompts exit 2" -Condition ($res.ExitCode -eq 2) -FailureMessage "expected exit 2, got $($res.ExitCode). Output:`n$($res.Output)"
        Assert-Result -Name "both prompts error message" -Condition ($res.Output -match "-PromptText and -PromptFile are mutually exclusive") -FailureMessage "expected mutually exclusive error message. Output:`n$($res.Output)"
    }

    $results += Run-Test -Name "Empty PromptFile exits 2 without codex invocation" -Body {
        $projectRoot = Join-Path $tempRoot "proj-promptfile-empty"
        New-Item -ItemType Directory -Path (Join-Path $projectRoot ".crucible") -Force | Out-Null
        $emptyFilePath = Join-Path $tempRoot "empty-prompt.md"
        [System.IO.File]::WriteAllText($emptyFilePath, "   `r`n  `n ")
        $res = Invoke-Launcher -Mode "success" -BinDir $binDir -LauncherArgs @(
            "-TaskId", "C-984", "-Phase", "verification", "-Model", "gpt-6-sol",
            "-PromptFile", $emptyFilePath, "-ProjectRoot", $projectRoot)
        Assert-Result -Name "empty promptfile exit 2" -Condition ($res.ExitCode -eq 2) -FailureMessage "expected exit 2, got $($res.ExitCode). Output:`n$($res.Output)"
        Assert-Result -Name "empty promptfile error message" -Condition ($res.Output -match "-PromptFile is empty") -FailureMessage "expected empty promptfile error message. Output:`n$($res.Output)"
    }

    $results += Run-Test -Name "Deployment phase forces WorkingDir to project root and emits notice when worktree dir passed" -Body {
        $projectRoot = Join-Path $tempRoot "proj-deploy-wt"
        $wtDir = Join-Path $projectRoot ".crucible/.agent-workspaces/deployment-C-983"
        New-Item -ItemType Directory -Path (Join-Path $projectRoot ".crucible") -Force | Out-Null
        New-Item -ItemType Directory -Path $wtDir -Force | Out-Null
        $res = Invoke-Launcher -Mode "success" -BinDir $binDir -LauncherArgs @(
            "-TaskId", "C-983", "-Phase", "deployment", "-Model", "gpt-6-sol",
            "-PromptText", "DEPLOY", "-ProjectRoot", $projectRoot, "-WorkingDir", $wtDir)
        Assert-Result -Name "deployment status success" -Condition ($res.Output -match "\[CODEX SPECIALIST\] STATUS=SUCCESS") -FailureMessage "expected SUCCESS. Output:`n$($res.Output)"
        Assert-Result -Name "deployment notice emitted" -Condition ($res.Output -match "\[CODEX\] Notice: Deployment phase forces WorkingDir to main repo root") -FailureMessage "expected notice about deployment WorkingDir override. Output:`n$($res.Output)"
        $transcript = Join-Path $projectRoot ".crucible/session/C-983/deployment/codex-transcript.txt"
        Assert-Result -Name "transcript exists" -Condition (Test-Path -LiteralPath $transcript) -FailureMessage "expected transcript at $transcript"
        $tx = Get-Content -LiteralPath $transcript -Raw
        $expectedC = "-C " + $projectRoot
        Assert-Result -Name "codex launched with project root CWD" -Condition ($tx -match [regex]::Escape($expectedC)) -FailureMessage "expected codex -C to be $projectRoot. transcript=$tx"
    }

    $results += Run-Test -Name "-PromptFile alone dispatches and names the session after the file" -Body {
        # On the -PromptFile path, -TaskId/-Phase select no content: New-BootstrapPrompt is never
        # reached. They were still hard-required, so dispatching work that has no task ID (the
        # framework's own TODO items) meant inventing a fake ID to satisfy an argument that only
        # named a directory. Both are now optional here and the session is named after the file.
        $projectRoot = Join-Path $tempRoot "proj-promptfile-adhoc"
        New-Item -ItemType Directory -Path (Join-Path $projectRoot ".crucible") -Force | Out-Null
        $promptFilePath = Join-Path $tempRoot "item-30-brief.md"
        [System.IO.File]::WriteAllText($promptFilePath, "Do the framework work described here.")
        $res = Invoke-Launcher -Mode "echostdin" -BinDir $binDir -LauncherArgs @(
            "-Model", "gpt-6-sol", "-PromptFile", $promptFilePath, "-ProjectRoot", $projectRoot)
        Assert-Result -Name "adhoc launch succeeds" -Condition ($res.Output -match "STATUS=SUCCESS") -FailureMessage "expected SUCCESS without -TaskId/-Phase. Output:`n$($res.Output)"
        Assert-Result -Name "adhoc exit 0" -Condition ($res.ExitCode -eq 0) -FailureMessage "expected exit 0, got $($res.ExitCode). Output:`n$($res.Output)"
        Assert-Result -Name "adhoc banner names the prompt file" -Condition ($res.Output -match "Launching Specialist for item-30-brief \(ad-hoc prompt\)") -FailureMessage "expected ad-hoc banner. Output:`n$($res.Output)"
        $transcript = Join-Path $projectRoot ".crucible/session/adhoc/item-30-brief/codex-transcript.txt"
        Assert-Result -Name "adhoc session dir derived from prompt basename" -Condition (Test-Path -LiteralPath $transcript) -FailureMessage "expected transcript at $transcript. Output:`n$($res.Output)"
        $tx = Get-Content -LiteralPath $transcript -Raw
        Assert-Result -Name "adhoc prompt still delivered on stdin" -Condition ($tx -match ([regex]::Escape("Do the framework work described here."))) -FailureMessage "expected prompt body on stdin. Transcript:`n$tx"
    }

    $results += Run-Test -Name "Ad-hoc session cannot collide with a task session dir" -Body {
        # session/adhoc/ is not decorative. crucible-health treats a top-level
        # session/<F|B|C>-<n>/ dir as a task session and archives it when the backlog says that
        # task is done, so a prompt file named F-001.md must NOT land at session/F-001/.
        $projectRoot = Join-Path $tempRoot "proj-promptfile-collide"
        New-Item -ItemType Directory -Path (Join-Path $projectRoot ".crucible") -Force | Out-Null
        $promptFilePath = Join-Path $tempRoot "F-001.md"
        [System.IO.File]::WriteAllText($promptFilePath, "prompt that happens to be named like a task")
        $res = Invoke-Launcher -Mode "success" -BinDir $binDir -LauncherArgs @(
            "-Model", "gpt-6-sol", "-PromptFile", $promptFilePath, "-ProjectRoot", $projectRoot)
        Assert-Result -Name "collide launch succeeds" -Condition ($res.Output -match "STATUS=SUCCESS") -FailureMessage "expected SUCCESS. Output:`n$($res.Output)"
        $taskShaped = Join-Path $projectRoot ".crucible/session/F-001"
        Assert-Result -Name "no task-shaped session dir created" -Condition (-not (Test-Path -LiteralPath $taskShaped)) -FailureMessage "ad-hoc prompt must not create a task-shaped session dir at $taskShaped"
        $adhoc = Join-Path $projectRoot ".crucible/session/adhoc/F-001/codex-transcript.txt"
        Assert-Result -Name "landed under session/adhoc instead" -Condition (Test-Path -LiteralPath $adhoc) -FailureMessage "expected transcript at $adhoc. Output:`n$($res.Output)"
    }

    $results += Run-Test -Name "-PromptFile with only one of -TaskId/-Phase exits 2" -Body {
        # All-or-nothing: -TaskId alone would name session/<id>/ with no phase segment, a shape
        # nothing else in Crucible writes or reads.
        $projectRoot = Join-Path $tempRoot "proj-promptfile-halfid"
        New-Item -ItemType Directory -Path (Join-Path $projectRoot ".crucible") -Force | Out-Null
        $promptFilePath = Join-Path $tempRoot "half-id-brief.md"
        [System.IO.File]::WriteAllText($promptFilePath, "prompt body")
        $res = Invoke-Launcher -Mode "success" -BinDir $binDir -LauncherArgs @(
            "-TaskId", "C-982", "-Model", "gpt-6-sol", "-PromptFile", $promptFilePath, "-ProjectRoot", $projectRoot)
        Assert-Result -Name "half-specified exit 2" -Condition ($res.ExitCode -eq 2) -FailureMessage "expected exit 2, got $($res.ExitCode). Output:`n$($res.Output)"
        Assert-Result -Name "half-specified names the missing arg" -Condition ($res.Output -match "-Phase is required") -FailureMessage "expected -Phase required message. Output:`n$($res.Output)"
        Assert-Result -Name "half-specified explains the ad-hoc alternative" -Condition ($res.Output -match "Omit both -TaskId and -Phase") -FailureMessage "expected the omit-both hint. Output:`n$($res.Output)"
        Assert-Result -Name "half-specified dispatches nothing" -Condition (-not ($res.Output -match "\[CODEX SPECIALIST\] STATUS=")) -FailureMessage "must exit before dispatch. Output:`n$($res.Output)"
    }

    $results += Run-Test -Name "Bootstrap path still requires -TaskId and -Phase" -Body {
        # The fix must not leak into the path where those two DO select content: without a
        # prompt override, New-BootstrapPrompt builds the prompt out of TaskId and Phase.
        $projectRoot = Join-Path $tempRoot "proj-bootstrap-required"
        New-Item -ItemType Directory -Path (Join-Path $projectRoot ".crucible") -Force | Out-Null
        $res = Invoke-Launcher -Mode "success" -BinDir $binDir -LauncherArgs @(
            "-Model", "gpt-6-sol", "-ProjectRoot", $projectRoot)
        Assert-Result -Name "bootstrap missing taskid exit 2" -Condition ($res.ExitCode -eq 2) -FailureMessage "expected exit 2, got $($res.ExitCode). Output:`n$($res.Output)"
        Assert-Result -Name "bootstrap missing taskid message" -Condition ($res.Output -match "-TaskId is required") -FailureMessage "expected -TaskId required message. Output:`n$($res.Output)"

        # -PromptText has no base name to derive a session directory from, so it does not get
        # the ad-hoc treatment and the two stay required there too.
        $res2 = Invoke-Launcher -Mode "success" -BinDir $binDir -LauncherArgs @(
            "-Model", "gpt-6-sol", "-PromptText", "inline prompt", "-ProjectRoot", $projectRoot)
        Assert-Result -Name "prompttext without taskid exit 2" -Condition ($res2.ExitCode -eq 2) -FailureMessage "expected exit 2 for -PromptText without -TaskId, got $($res2.ExitCode). Output:`n$($res2.Output)"
    }

    $results += Run-Test -Name "Bootstrap prompt names paths that resolve from a worktree WorkingDir" -Body {
        # A worktree has no copy of the gitignored session dir, so the relative
        # .crucible/session/... path the bootstrap prompt used to carry did not exist from the
        # specialist's cwd. Both the prompt path and the Crucible line must stand on their own.
        $projectRoot = Join-Path $tempRoot "proj-bootstrap-worktree"
        $promptDir = Join-Path $projectRoot ".crucible/session/C-979/implementation"
        New-Item -ItemType Directory -Path $promptDir -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $promptDir "prompt.md"), "phase prompt")
        $worktree = Join-Path $tempRoot "wt-bootstrap"
        New-Item -ItemType Directory -Path $worktree -Force | Out-Null
        $res = Invoke-Launcher -Mode "echostdin" -BinDir $binDir -LauncherArgs @(
            "-TaskId", "C-979", "-Phase", "implementation", "-Model", "gpt-6-sol",
            "-ProjectRoot", $projectRoot, "-WorkingDir", $worktree)
        Assert-Result -Name "worktree bootstrap succeeds" -Condition ($res.Output -match "STATUS=SUCCESS") -FailureMessage "expected SUCCESS. Output:`n$($res.Output)"
        $transcript = Join-Path $promptDir "codex-transcript.txt"
        $tx = if (Test-Path -LiteralPath $transcript) { Get-Content -LiteralPath $transcript -Raw } else { "" }
        $promptRef = if ($tx -match "read and follow all instructions in ([^\r\n]+)") { $Matches[1].Trim() } else { "" }
        $promptResolves = (-not [string]::IsNullOrWhiteSpace($promptRef)) -and [System.IO.Path]::IsPathRooted($promptRef) -and (Test-Path -LiteralPath $promptRef)
        Assert-Result -Name "prompt path is absolute and exists" -Condition $promptResolves -FailureMessage "prompt path '$promptRef' must be absolute and exist. Transcript:`n$tx"
        $rootRef = if ($tx -match '-Init -TaskId C-979 -ProjectRoot "([^"]+)"') { $Matches[1] } else { "" }
        $rootResolves = (-not [string]::IsNullOrWhiteSpace($rootRef)) -and (Test-Path -LiteralPath (Join-Path $rootRef ".crucible/session/C-979"))
        Assert-Result -Name "crucible line passes the project root" -Condition $rootResolves -FailureMessage "Crucible line must pass -ProjectRoot naming the adopter root. Transcript:`n$tx"
        $scriptRef = if ($tx -match 'pwsh -File "([^"]+)" -Init') { $Matches[1] } else { "" }
        Assert-Result -Name "crucible script path is absolute" -Condition ([System.IO.Path]::IsPathRooted($scriptRef)) -FailureMessage "crucible.ps1 path '$scriptRef' must be absolute. Transcript:`n$tx"
    }

    $results += Run-Test -Name "Bootstrap launch with no phase prompt under the root is refused before dispatch" -Body {
        # Launching an adopter's task through the framework checkout's launcher without
        # -ProjectRoot resolved the root to the framework repo, created a stray session dir there,
        # and sent Codex hunting for a prompt that was not under its root.
        $projectRoot = Join-Path $tempRoot "proj-bootstrap-noprompt"
        New-Item -ItemType Directory -Path (Join-Path $projectRoot ".crucible") -Force | Out-Null
        $res = Invoke-Launcher -Mode "success" -BinDir $binDir -LauncherArgs @(
            "-TaskId", "C-978", "-Phase", "implementation", "-Model", "gpt-6-sol", "-ProjectRoot", $projectRoot)
        Assert-Result -Name "missing prompt exit 2" -Condition ($res.ExitCode -eq 2) -FailureMessage "expected exit 2, got $($res.ExitCode). Output:`n$($res.Output)"
        Assert-Result -Name "missing prompt names the path" -Condition ($res.Output -match "phase prompt not found: .*C-978") -FailureMessage "expected the missing prompt path. Output:`n$($res.Output)"
        Assert-Result -Name "missing prompt names the root source" -Condition ($res.Output -match "from -ProjectRoot") -FailureMessage "expected the root source. Output:`n$($res.Output)"
        Assert-Result -Name "missing prompt dispatches nothing" -Condition (-not ($res.Output -match "\[CODEX SPECIALIST\]")) -FailureMessage "must exit before dispatch. Output:`n$($res.Output)"
        $strayDir = Join-Path $projectRoot ".crucible/session/C-978"
        Assert-Result -Name "missing prompt creates no session dir" -Condition (-not (Test-Path -LiteralPath $strayDir)) -FailureMessage "must not create $strayDir"
    }

    $results += Run-Test -Name "A phase ended without the next phase starting reports ADVANCE_INCOMPLETE" -Body {
        # Regression: a Codex reviewer ended its turn while its crucible.ps1 -Init was still
        # re-running the full checks. Codex killed it after verification's session_end was
        # logged but before deployment started, and the launcher still reported SUCCESS.
        $projectRoot = Join-Path $tempRoot "proj-half-advance"
        New-Item -ItemType Directory -Path (Join-Path $projectRoot ".crucible") -Force | Out-Null
        $res = Invoke-Launcher -Mode "halfadvance" -BinDir $binDir -LauncherArgs @(
            "-TaskId", "C-977", "-Phase", "verification", "-Model", "gpt-6-sol",
            "-PromptText", "REVIEW", "-ProjectRoot", $projectRoot)
        Assert-Result -Name "status advance_incomplete" -Condition ($res.Output -match "\[CODEX SPECIALIST\] STATUS=ADVANCE_INCOMPLETE") -FailureMessage "expected ADVANCE_INCOMPLETE. Output:`n$($res.Output)"
        Assert-Result -Name "not reported as success" -Condition (-not ($res.Output -match "STATUS=SUCCESS")) -FailureMessage "must not report SUCCESS. Output:`n$($res.Output)"
        Assert-Result -Name "exit 3" -Condition ($res.ExitCode -eq 3) -FailureMessage "expected exit 3, got $($res.ExitCode). Output:`n$($res.Output)"
        Assert-Result -Name "names the missing phase" -Condition ($res.Output -match "never started deployment") -FailureMessage "expected the missing phase named. Output:`n$($res.Output)"
        Assert-Result -Name "gives the recovery command" -Condition ($res.Output -match "-Init -TaskId C-977 -ProjectRoot") -FailureMessage "expected the -Init recovery command. Output:`n$($res.Output)"
    }

    $results += Run-Test -Name "A completed advance and an older half-advance both stay SUCCESS" -Body {
        $projectRoot = Join-Path $tempRoot "proj-full-advance"
        New-Item -ItemType Directory -Path (Join-Path $projectRoot ".crucible") -Force | Out-Null
        $res = Invoke-Launcher -Mode "fulladvance" -BinDir $binDir -LauncherArgs @(
            "-TaskId", "C-976", "-Phase", "verification", "-Model", "gpt-6-sol",
            "-PromptText", "REVIEW", "-ProjectRoot", $projectRoot)
        Assert-Result -Name "full advance success" -Condition ($res.Output -match "STATUS=SUCCESS") -FailureMessage "expected SUCCESS when the next phase started. Output:`n$($res.Output)"

        # A half-advance logged before this launch belongs to an earlier run, not this one.
        $staleRoot = Join-Path $tempRoot "proj-stale-advance"
        $taskDir = Join-Path $staleRoot ".crucible/session/C-975"
        New-Item -ItemType Directory -Path $taskDir -Force | Out-Null
        $stale = '{"event":"session_end","task_id":"C-975","phase":"verification","timestamp":"2020-01-01T00:00:00Z","outcome":"success","notes":"Handoff to deployment"}'
        [System.IO.File]::WriteAllText((Join-Path $taskDir "pipeline.log.jsonl"), ($stale + "`n"), (New-Object System.Text.UTF8Encoding($false)))
        $res2 = Invoke-Launcher -Mode "success" -BinDir $binDir -LauncherArgs @(
            "-TaskId", "C-975", "-Phase", "verification", "-Model", "gpt-6-sol",
            "-PromptText", "REVIEW", "-ProjectRoot", $staleRoot)
        Assert-Result -Name "stale half-advance ignored" -Condition ($res2.Output -match "STATUS=SUCCESS") -FailureMessage "an event before launch must not flag this run. Output:`n$($res2.Output)"
    }
} finally {
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

if ($results -contains $false) {
    Write-Host "`nSOME TESTS FAILED" -ForegroundColor Red
    exit 1
}

Write-Host ("`nALL TESTS PASSED (" + $results.Count + " tests)") -ForegroundColor Green
exit 0
