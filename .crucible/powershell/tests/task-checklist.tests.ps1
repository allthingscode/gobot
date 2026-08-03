# Tests for the shared task checklist helper.

$ErrorActionPreference = "Stop"
$REPO_ROOT = (Resolve-Path -Path "$PSScriptRoot/../..").Path
. (Join-Path $PSScriptRoot '_harness.ps1')
$HELPER = Join-Path $REPO_ROOT "powershell/lib/task-checklist.ps1"
. $HELPER

$results = @()







$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("crucible-task-checklist-test-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

try {
    $results += Run-Test -Name "Complete required checklist passes" -Body {
        $taskPath = Join-Path $tempRoot "complete-task.md"
        @"
# Task

## Task List
- [x] Implement the change
- [X] Run tests

## Notes
- [ ] Optional follow-up
"@ | Set-Content -LiteralPath $taskPath -Encoding UTF8

        $result = Get-TaskChecklistGateResult -TaskMdPath $taskPath
        Assert-Result -Name "section found" -Condition $result.RequiredSectionFound -FailureMessage "required section was not found"
        Assert-Result -Name "required unchecked" -Condition ($result.RequiredUnchecked.Count -eq 0) -FailureMessage "complete required checklist should have no unchecked items"
        Assert-Result -Name "required malformed" -Condition ($result.RequiredMalformed.Count -eq 0) -FailureMessage "complete required checklist should have no malformed items"
        Assert-Result -Name "optional unchecked" -Condition ($result.OptionalUnchecked.Count -eq 1) -FailureMessage "optional unchecked item should be reported as non-blocking"
    }

    $results += Run-Test -Name "Missing required section returns failure shape" -Body {
        $taskPath = Join-Path $tempRoot "missing-section-task.md"
        @"
# Task

## Notes
- [ ] Optional item
"@ | Set-Content -LiteralPath $taskPath -Encoding UTF8

        $result = Get-TaskChecklistGateResult -TaskMdPath $taskPath
        Assert-Result -Name "section missing" -Condition (-not $result.RequiredSectionFound) -FailureMessage "required section should not be found"
        Assert-Result -Name "required unchecked empty" -Condition ($result.RequiredUnchecked.Count -eq 0) -FailureMessage "missing section should not invent required unchecked items"
        Assert-Result -Name "optional unchecked captured" -Condition ($result.OptionalUnchecked.Count -eq 1) -FailureMessage "unchecked item outside required section should be optional"
    }

    $results += Run-Test -Name "Unchecked and malformed required items are identified" -Body {
        $taskPath = Join-Path $tempRoot "required-failures-task.md"
        @"
# Task

## Task List
- [x] Done item
- [ ] Required unchecked
- [/] Required in progress
- [?] Required malformed
"@ | Set-Content -LiteralPath $taskPath -Encoding UTF8

        $result = Get-TaskChecklistGateResult -TaskMdPath $taskPath
        Assert-Result -Name "required unchecked count" -Condition ($result.RequiredUnchecked.Count -eq 2) -FailureMessage "expected unchecked and in-progress required items"
        Assert-Result -Name "unchecked line" -Condition ($result.RequiredUnchecked[0].line -eq 5) -FailureMessage "unchecked item line number changed"
        Assert-Result -Name "in-progress text" -Condition ($result.RequiredUnchecked[1].text -eq "- [/] Required in progress") -FailureMessage "in-progress item text changed"
        Assert-Result -Name "malformed count" -Condition ($result.RequiredMalformed.Count -eq 1) -FailureMessage "expected one malformed required item"
        Assert-Result -Name "malformed line" -Condition ($result.RequiredMalformed[0].line -eq 7) -FailureMessage "malformed item line number changed"
    }

    $results += Run-Test -Name "Post-session factory init checklist line is ignored" -Body {
        $taskPath = Join-Path $tempRoot "factory-init-task.md"
        @"
# Task

## Task List
- [ ] Run factory.ps1 -Init -TaskId F-001
- [ ] Real unfinished item
"@ | Set-Content -LiteralPath $taskPath -Encoding UTF8

        $result = Get-TaskChecklistGateResult -TaskMdPath $taskPath
        Assert-Result -Name "factory init ignored" -Condition ($result.RequiredUnchecked.Count -eq 1) -FailureMessage "factory init instruction should be ignored"
        Assert-Result -Name "real item retained" -Condition ($result.RequiredUnchecked[0].text -eq "- [ ] Real unfinished item") -FailureMessage "real unchecked item was not retained"
    }

    $results += Run-Test -Name "Missing task file returns empty result" -Body {
        $taskPath = Join-Path $tempRoot "does-not-exist.md"
        $result = Get-TaskChecklistGateResult -TaskMdPath $taskPath
        Assert-Result -Name "section missing" -Condition (-not $result.RequiredSectionFound) -FailureMessage "missing file should not report required section"
        Assert-Result -Name "required unchecked empty" -Condition ($result.RequiredUnchecked.Count -eq 0) -FailureMessage "missing file should have no required unchecked items"
        Assert-Result -Name "optional unchecked empty" -Condition ($result.OptionalUnchecked.Count -eq 0) -FailureMessage "missing file should have no optional unchecked items"
        Assert-Result -Name "malformed empty" -Condition ($result.RequiredMalformed.Count -eq 0) -FailureMessage "missing file should have no malformed items"
    }

    $results += Run-Test -Name "Inapplicable skip marker [-] is accepted and not blocking" -Body {
        $taskPath = Join-Path $tempRoot "skipped-task.md"
        @"
# Task

## Task List
- [x] Done item
- [-] Skipped item
- [X] Another done item
"@ | Set-Content -LiteralPath $taskPath -Encoding UTF8

        $result = Get-TaskChecklistGateResult -TaskMdPath $taskPath
        Assert-Result -Name "required unchecked is empty" -Condition ($result.RequiredUnchecked.Count -eq 0) -FailureMessage "expected no unchecked items"
        Assert-Result -Name "required malformed is empty" -Condition ($result.RequiredMalformed.Count -eq 0) -FailureMessage "expected no malformed items"
    }

    $results += Run-Test -Name "Conditional optional checklist item is non-blocking" -Body {
        $taskPath = Join-Path $tempRoot "conditional-optional-task.md"
        @"
# Task

## Task List
- [x] Required implementation step

## Optional Steps
- [ ] Phase 1 (if needed): write implementation plan in task.md
"@ | Set-Content -LiteralPath $taskPath -Encoding UTF8

        $result = Get-TaskChecklistGateResult -TaskMdPath $taskPath
        Assert-Result -Name "required unchecked is empty" -Condition ($result.RequiredUnchecked.Count -eq 0) -FailureMessage "expected no required unchecked items"
        Assert-Result -Name "optional unchecked count" -Condition ($result.OptionalUnchecked.Count -eq 1) -FailureMessage "expected optional conditional item to be non-blocking"
        Assert-Result -Name "optional unchecked text" -Condition ($result.OptionalUnchecked[0].text -eq "- [ ] Phase 1 (if needed): write implementation plan in task.md") -FailureMessage "optional conditional item text changed"
    }
} finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

$failed = @($results | Where-Object { -not $_ }).Count
if ($failed -gt 0) {
    Write-Host ("`n$failed task checklist test(s) failed.") -ForegroundColor Red
    exit 1
}
Write-Host "`nAll task checklist tests passed." -ForegroundColor Green
exit 0
