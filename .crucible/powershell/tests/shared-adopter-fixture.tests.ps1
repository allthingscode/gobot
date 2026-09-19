# Get-SharedAdopterFixture must return a path, not installer chatter, even when
# init-project prints again. Item 106.

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$REPO_ROOT = (Resolve-Path -Path "$PSScriptRoot/../..").Path
. (Join-Path $PSScriptRoot "_harness.ps1")
. (Join-Path $PSScriptRoot "_fixtures.ps1")
. (Join-Path $REPO_ROOT "powershell/lib/platform.ps1")

$results = @()
$tempRoot = New-TestFixtureRoot -NameHint "shared-adopter-fixture"

try {
    $results += Run-Test -Name "Un-silenced installer does not become the fixture path" -Body {
        $wrapper = Join-Path $tempRoot "noisy-init.ps1"
        $realInit = Join-Path $REPO_ROOT "powershell/init-project.ps1"
        $wrapperBody = @"
`$ErrorActionPreference = "Stop"
Write-Host "Success: Set git core.hooksPath to '.crucible/scripts/hooks' in C:\poison"
& "$realInit" @args
exit `$LASTEXITCODE
"@
        [System.IO.File]::WriteAllText($wrapper, $wrapperBody, [System.Text.UTF8Encoding]::new($false))

        $prevFixture = $env:CRUCIBLE_SHARED_FIXTURE
        $prevCache = $script:SharedAdopterFixturePath
        try {
            $env:CRUCIBLE_SHARED_FIXTURE = $null
            $script:SharedAdopterFixturePath = $null

            $path = Get-SharedAdopterFixture -InitScript $wrapper
            Assert-Result -Name "returns a string" -Condition ($path -is [string]) -FailureMessage ("expected a single path string, got " + $path.GetType().FullName + ": " + ($path -join " | "))
            Assert-Result -Name "path exists" -Condition (Test-Path -LiteralPath $path -PathType Container) -FailureMessage ("expected an existing directory, got: " + $path)
            Assert-Result -Name "not installer chatter" -Condition ($path -notmatch '(?i)^Success:') -FailureMessage ("Get-SharedAdopterFixture returned installer chatter as a path: " + $path)
            Assert-Result -Name "bundle is present" -Condition (Test-Path -LiteralPath (Join-Path $path ".crucible/config.yaml") -PathType Leaf) -FailureMessage ("wrapper did not run the real installer; missing config.yaml under " + $path)
        } finally {
            if ($null -eq $prevFixture) {
                Remove-Item Env:CRUCIBLE_SHARED_FIXTURE -ErrorAction SilentlyContinue
            } else {
                $env:CRUCIBLE_SHARED_FIXTURE = $prevFixture
            }
            $script:SharedAdopterFixturePath = $prevCache
        }
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
