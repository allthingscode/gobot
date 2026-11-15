# Tests for platform resolver helper.

$ErrorActionPreference = "Stop"
$REPO_ROOT = (Resolve-Path -Path "$PSScriptRoot/../..").Path
. (Join-Path $PSScriptRoot '_harness.ps1')
$Quiet = $true

# platform.ps1 is dot-sourced here.
. (Join-Path $REPO_ROOT "powershell/lib/platform.ps1")

$results = @()







try {
    $results += Run-Test -Name "Get-PwshCommand returns correct command based on platform mock" -Body {
        $script:MockPlatformIsWindows = $true
        $script:MockPwshCommandExists = $true
        $cmdWin = Get-PwshCommand
        Assert-Result -Name "windows mock returns pwsh" -Condition ($cmdWin -eq "pwsh") -FailureMessage "expected pwsh on Windows"

        $script:MockPlatformIsWindows = $false
        $script:MockPwshCommandExists = $true
        $cmdUnix = Get-PwshCommand
        Assert-Result -Name "unix mock returns pwsh" -Condition ($cmdUnix -eq "pwsh") -FailureMessage "expected pwsh on Unix"

        $script:MockPlatformIsWindows = $true
        $script:MockPwshCommandExists = $false
        $threwWin = $false
        try {
            $null = Get-PwshCommand
        } catch {
            $threwWin = $true
            Assert-Result -Name "windows throw message" -Condition ($_.Exception.Message -match "not found on your PATH") -FailureMessage "unexpected exception message: $($_.Exception.Message)"
        }
        Assert-Result -Name "windows mock throws when pwsh absent" -Condition $threwWin -FailureMessage "expected Get-PwshCommand to throw when pwsh is absent on Windows"

        $script:MockPlatformIsWindows = $false
        $script:MockPwshCommandExists = $false
        $threw = $false
        try {
            $null = Get-PwshCommand
        } catch {
            $threw = $true
            Assert-Result -Name "unix throw message" -Condition ($_.Exception.Message -match "not found on your PATH") -FailureMessage "unexpected exception message: $($_.Exception.Message)"
        }
        Assert-Result -Name "unix mock throws when pwsh absent" -Condition $threw -FailureMessage "expected Get-PwshCommand to throw when pwsh is absent on Unix"
    }

    $results += Run-Test -Name "Embedded host never selects arbitrary process executable" -Body {
        function Get-Process { param($Id) [pscustomobject]@{ Path = (Get-Command git -CommandType Application).Source } }
        $command = Get-RunningPowerShellCommand
        Assert-Result 'non-pwsh host never executed' ((Split-Path -Leaf $command) -in @('pwsh', 'pwsh.exe')) "arbitrary host selected: $command"
    }

    $results += Run-Test 'Running pwsh process is accepted when PSHOME has no executable' {
        $realHost = (Get-Process -Id $PID).Path
        function Test-Path { param($LiteralPath, $PathType) return $LiteralPath -eq $realHost }
        # Hide both PSHOME candidates even when the process is the same executable.
        function Join-Path { param($Path, $ChildPath) return "absent/$ChildPath" }
        Assert-Result 'pwsh process fallback accepted' ((Get-RunningPowerShellCommand) -eq $realHost) 'running pwsh was rejected'
    }

    $results += Run-Test 'Encoding validator rejects arbitrary embedded host' {
        $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $REPO_ROOT 'powershell/run-isolated-checks.ps1'), [ref]$null, [ref]$null)
        $assignment = $ast.Find({ param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$host_exe' }, $true)
        function Get-Process { param($Id) [pscustomobject]@{ Path = (Get-Command git -CommandType Application).Source } }
        & ([scriptblock]::Create($assignment.Extent.Text + '; $host_exe')) | ForEach-Object {
            Assert-Result 'encoding child uses pwsh' ((Split-Path -Leaf $_) -in @('pwsh', 'pwsh.exe')) "arbitrary validator host: $_"
        }
    }

    foreach ($site in @('backlog-io.ps1', 'crucible-gates-breakers.ps1', 'crucible-gates-human.ps1')) {
        $results += Run-Test ("Validator bypasses PATH: " + $site) {
            $root = New-TestFixtureRoot -NameHint 'validator-host'
            try {
                $validator = Join-Path $root 'validator.ps1'
                [IO.File]::WriteAllText($validator, "param(`$ProjectRoot, `$TaskId, `$Mode, [switch]`$FixSummary)`nexit 7`n")
                $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $REPO_ROOT ('powershell/lib/' + $site)), [ref]$null, [ref]$null)
                $call = $ast.Find({ param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.Extent.Text -match '& (?:\(Get-(?:PwshCommand|RunningPowerShellCommand)\)|\$checkHost).*\$(?:validateScript|isolatedChecksScript|CheckScript)\b' }, $true)
                function Get-PwshCommand { throw 'PATH host resolution forbidden' }
                $checkHost = Get-RunningPowerShellCommand
                $validateScript = $validator; $isolatedChecksScript = $validator; $CheckScript = $validator
                $resolvedProjectRoot = $root; $ProjectRoot = $root; $TaskId = 'F-372'
                $handoff = [pscustomobject]@{ task_id = $TaskId }
                & ([scriptblock]::Create($call.Extent.Text)) | Out-Null
                Assert-Result 'validator nonzero exit preserved without PATH' ($LASTEXITCODE -eq 7) "validator skipped: $LASTEXITCODE"
            } finally { Remove-Item -LiteralPath $root -Recurse -Force }
        }
    }

    $results += Run-Test -Name "Real platform execution test" -Body {
        # Restore mock state to use real platform checks
        $script:MockPlatformIsWindows = $null
        $script:MockPwshCommandExists = $null

        $cmd = Get-PwshCommand
        Assert-Result -Name "returns non-empty command" -Condition (-not [string]::IsNullOrWhiteSpace($cmd)) -FailureMessage "command must not be empty"

        # Try to execute the command to verify it runs and returns exit code 0
        & $cmd -NoProfile -Command "exit 0"
        Assert-Result -Name "execution exit code" -Condition ($LASTEXITCODE -eq 0) -FailureMessage "execution of resolved command '$cmd' failed with exit code $LASTEXITCODE"
    }

    $results += Run-Test -Name "No test spawns a child host by the Windows-only executable name" -Body {
        # A test that hardcodes the Windows host passes locally and fails every case on
        # the Linux CI leg, where only pwsh exists. Spawn via (Get-Process -Id $PID).Path
        # or Get-PwshCommand instead. Regression: check-assertion-deletion.tests.ps1.
        $offenders = @()
        foreach ($file in (Get-ChildItem -LiteralPath (Join-Path $REPO_ROOT "powershell/tests") -Filter "*.ps1" -File)) {
            $lineNo = 0
            foreach ($line in (Get-Content -LiteralPath $file.FullName)) {
                $lineNo++
                if ($line -match '^\s*&?\s*powershell\.exe\b') {
                    $offenders += ($file.Name + ":" + $lineNo)
                }
            }
        }
        Assert-Result -Name "no hardcoded Windows host in test invocations" -Condition ($offenders.Count -eq 0) -FailureMessage ("these lines spawn the Windows-only host directly and will fail on Linux CI: " + ($offenders -join ", "))
    }
} finally {
    # Ensure mock state is cleaned up
    $script:MockPlatformIsWindows = $null
    $script:MockPwshCommandExists = $null
}

$failed = @($results | Where-Object { -not $_ }).Count
if ($failed -gt 0) {
    Write-Host ("`n$failed platform test(s) failed.") -ForegroundColor Red
    exit 1
}
Write-Host "`nAll platform tests passed." -ForegroundColor Green
exit 0
