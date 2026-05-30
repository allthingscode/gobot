function Get-TaskChecklistGateResult {
    param(
        [Parameter(Mandatory=$true)][string]$TaskMdPath,
        [string]$RequiredSectionHeader = "## Task List"
    )

    $result = [ordered]@{
        RequiredSectionHeader = $RequiredSectionHeader
        RequiredSectionFound  = $false
        RequiredUnchecked     = @()
        OptionalUnchecked     = @()
        RequiredMalformed     = @()
    }

    if (-not (Test-Path -LiteralPath $TaskMdPath)) {
        return [pscustomobject]$result
    }

    $lines = Get-Content -LiteralPath $TaskMdPath -Encoding UTF8
    $inRequiredSection = $false

    function Is-PostSessionFactoryChecklistItem {
        param([string]$ChecklistLine)
        return $ChecklistLine -match '^\s*-\s+\[( |/|x|X)\]\s*Run\s+factory\.ps1\s+-Init\s+-TaskId\b'
    }

    for ($idx = 0; $idx -lt $lines.Count; $idx++) {
        $line = $lines[$idx]
        $lineNo = $idx + 1

        if ($line -match '^\s*##\s+') {
            $heading = $line.Trim()
            if ($heading -eq $RequiredSectionHeader) {
                $inRequiredSection = $true
                $result.RequiredSectionFound = $true
            } elseif ($inRequiredSection) {
                $inRequiredSection = $false
            }
        }

        if ($line -match '^\s*-\s+\[( |/)\]') {
            if (Is-PostSessionFactoryChecklistItem -ChecklistLine $line) {
                continue
            }
            $entry = [pscustomobject]@{ line = $lineNo; text = $line.Trim() }
            if ($inRequiredSection) {
                $result.RequiredUnchecked += $entry
            } else {
                $result.OptionalUnchecked += $entry
            }
            continue
        }

        # Preserve strict blocking for malformed checklist markers in the required section.
        if ($inRequiredSection -and $line -match '^\s*-\s+\[' -and $line -notmatch '^\s*-\s+\[( |/|x|X)\]') {
            if (Is-PostSessionFactoryChecklistItem -ChecklistLine $line) {
                continue
            }
            $result.RequiredMalformed += [pscustomobject]@{ line = $lineNo; text = $line.Trim() }
        }
    }

    return [pscustomobject]$result
}
