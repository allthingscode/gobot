# Tests for the shared task checklist helper.

$ErrorActionPreference = "Stop"
$REPO_ROOT = (Resolve-Path -Path "$PSScriptRoot/../..").Path
. (Join-Path $PSScriptRoot '_harness.ps1')
$HELPER = Join-Path $REPO_ROOT "powershell/lib/task-checklist.ps1"
. $HELPER

$results = @()







$tempRoot = New-TestFixtureRoot -NameHint "task-checklist-test"

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

    $results += Run-Test -Name "Post-session crucible init checklist line is ignored" -Body {
        $taskPath = Join-Path $tempRoot "crucible-init-task.md"
        @"
# Task

## Task List
- [ ] Run crucible.ps1 -Init -TaskId F-001
- [ ] Real unfinished item
"@ | Set-Content -LiteralPath $taskPath -Encoding UTF8

        $result = Get-TaskChecklistGateResult -TaskMdPath $taskPath
        Assert-Result -Name "crucible init ignored" -Condition ($result.RequiredUnchecked.Count -eq 1) -FailureMessage "post-session init instruction should be ignored"
        Assert-Result -Name "real item retained" -Condition ($result.RequiredUnchecked[0].text -eq "- [ ] Real unfinished item") -FailureMessage "real unchecked item was not retained"
    }

    $results += Run-Test -Name "REGRESSION: a task.md written before the entrypoint rename is still recognised" -Body {
        # task.md is adopter data that no update rewrites, so an in-flight task carries
        # the old entrypoint name across the upgrade. Reading only the new name turns
        # that line into a blocking unchecked item the moment the adopter updates.
        $taskPath = Join-Path $tempRoot "legacy-init-task.md"
        @"
# Task

## Task List
- [ ] Run factory.ps1 -Init -TaskId F-001
- [ ] Real unfinished item
"@ | Set-Content -LiteralPath $taskPath -Encoding UTF8

        $result = Get-TaskChecklistGateResult -TaskMdPath $taskPath
        Assert-Result -Name "legacy init line ignored" -Condition ($result.RequiredUnchecked.Count -eq 1) -FailureMessage "the pre-rename post-session line was counted as real unfinished work"
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

    # The rule the gate enforces has to be stated where the specialist reads it. All three
    # phases in TODO item 53's Pass 29 were blocked by this gate; every one of them had done
    # the work and simply had not ticked the boxes, because only the *exception* to the rule
    # was written down anywhere. Filed as item 59.
    #
    # Worded identically in every prompt on purpose. One canonical sentence that must match
    # byte for byte is what stops the five copies drifting the way the successor declarations
    # did in item 58.
    $results += Run-Test -Name "Every phase prompt states the checklist precondition" -Body {
        $canonical = '- [ ] Every required `## Task List` item in `task.md` is `[x]`, or `[-]` if genuinely skipped, or moved under `## Optional Steps` - a `[ ]` or `[/]` item left in that section fails the gate and exits the run with code 2'

        $promptFiles = @(Get-ChildItem -Path (Join-Path $REPO_ROOT "prompts") -Filter "*_prompt.md" -File)
        Assert-Result -Name "phase prompts were found" -Condition ($promptFiles.Count -ge 1) -FailureMessage "no prompts/*_prompt.md matched, so the scan below would report clean without reading anything"

        $silent = @()
        foreach ($promptFile in $promptFiles) {
            $lines = @(Get-Content -LiteralPath $promptFile.FullName -Encoding UTF8)
            if (@($lines | Where-Object { $_.Trim() -eq $canonical }).Count -eq 0) {
                $silent += $promptFile.Name
            }
        }
        Assert-Result -Name "no phase prompt omits the checklist precondition" -Condition ($silent.Count -eq 0) -FailureMessage ("these prompts never state that an unticked required Task List item blocks the handoff: " + (($silent | Sort-Object) -join ", "))
    }

    # The sentence above is only worth asserting if the parser really does treat those two
    # markers as blocking. Without this, someone could relax the parser and the five prompts
    # would go on promising an enforcement that no longer exists.
    $results += Run-Test -Name "The markers the prompts name are the markers that block" -Body {
        $taskPath = Join-Path $tempRoot "prompt-contract-task.md"
        @"
# Task

## Task List

- [x] Done
- [ ] Unticked
- [/] In progress
- [-] Deliberately skipped
"@ | Set-Content -LiteralPath $taskPath -Encoding UTF8

        $result = Get-TaskChecklistGateResult -TaskMdPath $taskPath
        $blocking = @($result.RequiredUnchecked | ForEach-Object { $_.text })
        Assert-Result -Name "unchecked blocks" -Condition (@($blocking | Where-Object { $_ -eq "- [ ] Unticked" }).Count -eq 1) -FailureMessage 'the prompts promise that a [ ] item blocks, and it did not'
        Assert-Result -Name "in-progress blocks" -Condition (@($blocking | Where-Object { $_ -eq "- [/] In progress" }).Count -eq 1) -FailureMessage 'the prompts promise that a [/] item blocks, and it did not'
        Assert-Result -Name "skipped does not block" -Condition (@($blocking | Where-Object { $_ -like "*Deliberately skipped*" }).Count -eq 0) -FailureMessage 'the prompts promise that a [-] item is accepted as skipped, and it blocked'
        Assert-Result -Name "checked does not block" -Condition (@($blocking | Where-Object { $_ -like "*Done*" }).Count -eq 0) -FailureMessage "a completed item was reported as blocking"
    }

    # The C-383 Architect obeyed a prescribed "implement {task_id}" subject and committed a
    # message that said neither what changed nor why. All three places that tell the Architect
    # how to commit have to send it to the repo's own history instead. Item 120.
    $results += Run-Test -Name "Every Architect commit instruction defers to the repo's commit style" -Body {
        foreach ($relative in @("prompts/implementation_prompt.md", "sops/implementation.md", "powershell/lib/session-output.ps1")) {
            $text = [System.IO.File]::ReadAllText((Join-Path $REPO_ROOT $relative))
            Assert-Result -Name ($relative + " prescribes no fixed task-ID subject") -Condition (-not $text.Contains("implement {task_id}")) -FailureMessage ($relative + " still hands the Architect a commit subject that names only the task ID")
            Assert-Result -Name ($relative + " points at the repo's recent commits") -Condition ($text.Contains("style of this repo's recent commits")) -FailureMessage ($relative + " does not tell the Architect to match the repo's recent commit messages")
        }
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
