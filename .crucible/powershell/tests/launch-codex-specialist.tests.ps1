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

    $results += Run-Test -Name "Phase launch LAUNCH_FAILED when no final message captured" -Body {
        $projectRoot = Join-Path $tempRoot "proj-empty"
        New-Item -ItemType Directory -Path (Join-Path $projectRoot ".crucible") -Force | Out-Null
        $res = Invoke-Launcher -Mode "empty" -BinDir $binDir -LauncherArgs @(
            "-TaskId", "C-996", "-Phase", "verification", "-Model", "gpt-5.5",
            "-PromptText", "REVIEW", "-ProjectRoot", $projectRoot)
        Assert-Result -Name "status launch_failed empty" -Condition ($res.Output -match "STATUS=LAUNCH_FAILED") -FailureMessage "expected LAUNCH_FAILED. Output:`n$($res.Output)"
        Assert-Result -Name "no final message reason" -Condition ($res.Output -match "no final message") -FailureMessage "expected 'no final message' reason. Output:`n$($res.Output)"
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

    $results += Run-Test -Name "Missing -Model is rejected" -Body {
        $res = Invoke-Launcher -Mode "success" -BinDir $binDir -LauncherArgs @("-TaskId", "C-993", "-Phase", "verification")
        Assert-Result -Name "model required exit 2" -Condition ($res.ExitCode -eq 2) -FailureMessage "expected exit 2 for missing model, got $($res.ExitCode). Output:`n$($res.Output)"
        Assert-Result -Name "model required message" -Condition ($res.Output -match "-Model is required") -FailureMessage "expected model-required message. Output:`n$($res.Output)"
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
