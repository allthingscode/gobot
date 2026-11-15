# Item 259: a not-run line for a renamed or removed check is retired only by an explicit human
# decision, which keeps its history; nothing else erases that evidence.

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$REPO_ROOT = (Resolve-Path -Path "$PSScriptRoot/../..").Path
. (Join-Path $PSScriptRoot '_harness.ps1')
. (Join-Path $REPO_ROOT "powershell/lib/platform.ps1")
$Quiet = $true
. (Join-Path $REPO_ROOT "powershell/crucible-lib.ps1")

$RETIRE = Join-Path $REPO_ROOT "powershell/retire-check-not-run.ps1"
$TASK = "F-259"
$results = @()
$tempRoot = New-TestFixtureRoot -NameHint "retire-check-not-run"

function New-RetireProject {
    param([Parameter(Mandatory = $true)][string]$Name)
    $root = Join-Path $tempRoot $Name
    New-Item -ItemType Directory -Path (Join-Path $root ".crucible") -Force | Out-Null
    @('project:', '  name: "Retire test"', 'review:') | Set-Content -LiteralPath (Join-Path $root ".crucible/config.yaml") -Encoding UTF8
    return $root
}

function Get-RetireSession {
    param([Parameter(Mandatory = $true)][string]$Root)
    return (Get-ConfiguredPath -Key "session" -ProjectRoot $Root)
}

function Invoke-Retire {
    param([Parameter(Mandatory = $true)][string]$Root, [Parameter(Mandatory = $true)][string[]]$RetireArgs)
    $shell = (Get-Process -Id $PID).Path
    return (Invoke-ExternalCommand { & $shell -NoProfile -ExecutionPolicy Bypass -File $RETIRE -TaskId $TASK -ProjectRoot $Root @RetireArgs 2>&1 })
}

function Get-FileText {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return "<absent>" }
    return [IO.File]::ReadAllText($Path)
}

try {
    $results += Run-Test -Name "A renamed check's line is retired with its reason, replacement and history" -Body {
        $root = New-RetireProject -Name "rename"
        $session = Get-RetireSession -Root $root
        Write-CheckNotRun -SessionDir $session -TaskId $TASK -Source "isolated checks" -Check "lint: go" -Reason "requires command 'golangci-lint' on PATH"
        Write-CheckNotRun -SessionDir $session -TaskId $TASK -Source "isolated checks" -Check "gpu check" -Reason "requires command 'gpu-tool' on PATH"
        Write-CheckNotRun -SessionDir $session -TaskId $TASK -Source "scope gate" -Check "lint: go" -Reason "another source, same name"

        $r = Invoke-Retire -Root $root -RetireArgs @("-Source", "isolated checks", "-Check", "lint: go", "-Reason", "lint: go was renamed lint-go in config.yaml", "-ReplacedBy", "lint-go")
        Assert-Result -Name "retire exits 0" -Condition ($r.ExitCode -eq 0) -FailureMessage ("expected exit 0, got " + $r.ExitCode + ". Output: " + $r.Output)

        $record = @(Get-ChecksNotRun -SessionDir $session -TaskId $TASK)
        Assert-Result -Name "the retired line leaves the record" -Condition (@($record | Where-Object { $_.StartsWith("[isolated checks v2] lint\: go: ") }).Count -eq 0) -FailureMessage ($record -join "`n")
        Assert-Result -Name "other checks and other sources stay recorded" -Condition ($record.Count -eq 2 -and @($record | Where-Object { $_.StartsWith("[isolated checks v2] gpu check: ") }).Count -eq 1 -and @($record | Where-Object { $_.StartsWith("[scope gate v2] lint\: go: ") }).Count -eq 1) -FailureMessage ($record -join "`n")

        $history = @(Get-ChecksNotRunRetired -SessionDir $session -TaskId $TASK)
        $expected = '^\[retired \d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ\] \[isolated checks v2\] lint\\: go: requires command ''golangci-lint'' on PATH \| reason: lint: go was renamed lint-go in config\.yaml \| replaced by: lint-go$'
        Assert-Result -Name "the history keeps the line, time, reason and replacement" -Condition ($history.Count -eq 1 -and $history[0] -cmatch $expected) -FailureMessage ($history -join "`n")

        $r2 = Invoke-Retire -Root $root -RetireArgs @("-Source", "isolated checks", "-Check", "gpu check", "-Reason", "The GPU check was removed from config.yaml")
        Assert-Result -Name "a removal retires without a replacement" -Condition ($r2.ExitCode -eq 0) -FailureMessage $r2.Output
        $history = @(Get-ChecksNotRunRetired -SessionDir $session -TaskId $TASK)
        Assert-Result -Name "history is appended, never rewritten" -Condition ($history.Count -eq 2 -and $history[0] -cmatch $expected -and $history[1] -cmatch '\[isolated checks v2\] gpu check: .* \| reason: The GPU check was removed from config\.yaml$') -FailureMessage ($history -join "`n")

        # No other writer may clear the history: the record's own writers leave it as it is.
        $historyPath = Get-ChecksNotRunRetiredPath -SessionDir $session -TaskId $TASK
        $before = Get-FileText -Path $historyPath
        Write-CheckNotRun -SessionDir $session -TaskId $TASK -Source "isolated checks" -Check "gpu check" -Reason "skipped again"
        Clear-ChecksNotRun -SessionDir $session -TaskId $TASK -Source "isolated checks" -Check "gpu check"
        Clear-ChecksNotRun -SessionDir $session -TaskId $TASK -Source "scope gate" -Check "lint: go"
        Assert-Result -Name "record writers do not touch the history" -Condition ((Get-FileText -Path $historyPath) -ceq $before) -FailureMessage (Get-FileText -Path $historyPath)
        Assert-Result -Name "the history outlives an empty record" -Condition (@(Get-ChecksNotRun -SessionDir $session -TaskId $TASK).Count -eq 0 -and @(Get-ChecksNotRunRetired -SessionDir $session -TaskId $TASK).Count -eq 2) -FailureMessage (Get-FileText -Path $historyPath)
    }

    $results += Run-Test -Name "Retirement refuses a missing line or a stock-phrase reason and changes nothing" -Body {
        $root = New-RetireProject -Name "refusals"
        $session = Get-RetireSession -Root $root
        $none = Invoke-Retire -Root $root -RetireArgs @("-Source", "isolated checks", "-Check", "lint", "-Reason", "lint was removed from config.yaml")
        Assert-Result -Name "no record refuses" -Condition ($none.ExitCode -eq 1 -and $none.Output -match 'No not-run line') -FailureMessage ("exit " + $none.ExitCode + ": " + $none.Output)

        Write-CheckNotRun -SessionDir $session -TaskId $TASK -Source "isolated checks" -Check "lint" -Reason "requires command 'lint' on PATH"
        $recordPath = Get-ChecksNotRunPath -SessionDir $session -TaskId $TASK
        $historyPath = Get-ChecksNotRunRetiredPath -SessionDir $session -TaskId $TASK
        $recordBefore = Get-FileText -Path $recordPath
        $cases = [ordered]@{
            "another check" = @("-Source", "isolated checks", "-Check", "lint: go", "-Reason", "lint: go was removed from config.yaml")
            "another source" = @("-Source", "scope gate", "-Check", "lint", "-Reason", "lint was removed from config.yaml")
            "stock phrase" = @("-Source", "isolated checks", "-Check", "lint", "-Reason", "  Looks Good  ")
            "blank reason" = @("-Source", "isolated checks", "-Check", "lint", "-Reason", "   ")
            # Codex review of 4aa30e5: the line break is flattened on storage, so the stored
            # reason would be the stock phrase the rule refuses.
            "line-broken stock phrase" = @("-Source", "isolated checks", "-Check", "lint", "-Reason", "looks`ngood")
        }
        foreach ($case in $cases.Keys) {
            $r = Invoke-Retire -Root $root -RetireArgs $cases[$case]
            Assert-Result -Name "$case refuses" -Condition ($r.ExitCode -eq 1) -FailureMessage ("exit " + $r.ExitCode + ": " + $r.Output)
            Assert-Result -Name "$case names why" -Condition ($r.Output -match $(if ($case -like "another*") { 'No not-run line' } else { 'stock phrase' })) -FailureMessage $r.Output
            Assert-Result -Name "$case leaves the record" -Condition ((Get-FileText -Path $recordPath) -ceq $recordBefore) -FailureMessage (Get-FileText -Path $recordPath)
            Assert-Result -Name "$case writes no history" -Condition (-not (Test-Path -LiteralPath $historyPath)) -FailureMessage (Get-FileText -Path $historyPath)
        }

        # The owning function enforces the rule on the reason as stored, whoever calls it.
        foreach ($reason in @("looks`r`ngood", "ship`nit", "`nOK`n")) {
            $refusal = ""
            try { $null = Move-CheckNotRunToRetired -SessionDir $session -TaskId $TASK -Source "isolated checks" -Check "lint" -Reason $reason }
            catch { $refusal = $_.Exception.Message }
            $shown = $reason.Replace("`r", "\r").Replace("`n", "\n")
            Assert-Result -Name "the retirement owner refuses a line-broken stock phrase" -Condition ($refusal -match 'stock phrase') -FailureMessage ("reason '" + $shown + "' was not refused: " + $refusal)
            Assert-Result -Name "the owner's refusal leaves the record" -Condition ((Get-FileText -Path $recordPath) -ceq $recordBefore) -FailureMessage ("reason '" + $shown + "': " + (Get-FileText -Path $recordPath))
            Assert-Result -Name "the owner's refusal writes no history" -Condition (-not (Test-Path -LiteralPath $historyPath)) -FailureMessage ("reason '" + $shown + "': " + (Get-FileText -Path $historyPath))
        }
    }

    $results += Run-Test -Name "The Human Gate menu shows retired lines as history and the Reviewer prompt does not" -Body {
        $root = New-RetireProject -Name "surfaces"
        $session = Get-RetireSession -Root $root
        Write-CheckNotRun -SessionDir $session -TaskId $TASK -Source "isolated checks" -Check "old lint" -Reason "requires command 'old-lint' on PATH"
        Write-CheckNotRun -SessionDir $session -TaskId $TASK -Source "isolated checks" -Check "gpu check" -Reason "requires command 'gpu-tool' on PATH"
        $r = Invoke-Retire -Root $root -RetireArgs @("-Source", "isolated checks", "-Check", "old lint", "-Reason", "old lint was renamed new-lint", "-ReplacedBy", "new-lint")
        Assert-Result -Name "retire exits 0" -Condition ($r.ExitCode -eq 0) -FailureMessage $r.Output

        $section = Format-ChecksNotRunSection -SessionDir $session -TaskId $TASK
        Assert-Result -Name "the Reviewer prompt keeps the live line" -Condition ($section.Contains("gpu check: requires command 'gpu-tool' on PATH")) -FailureMessage $section
        Assert-Result -Name "the Reviewer prompt omits the retired line" -Condition (-not $section.Contains("old lint")) -FailureMessage $section

        $ctx = @{ RepoRoot = $root; CrucibleRoot = ".crucible"; SessionDir = $session; TaskId = $TASK; Quiet = $true }
        $pendingPath = Join-Path $session "$TASK/pending.json"
        $output = (Invoke-ExternalCommand -AsLines { & { Write-GatePendingSurface -Context $ctx -RepoRoot $root -SessionDir $session -TaskId $TASK -PendingFilePath $pendingPath -TaskBranchExists $false -NoCodeReviewHint "No code changes" -AcceptDesc "accept the work" } 6>&1 } | Out-String)
        $notRunIndex = $output.IndexOf("[CHECKS NOT RUN]")
        $retiredIndex = $output.IndexOf("[CHECKS RETIRED]")
        Assert-Result -Name "the menu still lists the live line as not run" -Condition ($notRunIndex -ge 0 -and $output -match '  - \[isolated checks v2\] gpu check: ') -FailureMessage $output
        Assert-Result -Name "the menu shows the retired line as history" -Condition ($retiredIndex -gt $notRunIndex -and $output -cmatch '  - \[retired [^\]]+\] \[isolated checks v2\] old lint: .* \| reason: old lint was renamed new-lint \| replaced by: new-lint') -FailureMessage $output
        $notRunBlock = if ($retiredIndex -gt $notRunIndex) { $output.Substring($notRunIndex, $retiredIndex - $notRunIndex) } else { $output }
        Assert-Result -Name "the retired line is not listed as not run" -Condition (-not $notRunBlock.Contains("old lint")) -FailureMessage $output
    }
}
finally {
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-TestFileSummary -Results $results
