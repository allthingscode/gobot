# Guards that examples/gobot/.crucible stays a faithful full copy of the
# canonical framework. The example adopter bundle is meant to mirror the
# framework exactly (commits f5da6ed, 6f584b5); the repo-root .crucible/
# ignore rule otherwise lets newly added canonical files silently fall out
# of the tracked example over time. This test makes that drift a CI failure.

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$REPO_ROOT = (Resolve-Path -Path "$PSScriptRoot/../..").Path
$MIRROR = "examples/gobot/.crucible"

# Structural dirs that must match canonical exactly. The adopter-specific
# config.yaml and nested .crucible/.gitignore are intentionally NOT mirrored.
$STRUCTURAL_DIRS = @("docs", "prompts", "sops", "personas", "schemas", "powershell")

$results = @()

function Assert-Result {
    param([string]$Name, [bool]$Condition, [string]$FailureMessage)
    if (-not $Condition) {
        throw ("FAILED: " + $Name + " - " + $FailureMessage)
    }
}

function Run-Test {
    param([string]$Name, [scriptblock]$Body)
    Write-Host ("`nTest: " + $Name) -ForegroundColor Cyan
    try {
        & $Body
        Write-Host "PASSED" -ForegroundColor Green
        return $true
    } catch {
        Write-Host $_.Exception.Message -ForegroundColor Red
        return $false
    }
}

function Get-TrackedRelative {
    param([string]$Dir)
    $prefix = $Dir.TrimEnd('/') + '/'
    $tracked = @(git ls-files -- $Dir)
    return @($tracked | ForEach-Object { $_ -replace ('^' + [regex]::Escape($prefix)), '' })
}

Push-Location $REPO_ROOT
try {
    $results += Run-Test -Name "Mirror tracks the same structural files as canonical" -Body {
        $problems = @()
        foreach ($dir in $STRUCTURAL_DIRS) {
            $canonicalRel = @(Get-TrackedRelative -Dir $dir)
            $mirrorRel = @(Get-TrackedRelative -Dir "$MIRROR/$dir")
            foreach ($rel in $canonicalRel) {
                if ($mirrorRel -notcontains $rel) { $problems += "  [$dir] missing from mirror: $rel" }
            }
            foreach ($rel in $mirrorRel) {
                if ($canonicalRel -notcontains $rel) { $problems += "  [$dir] extra in mirror (not in canonical): $rel" }
            }
        }
        Assert-Result -Name "file sets identical" -Condition ($problems.Count -eq 0) -FailureMessage (
            "examples/gobot/.crucible has drifted from canonical:`n" + ($problems -join "`n") +
            "`nRe-sync with: robocopy <dir> $MIRROR/<dir> /MIR (per structural dir), then 'git add -f $MIRROR/<dir>'.")
    }

    $results += Run-Test -Name "Mirror structural files are byte-identical to canonical" -Body {
        $mismatch = @()
        foreach ($dir in $STRUCTURAL_DIRS) {
            $canonical = Get-TrackedRelative -Dir $dir
            foreach ($rel in $canonical) {
                $canPath = Join-Path $REPO_ROOT (Join-Path $dir $rel)
                $mirPath = Join-Path $REPO_ROOT (Join-Path "$MIRROR/$dir" $rel)
                if (-not (Test-Path -LiteralPath $mirPath)) { continue } # set-diff test already reports absence
                $canHash = (Get-FileHash -LiteralPath $canPath -Algorithm SHA256).Hash
                $mirHash = (Get-FileHash -LiteralPath $mirPath -Algorithm SHA256).Hash
                if ($canHash -ne $mirHash) {
                    $mismatch += "  [$dir] content differs: $rel"
                }
            }
        }
        Assert-Result -Name "content identical" -Condition ($mismatch.Count -eq 0) -FailureMessage (
            "examples/gobot/.crucible content has drifted from canonical:`n" + ($mismatch -join "`n") +
            "`nRe-sync with: robocopy <dir> $MIRROR/<dir> /MIR (per structural dir), then 'git add -f $MIRROR/<dir>'.")
    }

    $results += Run-Test -Name "No runtime/data files tracked under the mirror" -Body {
        $tracked = @(git ls-files -- $MIRROR)
        $forbidden = $tracked | Where-Object {
            $_ -match '/(backlog|session|handoffs|logs|eval|archive|archived|history|research|dev-logs|locks|tmp|cache)/' -or
            $_ -match '\.(jsonl|log)$'
        }
        Assert-Result -Name "no runtime tracked" -Condition (($forbidden | Measure-Object).Count -eq 0) -FailureMessage (
            "runtime/data files should never be tracked in the example bundle:`n" + (($forbidden) -join "`n"))
    }
}
finally {
    Pop-Location
}

if ($results -contains $false) {
    Write-Host "`nSOME TESTS FAILED" -ForegroundColor Red
    exit 1
}

Write-Host ("`nALL TESTS PASSED (" + $results.Count + " tests)") -ForegroundColor Green
exit 0
