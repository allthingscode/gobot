# Shared test fixtures for Crucible.
# Name does not contain "test" to prevent runner execution.

$REPO_ROOT = (Resolve-Path -Path "$PSScriptRoot/../..").Path

# Get-TestRunRoot decides where this fixture is built. Guarded because a caller that
# dot-sources only this file would otherwise fail on the first fixture request;
# _harness.ps1 is idempotent, so loading it twice costs nothing.
if (-not (Get-Command "Get-TestRunRoot" -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot "_harness.ps1")
}

# Cache the path in a script-scope variable
$script:SharedAdopterFixturePath = $null

function Get-SharedAdopterFixture {
    # 1. Check if the environment variable is set by the pre-stage runner
    if ($env:CRUCIBLE_SHARED_FIXTURE -and (Test-Path -LiteralPath $env:CRUCIBLE_SHARED_FIXTURE)) {
        return $env:CRUCIBLE_SHARED_FIXTURE
    }

    # 2. Check if already built in this process context
    if ($null -ne $script:SharedAdopterFixturePath -and (Test-Path -LiteralPath $script:SharedAdopterFixturePath)) {
        return $script:SharedAdopterFixturePath
    }

    # 3. Otherwise, build it once (fallback for standalone runs)
    # Inside the run root, so the fixture needs no owner marking of its own: the root
    # carries the owning pid and collecting the root collects this with it. The guid
    # stays because processes SHARE a run root - two children that both fell through to
    # building their own fixture would otherwise git-init over each other.
    $tempPath = Join-Path (Get-TestRunRoot) ("shared-adopter-" + [guid]::NewGuid().ToString("N"))

    . (Join-Path $REPO_ROOT "powershell/lib/platform.ps1")

    New-Item -ItemType Directory -Path $tempPath -Force | Out-Null
    Push-Location $tempPath
    try {
        git init --quiet
        git config user.name "Shared Fixture User"
        git config user.email "shared@example.com"
        git config core.autocrlf false
        git config core.safecrlf false
        Set-Content -Path "README.md" -Value "# Shared App"
        git add README.md
        git commit -m "initial commit" --quiet
    } finally {
        Pop-Location
    }

    $initScript = Join-Path $REPO_ROOT "powershell/init-project.ps1"
    & (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $initScript `
        -ProjectRoot $tempPath `
        -ProjectName "Shared App" `
        -Quiet

    if ($LASTEXITCODE -ne 0) {
        throw "Failed to build shared adopter fixture at $tempPath"
    }

    $script:SharedAdopterFixturePath = $tempPath
    return $tempPath
}

function Invoke-GitCommit {
    param(
        [Parameter(Mandatory=$true)][string]$Repo,
        [Parameter(Mandatory=$true)][string]$Message
    )
    . (Join-Path $REPO_ROOT "powershell/lib/platform.ps1")
    Invoke-Git -Directory $Repo add -A | Out-Null
    Invoke-Git -Directory $Repo @("-c", "user.name=Crucible Tests", "-c", "user.email=tests@example.invalid", "commit", "-m", $Message, "--quiet") | Out-Null
    return (Invoke-Git -Directory $Repo rev-parse HEAD).Raw.Trim()
}
