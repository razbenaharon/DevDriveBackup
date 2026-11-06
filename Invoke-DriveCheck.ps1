#Requires -Version 7.2
# Drive check of a backup drive. Runs as administrator: DevDriveBackup asks Windows for that,
# because the drive's own report, raw reads and the file system scan need it.
#  Quick         the drive's health report and a short self-test, sample reads at the start,
#                middle and end, Windows' log of disk errors, the link speed, a file system scan
#  Surface       reads every part of the disk; stops on request and later continues from there
#  LongSelfTest  asks the drive to read itself completely. The drive works alone for hours;
#                the next quick check shows the result.
# Only reads. Nothing on the drive is written, moved or repaired.
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
# One check per drive at a time. The lock is held until this process ends; a second check stops
# here without touching the first one's files.
try{$lock=[IO.File]::Open((Join-Path $OutputDirectory 'check.lock'),'OpenOrCreate','ReadWrite','None')}
catch{[Console]::Error.WriteLine('Another drive check of this drive is running.');exit 1}

Add-Type -TypeDefinition @'
using System; using System.Collections.Generic; using System.ComponentModel; using System.Diagnostics; using System.Globalization; using System.Runtime.InteropServices; using System.Text; using Microsoft.Win32.SafeHandles;
public static class BackupDriveScanner {
 [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern SafeFileHandle CreateFile(string n,uint a,uint s,IntPtr sa,uint d,uint f,IntPtr t);
 [DllImport("kernel32.dll",SetLastError=true)] static extern bool ReadFile(SafeFileHandle h,IntPtr b,uint n,out uint done,IntPtr o);
 [DllImport("kernel32.dll",SetLastError=true)] static extern bool SetFilePointerEx(SafeFileHandle h,long d,out long np,uint m);
 [DllImport("kernel32.dll",SetLastError=true)] static extern IntPtr VirtualAlloc(IntPtr a,UIntPtr n,uint t,uint p);
 [DllImport("kernel32.dll")] static extern bool VirtualFree(IntPtr a,UIntPtr n,uint t);
 [DllImport("kernel32.dll")] static extern uint SetThreadExecutionState(uint flags);
 // These mean the drive is gone (unplugged, asleep, box reset), not that an area is bad.
 static readonly int[] Gone={2,3,6,21,55,433,1167};
 static string N(double v){return v.ToString("0.###",CultureInfo.InvariantCulture);}
 public static void KeepAwake(bool on){SetThreadExecutionState(on?0x80000001u:0x80000000u);}
 static int ReadAt(SafeFileHandle h,IntPtr buf,long pos,int n){
  long np;if(!SetFilePointerEx(h,pos,out np,0))return Marshal.GetLastWin32Error();
  uint got;if(!ReadFile(h,buf,(uint)n,out got,IntPtr.Zero))return Marshal.GetLastWin32Error();
  return got==(uint)n?0:38;
 }
 // Reads [start, start+length) of a physical disk without the Windows cache, 4 MiB at a time.
 // A chunk that fails is read again in 64 KiB pieces so the report names the damaged place.
 // VerySlow: a chunk over verySlowMs (the drive retried hard). Slow: over 10x the median and 250 ms.
 public static string Read(string device,long start,long length,int sector,double verySlowMs){
  const int chunk=4*1024*1024;int piece=Math.Max(sector,64*1024);
  IntPtr buf=VirtualAlloc(IntPtr.Zero,(UIntPtr)chunk,0x3000,4);if(buf==IntPtr.Zero)throw new Win32Exception();
  var times=new List<double>();var where=new List<long>();var bad=new StringBuilder();int badCount=0;long done=0;var total=Stopwatch.StartNew();
  try{
   using(var h=CreateFile(device,0x80000000,3,IntPtr.Zero,3,0x20000000,IntPtr.Zero)){
    if(h.IsInvalid)throw new Win32Exception(Marshal.GetLastWin32Error());
    long end=start+length;
    for(long pos=start;pos<end;pos+=chunk){
     int n=(int)Math.Min(chunk,end-pos);var w=Stopwatch.StartNew();int err=ReadAt(h,buf,pos,n);double ms=w.Elapsed.TotalMilliseconds;
     if(err==0){times.Add(ms);where.Add(pos);}
     else{
      if(Array.IndexOf(Gone,err)>=0)throw new Win32Exception(err,"The drive stopped answering ("+err+"). Check that it is still connected.");
      for(long p=pos;p<pos+n;p+=piece){
       int m=(int)Math.Min(piece,pos+n-p);int e=ReadAt(h,buf,p,m);if(e==0)continue;
       if(Array.IndexOf(Gone,e)>=0)throw new Win32Exception(e,"The drive stopped answering ("+e+"). Check that it is still connected.");
       if(badCount<200){if(bad.Length>0)bad.Append(',');bad.Append("{\"Offset\":"+p+",\"Length\":"+m+",\"Code\":"+e+"}");}
       badCount++;
      }
     }
     done+=n;
    }
   }
  }finally{VirtualFree(buf,UIntPtr.Zero,0x8000);}
  double[] sorted=times.ToArray();Array.Sort(sorted);double median=sorted.Length>0?sorted[sorted.Length/2]:0;double max=sorted.Length>0?sorted[sorted.Length-1]:0;
  var slow=new StringBuilder();int slowCount=0,verySlow=0;double slowMs=Math.Max(250,10*median);
  for(int i=0;i<times.Count;i++){
   bool very=times[i]>=verySlowMs;if(very)verySlow++;
   if(very||times[i]>=slowMs){if(slowCount<200){if(slow.Length>0)slow.Append(',');slow.Append("{\"Offset\":"+where[i]+",\"Ms\":"+N(times[i])+"}");}slowCount++;}
  }
  return "{\"Bytes\":"+done+",\"Seconds\":"+N(total.Elapsed.TotalSeconds)+",\"MedianMs\":"+N(median)+",\"MaxMs\":"+N(max)+",\"BadCount\":"+badCount+",\"Bad\":["+bad+"],\"SlowCount\":"+slowCount+",\"VerySlowCount\":"+verySlow+",\"Slow\":["+slow+"]}";
 }
}
'@

function Set-CheckProgress([string]$Text,[double]$Percent=-1){
 [void](Write-BackupStatus ([ordered]@{Mode=$Mode;Text=$Text;Percent=[math]::Round($Percent,1);Updated=(Get-Date).ToString('o')}) (Join-Path $OutputDirectory 'progress.json') -BestEffort)
}
function Complete-Check([bool]$Success,[string]$Message){
 [void](Write-BackupStatus ([ordered]@{Mode=$Mode;Success=$Success;Message=$Message;Started=$started.ToString('o');Finished=(Get-Date).ToString('o')}) (Join-Path $OutputDirectory 'run.json'))
}
# A request left over from an earlier run does not count, only one made after this run started.
function Test-StopRequested{(Test-Path -LiteralPath $stopFile) -and (Get-Item -LiteralPath $stopFile).LastWriteTime -ge $started}
function Invoke-Smart([string[]]$Arguments){
 $out=& $SmartTool @Arguments '--json' 2>$null;$code=$LASTEXITCODE;$json=$null
 try{$json=($out -join "`n")|ConvertFrom-Json}catch{}
 [pscustomobject]@{Code=$code;Json=$json}
}
function Get-SmartReport{
 if(-not(Test-Path -LiteralPath $SmartTool)){return [pscustomobject]@{Json=$null;Type=$null;Why='The health tool is not installed. Use "Install health tool" on this page, then check again.'}}
 # First the type smartctl detects itself; many USB boxes answer only when the standard SAT pass-through is named.
 foreach($t in @('auto','sat')){
  $r=Invoke-Smart @('-a','-d',$t,$script:smartDevice)
  if(Test-DriveSmartAnswer $r.Json){return [pscustomobject]@{Json=$r.Json;Type=$t;Why=''}}
 }
 [pscustomobject]@{Json=$null;Type=$null;Why='The drive did not answer. Its USB box or adapter does not pass the health request on, so this part cannot be checked through it.'}
}
function Read-DiskRegion([long]$Start,[long]$Length){[BackupDriveScanner]::Read($script:device,$Start,$Length,$script:sector,1000)|ConvertFrom-Json}

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
  $state=$null
  if(Test-Path -LiteralPath $statePath){$old=Read-BackupStatus $statePath;if($old.Identity -eq $identity -and -not $old.Complete){$state=$old}}
  if(-not $state){$state=[pscustomobject]@{Identity=$identity;Size=$size;NextOffset=[long]0;Complete=$false;Started=(Get-Date).ToString('o');Finished=$null;Seconds=0.0;BadCount=0;VerySlowCount=0;SlowCount=0;Bad=@();Slow=@()}}
  $from=[long]$state.NextOffset;$session=[Diagnostics.Stopwatch]::StartNew()
  [BackupDriveScanner]::KeepAwake($true)
  try{
   while([long]$state.NextOffset -lt $size -and -not (Test-StopRequested)){
    $pos=[long]$state.NextOffset;$len=[math]::Min([long]512MB,$size-$pos)
    $r=Read-DiskRegion $pos $len
    $state.BadCount+=$r.BadCount;$state.SlowCount+=$r.SlowCount;$state.VerySlowCount+=$r.VerySlowCount;$state.Seconds=[double]$state.Seconds+[double]$r.Seconds
    $state.Bad=@(@($state.Bad)+@($r.Bad)|Where-Object {$_}|Select-Object -First 200)
    $state.Slow=@(@($state.Slow)+@($r.Slow)|Where-Object {$_}|Select-Object -First 200)
    $state.NextOffset=$pos+$len
    [void](Write-BackupStatus $state $statePath)
    $readNow=[long]$state.NextOffset-$from;$rate=$readNow/[math]::Max(1,$session.Elapsed.TotalSeconds)
    $left=[TimeSpan]::FromSeconds(($size-[long]$state.NextOffset)/[math]::Max(1,$rate))
    $found=if($state.BadCount){"$($state.BadCount) unreadable areas so far"}else{'no unreadable areas so far'}
    Set-CheckProgress ('Full scan: {0:N0} of {1:N0} GB read, {2:N0} MB/s, about {3}h {4:D2}m left. {5}.' -f ([long]$state.NextOffset/1GB),($size/1GB),($rate/1e6),[int][math]::Floor($left.TotalHours),$left.Minutes,$found) (100*[double]$state.NextOffset/$size)
   }
  }finally{[BackupDriveScanner]::KeepAwake($false)}
  if([long]$state.NextOffset -ge $size){$state.Complete=$true;$state.Finished=(Get-Date).ToString('o')}
  [void](Write-BackupStatus $state $statePath)
  $msg=if($state.Complete){if($state.BadCount){"Full scan finished: $($state.BadCount) areas could not be read."}else{'Full scan finished: every part of the drive could be read.'}}else{'Full scan stopped at {0:N0}%. It continues from there next time.' -f (100*[double]$state.NextOffset/$size)}
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
  [pscustomobject]@{Name=$r[0];Offset=$r[1];MBps=[math]::Round([double]$x.Bytes/[math]::Max(0.001,[double]$x.Seconds)/1e6);BadCount=[int]$x.BadCount;VerySlowCount=[int]$x.VerySlowCount;Bad=@($x.Bad)}
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
 $eventFindings=@(Get-DriveEventFindings @($events) $disk.Number $letter ([string]$disk.BusType -eq 'USB') $connections)
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
  Health=Merge-DriveEvents (Get-DriveHealthFindings $final $smart.Why) $eventFindings 'Health'
  Connection=Merge-DriveEvents (Get-DriveConnectionFindings $link ([string]$disk.BusType) $final $counters) $eventFindings 'Connection'
  FileSystem=Merge-DriveEvents (Get-DriveFileSystemFindings $letter ([string]$volume.FileSystem) $fsResult $fsError ([string]$volume.HealthStatus)) $eventFindings 'FileSystem'
 }
 [void](Write-BackupStatus $report (Join-Path $OutputDirectory 'report.json'))
 Complete-Check $true 'Quick check finished.'
}catch{
 try{Complete-Check $false $_.Exception.Message}catch{}
 throw
}
