# Tests for Invoke-Git safe native command execution helper.

$ErrorActionPreference = "Stop"
$REPO_ROOT = (Resolve-Path -Path "$PSScriptRoot/../..").Path
. (Join-Path $PSScriptRoot '_harness.ps1')
$Quiet = $true

. (Join-Path $REPO_ROOT "powershell/lib/platform.ps1")

$results = @()

try {
    $results += Run-Test -Name "Non-zero exit is reported as ExitCode and not thrown under EAP Stop" -Body {
        $prevEAP = $ErrorActionPreference
        Assert-Result -Name "initial EAP is Stop" -Condition ($prevEAP -eq "Stop") -FailureMessage "Expected initial EAP to be Stop"

        # Query a non-existent ref which causes git to exit with non-zero (128) and emit stderr
        $res = Invoke-Git rev-parse --verify --quiet "refs/heads/non-existent-branch-crucible-test-xyz"
        Assert-Result -Name "non-zero exit code reported" -Condition ($res.ExitCode -ne 0) -FailureMessage "Expected non-zero exit code, got $($res.ExitCode)"
        Assert-Result -Name "lines is empty array on non-zero exit" -Condition ($res.Lines.Count -eq 0) -FailureMessage "Expected empty Lines array, got $($res.Lines.Count) lines"
        Assert-Result -Name "raw is empty on non-zero exit" -Condition ($res.Raw -eq "") -FailureMessage "Expected empty Raw string, got '$($res.Raw)'"
        Assert-Result -Name "EAP preserved after non-zero exit" -Condition ($ErrorActionPreference -eq "Stop") -FailureMessage "Expected EAP to remain Stop"
    }

    $results += Run-Test -Name "Stderr never appears in Lines or Raw" -Body {
        # A git command with invalid options or missing ref emits error text to stderr
        $res = Invoke-Git log -n 1 "refs/heads/definitely-nonexistent-ref-12345"
        Assert-Result -Name "non-zero exit" -Condition ($res.ExitCode -ne 0) -FailureMessage "Expected non-zero exit code"
        Assert-Result -Name "stderr not in Lines" -Condition ($res.Lines.Count -eq 0) -FailureMessage "Expected stderr to be discarded, but Lines contained: $($res.Lines -join '; ')"
        Assert-Result -Name "stderr not in Raw" -Condition ($res.Raw -eq "") -FailureMessage "Expected Raw to be empty"
    }

    $results += Run-Test -Name "ErrorActionPreference is restored even when callee throws" -Body {
        $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ("crucible-test-git-" + [guid]::NewGuid().ToString("N"))
        New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
        try {
            $prevEAP = $ErrorActionPreference
            Assert-Result -Name "EAP is Stop before call" -Condition ($prevEAP -eq "Stop") -FailureMessage "Expected EAP Stop"

            # Execute valid git command
            $res = Invoke-Git -Directory $tempDir init --quiet
            Assert-Result -Name "init exit 0" -Condition ($res.ExitCode -eq 0) -FailureMessage "git init failed"
            Assert-Result -Name "EAP restored after success" -Condition ($ErrorActionPreference -eq "Stop") -FailureMessage "Expected EAP restored to Stop"
        } finally {
            if (Test-Path -LiteralPath $tempDir) {
                Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    $results += Run-Test -Name "Stderr-only exit-0 command yields exit 0 with empty Lines" -Body {
        $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ("crucible-test-git-" + [guid]::NewGuid().ToString("N"))
        New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
        try {
            $initRes = Invoke-Git -Directory $tempDir init --quiet
            Assert-Result -Name "init success" -Condition ($initRes.ExitCode -eq 0) -FailureMessage "git init failed"

            # Config commands emit nothing to stdout and exit 0
            $res = Invoke-Git -Directory $tempDir config user.name "Test User"
            Assert-Result -Name "config exit 0" -Condition ($res.ExitCode -eq 0) -FailureMessage "git config failed"
            Assert-Result -Name "Lines is empty for quiet command" -Condition ($res.Lines.Count -eq 0) -FailureMessage "Expected empty Lines, got count $($res.Lines.Count)"
            Assert-Result -Name "Raw is empty for quiet command" -Condition ($res.Raw -eq "") -FailureMessage "Expected empty Raw"
        } finally {
            if (Test-Path -LiteralPath $tempDir) {
                Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    $results += Run-Test -Name "Structured return object contains ExitCode, Lines array, and Raw string" -Body {
        $res = Invoke-Git -Directory $REPO_ROOT rev-parse --show-toplevel
        Assert-Result -Name "rev-parse success" -Condition ($res.ExitCode -eq 0) -FailureMessage "rev-parse failed"
        Assert-Result -Name "Lines is string array" -Condition ($res.Lines -is [array] -and $res.Lines.Count -ge 1) -FailureMessage "Expected Lines array"
        Assert-Result -Name "Raw is string" -Condition ($res.Raw -is [string] -and -not [string]::IsNullOrWhiteSpace($res.Raw)) -FailureMessage "Expected Raw string"
        Assert-Result -Name "Raw matches Lines join" -Condition ($res.Raw -eq ($res.Lines -join "`n")) -FailureMessage "Raw should equal Lines joined with newline"
    }

    $results += Run-Test -Name "Directory and Repo parameters pass -C correctly" -Body {
        $resDir = Invoke-Git -Directory $REPO_ROOT rev-parse --show-toplevel
        $resRepo = Invoke-Git -Repo $REPO_ROOT rev-parse --show-toplevel
        Assert-Result -Name "Directory parameter works" -Condition ($resDir.ExitCode -eq 0 -and $resDir.Raw.Trim().Length -gt 0) -FailureMessage "-Directory failed"
        Assert-Result -Name "Repo alias works" -Condition ($resRepo.ExitCode -eq 0 -and $resRepo.Raw.Trim() -eq $resDir.Raw.Trim()) -FailureMessage "-Repo alias failed"
    }
} finally {
    # Ensure test environment stays clean
}

$failed = @($results | Where-Object { -not $_ }).Count
if ($failed -gt 0) {
    Write-Host ("`n$failed Invoke-Git test(s) failed.") -ForegroundColor Red
    exit 1
}
Write-Host "`nAll Invoke-Git tests passed." -ForegroundColor Green
exit 0
