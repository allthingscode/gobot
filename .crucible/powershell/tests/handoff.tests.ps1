# Tests for shared handoff helpers.

$ErrorActionPreference = "Stop"
$REPO_ROOT = (Resolve-Path -Path "$PSScriptRoot/../..").Path
$FACTORY_LIB = Join-Path $REPO_ROOT "powershell/factory-lib.ps1"
$Quiet = $true
. $FACTORY_LIB

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

function Write-TestHandoff {
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)][hashtable]$Values
    )

    if (-not $Values.ContainsKey("generated_by")) {
        $Values.generated_by = "new-handoff.ps1"
    }
    if (-not $Values.ContainsKey("tool_version")) {
        $Values.tool_version = "1.0.0"
    }

    $Values | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $Path -Encoding UTF8
}

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("crucible-handoff-test-" + [guid]::NewGuid().ToString("N"))
$handoffDir = Join-Path $tempRoot "handoffs"
$LOG_FILE = Join-Path $tempRoot "logs/pipeline.log.jsonl"
$CB_HISTORY_FILE = Join-Path $tempRoot "logs/circuit_breakers.jsonl"
New-Item -ItemType Directory -Path $handoffDir -Force | Out-Null

try {
    $results += Run-Test -Name "Get-HandoffTextForSecurityScan flattens scalar and array fields" -Body {
        $handoff = [PSCustomObject]@{
            reason = "Reason"
            summary = "Summary"
            artifacts = @("artifact-a.md", "artifact-b.md")
            file_affinity = @("src/", "tests/")
            reviewer_checks_passed = @("tests", "lint")
        }

        $text = Get-HandoffTextForSecurityScan -HandoffObj $handoff
        $expected = "Reason`nSummary`nartifact-a.md`nartifact-b.md`nsrc/`ntests/`ntests`nlint"
        Assert-Result -Name "flattened text" -Condition ($text -eq $expected) -FailureMessage "security scan text changed"
    }

    $results += Run-Test -Name "Get-HandoffDedupeKey normalizes phase fields and counters" -Body {
        $handoff = [PSCustomObject]@{
            task_id = " F-001 "
            source_phase = " Grooming "
            target_phase = " Implementation "
            review_strike_count = 2
            rebase_count = 1
            handoff_retry_count = 3
        }

        $key = Get-HandoffDedupeKey -HandoffObj $handoff
        Assert-Result -Name "dedupe key" -Condition ($key -eq "f-001|grooming|implementation|2|1|3") -FailureMessage "dedupe key changed"
    }

    $results += Run-Test -Name "Get-HandoffDedupeKey accepts legacy specialist fields" -Body {
        $handoff = [PSCustomObject]@{
            task_id = "F-002"
            source_specialist = "reviewer"
            target_specialist = "operator"
        }

        $key = Get-HandoffDedupeKey -HandoffObj $handoff
        Assert-Result -Name "legacy key" -Condition ($key -eq "f-002|reviewer|operator|0|0|0") -FailureMessage "legacy specialist compatibility changed"
    }

    $results += Run-Test -Name "Get-HandoffTimestampFromFileName parses canonical names only" -Body {
        $parsed = Get-HandoffTimestampFromFileName -Name "F-001-20260526T143012Z.json"
        $invalid = Get-HandoffTimestampFromFileName -Name "not-a-handoff.json"

        Assert-Result -Name "parsed datetime" -Condition ($parsed.ToString("yyyy-MM-ddTHH:mm:ssZ") -eq "2026-05-26T14:30:12Z") -FailureMessage "timestamp parse changed"
        Assert-Result -Name "invalid datetime" -Condition ($invalid -eq [datetime]::MinValue) -FailureMessage "invalid names should return MinValue"
    }

    $results += Run-Test -Name "Mark-DuplicateHandoffsAsSuperseded marks older duplicate" -Body {
        $oldPath = Join-Path $handoffDir "F-003-20260526T140000Z.json"
        $newPath = Join-Path $handoffDir "F-003-20260526T150000Z.json"
        $base = @{
            task_id = "F-003"
            source_phase = "grooming"
            target_phase = "implementation"
            handoff_retry_count = 0
            review_strike_count = 0
            rebase_count = 0
            summary = "duplicate transition"
        }
        Write-TestHandoff -Path $oldPath -Values $base
        Write-TestHandoff -Path $newPath -Values $base

        Mark-DuplicateHandoffsAsSuperseded -TaskId "F-003" -HandoffDir $handoffDir

        $old = Get-Content -LiteralPath $oldPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $new = Get-Content -LiteralPath $newPath -Raw -Encoding UTF8 | ConvertFrom-Json
        Assert-Result -Name "old superseded" -Condition ($old.superseded -eq $true) -FailureMessage "older duplicate was not superseded"
        Assert-Result -Name "winner name" -Condition ($old.superseded_by -eq "F-003-20260526T150000Z.json") -FailureMessage "wrong winner selected"
        Assert-Result -Name "reason" -Condition ($old.superseded_reason -eq "deterministic_duplicate_transition") -FailureMessage "superseded reason changed"
        Assert-Result -Name "winner untouched" -Condition (-not $new.PSObject.Properties["superseded"]) -FailureMessage "winner should not be superseded"
    }
} finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

$failed = @($results | Where-Object { -not $_ }).Count
if ($failed -gt 0) {
    Write-Host ("`n$failed handoff test(s) failed.") -ForegroundColor Red
    exit 1
}
Write-Host "`nAll handoff tests passed." -ForegroundColor Green
exit 0
