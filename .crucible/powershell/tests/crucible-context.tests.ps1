# Tests for the shared CrucibleContext required-key contract, and for the rule it exists
# to enforce: a gate function's event destination is declared, never inherited from the
# caller's dynamic scope.

$ErrorActionPreference = "Stop"
$REPO_ROOT = (Resolve-Path -Path "$PSScriptRoot/../..").Path
. (Join-Path $PSScriptRoot '_harness.ps1')
$CRUCIBLE_LIB = Join-Path $REPO_ROOT "powershell/crucible-lib.ps1"
$Quiet = $true
. $CRUCIBLE_LIB

$results = @()

function Get-ThrownMessage {
    param([Parameter(Mandatory=$true)][scriptblock]$Body)
    try {
        & $Body | Out-Null
        return ""
    } catch {
        return [string]$_.Exception.Message
    }
}

$results += Run-Test -Name "Assert-CrucibleContextKeys names the missing key" -Body {
    $message = Get-ThrownMessage { Assert-CrucibleContextKeys -Context @{ Handoff = "h" } -RequiredKeys @("Handoff", "SessionDir") }
    Assert-Result -Name "missing required key throws" -Condition ($message -ne "") -FailureMessage "a context missing SessionDir was accepted"
    Assert-Result -Name "missing required key is named" -Condition ($message -match "'SessionDir'") -FailureMessage ("expected the message to name SessionDir, got: " + $message)
}

$results += Run-Test -Name "Assert-CrucibleContextKeys accepts a present-but-null required key" -Body {
    # GateRedirectTarget and NextCrucibleCommand are $null on every run that is not a
    # redirect, so presence and non-nullness are genuinely different contracts. Collapsing
    # them into one would reject the normal case.
    $message = Get-ThrownMessage { Assert-CrucibleContextKeys -Context @{ GateRedirectTarget = $null } -RequiredKeys @("GateRedirectTarget") }
    Assert-Result -Name "present null required key accepted" -Condition ($message -eq "") -FailureMessage ("a null-valued required key was rejected: " + $message)
}

$results += Run-Test -Name "Assert-CrucibleContextKeys rejects a null value in the non-null list" -Body {
    $message = Get-ThrownMessage { Assert-CrucibleContextKeys -Context @{ LogFile = $null } -RequiredKeys @() -NonNullKeys @("LogFile") }
    Assert-Result -Name "null non-null key throws" -Condition ($message -ne "") -FailureMessage "a null LogFile was accepted"
    Assert-Result -Name "null non-null key is named" -Condition ($message -match "'LogFile'") -FailureMessage ("expected the message to name LogFile, got: " + $message)
    Assert-Result -Name "null is reported as null, not as missing" -Condition ($message -match "is null") -FailureMessage ("a present-but-null key should not be reported as missing, got: " + $message)
}

$results += Run-Test -Name "Assert-CrucibleContextKeys rejects a null context" -Body {
    $message = Get-ThrownMessage { Assert-CrucibleContextKeys -Context $null -RequiredKeys @("Handoff") }
    Assert-Result -Name "null context throws" -Condition ($message -match "CrucibleContext is null") -FailureMessage ("expected a null-context error, got: " + $message)
}

# Written as a sweep over the source rather than one test per function on purpose: a gate
# function added later that reads $Context.LogFile without declaring it is caught by this
# existing test instead of needing a new one. That is the failure this item is about -
# thirteen functions followed the convention, one did not, and nothing detected it.
$results += Run-Test -Name "Every gate function reading a log destination declares it" -Body {
    $gatesPath = Join-Path $REPO_ROOT "powershell/lib/crucible-gates.ps1"
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($gatesPath, [ref]$null, [ref]$null)
    $functions = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true))

    # Assert-CrucibleFrameworkIntegrity is deliberately exempt. It reports a context too
    # malformed to name a log file as an operator-readable reason and exits 2, with the
    # event write wrapped best-effort; asserting the contract there would replace that
    # verdict with a less useful crash. See its catch block.
    $exempt = @("Assert-CrucibleFrameworkIntegrity")

    $undeclared = @()
    foreach ($fn in $functions) {
        if ($exempt -contains $fn.Name) { continue }
        $body = $fn.Extent.Text
        if ($body -notmatch '\$Context\.LogFile') { continue }
        if ($body -notmatch 'Assert-CrucibleContextKeys') {
            $undeclared += ($fn.Name + " (no Assert-CrucibleContextKeys call)")
            continue
        }
        if ($body -notmatch '(?s)Assert-CrucibleContextKeys.*?"LogFile"') {
            $undeclared += ($fn.Name + " (LogFile absent from its key lists)")
        }
    }

    Assert-Result -Name "no gate function reads a log destination it did not declare" `
        -Condition ($undeclared.Count -eq 0) `
        -FailureMessage ("these functions read `$Context.LogFile without declaring it: " + ($undeclared -join "; "))

    # Guards the sweep itself: if the pattern stops matching anything, the assertion above
    # passes having checked nothing.
    $checked = @($functions | Where-Object { $exempt -notcontains $_.Name -and $_.Extent.Text -match '\$Context\.LogFile' })
    Assert-Result -Name "the sweep examined a non-empty set" -Condition ($checked.Count -ge 8) `
        -FailureMessage ("expected at least 8 gate functions reading `$Context.LogFile, found " + $checked.Count)
}

$results += Run-Test -Name "The human-gate helpers refuse a destination inherited from the caller" -Body {
    # Both used to read the ambient - Invoke-HumanGateMerge with a bare Write-EventLog
    # call, Invoke-HumanGateAction via Get-Variable up the scope chain. Setting the
    # historic names in the calling frame here is what makes the assertion load-bearing:
    # if either dependency goes back to being inherited, these calls succeed.
    $LOG_FILE = Join-Path ([System.IO.Path]::GetTempPath()) "crucible-ambient-should-not-be-used.jsonl"
    $CB_HISTORY_FILE = Join-Path ([System.IO.Path]::GetTempPath()) "crucible-ambient-cb-should-not-be-used.jsonl"

    $mergeMessage = Get-ThrownMessage {
        Invoke-HumanGateMerge -TaskId "F-CTX" -PrimaryBranch "master" -ProjectRoot $REPO_ROOT -Handoff $null
    }
    Assert-Result -Name "Invoke-HumanGateMerge requires a declared destination" -Condition ($mergeMessage -match "LogFile") `
        -FailureMessage ("expected a LogFile binding error, got: " + $mergeMessage)

    $actionMessage = Get-ThrownMessage {
        Invoke-HumanGateAction -TaskId "F-CTX" -Outcome "rejected" -ProjectRoot $REPO_ROOT
    }
    Assert-Result -Name "Invoke-HumanGateAction requires a declared destination" -Condition ($actionMessage -match "LogFile") `
        -FailureMessage ("expected a LogFile binding error, got: " + $actionMessage)

    Assert-Result -Name "neither helper wrote to the ambient path" `
        -Condition (-not (Test-Path -LiteralPath $LOG_FILE) -and -not (Test-Path -LiteralPath $CB_HISTORY_FILE)) `
        -FailureMessage "a human-gate helper wrote to the calling frame's log path"
}

$failed = @($results | Where-Object { -not $_ }).Count
if ($failed -gt 0) {
    Write-Host ("`n$failed Crucible context test(s) failed.") -ForegroundColor Red
    exit 1
}
Write-Host "`nAll Crucible context tests passed." -ForegroundColor Green
exit 0
