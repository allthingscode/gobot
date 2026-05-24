param (
    # Absolute path to the project root (the directory containing .crucible/).
    # Defaults to the current working directory.
    [Parameter(Mandatory=$false)]
    [string]$ProjectRoot = ""
)

$ErrorActionPreference = "Stop"

# Anchor paths to the project root (where .crucible/ lives).
if ([string]::IsNullOrWhiteSpace($ProjectRoot)) {
    $REPO_ROOT = (Get-Location).Path
} else {
    if (-not (Test-Path -LiteralPath $ProjectRoot)) {
        Write-Host ("Error: -ProjectRoot path does not exist: " + $ProjectRoot) -ForegroundColor Red
        exit 1
    }
    $REPO_ROOT = (Resolve-Path -LiteralPath $ProjectRoot).Path
}
Push-Location $REPO_ROOT

$minimumGoVersion = "1.25.7"
$results = New-Object System.Collections.Generic.List[object]

function Add-DoctorResult {
    param(
        [Parameter(Mandatory=$true)][string]$Check,
        [Parameter(Mandatory=$true)][ValidateSet("pass", "warn", "fail")][string]$Status,
        [Parameter(Mandatory=$true)][ValidateSet("critical", "advisory")][string]$Severity,
        [Parameter(Mandatory=$true)][string]$Details,
        [string]$Remediation = ""
    )

    $results.Add([PSCustomObject]@{
        check       = $Check
        status      = $Status
        severity    = $Severity
        details     = $Details
        remediation = $Remediation
    }) | Out-Null
}

function Parse-SemVer {
    param([string]$Raw)
    if ([string]::IsNullOrWhiteSpace($Raw)) {
        return $null
    }
    if ($Raw -match '(\d+)\.(\d+)\.(\d+)') {
        return [int[]]@([int]$matches[1], [int]$matches[2], [int]$matches[3])
    }
    if ($Raw -match '(\d+)\.(\d+)') {
        return [int[]]@([int]$matches[1], [int]$matches[2], 0)
    }
    return $null
}

function Compare-SemVer {
    param(
        [Parameter(Mandatory=$true)][int[]]$A,
        [Parameter(Mandatory=$true)][int[]]$B
    )

    for ($i = 0; $i -lt 3; $i++) {
        if ($A[$i] -gt $B[$i]) { return 1 }
        if ($A[$i] -lt $B[$i]) { return -1 }
    }
    return 0
}

function Invoke-ToolCheck {
    param(
        [Parameter(Mandatory=$true)][string]$Command,
        [string[]]$Arguments = @()
    )

    $output = & $Command @Arguments 2>&1
    return [PSCustomObject]@{
        ExitCode = $LASTEXITCODE
        Output   = ($output | Out-String).Trim()
    }
}

# Check: gh installed + authenticated.
$ghCmd = Get-Command gh -ErrorAction SilentlyContinue
if (-not $ghCmd) {
    Add-DoctorResult -Check "gh.cli" -Status "fail" -Severity "critical" `
        -Details "GitHub CLI (gh) is not installed or not in PATH." `
        -Remediation "Install GitHub CLI and ensure 'gh' is available in PATH."
} else {
    Add-DoctorResult -Check "gh.cli" -Status "pass" -Severity "critical" `
        -Details ("Found gh at " + $ghCmd.Source)

    $ghAuth = Invoke-ToolCheck -Command "gh" -Arguments @("auth", "status")
    if ($ghAuth.ExitCode -eq 0) {
        Add-DoctorResult -Check "gh.auth" -Status "pass" -Severity "critical" `
            -Details "GitHub CLI authentication is active."
    } else {
        Add-DoctorResult -Check "gh.auth" -Status "fail" -Severity "critical" `
            -Details "gh auth status failed; CLI is not authenticated for required CI diagnostics." `
            -Remediation "Run 'gh auth login' and verify with 'gh auth status'."
    }
}

# Check: go present + minimum version.
$goCmd = Get-Command go -ErrorAction SilentlyContinue
if (-not $goCmd) {
    Add-DoctorResult -Check "go.cli" -Status "fail" -Severity "critical" `
        -Details "Go is not installed or not in PATH." `
        -Remediation "Install Go 1.25.7+ and ensure 'go' is available in PATH."
} else {
    $goVersionResult = Invoke-ToolCheck -Command "go" -Arguments @("version")
    if ($goVersionResult.ExitCode -ne 0) {
        Add-DoctorResult -Check "go.version" -Status "fail" -Severity "critical" `
            -Details ("Unable to execute 'go version': " + $goVersionResult.Output) `
            -Remediation "Repair Go installation so 'go version' returns successfully."
    } else {
        if ($goVersionResult.Output -match 'go version go([0-9]+\.[0-9]+(?:\.[0-9]+)?)') {
            $actual = Parse-SemVer -Raw $matches[1]
            $required = Parse-SemVer -Raw $minimumGoVersion
            if ($actual -eq $null) {
                Add-DoctorResult -Check "go.version" -Status "warn" -Severity "advisory" `
                    -Details ("Go version string was detected but not parseable: " + $goVersionResult.Output) `
                    -Remediation "Verify Go version manually and keep it at or above $minimumGoVersion."
            } else {
                $cmp = Compare-SemVer -A $actual -B $required
                if ($cmp -ge 0) {
                    Add-DoctorResult -Check "go.version" -Status "pass" -Severity "critical" `
                        -Details ("Detected Go version " + $matches[1] + " (required >= " + $minimumGoVersion + ").")
                } else {
                    Add-DoctorResult -Check "go.version" -Status "fail" -Severity "critical" `
                        -Details ("Detected Go version " + $matches[1] + " (required >= " + $minimumGoVersion + ").") `
                        -Remediation ("Upgrade Go to at least " + $minimumGoVersion + ".")
                }
            }
        } else {
            Add-DoctorResult -Check "go.version" -Status "warn" -Severity "advisory" `
                -Details ("Unable to parse Go version output: " + $goVersionResult.Output) `
                -Remediation "Verify Go version manually and keep it at or above 1.25.7."
        }
    }
}

# Check: golangci-lint installed + version detectable.
$lintCmd = Get-Command golangci-lint -ErrorAction SilentlyContinue
if (-not $lintCmd) {
    Add-DoctorResult -Check "golangci-lint.cli" -Status "fail" -Severity "critical" `
        -Details "golangci-lint is not installed or not in PATH." `
        -Remediation "Install golangci-lint and ensure it is available in PATH."
} else {
    $lintVersionResult = Invoke-ToolCheck -Command "golangci-lint" -Arguments @("version", "--short")
    if ($lintVersionResult.ExitCode -ne 0) {
        Add-DoctorResult -Check "golangci-lint.version" -Status "warn" -Severity "advisory" `
            -Details ("golangci-lint exists, but version detection failed: " + $lintVersionResult.Output) `
            -Remediation "Reinstall golangci-lint and verify with 'golangci-lint version --short'."
    } else {
        if ($lintVersionResult.Output -match 'v?(\d+\.\d+\.\d+)') {
            Add-DoctorResult -Check "golangci-lint.version" -Status "pass" -Severity "critical" `
                -Details ("Detected golangci-lint version " + $matches[1] + ".")
        } else {
            Add-DoctorResult -Check "golangci-lint.version" -Status "warn" -Severity "advisory" `
                -Details ("golangci-lint output was not parseable: " + $lintVersionResult.Output) `
                -Remediation "Use a stable golangci-lint release and verify version output."
        }
    }
}

# Check: hook presence and usability.
$hookPath = "scripts/hooks/pre-commit"
if (-not (Test-Path -LiteralPath $hookPath)) {
    Add-DoctorResult -Check "hooks.pre-commit" -Status "fail" -Severity "critical" `
        -Details "Required hook file scripts/hooks/pre-commit is missing." `
        -Remediation "Restore scripts/hooks/pre-commit from source control."
} else {
    $hookInfo = Get-Item -LiteralPath $hookPath
    if ($hookInfo.Length -le 0) {
        Add-DoctorResult -Check "hooks.pre-commit" -Status "fail" -Severity "critical" `
            -Details "scripts/hooks/pre-commit exists but is empty." `
            -Remediation "Restore hook contents so pre-commit checks can execute."
    } else {
        $shCmd = Get-Command sh -ErrorAction SilentlyContinue
        if ($shCmd) {
            $hookSyntax = Invoke-ToolCheck -Command "sh" -Arguments @("-n", $hookPath)
            if ($hookSyntax.ExitCode -eq 0) {
                Add-DoctorResult -Check "hooks.pre-commit" -Status "pass" -Severity "critical" `
                    -Details "scripts/hooks/pre-commit exists and passes shell syntax check."
            } else {
                Add-DoctorResult -Check "hooks.pre-commit" -Status "fail" -Severity "critical" `
                    -Details ("scripts/hooks/pre-commit failed shell syntax check: " + $hookSyntax.Output) `
                    -Remediation "Fix shell syntax in scripts/hooks/pre-commit."
            }
        } else {
            Add-DoctorResult -Check "hooks.pre-commit" -Status "warn" -Severity "advisory" `
                -Details "scripts/hooks/pre-commit exists, but 'sh' is unavailable so usability could not be verified." `
                -Remediation "Install a POSIX shell (Git Bash) and run 'sh -n scripts/hooks/pre-commit'."
        }
    }
}

# Check: required factory scripts present (in the framework, not the project).
$requiredScripts = @(
    "factory.ps1",
    "validate-handoff.ps1",
    "validate-backlog.ps1",
    "update_session_state.ps1"
)
$missingScripts = @()
foreach ($scriptName in $requiredScripts) {
    $scriptPath = Join-Path $PSScriptRoot $scriptName
    if (-not (Test-Path -LiteralPath $scriptPath)) {
        $missingScripts += $scriptName
    }
}
if ($missingScripts.Count -eq 0) {
    Add-DoctorResult -Check "factory.required-scripts" -Status "pass" -Severity "critical" `
        -Details "All required factory scripts are present."
} else {
    Add-DoctorResult -Check "factory.required-scripts" -Status "fail" -Severity "critical" `
        -Details ("Missing required factory script(s): " + ($missingScripts -join ", ")) `
        -Remediation "Restore the missing scripts before running the factory pipeline."
}

$passed = @($results | Where-Object { $_.status -eq "pass" })
$warned = @($results | Where-Object { $_.status -eq "warn" })
$failed = @($results | Where-Object { $_.status -eq "fail" })
$criticalFailures = @($results | Where-Object { $_.status -eq "fail" -and $_.severity -eq "critical" })

Write-Host ""
Write-Host "[DOCTOR] Factory Readiness Check" -ForegroundColor Cyan
Write-Host "--------------------------------" -ForegroundColor Cyan
Write-Host ("Repository: " + $REPO_ROOT)
Write-Host ("Go Requirement: >= " + $minimumGoVersion)

Write-Host ""
Write-Host ("PASS (" + $passed.Count + ")") -ForegroundColor Green
if ($passed.Count -eq 0) {
    Write-Host "  - none"
} else {
    foreach ($entry in $passed) {
        Write-Host ("  - [" + $entry.check + "] " + $entry.details)
    }
}

Write-Host ""
Write-Host ("WARN (" + $warned.Count + ")") -ForegroundColor Yellow
if ($warned.Count -eq 0) {
    Write-Host "  - none"
} else {
    foreach ($entry in $warned) {
        Write-Host ("  - [" + $entry.check + "] " + $entry.details + " (severity: " + $entry.severity + ")")
        Write-Host ("    remediation: " + $entry.remediation)
    }
}

Write-Host ""
Write-Host ("FAIL (" + $failed.Count + ")") -ForegroundColor Red
if ($failed.Count -eq 0) {
    Write-Host "  - none"
} else {
    foreach ($entry in $failed) {
        Write-Host ("  - [" + $entry.check + "] " + $entry.details + " (severity: " + $entry.severity + ")")
        Write-Host ("    remediation: " + $entry.remediation)
    }
}

$exitCode = if ($criticalFailures.Count -gt 0) { 1 } else { 0 }
Write-Host ""
if ($exitCode -eq 0) {
    Write-Host "[DOCTOR] Result: READY (no critical failures)." -ForegroundColor Green
} else {
    Write-Host ("[DOCTOR] Result: NOT READY (" + $criticalFailures.Count + " critical failure(s)).") -ForegroundColor Red
}

Pop-Location
exit $exitCode
