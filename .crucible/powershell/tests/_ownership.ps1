# One answer to "can a live process still be shown to own this?", shared by the two places
# that ask it: run roots in _harness.ps1 and fixture worktrees in _worktree-fixture.ps1.
# Name does not contain "test" to prevent runner execution.
#
# It is its own file because those two cannot share code any other way: _worktree-fixture.ps1
# deliberately does not dot-source _harness.ps1, since _harness.ps1 computes
# $CRUCIBLE_TEST_ROOT_CREATED at load time and a second dot-source would flip that flag and
# take away run-all-tests.ps1's knowledge of whether it owns the root it is about to delete.
# So this file has NO load-time side effects at all - no variables, no root creation, no
# environment - and is safe to dot-source twice or from either side.
#
# Age is not ownership. The run lock serialises one checkout, so a second checkout can
# legitimately have a run in flight, and a threshold short enough to collect a crashed run
# would also collect that one alive. A dead owner is proof; nothing else is.
#
# But a pid on its own is not an identity. Windows reuses process ids, and two run roots
# created 2026-09-10 survived every suite run for three days: their pids had been handed to
# Wispr Flow and to chrome, both of which started the next morning, eleven hours after the
# directories they were now vouching for. Pid liveness answered "live owner" forever, so the
# reaper skipped them forever, and the count of such roots only ever grows. A pid becomes an
# identity when paired with a start time - a process that started AFTER a directory was
# created cannot be the process that created it.

function Get-ProcessStartTimeUtc {
    <#
    .SYNOPSIS
        A process's start time in UTC, or $null when it cannot be read.
    #>
    param([Parameter(Mandatory = $true)][AllowNull()]$Process)

    if ($null -eq $Process) { return $null }

    # Measured rather than assumed: under Windows PowerShell 5.1, reading .StartTime on a
    # process this user may not query - pid 4 (System), pid 0 (Idle), anything owned by
    # another account - yields $null rather than throwing, because a property getter's
    # exception is swallowed by the engine. Other hosts throw instead. Both paths return
    # $null so callers have one case to handle, and so the branch that cannot be exercised
    # on 5.1 cannot behave differently from the one that can.
    try {
        $start = $Process.StartTime
    } catch {
        return $null
    }

    if ($null -eq $start) { return $null }
    return $start.ToUniversalTime()
}

function Test-OwnerProcessLive {
    <#
    .SYNOPSIS
        True when a live process can still be shown to own something created at $CreatedUtc.
    #>
    param(
        [Parameter(Mandatory = $true)][int]$OwnerPid,
        [Parameter(Mandatory = $true)][AllowNull()][Nullable[datetime]]$CreatedUtc
    )

    if ($OwnerPid -le 0) { return $false }

    $owner = Get-Process -Id $OwnerPid -ErrorAction SilentlyContinue
    if ($null -eq $owner) { return $false }

    # $null is a caller with no creation time to offer - a worktree registration whose
    # checkout is already gone. It is passed explicitly rather than defaulted, because the
    # answer then falls back to pid liveness alone: the weaker rule this function exists to
    # replace. A caller that could have supplied a time must not get that fallback silently.
    if ($null -eq $CreatedUtc) { return $true }

    $startUtc = Get-ProcessStartTimeUtc -Process $owner
    # An unreadable start time means assume the owner, which is the answer the pid-only rule
    # gave for everything. The opposite would let the reaper delete a live run's root, and
    # that is worse than the leak this narrows.
    #
    # No test can catch the deletion of this line, and that is recorded rather than fixed:
    # `$null -le $anyDate` is $True in PowerShell, so falling through to the comparison below
    # returns the same answer by accident. Deleting it is an equivalent mutant, proved by
    # measurement in item 90's battery. It stays because the accident is the kind that a
    # language version or a type change quietly reverses, and because the rule has to be
    # readable as a rule.
    if ($null -eq $startUtc) { return $true }

    # UTC on both sides. Process.StartTime is local and DirectoryInfo.CreationTimeUtc is not,
    # so comparing them as given would misjudge by an hour twice a year.
    # -le rather than -lt: a tie favours the owner, for the same reason as above.
    return ($startUtc -le $CreatedUtc)
}
