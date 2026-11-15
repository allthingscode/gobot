# Every command a shipped document gives for one of Crucible's own scripts binds to that script.
#
# Item 275. Item 247 binds the commands runtime PowerShell prints (I15), but the documents an
# orchestrator or specialist copies commands from were free text: items 125, 126 and 272 were
# instances there of the class item 219 was at runtime. This reads the fenced code, inline code
# and plain prose of every Markdown file the bundle ships and checks each "<script>.ps1 -<Param>": the
# script is in the bundle, it declares every parameter, a parameter that takes a value has one,
# the builder's companion rules (Get-CrucibleCommandCompanionProblems) hold, and a literal value is
# one its parameter accepts (Get-CrucibleCommandValueProblems, item 365). Placeholders
# such as <task-id> and {project_root} are values like any other. A line that breaks a rule on
# purpose needs an allowance with its reason, and an allowance that excuses nothing fails.
#
# It ships, and reads the bundle it runs in. The framework's dev-only scripts are absent from
# an adopter bundle and are not counted as bundle scripts here either, so a document naming one
# needs the same allowance in both layouts.

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$BUNDLE_ROOT = (Resolve-Path -Path "$PSScriptRoot/../..").Path
. (Join-Path $PSScriptRoot '_harness.ps1')
. (Join-Path $BUNDLE_ROOT "powershell/lib/platform.ps1")
. (Join-Path $BUNDLE_ROOT "powershell/lib/install-manifest.ps1")
. (Join-Path $BUNDLE_ROOT "powershell/lib/crucible-command.ps1")

$results = @()

# Invocations that break a rule and are not a command anyone runs as written. Each names its
# document, a pattern for the invocation's text, and why. A bare `crucible.ps1 -Init` span is
# not exempt by shape: items 125 and 126 were bare copies an agent ran, so each document that
# names the entry point in a sentence is reviewed here.
$BARE_INIT = '^crucible\.ps1 -Init$'
$DOCUMENTED_COMMAND_ALLOWANCES = @(
    @{ RelativePath = "docs/config-reference.md"; Pattern = $BARE_INIT
       Reason = "says what -Init prints about the approval mode; the runnable line is in sops/orchestrator.md" },
    @{ RelativePath = "docs/orchestrators/claude.md"; Pattern = $BARE_INIT
       Reason = "explains STATUS=ADVANCE_INCOMPLETE, the specialist's own -Init that was cut off; the launcher prints the recovery command" },
    @{ RelativePath = "docs/orchestrators/codex.md"; Pattern = $BARE_INIT
       Reason = "names the specialist's cut-off -Init and the run that prints [APPROVAL MODE]; the runnable lines are in this guide's fences" },
    @{ RelativePath = "docs/orchestrators/grok.md"; Pattern = $BARE_INIT
       Reason = "names the orchestrator's first -Init and where -Target grok goes; the runnable lines are in this guide's fences" },
    @{ RelativePath = "sops/deployment.md"; Pattern = $BARE_INIT
       Reason = "says the orchestrator's -Init already ran the dependency gate, and tells the Operator not to run it again" },
    @{ RelativePath = "sops/implementation.md"; Pattern = $BARE_INIT
       Reason = "tells an escalating Architect not to run -Init; the runnable line is in Phase 4" },
    @{ RelativePath = "sops/orchestrator.md"; Pattern = $BARE_INIT
       Reason = "names the -Init that prints [APPROVAL MODE] and the specialist's own -Init; the runnable line is in Step 1" },
    @{ RelativePath = "docs/policy.md"; Pattern = '^powershell/gates/check-generated-docs\.ps1 -Write$'
       Reason = "the sentence says this regenerator runs in the framework repo only and is not part of a bundle" }
)

. (Join-Path $PSScriptRoot "_command-binding.ps1")

$shipped = Get-ShippedFileSet -BundleRoot $BUNDLE_ROOT
$treeBound = @(Get-DocumentedCommandScan -Root $BUNDLE_ROOT -Documents $shipped.Markdown -Shipped $shipped -Allowances $DOCUMENTED_COMMAND_ALLOWANCES -BundleRoot $BUNDLE_ROOT)

$results += Run-Test -Name "Every documented command for a Crucible script binds to the script" -Body {
    Assert-Result -Name "the shipped documents are read" -Condition ($shipped.Markdown.Count -ge 50 -and $shipped.Scripts.Count -ge 40) -FailureMessage (
        "read " + $shipped.Markdown.Count + " shipped Markdown files and " + $shipped.Scripts.Count + " bundle scripts; fewer means the scan is not reading this bundle and the binding below proves nothing")
    Assert-Result -Name "documented commands found" -Condition ($treeBound.Count -ge 120) -FailureMessage (
        "found " + $treeBound.Count + " documented invocations; the shipped documents held about 150 when this guard was written, so fewer means the parser stopped seeing them")
    $unbound = @(Get-UnboundDocumentedCommands -Bound $treeBound)
    $message = if ($unbound.Count -gt 0) { "Documented commands that do not bind (fix the document, or add an allowance with its reason):`n" + ($unbound -join "`n") } else { "none" }
    Assert-Result -Name "every documented command binds" -Condition ($unbound.Count -eq 0) -FailureMessage $message
}

$results += Run-Test -Name "Every documented-command allowance has a reason and still excuses a line" -Body {
    $invalid = @()
    foreach ($entry in $DOCUMENTED_COMMAND_ALLOWANCES) {
        if (-not (Test-Path -LiteralPath (Join-Path $BUNDLE_ROOT $entry.RelativePath) -PathType Leaf)) { $invalid += ($entry.RelativePath + ": document does not exist") }
        if ([string]::IsNullOrWhiteSpace($entry.Reason) -or $entry.Reason.Length -lt 20) { $invalid += ($entry.RelativePath + ": missing or too short a reason") }
    }
    $invalid += @(Get-StaleDocumentedCommandAllowances -Bound $treeBound -Allowances $DOCUMENTED_COMMAND_ALLOWANCES)
    $message = if ($invalid.Count -gt 0) { $invalid -join "`n" } else { "none" }
    Assert-Result -Name "documented-command allowances are valid and live" -Condition ($invalid.Count -eq 0) -FailureMessage $message
}

# Each instance in the record, written the way the documents had it, planted in a scratch
# document with no allowance. Each must be reported with its own problem.
$FENCE = '```'
$PLANTED_DOCUMENTS = [ordered]@{

    "item 125 SOP advance without the root" = @(
        ($FENCE + "bash`npwsh -ExecutionPolicy Bypass \`n  -File `"{{crucible_root}}/powershell/crucible.ps1`" -Init -TaskId {task_id} -Quiet`n" + $FENCE),
        "-Init needs -ProjectRoot")
    "item 126 bare Init copy" = @(
        "At session end, run ``crucible.ps1 -Init`` to advance.",
        "-Init needs -ProjectRoot")
    "item 126 Init with a task and no root" = @(
        "Each agent runs ``crucible.ps1 -Init -TaskId {id}`` and chains forward.",
        "-Init needs -ProjectRoot")
    "item 219 dispatch without the effort" = @(
        "Re-dispatch with ``launch-codex-specialist.ps1 -TaskId <id> -Phase research -Model <model> -PromptFile <path>``.",
        "-Model needs -Effort")
    "item 272 specialist example without the effort" = @(
        ($FENCE + "powershell`npwsh -ExecutionPolicy Bypass ```n  -File `"{{crucible_root}}/powershell/launch-codex-specialist.ps1`" ```n  -TaskId {task_id} -Phase implementation -Model {model} -PromptFile `"{prompt}`"`n" + $FENCE),
        "-Model needs -Effort")
    "undeclared parameter" = @(
        "Run ``{{crucible_root}}/powershell/crucible.ps1 -Init -TaskId {task_id} -ProjectRoot `"{project_root}`" -Recovr``.",
        "declares no parameter -Recovr")
    "item 218 path outside the bundle layout" = @(
        "Usage: ``.\.crucible\\crucible.ps1 -Init -TaskId {task_id} -ProjectRoot `"{project_root}`"``",
        "names no script")
    "bool parameter with no value" = @(
        "For state updates use ``update-session-state.ps1 -Specialist grooming -TaskId {task_id} -UpdateJsonFile temp.json -Merge``.",
        "-Merge takes a value")
    "command in prose without backticks" = @(
        "Then run crucible.ps1 -Init -TaskId F-1 to advance.",
        "-Init needs -ProjectRoot")
    # Codex review of 3045d19: each of these passed.
    "parameter name with a dash" = @(
        "Run ``crucible.ps1 -Init -ProjectRoot . -Not-A-Parameter``.",
        "declares no parameter -Not-A-Parameter")
    "splatted parameters" = @(
        ($FENCE + "powershell`n`$options = @{ Init = `$true; Recovr = `$true }`n& ./powershell/crucible.ps1 @options`n" + $FENCE),
        "splats @options")
    "value after a switch" = @(
        "Run ``crucible.ps1 -Init `$true -ProjectRoot .``.",
        "after the switch -Init")
    "abbreviated parameter" = @(
        "Run ``crucible.ps1 -Ini -ProjectRoot .``.",
        "abbreviated parameter -Ini; write -Init")
    "positional value" = @(
        "Run ``clear-session-state.ps1 implementation -ProjectRoot .``.",
        "binds it positionally")
    "framework dev-only script" = @(
        "Run ``powershell/gates/check-ascii.ps1 -Staged`` before committing.",
        "framework dev-only script")
    # Item 365: a value its parameter's ValidateSet refuses.
    "value outside the accepted set" = @(
        "Run ``run-isolated-checks.ps1 -Mode fast`` first.",
        "-Mode value 'fast' is outside its accepted values")
    "inline value outside the accepted set" = @(
        "Run ``crucible.ps1 -Target:grook -Init -ProjectRoot .``.",
        "-Target value 'grook' is outside its accepted values")
    "prose value outside the accepted set" = @(
        "Then run crucible.ps1 -Init -Target grook -ProjectRoot . to start.",
        "-Target value 'grook' is outside its accepted values")
    "choice list with a member outside the set" = @(
        "Hand off with ``new-handoff.ps1 -TaskId {task_id} -Source grooming -Target <implementation|resaerch> -Reason <why>``.",
        "-Target value 'resaerch' is outside its accepted values")
    # Codex review of 11c2a5c: a single-quoted value is literal whatever it holds.
    "single-quoted value with a special character" = @(
        "Run ``run-isolated-checks.ps1 -Mode 'fast@'`` first.",
        "-Mode value 'fast@' is outside its accepted values")
    "quoted choice list, which PowerShell reads as one value" = @(
        "Run ``run-isolated-checks.ps1 -Mode `"quick|full`"``.",
        "-Mode value 'quick|full' is outside its accepted values")
}

$CORRECT_DOCUMENT = @(
    "Run ``run-isolated-checks.ps1 -Mode <quick|full>``, ``run-isolated-checks.ps1 [-Mode <mode>]`` or ``run-isolated-checks.ps1 -Mode 'QUICK'``.",
    "Start with crucible.ps1 -Init -Target codex -ProjectRoot . and continue.",
    "The archive-task.ps1 helper takes -Status, and an unshipped helper.ps1 named in passing takes -Anything.",
    "",
    "Run ``crucible.ps1 -Init -TaskId <task-id> -ProjectRoot `"{project_root}`"`` to advance.",
    "",
    ($FENCE + "bash"),
    "pwsh -ExecutionPolicy Bypass \",
    "  -File `"{{crucible_root}}/powershell/new-handoff.ps1`" -TaskId {task_id} -Source grooming -Target <implementation|research> -Reason `"Ready - see notes.`" [-FileAffinity `"<paths>`"] [-DesignRequired] -ProjectRoot `"{project_root}`"",
    $FENCE,
    "",
    "Preflight with ``launch-codex-specialist.ps1 -Preflight -Model <slug>``, then",
    "dispatch with ``launch-codex-specialist.ps1 -TaskId {task_id} -Phase research",
    "-Model {model} -Effort {effort} -PromptFile <path>``.",
    "",
    ('````markdown'),
    $FENCE,
    "& '{{crucible_root}}/powershell/crucible.ps1' -Init -TaskId <task-id> -ProjectRoot '{project_root}'",
    $FENCE,
    '````',
    "",
    "Run ``C:\path\to\crucible-source\powershell\update-bundle.ps1 -FrameworkSource `"C:\path\to\crucible-source`" -AdopterRoot . -Mode report-only``.",
    "",
    ($FENCE + "text"),
    "-> Run crucible.ps1 -Health to check worktree state.",
    $FENCE
) -join "`n"

function Get-PlantedScan {
    param(
        [Parameter(Mandatory = $true)][string]$Directory,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Body,
        [AllowEmptyCollection()][array]$Allowances = @()
    )
    $rel = "docs/" + $Name + ".md"
    $path = Join-Path $Directory $rel
    New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
    [System.IO.File]::WriteAllText($path, $Body + "`n", (New-Object System.Text.UTF8Encoding($false)))
    return @(Get-DocumentedCommandScan -Root $Directory -Documents @($rel) -Shipped $shipped -Allowances $Allowances -BundleRoot $BUNDLE_ROOT)
}

$results += Run-Test -Name "MUT: each recorded documented instance, planted, is reported" -Body {
    $tempDir = New-TestFixtureRoot -NameHint "documented-commands-planted"
    try {
        $index = 0
        foreach ($name in $PLANTED_DOCUMENTS.Keys) {
            $index++
            $bound = @(Get-PlantedScan -Directory $tempDir -Name ("planted-" + $index) -Body $PLANTED_DOCUMENTS[$name][0])
            $expected = $PLANTED_DOCUMENTS[$name][1]
            $unbound = @(Get-UnboundDocumentedCommands -Bound $bound)
            $matching = @($unbound | Where-Object { $_.Contains($expected) })
            Assert-Result -Name ("planted " + $name + " reported") -Condition ($unbound.Count -eq 1 -and $matching.Count -eq 1) -FailureMessage (
                "expected one unbound command reporting '" + $expected + "'; got " + $unbound.Count + ": " + ($unbound -join " | "))
        }
    } finally {
        Remove-DocumentedCommandFixture -Path $tempDir
    }
}

$results += Run-Test -Name "MUT: correctly documented commands, placeholders included, bind" -Body {
    $tempDir = New-TestFixtureRoot -NameHint "documented-commands-correct"
    try {
        $bound = @(Get-PlantedScan -Directory $tempDir -Name "correct" -Body $CORRECT_DOCUMENT)
        Assert-Result -Name "every planted command is seen" -Condition ($bound.Count -eq 11) -FailureMessage (
            "expected 11 invocations; got " + $bound.Count + ": " + (($bound | ForEach-Object { $_.Invocation.Text }) -join " | "))
        $unbound = @(Get-UnboundDocumentedCommands -Bound $bound)
        Assert-Result -Name "correct commands bind" -Condition ($unbound.Count -eq 0) -FailureMessage ($unbound -join "`n")
    } finally {
        Remove-DocumentedCommandFixture -Path $tempDir
    }
}

$results += Run-Test -Name "MUT: an allowance excuses its line, and one that excuses nothing is reported" -Body {
    $tempDir = New-TestFixtureRoot -NameHint "documented-commands-allowance"
    try {
        $allowance = @{ RelativePath = "docs/allowed.md"; Pattern = $BARE_INIT; Reason = "a planted sentence that names the entry point" }
        $bound = @(Get-PlantedScan -Directory $tempDir -Name "allowed" -Body "The orchestrator's ``crucible.ps1 -Init`` already ran." -Allowances @($allowance))
        Assert-Result -Name "allowed line excused" -Condition (@(Get-UnboundDocumentedCommands -Bound $bound).Count -eq 0 -and @(Get-StaleDocumentedCommandAllowances -Bound $bound -Allowances @($allowance)).Count -eq 0) -FailureMessage (
            "the allowance did not excuse its line: " + (@(Get-UnboundDocumentedCommands -Bound $bound) -join " | "))
        $fixed = @(Get-PlantedScan -Directory $tempDir -Name "allowed" -Body "The orchestrator's ``crucible.ps1 -Init -ProjectRoot `"{project_root}`"`` already ran." -Allowances @($allowance))
        Assert-Result -Name "stale documented-command allowance reported" -Condition (@(Get-StaleDocumentedCommandAllowances -Bound $fixed -Allowances @($allowance)).Count -eq 1) -FailureMessage (
            "an allowance whose line was fixed still counted as used")
    } finally {
        Remove-DocumentedCommandFixture -Path $tempDir
    }
}

$results += Run-Test -Name "MUT: a tree allowance that matches nothing is reported" -Body {
    $dead = @{ RelativePath = "sops/orchestrator.md"; Pattern = '^crucible\.ps1 -Frobnicate$'; Reason = "a sentence that was rewritten and left its allowance behind" }
    $bound = @(Get-DocumentedCommandScan -Root $BUNDLE_ROOT -Documents $shipped.Markdown -Shipped $shipped -Allowances @($dead) -BundleRoot $BUNDLE_ROOT)
    Assert-Result -Name "dead tree allowance reported" -Condition (@(Get-StaleDocumentedCommandAllowances -Bound $bound -Allowances @($dead)).Count -eq 1) -FailureMessage "an allowance matching no documented command was not reported"
}

$failedCount = @($results | Where-Object { -not $_ }).Count
if ($failedCount -gt 0) {
    Write-Host "`nSOME TESTS FAILED" -ForegroundColor Red
    exit 1
}
Write-Host "`nALL TESTS PASSED ($($results.Count) tests)" -ForegroundColor Green
exit 0
