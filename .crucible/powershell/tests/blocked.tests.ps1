# Tests for the shared blocked task record helper.

$ErrorActionPreference = "Stop"
$REPO_ROOT = (Resolve-Path -Path "$PSScriptRoot/../..").Path
. (Join-Path $PSScriptRoot '_harness.ps1')
$CRUCIBLE_LIB = Join-Path $REPO_ROOT "powershell/crucible-lib.ps1"
$HELPER = Join-Path $REPO_ROOT "powershell/lib/blocked.ps1"
$Quiet = $true
. $CRUCIBLE_LIB
. $HELPER

$results = @()







$tempRoot = New-TestFixtureRoot -NameHint "blocked-test"
$backlogDir = Join-Path $tempRoot "backlog"
$frameworkDir = Join-Path $tempRoot "powershell"
New-Item -ItemType Directory -Path $backlogDir -Force | Out-Null
New-Item -ItemType Directory -Path $frameworkDir -Force | Out-Null

$stubScript = Join-Path $frameworkDir "update-session-state.ps1"
@'
param(
    [string]$Specialist,
    [string]$TaskId,
    [string]$UpdateJson,
    [bool]$Merge
)

$payload = [ordered]@{
    specialist = $Specialist
    task_id = $TaskId
    update_json = $UpdateJson
    merge = $Merge
}
$payload | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $PSScriptRoot "update-called.json") -Encoding UTF8
'@ | Set-Content -LiteralPath $stubScript -Encoding UTF8

try {
    foreach ($parameter in @('BacklogDir', 'FrameworkPowerShell')) {
        foreach ($mode in @('missing', 'empty')) {
            $results += Run-Test -Name "Required $parameter refuses $mode despite ambient defaults" -Body {
                $caseRoot = Join-Path $tempRoot "$parameter-$mode"
                New-Item -ItemType Directory -Path $caseRoot -Force | Out-Null
                $child = Join-Path $caseRoot 'required.ps1'
                $supplied = if ($parameter -eq 'BacklogDir') { "-FrameworkPowerShell '$frameworkDir'" } else { "-BacklogDir '$caseRoot'" }
                if ($mode -eq 'empty') { $supplied += " -$parameter ''" }
                @"
`$ErrorActionPreference = 'Stop'
`$PSStyle.OutputRendering = 'PlainText'
. '$CRUCIBLE_LIB'
`$Quiet = `$true
`$backlogDir = '$caseRoot'
`$FRAMEWORK_POWERSHELL = '$frameworkDir'
Write-BlockedTaskRecord -TaskId F-369 -CircuitBreaker fixture -AttemptCount 1 -LastPhase implementation -Summary fixture $supplied
Write-Host 'SILENT_SUCCESS'
"@ | Set-Content -LiteralPath $child -Encoding utf8
                $res = Invoke-ExternalCommand { & (Get-PwshCommand) -NoProfile -NonInteractive -File $child }
                Assert-Result 'required input refuses' ($res.ExitCode -ne 0 -and $res.Output -notmatch 'SILENT_SUCCESS') $res.Output
                Assert-Result 'refusal names required parameter' (($res.Output -match ("mandatory[\s|]+parameters:[\s|]*\b" + $parameter + "\b")) -or ($res.Output -match ("parameter '" + $parameter + "'"))) $res.Output
                Assert-Result 'no partial blocked record' (-not (Test-Path (Join-Path $caseRoot 'blocked'))) $res.Output
            }
        }
    }
    $results += Run-Test -Name "Item255 blocked record asks the owner for the backlog ancestor" -Body {
        $caseRoot = Join-Path $tempRoot "item255-ancestor"
        $caseBacklog = Join-Path $caseRoot "external/backlog"
        $caseFramework = Join-Path $caseRoot "framework"
        New-Item -ItemType Directory -Force -Path $caseBacklog, $caseFramework | Out-Null
        $capture = Join-Path $caseFramework "root.txt"
        Set-Content -LiteralPath (Join-Path $caseFramework "update-session-state.ps1") -Encoding UTF8 -Value @'
param($Specialist, $TaskId, $UpdateJson, $Merge, $ProjectRoot)
Set-Content -LiteralPath (Join-Path $PSScriptRoot "root.txt") -Value $ProjectRoot
'@
        function Resolve-CrucibleProjectRoot {
            param([string]$AncestorOf)
            if ($AncestorOf -ne $caseBacklog) { throw "wrong ancestor input" }
            return "owner-result"
        }
        $Context = @{}
        $repoRoot = ""
        Write-BlockedTaskRecord -TaskId "F-255" -CircuitBreaker "budget_exceeded" -AttemptCount 1 -LastPhase "verification" -Summary "Test" -BacklogDir $caseBacklog -FrameworkPowerShell $caseFramework
        Assert-Result "blocked record routes through owner" ((Get-Content -LiteralPath $capture -Raw).Trim() -eq "owner-result") "blocked helper bypassed ancestor owner"
    }

    $results += Run-Test -Name "Write-BlockedTaskRecord creates blocked record" -Body {
        Write-BlockedTaskRecord -TaskId "F-010" -CircuitBreaker "budget_exceeded" -AttemptCount 7 -LastPhase "verification" -Summary "Too many handoffs" -Artifacts @("report.md", "log.txt") -BacklogDir $backlogDir -FrameworkPowerShell $frameworkDir

        $blockedDir = Join-Path $backlogDir "blocked"
        Assert-Result -Name "blocked dir" -Condition (Test-Path -LiteralPath $blockedDir) -FailureMessage "blocked directory was not created"
        $records = @(Get-ChildItem -LiteralPath $blockedDir -Filter "F-010-*.json")
        Assert-Result -Name "one record" -Condition ($records.Count -eq 1) -FailureMessage "expected exactly one blocked record"
    }

    $results += Run-Test -Name "Blocked record contains required keys" -Body {
        $record = Get-ChildItem -LiteralPath (Join-Path $backlogDir "blocked") -Filter "F-010-*.json" | Select-Object -First 1 | Get-Content -Raw | ConvertFrom-Json

        Assert-Result -Name "task_id" -Condition ($record.task_id -eq "F-010") -FailureMessage "task_id changed"
        Assert-Result -Name "circuit_breaker" -Condition ($record.circuit_breaker -eq "budget_exceeded") -FailureMessage "circuit breaker changed"
        Assert-Result -Name "attempt_count" -Condition ($record.attempt_count -eq 7) -FailureMessage "attempt count changed"
        Assert-Result -Name "last_phase" -Condition ($record.last_phase -eq "verification") -FailureMessage "last phase changed"
        Assert-Result -Name "summary" -Condition ($record.summary -eq "Too many handoffs") -FailureMessage "summary changed"
        Assert-Result -Name "human decision" -Condition ($record.human_decision_needed -eq "Should we reduce scope, split the task, or abandon it?") -FailureMessage "default human decision changed"
        Assert-Result -Name "artifacts" -Condition (@($record.artifacts).Count -eq 2) -FailureMessage "artifacts changed"
    }

    $results += Run-Test -Name "Update session state side effect uses supplied framework path" -Body {
        $calledPath = Join-Path $frameworkDir "update-called.json"
        Assert-Result -Name "stub called" -Condition (Test-Path -LiteralPath $calledPath) -FailureMessage "update-session-state stub was not called"
        $called = Get-Content -LiteralPath $calledPath -Raw | ConvertFrom-Json
        Assert-Result -Name "stub specialist" -Condition ($called.specialist -eq "verification") -FailureMessage "specialist argument changed"
        Assert-Result -Name "stub task" -Condition ($called.task_id -eq "F-010") -FailureMessage "task argument changed"
        Assert-Result -Name "stub merge" -Condition ($called.merge -eq $true) -FailureMessage "merge argument changed"
        $update = $called.update_json | ConvertFrom-Json
        Assert-Result -Name "stub status" -Condition ($update.status -eq "blocked") -FailureMessage "status update changed"
        Assert-Result -Name "stub breaker" -Condition ($update.circuit_breaker -eq "budget_exceeded") -FailureMessage "circuit breaker update changed"
    }
} finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

$failed = @($results | Where-Object { -not $_ }).Count
if ($failed -gt 0) {
    Write-Host ("`n$failed blocked record test(s) failed.") -ForegroundColor Red
    exit 1
}
Write-Host "`nAll blocked record tests passed." -ForegroundColor Green
exit 0
