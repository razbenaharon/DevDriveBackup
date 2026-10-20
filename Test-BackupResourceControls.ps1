#Requires -Version 7.2
$ErrorActionPreference='Stop'
Add-Type -Path (Join-Path $PSScriptRoot 'Backup.Process.cs')
$job=[BackupMemoryJob]::new(256MB)
$process=$null
try {
 $psi=[Diagnostics.ProcessStartInfo]::new((Get-Process -Id $PID).Path);$psi.UseShellExecute=$false;$psi.CreateNoWindow=$true;$psi.RedirectStandardOutput=$true;$psi.RedirectStandardError=$true
 $code="try { [byte[]]`$allocation=[byte[]]::new(536870912);Write-Output 'UNEXPECTED_ALLOCATION';exit 2 } catch {Write-Output 'ALLOCATION_BLOCKED';exit 0}"
 foreach($a in @('-NoProfile','-EncodedCommand',[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($code)))){[void]$psi.ArgumentList.Add($a)}
 $process=[Diagnostics.Process]::Start($psi);$job.Add($process)
 $output=$process.StandardOutput.ReadToEnd();$errorOutput=$process.StandardError.ReadToEnd();$process.WaitForExit()
 if($process.ExitCode -ne 0 -or $output.Trim() -ne 'ALLOCATION_BLOCKED'){throw 'Hard memory-limit enforcement test failed'}
 Write-Output 'PASS: a 256 MiB job budget blocked a 512 MiB allocation'
}finally{if($process){if(-not $process.HasExited){$process.Kill($true)};$process.Dispose()};$job.Dispose()}
