# Table-driven tests for the update-bundle classification lattice.
#
# Every branch of Get-BundleFileClassification is reached here without touching git, the
# filesystem or a manifest. Before this file the same logic was reachable only through
# adopter-update-materialization.tests.ps1, which installs a whole framework into a
# throwaway git repo and takes over two minutes to exercise a handful of branches.

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
$REPO_ROOT = (Resolve-Path -Path "$PSScriptRoot/../..").Path
. (Join-Path $PSScriptRoot '_harness.ps1')
. (Join-Path $REPO_ROOT "powershell/lib/update-classification.ps1")

$results = @()

# Distinct opaque values. The lattice only ever compares them for equality, so their
# content is irrelevant and readable names beat realistic sha256 strings.
$HEAD = "hash-head"
$PREV = "hash-previous"
$LOCAL = "hash-local-edit"
$BASE = "hash-shared-base"
$OTHER = "hash-other-base"

function New-LatticeCase {
    param(
        [Parameter(Mandatory=$true)][string]$Name,
        [Parameter(Mandatory=$true)][hashtable]$With,
        [Parameter(Mandatory=$true)][string]$Category,
        [AllowNull()][object]$ScaffoldAction = $null
    )

    # Every parameter is supplied on every call. An omitted key would make a case depend
    # on the function's own defaults, so a default that drifted would not be caught here.
    $params = @{
        HeadHash = $null
        AdopterHash = $null
        AdopterBaseHash = $null
        BaselineHash = $null
        BaselineBaseHash = $null
        IsExpectedPath = $false
        InProvenance = $false
        SourceIsScaffoldSnapshot = $false
        AdopterIsScaffoldSnapshot = $false
        IsSupersededRename = $false
    }
    foreach ($key in $With.Keys) {
        if (-not $params.ContainsKey($key)) {
            throw "Test case '$Name' sets unknown parameter '$key'."
        }
        $params[$key] = $With[$key]
    }

    return [pscustomobject]@{
        Name = $Name
        Params = $params
        Category = $Category
        ScaffoldAction = $ScaffoldAction
    }
}

$cases = @(
    # --- Source is gone at framework HEAD ---
    (New-LatticeCase -Name "source gone and adopter has no file is skipped" `
        -With @{ HeadHash = $null; AdopterHash = $null } -Category "skip"),

    # The guard that item 22's fixture exists to prove, and that MUT-1 killed. A scaffold
    # rename leaves the old source gone while a new source still produces the same live
    # adopter path; classifying it for removal would delete a file the update rewrites.
    (New-LatticeCase -Name "source gone but another source still claims the path is skipped" `
        -With @{ HeadHash = $null; AdopterHash = $LOCAL; IsExpectedPath = $true } -Category "skip"),

    (New-LatticeCase -Name "source gone with no baseline base hash is review-removal" `
        -With @{ HeadHash = $null; AdopterHash = $LOCAL; BaselineBaseHash = $null } -Category "review-removal"),

    (New-LatticeCase -Name "source gone and adopter untouched outside custom regions is review-removal" `
        -With @{ HeadHash = $null; AdopterHash = $LOCAL; AdopterBaseHash = $BASE; BaselineBaseHash = $BASE } -Category "review-removal"),

    (New-LatticeCase -Name "source gone but adopter edited outside custom regions is needs-merge" `
        -With @{ HeadHash = $null; AdopterHash = $LOCAL; AdopterBaseHash = $OTHER; BaselineBaseHash = $BASE } -Category "needs-merge"),

    (New-LatticeCase -Name "source renamed away and adopter untouched is retired" `
        -With @{ HeadHash = $null; AdopterHash = $LOCAL; AdopterBaseHash = $BASE; BaselineBaseHash = $BASE; IsSupersededRename = $true } -Category "retired"),

    (New-LatticeCase -Name "source renamed away with no baseline base hash is retired" `
        -With @{ HeadHash = $null; AdopterHash = $LOCAL; BaselineBaseHash = $null; IsSupersededRename = $true } -Category "retired"),

    # The safety property of the rename map: knowing where a file went is not permission
    # to delete an edited copy of it. If this case ever returns "retired" the mechanism is
    # silently discarding adopter work.
    (New-LatticeCase -Name "source renamed away but adopter edited outside custom regions is still needs-merge" `
        -With @{ HeadHash = $null; AdopterHash = $LOCAL; AdopterBaseHash = $OTHER; BaselineBaseHash = $BASE; IsSupersededRename = $true } -Category "needs-merge"),

    (New-LatticeCase -Name "source renamed away but another source still claims the path is skipped" `
        -With @{ HeadHash = $null; AdopterHash = $LOCAL; IsExpectedPath = $true; IsSupersededRename = $true } -Category "skip"),

    (New-LatticeCase -Name "a rename flag on a file that still exists at HEAD does not retire it" `
        -With @{ HeadHash = $HEAD; AdopterHash = $LOCAL; AdopterBaseHash = $BASE; BaselineBaseHash = $BASE; BaselineHash = $PREV; IsSupersededRename = $true } -Category "safe-overwrite"),

    # --- File missing on the adopter ---
    (New-LatticeCase -Name "framework file missing on the adopter is add" `
        -With @{ HeadHash = $HEAD; AdopterHash = $null } -Category "add"),

    (New-LatticeCase -Name "scaffold seed absent from provenance is announced as instantiated" `
        -With @{ HeadHash = $HEAD; AdopterHash = $null; SourceIsScaffoldSnapshot = $true; InProvenance = $false } `
        -Category "add" -ScaffoldAction "instantiated"),

    (New-LatticeCase -Name "scaffold seed present in provenance is announced as recreated" `
        -With @{ HeadHash = $HEAD; AdopterHash = $null; SourceIsScaffoldSnapshot = $true; InProvenance = $true } `
        -Category "add" -ScaffoldAction "recreated"),

    # The snapshot copy lands at the same path it occupies in the framework. Only the
    # flattened instantiated copy is seed material the adopter may decline.
    (New-LatticeCase -Name "the scaffold snapshot path itself is not announced" `
        -With @{ HeadHash = $HEAD; AdopterHash = $null; SourceIsScaffoldSnapshot = $true; AdopterIsScaffoldSnapshot = $true; InProvenance = $true } `
        -Category "add"),

    (New-LatticeCase -Name "provenance alone does not announce a non-scaffold file" `
        -With @{ HeadHash = $HEAD; AdopterHash = $null; SourceIsScaffoldSnapshot = $false; InProvenance = $true } `
        -Category "add"),

    # --- Present on both sides ---
    (New-LatticeCase -Name "adopter already matching HEAD is no-op" `
        -With @{ HeadHash = $HEAD; AdopterHash = $HEAD } -Category "no-op"),

    (New-LatticeCase -Name "custom-region-only edits with a moved framework file is safe-overwrite" `
        -With @{ HeadHash = $HEAD; AdopterHash = $LOCAL; AdopterBaseHash = $BASE; BaselineBaseHash = $BASE; BaselineHash = $PREV } `
        -Category "safe-overwrite"),

    (New-LatticeCase -Name "custom-region-only edits with an unchanged framework file is no-op" `
        -With @{ HeadHash = $HEAD; AdopterHash = $LOCAL; AdopterBaseHash = $BASE; BaselineBaseHash = $BASE; BaselineHash = $HEAD } `
        -Category "no-op"),

    (New-LatticeCase -Name "edits outside custom regions with a moved framework file is needs-merge" `
        -With @{ HeadHash = $HEAD; AdopterHash = $LOCAL; AdopterBaseHash = $OTHER; BaselineBaseHash = $BASE; BaselineHash = $PREV } `
        -Category "needs-merge"),

    (New-LatticeCase -Name "edits outside custom regions with an unchanged framework file is no-op" `
        -With @{ HeadHash = $HEAD; AdopterHash = $LOCAL; AdopterBaseHash = $OTHER; BaselineBaseHash = $BASE; BaselineHash = $HEAD } `
        -Category "no-op"),

    (New-LatticeCase -Name "no baseline base hash with a moved framework file is needs-merge" `
        -With @{ HeadHash = $HEAD; AdopterHash = $LOCAL; BaselineBaseHash = $null; BaselineHash = $PREV } `
        -Category "needs-merge"),

    (New-LatticeCase -Name "no baseline base hash with an unchanged framework file is no-op" `
        -With @{ HeadHash = $HEAD; AdopterHash = $LOCAL; BaselineBaseHash = $null; BaselineHash = $HEAD } `
        -Category "no-op")
)

foreach ($case in $cases) {
    $results += Run-Test -Name ("classify: " + $case.Name) -Body {
        $params = $case.Params
        $verdict = Get-BundleFileClassification @params

        Assert-Result -Name ("category is " + $case.Category) `
            -Condition ($verdict.Category -eq $case.Category) `
            -FailureMessage ("expected category '" + $case.Category + "', got '" + $verdict.Category + "'")

        if ($null -eq $case.ScaffoldAction) {
            Assert-Result -Name "no scaffold action" `
                -Condition ($null -eq $verdict.ScaffoldAction) `
                -FailureMessage ("expected no scaffold action, got '" + $verdict.ScaffoldAction + "'")
        } else {
            Assert-Result -Name ("scaffold action is " + $case.ScaffoldAction) `
                -Condition ($verdict.ScaffoldAction -eq $case.ScaffoldAction) `
                -FailureMessage ("expected scaffold action '" + $case.ScaffoldAction + "', got '" + $verdict.ScaffoldAction + "'")
        }
    }
}

# The lattice must be total: every category the caller allocates a bucket for has to be
# reachable, or a bucket is dead code and a branch is untested.
$results += Run-Test -Name "every classification category is covered by a case" -Body {
    $covered = @($cases | ForEach-Object { $_.Category } | Sort-Object -Unique)
    foreach ($category in @("skip", "add", "no-op", "safe-overwrite", "needs-merge", "review-removal", "retired")) {
        Assert-Result -Name ("category '" + $category + "' has at least one case") `
            -Condition ($covered -contains $category) `
            -FailureMessage ("no test case produces '" + $category + "'")
    }
}

if ($results -contains $false) {
    Write-Host "`nSOME TESTS FAILED" -ForegroundColor Red
    exit 1
}

Write-Host ("`nALL TESTS PASSED (" + $results.Count + " tests)") -ForegroundColor Green
exit 0
