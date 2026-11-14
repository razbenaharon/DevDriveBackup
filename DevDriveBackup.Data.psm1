#Requires -Version 7.2
# Data layer of the DevDriveBackup: drive profiles, their sources, run history and freshness.
#
# A profile belongs to one backup drive (matched by volume identity, not drive letter) and
# lists the folders backed up to that drive. Each source is any folder on any local volume
# and has its own job configuration in the format backup.local.json uses, so the existing
# tools run it unchanged: Invoke-FastMirror.ps1 for the plain copy and Backup-Worker.ps1 for
# versioned history. Per-folder modes (Mirror, Versioned, Both, Skip) live in that file.
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'Backup.Status.psm1')
Import-Module (Join-Path $PSScriptRoot 'Backup.Selection.psm1')

$script:ToolRoot=$PSScriptRoot
$script:Paths=$null
# Rebuildable folders skipped everywhere, as in Invoke-FastMirror.ps1.
$script:CacheNames=@('node_modules','.venv','venv','__pycache__','.pytest_cache','.next','.turbo','.pnpm-store','.mypy_cache','.ruff_cache','pytest-of-*','.temporary-worker-test-*')
$script:LoadNames=@('Light','Balanced','Strong','Maximum','Custom')
$script:Hardware=$null

function Get-CenterHardware([switch]$Refresh) {
 # Processor and memory of this computer; free memory is read fresh each time.
 if(-not $script:Hardware -or $Refresh){
  $cpus=@(Get-CimInstance Win32_Processor)
  $script:Hardware=[pscustomobject]@{CpuName=(([string]$cpus[0].Name) -replace '\s+',' ').Trim();Cores=[int]($cpus|Measure-Object NumberOfCores -Sum).Sum;Threads=[Environment]::ProcessorCount;MemoryGB=0.0;FreeMemoryGB=0.0}
 }
 $os=Get-CimInstance Win32_OperatingSystem
 $script:Hardware.MemoryGB=[math]::Round($os.TotalVisibleMemorySize/1MB,1);$script:Hardware.FreeMemoryGB=[math]::Round($os.FreePhysicalMemory/1MB,1)
 $script:Hardware
}
function Get-CenterLoadPresets($Hardware) {
 # Four levels scaled to this computer. Threads = processor threads used for compression and
 # encryption (versions); CopyThreads = files copied at once (plain copy); MemoryMiB = hard cap
 # for the versions engine; Priority decides who wins when your own programs need the computer.
 $t=[math]::Max(1,[int]$Hardware.Threads);$mem=[double]$Hardware.MemoryGB*1024
 # Maximum leaves one thread for the rest of the computer, but never works with fewer than Strong
 # (on 2 and 3 threads "all but one" would be below it).
 $strong=[int][math]::Min($t,[math]::Max(2,[math]::Floor($t/2)))
 $m={param([double]$Share,[int]$Min,[int]$Max)[int][math]::Max($Min,[math]::Min($Max,[math]::Floor($mem*$Share/256)*256))}
 [ordered]@{
  Light=[pscustomobject]@{Name='Light';CpuThreads=[int][math]::Max(1,[math]::Floor($t/6));MemoryMiB=(& $m 0.03 512 1024);CopyThreads=4;ReadConcurrency=1;Priority='BelowNormal'}
  Balanced=[pscustomobject]@{Name='Balanced';CpuThreads=[int][math]::Min($t,[math]::Max(2,[math]::Floor($t/3)));MemoryMiB=(& $m 0.06 512 2048);CopyThreads=8;ReadConcurrency=2;Priority='BelowNormal'}
  Strong=[pscustomobject]@{Name='Strong';CpuThreads=$strong;MemoryMiB=(& $m 0.12 1024 4096);CopyThreads=16;ReadConcurrency=4;Priority='Normal'}
  Maximum=[pscustomobject]@{Name='Maximum';CpuThreads=[int][math]::Max($strong,$t-1);MemoryMiB=(& $m 0.25 1024 8192);CopyThreads=32;ReadConcurrency=8;Priority='Normal'}
 }
}
function Get-CenterLoad($Profile,$Hardware=(Get-CenterHardware)) {
 # The load chosen for a profile: one of the levels, or the user's own numbers (Custom).
 $name=if($Profile.PSObject.Properties['Load'] -and $Profile.Load){[string]$Profile.Load}else{'Balanced'}
 if($name -eq 'Custom' -and $Profile.PSObject.Properties['CustomLoad'] -and $Profile.CustomLoad){
  $c=$Profile.CustomLoad;$threads=[int][math]::Min([math]::Max(1,[int]$c.CpuThreads),[int]$Hardware.Threads)
  return [pscustomobject]@{Name='Custom';CpuThreads=$threads;MemoryMiB=[int][math]::Min(8192,[math]::Max(512,[int]$c.MemoryMiB));CopyThreads=[int][math]::Min(128,[math]::Max(1,[int]$c.CopyThreads));ReadConcurrency=[int][math]::Min(8,$threads);Priority=$(if([string]$c.Priority -eq 'Normal'){'Normal'}else{'BelowNormal'})}
 }
 $presets=Get-CenterLoadPresets $Hardware
 if(-not $presets.Contains($name)){$name='Balanced'}
 $presets[$name]
}
function Set-CenterRunPriority($Process,[string]$Priority) {
 # Applies a priority to a running tool and everything it started (robocopy, restic), so the
 # load can be lowered or raised while a backup runs.
 $ids=[Collections.Generic.List[int]]::new();$ids.Add($Process.Id)
 $all=@(Get-CimInstance Win32_Process -Property ProcessId,ParentProcessId)
 for($i=0;$i -lt $ids.Count;$i++){foreach($c in $all){if($c.ParentProcessId -eq $ids[$i] -and -not $ids.Contains([int]$c.ProcessId)){$ids.Add([int]$c.ProcessId)}}}
 foreach($id in $ids){try{(Get-Process -Id $id -ErrorAction Stop).PriorityClass=$Priority}catch{}}
}

function Set-CenterPaths([string]$Root) {
 # Root '' = the real locations; tests pass a disposable folder.
 if($Root){
  $script:Paths=[pscustomobject]@{Profiles=(Join-Path $Root 'profiles.local.json');Jobs=(Join-Path $Root 'jobs');History=(Join-Path $Root 'history.jsonl');Keys=(Join-Path $Root 'keys');Documents=(Join-Path $Root 'documents');DriveCheck=(Join-Path $Root 'drive-check');Appearance=(Join-Path $Root 'appearance.json');Logs=(Join-Path $Root 'logs')}
 }else{
  $app=Join-Path $env:LOCALAPPDATA 'DevDriveMirror'
  $script:Paths=[pscustomobject]@{Profiles=(Join-Path $script:ToolRoot 'profiles.local.json');Jobs=(Join-Path $script:ToolRoot 'jobs');History=(Join-Path $app 'center\history.jsonl');Keys=$app;Documents=(Join-Path $env:USERPROFILE $(if(Test-Path -LiteralPath (Join-Path $env:USERPROFILE 'Backup Center recovery keys')){'Backup Center recovery keys'}else{'DevDriveBackup recovery keys'}));DriveCheck=(Join-Path $app 'drive-check');Appearance=(Join-Path $app 'center\appearance.json');Logs=(Join-Path $app 'center')}  # local, not a synced Documents folder
 }
 $script:Paths
}
function Get-CenterPaths {if(-not $script:Paths){[void](Set-CenterPaths '')};$script:Paths}

function Get-CenterProfilesProblem([string]$Text,[ref]$Data) {
 # Why this text is not a settings file ('' = it is one). -Data receives what was read.
 $d=$null
 try{$d=$Text|ConvertFrom-Json}catch{return $_.Exception.Message}
 if($d -isnot [pscustomobject] -or -not $d.PSObject.Properties['Profiles'] -or $null -eq $d.Profiles){return 'it has no list of profiles'}
 if(@($d.Profiles|Where-Object {$q=$_;$q -isnot [pscustomobject] -or @('Id','Name','DestinationVolumeId','Sources'|Where-Object {-not $q.PSObject.Properties[$_]}).Count}).Count){return 'a profile in it is incomplete'}
 # Checked profile by profile and without a pipeline: a profile with no sources (nothing, or an empty
 # list) is fine, but an empty place inside the list is damage, and a pipeline would not tell the two apart.
 foreach($profile in @($d.Profiles)){
  if($null -eq $profile.Sources){continue}
  foreach($q in $profile.Sources){if($null -eq $q -or $q -isnot [pscustomobject] -or @('Id','Path','ConfigPath'|Where-Object {-not $q.PSObject.Properties[$_]}).Count){return 'a folder listed in it is incomplete'}}
 }
 if($Data){$Data.Value=$d}
 ''
}
# --- The copy of the last good settings ------------------------------------------------------
# Beside the settings file, under a name the same ignore rule covers (*.local.json). It is only ever
# written from a settings file that was read back from disk and is valid, so a damaged file can be
# replaced by it. Nothing here deletes or overwrites a damaged file.
function Get-CenterLastGoodPath {$p=(Get-CenterPaths).Profiles;if($p -match '\.local\.json$'){$p -replace '\.local\.json$','.lastgood.local.json'}else{$p+'.lastgood'}}
function Read-CenterFileText([string]$Path,[ref]$Bytes) {
 # The text of a file as the settings are read (a byte order mark is not part of it), and its exact bytes.
 $b=[IO.File]::ReadAllBytes($Path);if($Bytes){$Bytes.Value=$b}
 $r=[IO.StreamReader]::new([IO.MemoryStream]::new($b),[Text.UTF8Encoding]::new($false),$true);try{$r.ReadToEnd()}finally{$r.Dispose()}
}
function Save-CenterLastGood {
 # Copies the settings file as it is on disk right now to the last good copy, when it is valid.
 # Returns whether a good copy of exactly these settings exists afterwards. Never an error: a copy
 # that could not be written must not fail the save that was just made.
 try{
  $p=(Get-CenterPaths).Profiles;$g=Get-CenterLastGoodPath
  if(-not(Test-Path -LiteralPath $p -PathType Leaf)){return $false}
  $bytes=$null;if(Get-CenterProfilesProblem (Read-CenterFileText $p ([ref]$bytes))){return $false}
  if((Test-Path -LiteralPath $g -PathType Leaf) -and [Linq.Enumerable]::SequenceEqual([byte[]][IO.File]::ReadAllBytes($g),[byte[]]$bytes)){return $true}
  $tmp=$g+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
  try{
   [IO.File]::WriteAllBytes($tmp,$bytes)
   # Its date is the date of the settings it holds, which is what is shown when it is offered.
   [IO.File]::SetLastWriteTime($tmp,[IO.File]::GetLastWriteTime($p))
   if([IO.File]::Exists($g)){[IO.File]::Replace($tmp,$g,[System.Management.Automation.Language.NullString]::Value)}else{[IO.File]::Move($tmp,$g)}
  }finally{if([IO.File]::Exists($tmp)){try{[IO.File]::Delete($tmp)}catch{}}}
  $true
 }catch{$false}
}
function Get-CenterSettingsRecovery {
 # What can be done about the settings file: Damaged (and Why), whether the last good copy can be put
 # back (CanRestore, its date and what it holds), and the Message to show. It changes nothing.
 $p=(Get-CenterPaths).Profiles;$g=Get-CenterLastGoodPath
 $r=[pscustomobject]@{Path=$p;Damaged=$false;Why='';LastGood=$g;CanRestore=$false;LastGoodWhen=$null;LastGoodProfiles=0;LastGoodFolders=0;Message=''}
 if(-not(Test-Path -LiteralPath $p -PathType Leaf)){return $r}
 $r.Why=try{Get-CenterProfilesProblem (Read-CenterFileText $p)}catch{$_.Exception.Message}
 if(-not $r.Why){return $r}
 $r.Damaged=$true
 $head="DevDriveBackup cannot open, because its settings file cannot be read.`n`nThe settings file $p is damaged ($($r.Why)).`n`nYour backups on the drives, the settings of each folder and the keys are not affected, and this file was not changed."
 $byHand="put back an earlier copy of the file yourself. Or move the file somewhere else and start DevDriveBackup again: it opens without profiles, and when you add the drive and its folders again, the earlier settings of each folder are picked up."
 if(-not(Test-Path -LiteralPath $g -PathType Leaf)){$r.Message="$head`n`nThere is no earlier good copy of the settings to put back.`n`nWhat you can do: $byHand";return $r}
 $old=$null;$bad=try{Get-CenterProfilesProblem (Read-CenterFileText $g) ([ref]$old)}catch{$_.Exception.Message}
 if($bad){$r.Message="$head`n`nThe copy of the last good settings ($g) cannot be read either, so it is not offered.`n`nWhat you can do: $byHand";return $r}
 $r.CanRestore=$true;$r.LastGoodWhen=[IO.File]::GetLastWriteTime($g);$r.LastGoodProfiles=@($old.Profiles).Count;$r.LastGoodFolders=@($old.Profiles|ForEach-Object {$_.Sources}|Where-Object {$_}).Count
 # Only the last part is a format: the path and the reason above may hold braces of their own.
 $r.Message="$head`n`n"+("What you can do: restore the last good copy of the settings, from {0:d MMM yyyy, HH:mm} ({1} and {2}). Settings changed after that time are not in it. The damaged file is kept beside it under a new name; nothing is deleted.") -f $r.LastGoodWhen,$(if($r.LastGoodProfiles -eq 1){'1 backup drive'}else{"$($r.LastGoodProfiles) backup drives"}),$(if($r.LastGoodFolders -eq 1){'1 folder'}else{"$($r.LastGoodFolders) folders"})
 $r
}
function Restore-CenterLastGood {
 # Puts the last good copy in the place of the settings file. The file that is there now is renamed
 # aside with the time in its name and never deleted or written over. The new file is made ready and
 # checked first, so the settings are never left missing: if putting it in place fails, the old file
 # goes back where it was.
 $p=(Get-CenterPaths).Profiles;$g=Get-CenterLastGoodPath
 if(-not(Test-Path -LiteralPath $g -PathType Leaf)){throw 'There is no good copy of the settings to restore.'}
 $bytes=$null;$bad=try{Get-CenterProfilesProblem (Read-CenterFileText $g ([ref]$bytes))}catch{$_.Exception.Message}
 if($bad){throw "The good copy of the settings ($g) cannot be read ($bad). Nothing was changed."}
 $when=[IO.File]::GetLastWriteTime($g);$dir=[IO.Path]::GetDirectoryName($p)
 $tmp=$p+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
 try{
  [IO.File]::WriteAllBytes($tmp,$bytes)
  if(Get-CenterProfilesProblem (Read-CenterFileText $tmp)){throw 'The copy could not be written correctly. Nothing was changed.'}
  $kept=$null
  if(Test-Path -LiteralPath $p -PathType Leaf){
   $base=[IO.Path]::GetFileName($p) -replace '\.local\.json$','';$tail=if($p -match '\.local\.json$'){'.local.json'}else{''};$stamp=Get-Date -Format 'yyyyMMdd-HHmmss'
   for($i=1;;$i++){$kept=Join-Path $dir ($base+'.damaged-'+$stamp+$(if($i -gt 1){"-$i"})+$tail);if(-not(Test-Path -LiteralPath $kept)){break}}
   [IO.File]::Move($p,$kept)   # fails rather than overwrites when the name is taken after all
  }
  try{[IO.File]::Move($tmp,$p)}catch{if($kept -and -not [IO.File]::Exists($p)){[IO.File]::Move($kept,$p)};throw}
 }finally{if([IO.File]::Exists($tmp)){try{[IO.File]::Delete($tmp)}catch{}}}
 [pscustomobject]@{KeptAs=$kept;RestoredFrom=$g;When=$when}
}

function Read-CenterProfiles {
 $p=(Get-CenterPaths).Profiles
 if(-not(Test-Path -LiteralPath $p)){return [pscustomobject]@{Version=1;Profiles=@()}}
 # A file that is empty, cut off or not shaped like the settings is reported by name and left exactly as
 # it is: guessing (for example "no profiles") would let the next save write over what is left of it.
 $data=$null
 $why=try{Get-CenterProfilesProblem (Get-Content -LiteralPath $p -Raw) ([ref]$data)}catch{$_.Exception.Message}
 if($why){throw "The settings file $p is damaged and cannot be read ($why). Nothing was changed."}
 $data.Profiles=@($data.Profiles|ForEach-Object {$_.Sources=@($_.Sources);$_})
 # A source's settings file is stored by full path. When the tool folder is moved or renamed, that path
 # goes stale; a file of the same name in the jobs folder or beside the profiles file is the same file, moved.
 $moved=$false
 foreach($s in @($data.Profiles|ForEach-Object {$_.Sources})){
  $old=[string]$s.ConfigPath
  if(-not $old -or (Test-Path -LiteralPath $old)){continue}
  $leaf=Split-Path $old -Leaf
  foreach($dir in @((Get-CenterPaths).Jobs,[IO.Path]::GetDirectoryName($p))){
   $candidate=Join-Path $dir $leaf
   if(-not(Test-Path -LiteralPath $candidate -PathType Leaf)){continue}
   # Same name is not proof: the file must describe this very source (its folder and its plain copy folder).
   $same=try{$job=Get-Content -LiteralPath $candidate -Raw|ConvertFrom-Json;[string]$job.Source -ieq [string]$s.Path -and [string]$job.MirrorFolder -ieq [string]$s.MirrorFolder}catch{$false}
   if($same){$s.ConfigPath=$candidate;$moved=$true;break}
  }
 }
 if($moved){Save-CenterProfiles $data}
 $data
}
function Save-CenterProfiles($Data) {
 $p=(Get-CenterPaths).Profiles
 New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($p)) -Force|Out-Null
 [void](Write-BackupStatus $Data $p)
 # What was just saved, read back from disk and found valid, becomes the copy to fall back on.
 [void](Save-CenterLastGood)
}
function Get-CenterProfile($Data,[string]$Id) {
 $hit=@($Data.Profiles|Where-Object {$_.Id -eq $Id})
 if(-not $hit.Count){throw "Profile not found: $Id"}
 $hit[0]
}

function Get-SafeName([string]$Text) {
 $s=($Text -replace '[^A-Za-z0-9._-]+','-').Trim('-','.')
 if(-not $s){$s='Source'}
 if($s -notmatch '^[A-Za-z0-9]'){$s='S'+$s}
 if($s.Length -gt 60){$s=$s.Substring(0,60).TrimEnd('-','.')}
 $s
}
function New-ShortId {[guid]::NewGuid().ToString('N').Substring(0,8)}

$script:VolumeCache=$null;$script:VolumeQueries=0
function Get-CenterDriveKey {
 # The lettered drives as Windows shows them right now, read in a few milliseconds: letter, size, label
 # and file system of each. It changes when a drive is plugged in, unplugged or swapped.
 try{@([IO.DriveInfo]::GetDrives()|ForEach-Object {try{if($_.IsReady){$_.Name+'|'+$_.TotalSize+'|'+$_.VolumeLabel+'|'+$_.DriveFormat}else{$_.Name+'|not ready'}}catch{$_.Name+'|?'}}) -join "`n"}catch{[guid]::NewGuid().ToString()}
}
function Get-CenterVolumes([switch]$Fresh) {
 # Listing the volumes takes a second or more, on the window's own thread. For showing (the refresh of
 # the window, the status line of a running backup) the list is reused while the same drives are
 # plugged in, for at most a minute. -Fresh, used by everything that starts work on a drive, always
 # lists again: the identity of the drive must be the one that is plugged in at that moment.
 $key=if($Fresh){''}else{Get-CenterDriveKey}
 if($Fresh -or -not $script:VolumeCache -or $script:VolumeCache.Key -ne $key -or ((Get-Date)-$script:VolumeCache.At).TotalSeconds -gt 60){
  $script:VolumeQueries++
  $list=@(Get-Volume -ErrorAction SilentlyContinue)
  $script:VolumeCache=[pscustomobject]@{At=Get-Date;Key=(Get-CenterDriveKey);List=$list}
 }
 $script:VolumeCache.List
}
function Get-CenterVolumeQueryCount {$script:VolumeQueries}   # for tests: how often the volumes were listed
function Get-CenterFreeBytes([string]$Letter) {
 # Free space of a lettered drive without listing the volumes (asked every few seconds during a backup).
 try{$d=[IO.DriveInfo]::new($Letter.Substring(0,1)+':');if($d.IsReady){[long]$d.AvailableFreeSpace}else{$null}}catch{$null}
}
function Get-CenterDrive([string]$VolumeId,[switch]$Fresh) {
 # The drive of a profile, or Connected=$false when it is not plugged in.
 $v=@(Get-CenterVolumes -Fresh:$Fresh|Where-Object {$_.UniqueId -eq $VolumeId -and $_.DriveLetter})
 if($v.Count -ne 1){return [pscustomobject]@{Connected=$false;Letter=$null;Label=$null;FileSystem=$null;SizeGB=$null;FreeGB=$null}}
 # Free space changes while the list is reused, so it is read now.
 $free=Get-CenterFreeBytes ([string]$v[0].DriveLetter);if($null -eq $free){$free=$v[0].SizeRemaining}
 [pscustomobject]@{Connected=$true;Letter=[string]$v[0].DriveLetter;Label=$v[0].FileSystemLabel;FileSystem=$v[0].FileSystem;SizeGB=[math]::Round($v[0].Size/1GB,1);FreeGB=[math]::Round($free/1GB,1)}
}
function Get-CenterBusyReason {
 # One job per drive: a backup, a drive check and a speed test of the same drive would compete for it
 # (and a speed test would measure the backup). Returns why -For cannot start on this profile's drive
 # now, or '' when it can. The window uses it for the buttons and again at the moment a job starts,
 # because a backup that waited for AI sessions starts by itself, long after the button was pressed.
 param([string]$ProfileId,[ValidateSet('Backup','Check','Speed')][string]$For,[string]$RunProfileId,[string]$WaitProfileId,[string]$CheckProfileId,[string]$SpeedProfileId)
 if(-not $ProfileId){return ''}
 if($For -ne 'Backup' -and $RunProfileId -eq $ProfileId){return 'A backup of this drive is running. Wait until it has finished.'}
 if($For -ne 'Backup' -and $WaitProfileId -eq $ProfileId){return 'A backup of this drive is waiting for AI sessions to finish and starts by itself. Stop the wait first, or wait for the backup.'}
 if($For -ne 'Check' -and $CheckProfileId -eq $ProfileId){return 'A drive check of this drive is running. Wait until it has finished, or stop it on the Drive check page.'}
 if($For -ne 'Speed' -and $SpeedProfileId -eq $ProfileId){return 'A speed test of this drive is running. It takes about half a minute; try again then.'}
 ''
}
function Get-CenterCandidateDrives {
 # Volumes that can hold a backup: lettered, with a file system, not the system drive.
 $sys=$env:SystemDrive.Substring(0,1)
 foreach($v in @(Get-Volume|Where-Object {$_.DriveLetter -and $_.FileSystem -and $_.Size -gt 0 -and [string]$_.DriveLetter -ne $sys}|Sort-Object DriveLetter)){
  $disk=$null;try{$disk=Get-Partition -DriveLetter $v.DriveLetter|Get-Disk}catch{}
  [pscustomobject]@{Letter=[string]$v.DriveLetter;VolumeId=$v.UniqueId;Label=$v.FileSystemLabel;FileSystem=$v.FileSystem;SizeGB=[math]::Round($v.Size/1GB,1);FreeGB=[math]::Round($v.SizeRemaining/1GB,1);Model=if($disk){[string]$disk.FriendlyName}else{''};BusType=if($disk){[string]$disk.BusType}else{''}}
 }
}

function New-CenterProfile($Data,[string]$Name,[string]$VolumeId,[string]$Model='',[double]$SizeGB=0) {
 if(-not $Name.Trim()){throw 'Give the profile a name'}
 if(@($Data.Profiles|Where-Object {$_.DestinationVolumeId -eq $VolumeId}).Count){throw 'This drive already has a profile'}
 $p=[pscustomobject]@{Id=(New-ShortId);Name=$Name.Trim();DestinationVolumeId=$VolumeId;DriveModel=$Model;DriveSizeGB=$SizeGB;ReminderDays=7;Load='Balanced';CustomLoad=$null;Created=(Get-Date).ToString('o');Sources=@()}
 $Data.Profiles=@($Data.Profiles)+$p
 $p
}
function Remove-CenterProfile($Data,[string]$Id) {
 # Forgets the profile only. Job files, keys and everything on the backup drive stay.
 [void](Get-CenterProfile $Data $Id)
 $Data.Profiles=@($Data.Profiles|Where-Object {$_.Id -ne $Id})
}

function Test-PathOverlap([string]$A,[string]$B) {
 $a=$A.TrimEnd('\')+'\';$b=$B.TrimEnd('\')+'\'
 $a.StartsWith($b,[StringComparison]::OrdinalIgnoreCase) -or $b.StartsWith($a,[StringComparison]::OrdinalIgnoreCase)
}

function Add-CenterSource {
 # -Restored ([ref]): set to the earlier settings (copy folder, versions folder, mode of unlisted folders)
 # when this folder was a source of this drive before and its kept settings were taken up again, so the
 # caller can say that -Label and -DefaultMode were not applied. Left alone otherwise.
 param($Data,[string]$ProfileId,[string]$Path,[string]$Label,[ValidateSet('Mirror','Versioned','Both','Skip')][string]$DefaultMode='Mirror',[string]$ExistingConfigPath,[string]$MirrorFolder,[ref]$Restored)
 $profile=Get-CenterProfile $Data $ProfileId
 $root=[IO.Path]::GetFullPath($Path).TrimEnd('\')+'\'
 if($root -notmatch '^[A-Za-z]:\\'){throw "Choose a folder on a drive of this computer (one with a drive letter). A network folder such as $($root.TrimEnd('\')) cannot be backed up from here."}
 if(-not(Test-Path -LiteralPath $root -PathType Container)){throw "Folder not found: $root"}
 if((Get-Item -LiteralPath $root -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Choose the real folder, not a shortcut (junction or link) to it'}
 $volume=try{Get-Volume -DriveLetter $root.Substring(0,1) -ErrorAction Stop}catch{$null}
 if(-not $volume){throw "Drive $($root.Substring(0,1)): is not a disk of this computer that Windows can identify (a network or substituted drive letter?). Choose the folder on its real drive."}
 if($volume.UniqueId -eq $profile.DestinationVolumeId){throw 'This folder is on the backup drive itself'}
 foreach($s in $profile.Sources){if(Test-PathOverlap $s.Path $root){throw "Overlaps with the existing source '$($s.Label)' ($($s.Path))"}}
 if(-not $Label.Trim()){$Label=if($root.Length -eq 3){'Drive '+$root.Substring(0,1)}else{Split-Path -Leaf $root.TrimEnd('\')}}
 $safe=Get-SafeName $Label
 # Names that are not Latin letters all become "Source"; keep them apart.
 if($safe -eq 'Source'){$safe='Source-'+(New-ShortId).Substring(0,4)}
 $drive=Get-CenterDrive $profile.DestinationVolumeId -Fresh
 # The folder names this drive's job files record, also those of sources removed earlier: their plain
 # copy and versions stay on the drive, so a new source must never get one, even while it is unplugged.
 $jobFiles=@(Get-ChildItem -LiteralPath (Get-CenterPaths).Jobs -Filter '*.local.json' -File -ErrorAction SilentlyContinue|ForEach-Object {
  try{$j=Get-Content -LiteralPath $_.FullName -Raw|ConvertFrom-Json}catch{return}
  if($j.PSObject.Properties['DestinationVolumeId'] -and $j.DestinationVolumeId -eq $profile.DestinationVolumeId){[pscustomobject]@{Path=$_.FullName;Job=$j}}
 })
 $jobNames=@($jobFiles|ForEach-Object {
  if($_.Job.PSObject.Properties['MirrorFolder'] -and $_.Job.MirrorFolder){[string]$_.Job.MirrorFolder}
  if($_.Job.PSObject.Properties['RepositoryFolder'] -and $_.Job.RepositoryFolder){[string]$_.Job.RepositoryFolder;if([string]$_.Job.RepositoryFolder -match '^(.+)-Versions$'){$Matches[1]+'-Mirror'}}
 })
 # A name is taken when another source of this drive has it, a job file of this drive records it, or
 # its plain copy or versions folder is already on the drive (an earlier source's copy is never shared).
 # The label is compared by its safe name, so a second folder with the same label gets a new name
 # instead of looping forever.
 $taken={param($n)@($profile.Sources|Where-Object {$_.MirrorFolder -ieq $n+'-Mirror' -or (Get-SafeName $_.Label) -ieq $n}).Count -or ($jobNames -icontains ($n+'-Mirror')) -or ($jobNames -icontains ($n+'-Versions')) -or ($drive.Connected -and ((Test-Path -LiteralPath ($drive.Letter+':\'+$n+'-Versions')) -or (Test-Path -LiteralPath ($drive.Letter+':\'+$n+'-Mirror'))))}
 $used={param($m)@($profile.Sources|Where-Object {$_.MirrorFolder -ieq $m}).Count -gt 0}
 if($MirrorFolder -and (& $used $MirrorFolder)){throw "The plain copy folder $MirrorFolder is already used by another source of this drive"}
 $id=New-ShortId
 if(-not $ExistingConfigPath){
  # A source removed earlier keeps its job file (with its keys); adding the same folder again to
  # the same drive picks it up instead of creating a second repository next to the first. A job whose
  # versions folder a current source of this drive uses now is not picked up: two sources never share
  # one repository, so the folder then starts with names of its own.
  $current=@($profile.Sources|Where-Object {$_.PSObject.Properties['ConfigPath'] -and $_.ConfigPath}|ForEach-Object {[IO.Path]::GetFullPath([string]$_.ConfigPath)})
  # Read from each current source's own job file, wherever it is kept, not only those in the jobs folder.
  $inUse=@($current|ForEach-Object {try{$j=Get-Content -LiteralPath $_ -Raw|ConvertFrom-Json;if($j.PSObject.Properties['RepositoryFolder'] -and $j.RepositoryFolder){[string]$j.RepositoryFolder}}catch{}})
  $old=@($jobFiles|Where-Object {
   try{(([IO.Path]::GetFullPath([string]$_.Job.Source).TrimEnd('\')+'\') -ieq $root)}catch{$false}
  }|Where-Object {$current -inotcontains $_.Path -and -not ($_.Job.PSObject.Properties['RepositoryFolder'] -and $inUse -icontains [string]$_.Job.RepositoryFolder)}|Sort-Object {(Get-Item -LiteralPath $_.Path).LastWriteTime} -Descending)
  if($old.Count){
   $ExistingConfigPath=$old[0].Path
   if($Restored){$j=$old[0].Job;$Restored.Value=[pscustomobject]@{ConfigPath=$ExistingConfigPath;MirrorFolder=$(if($j.PSObject.Properties['MirrorFolder']){[string]$j.MirrorFolder}else{''});RepositoryFolder=$(if($j.PSObject.Properties['RepositoryFolder']){[string]$j.RepositoryFolder}else{''});DefaultMode=$(if($j.PSObject.Properties['DefaultMode']){[string]$j.DefaultMode}else{''})}}
  }
 }
 if(-not $ExistingConfigPath){while(& $taken $safe){$safe=(Get-SafeName $Label)+'-'+(New-ShortId).Substring(0,4)}}
 if($ExistingConfigPath){
  # Adopt an existing job file (keeps its keys and repository).
  $config=[IO.Path]::GetFullPath($ExistingConfigPath)
  $c=Get-Content -LiteralPath $config -Raw|ConvertFrom-Json
  if(([IO.Path]::GetFullPath($c.Source).TrimEnd('\')+'\') -ine $root){throw 'That job file belongs to another source folder'}
  # It keeps its own plain copy folder too (recorded in the job, or named like its repository) unless
  # another source of this drive uses that name now; then it gets a name no folder on the drive has.
  if(-not $MirrorFolder){
   $MirrorFolder=if($c.PSObject.Properties['MirrorFolder'] -and $c.MirrorFolder){[string]$c.MirrorFolder}elseif($c.PSObject.Properties['RepositoryFolder'] -and [string]$c.RepositoryFolder -match '^(.+)-Versions$'){$Matches[1]+'-Mirror'}else{''}
   if(-not $MirrorFolder -or (& $used $MirrorFolder)){while(& $taken $safe){$safe=(Get-SafeName $Label)+'-'+(New-ShortId).Substring(0,4)};$MirrorFolder=$safe+'-Mirror'}
  }
 }else{
  if(-not $MirrorFolder){$MirrorFolder=$safe+'-Mirror'}
  $jobs=(Get-CenterPaths).Jobs;New-Item -ItemType Directory -Path $jobs -Force|Out-Null
  $config=Join-Path $jobs ($profile.Id+'-'+$id+'.local.json')
  $keyId=[guid]::NewGuid().ToString('N')
  $choices=@(Get-ChildItem -LiteralPath $root -Directory -Force -ErrorAction SilentlyContinue|Where-Object {$_.Name -notin @('$RECYCLE.BIN','System Volume Information') -and -not($_.Attributes -band [IO.FileAttributes]::ReparsePoint)}|Sort-Object Name|ForEach-Object {[pscustomobject]@{Path=$_.Name;Mode=$DefaultMode;Reason=''}})
  $c=[ordered]@{Source=$root;SourceVolumeId=$volume.UniqueId;DestinationVolumeId=$profile.DestinationVolumeId
   RepositoryFolder=($safe+'-Versions');PasswordDpapiPath=(Join-Path (Get-CenterPaths).Keys ($keyId+'.dpapi'))
   RecoveryKeyPath=(Join-Path (Get-CenterPaths).Documents ('Backup-'+$safe+'-'+$keyId+'-recovery-key.txt'))
   DefaultMode=$DefaultMode;Choices=$choices;Include=@();Exclude=$script:CacheNames;RecommendedExclude=$script:CacheNames;MirrorFolder=$MirrorFolder}
  [void](Write-BackupStatus ([pscustomobject]$c) $config)
 }
 $source=[pscustomobject]@{Id=$id;Label=$Label.Trim();Path=$root;ConfigPath=$config;MirrorFolder=$MirrorFolder;Created=(Get-Date).ToString('o')}
 $profile.Sources=@($profile.Sources)+$source
 $source
}
function Remove-CenterSource($Data,[string]$ProfileId,[string]$SourceId) {
 # Forgets the source only; its job file (with key locations) and backups are kept.
 $profile=Get-CenterProfile $Data $ProfileId
 $profile.Sources=@($profile.Sources|Where-Object {$_.Id -ne $SourceId})
}

function Read-CenterJob([string]$ConfigPath) {Get-Content -LiteralPath $ConfigPath -Raw|ConvertFrom-Json}
function Save-CenterJob($Job,[string]$ConfigPath,[scriptblock]$Update,[int]$WaitMilliseconds=3000) {
 # Writes under the job's run lock (as Backup-Worker.ps1 and Set-BackupDestination.ps1 take it) after
 # reading the file again, so a password change running elsewhere keeps its new recovery-key location.
 # With -Update the change is made to that fresh copy instead of writing $Job.
 # -WaitMilliseconds: how long to try for the lock. A backup or an open restore window holds it for
 # minutes, so waiting longer does not help; the window passes a short wait to stay responsive.
 $key={param($j)if($j -and $j.PSObject.Properties['PasswordDpapiPath'] -and $j.PasswordDpapiPath){[IO.Path]::GetFullPath([string]$j.PasswordDpapiPath)}else{''}}
 $keyPath=if(Test-Path -LiteralPath $ConfigPath){& $key (Read-CenterJob $ConfigPath)}else{& $key $Job}
 $lock=$null
 if($keyPath){
  New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($keyPath)) -Force|Out-Null
  for($i=0;-not $lock;$i++){try{$lock=[IO.File]::Open($keyPath+'.run.lock',[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)}catch [IO.IOException]{if($i*100 -ge $WaitMilliseconds){throw 'This source is busy: a backup, check, restore or password change is using it. Try again when it has finished.'};Start-Sleep -Milliseconds 100}}
 }
 try{
  $fresh=if(Test-Path -LiteralPath $ConfigPath){Read-CenterJob $ConfigPath}else{$null}
  if($fresh -and (& $key $fresh) -ine $keyPath){throw 'The password settings of this source changed while saving. Try again.'}
  if($Update){if(-not $fresh){throw "Job file not found: $ConfigPath"};[void](& $Update $fresh);$Job=$fresh}
  elseif($fresh){
   if((& $key $Job) -ine $keyPath){throw 'The password settings of this source changed elsewhere. Close and reopen DevDriveBackup.'}
   if($fresh.PSObject.Properties['RecoveryKeyPath']){$Job|Add-Member -NotePropertyName RecoveryKeyPath -NotePropertyValue $fresh.RecoveryKeyPath -Force}
  }
  [void](Write-BackupStatus $Job $ConfigPath)
 }finally{if($lock){$lock.Dispose()}}
}

function Get-CenterSourceKinds($Source) {
 # Which tools this source uses, from its per-folder modes.
 $sel=Get-BackupSelection (Read-CenterJob $Source.ConfigPath)
 [pscustomobject]@{
  Mirror=$sel.HasModes -and @(Get-BackupRegions $sel 'Mirror').Count -gt 0
  Versioned=@(Get-BackupRegions $sel 'Versioned').Count -gt 0
 }
}

function Sync-CenterJob($Profile,$Source,$Load=(Get-CenterLoad $Profile),[int]$WaitMilliseconds=3000) {
 # Keeps a job file pointed at its profile's drive and the chosen load, and records its plain copy
 # folder (so adding the folder again later finds the same copy).
 $light=$Load.Name -eq 'Light'
 $want=[ordered]@{DestinationVolumeId=$Profile.DestinationVolumeId;Profile=$Load.Name;CpuThreads=$Load.CpuThreads;MemoryMiB=$Load.MemoryMiB;ReadConcurrency=$Load.ReadConcurrency;Priority=$Load.Priority
  RateMBps=0;PackMiB=$(if($light){16}else{32});BackendConnections=$(if($Load.Name -in @('Light','Balanced')){2}else{4})}
 if($Source.PSObject.Properties['MirrorFolder'] -and $Source.MirrorFolder){$want.MirrorFolder=[string]$Source.MirrorFolder}
 $apply={param($job)$changed=$false
  foreach($k in $want.Keys){
   if(-not $job.PSObject.Properties[$k]){$job|Add-Member -NotePropertyName $k -NotePropertyValue $want[$k];$changed=$true}
   elseif($job.$k -ne $want[$k]){$job.$k=$want[$k];$changed=$true}
  }
  $changed}.GetNewClosure()
 # Checked first without the lock: most calls change nothing and must not wait for a running backup.
 # A change is made to a fresh copy under the job's lock.
 if(& $apply (Read-CenterJob $Source.ConfigPath)){Save-CenterJob $null $Source.ConfigPath -Update $apply -WaitMilliseconds $WaitMilliseconds}
}

# --- History and freshness ----------------------------------------------------------------
function Add-CenterHistory($Entry) {
 $p=(Get-CenterPaths).History
 New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($p)) -Force|Out-Null
 [IO.File]::AppendAllText($p,(($Entry|ConvertTo-Json -Depth 6 -Compress)+"`n"),[Text.UTF8Encoding]::new($false))
}
function Get-CenterHistory {
 $p=(Get-CenterPaths).History
 # Callers wrap the result in @(): with no history this returns nothing, which @() makes an
 # empty list (a returned empty array would arrive as $null).
 if(-not(Test-Path -LiteralPath $p)){return}
 # Keep only well-formed entries; a damaged line must not break the window.
 # A line whose finish time cannot be read is skipped as well: every list and age is ordered by it.
 # The time is handed on as a local time, whatever form it was written in.
 Get-Content -LiteralPath $p -Encoding utf8|Where-Object {$_.Trim()}|ForEach-Object {try{$_|ConvertFrom-Json}catch{}}|
  Where-Object {$_ -is [pscustomobject] -and $_.PSObject.Properties['SourceId'] -and $_.PSObject.Properties['Kind'] -and $_.PSObject.Properties['Finished'] -and $_.PSObject.Properties['Success']}|
  ForEach-Object {$t=ConvertTo-CenterTime $_.Finished;if($t){$_.Finished=$t;$_}}
}
function ConvertTo-CenterTime($Value) {
 # A time from a history or result file as a local time, or nothing when it cannot be read. Reading
 # JSON already turns "2026-01-02T10:00:00+02:00" into a local time, but leaves "...Z" in UTC and a
 # damaged value as text; used unchanged, a UTC time is off by the time zone and text stops the window.
 if($null -eq $Value){return $null}
 $t=$null
 if($Value -is [datetime]){$t=$Value}
 elseif($Value -is [DateTimeOffset]){return $Value.LocalDateTime}
 else{
  $o=[DateTimeOffset]::MinValue;$s=([string]$Value).Trim()
  if(-not $s -or -not [DateTimeOffset]::TryParse($s,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::AssumeLocal,[ref]$o)){return $null}
  return $o.LocalDateTime
 }
 if($t.Kind -eq [DateTimeKind]::Utc){$t.ToLocalTime()}else{$t}
}
function Get-CenterElapsed($When,[datetime]$Now) {
 # Time passed since $When, or nothing when it cannot be read. Both ends are compared as moments (UTC),
 # so a clock change for summer time in between does not add or lose an hour.
 $t=ConvertTo-CenterTime $When;if(-not $t){return $null}
 $Now.ToUniversalTime()-$t.ToUniversalTime()
}
function Get-LastSuccess($History,[string]$SourceId,[string]$Kind) {
 $hit=@(@($History)|Where-Object {$_ -and $_.SourceId -eq $SourceId -and $_.Kind -eq $Kind -and $_.Success -eq $true}|ForEach-Object {ConvertTo-CenterTime $_.Finished}|Where-Object {$_}|Sort-Object {$_.ToUniversalTime()} -Descending)
 if($hit.Count){$hit[0]}else{$null}
}
function Get-FreshnessState($When,[int]$ReminderDays,[datetime]$Now) {
 $age=Get-CenterElapsed $When $Now
 if($null -eq $age){return 'Never'}
 if($age.TotalHours -lt 24){'Fresh'}elseif($age.TotalDays -lt $ReminderDays){'OK'}else{'Stale'}
}
function Format-CenterAge($When,[datetime]$Now=(Get-Date)) {
 if(-not $When){return 'never'}
 $age=Get-CenterElapsed $When $Now
 if($null -eq $age){return 'unknown'}
 if($age.TotalMinutes -lt 2){'just now'}
 elseif($age.TotalHours -lt 1){'{0} minutes ago' -f [int][math]::Floor($age.TotalMinutes)}
 elseif($age.TotalHours -lt 48){$h=[int][math]::Floor($age.TotalHours);if($h -eq 1){'1 hour ago'}else{"$h hours ago"}}
 else{'{0} days ago' -f [int][math]::Floor($age.TotalDays)}
}
function Format-CenterElapsed([timespan]$Span) {
 # "1 min 40 s" for a running or finished step. Whole minutes are rounded down: rounding to the nearest
 # showed 100 seconds as "2 min 40 s".
 '{0} min {1} s' -f [int][math]::Floor($Span.TotalMinutes),$Span.Seconds
}
function Format-CenterRunDuration($Entry) {
 # History entries carry exact Seconds; older ones only Minutes, rounded to a tenth.
 if($Entry.PSObject.Properties['Seconds'] -and $null -ne $Entry.Seconds){$s=[double]$Entry.Seconds;return $(if($s -lt 60){'{0} s' -f [int][math]::Floor($s)}else{Format-CenterElapsed ([timespan]::FromSeconds($s))})}
 if($Entry.PSObject.Properties['Minutes'] -and $null -ne $Entry.Minutes){return '{0:N1} min' -f [double]$Entry.Minutes}
 ''
}
function Get-CenterRunSpeed($Entry) {
 # Average speed of a finished run in MB/s (millions of bytes, as drives are sold and as the speed test
 # reports), or '' when it cannot be said honestly: a content check copies nothing; a run under 100 MB
 # is mostly waiting; an old entry knows its time only to a tenth of a minute, too rough below a minute;
 # and versions store only what is new after compression, so their speed is what was read
 # (ProcessedBytes), when the worker reported it.
 $get={param($n)if($Entry.PSObject.Properties[$n] -and $null -ne $Entry.$n){[double]$Entry.$n}else{$null}}
 if([string]$Entry.Kind -like '*Check'){return ''}
 $bytes=if([string]$Entry.Kind -eq 'Versioned'){& $get 'ProcessedBytes'}else{& $get 'CopiedBytes'}
 $seconds=& $get 'Seconds'
 if($null -eq $seconds){$m=& $get 'Minutes';if($null -ne $m -and $m -ge 1){$seconds=$m*60}}
 if($null -eq $bytes -or $bytes -lt 100e6 -or $null -eq $seconds -or $seconds -lt 1){return ''}
 '{0:N0} MB/s' -f ($bytes/1e6/$seconds)
}
function ConvertFrom-CenterToolJson([string]$Text,[string]$Require) {
 # The result a tool printed as JSON, found among its other output: warnings before it, error text
 # after it, lines that merely contain a brace. A result starts with "{" at the start of a line; of
 # several, the last one that reads as JSON (and has the property -Require names) is taken. When there
 # is none, the error is the tool's own words rather than a parsing error.
 $starts=@([regex]::Matches($Text,'(?m)^\{')|ForEach-Object {$_.Index});[array]::Reverse($starts)
 foreach($s in $starts){
  $ends=@($Text.Length)+@([regex]::Matches($Text.Substring($s),'(?m)^\}')|ForEach-Object {$s+$_.Index+1}|Sort-Object -Descending)
  $line=$Text.IndexOf("`n",$s);if($line -gt $s){$ends+=$line}
  foreach($e in $ends|Select-Object -Unique){
   $o=try{$Text.Substring($s,$e-$s)|ConvertFrom-Json -ErrorAction Stop}catch{$null}
   if($o -is [pscustomobject] -and (-not $Require -or $o.PSObject.Properties[$Require])){return $o}
  }
 }
 $said=($Text.Trim() -replace '\s+',' ');if($said.Length -gt 600){$said=$said.Substring(0,600)+'...'}
 throw $(if($said){$said}else{'The tool gave no result.'})
}
function Get-CenterFreshness($Profile,$History,[datetime]$Now=(Get-Date)) {
 # A source is as fresh as the older of its two kinds; a profile as fresh as its oldest source.
 $rows=foreach($s in $Profile.Sources){
  $kinds=try{Get-CenterSourceKinds $s}catch{[pscustomobject]@{Mirror=$false;Versioned=$false;Error=$_.Exception.Message}}
  $lm=if($kinds.Mirror){Get-LastSuccess $History $s.Id 'Mirror'}else{$null}
  $lv=if($kinds.Versioned){Get-LastSuccess $History $s.Id 'Versioned'}else{$null}
  $needed=@();if($kinds.Mirror){$needed+=,$lm};if($kinds.Versioned){$needed+=,$lv}
  $complete=if($needed.Count -eq 0 -or @($needed|Where-Object {$null -eq $_}).Count){$null}else{@($needed|Sort-Object {$_.ToUniversalTime()})[0]}
  $problem=if($kinds.PSObject.Properties['Error']){[string]$kinds.Error}else{$null}
  [pscustomobject]@{Source=$s;Mirror=$kinds.Mirror;Versioned=$kinds.Versioned;LastMirror=$lm;LastVersioned=$lv;LastComplete=$complete;Problem=$problem
   State=if($problem){'Error'}elseif($needed.Count -eq 0){'Nothing selected'}else{Get-FreshnessState $complete $Profile.ReminderDays $Now}}
 }
 $rows=@($rows)
 # A source whose settings cannot be read is not backed up, so it keeps the drive from looking fresh.
 $active=@($rows|Where-Object {$_.State -ne 'Nothing selected'})
 $profileComplete=if(-not $active.Count -or @($active|Where-Object {$null -eq $_.LastComplete}).Count){$null}else{@($active.LastComplete|Sort-Object {$_.ToUniversalTime()})[0]}
 $state=if(-not $active.Count){'Nothing selected'}elseif(@($active|Where-Object {$_.State -eq 'Error'}).Count){'Error'}else{Get-FreshnessState $profileComplete $Profile.ReminderDays $Now}
 [pscustomobject]@{Rows=$rows;LastComplete=$profileComplete;State=$state}
}

# --- The latest run failed; files a content check found different ------------------------------
function Get-CenterOpenCheck($Entries,[string]$Kind) {
 # The newest content check of one source and kind ('Mirror' or 'Versioned') when it failed and nothing
 # after it put that right, or nothing. $Entries: that source's history, oldest first. A check that was
 # stopped says nothing about the backup, so the one before it counts. Put right means: a later repair
 # that succeeded, or a later plain copy that compared every file (it records CheckedFiles) and succeeded.
 # An ordinary backup does not: it copies by size and time and would leave a file that only differs inside.
 $checks=@($Entries|Where-Object {$_.Kind -eq $Kind+'Check' -and -not ($_.PSObject.Properties['Stopped'] -and $_.Stopped)})
 if(-not $checks.Count -or $checks[-1].Success){return $null}
 $c=$checks[-1];$at=$c.Finished.ToUniversalTime()
 if($Kind -eq 'Mirror' -and @($Entries|Where-Object {$_.Success -and $_.Finished.ToUniversalTime() -gt $at -and ($_.Kind -eq 'MirrorRepair' -or ($_.Kind -eq 'Mirror' -and $_.PSObject.Properties['CheckedFiles'] -and $null -ne $_.CheckedFiles))}).Count){return $null}
 $c
}
function Get-CenterSourceRuns($History,[string]$SourceId) {
 # One source's runs, oldest first, each with its finish time as a time (entries handed in by a caller
 # may still carry it as text); the entries themselves are not changed.
 @(@($History)|Where-Object {$_ -and $_.SourceId -eq $SourceId}|ForEach-Object {$t=ConvertTo-CenterTime $_.Finished;if($t){$c=$_.PSObject.Copy();$c.Finished=$t;$c}}|Sort-Object {$_.Finished.ToUniversalTime()})
}
function Get-CenterEntryText($Entry,[string]$Name) {
 # A text field of a history entry, '' when the entry has none (older entries, and successes, carry fewer fields).
 if($Entry.PSObject.Properties[$Name] -and $null -ne $Entry.$Name){[string]$Entry.$Name}else{''}
}
function Get-CenterRepairState($History,[string]$SourceId) {
 # Whether "Repair differing files" has something to do for this source: its newest content check of
 # the plain copy found files that differ, and no later repair or comparing backup put them right.
 # The number is the entry's Differences; entries written before that field say it in their error text.
 $c=Get-CenterOpenCheck (Get-CenterSourceRuns $History $SourceId) 'Mirror'
 $n=0;$said=if($c){Get-CenterEntryText $c 'Error'}else{''}
 if($c){
  if($c.PSObject.Properties['Differences'] -and $null -ne $c.Differences){try{$n=[int]$c.Differences}catch{}}
  elseif($said -match '^(\d+) files differ'){$n=[int]$Matches[1]}
 }
 [pscustomobject]@{Needed=($n -gt 0);Differences=$n;When=$(if($c){$c.Finished});Details=$(if($c){$d=Get-CenterEntryText $c 'Details';if(-not $d -and $said -match ' in (.+)$'){$d=$Matches[1]};$d})}
}
function Get-CenterRunWarnings($Profile,$History,[datetime]$Now=(Get-Date)) {
 # What the overview warns about beside the age: for every source of this profile and each kind it
 # uses, the newest backup when it failed (Level Failed) or was stopped (Stopped); and, milder (Check),
 # a content check that failed and was not put right since. Age and colour are not changed by this:
 # they keep saying how old the last complete backup is. Runs of removed sources, of a kind a source no
 # longer uses, and repairs are not backups and are left out. Failed backups first, newest first.
 $short={param($t)$s=(([string]$t -split ';\s|(?<=[.!?])\s',2)[0]).Trim().TrimEnd('.');if($s.Length -gt 110){$s=$s.Substring(0,110).TrimEnd()+'...'};$s}
 $list=foreach($s in @($Profile.Sources)){
  $kinds=try{Get-CenterSourceKinds $s}catch{[pscustomobject]@{Mirror=$true;Versioned=$true}}
  $runs=Get-CenterSourceRuns $History $s.Id
  foreach($k in @(@('Mirror','plain copy'),@('Versioned','versions'))){
   if(-not $kinds.($k[0])){continue}
   $last=@($runs|Where-Object {$_.Kind -eq $k[0]})|Select-Object -Last 1
   if($last -and -not $last.Success){
    $stopped=[bool]($last.PSObject.Properties['Stopped'] -and $last.Stopped);$why=& $short (Get-CenterEntryText $last 'Error')
    [pscustomobject]@{Level=$(if($stopped){'Stopped'}else{'Failed'});SourceId=$s.Id;Label=$s.Label;Kind=$k[0];When=$last.Finished;Reason=$why
     Text=if($stopped){"The latest backup of $($s.Label) ($($k[1])) was stopped $(Format-CenterAge $last.Finished $Now), before it finished"}else{"The latest backup of $($s.Label) ($($k[1])) failed $(Format-CenterAge $last.Finished $Now)$(if($why){': '+$why})"}}
   }
   $c=Get-CenterOpenCheck $runs $k[0]
   if($c){$why=& $short (Get-CenterEntryText $c 'Error');[pscustomobject]@{Level='Check';SourceId=$s.Id;Label=$s.Label;Kind=$k[0];When=$c.Finished;Reason=$why;Text="The last content check of $($s.Label) ($($k[1])) found a problem $(Format-CenterAge $c.Finished $Now)$(if($why){': '+$why})"}}
  }
 }
 @($list|Sort-Object @{e={if($_.Level -eq 'Check'){1}else{0}}},@{e={$_.When.ToUniversalTime()};Descending=$true})
}
function Format-CenterRunWarnings($Warnings) {
 # One line for the overview (the first warning, how many more, where the details are), every warning
 # for the tooltip, and the Level of the worst one ('' = nothing to warn about).
 $w=@($Warnings|Where-Object {$_})
 if(-not $w.Count){return [pscustomobject]@{Level='';Text='';Full='';Count=0}}
 $where='Details: Recent runs on the Speed and load page.'
 [pscustomobject]@{Level=$w[0].Level;Count=$w.Count
  Text=$w[0].Text+$(if($w.Count -gt 1){" (and $($w.Count-1) more)"})+'. '+$where
  Full=(@($w|ForEach-Object {$_.Text+'.'})+$where) -join "`n"}
}
function Remove-CenterOldStepLogs([int]$Days=30,[datetime]$Now=(Get-Date)) {
 # The detailed output of each tool run (step-<date>-<time>-<id>.log, written by the window) is only
 # needed to look into a recent run, and one is written per step for ever. Those older than -Days are
 # deleted; only files with exactly that name, directly in the logs folder. The run history and the run
 # summaries are in other files and are never touched. Returns how many were deleted.
 $dir=(Get-CenterPaths).Logs;$n=0
 if(-not(Test-Path -LiteralPath $dir -PathType Container)){return 0}
 foreach($f in [IO.Directory]::EnumerateFiles($dir,'step-*.log',[IO.SearchOption]::TopDirectoryOnly)){
  if([IO.Path]::GetFileName($f) -notmatch '^step-\d{8}-\d{6}-[0-9a-f]{6}\.log$'){continue}
  try{if([IO.File]::GetLastWriteTime($f) -lt $Now.AddDays(-$Days)){[IO.File]::Delete($f);$n++}}catch{}
 }
 $n
}
function Get-CenterLoadWarning([int]$MemoryMiB,$Hardware=(Get-CenterHardware)) {
 # A memory limit above half of the memory this computer has gets a warning ('' = fine). Half of what
 # is installed, not what is free at the moment: that changes from minute to minute and the limit is
 # used at the next backup. The number is not lowered and saving is not blocked; it is the user's call.
 $all=[double]$Hardware.MemoryGB*1024
 if($all -le 0 -or $MemoryMiB -le $all/2){return ''}
 $safe=[math]::Max(512,[math]::Floor($all/2/256)*256)
 # One line beside the fields, so it is short.
 '{0:N0} MB is more than half of this computer''s {1:0.#} GB of memory and may slow it down. {2:N0} MB or less is safer.' -f $MemoryMiB,[double]$Hardware.MemoryGB,$safe
}
function Get-CenterDisabledReason {
 # Why the buttons of one kind are off for this profile right now, in one sentence ('' = they are on,
 # or what is running already says so itself). -For Backup: Back up now, Back up selected source,
 # Check backup content, Repair. Check: the drive check buttons. Speed: Run speed test.
 # The first thing in the way is named: work that is going on, then the drive, then what is selected.
 param([ValidateSet('Backup','Check','Speed')][string]$For='Backup',[string]$ProfileId,[bool]$Connected=$true,[bool]$NothingSelected=$false,[string]$RunProfileId,[string]$WaitProfileId,[string]$CheckProfileId,[string]$SpeedProfileId)
 if(-not $ProfileId){return ''}
 $busy=Get-CenterBusyReason -ProfileId $ProfileId -For $For -RunProfileId $RunProfileId -WaitProfileId $WaitProfileId -CheckProfileId $CheckProfileId -SpeedProfileId $SpeedProfileId
 if($For -eq 'Backup'){
  # One backup at a time, whichever drive it is for.
  if($RunProfileId){return $(if($RunProfileId -eq $ProfileId){'A backup of this drive is running. Stop ends it.'}else{'A backup of another drive is running, and only one runs at a time. Wait until it has finished, or stop it.'})}
  if($WaitProfileId){return $(if($WaitProfileId -eq $ProfileId){'A backup of this drive is waiting for AI sessions to finish and starts by itself. Stop cancels the wait.'}else{'A backup of another drive is waiting for AI sessions to finish. Stop cancels the wait.'})}
  if(-not $Connected){return 'Connect this drive to back up, check the backup or restore.'}
  if($busy){return $busy}
  if($NothingSelected){return 'Nothing is selected for backup on this drive. Add a folder, or choose how its folders are backed up, on the "What to back up" page.'}
  return ''
 }
 if(-not $Connected){return $(if($For -eq 'Check'){'Connect the drive to check it.'}else{'Connect the drive to test its speed.'})}
 if($For -eq 'Check'){
  if($CheckProfileId -and $CheckProfileId -ne $ProfileId){return 'A drive check of another drive is running. One drive at a time.'}
  return $busy
 }
 if($SpeedProfileId -and $SpeedProfileId -ne $ProfileId){return 'A speed test of another drive is running. It takes about half a minute; try again then.'}
 if($busy){return $busy}
 if($RunProfileId){return 'A backup of another drive is running. Wait until it has finished.'}
 if($WaitProfileId){return 'A backup of another drive is waiting for AI sessions to finish. Stop the wait first, or wait for the backup.'}
 ''
}
function Resolve-CenterSource($Profile,[string]$SelectedId) {
 # The source a link on the overview acts on: the selected one, or the only one. With several sources
 # and none selected it is nobody's guess: Source is empty and Message asks to select one.
 $all=@(if($Profile){$Profile.Sources})
 if(-not $all.Count){return [pscustomobject]@{Source=$null;Message='This drive has no folders to back up yet. Add one on the "What to back up" page.'}}
 $hit=if($SelectedId){$all|Where-Object {$_.Id -eq $SelectedId}|Select-Object -First 1}elseif($all.Count -eq 1){$all[0]}else{$null}
 [pscustomobject]@{Source=$hit;Message=$(if($hit){''}else{"Select a source in the list first: this drive has $($all.Count) sources."})}
}
function Get-CenterResultNotes($Result,[string]$Kind) {
 # Short notes for the history from things a tool mentions in its result. Every field is optional and
 # may be spelled or shaped a little differently (a list, a number, objects); what is missing or empty
 # gives no note, never an error.
 if($null -eq $Result -or $Result -isnot [pscustomobject]){return @()}
 $pick={param([string[]]$names)foreach($n in $names){if($Result.PSObject.Properties[$n] -and $null -ne $Result.$n){return ,$Result.$n}};$null}
 $text={param($x)
  if($x -is [string]){return $x}
  if($x -is [Collections.IEnumerable]){return (@($x|ForEach-Object {[string]$_}) -join ' / ')}
  if($x -is [pscustomobject]){
   foreach($n in 'Names','Paths'){if($x.PSObject.Properties[$n] -and $x.$n){return (@($x.$n|ForEach-Object {[string]$_}) -join ' / ')}}
   foreach($n in 'Path','Relative','Name','File'){if($x.PSObject.Properties[$n] -and $x.$n){return [string]$x.$n}}
   return (@($x.PSObject.Properties|ForEach-Object {[string]$_.Value}) -join ' / ')
  }
  [string]$x}
 $some={param($items)$t=@($items|ForEach-Object {& $text $_}|Where-Object {$_});if($t.Count -gt 5){(@($t|Select-Object -First 5) -join ', ')+" and $($t.Count-5) more"}else{$t -join ', '}}
 $list={param($v)if($v -is [string] -or $v -is [pscustomobject]){,@($v)}elseif($v -is [Collections.IEnumerable]){,@($v|Where-Object {$null -ne $_})}else{,@()}}
 $notes=@()
 if($Kind -like 'Mirror*'){
  $v=& $pick 'TypeSwapsHealed','TypeSwaps','HealedTypeSwaps'
  if($null -ne $v){
   $items=& $list $v
   if($items.Count){
    $to=[string]($items|Where-Object {$_ -is [pscustomobject] -and $_.PSObject.Properties['MovedTo'] -and $_.MovedTo}|ForEach-Object {[string]$_.MovedTo}|Select-Object -First 1)
    if(-not $to){$to=[string](& $pick 'RecoveryFolder','Recovery','MovedTo')}
    $notes+="A folder took the place of a file of the same name, or a file the place of a folder ($(& $some $items)); the old one was moved to $(if($to){$to}else{'the recovery folder beside the plain copy'})."
   }
  }
  $v=& $pick 'SkippedByShortName','ShortNameSkipped','SkippedShortNames'
  if($null -ne $v){
   $items=& $list $v;$n=if($items.Count){$items.Count}else{try{[int]$v}catch{0}}
   if($n -gt 0){$notes+="$n $(if($n -eq 1){'file was'}else{'files were'}) skipped because an Exclude pattern also matches $(if($n -eq 1){'its'}else{'their'}) short Windows name$(if($items.Count){': '+(& $some $items)})."}
  }
  $v=& $pick 'CaseCollisions','CaseConflicts'
  if($null -ne $v){$items=& $list $v;if($items.Count){$notes+="Two names differ only by upper/lower case and cannot both be kept: $(& $some $items)."}}
 }else{
  $v=& $pick 'LockReleased','LockRemoved','StaleLockRemoved'
  if($v -and "$v" -ne 'False'){$notes+='A lock left by an earlier run that had ended was removed and the run was tried again.'}
 }
 @($notes)
}

# --- Other work on this computer -----------------------------------------------------------
function Get-CenterAgentActivity {
 # Are AI coding sessions (Claude Code, Codex) still working? A backup taken while they edit files
 # catches them half-way. A working session appends to its conversation file every few seconds, which
 # is a reliable sign: the app's own "running" flag and the list of open programs are not (helper
 # programs stay open while idle). A Codex program that is running also counts as work.
 param([int]$QuietMinutes=10,[datetime]$Now=(Get-Date),
  [string]$ClaudeRoot=(Join-Path $env:USERPROFILE '.claude\projects'),
  [string]$CodexRoot=(Join-Path $env:USERPROFILE '.codex\sessions'),
  [switch]$SkipProcesses,[string]$ProcessName='codex')
 $cut=$Now.AddMinutes(-$QuietMinutes);$recent=@();$newest=$null
 foreach($root in @($ClaudeRoot,$CodexRoot)){
  if(-not $root -or -not(Test-Path -LiteralPath $root -PathType Container)){continue}
  foreach($f in [IO.Directory]::EnumerateFiles($root,'*.jsonl',[IO.SearchOption]::AllDirectories)){
   $t=[IO.File]::GetLastWriteTime($f)
   # A time slightly ahead (clocks differ a little) counts as now. One far ahead (a file copied from
   # another computer, a clock that was set back) says nothing about work going on: counted as now it
   # would look busy at every check until that time came, and a waiting backup would never start.
   if($t -gt $Now.AddMinutes(2)){continue}
   if($t -gt $Now){$t=$Now}
   if(-not $newest -or $t -gt $newest){$newest=$t}
   if($t -gt $cut){$recent+=[pscustomobject]@{Path=$f;LastWrite=$t;Codex=($root -eq $CodexRoot)}}
  }
 }
 $sessions=@()
 foreach($r in @($recent|Sort-Object LastWrite -Descending)){
  # A helper agent writes under <session>\subagents; it belongs to its parent session.
  $owner=$r.Path;if($owner -match '^(.*)\\subagents\\[^\\]+$'){$owner=[IO.Path]::GetDirectoryName($matches[1])+'\'+[IO.Path]::GetFileName($matches[1])+'.jsonl'}
  if(@($sessions|Where-Object {$_.Owner -eq $owner}).Count){continue}
  $name=if($r.Codex){'Codex session'}else{Get-CenterSessionTitle $owner}
  $sessions+=[pscustomobject]@{Owner=$owner;Name=$name;LastWrite=$r.LastWrite}
 }
 $codex=if($SkipProcesses){0}else{@(Get-Process -Name $ProcessName -ErrorAction SilentlyContinue).Count}
 [pscustomobject]@{
  Busy=($sessions.Count -gt 0 -or $codex -gt 0);Sessions=$sessions;CodexPrograms=$codex
  LastActivity=$newest;QuietMinutes=$QuietMinutes
 }
}
function Get-CenterSessionTitle([string]$Path) {
 # The newest title in the last part of a conversation file; otherwise the project folder name.
 $fallback=[IO.Path]::GetFileName([IO.Path]::GetDirectoryName($Path)) -replace '^[A-Za-z]--',''
 if(-not(Test-Path -LiteralPath $Path -PathType Leaf)){return $fallback}
 try{
  $fs=[IO.File]::Open($Path,'Open','Read','ReadWrite,Delete')
  try{$len=[Math]::Min($fs.Length,262144);[void]$fs.Seek(-$len,'End');$buf=[byte[]]::new($len);[void]$fs.Read($buf,0,$len);$text=[Text.Encoding]::UTF8.GetString($buf)}finally{$fs.Dispose()}
  $m=[regex]::Matches($text,'"(?:customTitle|aiTitle)":"((?:[^"\\]|\\.)*)"')
  if($m.Count){return [regex]::Unescape($m[$m.Count-1].Groups[1].Value)}
 }catch{}
 $fallback
}

# --- Running ------------------------------------------------------------------------------
function Get-CenterKeepDeleted($Profile) {
 # KeepDeleted N (1-100): files deleted from the source are moved out of the plain copy into a dated
 # recovery folder, and only the newest N recovery folders are kept. 0 or missing: they stay in the copy.
 if(-not $Profile.PSObject.Properties['KeepDeleted'] -or $null -eq $Profile.KeepDeleted){return 0}
 [math]::Max(0,[math]::Min(100,[int]$Profile.KeepDeleted))
}
function Get-CenterVersionRetention($Profile) {
 # VersionRetention {Days,Weeks,Months}: after each versioned backup keep one version per day for Days
 # days, per week for Weeks weeks and per month for Months months; older ones are deleted. Missing or
 # all zero: every version is kept until deleted by hand.
 $r=if($Profile.PSObject.Properties['VersionRetention']){$Profile.VersionRetention}else{$null}
 $get={param($n,$max)if($r -and $r.PSObject.Properties[$n] -and $null -ne $r.$n){[math]::Max(0,[math]::Min($max,[int]$r.$n))}else{0}}
 $d=& $get 'Days' 3650;$w=& $get 'Weeks' 520;$m=& $get 'Months' 240
 [pscustomobject]@{Enabled=($d+$w+$m -gt 0);Days=$d;Weeks=$w;Months=$m}
}
function Format-CenterVersionRetention($Retention) {
 if(-not $Retention.Enabled){return 'every version'}
 @(if($Retention.Days){"$($Retention.Days) d"};if($Retention.Weeks){"$($Retention.Weeks) w"};if($Retention.Months){"$($Retention.Months) m"}) -join ' / '
}
function Get-CenterSteps($Profile,[string[]]$SourceIds=@(),[ValidateSet('Backup','Verify','Repair')][string]$Purpose='Backup') {
 # The ordered list of tool runs for one press of Back up / Verify / Repair. A repair is for plain
 # copies only: the files the last content check found different are moved aside and copied again.
 $drive=Get-CenterDrive $Profile.DestinationVolumeId -Fresh
 if(-not $drive.Connected){throw "The drive for '$($Profile.Name)' is not connected"}
 $pwsh=(Get-Process -Id $PID).Path
 $load=Get-CenterLoad $Profile
 foreach($s in @($Profile.Sources|Where-Object {-not $SourceIds.Count -or $_.Id -in $SourceIds})){
  $kinds=Get-CenterSourceKinds $s
  if($kinds.Mirror){
   $a=@('-NoProfile','-File',(Join-Path $script:ToolRoot 'Invoke-FastMirror.ps1'),'-ConfigPath',$s.ConfigPath,'-DestinationDrive',$drive.Letter,'-Folder',$s.MirrorFolder,'-Threads',[string]$load.CopyThreads)
   if($Purpose -eq 'Verify'){$a+='-VerifyOnly'}
   elseif($Purpose -eq 'Repair'){$a+='-Repair'}
   else{$keep=Get-CenterKeepDeleted $Profile;if($keep -gt 0){$a+=@('-MoveExtras','-KeepRecovery',[string]$keep)}}
   [pscustomobject]@{SourceId=$s.Id;Label=$s.Label;Kind='Mirror';Purpose=$Purpose;FilePath=$pwsh;Arguments=$a;RunDirectory=$null;Priority=$load.Priority}
  }
  if($kinds.Versioned -and $Purpose -ne 'Repair'){
   $run=Join-Path $env:LOCALAPPDATA ('DevDriveMirror\runs\center-'+(Get-Date -Format 'yyyyMMdd-HHmmss')+'-'+(New-ShortId))
   $a=@('-NoProfile','-File',(Join-Path $script:ToolRoot 'Backup-Worker.ps1'),'-ConfigPath',$s.ConfigPath,'-RunDirectory',$run)
   $a+=if($Purpose -eq 'Verify'){@('-Action','Check','-ReadAllData')}else{@('-Action','Backup')}
   $keep=Get-CenterVersionRetention $Profile
   if($Purpose -eq 'Backup' -and $keep.Enabled){$a+=@('-KeepDays',[string]$keep.Days,'-KeepWeeks',[string]$keep.Weeks,'-KeepMonths',[string]$keep.Months)}
   [pscustomobject]@{SourceId=$s.Id;Label=$s.Label;Kind='Versioned';Purpose=$Purpose;FilePath=$pwsh;Arguments=$a;RunDirectory=$run;Priority=$load.Priority}
  }
 }
}
function Start-CenterStep($Step,[string]$OutputPath) {
 $psi=[Diagnostics.ProcessStartInfo]::new($Step.FilePath)
 foreach($a in $Step.Arguments){[void]$psi.ArgumentList.Add($a)}
 $psi.UseShellExecute=$false;$psi.CreateNoWindow=$true;$psi.RedirectStandardOutput=$true;$psi.RedirectStandardError=$true
 $p=[Diagnostics.Process]::new();$p.StartInfo=$psi
 [void]$p.Start()
 # Programs a lower-priority process starts (robocopy) inherit its priority.
 if($Step.PSObject.Properties['Priority'] -and $Step.Priority){try{$p.PriorityClass=$Step.Priority}catch{}}
 # Read both streams asynchronously so a full pipe never blocks the tool.
 $out=$p.StandardOutput.ReadToEndAsync();$err=$p.StandardError.ReadToEndAsync()
 [pscustomobject]@{Step=$Step;Process=$p;Out=$out;Err=$err;Started=Get-Date;OutputPath=$OutputPath}
}
function Complete-CenterStep($Running,[string]$ProfileId,[switch]$Stopped) {
 # Turns a finished tool run into one history entry. -Stopped: the user ended it (Stop, or closing the
 # window) and the tool was killed; it is recorded as stopped rather than as a tool that failed, and
 # the waits are limited, because a killed tool can leave a helper behind that keeps its output open.
 $p=$Running.Process
 if($Stopped){[void]$p.WaitForExit(10000)}else{$p.WaitForExit()}
 $read={param($task)if(-not $Stopped){return $task.GetAwaiter().GetResult()};try{if($task.Wait(5000)){$task.Result}else{''}}catch{''}}
 $stdout=[string](& $read $Running.Out);$stderr=[string](& $read $Running.Err)
 $code=if($p.HasExited){$p.ExitCode}else{-1}
 if($Running.OutputPath){[IO.File]::WriteAllText($Running.OutputPath,$stdout+"`n--- errors ---`n"+$stderr)}
 $s=$Running.Step
 # Seconds is exact; Minutes (a tenth of a minute) stays for older readers. ProcessedBytes: what a
 # versioned backup read, where CopiedBytes is only what it had to store.
 $e=[ordered]@{ProfileId=$ProfileId;SourceId=$s.SourceId;Label=$s.Label;Kind=$s.Kind;Purpose=$s.Purpose;Started=$Running.Started.ToString('o');Finished=(Get-Date).ToString('o')
  Minutes=[math]::Round(((Get-Date)-$Running.Started).TotalMinutes,1);Seconds=[math]::Round(((Get-Date)-$Running.Started).TotalSeconds,1);Success=$false;Stopped=$false;Error=$null;CopiedFiles=$null;CopiedBytes=$null;ProcessedBytes=$null;CheckedFiles=$null;Differences=$null;Details=$null;Note=$null}
 $notes=@()
 try{
  if($s.Kind -eq 'Mirror'){
   $r=try{ConvertFrom-CenterToolJson $stdout 'CopyErrors'}catch{$null}
   if(-not $r){throw ($stderr.Trim() -replace '\s+',' ')}
   $e.Details=$r.RunFolder
   # Files and bytes copied are the second number of each robocopy total. A total that was not read
   # (the tool could not find it in the log) leaves both unknown: 0 would claim that nothing was copied.
   $files=[long]0;$bytes=[long]0;$known=[bool]@($r.Runs).Count   # no run listed: nothing was read either
   foreach($run in @($r.Runs)){
    if([string]$run.Files -match '^Files : \d+ (\d+)'){$files+=[long]$Matches[1]}else{$known=$false}
    if([string]$run.Bytes -match '^Bytes : \d+ (\d+)'){$bytes+=[long]$Matches[1]}else{$known=$false}
   }
   if($known){$e.CopiedFiles=$files;$e.CopiedBytes=$bytes}
   $verifyOk=$true
   # Differences is kept as a number of its own: "Repair differing files" is offered from it, also when
   # the error text below names something else.
   if($r.PSObject.Properties['Verify'] -and $r.Verify){$e.CheckedFiles=$r.Verify.FilesMatched;$e.Differences=$r.Verify.Differences;$verifyOk=$r.Verify.Differences -eq 0;if(-not $verifyOk){$e.Error="$($r.Verify.Differences) files differ from the source; see verify-differences.txt in $($r.RunFolder)"}}
   if($r.CopyErrors -gt 0){$e.Error="$($r.CopyErrors) files could not be copied; see copy-errors.txt in $($r.RunFolder)"}
   $e.Success=($code -eq 0 -and $r.CopyErrors -eq 0 -and $verifyOk)
   # A repair reports what it did with the files the last content check found different. Without that
   # report it is not known to have repaired anything, so it is never recorded as a success.
   if($s.Purpose -eq 'Repair'){
    $rep=if($r.PSObject.Properties['Repair'] -and $r.Repair -is [pscustomobject]){$r.Repair}else{$null}
    # A report without its numbers (how many were asked for, how many were repaired) says nothing either.
    if($rep -and @('Requested','Repaired'|Where-Object {-not $rep.PSObject.Properties[$_] -or $null -eq $rep.$_}).Count){$rep=$null}
    if(-not $rep){$e.Success=$false;if(-not $e.Error){$e.Error='The plain copy tool did not report what it repaired.'}}
    else{
     $num={param($n)if($rep.PSObject.Properties[$n] -and $null -ne $rep.$n){try{[long]$rep.$n}catch{[long]0}}else{[long]0}}
     $asked=& $num 'Requested';$fixed=& $num 'Repaired';$still=& $num 'StillDifferent';$lost=& $num 'Failed'
     $to=if($rep.PSObject.Properties['MovedTo'] -and $rep.MovedTo){[string]$rep.MovedTo}else{''}
     if($fixed -gt 0){$notes+="Repaired $fixed $(if($fixed -eq 1){'file'}else{'files'}); $(if($fixed -eq 1){'its earlier copy is'}else{'their earlier copies are'}) in $(if($to){$to}else{'the recovery folder beside the plain copy'})."}
     elseif($asked -eq 0 -and $still+$lost -eq 0){$notes+='No differing files were found, so nothing was repaired.'}
     # Fewer repaired than asked for, with nothing said about the rest, is not a repair that worked.
     if($still+$lost -eq 0 -and $fixed -lt $asked){$still=$asked-$fixed}
     if($still+$lost -gt 0){
      $e.Success=$false
      $e.Error=(@(if($still){"$still of $asked files still differ after the repair"};if($lost){"$lost could not be repaired"}) -join ' and ')+"; see $($r.RunFolder)"
     }
    }
   }
   # DevDriveBackup's own password and recovery key folders are never copied, even when selected.
   if($r.PSObject.Properties['SelectionsSkippedAsPrivate'] -and @($r.SelectionsSkippedAsPrivate).Count){$notes+="Not copied, because DevDriveBackup never copies its own password and recovery key folders: $(@($r.SelectionsSkippedAsPrivate) -join ', ')."}
   if($r.PSObject.Properties['PrivateCopiesOnDrive'] -and @($r.PrivateCopiesOnDrive).Count){$notes+="An older copy of DevDriveBackup's private folders is still in the plain copy and holds readable recovery keys: $(@($r.PrivateCopiesOnDrive) -join ', '). Delete it from the backup drive."}
   $notes+=@(Get-CenterResultNotes $r 'Mirror')
  }else{
   $resultPath=Join-Path $s.RunDirectory 'result.json'
   if(-not(Test-Path -LiteralPath $resultPath)){throw ($stderr.Trim() -replace '\s+',' ')}
   $r=Read-BackupStatus $resultPath
   $e.Details=$s.RunDirectory
   # The worker ends with exit code 0 only after it wrote Completed; a result left by an earlier
   # run, or written before the worker failed, must not turn a failed run into a success.
   if($r.State -eq 'Completed' -and $code -eq 0){
    $e.Success=$true
    # The worker's BackupSummary is the engine's own end-of-backup summary. Results written before it
    # existed carry the same numbers in Progress only when the last progress line was the summary.
    $sum=if($r.PSObject.Properties['BackupSummary'] -and $r.BackupSummary){$r.BackupSummary}elseif($r.PSObject.Properties['Progress'] -and $r.Progress -and $r.Progress.PSObject.Properties['files_new']){$r.Progress}else{$null}
    if($sum){
     $num={param($n)if($sum.PSObject.Properties[$n] -and $null -ne $sum.$n){try{[long]$sum.$n}catch{$null}}else{$null}}   # an unreadable number is unknown, not an error
     $new=& $num 'files_new';$changed=& $num 'files_changed'
     if($null -ne $new -and $null -ne $changed){$e.CopiedFiles=$new+$changed}
     $e.CopiedBytes=& $num 'data_added';$e.ProcessedBytes=& $num 'total_bytes_processed'
    }
   }
   elseif($r.PSObject.Properties['Error'] -and $r.Error){$e.Error=[string]$r.Error}
   # The automatic clean-up of old versions: a note. Only a failed check of the repository after it
   # fails the backup, and the worker reports that as the run's error.
   if($r.PSObject.Properties['Retention'] -and $r.Retention){
    $ret=$r.Retention
    $err=if($ret.PSObject.Properties['Error'] -and $ret.Error){[string]$ret.Error}else{''}
    $removed=if($ret.PSObject.Properties['Removed'] -and $ret.Removed){try{[int]$ret.Removed}catch{0}}else{0}
    $kept=if($ret.PSObject.Properties['Kept'] -and $null -ne $ret.Kept){"; $($ret.Kept) kept"}else{''}
    $notes+=if($err -and $removed){"Deleted $removed old versions$kept, but the clean-up did not finish: $err"}elseif($err){"Backed up, but old versions were not cleaned up: $err"}elseif($removed){"Deleted $removed old versions$kept."}else{"No old versions to delete$kept."}
   }
   $notes+=@(Get-CenterResultNotes $r 'Versioned')
  }
 }catch{$e.Error=$_.Exception.Message;$e.Success=$false}   # a result that could not be read in full is never recorded as a success
 if($notes.Count){$e.Note=$notes -join ' '}
 # A tool that was killed did not finish, whatever result it had already written; one that had ended
 # by itself just before the kill keeps its own result.
 if($Stopped -and $code -ne 0){$e.Success=$false;$e.Stopped=$true;$e.Error='Stopped by you before it finished.'}
 if(-not $e.Success -and -not $e.Error){$e.Error="The tool ended with exit code $code"}
 # A verification of an existing backup does not make the backup newer.
 # Nor does a repair: it puts single files right and is no complete backup.
 if($s.Purpose -eq 'Verify'){$e.Kind=$s.Kind+'Check'}elseif($s.Purpose -eq 'Repair'){$e.Kind=$s.Kind+'Repair'}
 try{Add-CenterHistory ([pscustomobject]$e)}finally{$p.Dispose()}
 [pscustomobject]$e
}

# --- Old backups (shown in the window; there is no automatic reminder) ----------------------
function Get-CenterStaleProfiles([datetime]$Now=(Get-Date)) {
 $data=Read-CenterProfiles;$history=@(Get-CenterHistory)
 foreach($p in $data.Profiles){
  $f=Get-CenterFreshness $p $history $Now
  if($f.State -in @('Stale','Never')){[pscustomobject]@{Profile=$p;Freshness=$f}}
 }
}
Export-ModuleMember -Function Get-CenterHardware,Get-CenterLoadPresets,Get-CenterLoad,Set-CenterRunPriority,Set-CenterPaths,Get-CenterPaths,Read-CenterProfiles,Save-CenterProfiles,Get-CenterProfile,Get-CenterKeepDeleted,Get-CenterVersionRetention,Format-CenterVersionRetention,Get-CenterDrive,Get-CenterCandidateDrives,
 New-CenterProfile,Remove-CenterProfile,Add-CenterSource,Remove-CenterSource,Read-CenterJob,Save-CenterJob,Get-CenterSourceKinds,Sync-CenterJob,
 Add-CenterHistory,Get-CenterHistory,Get-LastSuccess,Get-FreshnessState,Format-CenterAge,Get-CenterFreshness,ConvertTo-CenterTime,Format-CenterElapsed,Format-CenterRunDuration,Get-CenterRunSpeed,ConvertFrom-CenterToolJson,
 Get-CenterBusyReason,Get-CenterFreeBytes,Get-CenterVolumeQueryCount,
 Save-CenterLastGood,Get-CenterSettingsRecovery,Restore-CenterLastGood,Get-CenterRunWarnings,Format-CenterRunWarnings,Get-CenterRepairState,Remove-CenterOldStepLogs,Get-CenterLoadWarning,Get-CenterDisabledReason,Resolve-CenterSource,Get-CenterResultNotes,
 Get-CenterSteps,Start-CenterStep,Complete-CenterStep,Get-CenterStaleProfiles,Get-CenterAgentActivity,Get-CenterSessionTitle
