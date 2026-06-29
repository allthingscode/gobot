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
$factoryLibPath = Join-Path $PSScriptRoot "factory-lib.ps1"
if (-not (Test-Path -LiteralPath $factoryLibPath)) {
    throw "Required helper script not found at $factoryLibPath; your Crucible bundle is incomplete."
}
. $factoryLibPath
$platformLibPath = Join-Path $PSScriptRoot "lib/platform.ps1"
if (-not (Test-Path -LiteralPath $platformLibPath)) {
    throw "Required helper script not found at $platformLibPath; your Crucible bundle is incomplete."
}
. $platformLibPath
Push-Location $REPO_ROOT

$minimumGoVersion = "1.25.7"
$results = New-Object System.Collections.Generic.List[object]

# Mode detection. An installed adopter project has .crucible/config.yaml at the
# project root; the Crucible source repo does not. The same distinction the
# pre-commit hook uses (REPO_ROOT == FRAMEWORK_ROOT) drives readiness here:
# the framework's own toolchain (Go, golangci-lint, gh) is only required when
# developing Crucible itself, not when consuming an installed bundle.
$adopterConfigPath = Join-Path $REPO_ROOT ".crucible/config.yaml"
$adopterMode = Test-Path -LiteralPath $adopterConfigPath
$frameworkMode = -not $adopterMode

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

function Invoke-ToolCheck {
    param(
        [Parameter(Mandatory=$true)][string]$Command,
        [string[]]$Arguments = @()
    )

    # A missing executable makes the call operator throw CommandNotFoundException,
    # which would abort the whole doctor run with no structured output. Treat an
    # absent command as a non-zero check (exit 127) so every caller degrades safely.
    if (-not (Get-Command $Command -ErrorAction SilentlyContinue)) {
        return [PSCustomObject]@{
            ExitCode = 127
            Output   = ("'" + $Command + "' was not found on PATH.")
        }
    }

    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $output = & $Command @Arguments 2>&1
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousPreference
    }
    return [PSCustomObject]@{
        ExitCode = $exitCode
        Output   = ($output | Out-String).Trim()
    }
}

# Derive the executables an adopter's verification commands actually require, so
# the doctor checks the project's real toolchain instead of a hard-coded one.
function Get-VerificationTools {
    param([Parameter(Mandatory=$true)][string]$ConfigText)

    $shells = @("pwsh", "powershell", "powershell.exe", "cmd", "cmd.exe", "sh", "bash")
    $tools = New-Object System.Collections.Generic.List[string]
    foreach ($m in [regex]::Matches($ConfigText, '(?m)^\s*command:\s*(.+?)\s*$')) {
        $cmd = $m.Groups[1].Value.Trim()
        if ($cmd.Length -ge 2) {
            if (($cmd.StartsWith('"') -and $cmd.EndsWith('"')) -or ($cmd.StartsWith("'") -and $cmd.EndsWith("'"))) {
                $cmd = $cmd.Substring(1, $cmd.Length - 2).Trim()
            }
        }
        if ([string]::IsNullOrWhiteSpace($cmd)) { continue }
        if ($cmd -match 'replace-with|REPLACE_WITH') { continue }
        $first = ($cmd -split '\s+')[0]
        if ([string]::IsNullOrWhiteSpace($first)) { continue }
        $leaf = [System.IO.Path]::GetFileName($first)
        if ($shells -contains $leaf.ToLowerInvariant()) { continue }
        if (-not ($tools -contains $leaf)) { $tools.Add($leaf) | Out-Null }
    }
    return $tools
}

# Check (always): a usable PowerShell runtime for the current platform.
try {
    $pwshName = Get-PwshCommand
    $pwshResolved = Get-Command $pwshName -ErrorAction SilentlyContinue
    if ($pwshResolved) {
        Add-DoctorResult -Check "powershell.runtime" -Status "pass" -Severity "critical" `
            -Details ("Found PowerShell host '" + $pwshName + "' at " + $pwshResolved.Source + ".")
    } else {
        Add-DoctorResult -Check "powershell.runtime" -Status "fail" -Severity "critical" `
            -Details ("Resolved PowerShell host '" + $pwshName + "' is not available on PATH.") `
            -Remediation "Install Windows PowerShell 5.1 (Windows) or PowerShell 7+ (pwsh, Linux/macOS)."
    }
} catch {
    Add-DoctorResult -Check "powershell.runtime" -Status "fail" -Severity "critical" `
        -Details ("PowerShell host could not be resolved: " + $_.Exception.Message) `
        -Remediation "Install PowerShell 7+ (pwsh) on this platform."
}

if ($frameworkMode) {
    # Framework-development context: the pre-commit hook runs go run
    # scripts/factory_lint.go and CI uses gh + golangci-lint, so these are
    # genuine, critical readiness requirements here.

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
} else {
    # Adopter context: the installed bundle is what must be healthy. The adopter
    # pre-commit hook runs only merge-conflict + mojibake checks via PowerShell,
    # so Go/golangci-lint/gh are not readiness requirements; they are advisory and
    # only matter if the project opts into the GitHub deployment gate.

    $configText = ""
    try {
        $configText = Get-Content -LiteralPath $adopterConfigPath -Raw -Encoding UTF8
    } catch {
        $configText = ""
    }

    $crucibleRootValue = ""
    if ($configText -match '(?m)^crucible_root:\s*["'']?([^"''\r\n]+)["'']?\s*$') {
        $crucibleRootValue = $matches[1].Trim()
    }
    if ([string]::IsNullOrWhiteSpace($configText)) {
        Add-DoctorResult -Check "config.parse" -Status "fail" -Severity "critical" `
            -Details ("Found .crucible/config.yaml but could not read it: " + $adopterConfigPath) `
            -Remediation "Ensure .crucible/config.yaml is readable UTF-8."
    } elseif ([string]::IsNullOrWhiteSpace($crucibleRootValue)) {
        Add-DoctorResult -Check "config.parse" -Status "fail" -Severity "critical" `
            -Details "config.yaml is present but has no 'crucible_root:' key." `
            -Remediation "Add 'crucible_root: \".crucible\"' (or your bundle path) to config.yaml."
    } else {
        Add-DoctorResult -Check "config.parse" -Status "pass" -Severity "critical" `
            -Details ("config.yaml parsed; crucible_root = '" + $crucibleRootValue + "'.")
    }

    if (-not [string]::IsNullOrWhiteSpace($crucibleRootValue)) {
        $resolvedBundle = $crucibleRootValue
        if (-not [System.IO.Path]::IsPathRooted($resolvedBundle)) {
            $resolvedBundle = Join-Path $REPO_ROOT $crucibleRootValue
        }
        if (Test-Path -LiteralPath $resolvedBundle -PathType Container) {
            Add-DoctorResult -Check "bundle.root" -Status "pass" -Severity "critical" `
                -Details ("Bundle directory exists at " + $resolvedBundle + ".")
        } else {
            Add-DoctorResult -Check "bundle.root" -Status "fail" -Severity "critical" `
                -Details ("crucible_root points to a missing directory: " + $resolvedBundle + ".") `
                -Remediation "Fix crucible_root in config.yaml or reinstall the bundle (docs/updating.md)."
        }
    }

    $verificationTools = @(Get-VerificationTools -ConfigText $configText)
    if ($verificationTools.Count -eq 0) {
        Add-DoctorResult -Check "verification.tools" -Status "warn" -Severity "advisory" `
            -Details "No concrete verification commands configured yet (placeholders or shell-only)." `
            -Remediation "Set real verification commands in config.yaml so the pipeline can verify work."
    } else {
        foreach ($tool in $verificationTools) {
            $resolved = Get-Command $tool -ErrorAction SilentlyContinue
            if ($resolved) {
                Add-DoctorResult -Check ("verification.tool." + $tool) -Status "pass" -Severity "advisory" `
                    -Details ("Verification tool '" + $tool + "' found at " + $resolved.Source + ".")
            } else {
                Add-DoctorResult -Check ("verification.tool." + $tool) -Status "warn" -Severity "advisory" `
                    -Details ("Verification tool '" + $tool + "' from config.yaml is not on PATH.") `
                    -Remediation ("Install '" + $tool + "', or update the verification command in config.yaml.")
            }
        }
    }

    $hooksRel = ".crucible/scripts/hooks"
    $gitCmd = Get-Command git -ErrorAction SilentlyContinue
    if (-not $gitCmd) {
        Add-DoctorResult -Check "git.cli" -Status "warn" -Severity "advisory" `
            -Details "git is not installed or not on PATH; using the default hooks path and skipping git-derived checks." `
            -Remediation "Install git; it is required for worktrees, commits, and the deployment phase."
    } else {
        $gitHooks = Invoke-ToolCheck -Command "git" -Arguments @("-C", $REPO_ROOT, "config", "core.hooksPath")
        if ($gitHooks.ExitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace($gitHooks.Output)) {
            $hooksRel = $gitHooks.Output.Trim()
        }
    }
    $adopterHook = $hooksRel
    if (-not [System.IO.Path]::IsPathRooted($adopterHook)) {
        $adopterHook = Join-Path $REPO_ROOT $hooksRel
    }
    $adopterHook = Join-Path $adopterHook "pre-commit"
    if (-not (Test-Path -LiteralPath $adopterHook)) {
        Add-DoctorResult -Check "hooks.pre-commit" -Status "warn" -Severity "advisory" `
            -Details ("No pre-commit hook found at " + $adopterHook + ".") `
            -Remediation "Run .crucible/powershell/install-hooks.ps1 to enable the optional pre-commit guard."
    } else {
        $shCmd = Get-Command sh -ErrorAction SilentlyContinue
        if ($shCmd) {
            $hookSyntax = Invoke-ToolCheck -Command "sh" -Arguments @("-n", $adopterHook)
            if ($hookSyntax.ExitCode -eq 0) {
                Add-DoctorResult -Check "hooks.pre-commit" -Status "pass" -Severity "advisory" `
                    -Details ("pre-commit hook present and passes shell syntax check (" + $adopterHook + ").")
            } else {
                Add-DoctorResult -Check "hooks.pre-commit" -Status "warn" -Severity "advisory" `
                    -Details ("pre-commit hook failed shell syntax check: " + $hookSyntax.Output) `
                    -Remediation "Repair the hook or reinstall it via install-hooks.ps1."
            }
        } else {
            Add-DoctorResult -Check "hooks.pre-commit" -Status "pass" -Severity "advisory" `
                -Details ("pre-commit hook present at " + $adopterHook + " ('sh' unavailable, syntax not verified).")
        }
    }

    $ghCmd = Get-Command gh -ErrorAction SilentlyContinue
    if (-not $ghCmd) {
        Add-DoctorResult -Check "gh.cli" -Status "warn" -Severity "advisory" `
            -Details "GitHub CLI (gh) is not installed; only required if you use the GitHub deployment gate." `
            -Remediation "Install GitHub CLI only if your deployment phase opens GitHub PRs."
    } else {
        $ghAuth = Invoke-ToolCheck -Command "gh" -Arguments @("auth", "status")
        if ($ghAuth.ExitCode -eq 0) {
            Add-DoctorResult -Check "gh.auth" -Status "pass" -Severity "advisory" `
                -Details "GitHub CLI authentication is active."
        } else {
            Add-DoctorResult -Check "gh.auth" -Status "warn" -Severity "advisory" `
                -Details "GitHub CLI is installed but not authenticated; only required for the GitHub deployment gate." `
                -Remediation "Run 'gh auth login' if your deployment phase opens GitHub PRs."
        }
    }

    # Staleness advisory check for installed bundle
    $bannerCommit = ""
    if ($configText -match '(?m)^crucible_install_commit:\s+["'']([^"''\r\n]+)["'']\s*$') {
        $bannerCommit = $Matches[1].Trim()
    }
    if ($bannerCommit -match '^[0-9a-f]{40}$') {
        $frameworkSource = ""
        if (-not [string]::IsNullOrWhiteSpace($env:CRUCIBLE_DEV_ROOT) -and (Test-Path -LiteralPath (Join-Path $env:CRUCIBLE_DEV_ROOT ".git"))) {
            $frameworkSource = $env:CRUCIBLE_DEV_ROOT
        } elseif (-not [string]::IsNullOrWhiteSpace($env:CRUCIBLE_FRAMEWORK_DIR) -and (Test-Path -LiteralPath (Join-Path $env:CRUCIBLE_FRAMEWORK_DIR ".git"))) {
            $frameworkSource = $env:CRUCIBLE_FRAMEWORK_DIR
        } else {
            $siblingCandidate = Join-Path (Split-Path -Parent $REPO_ROOT) "crucible"
            if (Test-Path -LiteralPath (Join-Path $siblingCandidate ".git")) {
                $frameworkSource = $siblingCandidate
            }
        }
        if ($frameworkSource) {
            $gitMainResult = git -C $frameworkSource rev-parse --verify --quiet main
            $frameworkHead = if ($LASTEXITCODE -eq 0 -and $gitMainResult) { ($gitMainResult | Out-String).Trim() } else { "" }
            if (-not ($frameworkHead -match '^[0-9a-f]{40}$')) {
                $gitHeadResult = git -C $frameworkSource rev-parse HEAD 2>$null
                $frameworkHead = if ($LASTEXITCODE -eq 0 -and $gitHeadResult) { ($gitHeadResult | Out-String).Trim() } else { "" }
            }
            if ($frameworkHead -match '^[0-9a-f]{40}$') {
                if ($bannerCommit -eq $frameworkHead) {
                    Add-DoctorResult -Check "bundle.staleness" -Status "pass" -Severity "advisory" `
                        -Details ("Bundle is up-to-date with framework HEAD (" + $frameworkHead.Substring(0, 7) + ").")
                } else {
                    $null = git -C $frameworkSource merge-base --is-ancestor $bannerCommit $frameworkHead 2>$null
                    if ($LASTEXITCODE -eq 0) {
                        Add-DoctorResult -Check "bundle.staleness" -Status "warn" -Severity "advisory" `
                            -Details ("Installed bundle (commit " + $bannerCommit.Substring(0, 7) + ") lags framework HEAD (" + $frameworkHead.Substring(0, 7) + ").") `
                            -Remediation ("Run 'update-bundle.ps1 -FrameworkSource " + $frameworkSource + "' to bring it current.")
                    } else {
                        Add-DoctorResult -Check "bundle.staleness" -Status "pass" -Severity "advisory" `
                            -Details ("Installed bundle (commit " + $bannerCommit.Substring(0, 7) + ") is not stale relative to framework HEAD (" + $frameworkHead.Substring(0, 7) + ").")
                    }
                }
            } else {
                Add-DoctorResult -Check "bundle.staleness" -Status "warn" -Severity "advisory" `
                    -Details ("Framework source found at " + $frameworkSource + " but could not resolve HEAD commit.")
            }
        }
    }
}

# Check (always, advisory): Codex specialist runtime. Codex is an opt-in multi-brand
# specialist target; this never blocks readiness. A live exec smoke is intentionally NOT
# run here (cost/network) - the deep runtime check is launch-codex-specialist.ps1 -Preflight,
# which catches the broken-sandbox-helper failure mode before a phase runs.
$codexCmd = Get-Command codex -ErrorAction SilentlyContinue
if (-not $codexCmd) {
    Add-DoctorResult -Check "codex.cli" -Status "warn" -Severity "advisory" `
        -Details "Codex CLI (codex) is not installed; only required if you dispatch Codex specialists." `
        -Remediation "Install the Codex CLI and run 'codex login' only if you use Codex as a pipeline specialist."
} else {
    Add-DoctorResult -Check "codex.cli" -Status "pass" -Severity "advisory" `
        -Details ("Found codex at " + $codexCmd.Source + "; verify the runtime with 'launch-codex-specialist.ps1 -Preflight -Model <codex-model>' before dispatching.")
}

# Check (always): required factory scripts present in the bundle.
$requiredScripts = @(
    "factory.ps1",
    "validate-handoff.ps1",
    "validate-backlog.ps1",
    "update-session-state.ps1",
    "launch-codex-specialist.ps1"
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
if ($frameworkMode) {
    Write-Host "Mode: framework (Crucible source repo)"
    Write-Host ("Go Requirement: >= " + $minimumGoVersion)
} else {
    Write-Host "Mode: adopter (installed .crucible/ bundle)"
}

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
