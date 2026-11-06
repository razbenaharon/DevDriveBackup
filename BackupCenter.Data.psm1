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
  $script:Paths=[pscustomobject]@{Profiles=(Join-Path $Root 'profiles.local.json');Jobs=(Join-Path $Root 'jobs');History=(Join-Path $Root 'history.jsonl');Keys=(Join-Path $Root 'keys');Documents=(Join-Path $Root 'documents');DriveCheck=(Join-Path $Root 'drive-check');Appearance=(Join-Path $Root 'appearance.json')}
 }else{
  $app=Join-Path $env:LOCALAPPDATA 'DevDriveMirror'
  $script:Paths=[pscustomobject]@{Profiles=(Join-Path $script:ToolRoot 'profiles.local.json');Jobs=(Join-Path $script:ToolRoot 'jobs');History=(Join-Path $app 'center\history.jsonl');Keys=$app;Documents=(Join-Path $env:USERPROFILE 'Backup Center recovery keys');DriveCheck=(Join-Path $app 'drive-check');Appearance=(Join-Path $app 'center\appearance.json')}  # local, not a synced Documents folder
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

$script:VolumeCache=$null
function Get-CenterVolumes {
 # Listing the volumes takes about a second; one refresh of the window asks several times, so the list
 # is reused for 3 seconds. Plugging a drive in or out shows up on the next refresh.
 if(-not $script:VolumeCache -or ((Get-Date)-$script:VolumeCache.At).TotalSeconds -gt 3){
  $script:VolumeCache=[pscustomobject]@{At=Get-Date;List=@(Get-Volume -ErrorAction SilentlyContinue)}
 }
 $script:VolumeCache.List
}
function Get-CenterDrive([string]$VolumeId) {
 # The drive of a profile, or Connected=$false when it is not plugged in.
 $v=@(Get-CenterVolumes|Where-Object {$_.UniqueId -eq $VolumeId -and $_.DriveLetter})
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
 # A name is taken when another source of this drive has it, or its plain copy or versions folder
 # is already on the drive (an earlier source's copy is never shared). The label is compared by its
 # safe name, so a second folder with the same label gets a new name instead of looping forever.
 $taken={param($n)@($profile.Sources|Where-Object {$_.MirrorFolder -ieq $n+'-Mirror' -or (Get-SafeName $_.Label) -ieq $n}).Count -or ($drive.Connected -and ((Test-Path -LiteralPath ($drive.Letter+':\'+$n+'-Versions')) -or (Test-Path -LiteralPath ($drive.Letter+':\'+$n+'-Mirror'))))}
 $used={param($m)@($profile.Sources|Where-Object {$_.MirrorFolder -ieq $m}).Count -gt 0}
 if($MirrorFolder -and (& $used $MirrorFolder)){throw "The plain copy folder $MirrorFolder is already used by another source of this drive"}
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
function Save-CenterJob($Job,[string]$ConfigPath,[scriptblock]$Update) {
 # Writes under the job's run lock (as Backup-Worker.ps1 and Set-BackupDestination.ps1 take it) after
 # reading the file again, so a password change running elsewhere keeps its new recovery-key location.
 # With -Update the change is made to that fresh copy instead of writing $Job.
 $key={param($j)if($j -and $j.PSObject.Properties['PasswordDpapiPath'] -and $j.PasswordDpapiPath){[IO.Path]::GetFullPath([string]$j.PasswordDpapiPath)}else{''}}
 $keyPath=if(Test-Path -LiteralPath $ConfigPath){& $key (Read-CenterJob $ConfigPath)}else{& $key $Job}
 $lock=$null
 if($keyPath){
  New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($keyPath)) -Force|Out-Null
  for($i=0;-not $lock;$i++){try{$lock=[IO.File]::Open($keyPath+'.run.lock',[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)}catch [IO.IOException]{if($i -ge 30){throw 'This source is busy: a backup, check, restore or password change is using it. Try again when it has finished.'};Start-Sleep -Milliseconds 100}}
 }
 try{
  $fresh=if(Test-Path -LiteralPath $ConfigPath){Read-CenterJob $ConfigPath}else{$null}
  if($fresh -and (& $key $fresh) -ine $keyPath){throw 'The password settings of this source changed while saving. Try again.'}
  if($Update){if(-not $fresh){throw "Job file not found: $ConfigPath"};[void](& $Update $fresh);$Job=$fresh}
  elseif($fresh){
   if((& $key $Job) -ine $keyPath){throw 'The password settings of this source changed elsewhere. Close and reopen Backup Center.'}
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

function Sync-CenterJob($Profile,$Source,$Load=(Get-CenterLoad $Profile)) {
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
 if(& $apply (Read-CenterJob $Source.ConfigPath)){Save-CenterJob $null $Source.ConfigPath -Update $apply}
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

# --- Other work on this computer -----------------------------------------------------------
function Get-CenterAgentActivity {
 # Are AI coding sessions (Claude Code, Codex) still working? A backup taken while they edit files
 # catches them half-way. A working session appends to its conversation file every few seconds, which
 # is a reliable sign: the app's own "running" flag and the list of open programs are not (helper
 # programs stay open while idle). A Codex program that is running also counts as work.
 param([int]$QuietMinutes=10,[datetime]$Now=(Get-Date),
  [string]$ClaudeRoot=(Join-Path $env:USERPROFILE '.claude\projects'),
  [string]$CodexRoot=(Join-Path $env:USERPROFILE '.codex\sessions'),
  [switch]$SkipProcesses)
 $cut=$Now.AddMinutes(-$QuietMinutes);$recent=@();$newest=$null
 foreach($root in @($ClaudeRoot,$CodexRoot)){
  if(-not $root -or -not(Test-Path -LiteralPath $root -PathType Container)){continue}
  foreach($f in [IO.Directory]::EnumerateFiles($root,'*.jsonl',[IO.SearchOption]::AllDirectories)){
   $t=[IO.File]::GetLastWriteTime($f)
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
 $codex=if($SkipProcesses){0}else{@(Get-Process -Name codex -ErrorAction SilentlyContinue).Count}
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
   else{$keep=Get-CenterKeepDeleted $Profile;if($keep -gt 0){$a+=@('-MoveExtras','-KeepRecovery',[string]$keep)}}
   [pscustomobject]@{SourceId=$s.Id;Label=$s.Label;Kind='Mirror';Purpose=$Purpose;FilePath=$pwsh;Arguments=$a;RunDirectory=$null;Priority=$load.Priority}
  }
  if($kinds.Versioned){
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
function Complete-CenterStep($Running,[string]$ProfileId) {
 # Turns a finished tool run into one history entry.
 $p=$Running.Process;$p.WaitForExit()
 $stdout=$Running.Out.GetAwaiter().GetResult();$stderr=$Running.Err.GetAwaiter().GetResult()
 if($Running.OutputPath){[IO.File]::WriteAllText($Running.OutputPath,$stdout+"`n--- errors ---`n"+$stderr)}
 $s=$Running.Step
 $e=[ordered]@{ProfileId=$ProfileId;SourceId=$s.SourceId;Label=$s.Label;Kind=$s.Kind;Purpose=$s.Purpose;Started=$Running.Started.ToString('o');Finished=(Get-Date).ToString('o')
  Minutes=[math]::Round(((Get-Date)-$Running.Started).TotalMinutes,1);Success=$false;Error=$null;CopiedFiles=$null;CopiedBytes=$null;CheckedFiles=$null;Details=$null;Note=$null}
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
   # The automatic clean-up of old versions: a note, never a failed backup.
   if($r.PSObject.Properties['Retention'] -and $r.Retention){
    $e.Note=if($r.Retention.PSObject.Properties['Error'] -and $r.Retention.Error){'Backed up, but old versions were not cleaned up: '+$r.Retention.Error}
     elseif($r.Retention.Removed -gt 0){"Deleted $($r.Retention.Removed) old versions; $($r.Retention.Kept) kept."}else{"No old versions to delete; $($r.Retention.Kept) kept."}
   }
  }
 }catch{$e.Error=$_.Exception.Message}
 if(-not $e.Success -and -not $e.Error){$e.Error="The tool ended with exit code $($p.ExitCode)"}
 # A verification of an existing backup does not make the backup newer.
 if($s.Purpose -eq 'Verify'){$e.Kind=$s.Kind+'Check'}
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
 Add-CenterHistory,Get-CenterHistory,Get-LastSuccess,Get-FreshnessState,Format-CenterAge,Get-CenterFreshness,
 Get-CenterSteps,Start-CenterStep,Complete-CenterStep,Get-CenterStaleProfiles,Get-CenterAgentActivity,Get-CenterSessionTitle
