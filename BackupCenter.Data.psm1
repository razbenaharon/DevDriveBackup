#Requires -Version 7.2
# Data layer of the Backup Center: drive profiles, their sources, run history and freshness.
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
 $t=[int]$Hardware.Threads;$mem=[double]$Hardware.MemoryGB*1024
 $m={param([double]$Share,[int]$Min,[int]$Max)[int][math]::Max($Min,[math]::Min($Max,[math]::Floor($mem*$Share/256)*256))}
 [ordered]@{
  Light=[pscustomobject]@{Name='Light';CpuThreads=[int][math]::Max(1,[math]::Floor($t/6));MemoryMiB=(& $m 0.03 512 1024);CopyThreads=4;ReadConcurrency=1;Priority='BelowNormal'}
  Balanced=[pscustomobject]@{Name='Balanced';CpuThreads=[int][math]::Min($t,[math]::Max(2,[math]::Floor($t/3)));MemoryMiB=(& $m 0.06 512 2048);CopyThreads=8;ReadConcurrency=2;Priority='BelowNormal'}
  Strong=[pscustomobject]@{Name='Strong';CpuThreads=[int][math]::Min($t,[math]::Max(2,[math]::Floor($t/2)));MemoryMiB=(& $m 0.12 1024 4096);CopyThreads=16;ReadConcurrency=4;Priority='Normal'}
  Maximum=[pscustomobject]@{Name='Maximum';CpuThreads=[int][math]::Max(1,$t-1);MemoryMiB=(& $m 0.25 1024 8192);CopyThreads=32;ReadConcurrency=8;Priority='Normal'}
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
  $script:Paths=[pscustomobject]@{Profiles=(Join-Path $Root 'profiles.local.json');Jobs=(Join-Path $Root 'jobs');History=(Join-Path $Root 'history.jsonl');Keys=(Join-Path $Root 'keys');Documents=(Join-Path $Root 'documents');DriveCheck=(Join-Path $Root 'drive-check')}
 }else{
  $app=Join-Path $env:LOCALAPPDATA 'DevDriveMirror'
  $script:Paths=[pscustomobject]@{Profiles=(Join-Path $script:ToolRoot 'profiles.local.json');Jobs=(Join-Path $script:ToolRoot 'jobs');History=(Join-Path $app 'center\history.jsonl');Keys=$app;Documents=(Join-Path $env:USERPROFILE 'Backup Center recovery keys');DriveCheck=(Join-Path $app 'drive-check')}  # local, not a synced Documents folder
 }
 $script:Paths
}
function Get-CenterPaths {if(-not $script:Paths){[void](Set-CenterPaths '')};$script:Paths}

function Read-CenterProfiles {
 $p=(Get-CenterPaths).Profiles
 if(-not(Test-Path -LiteralPath $p)){return [pscustomobject]@{Version=1;Profiles=@()}}
 $data=Get-Content -LiteralPath $p -Raw|ConvertFrom-Json
 $data.Profiles=@($data.Profiles|ForEach-Object {$_.Sources=@($_.Sources);$_})
 $data
}
function Save-CenterProfiles($Data) {
 $p=(Get-CenterPaths).Profiles
 New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($p)) -Force|Out-Null
 [void](Write-BackupStatus $Data $p)
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

function Get-CenterDrive([string]$VolumeId) {
 # The drive of a profile, or Connected=$false when it is not plugged in.
 $v=@(Get-Volume -ErrorAction SilentlyContinue|Where-Object {$_.UniqueId -eq $VolumeId -and $_.DriveLetter})
 if($v.Count -ne 1){return [pscustomobject]@{Connected=$false;Letter=$null;Label=$null;FileSystem=$null;SizeGB=$null;FreeGB=$null}}
 [pscustomobject]@{Connected=$true;Letter=[string]$v[0].DriveLetter;Label=$v[0].FileSystemLabel;FileSystem=$v[0].FileSystem;SizeGB=[math]::Round($v[0].Size/1GB,1);FreeGB=[math]::Round($v[0].SizeRemaining/1GB,1)}
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
 param($Data,[string]$ProfileId,[string]$Path,[string]$Label,[ValidateSet('Mirror','Versioned','Both','Skip')][string]$DefaultMode='Mirror',[string]$ExistingConfigPath,[string]$MirrorFolder)
 $profile=Get-CenterProfile $Data $ProfileId
 $root=[IO.Path]::GetFullPath($Path).TrimEnd('\')+'\'
 if(-not(Test-Path -LiteralPath $root -PathType Container)){throw "Folder not found: $root"}
 if((Get-Item -LiteralPath $root -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Choose the real folder, not a shortcut (junction or link) to it'}
 $volume=Get-Volume -DriveLetter $root.Substring(0,1)
 if($volume.UniqueId -eq $profile.DestinationVolumeId){throw 'This folder is on the backup drive itself'}
 foreach($s in $profile.Sources){if(Test-PathOverlap $s.Path $root){throw "Overlaps with the existing source '$($s.Label)' ($($s.Path))"}}
 if(-not $Label.Trim()){$Label=if($root.Length -eq 3){'Drive '+$root.Substring(0,1)}else{Split-Path -Leaf $root.TrimEnd('\')}}
 $safe=Get-SafeName $Label
 # Names that are not Latin letters all become "Source"; keep them apart.
 if($safe -eq 'Source'){$safe='Source-'+(New-ShortId).Substring(0,4)}
 $drive=Get-CenterDrive $profile.DestinationVolumeId
 $taken={param($n)@($profile.Sources|Where-Object {$_.MirrorFolder -ieq $n+'-Mirror' -or $_.Label -ieq $Label}).Count -or ($drive.Connected -and (Test-Path -LiteralPath ($drive.Letter+':\'+$n+'-Versions')))}
 $id=New-ShortId
 if(-not $ExistingConfigPath){
  # A source removed earlier keeps its job file (with its keys); adding the same folder again to
  # the same drive picks it up instead of creating a second repository next to the first.
  $jobs=(Get-CenterPaths).Jobs
  $old=@(Get-ChildItem -LiteralPath $jobs -Filter '*.local.json' -File -ErrorAction SilentlyContinue|Where-Object {
   try{$j=Get-Content -LiteralPath $_.FullName -Raw|ConvertFrom-Json;(([IO.Path]::GetFullPath([string]$j.Source).TrimEnd('\')+'\') -ieq $root) -and $j.DestinationVolumeId -eq $profile.DestinationVolumeId}catch{$false}
  }|Where-Object {$f=$_.FullName;-not @($profile.Sources|Where-Object {$_.ConfigPath -ieq $f}).Count}|Sort-Object LastWriteTime -Descending)
  if($old.Count){$ExistingConfigPath=$old[0].FullName}
 }
 if(-not $ExistingConfigPath){while(& $taken $safe){$safe=(Get-SafeName $Label)+'-'+(New-ShortId).Substring(0,4)}}
 if($ExistingConfigPath){
  # Adopt an existing job file (keeps its keys and repository).
  $config=[IO.Path]::GetFullPath($ExistingConfigPath)
  $c=Get-Content -LiteralPath $config -Raw|ConvertFrom-Json
  if(([IO.Path]::GetFullPath($c.Source).TrimEnd('\')+'\') -ine $root){throw 'That job file belongs to another source folder'}
 }else{
  $jobs=(Get-CenterPaths).Jobs;New-Item -ItemType Directory -Path $jobs -Force|Out-Null
  $config=Join-Path $jobs ($profile.Id+'-'+$id+'.local.json')
  $keyId=[guid]::NewGuid().ToString('N')
  $choices=@(Get-ChildItem -LiteralPath $root -Directory -Force -ErrorAction SilentlyContinue|Where-Object {$_.Name -notin @('$RECYCLE.BIN','System Volume Information') -and -not($_.Attributes -band [IO.FileAttributes]::ReparsePoint)}|Sort-Object Name|ForEach-Object {[pscustomobject]@{Path=$_.Name;Mode=$DefaultMode;Reason=''}})
  $c=[ordered]@{Source=$root;SourceVolumeId=$volume.UniqueId;DestinationVolumeId=$profile.DestinationVolumeId
   RepositoryFolder=($safe+'-Versions');PasswordDpapiPath=(Join-Path (Get-CenterPaths).Keys ($keyId+'.dpapi'))
   RecoveryKeyPath=(Join-Path (Get-CenterPaths).Documents ('Backup-'+$safe+'-'+$keyId+'-recovery-key.txt'))
   DefaultMode=$DefaultMode;Choices=$choices;Include=@();Exclude=$script:CacheNames;RecommendedExclude=$script:CacheNames}
  [void](Write-BackupStatus ([pscustomobject]$c) $config)
 }
 $source=[pscustomobject]@{Id=$id;Label=$Label.Trim();Path=$root;ConfigPath=$config;MirrorFolder=if($MirrorFolder){$MirrorFolder}else{$safe+'-Mirror'};Created=(Get-Date).ToString('o')}
 $profile.Sources=@($profile.Sources)+$source
 $source
}
function Remove-CenterSource($Data,[string]$ProfileId,[string]$SourceId) {
 # Forgets the source only; its job file (with key locations) and backups are kept.
 $profile=Get-CenterProfile $Data $ProfileId
 $profile.Sources=@($profile.Sources|Where-Object {$_.Id -ne $SourceId})
}

function Read-CenterJob([string]$ConfigPath) {Get-Content -LiteralPath $ConfigPath -Raw|ConvertFrom-Json}
function Save-CenterJob($Job,[string]$ConfigPath) {[void](Write-BackupStatus $Job $ConfigPath)}

function Get-CenterSourceKinds($Source) {
 # Which tools this source uses, from its per-folder modes.
 $sel=Get-BackupSelection (Read-CenterJob $Source.ConfigPath)
 [pscustomobject]@{
  Mirror=$sel.HasModes -and @(Get-BackupRegions $sel 'Mirror').Count -gt 0
  Versioned=@(Get-BackupRegions $sel 'Versioned').Count -gt 0
 }
}

function Sync-CenterJob($Profile,$Source,$Load=(Get-CenterLoad $Profile)) {
 # Keeps a job file pointed at its profile's drive and the chosen load.
 $job=Read-CenterJob $Source.ConfigPath;$changed=$false
 if($job.DestinationVolumeId -ne $Profile.DestinationVolumeId){$job.DestinationVolumeId=$Profile.DestinationVolumeId;$changed=$true}
 $light=$Load.Name -eq 'Light'
 $speed=[ordered]@{Profile=$Load.Name;CpuThreads=$Load.CpuThreads;MemoryMiB=$Load.MemoryMiB;ReadConcurrency=$Load.ReadConcurrency;Priority=$Load.Priority
  RateMBps=0;PackMiB=$(if($light){16}else{32});BackendConnections=$(if($Load.Name -in @('Light','Balanced')){2}else{4})}
 foreach($k in $speed.Keys){
  if(-not $job.PSObject.Properties[$k]){$job|Add-Member -NotePropertyName $k -NotePropertyValue $speed[$k];$changed=$true}
  elseif($job.$k -ne $speed[$k]){$job.$k=$speed[$k];$changed=$true}
 }
 if($changed){Save-CenterJob $job $Source.ConfigPath}
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
 Get-Content -LiteralPath $p -Encoding utf8|Where-Object {$_.Trim()}|ForEach-Object {try{$_|ConvertFrom-Json}catch{}}|
  Where-Object {$_ -is [pscustomobject] -and $_.PSObject.Properties['SourceId'] -and $_.PSObject.Properties['Kind'] -and $_.PSObject.Properties['Finished'] -and $_.PSObject.Properties['Success']}
}
function Get-LastSuccess($History,[string]$SourceId,[string]$Kind) {
 $hit=@(@($History)|Where-Object {$_ -and $_.SourceId -eq $SourceId -and $_.Kind -eq $Kind -and $_.Success -eq $true}|Sort-Object {[datetime]$_.Finished} -Descending)
 if($hit.Count){[datetime]$hit[0].Finished}else{$null}
}
function Get-FreshnessState($When,[int]$ReminderDays,[datetime]$Now) {
 if(-not $When){return 'Never'}
 $age=$Now-[datetime]$When
 if($age.TotalHours -lt 24){'Fresh'}elseif($age.TotalDays -lt $ReminderDays){'OK'}else{'Stale'}
}
function Format-CenterAge($When,[datetime]$Now=(Get-Date)) {
 if(-not $When){return 'never'}
 $age=$Now-[datetime]$When
 if($age.TotalMinutes -lt 2){'just now'}
 elseif($age.TotalHours -lt 1){'{0} minutes ago' -f [int]$age.TotalMinutes}
 elseif($age.TotalHours -lt 48){$h=[int][math]::Floor($age.TotalHours);if($h -eq 1){'1 hour ago'}else{"$h hours ago"}}
 else{'{0} days ago' -f [int][math]::Floor($age.TotalDays)}
}
function Get-CenterFreshness($Profile,$History,[datetime]$Now=(Get-Date)) {
 # A source is as fresh as the older of its two kinds; a profile as fresh as its oldest source.
 $rows=foreach($s in $Profile.Sources){
  $kinds=try{Get-CenterSourceKinds $s}catch{[pscustomobject]@{Mirror=$false;Versioned=$false;Error=$_.Exception.Message}}
  $lm=if($kinds.Mirror){Get-LastSuccess $History $s.Id 'Mirror'}else{$null}
  $lv=if($kinds.Versioned){Get-LastSuccess $History $s.Id 'Versioned'}else{$null}
  $needed=@();if($kinds.Mirror){$needed+=,$lm};if($kinds.Versioned){$needed+=,$lv}
  $complete=if($needed.Count -eq 0 -or @($needed|Where-Object {$null -eq $_}).Count){$null}else{($needed|Sort-Object)[0]}
  $problem=if($kinds.PSObject.Properties['Error']){[string]$kinds.Error}else{$null}
  [pscustomobject]@{Source=$s;Mirror=$kinds.Mirror;Versioned=$kinds.Versioned;LastMirror=$lm;LastVersioned=$lv;LastComplete=$complete;Problem=$problem
   State=if($problem){'Error'}elseif($needed.Count -eq 0){'Nothing selected'}else{Get-FreshnessState $complete $Profile.ReminderDays $Now}}
 }
 $rows=@($rows)
 # A source whose settings cannot be read is not backed up, so it keeps the drive from looking fresh.
 $active=@($rows|Where-Object {$_.State -ne 'Nothing selected'})
 $profileComplete=if(-not $active.Count -or @($active|Where-Object {$null -eq $_.LastComplete}).Count){$null}else{($active.LastComplete|Sort-Object)[0]}
 $state=if(-not $active.Count){'Nothing selected'}elseif(@($active|Where-Object {$_.State -eq 'Error'}).Count){'Error'}else{Get-FreshnessState $profileComplete $Profile.ReminderDays $Now}
 [pscustomobject]@{Rows=$rows;LastComplete=$profileComplete;State=$state}
}

# --- Running ------------------------------------------------------------------------------
function Get-CenterSteps($Profile,[string[]]$SourceIds=@(),[ValidateSet('Backup','Verify')][string]$Purpose='Backup') {
 # The ordered list of tool runs for one press of Back up / Verify.
 $drive=Get-CenterDrive $Profile.DestinationVolumeId
 if(-not $drive.Connected){throw "The drive for '$($Profile.Name)' is not connected"}
 $pwsh=(Get-Process -Id $PID).Path
 $load=Get-CenterLoad $Profile
 foreach($s in @($Profile.Sources|Where-Object {-not $SourceIds.Count -or $_.Id -in $SourceIds})){
  $kinds=Get-CenterSourceKinds $s
  if($kinds.Mirror){
   $a=@('-NoProfile','-File',(Join-Path $script:ToolRoot 'Invoke-FastMirror.ps1'),'-ConfigPath',$s.ConfigPath,'-DestinationDrive',$drive.Letter,'-Folder',$s.MirrorFolder,'-Threads',[string]$load.CopyThreads)
   if($Purpose -eq 'Verify'){$a+='-VerifyOnly'}
   [pscustomobject]@{SourceId=$s.Id;Label=$s.Label;Kind='Mirror';Purpose=$Purpose;FilePath=$pwsh;Arguments=$a;RunDirectory=$null;Priority=$load.Priority}
  }
  if($kinds.Versioned){
   $run=Join-Path $env:LOCALAPPDATA ('DevDriveMirror\runs\center-'+(Get-Date -Format 'yyyyMMdd-HHmmss')+'-'+(New-ShortId))
   $a=@('-NoProfile','-File',(Join-Path $script:ToolRoot 'Backup-Worker.ps1'),'-ConfigPath',$s.ConfigPath,'-RunDirectory',$run)
   $a+=if($Purpose -eq 'Verify'){@('-Action','Check','-ReadAllData')}else{@('-Action','Backup')}
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
function Complete-CenterStep($Running,[string]$ProfileId) {
 # Turns a finished tool run into one history entry.
 $p=$Running.Process;$p.WaitForExit()
 $stdout=$Running.Out.GetAwaiter().GetResult();$stderr=$Running.Err.GetAwaiter().GetResult()
 if($Running.OutputPath){[IO.File]::WriteAllText($Running.OutputPath,$stdout+"`n--- errors ---`n"+$stderr)}
 $s=$Running.Step
 $e=[ordered]@{ProfileId=$ProfileId;SourceId=$s.SourceId;Label=$s.Label;Kind=$s.Kind;Purpose=$s.Purpose;Started=$Running.Started.ToString('o');Finished=(Get-Date).ToString('o')
  Minutes=[math]::Round(((Get-Date)-$Running.Started).TotalMinutes,1);Success=$false;Error=$null;CopiedFiles=$null;CopiedBytes=$null;CheckedFiles=$null;Details=$null}
 try{
  if($s.Kind -eq 'Mirror'){
   $start=$stdout.IndexOf('{');if($start -lt 0){throw ($stderr.Trim() -replace '\s+',' ')}
   $r=$stdout.Substring($start)|ConvertFrom-Json
   $e.Details=$r.RunFolder
   $files=[long]0;$bytes=[long]0
   foreach($run in @($r.Runs)){
    if($run.Files -match '^Files : \d+ (\d+)'){$files+=[long]$Matches[1]}
    if($run.Bytes -match '^Bytes : \d+ (\d+)'){$bytes+=[long]$Matches[1]}
   }
   $e.CopiedFiles=$files;$e.CopiedBytes=$bytes
   $verifyOk=$true
   if($r.PSObject.Properties['Verify'] -and $r.Verify){$e.CheckedFiles=$r.Verify.FilesMatched;$verifyOk=$r.Verify.Differences -eq 0;if(-not $verifyOk){$e.Error="$($r.Verify.Differences) files differ from the source; see verify-differences.txt in $($r.RunFolder)"}}
   if($r.CopyErrors -gt 0){$e.Error="$($r.CopyErrors) files could not be copied; see copy-errors.txt in $($r.RunFolder)"}
   $e.Success=($p.ExitCode -eq 0 -and $r.CopyErrors -eq 0 -and $verifyOk)
  }else{
   $resultPath=Join-Path $s.RunDirectory 'result.json'
   if(-not(Test-Path -LiteralPath $resultPath)){throw ($stderr.Trim() -replace '\s+',' ')}
   $r=Read-BackupStatus $resultPath
   $e.Details=$s.RunDirectory
   if($r.State -eq 'Completed'){$e.Success=$true;if($r.Progress -and $r.Progress.PSObject.Properties['files_new']){$e.CopiedFiles=[long]$r.Progress.files_new+[long]$r.Progress.files_changed;$e.CopiedBytes=[long]$r.Progress.data_added}}
   else{$e.Error=[string]$r.Error}
  }
 }catch{$e.Error=$_.Exception.Message}
 if(-not $e.Success -and -not $e.Error){$e.Error="The tool ended with exit code $($p.ExitCode)"}
 # A verification of an existing backup does not make the backup newer.
 if($s.Purpose -eq 'Verify'){$e.Kind=$s.Kind+'Check'}
 $p.Dispose()
 Add-CenterHistory ([pscustomobject]$e)
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
Export-ModuleMember -Function Get-CenterHardware,Get-CenterLoadPresets,Get-CenterLoad,Set-CenterRunPriority,Set-CenterPaths,Get-CenterPaths,Read-CenterProfiles,Save-CenterProfiles,Get-CenterProfile,Get-CenterDrive,Get-CenterCandidateDrives,
 New-CenterProfile,Remove-CenterProfile,Add-CenterSource,Remove-CenterSource,Read-CenterJob,Save-CenterJob,Get-CenterSourceKinds,Sync-CenterJob,
 Add-CenterHistory,Get-CenterHistory,Get-LastSuccess,Get-FreshnessState,Format-CenterAge,Get-CenterFreshness,
 Get-CenterSteps,Start-CenterStep,Complete-CenterStep,Get-CenterStaleProfiles
