# Match generated prompt rules without freezing their wording. TODO item 194.
# Unit tests for record-research-gate.ps1: the post-Research-Gate continuation helper that
# records a human gate decision and generates a self-contained gate-filing.md so a
# re-dispatched Researcher files the approved stubs instead of re-presenting the gate.

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$REPO_ROOT = (Resolve-Path -Path "$PSScriptRoot/../..").Path
. (Join-Path $PSScriptRoot '_harness.ps1')
. (Join-Path $REPO_ROOT "powershell/lib/platform.ps1")
$SCRIPT = Join-Path $REPO_ROOT "powershell/record-research-gate.ps1"

$results = @()

function New-GateProject {
    param([Parameter(Mandatory=$true)][string]$Root, [string]$TaskId = "R-021")
    $crucible = Join-Path $Root ".crucible"
    $researchSession = Join-Path $crucible "session/$TaskId/research"
    $researchDir = Join-Path $crucible "research"
    New-Item -ItemType Directory -Path $researchSession, $researchDir, (Join-Path $crucible "backlog") -Force | Out-Null
    "paths:`n  backlog: `".crucible/backlog`"`n  session: `".crucible/session`"" | Set-Content -LiteralPath (Join-Path $crucible "config.yaml") -Encoding UTF8
    "# findings" | Set-Content -LiteralPath (Join-Path $researchDir "$TaskId`_Quality_Audit_20260715.md") -Encoding UTF8
    return @{ Root = $Root; TaskId = $TaskId; GateFiling = (Join-Path $researchSession "gate-filing.md") }
}

$tempRoot = New-TestFixtureRoot -NameHint "research-gate-test"

try {
    $results += Run-Test -Name "records approval and generates a gate-filing prompt listing approved items" -Body {
        $p = New-GateProject -Root (Join-Path $tempRoot "approve")
        & $SCRIPT -TaskId $p.TaskId -Reason "Gate approved" -Approved "C-350","C-351" -ProjectRoot $p.Root | Out-Null
        Assert-Result "gate-filing written" (Test-Path -LiteralPath $p.GateFiling) "gate-filing.md was not generated"
        $body = Get-Content -LiteralPath $p.GateFiling -Raw
        Assert-Result "names approved C-350" ($body -match "C-350") "approved item C-350 not listed"
        Assert-Result "names approved C-351" ($body -match "C-351") "approved item C-351 not listed"
        Assert-Result "forbids re-audit" ($body -match '(?im)^(?=[^\r\n]*(?:do not|must not|never))(?=[^\r\n]*(?:re-run|repeat))(?=[^\r\n]*audit)[^\r\n]+\r?$') "missing the do-not-re-audit directive"
        Assert-Result "instructs handoff" ($body -match "new-handoff\.ps1") "missing the handoff instruction"
        Assert-Result "passes HumanApproved" ($body -match "-HumanApproved") "handoff command should record HumanApproved"
    }

    # TODO item 208: background pwsh launches re-split multi-word -PromptText values.
    $results += Run-Test -Name "printed Codex dispatch uses a file-sourced one-line pointer" -Body {
        $p = New-GateProject -Root (Join-Path $tempRoot "dispatch with spaces")
        $output = (& $SCRIPT -TaskId $p.TaskId -Reason "ok" -Approved "C-350" -ProjectRoot $p.Root 6>&1 | Out-String)
        $codex = @($output -split "`r?`n" | Where-Object { $_ -match '^    Codex:' })
        Assert-Result "one Codex command" ($codex.Count -eq 1) "expected one printed Codex command"
        Assert-Result "no PromptText" ($codex[0] -notmatch '-PromptText') "printed Codex command must not use -PromptText"
        $pointerPath = Join-Path (Split-Path $p.GateFiling) "gate-filing-pointer.md"
        Assert-Result "quoted PromptFile path" ($codex[0].Contains('-PromptFile "' + $pointerPath + '"')) "expected quoted pointer file path"
        # Item 219: a Codex level includes both model and effort.
        Assert-Result "model and effort in dispatch" ($codex[0] -match '-Model <model> -Effort <effort>') "expected both halves of the Codex level"
        Assert-Result "task-scoped dispatch" ($codex[0] -match '-TaskId R-021 -Phase research') "expected TaskId and Phase"
        Assert-Result "pointer written" (Test-Path -LiteralPath $pointerPath) "missing pointer file"
        $pointer = [IO.File]::ReadAllText($pointerPath)
        $expected = "Researcher: $($p.TaskId) - read and follow all instructions in $($p.GateFiling)"
        Assert-Result "one-line pointer content" ($pointer.TrimEnd("`r", "`n") -eq $expected) "pointer must direct the Researcher to gate-filing.md"
        $bytes = [IO.File]::ReadAllBytes($pointerPath)
        Assert-Result "pointer ASCII without BOM" (@($bytes | Where-Object { $_ -gt 127 }).Count -eq 0) "pointer must be ASCII and BOM-free"
        Assert-Result "Claude pointer unchanged" ($output.Contains('Claude: Agent tool, prompt = "' + $expected + '"')) "expected Claude inline pointer"
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

    $results += Run-Test -Name "gate-filing never tells the Researcher to set a status the deployment gate refuses" -Body {
        # R-031's Researcher followed "set R-031's own status to Production", and the Operator
        # had to revert it: the deployment gate's premature-status guard (F12) refuses a
        # terminal status before a human accepts. Read the terminal set from that guard so a
        # status added there is checked here too.
        $gatesText = Get-Content -LiteralPath (Join-Path $REPO_ROOT "powershell/lib/crucible-gates.ps1") -Raw
        $terminal = @()
        if ($gatesText -match "(?s)Premature Production/Resolved status guard.*?\\b\(\?:([A-Za-z|]+)\)\\b") {
            $terminal = @($Matches[1] -split '\|')
        }
        Assert-Result "terminal set read from the F12 guard" ($terminal.Count -ge 2) "could not read the terminal statuses from the F12 guard in crucible-gates.ps1"
        foreach ($case in @(@{ Name = "approved"; Args = @{ Approved = @("C-350") } }, @{ Name = "deferred"; Args = @{ Deferred = @("C-350") } })) {
            $p = New-GateProject -Root (Join-Path $tempRoot ("status-" + $case.Name))
            $gateArgs = $case.Args
            & $SCRIPT -TaskId $p.TaskId -Reason "ok" -ProjectRoot $p.Root @gateArgs | Out-Null
            $body = Get-Content -LiteralPath $p.GateFiling -Raw
            $sentences = @(($body -replace "\s+", " ") -split "(?<=[.:;])\s+")
            foreach ($status in $terminal) {
                $offending = @($sentences | Where-Object { $_ -match "\b$status\b" -and $_ -notmatch '(?i)\b(?:do not|must not|never)\b' })
                Assert-Result "$($case.Name): no instruction to set $status" ($offending.Count -eq 0) ("gate-filing tells the Researcher to set " + $status + ": " + ($offending -join " | "))
            }
            Assert-Result "$($case.Name): says to leave the parent status" ($body -match ('(?im)^(?=[^\r\n]*' + [regex]::Escape($p.TaskId) + ')(?=[^\r\n]*status)(?=[^\r\n]*(?:leave|keep))(?=[^\r\n]*(?:as it is|unchanged|alone))[^\r\n]+\r?$')) "gate-filing should tell the Researcher to leave the parent status alone"
        }
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

    $results += Run-Test -Name "a gate recorded through pwsh -File stores bare IDs and a prompt with real paths (item 174)" -Body {
        # gobot R-040: the quotes reached the script, and the prompt named `$findingsRel and
        # `$CrucibleRoot literally because a Markdown backtick escaped the dollar sign.
        $p = New-GateProject -Root (Join-Path $tempRoot "pwsh-file")
        $run = Invoke-ExternalCommand { & (Get-PwshCommand) -NoProfile -File $SCRIPT -TaskId $p.TaskId -Reason "ok" -Approved '"C-350","C-351"' -ProjectRoot $p.Root }
        Assert-Result "exit 0" ($run.ExitCode -eq 0) ("record-research-gate failed: " + $run.Output)
        $gateDir = Join-Path $p.Root ".crucible/session/global/research_gate"
        $obj = Get-Content -LiteralPath (Get-ChildItem -LiteralPath $gateDir -Filter "$($p.TaskId)-*.json")[0].FullName -Raw | ConvertFrom-Json
        Assert-Result "bare IDs recorded" ((@($obj.approved) -join ",") -eq "C-350,C-351") ("approved recorded as: " + (@($obj.approved) -join ","))
        $body = Get-Content -LiteralPath $p.GateFiling -Raw
        Assert-Result "no dollar sign" ($body -notmatch '\$') ("gate-filing.md holds an unexpanded variable: " + $body)
        Assert-Result "names the findings artifact" ($body -match '`\.crucible/research/R-021_Quality_Audit_20260715\.md`') "gate-filing.md should name the findings artifact in backticks"
        Assert-Result "names the backlog path" ($body -match '`\.crucible/backlog/\{bugs,chores,features\}/active/`') "gate-filing.md should name the backlog directory in backticks"
        Assert-Result "handoff IDs singly quoted" ($body -match '-HumanApproved "C-350","C-351"') "handoff command should quote each ID once"
        Assert-Result "no suspicious-content sentinel" ($body -notmatch 'SuspiciousContent') "the handoff command must not pass -SuspiciousContent"
        Assert-Result "stubs filed as Stub" ($body -match 'status: "Stub"' -and $body -notmatch 'status: "Ready"') "stubs must be filed with status Stub for the Stub-Only Close-Out"
    }

    $results += Run-Test -Name "a value that is not a backlog ID is refused (item 174)" -Body {
        $p = New-GateProject -Root (Join-Path $tempRoot "bad-id")
        $threw = $false
        try { & $SCRIPT -TaskId $p.TaskId -Reason "x" -Approved "C-350","B034" -ProjectRoot $p.Root 2>$null } catch { $threw = ($_.Exception.Message -match "'B034' is not a backlog item ID") }
        Assert-Result "refuses B034" $threw "expected a refusal naming B034"
        Assert-Result "writes no gate-filing" (-not (Test-Path -LiteralPath $p.GateFiling)) "a refused gate must not write gate-filing.md"
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
        "paths:`n  backlog: `".crucible/backlog`"`n  session: `".crucible/session`"" | Set-Content -LiteralPath (Join-Path $crucible "config.yaml") -Encoding UTF8
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
