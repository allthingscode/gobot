$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot '_harness.ps1')
$results = @()
$root = New-TestFixtureRoot -NameHint 'harness-progress'
$utf8 = [Text.UTF8Encoding]::new($false)
$shell = (Get-Process -Id $PID).Path
try {
    $results += Run-Test 'Captured child steps are visible before child exit' {
        $child = Join-Path $root 'child.ps1'
        $driver = Join-Path $root 'driver.ps1'
        $release = Join-Path $root 'release'
        $resultPath = Join-Path $root 'result.json'
        [IO.File]::WriteAllText($child, @'
param($Release)
Write-Output 'Test: CHILD-STEP'
[Console]::Error.WriteLine('CHILD-STDERR')
Write-Output '    fixture progress: FAILED: prefixed fixture'
$deadline = [datetime]::UtcNow.AddSeconds(60)
while (-not (Test-Path -LiteralPath $Release) -and [datetime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 50 }
if (-not (Test-Path -LiteralPath $Release)) { exit 9 }
Write-Output 'SKIPPED: child platform case'
Write-Output ('FAI' + 'LED: deliberate fixture')
exit 7
'@, $utf8)
        [IO.File]::WriteAllText($driver, @'
param($Harness, $Shell, $Child, $Release, $Result)
. $Harness
$r = Invoke-ExternalCommand { & $Shell -NoProfile -File $Child $Release }
[IO.File]::WriteAllText($Result, ($r | ConvertTo-Json))
'@, $utf8)
        $psi = [Diagnostics.ProcessStartInfo]::new($shell)
        foreach ($a in @('-NoProfile', '-File', $driver, (Join-Path $PSScriptRoot '_harness.ps1'), $shell, $child, $release, $resultPath)) { $psi.ArgumentList.Add($a) }
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $proc = [Diagnostics.Process]::Start($psi)
        try {
            $stderr = $proc.StandardError.ReadToEndAsync()
            $seen = [Collections.Generic.List[string]]::new()
            $pending = $proc.StandardOutput.ReadLineAsync()
            $deadline = [datetime]::UtcNow.AddSeconds(30)
            $stepSeen = $false
            while ([datetime]::UtcNow -lt $deadline -and -not $stepSeen) {
                if (-not $pending.Wait(100)) { continue }
                $line = $pending.Result
                if ($null -eq $line) { break }
                $seen.Add($line)
                $stepSeen = $line -cmatch 'fixture progress: test: child-step'
                $pending = $proc.StandardOutput.ReadLineAsync()
            }
            # Always release before asserting, including the buffered-output mutation.
            $wasRunning = -not $proc.HasExited
            [IO.File]::WriteAllText($release, 'released')
            Assert-Result 'child step arrives before release' $stepSeen ($seen -join "`n")
            Assert-Result 'child is still running when progress arrives' $wasRunning 'Progress was buffered until exit.'
            Assert-Result 'released child exits within bound' ($proc.WaitForExit(30000)) 'Child did not finish.'
            while ($null -ne ($line = $pending.GetAwaiter().GetResult())) {
                $seen.Add($line)
                $pending = $proc.StandardOutput.ReadLineAsync()
            }
            $r = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json
            Assert-Result 'child refusal exit status is preserved' ($r.ExitCode -eq 7) ($r | ConvertTo-Json)
            Assert-Result 'both child streams and skip contract stay captured' ($r.Output -cmatch 'CHILD-STEP' -and $r.Output -cmatch 'CHILD-STDERR' -and $r.Output -cmatch '(?m)^SKIPPED: child platform case') $r.Output
            Assert-Result 'progress cannot forge parent failure or skip contracts' (($seen -join "`n") -cnotmatch 'EXCEPTION OCCURRED:|SOME TESTS FAILED|\bFAILED:|(?m)^SKIPPED:') ($seen -join "`n")
            Assert-Result 'driver has no unhandled errors' ([string]::IsNullOrEmpty($stderr.GetAwaiter().GetResult())) 'Driver stderr was not empty.'
        } finally {
            if (-not $proc.HasExited) { $proc.Kill($true); $proc.WaitForExit() }
            $proc.Dispose()
        }
    }
    $results += Run-Test 'Line mode preserves objects and native status' {
        Assert-Result 'line capture mode is available' ((Get-Command Invoke-ExternalCommand).Parameters.ContainsKey('AsLines')) 'Missing line-preserving capture mode.'
        $lines = @(Invoke-ExternalCommand -AsLines { & $shell -NoProfile -Command '"one"; "two"; exit 5' })
        Assert-Result 'line capture retains native status' ($LASTEXITCODE -eq 5) "exit=$LASTEXITCODE"
        Assert-Result 'line capture retains individual values' ($lines.Count -eq 2 -and $lines[0] -ceq 'one' -and $lines[1] -ceq 'two') ($lines -join ',')
    }
    $results += Run-Test 'In-process captures preserve caller error semantics' {
        function Invoke-NonterminatingRefusal { Write-Error 'boom'; return $false }
        foreach ($asLines in @($false, $true)) {
            $caught = ''
            try { $null = Invoke-ExternalCommand -AsLines:$asLines { Invoke-NonterminatingRefusal } }
            catch { $caught = $_.Exception.Message }
            Assert-Result 'non-terminating error still terminates under Stop' ($caught -match 'boom') "AsLines=$asLines; caught=$caught"
        }
        $ErrorActionPreference = 'Continue'
        $continued = @(Invoke-ExternalCommand -AsLines { Invoke-NonterminatingRefusal } 2>$null)
        Assert-Result 'Continue still permits the refusal return' ($continued.Count -eq 1 -and $continued[0] -eq $false) ($continued -join ',')
    }
    $results += Run-Test 'Line captures keep stderr separate unless explicitly merged' {
        $errors = Join-Path $root 'line-stderr.txt'
        $lines = @(Invoke-ExternalCommand -AsLines { & $shell -NoProfile -Command '[Console]::Error.WriteLine("warning"); "stdout"' } 2>$errors)
        Assert-Result 'line mode returns stdout only' ($lines.Count -eq 1 -and $lines[0].Trim() -ceq 'stdout') ($lines -join ',')
        Assert-Result 'line mode forwards stderr' ((Get-Content $errors -Raw) -match 'warning') 'Lost stderr.'
        $merged = @(Invoke-ExternalCommand -AsLines { & $shell -NoProfile -Command '[Console]::Error.WriteLine("warning"); "stdout"' 2>&1 })
        Assert-Result 'explicit stderr merge stays captured' (($merged -join ',') -match 'warning' -and ($merged -join ',') -match 'stdout') ($merged -join ',')
    }
    $results += Run-Test 'Output before a throw survives the capture boundary' {
        $lines = @(try { Invoke-ExternalCommand -AsLines { 'before throw'; throw 'after output' } } catch { $_.Exception.Message })
        Assert-Result 'partial line output precedes the refusal' ($lines.Count -eq 2 -and $lines[0] -ceq 'before throw' -and $lines[1] -ceq 'after output') ($lines -join ',')
        $partial = @()
        try { $null = Invoke-ExternalCommand { 'object output'; throw 'object refusal' } }
        catch { $partial = @($_.Exception.Data['CrucibleCapturedOutput']) }
        Assert-Result 'object capture attaches partial output to the exception' ($partial.Count -eq 1 -and $partial[0] -ceq 'object output') ($partial -join ',')
        $nested = @()
        try { $null = Invoke-ExternalCommand { 'outer output'; Invoke-ExternalCommand { 'inner output'; throw 'nested refusal' } } }
        catch { $nested = @($_.Exception.Data['CrucibleCapturedOutput']) }
        Assert-Result 'nested captures retain partial output from both owners in order' ($nested.Count -eq 2 -and $nested[0] -ceq 'outer output' -and $nested[1] -ceq 'inner output') ($nested -join ',')
    }
    $results += Run-Test 'Outer captures forward nested progress once without retaining it' {
        $seen = @(Invoke-ExternalCommand { '    fixture progress: test: nested step'; 'payload' } 6>&1)
        $progress = @($seen | Where-Object { [string]$_ -match 'nested step' })
        $result = @($seen | Where-Object { $_ -is [pscustomobject] -and $_.PSObject.Properties['Output'] })
        Assert-Result 'nested progress is displayed exactly once' ($progress.Count -eq 1 -and [string]$progress[0] -ceq '    fixture progress: test: nested step') ($seen -join "`n")
        Assert-Result 'nested progress does not accumulate in outer output' ($result.Count -eq 1 -and $result[0].Output -ceq 'payload') ($seen -join "`n")
        $nested = @(Invoke-ExternalCommand { Invoke-ExternalCommand -AsLines { 'payload'; 'payload' } 6>&1 } 6>&1)
        $displays = @($nested | Where-Object { [string]$_ -ceq '    fixture progress: payload' })
        $captured = @($nested | Where-Object { $_ -is [pscustomobject] -and $_.PSObject.Properties['Output'] })
        Assert-Result 'each nested payload is displayed once including real repeats' ($displays.Count -eq 2) ($nested -join "`n")
        Assert-Result 'nested payloads remain captured including real repeats' ($captured.Count -eq 1 -and $captured[0].Output -ceq "payload`npayload") ($nested -join "`n")
    }
    $results += Run-Test 'A silent child reports a completed command boundary' {
        $seen = @(Invoke-ExternalCommand { & $shell -NoProfile -Command 'exit 0' } 6>&1)
        Assert-Result 'silent child completion is visible' (@($seen | Where-Object { [string]$_ -cmatch 'fixture progress: command completed \(exit 0\)' }).Count -eq 1) ($seen -join "`n")
        $result = @($seen | Where-Object { $_ -is [pscustomobject] -and $_.PSObject.Properties['ExitCode'] })
        Assert-Result 'silent child output and status stay captured' ($result.Count -eq 1 -and $result[0].ExitCode -eq 0 -and $result[0].Output -ceq '') ($seen -join "`n")
    }
    $results += Run-Test 'Repeated captures preserve each native refusal status' {
        Assert-Result 'sequence supports line captures' ((Get-Command Invoke-ExternalCommand).Parameters.ContainsKey('AsLines')) 'Missing line-preserving capture mode.'
        function Invoke-RefusalSequence {
            $first = Invoke-ExternalCommand { & $shell -NoProfile -Command 'exit 2' }
            $second = Invoke-ExternalCommand { & $shell -NoProfile -Command 'exit 7' }
            $lines = @(Invoke-ExternalCommand -AsLines { & $shell -NoProfile -Command '"last"; exit 3' })
            return [pscustomobject]@{ First = $first.ExitCode; Second = $second.ExitCode; Last = $LASTEXITCODE; Lines = $lines }
        }
        $sequence = Invoke-RefusalSequence
        Assert-Result 'successive captures retain distinct refusal exits' ($sequence.First -eq 2 -and $sequence.Second -eq 7) ($sequence | ConvertTo-Json)
        Assert-Result 'line mode leaves the latest native refusal visible' ($sequence.Last -eq 3 -and $sequence.Lines.Count -eq 1 -and $sequence.Lines[0] -ceq 'last') ($sequence | ConvertTo-Json)
    }
    $results += Run-Test 'PowerShell captures preserve objects without a native exit' {
        $savedExit = Get-Variable -Name LASTEXITCODE -Scope Global -ErrorAction SilentlyContinue
        try {
            Remove-Variable -Name LASTEXITCODE -Scope Global -ErrorAction SilentlyContinue
            $caught = ''
            $pure = $null
            try { $pure = Invoke-ExternalCommand { Write-Output 'pure PowerShell output' } } catch { $caught = $_.Exception.Message }
            Assert-Result 'capture without a native child has no invented exit status' ($caught -eq '' -and $null -ne $pure -and $null -eq $pure.ExitCode -and $pure.Output -ceq 'pure PowerShell output') $caught
            Assert-Result 'object mode is available' ((Get-Command Invoke-ExternalCommand).Parameters.ContainsKey('AsLines')) 'Missing line-preserving capture mode.'
            $object = [pscustomobject]@{ Step = 42 }
            $objects = @(Invoke-ExternalCommand -AsLines { $object })
            Assert-Result 'line mode preserves the original object' ($objects.Count -eq 1 -and [object]::ReferenceEquals($object, $objects[0])) ($objects -join ',')
        } finally {
            if ($null -ne $savedExit) { $global:LASTEXITCODE = $savedExit.Value }
        }
    }
} finally {
    Remove-Item -LiteralPath $root -Recurse -Force
}
Write-TestFileSummary -Results $results
