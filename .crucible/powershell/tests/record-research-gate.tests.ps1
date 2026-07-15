# Unit tests for record-research-gate.ps1: the post-Research-Gate continuation helper that
# records a human gate decision and generates a self-contained gate-filing.md so a
# re-dispatched Researcher files the approved stubs instead of re-presenting the gate.

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$REPO_ROOT = (Resolve-Path -Path "$PSScriptRoot/../..").Path
. (Join-Path $PSScriptRoot '_harness.ps1')
$SCRIPT = Join-Path $REPO_ROOT "powershell/record-research-gate.ps1"

$results = @()

function New-GateProject {
    param([Parameter(Mandatory=$true)][string]$Root, [string]$TaskId = "R-021")
    $crucible = Join-Path $Root ".crucible"
    $researchSession = Join-Path $crucible "session/$TaskId/research"
    $researchDir = Join-Path $crucible "research"
    New-Item -ItemType Directory -Path $researchSession, $researchDir, (Join-Path $crucible "backlog") -Force | Out-Null
    "paths:`n  backlog: `"backlog`"`n  session: `"session`"" | Set-Content -LiteralPath (Join-Path $crucible "config.yaml") -Encoding UTF8
    "# findings" | Set-Content -LiteralPath (Join-Path $researchDir "$TaskId`_Quality_Audit_20260715.md") -Encoding UTF8
    return @{ Root = $Root; TaskId = $TaskId; GateFiling = (Join-Path $researchSession "gate-filing.md") }
}

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("crucible-research-gate-test-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

try {
    $results += Run-Test -Name "records approval and generates a gate-filing prompt listing approved items" -Body {
        $p = New-GateProject -Root (Join-Path $tempRoot "approve")
        & $SCRIPT -TaskId $p.TaskId -Reason "Gate approved" -Approved "C-350","C-351" -ProjectRoot $p.Root | Out-Null
        Assert-Result "gate-filing written" (Test-Path -LiteralPath $p.GateFiling) "gate-filing.md was not generated"
        $body = Get-Content -LiteralPath $p.GateFiling -Raw
        Assert-Result "names approved C-350" ($body -match "C-350") "approved item C-350 not listed"
        Assert-Result "names approved C-351" ($body -match "C-351") "approved item C-351 not listed"
        Assert-Result "forbids re-audit" ($body -match "Do NOT re-run the audit") "missing the do-not-re-audit directive"
        Assert-Result "instructs handoff" ($body -match "new-handoff\.ps1") "missing the handoff instruction"
        Assert-Result "passes HumanApproved" ($body -match "-HumanApproved") "handoff command should record HumanApproved"
    }

    $results += Run-Test -Name "writes a structural decision record with the approved list" -Body {
        $p = New-GateProject -Root (Join-Path $tempRoot "record")
        & $SCRIPT -TaskId $p.TaskId -Reason "ok" -Approved "C-350" -Deferred "C-352" -Rejected "C-999" -ProjectRoot $p.Root | Out-Null
        $gateDir = Join-Path $p.Root ".crucible/session/global/research_gate"
        $rec = @(Get-ChildItem -LiteralPath $gateDir -Filter "$($p.TaskId)-*.json")
        Assert-Result "one decision record" ($rec.Count -eq 1) "expected exactly one decision record"
        $obj = Get-Content -LiteralPath $rec[0].FullName -Raw | ConvertFrom-Json
        Assert-Result "outcome approved" ($obj.outcome -eq "approved") "outcome should be approved when items approved"
        Assert-Result "approved recorded" ($obj.approved -contains "C-350") "approved list missing C-350"
        Assert-Result "deferred recorded" ($obj.deferred -contains "C-352") "deferred list missing C-352"
        Assert-Result "rejected recorded" ($obj.rejected -contains "C-999") "rejected list missing C-999"
    }

    $results += Run-Test -Name "all-deferred decision files no stubs but still records and hands off" -Body {
        $p = New-GateProject -Root (Join-Path $tempRoot "defer")
        & $SCRIPT -TaskId $p.TaskId -Reason "not now" -Deferred "C-350","C-351" -ProjectRoot $p.Root | Out-Null
        $body = Get-Content -LiteralPath $p.GateFiling -Raw
        Assert-Result "no-stub path" ($body -match "No stubs to file") "should take the no-stubs branch"
        Assert-Result "still hands off" ($body -match "new-handoff\.ps1") "should still write a handoff"
        $gateDir = Join-Path $p.Root ".crucible/session/global/research_gate"
        $obj = Get-Content -LiteralPath (Get-ChildItem -LiteralPath $gateDir -Filter "$($p.TaskId)-*.json")[0].FullName -Raw | ConvertFrom-Json
        Assert-Result "outcome closed" ($obj.outcome -eq "closed") "outcome should be closed when nothing approved"
    }

    $results += Run-Test -Name "generated gate-filing.md is ASCII and BOM-free" -Body {
        $p = New-GateProject -Root (Join-Path $tempRoot "encoding")
        & $SCRIPT -TaskId $p.TaskId -Reason "clean" -Approved "C-350" -ProjectRoot $p.Root | Out-Null
        $bytes = [System.IO.File]::ReadAllBytes($p.GateFiling)
        $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
        Assert-Result "no BOM" (-not $hasBom) "gate-filing.md must be BOM-free"
        $nonAscii = @($bytes | Where-Object { $_ -gt 0x7F })
        Assert-Result "ascii only" ($nonAscii.Count -eq 0) "gate-filing.md must be ASCII-only"
    }

    $results += Run-Test -Name "empty decision is refused" -Body {
        $p = New-GateProject -Root (Join-Path $tempRoot "empty")
        $threw = $false
        try { & $SCRIPT -TaskId $p.TaskId -Reason "x" -ProjectRoot $p.Root 2>$null } catch { $threw = $true }
        Assert-Result "throws on empty decision" $threw "expected an error when no items are approved/deferred/rejected"
    }

    $results += Run-Test -Name "missing research session directory is refused" -Body {
        $root = Join-Path $tempRoot "nosession"
        $crucible = Join-Path $root ".crucible"
        New-Item -ItemType Directory -Path (Join-Path $crucible "backlog") -Force | Out-Null
        "paths:`n  backlog: `"backlog`"`n  session: `"session`"" | Set-Content -LiteralPath (Join-Path $crucible "config.yaml") -Encoding UTF8
        $threw = $false
        try { & $SCRIPT -TaskId "R-099" -Reason "x" -Approved "C-1" -ProjectRoot $root 2>$null } catch { $threw = $true }
        Assert-Result "throws without research session" $threw "expected an error when the research session dir is absent"
    }

} finally {
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

$failures = @($results | Where-Object { -not $_ }).Count
if ($failures -gt 0) {
    Write-Host ("`n{0} test(s) failed." -f $failures) -ForegroundColor Red
    exit 1
}
Write-Host "`nALL TESTS PASSED" -ForegroundColor Green
exit 0
