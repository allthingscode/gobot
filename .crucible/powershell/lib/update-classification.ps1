# Deliberately does NOT call Set-StrictMode. The mode is scoped to the session, not to
# the file that sets it, so a dot-sourced library imposes it on every caller. This file
# is dot-sourced into update-bundle.ps1, which was not written for strict mode and reads
# absent properties off the provenance manifest by design ($provManifest.files.$path);
# setting the mode here turned those reads into terminating errors and failed three
# update-bundle test files. Strictness belongs to the entry point, and
# update-classification.tests.ps1 does set it, so this function is still exercised under
# strict mode where it can be checked without changing anyone else's semantics.

# The classification lattice for a single (source path, adopter path) pair.
#
# This is deliberately a pure function over scalars: every git lookup, file read and
# manifest predicate is resolved by the caller and passed in. The lattice is the most
# intricate logic in update-bundle.ps1 and it used to be reachable only by installing a
# whole framework into a throwaway git repo, which made most of its branches expensive
# to reach and some of them untested. Keep it free of I/O so that
# update-classification.tests.ps1 can exercise every branch in milliseconds.
#
# Hashes are $null when the file does not exist at that revision or on disk, and they are
# compared with -eq and $null -eq exactly as the inlined version did. Do not "simplify" a
# null check into a truthiness check: that silently reclassifies a missing file as an
# unmodified one.
#
# Categories:
#   skip           - not a candidate at all; the caller adds nothing and moves on
#   add            - the framework has it and the adopter does not
#   no-op          - the adopter already matches, or their edits do not affect this update
#   safe-overwrite - nothing changed outside the custom regions and the file moved
#   needs-merge    - adopter edits and framework edits both exist
#   review-removal - the framework dropped the source and nothing else claims the path
#   retired        - the framework renamed the source, and the replacement is shipping in
#                    this same update, so the old path is dead weight rather than a
#                    judgement call. Distinct from review-removal because review-removal
#                    is cleared only by the interactive -Prune, which leaves the bundle
#                    unable to restamp its provenance until a human answers a prompt.

function New-ClassificationVerdict {
    param(
        [Parameter(Mandatory=$true)][string]$Category,
        [AllowNull()][object]$ScaffoldAction = $null
    )
    return [pscustomobject]@{
        Category = $Category
        ScaffoldAction = $ScaffoldAction
    }
}

function Get-BundleFileClassification {
    param(
        [AllowNull()][object]$HeadHash,
        [AllowNull()][object]$AdopterHash,
        [AllowNull()][object]$AdopterBaseHash,
        [AllowNull()][object]$BaselineHash,
        [AllowNull()][object]$BaselineBaseHash,
        [bool]$IsExpectedPath,
        [bool]$InProvenance,
        [bool]$SourceIsScaffoldSnapshot,
        [bool]$AdopterIsScaffoldSnapshot,
        [bool]$IsSupersededRename = $false
    )

    # 1. Not present at framework HEAD.
    if ($null -eq $HeadHash) {
        if ($null -eq $AdopterHash) {
            return (New-ClassificationVerdict -Category "skip")
        }

        # Another source at HEAD still produces this adopter path. A scaffold rename is
        # the usual cause, where "gitignore" and ".gitignore" flatten to one live file.
        # Removing it here would delete a file the update is about to write.
        if ($IsExpectedPath) {
            return (New-ClassificationVerdict -Category "skip")
        }

        # Local edits outside the custom regions outrank a removal: surface the conflict
        # rather than silently deleting the adopter's work.
        if ($null -ne $BaselineBaseHash -and $AdopterBaseHash -ne $BaselineBaseHash) {
            return (New-ClassificationVerdict -Category "needs-merge")
        }

        # Strictly below the conflict check above, and that order is the safety property:
        # knowing where a file went is not permission to delete an edited copy of it. A
        # rename only downgrades the *unmodified* case, where the adopter has nothing to
        # lose and the replacement is already landing.
        if ($IsSupersededRename) {
            return (New-ClassificationVerdict -Category "retired")
        }
        return (New-ClassificationVerdict -Category "review-removal")
    }

    # 2. Not present on the adopter.
    if ($null -eq $AdopterHash) {
        $scaffoldAction = $null

        # A scaffold source has two adopter paths: the snapshot (same path) and the
        # instantiated copy (relative to the bundle root). Only the latter is seed
        # material the adopter may decline, so only the latter is announced.
        if ($SourceIsScaffoldSnapshot -and -not $AdopterIsScaffoldSnapshot) {
            # Provenance chooses the wording and never the behaviour. It records what the
            # framework owned at the baseline commit, not what was written to this
            # adopter's disk, so "was shipped at your baseline" is all it can honestly
            # support. The file lands either way.
            if ($InProvenance) {
                $scaffoldAction = "recreated"
            } else {
                $scaffoldAction = "instantiated"
            }
        }
        return (New-ClassificationVerdict -Category "add" -ScaffoldAction $scaffoldAction)
    }

    # 3. Present on both.
    if ($AdopterHash -eq $HeadHash) {
        return (New-ClassificationVerdict -Category "no-op")
    }

    # The adopter changed nothing outside the custom regions, so the framework's version
    # can be written over the top without losing their work.
    if ($null -ne $BaselineBaseHash -and $AdopterBaseHash -eq $BaselineBaseHash) {
        if ($BaselineHash -ne $HeadHash) {
            return (New-ClassificationVerdict -Category "safe-overwrite")
        }
        return (New-ClassificationVerdict -Category "no-op")
    }

    # The adopter edited outside the custom regions, or there is no baseline to compare
    # against. Only a framework-side change makes this a conflict.
    if ($BaselineHash -eq $HeadHash) {
        return (New-ClassificationVerdict -Category "no-op")
    }
    return (New-ClassificationVerdict -Category "needs-merge")
}
