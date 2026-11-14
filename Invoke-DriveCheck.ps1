#Requires -Version 7.2
# Drive check of a backup drive. Runs as administrator: DevDriveBackup asks Windows for that,
# because the drive's own report, raw reads and the file system scan need it.
#  Quick         the drive's health report and a short self-test, sample reads at the start,
#                middle and end, Windows' log of disk errors, the link speed, a file system scan
#  Surface       reads every part of the disk; stops on request and later continues from there
#  LongSelfTest  asks the drive to read itself completely. The drive works alone for hours;
#                the next quick check shows the result.
# Only reads. Nothing on the drive is written, moved or repaired. smartctl (the bundled copy, or
# one given with -SmartTool) runs only when its SHA-256 matches the official 7.5 build.
# Into -OutputDirectory it writes progress.json while it runs and run.json at the end, plus
# report.json (quick check) and surface.json (full scan). A file named stop.request ends the run.
param(
 [Parameter(Mandatory)][ValidatePattern('^[A-Za-z]$')][string]$Drive,
 [Parameter(Mandatory)][string]$OutputDirectory,
 [ValidateSet('Quick','Surface','LongSelfTest')][string]$Mode='Quick',
 [string]$SmartTool=(Join-Path $PSScriptRoot 'bin\smartmontools\bin\smartctl.exe'),
 [ValidateRange(16,4096)][int]$SampleMiB=256
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'Backup.Status.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Backup.DriveCheck.psm1') -Force
New-Item -ItemType Directory -Path $OutputDirectory -Force|Out-Null
$stopFile=Join-Path $OutputDirectory 'stop.request'
$started=Get-Date
# Stop requests are compared with the moment Windows started this process, not the moment this line
# ran: a Stop pressed while PowerShell was still starting must count too.
$stopSince=[Diagnostics.Process]::GetCurrentProcess().StartTime
# One check per drive at a time. The lock is held until this process ends; a second check stops
# here without touching the first one's files.
try{$lock=[IO.File]::Open((Join-Path $OutputDirectory 'check.lock'),'OpenOrCreate','ReadWrite','None')}
catch{[Console]::Error.WriteLine('Another drive check of this drive is running.');exit 1}
# smartctl runs as administrator here, so the copy that is asked for (the bundled one, or another
# path given with -SmartTool) must be the official 7.5 build. It stays open (others may only read
# it) until this check ends, so it cannot be replaced after the check. A tool that is missing now
# is never run later in this check, even if a file appears meanwhile.
$tool=Open-DriveCheckSmartTool $SmartTool
$script:smartProblem=$tool.Problem;$script:smartHold=$tool.Hold

# The reader (BackupDriveScanner) lives in Backup.DriveCheck.psm1, where it is tested on a file.
Add-DriveScannerType

function Set-CheckProgress([string]$Text,[double]$Percent=-1){
 [void](Write-BackupStatus ([ordered]@{Mode=$Mode;Text=$Text;Percent=[math]::Round($Percent,1);Updated=(Get-Date).ToString('o')}) (Join-Path $OutputDirectory 'progress.json') -BestEffort)
}
function Complete-Check([bool]$Success,[string]$Message){
 [void](Write-BackupStatus ([ordered]@{Mode=$Mode;Success=$Success;Message=$Message;Started=$started.ToString('o');Finished=(Get-Date).ToString('o')}) (Join-Path $OutputDirectory 'run.json'))
}
function Test-StopRequested{Test-DriveStopRequest $stopFile $stopSince}
function Invoke-Smart([string[]]$Arguments){
 if($script:smartProblem){return [pscustomobject]@{Code=-1;Json=$null}}
 $out=& $SmartTool @Arguments '--json' 2>$null;$code=$LASTEXITCODE;$json=$null
 try{$json=($out -join "`n")|ConvertFrom-Json}catch{}
 [pscustomobject]@{Code=$code;Json=$json}
}
function Get-SmartReport{
 # Decided once at the start: missing, not the official build, or held open and checked.
 if($script:smartProblem){return [pscustomobject]@{Json=$null;Type=$null;Seen=$null;Why=$script:smartProblem}}
 # First the type smartctl detects itself; many USB boxes answer only when the standard SAT pass-through is named.
 # Seen: an answer that carried only the overall "passed" flag, kept so that the report can say so.
 $seen=$null
 foreach($t in @('auto','sat')){
  $r=Invoke-Smart @('-a','-d',$t,$script:smartDevice)
  if(Test-DriveSmartAnswer $r.Json){return [pscustomobject]@{Json=$r.Json;Type=$t;Seen=$null;Why=''}}
  if(Test-DriveSmartFlagOnly $r.Json){$seen=$r.Json}
 }
 [pscustomobject]@{Json=$null;Type=$null;Seen=$seen;Why='The drive did not answer. Its USB box or adapter does not pass the health request on, so this part cannot be checked through it.'}
}
# The reader looks for a stop request before every 4 MiB chunk, so Stop does not wait for a whole stretch.
function Read-DiskRegion([long]$Start,[long]$Length){[BackupDriveScanner]::Read($script:device,$Start,$Length,$script:sector,1000,$stopFile,$stopSince.Ticks)|ConvertFrom-Json}

try{
 if(-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){
  throw 'The drive check needs administrator rights. Start it from DevDriveBackup, which asks Windows for them.'
 }
 $letter=$Drive.ToUpperInvariant()
 $volume=Get-Volume -DriveLetter $letter
 $disk=Get-Partition -DriveLetter $letter|Get-Disk
 $script:device="\\.\PhysicalDrive$($disk.Number)"
 $script:smartDevice="/dev/pd$($disk.Number)"
 $script:sector=[int]$disk.LogicalSectorSize
 $size=[long]$disk.Size
 $chunk=4MB

 if($Mode -eq 'LongSelfTest'){
  Set-CheckProgress 'Asking the drive to start its long self-test...'
  $smart=Get-SmartReport;if(-not $smart.Json){throw $smart.Why}
  $t=Get-DriveSelfTest $smart.Json
  if(-not $t.Supported){throw 'This drive does not offer self-tests.'}
  if($t.Running){Complete-Check $true "A self-test is already running, about $($t.Running.Remaining)% left. Run a quick check after it finishes.";return}
  $r=Invoke-Smart @('-t','long','-d',$smart.Type,$script:smartDevice)
  if($r.Code -band 6){throw 'The drive did not accept the self-test.'}
  $time=if($t.LongMinutes){" It expects to need about $([math]::Round([double]$t.LongMinutes/60,1)) hours."}else{''}
  Complete-Check $true ("The drive is now reading itself.$time Keep it connected and keep the computer awake: a USB box that goes to sleep stops the test. Run a quick check afterwards to see the result.")
  return
 }

 if($Mode -eq 'Surface'){
  $statePath=Join-Path $OutputDirectory 'surface.json'
  $identity="$($disk.SerialNumber)|$size"
  # An unfinished scan of this drive continues. A new one carries what the last finished scan found
  # (Previous) until it is through; a saved position that cannot be read is set aside, never deleted.
  $saved=Read-DriveScanState $statePath $identity
  $state=if($saved.State){$saved.State}else{New-DriveScanState $identity $size $saved.Previous}
  $from=[long]$state.NextOffset;$session=[Diagnostics.Stopwatch]::StartNew()
  [BackupDriveScanner]::KeepAwake($true)
  try{
   while([long]$state.NextOffset -lt $size -and -not (Test-StopRequested)){
    $pos=[long]$state.NextOffset;$len=[math]::Min([long]512MB,$size-$pos)
    $r=Read-DiskRegion $pos $len
    $state.BadCount+=$r.BadCount;$state.SlowCount+=$r.SlowCount;$state.VerySlowCount+=$r.VerySlowCount;$state.RecoveredCount+=$r.RecoveredCount;$state.Seconds=[double]$state.Seconds+[double]$r.Seconds
    $state.Bad=@(@($state.Bad)+@($r.Bad)|Where-Object {$_}|Select-Object -First 200)
    $state.Slow=@(@($state.Slow)+@($r.Slow)|Where-Object {$_}|Select-Object -First 200)
    $state.Recovered=@(@($state.Recovered)+@($r.Recovered)|Where-Object {$_}|Select-Object -First 200)
    # A stretch cut short by a stop request ends at its last whole chunk; the scan goes on from there.
    $state.NextOffset=$pos+[long]$r.Bytes
    [void](Write-BackupStatus $state $statePath)
    $readNow=[long]$state.NextOffset-$from;$rate=$readNow/[math]::Max(1,$session.Elapsed.TotalSeconds)
    $left=[TimeSpan]::FromSeconds(($size-[long]$state.NextOffset)/[math]::Max(1,$rate))
    $found=if($state.BadCount){"$($state.BadCount) unreadable areas so far"}else{'no unreadable areas so far'}
    Set-CheckProgress ('Full scan: {0:N0} of {1:N0} GiB read, {2:N0} MB/s, about {3}h {4:D2}m left. {5}.' -f ([long]$state.NextOffset/1GB),($size/1GB),($rate/1e6),[int][math]::Floor($left.TotalHours),$left.Minutes,$found) (100*[double]$state.NextOffset/$size)
    if($r.Stopped){break}
   }
  }finally{[BackupDriveScanner]::KeepAwake($false)}
  if([long]$state.NextOffset -ge $size){$state.Complete=$true;$state.Finished=(Get-Date).ToString('o');$state.Previous=$null}
  [void](Write-BackupStatus $state $statePath)
  $msg=if($state.Complete){if($state.BadCount){"Full scan finished: $($state.BadCount) areas could not be read."}else{'Full scan finished: every part of the drive could be read.'}}else{'Full scan stopped at {0:N0}%. It continues from there next time.' -f (100*[double]$state.NextOffset/$size)}
  if($saved.SetAside){$msg+=" The saved position of an earlier scan could not be read, so this scan started from the beginning; that file was kept as $(Split-Path -Leaf $saved.SetAside)."}
  Complete-Check $true $msg
  return
 }

 # --- Quick check ---------------------------------------------------------------------------
 Set-CheckProgress 'Reading the drive''s own health report...' 2
 $smart=Get-SmartReport
 Set-CheckProgress 'Reading samples at the start, middle and end of the drive...' 8
 # Samples are read before the self-test starts, so the self-test does not slow them down.
 $len=[long][math]::Min([long]$SampleMiB*1MB,[math]::Floor($size/3/$chunk)*$chunk)
 $regions=foreach($r in @(@('start',[long]0),@('middle',[long]([math]::Floor($size/2/$chunk)*$chunk)),@('end',[long]($size-$len)))){
  if(Test-StopRequested){break}
  $x=Read-DiskRegion $r[1] $len
  if($x.Stopped){break}
  [pscustomobject]@{Name=$r[0];Offset=$r[1];MBps=[math]::Round([double]$x.Bytes/[math]::Max(0.001,[double]$x.Seconds)/1e6);BadCount=[int]$x.BadCount;VerySlowCount=[int]$x.VerySlowCount;RecoveredCount=[int]$x.RecoveredCount;Bad=@($x.Bad)}
 }
 $testStarted=$null
 if($smart.Json){
  $t=Get-DriveSelfTest $smart.Json
  if($t.Supported -and -not $t.Running -and -not (Test-StopRequested)){
   $r=Invoke-Smart @('-t','short','-d',$smart.Type,$script:smartDevice)
   if(-not ($r.Code -band 6)){$testStarted=Get-Date}
  }
 }
 Set-CheckProgress 'Reading Windows'' log of disk and connection errors...' 30
 # One source at a time: a source this computer lacks, or one that cannot be read, must not hide the others.
 $events=[Collections.Generic.List[object]]::new();$unread=[Collections.Generic.List[string]]::new()
 foreach($provider in @('disk','Ntfs','Microsoft-Windows-Ntfs','uaspstor','USBSTOR','stornvme','storahci')){
  try{$found=@(Get-WinEvent -FilterHashtable @{LogName='System';ProviderName=$provider;StartTime=(Get-Date).AddDays(-30);Level=1,2,3} -ErrorAction Stop)}
  catch{if($_.FullyQualifiedErrorId -notlike 'NoMatching*'){$unread.Add("$provider ($($_.Exception.Message))")};continue}
  foreach($e in $found){
   # The event data always holds \Device\Harddisk<N>\; some messages name the disk only in words.
   $text=$null;try{$text=$e.Message}catch{}
   $text=[string]$text+' '+(@($e.Properties|ForEach-Object {if($_.Value -is [string]){$_.Value}}) -join ' ')
   $events.Add([pscustomobject]@{ProviderName=($e.ProviderName -replace '^Microsoft-Windows-','');Id=$e.Id;TimeCreated=$e.TimeCreated;Message=$text})
  }
 }
 # Windows records every drive arrival with its disk number; that tells which drive an older entry was about.
 $connections=[Collections.Generic.List[object]]::new()
 try{
  foreach($e in @(Get-WinEvent -FilterHashtable @{LogName='Microsoft-Windows-Partition/Diagnostic';Id=1006} -ErrorAction Stop)){
   $d=@{};foreach($x in ([xml]$e.ToXml()).Event.EventData.Data){$d[$x.Name]=$x.InnerText}
   if($d['Capacity'] -and $d['Capacity'] -ne '0'){$connections.Add([pscustomobject]@{Time=$e.TimeCreated;DiskNumber=[int]$d['DiskNumber'];Key=(Get-DriveConnectionKey $d['SerialNumber'] $d['Model'] $d['Capacity'])})}
  }
 }catch{if($_.FullyQualifiedErrorId -notlike 'NoMatching*'){$unread.Add("drive connections ($($_.Exception.Message))")}}
 $eventFindings=@(Get-DriveEventFindings @($events) $disk.Number $letter ([string]$disk.BusType -eq 'USB') $connections ([string]$disk.BusType))
 if($unread.Count){$eventFindings+=[pscustomobject]@{Group='Connection';Status='NotRun';Line='Part of the Windows log could not be read: '+($unread -join '; ')}}
 Set-CheckProgress 'Checking the connection...' 36
 $link=$null
 try{& (Join-Path $PSScriptRoot 'Measure-BackupDisk.ps1') -Drive $letter -LinkOnly -OutputDirectory $OutputDirectory|Out-Null;$link=Get-Content -LiteralPath (Join-Path $OutputDirectory 'usb-speed.json') -Raw|ConvertFrom-Json}catch{}
 $counters=$null
 try{$counters=Get-PhysicalDisk|Where-Object {[string]$_.DeviceId -eq [string]$disk.Number}|Get-StorageReliabilityCounter -ErrorAction Stop|Select-Object -First 1 ReadErrorsTotal,ReadErrorsUncorrected,WriteErrorsTotal,WriteErrorsUncorrected}catch{}
 $fsResult='';$fsError=''
 if(-not (Test-StopRequested) -and [string]$volume.FileSystem -eq 'NTFS'){
  Set-CheckProgress 'Checking the file system (Windows scan, read only)...' 42
  try{$fsResult=[string](Repair-Volume -DriveLetter $letter -Scan)}catch{$fsError=$_.Exception.Message}
 }
 $final=$smart.Json
 if($testStarted){
  # The short self-test takes about two minutes; the drive reports its own estimate.
  $limit=$testStarted.AddMinutes([math]::Max(2,[double]$(if($t.ShortMinutes){$t.ShortMinutes}else{2}))+3)
  while((Get-Date) -lt $limit){
   if(Test-StopRequested){[void](Invoke-Smart @('-X','-d',$smart.Type,$script:smartDevice));break}
   $pct=50+45*((Get-Date)-$testStarted).TotalSeconds/($limit-$testStarted).TotalSeconds
   Set-CheckProgress 'The drive is running its short self-test (about two minutes)...' $pct
   Start-Sleep -Seconds 10
   $now=(Invoke-Smart @('-a','-d',$smart.Type,$script:smartDevice)).Json
   if(Test-DriveSmartAnswer $now){$final=$now;if(-not (Get-DriveSelfTest $now).Running){break}}
  }
 }
 if(Test-StopRequested){Complete-Check $false 'Stopped. The previous result is kept.';return}
 $report=[ordered]@{
  Drive=$letter;DiskNumber=$disk.Number;BusType=[string]$disk.BusType;Format=[string]$volume.FileSystem;SmartType=$smart.Type
  Started=$started.ToString('o');Finished=(Get-Date).ToString('o')
  Sample=[ordered]@{Regions=@($regions)};Events=$eventFindings
  Health=Merge-DriveEvents (Get-DriveHealthFindings $(if($final){$final}else{$smart.Seen}) $smart.Why) $eventFindings 'Health'
  Connection=Merge-DriveEvents (Get-DriveConnectionFindings $link ([string]$disk.BusType) $final $counters) $eventFindings 'Connection'
  FileSystem=Merge-DriveEvents (Get-DriveFileSystemFindings $letter ([string]$volume.FileSystem) $fsResult $fsError ([string]$volume.HealthStatus)) $eventFindings 'FileSystem'
 }
 [void](Write-BackupStatus $report (Join-Path $OutputDirectory 'report.json'))
 Complete-Check $true 'Quick check finished.'
}catch{
 try{Complete-Check $false $_.Exception.Message}catch{}
 throw
}
