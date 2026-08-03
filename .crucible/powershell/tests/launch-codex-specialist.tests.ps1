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
    "stdinprobe" {
        # Mimic real codex reading stdin: report whether stdin reaches EOF promptly.
        # If the launcher closes codex stdin (the fix), EOF is immediate -> STDIN_EOF.
        # If stdin is left open (the bug), the async read does not complete -> STDIN_OPEN.
        $t = [Console]::In.ReadToEndAsync()
        if ($t.Wait(3000)) { Write-Output "CRUCIBLE_OK STDIN_EOF" } else { Write-Output "CRUCIBLE_OK STDIN_OPEN" }
        if ($outFile) { [System.IO.File]::WriteAllText($outFile, '{"verdict":"APPROVED","summary":"ok","findings":[]}', $enc) }
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

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("crucible-launch-codex-test-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
$binDir = Join-Path $tempRoot "fake-bin"
Write-FakeCodex -BinDir $binDir

try {
    $results += Run-Test -Name "Preflight PASS on a healthy runtime" -Body {
        $res = Invoke-Launcher -Mode "success" -BinDir $binDir -LauncherArgs @("-Preflight", "-Model", "gpt-5.5")
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
            ' -TaskId C-998 -Phase verification -Model gpt-5.5 -PromptText "REVIEW" -ProjectRoot "' + $projectRoot + '"'
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
        $res = Invoke-Launcher -Mode "infra" -BinDir $binDir -LauncherArgs @("-Preflight", "-Model", "gpt-5.5")
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
                & (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $LAUNCHER -Preflight -Model "gpt-5.5"
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
            "-TaskId", "C-999", "-Phase", "verification", "-Model", "gpt-5.5",
            "-PromptText", "REVIEW THIS TASK", "-ProjectRoot", $projectRoot)
        Assert-Result -Name "status success" -Condition ($res.Output -match "\[CODEX SPECIALIST\] STATUS=SUCCESS") -FailureMessage "expected SUCCESS. Output:`n$($res.Output)"
        Assert-Result -Name "exit 0" -Condition ($res.ExitCode -eq 0) -FailureMessage "expected exit 0, got $($res.ExitCode). Output:`n$($res.Output)"
        $lastMsg = Join-Path $projectRoot ".crucible/session/C-999/verification/codex-last-message.txt"
        $transcript = Join-Path $projectRoot ".crucible/session/C-999/verification/codex-transcript.txt"
        Assert-Result -Name "last message written" -Condition (Test-Path -LiteralPath $lastMsg) -FailureMessage "no last-message file"
        Assert-Result -Name "transcript written" -Condition (Test-Path -LiteralPath $transcript) -FailureMessage "no transcript file"
    }

    $results += Run-Test -Name "Dirty git tree blocks specialist dispatch without override" -Body {
        $projectRoot = Join-Path $tempRoot "proj-dirty-block"
        New-TestGitProject -Root $projectRoot
        $enc = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText((Join-Path $projectRoot "dirty.txt"), "uncommitted`n", $enc)
        $res = Invoke-Launcher -Mode "success" -BinDir $binDir -LauncherArgs @(
            "-TaskId", "C-980", "-Phase", "verification", "-Model", "gpt-5.5",
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
            "-TaskId", "C-979", "-Phase", "verification", "-Model", "gpt-5.5",
            "-PromptText", "REVIEW", "-ProjectRoot", $projectRoot, "-AllowDirtyTree")
        Assert-Result -Name "override status line" -Condition ($res.Output -match "\[CODEX SPECIALIST\] STATUS=SUCCESS") -FailureMessage "expected SUCCESS with override. Output:`n$($res.Output)"
        Assert-Result -Name "override exit 0" -Condition ($res.ExitCode -eq 0) -FailureMessage "expected exit 0, got $($res.ExitCode). Output:`n$($res.Output)"
    }

    $results += Run-Test -Name "Clean git tree dispatches normally" -Body {
        $projectRoot = Join-Path $tempRoot "proj-clean-git"
        New-TestGitProject -Root $projectRoot
        $res = Invoke-Launcher -Mode "success" -BinDir $binDir -LauncherArgs @(
            "-TaskId", "C-978", "-Phase", "verification", "-Model", "gpt-5.5",
            "-PromptText", "REVIEW", "-ProjectRoot", $projectRoot)
        Assert-Result -Name "clean status line" -Condition ($res.Output -match "\[CODEX SPECIALIST\] STATUS=SUCCESS") -FailureMessage "expected SUCCESS on clean git tree. Output:`n$($res.Output)"
        Assert-Result -Name "clean exit 0" -Condition ($res.ExitCode -eq 0) -FailureMessage "expected exit 0, got $($res.ExitCode). Output:`n$($res.Output)"
    }

    $results += Run-Test -Name "Non-git WorkingDir skips tree guard and dispatches" -Body {
        $projectRoot = Join-Path $tempRoot "proj-non-git-skip"
        New-Item -ItemType Directory -Path (Join-Path $projectRoot ".crucible") -Force | Out-Null
        $res = Invoke-Launcher -Mode "success" -BinDir $binDir -LauncherArgs @(
            "-TaskId", "C-977", "-Phase", "verification", "-Model", "gpt-5.5",
            "-PromptText", "REVIEW", "-ProjectRoot", $projectRoot)
        Assert-Result -Name "skip note" -Condition ($res.Output -match "WorkingDir is not a git work tree") -FailureMessage "expected non-git skip note. Output:`n$($res.Output)"
        Assert-Result -Name "non-git status line" -Condition ($res.Output -match "\[CODEX SPECIALIST\] STATUS=SUCCESS") -FailureMessage "expected SUCCESS for non-git WorkingDir. Output:`n$($res.Output)"
        Assert-Result -Name "non-git exit 0" -Condition ($res.ExitCode -eq 0) -FailureMessage "expected exit 0, got $($res.ExitCode). Output:`n$($res.Output)"
    }

    $results += Run-Test -Name "Phase launch SUCCESS when session dir vanishes before transcript write" -Body {
        $projectRoot = Join-Path $tempRoot "proj-vanishrestore"
        New-Item -ItemType Directory -Path (Join-Path $projectRoot ".crucible") -Force | Out-Null
        $res = Invoke-Launcher -Mode "vanishrestore" -BinDir $binDir -LauncherArgs @(
            "-TaskId", "C-981", "-Phase", "verification", "-Model", "gpt-5.5",
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
            "-TaskId", "C-998", "-Phase", "verification", "-Model", "gpt-5.5",
            "-PromptText", "REVIEW", "-ProjectRoot", $projectRoot)
        $transcript = Get-Content -LiteralPath (Join-Path $projectRoot ".crucible/session/C-998/verification/codex-transcript.txt") -Raw
        Assert-Result -Name "danger-full-access" -Condition ($transcript -match "danger-full-access") -FailureMessage "missing -s danger-full-access. Transcript:`n$transcript"
        Assert-Result -Name "skip-git-repo-check" -Condition ($transcript -match "--skip-git-repo-check") -FailureMessage "missing --skip-git-repo-check. Transcript:`n$transcript"
        Assert-Result -Name "model passed" -Condition ($transcript -match "gpt-5\.5") -FailureMessage "missing model. Transcript:`n$transcript"
        Assert-Result -Name "output-last-message passed" -Condition ($transcript -match "--output-last-message") -FailureMessage "missing --output-last-message. Transcript:`n$transcript"
    }

    $results += Run-Test -Name "Phase launch LAUNCH_FAILED on infra failure (never a verdict)" -Body {
        $projectRoot = Join-Path $tempRoot "proj-infra"
        New-Item -ItemType Directory -Path (Join-Path $projectRoot ".crucible") -Force | Out-Null
        $res = Invoke-Launcher -Mode "infra" -BinDir $binDir -LauncherArgs @(
            "-TaskId", "C-997", "-Phase", "verification", "-Model", "gpt-5.5",
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
            "-TaskId", "C-992", "-Phase", "research", "-Model", "gpt-5.5",
            "-PromptText", "RESEARCH", "-ProjectRoot", $projectRoot)
        Assert-Result -Name "marker words do not fail a 0-exit run" -Condition ($res.Output -match "STATUS=SUCCESS") -FailureMessage "0-exit run with marker words in transcript must be SUCCESS. Output:`n$($res.Output)"
        Assert-Result -Name "markerok exit 0" -Condition ($res.ExitCode -eq 0) -FailureMessage "expected exit 0, got $($res.ExitCode). Output:`n$($res.Output)"
    }

    $results += Run-Test -Name "Phase launch SUCCESS on exit 0 with empty final message (non-schema; repo state authoritative)" -Body {
        $projectRoot = Join-Path $tempRoot "proj-empty"
        New-Item -ItemType Directory -Path (Join-Path $projectRoot ".crucible") -Force | Out-Null
        $res = Invoke-Launcher -Mode "empty" -BinDir $binDir -LauncherArgs @(
            "-TaskId", "C-996", "-Phase", "verification", "-Model", "gpt-5.5",
            "-PromptText", "REVIEW", "-ProjectRoot", $projectRoot)
        Assert-Result -Name "status success empty" -Condition ($res.Output -match "STATUS=SUCCESS") -FailureMessage "expected SUCCESS. Output:`n$($res.Output)"
        Assert-Result -Name "empty exit 0" -Condition ($res.ExitCode -eq 0) -FailureMessage "expected exit 0, got $($res.ExitCode). Output:`n$($res.Output)"
    }

    $results += Run-Test -Name "ReviewSchema accepts a conforming verdict" -Body {
        $projectRoot = Join-Path $tempRoot "proj-schema-ok"
        New-Item -ItemType Directory -Path (Join-Path $projectRoot ".crucible") -Force | Out-Null
        $res = Invoke-Launcher -Mode "success" -BinDir $binDir -LauncherArgs @(
            "-TaskId", "C-995", "-Phase", "verification", "-Model", "gpt-5.5",
            "-PromptText", "REVIEW", "-ReviewSchema", "-ProjectRoot", $projectRoot)
        Assert-Result -Name "schema success" -Condition ($res.Output -match "STATUS=SUCCESS") -FailureMessage "valid verdict JSON should be SUCCESS. Output:`n$($res.Output)"
        Assert-Result -Name "schema enforced banner" -Condition ($res.Output -match "review verdict schema: enforced") -FailureMessage "expected schema-enforced banner. Output:`n$($res.Output)"
    }

    $results += Run-Test -Name "ReviewSchema rejects a non-verdict final message" -Body {
        $projectRoot = Join-Path $tempRoot "proj-schema-bad"
        New-Item -ItemType Directory -Path (Join-Path $projectRoot ".crucible") -Force | Out-Null
        $res = Invoke-Launcher -Mode "badverdict" -BinDir $binDir -LauncherArgs @(
            "-TaskId", "C-994", "-Phase", "verification", "-Model", "gpt-5.5",
            "-PromptText", "REVIEW", "-ReviewSchema", "-ProjectRoot", $projectRoot)
        Assert-Result -Name "schema bad launch_failed" -Condition ($res.Output -match "STATUS=LAUNCH_FAILED") -FailureMessage "non-verdict should be LAUNCH_FAILED. Output:`n$($res.Output)"
        Assert-Result -Name "verdict reason" -Condition ($res.Output -match "valid review verdict") -FailureMessage "expected verdict-validation reason. Output:`n$($res.Output)"
    }

    $results += Run-Test -Name "ReviewSchema rejects an empty final message" -Body {
        $projectRoot = Join-Path $tempRoot "proj-schema-empty"
        New-Item -ItemType Directory -Path (Join-Path $projectRoot ".crucible") -Force | Out-Null
        $res = Invoke-Launcher -Mode "empty" -BinDir $binDir -LauncherArgs @(
            "-TaskId", "C-993", "-Phase", "verification", "-Model", "gpt-5.5",
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
                    -TaskId "C-991" -Phase "verification" -Model "gpt-5.5" -PromptText "REVIEW"
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
            "-TaskId", "C-990", "-Phase", "verification", "-Model", "gpt-5.5",
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
            "-TaskId", "C-989", "-Phase", "verification", "-Model", "gpt-5.5",
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
            "-TaskId", "C-988", "-Phase", "verification", "-Model", "gpt-5.5",
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
            "-TaskId", "C-987", "-Phase", "verification", "-Model", "gpt-5.5",
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
            "-TaskId", "C-986", "-Phase", "verification", "-Model", "gpt-5.5",
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
            "-TaskId", "C-985", "-Phase", "verification", "-Model", "gpt-5.5",
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
            "-TaskId", "C-984", "-Phase", "verification", "-Model", "gpt-5.5",
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
            "-TaskId", "C-983", "-Phase", "deployment", "-Model", "gpt-5.5",
            "-PromptText", "DEPLOY", "-ProjectRoot", $projectRoot, "-WorkingDir", $wtDir)
        Assert-Result -Name "deployment status success" -Condition ($res.Output -match "\[CODEX SPECIALIST\] STATUS=SUCCESS") -FailureMessage "expected SUCCESS. Output:`n$($res.Output)"
        Assert-Result -Name "deployment notice emitted" -Condition ($res.Output -match "\[CODEX\] Notice: Deployment phase forces WorkingDir to main repo root") -FailureMessage "expected notice about deployment WorkingDir override. Output:`n$($res.Output)"
        $transcript = Join-Path $projectRoot ".crucible/session/C-983/deployment/codex-transcript.txt"
        Assert-Result -Name "transcript exists" -Condition (Test-Path -LiteralPath $transcript) -FailureMessage "expected transcript at $transcript"
        $tx = Get-Content -LiteralPath $transcript -Raw
        $expectedC = "-C " + $projectRoot
        Assert-Result -Name "codex launched with project root CWD" -Condition ($tx -match [regex]::Escape($expectedC)) -FailureMessage "expected codex -C to be $projectRoot. transcript=$tx"
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
