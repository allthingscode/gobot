# Shared test fixtures for Crucible.
# Name does not contain "test" to prevent runner execution.

$REPO_ROOT = (Resolve-Path -Path "$PSScriptRoot/../..").Path

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
    $tempPath = Join-Path ([System.IO.Path]::GetTempPath()) ("crucible-shared-adopter-" + [guid]::NewGuid().ToString("N"))

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
