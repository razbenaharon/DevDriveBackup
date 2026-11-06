#Requires -Version 7.2
# Point the versioned backup at a new destination drive and tune speed settings for it.
# Without -Apply it only inspects, measures and recommends; nothing is written to the configuration.
param(
 [Parameter(Mandatory)][ValidatePattern('^[A-Za-z]$')][string]$DestinationDrive,
 [string]$ConfigPath=(Join-Path $PSScriptRoot 'backup.local.json'),
 [ValidateRange(256,8192)][int]$BenchmarkMiB=4096,
 [switch]$SkipBenchmark,
 [switch]$Apply
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'Backup.Status.psm1') -Force
# Without a configuration (a first drive, or a speed test only) the source checks are skipped.
$config=if(Test-Path -LiteralPath $ConfigPath){Get-Content -LiteralPath $ConfigPath -Raw|ConvertFrom-Json}else{$null}
if($Apply -and -not $config){throw "Configuration not found: $ConfigPath"}
$letter=$DestinationDrive.ToUpperInvariant()

# --- Identify the destination and refuse unsafe targets ---------------------------------------
$volume=Get-Volume -DriveLetter $letter
$disk=Get-Partition -DriveLetter $letter|Get-Disk
if($config){
 if($volume.UniqueId -eq $config.SourceVolumeId){throw 'The destination is the source volume'}
 $sourceDisk=Get-Partition -DriveLetter $config.Source.Substring(0,1)|Get-Disk
 if($disk.Number -eq $sourceDisk.Number){throw 'The destination is on the same disk as the source'}
 if($sourceDisk.BusType -eq 'File Backed Virtual' -and $sourceDisk.Location -match '^([A-Za-z]):\\'){
  # A VHDX Dev Drive lives on another disk; a backup on that same physical disk fails together with it.
  $hostDisk=Get-Partition -DriveLetter $Matches[1]|Get-Disk
  if($disk.Number -eq $hostDisk.Number){throw "The destination is on the physical disk that holds the Dev Drive file ($($sourceDisk.Location))"}
 }
}
$physical=Get-PhysicalDisk|Where-Object {[string]$_.DeviceId -eq [string]$disk.Number}|Select-Object -First 1
$media=if($physical){[string]$physical.MediaType}else{'Unknown'}
$health=if($physical){[string]$physical.HealthStatus}else{'Unknown'}
$cluster=(Get-CimInstance Win32_Volume -Filter "DriveLetter='$($letter):'").BlockSize

$warnings=[Collections.Generic.List[string]]::new()
$blockers=[Collections.Generic.List[string]]::new()
if($volume.FileSystem -ne 'NTFS'){$warnings.Add("File system is $($volume.FileSystem). NTFS is recommended (journaled, safer if unplugged mid-write). Reformatting erases the drive; do it yourself only if it holds nothing you need.")}
if($health -notin @('Healthy','Unknown')){$blockers.Add("Windows reports disk health '$health'. Do not use this drive.")}
if($volume.SizeRemaining -lt 100GB){$warnings.Add(('Only {0:N1} GiB free.' -f ($volume.SizeRemaining/1GB)))}

# --- Measure the link and the drive ------------------------------------------------------------
$audit=Join-Path $env:LOCALAPPDATA ('DevDriveMirror\audit\destination-'+$letter+'-'+(Get-Date -Format 'yyyyMMdd-HHmmss'))
$measure=Join-Path $PSScriptRoot 'Measure-BackupDisk.ps1'
if($SkipBenchmark){& $measure -Drive $letter -LinkOnly -OutputDirectory $audit|Out-Null}
else{
 if($volume.SizeRemaining -lt 3*$BenchmarkMiB*1MB){throw 'Not enough free space for the benchmark file'}
 & $measure -Drive $letter -SizeMiB $BenchmarkMiB -OutputDirectory $audit
}
$link=Get-Content -LiteralPath (Join-Path $audit 'usb-speed.json') -Raw|ConvertFrom-Json
$bench=$null;if(-not $SkipBenchmark){$bench=(Get-Content -LiteralPath (Join-Path $audit 'disk-benchmark.json') -Raw|ConvertFrom-Json).Benchmark}
$linkText=if($link.PSObject.Properties['Speed']){[string]$link.Speed}else{'n/a: '+[string]$link.Error}
if($disk.BusType -eq 'USB' -and $link.PSObject.Properties['Speed']){
 if(-not $link.SuperSpeedActive){$blockers.Add("The drive is connected at $($link.Speed) (USB 2 speed). Use a USB 3 port and the cable that came with the drive, connected directly rather than through a hub.")}
 elseif($link.Speed -notmatch 'SuperSpeedPlus'){$warnings.Add('Connected at 5 Gbit/s (about 450 MB/s at most). If the drive supports 10 Gbit/s or more, connect it to a faster port (USB 3.2 Gen 2, USB4 or Thunderbolt) if this computer has one.')}
}
$writeMBps=if($bench){[double]$bench.WriteMBps}else{0}
if($bench -and $writeMBps -lt 80){$warnings.Add(('Measured write is only {0:N0} MB/s. Check the port, cable and drive.' -f $writeMBps))}

# --- Recommend settings ------------------------------------------------------------------------
# Restic compresses and encrypts on the CPU, so a fast SSD makes the CPU the limit, not the drive.
$fastDrive=($media -eq 'SSD') -or ($writeMBps -ge 250)
$rec=if($fastDrive){[ordered]@{Profile='Fast';RateMBps=0;MemoryMiB=2048;CpuThreads=[math]::Min(4,[Environment]::ProcessorCount);ReadConcurrency=4;PackMiB=32;BackendConnections=4}}
     else{[ordered]@{Profile='Balanced';RateMBps=45;MemoryMiB=1024;CpuThreads=[math]::Min(2,[Environment]::ProcessorCount);ReadConcurrency=2;PackMiB=16;BackendConnections=1}}

$report=[ordered]@{
 Drive="$($letter):";Model=[string]$disk.FriendlyName;BusType=[string]$disk.BusType;MediaType=$media;Health=$health
 SizeGiB=[math]::Round($disk.Size/1GB,1);FreeGiB=[math]::Round($volume.SizeRemaining/1GB,1);FileSystem=[string]$volume.FileSystem;ClusterBytes=$cluster
 Link=$linkText
 WriteMBps=if($bench){[math]::Round($bench.WriteMBps)}else{$null};ReadMBps=if($bench){[math]::Round($bench.ReadMBps)}else{$null}
 Recommended=$rec;Warnings=@($warnings);Blockers=@($blockers);AuditFolder=$audit
}
$report|ConvertTo-Json -Depth 5|Set-Content -LiteralPath (Join-Path $audit 'destination-summary.json')
$report|ConvertTo-Json -Depth 5
if($bench){Write-Output 'Note: the benchmark is short. Some SSDs slow down after their fast cache fills during a long first backup; the live speed in the manager shows that.'}

if(-not $Apply){Write-Output 'Inspection only. Re-run with -Apply to use this drive and these settings.';return}
if($blockers.Count){throw 'Not applied: '+($blockers -join ' ')}

# --- Apply -------------------------------------------------------------------------------------
$lockPath=$config.PasswordDpapiPath+'.run.lock'
New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($lockPath)) -Force|Out-Null
$lock=[IO.File]::Open($lockPath,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
try{
 $fresh=Get-Content -LiteralPath $ConfigPath -Raw|ConvertFrom-Json
 $repoConfig=Join-Path ($letter+':\') (Join-Path $fresh.RepositoryFolder 'config')
 if($fresh.DestinationVolumeId -cne $volume.UniqueId){
  if(Test-Path -LiteralPath $repoConfig){throw "$($letter):\$($fresh.RepositoryFolder) already holds a repository that this configuration does not know. Choose another RepositoryFolder or inspect it first."}
  # A new repository gets its own password and recovery file; the previous ones stay valid for the old drive.
  $keyId=[guid]::NewGuid().ToString('N')
  $fresh.PasswordDpapiPath=Join-Path $env:LOCALAPPDATA ('DevDriveMirror\'+$keyId+'.dpapi')
  $fresh.RecoveryKeyPath=Join-Path (Join-Path $env:USERPROFILE $(if(Test-Path -LiteralPath (Join-Path $env:USERPROFILE 'Backup Center recovery keys')){'Backup Center recovery keys'}else{'DevDriveBackup recovery keys'})) ('DevDrive-'+$keyId+'-recovery-key.txt')
  $fresh.DestinationVolumeId=$volume.UniqueId
 }
 foreach($k in $rec.Keys){$fresh|Add-Member -NotePropertyName $k -NotePropertyValue $rec[$k] -Force}
 New-Item -ItemType Directory -Path (Join-Path $env:LOCALAPPDATA 'DevDriveMirror') -Force|Out-Null
 Copy-Item -LiteralPath $ConfigPath -Destination (Join-Path $env:LOCALAPPDATA ('DevDriveMirror\backup.local.before-destination-'+(Get-Date -Format 'yyyyMMdd-HHmmss')+'.json'))
 [void](Write-BackupStatus $fresh $ConfigPath)
}finally{$lock.Dispose()}
Write-Output "Applied. Backups now go to $($letter):\$($config.RepositoryFolder) with the $($rec.Profile) profile."
Write-Output 'The first backup creates a new password and a recovery-key file in Documents. Copy that key to a password manager or a safe place off this computer.'
