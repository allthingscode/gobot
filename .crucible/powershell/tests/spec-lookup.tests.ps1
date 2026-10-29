# TODO item 190: every spec reader must accept both legal filename forms.
$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
$REPO_ROOT = (Resolve-Path "$PSScriptRoot/../..").Path
. (Join-Path $PSScriptRoot '_harness.ps1')
. (Join-Path $REPO_ROOT "powershell/crucible-lib.ps1")
$Quiet = $true
$results = @()
$tempRoot = New-TestFixtureRoot -NameHint "spec-lookup"
$utf8 = [System.Text.UTF8Encoding]::new($false)

function Write-SpecLookupFixture {
    param([string]$Root, [string]$Subdir = "active", [string]$Status = "Ready")
    New-Item -ItemType Directory -Force -Path (Join-Path $Root ".crucible"), (Join-Path $Root "backlog/features/$Subdir") | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $Root ".crucible/config.yaml"), "paths:`n  backlog: backlog`n", $utf8)
    [System.IO.File]::WriteAllText((Join-Path $Root "backlog/features/$Subdir/F-190.md"), "---`nitem_id: F-190`nstatus: $Status`nbudget_tier: high`n---`n# Bare spec`n", $utf8)
    [System.IO.File]::WriteAllText((Join-Path $Root "backlog/BACKLOG.md"), "# Backlog`n`n| ID | Title | Status |`n| --- | --- | --- |`n| [F-190](features/$Subdir/F-190.md) | Bare spec | $Status |`n", $utf8)
}

try {
    $results += Run-Test -Name "Directory helper matches both spec forms and only the requested task" -Body {
        $dir = Join-Path $tempRoot "matches"
        New-Item -ItemType Directory -Force -Path (Join-Path $dir "nested"), (Join-Path $dir "F-190_directory.md") | Out-Null
        foreach ($name in @("F-190.md", "F-190_slug.md", "F-1900.md", "F-1900_slug.md", "F-190-other.md", "F-190.txt", "nested/F-190_nested.md")) {
            [System.IO.File]::WriteAllText((Join-Path $dir $name), "spec", $utf8)
        }
        $direct = @(Get-BacklogSpecFiles -Task "F-190" -Directory $dir)
        Assert-Result "direct matches" ($direct.Count -eq 2 -and $direct.Name -contains "F-190.md" -and $direct.Name -contains "F-190_slug.md") ($direct.Name -join ", ")
        Assert-Result "slug keeps precedence" ($direct[0].Name -eq "F-190_slug.md") "expected slug before bare name"
        $recursive = @(Get-BacklogSpecFiles -Task "F-190" -Directory $dir -Recurse)
        Assert-Result "recursive matches" ($recursive.Count -eq 3 -and $recursive.Name -contains "F-190_nested.md") ($recursive.Name -join ", ")
        Assert-Result "missing directory is empty" (@(Get-BacklogSpecFiles -Task "F-190" -Directory (Join-Path $dir "missing")).Count -eq 0) "expected no matches"
    }

    $results += Run-Test -Name "Budget reader finds a bare spec through an explicit project root" -Body {
        $root = Join-Path $tempRoot "budget"
        Write-SpecLookupFixture $root
        $savedRoot = $REPO_ROOT
        $REPO_ROOT = $root
        try {
            Assert-Result "budget with implicit root" ((Get-SpecBudgetTier -Task "F-190") -eq "high") "expected high tier from bare spec"
        } finally { $REPO_ROOT = $savedRoot }
        $budget = Get-SpecBudgetTier -Task "F-190" -ProjectRoot $root -IncludePath
        Assert-Result "budget from bare spec" ($budget.Tier -eq "high" -and $budget.Path -eq (Join-Path $root "backlog/features/active/F-190.md")) "expected high tier and bare spec path"
    }

    $results += Run-Test -Name "Session initialization finds a loose bare spec and enforces its budget" -Body {
        $root = Join-Path $tempRoot "loose-session"
        Write-SpecLookupFixture $root
        $spec = Join-Path $root "backlog/features/F-190.md"
        Move-Item -LiteralPath (Join-Path $root "backlog/features/active/F-190.md") -Destination $spec
        [System.IO.File]::WriteAllText($spec, "---`nbudget_tier: `"high`"`n---`n", $utf8)
        $ctx = @{
            RepoRoot = $root; BacklogDir = (Join-Path $root "backlog"); SessionDir = (Join-Path $root "session")
            CrucibleRoot = ".crucible"; FrameworkPowerShell = (Join-Path $REPO_ROOT "powershell")
            TaskId = "F-190"; Init = $true; TypeDir = "features"; BudgetCeilings = (Get-BudgetCeilings)
            Ceiling = 40; RelativeHandoffPath = "handoffs/test.json"; WorkspacesDir = (Join-Path $root "workspaces")
            Handoff = [pscustomobject]@{
                task_id = "F-190"; source_phase = "grooming"; target_phase = "research"
                budget_tier = "extended"; reason = "fixture"; cumulative_handoff_count = 1; file_affinity = @()
            }
        }
        # Check-Dependencies is supplied by crucible.ps1 in production. For this
        # session-only test, pin the spec path it receives (TODO item 190).
        function Check-Dependencies {
            param([string]$BacklogItemPath, [string]$TargetSpecialist, [string]$TaskId)
            Assert-Result "dependency gate receives bare spec" ($BacklogItemPath -eq $spec) "expected loose bare spec, got $BacklogItemPath"
        }
        Initialize-CrucibleTargetSession -Context $ctx
        $task = Get-Content (Join-Path $root "session/F-190/research/task.md") -Raw
        Assert-Result "loose bare spec path" ($task.Contains($spec)) "expected loose bare spec path in task.md"
        Assert-Result "spec budget enforced" ($ctx.Handoff.budget_tier -eq "high" -and $ctx.Ceiling -eq 28) "expected high tier and ceiling 28"
    }

    $results += Run-Test -Name "Finalization sees bare specs in active and archived" -Body {
        $root = Join-Path $tempRoot "finalized"
        Write-SpecLookupFixture $root "archived" "Resolved"
        $info = Get-TaskFinalizationDetails -TaskId "F-190" -ProjectRoot $root
        Assert-Result "archived bare spec is finalized" ($info.IsFinalized -and $info.SpecExistsInArchived) "expected finalized archived spec"
        New-Item -ItemType Directory -Force -Path (Join-Path $root "backlog/features/active") | Out-Null
        Copy-Item -LiteralPath $info.SpecPathInArchived -Destination (Join-Path $root "backlog/features/active/F-190.md")
        $info = Get-TaskFinalizationDetails -TaskId "F-190" -ProjectRoot $root
        Assert-Result "active bare spec prevents finalization" ($info.SpecExistsInActive -and -not $info.IsFinalized) "expected active spec to prevent finalization"
    }

    $results += Run-Test -Name "Restore prefers the archived bare spec over an active slug spec" -Body {
        $root = Join-Path $tempRoot "restore"
        Write-SpecLookupFixture $root "archived" "Resolved"
        New-Item -ItemType Directory -Force -Path (Join-Path $root "backlog/features/active") | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $root "backlog/features/active/F-190_slug.md"), "---`nstatus: Ready`n---`n", $utf8)
        Restore-BacklogTask -TaskId "F-190" -ProjectRoot $root
        $active = Join-Path $root "backlog/features/active/F-190.md"
        Assert-Result "bare spec restored" ((Test-Path -LiteralPath $active) -and -not (Test-Path -LiteralPath (Join-Path $root "backlog/features/archived/F-190.md"))) "expected archived bare spec to move to active"
        Assert-Result "restored status" ((Get-Content -LiteralPath $active -Raw) -match 'status:.*In Progress') "expected In Progress"
    }

    $results += Run-Test -Name "Abandon updates an already archived bare spec" -Body {
        $root = Join-Path $tempRoot "abandon"
        Write-SpecLookupFixture $root "archived" "Resolved"
        git -C $root init --quiet
        [System.IO.File]::WriteAllText((Join-Path $root "README.md"), "fixture", $utf8)
        git -C $root add README.md
        git -C $root commit -m "fixture" --quiet
        $primary = (Invoke-ExternalCommand -AsLines { git -C $root branch --show-current }).Trim()
        Push-Location $root
        try {
            Invoke-HumanGateRejectAbandon -TaskId "F-190" -Outcome "abandoned" -ProjectRoot $root -PrimaryBranch $primary
        } finally { Pop-Location }
        Assert-Result "spec abandoned" ((Get-Content -LiteralPath (Join-Path $root "backlog/features/archived/F-190.md") -Raw) -match 'status:.*Abandoned') "expected Abandoned spec"
        Assert-Result "index abandoned" ((Get-Content -LiteralPath (Join-Path $root "backlog/BACKLOG.md") -Raw) -match '\| Abandoned \|') "expected Abandoned row"
    }

    $results += Run-Test -Name "Bare spec bootstraps through crucible.ps1 -Init and populates task.md" -Body {
        $root = Join-Path $tempRoot "bootstrap"
        New-Item -ItemType Directory -Force -Path $root | Out-Null
        git -C $root init --quiet
        [System.IO.File]::WriteAllText((Join-Path $root "README.md"), "fixture", $utf8)
        git -C $root add README.md
        git -C $root commit -m "fixture" --quiet
        $init = Invoke-ExternalCommand {
            & (Get-PwshCommand) -NoProfile -File (Join-Path $REPO_ROOT "powershell/init-project.ps1") -ProjectRoot $root -ProjectName "Spec Lookup" -Quiet
        }
        Assert-Result "fixture initialized" ($init.ExitCode -eq 0) ($init.Output -join "`n")
        $spec = Join-Path $root ".crucible/backlog/features/active/F-190.md"
        [System.IO.File]::WriteAllText($spec, "---`nitem_id: F-190`nstatus: Ready`nbudget_tier: high`npriority: `"P0`"`ncreated_at: `"2026-10-13`"`n---`n# Bare spec`n", $utf8)
        [System.IO.File]::WriteAllText((Join-Path $root ".crucible/backlog/BACKLOG.md"), "# Backlog`n`n| ID | Title | Status |`n| --- | --- | --- |`n| [F-190](features/active/F-190.md) | Bare spec | Ready |`n", $utf8)
        Push-Location $root
        try {
            $run = Invoke-ExternalCommand {
                & (Get-PwshCommand) -NoProfile -File (Join-Path $REPO_ROOT "powershell/crucible.ps1") -Init -ProjectRoot $root -TaskId "F-190"
            }
        } finally { Pop-Location }
        $output = $run.Output -join "`n"
        Assert-Result "bare -Init exits zero" ($run.ExitCode -eq 0) ("expected exit 0, got " + $run.ExitCode + ". Output: " + $output)
        $handoff = Get-ChildItem (Join-Path $root ".crucible/session/handoffs") -Filter "F-190-*.json" | Select-Object -First 1
        $data = Get-Content $handoff.FullName -Raw | ConvertFrom-Json
        Assert-Result "bootstrap tier" ($data.budget_tier -eq "high" -and $data.target_phase -eq "grooming") "expected high tier and grooming"
        $task = Get-Content (Join-Path $root ".crucible/session/F-190/grooming/task.md") -Raw
        Assert-Result "task.md names bare spec" ($task.Contains("F-190.md")) "expected bare spec path in task.md"
    }
} finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
if ($results -contains $false) { exit 1 }
Write-Host "ALL TESTS PASSED ($($results.Count) tests)"
exit 0
