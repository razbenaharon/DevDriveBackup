#Requires -Version 7.2
# DevDriveBackup data layer: profiles, sources, freshness, and real runs of both tools
# against a disposable source, a disposable data folder and uniquely named folders on the
# destination drive. The configured real profiles, history and backups are not touched.
param([Parameter(Mandatory)][ValidatePattern('^[A-Za-z]$')][string]$DestinationDrive)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'DevDriveBackup.Data.psm1') -Force
function Assert($ok,[string]$message){if(-not $ok){throw "FAIL $message"};Write-Output "PASS $message"}
function Assert-Throws([scriptblock]$Block,[string]$Like,[string]$message){
 try{& $Block;throw "FAIL $message (no error)"}catch{if($_.Exception.Message -like "FAIL*"){throw};if($_.Exception.Message -notlike $Like){throw "FAIL $message (got: $($_.Exception.Message))"}}
 Write-Output "PASS $message"
}

$id=[guid]::NewGuid().ToString('N').Substring(0,10)
$dataRoot=Join-Path ([IO.Path]::GetTempPath()) ('dev-drive-backup-test-'+$id)
$source=Join-Path $PSScriptRoot ('.temporary-worker-test-center-'+$id)
New-Item -ItemType Directory -Path $dataRoot,(Join-Path $source 'work\node_modules\x'),(Join-Path $source 'notes') -Force|Out-Null
[IO.File]::WriteAllText((Join-Path $source 'work\עברית [1].txt'),'first')
[IO.File]::WriteAllText((Join-Path $source 'work\node_modules\x\skip.js'),'rebuildable')
[IO.File]::WriteAllBytes((Join-Path $source 'notes\data.bin'),[Security.Cryptography.RandomNumberGenerator]::GetBytes(2MB))
[void](Set-CenterPaths $dataRoot)
$dest=Get-Volume -DriveLetter $DestinationDrive
$label='CenterTest'+$id
$created=@()
try{
 $data=Read-CenterProfiles
 Assert ($data.Profiles.Count -eq 0) 'a new data folder has no profiles'
 $empty=@(Get-CenterHistory)
 Assert ($null -ne $empty -and @($empty).Count -eq 0) 'history without a file is an empty list, not nothing'
 Set-StrictMode -Version Latest
 Assert ((Get-CenterFreshness ([pscustomobject]@{ReminderDays=7;Sources=@()}) $empty).State -eq 'Nothing selected') 'an empty history does not break freshness'
 Set-StrictMode -Off
 $hw=Get-CenterHardware;$levels=Get-CenterLoadPresets $hw
 Assert ($levels.Light.CpuThreads -le $levels.Balanced.CpuThreads -and $levels.Balanced.CpuThreads -le $levels.Maximum.CpuThreads -and $levels.Maximum.CpuThreads -le $hw.Threads) 'load levels grow and never use more threads than this computer has'
 $custom=Get-CenterLoad ([pscustomobject]@{Load='Custom';CustomLoad=[pscustomobject]@{CpuThreads=999;MemoryMiB=1;CopyThreads=0;Priority='Normal'}}) $hw
 Assert ($custom.CpuThreads -eq $hw.Threads -and $custom.MemoryMiB -eq 512 -and $custom.CopyThreads -eq 1) 'custom load values are kept within safe limits'
 $p=New-CenterProfile $data 'Test drive' $dest.UniqueId 'Test model' 100
 Assert-Throws {New-CenterProfile $data 'Again' $dest.UniqueId} '*already has a profile*' 'one profile per drive'
 Save-CenterProfiles $data
 $data=Read-CenterProfiles;$p=Get-CenterProfile $data $p.Id
 Assert ($p.Name -eq 'Test drive' -and @($p.Sources).Count -eq 0) 'profile survives save and reload'

 $s=Add-CenterSource -Data $data -ProfileId $p.Id -Path $source -Label $label -DefaultMode Both
 Save-CenterProfiles $data
 $created+=Join-Path ($DestinationDrive+':\') $s.MirrorFolder
 $job=Read-CenterJob $s.ConfigPath
 $created+=Join-Path ($DestinationDrive+':\') $job.RepositoryFolder
 Assert (@($job.Choices).Count -eq 2 -and @($job.Choices|Where-Object {$_.Mode -ne 'Both'}).Count -eq 0) 'new source lists its top-level folders with the chosen mode'
 Assert ($job.RecoveryKeyPath.StartsWith($dataRoot)) 'test keys stay in the disposable data folder'
 Assert-Throws {Add-CenterSource -Data $data -ProfileId $p.Id -Path (Join-Path $source 'work')} '*Overlaps*' 'a folder inside an existing source is refused'
 Assert-Throws {Add-CenterSource -Data $data -ProfileId $p.Id -Path ($DestinationDrive+':\')} '*backup drive itself*' 'the backup drive cannot be a source'
 $junction=Join-Path $dataRoot 'link';New-Item -ItemType Junction -Path $junction -Target $source|Out-Null
 Assert-Throws {Add-CenterSource -Data $data -ProfileId $p.Id -Path $junction} '*shortcut*' 'a junction cannot be a source'

 $kinds=Get-CenterSourceKinds $s
 Assert ($kinds.Mirror -and $kinds.Versioned) 'Both uses the plain copy and versions'
 $now=Get-Date
 $f=Get-CenterFreshness $p @() $now
 Assert ($f.State -eq 'Never' -and -not $f.LastComplete) 'never backed up before the first run'
 $fake=@([pscustomobject]@{ProfileId=$p.Id;SourceId=$s.Id;Kind='Mirror';Success=$true;Finished=$now.AddHours(-2).ToString('o')})
 Assert ((Get-CenterFreshness $p $fake $now).State -eq 'Never') 'a source using Both is not complete with only its plain copy'
 $fake+=[pscustomobject]@{ProfileId=$p.Id;SourceId=$s.Id;Kind='Versioned';Success=$true;Finished=$now.AddDays(-3).ToString('o')}
 $f=Get-CenterFreshness $p $fake $now
 Assert ($f.State -eq 'OK' -and ([datetime]$f.LastComplete) -lt $now.AddDays(-2)) 'freshness follows the older of the two kinds'
 Assert ((Get-FreshnessState $now.AddDays(-8) 7 $now) -eq 'Stale' -and (Get-FreshnessState $now.AddHours(-1) 7 $now) -eq 'Fresh') 'old and fresh thresholds'
 Assert ((Format-CenterAge $now.AddHours(-5) $now) -eq '5 hours ago' -and (Format-CenterAge $now.AddDays(-3) $now) -eq '3 days ago') 'ages read naturally'

 Sync-CenterJob $p $s
 $versionArgs={param($Purpose)@((@(Get-CenterSteps $p @() $Purpose)|Where-Object {$_.Kind -eq 'Versioned'})[0].Arguments)}
 Assert (-not (Get-CenterVersionRetention $p).Enabled -and '-KeepDays' -notin (& $versionArgs 'Backup')) 'by default every version is kept'
 $p|Add-Member -NotePropertyName VersionRetention -NotePropertyValue ([pscustomobject]@{Days=7;Weeks=4;Months=3}) -Force
 $va=& $versionArgs 'Backup'
 Assert ($va[[array]::IndexOf($va,'-KeepDays')+1] -eq '7' -and $va[[array]::IndexOf($va,'-KeepWeeks')+1] -eq '4' -and $va[[array]::IndexOf($va,'-KeepMonths')+1] -eq '3' -and '-KeepDays' -notin (& $versionArgs 'Verify')) 'Keep versions passes 7 days / 4 weeks / 3 months to a versioned backup, never to a check'
 Assert ((Format-CenterVersionRetention (Get-CenterVersionRetention $p)) -eq '7 d / 4 w / 3 m') 'the overview shows the rule briefly'
 $p.VersionRetention=[pscustomobject]@{Days=0;Weeks=0;Months=0}
 function Invoke-All([string]$Purpose){
  $results=@()
  foreach($step in @(Get-CenterSteps $p @() $Purpose)){
   $r=Start-CenterStep $step (Join-Path $dataRoot ('step-'+[guid]::NewGuid().ToString('N')+'.log'))
   $results+=Complete-CenterStep $r $p.Id
  }
  $results
 }
 $first=@(Invoke-All 'Backup')
 Assert ($first.Count -eq 2 -and @($first|Where-Object {-not $_.Success}).Count -eq 0) ('first backup: plain copy and versions succeed '+(($first|ForEach-Object {$_.Error}) -join ' '))
 $mirror=$first|Where-Object {$_.Kind -eq 'Mirror'}
 Assert ($mirror.CopiedFiles -eq 2 -and $mirror.CheckedFiles -eq 2) 'plain copy copied and verified the two regular files'
 Assert (Test-Path -LiteralPath (Join-Path ($DestinationDrive+':\') ($s.MirrorFolder+'\work\עברית [1].txt'))) 'Hebrew and bracket filename in the plain copy'
 Assert (-not(Test-Path -LiteralPath (Join-Path ($DestinationDrive+':\') ($s.MirrorFolder+'\work\node_modules')))) 'rebuildable folder skipped'
 Assert (Test-Path -LiteralPath $job.RecoveryKeyPath) 'first versioned backup created a recovery key'
 $f=Get-CenterFreshness $p @(Get-CenterHistory)
 Assert ($f.State -eq 'Fresh') 'profile is fresh after a complete backup'

 $second=@(Invoke-All 'Backup')
 Assert (($second|Where-Object {$_.Kind -eq 'Mirror'}).CopiedFiles -eq 0) 'second plain copy copies nothing unchanged'
 $check=@(Invoke-All 'Verify')
 Assert (@($check|Where-Object {$_.Success -and $_.Kind -in @('MirrorCheck','VersionedCheck')}).Count -eq 2) 'content checks of both kinds succeed'
 $before=(Get-CenterFreshness $p @(Get-CenterHistory)).LastComplete
 Assert ($before -eq (Get-CenterFreshness $p (@(Get-CenterHistory|Where-Object {$_.Kind -notlike '*Check'}))).LastComplete) 'a content check does not count as a newer backup'

 $job=Read-CenterJob $s.ConfigPath;($job.Choices|Where-Object {$_.Path -eq 'notes'}).Mode='Skip';$job.DefaultMode='Skip';Save-CenterJob $job $s.ConfigPath
 ($job.Choices|Where-Object {$_.Path -eq 'work'}).Mode='Mirror';Save-CenterJob $job $s.ConfigPath
 $kinds=Get-CenterSourceKinds $s
 Assert ($kinds.Mirror -and -not $kinds.Versioned) 'changing folder modes changes which tools run'
 Assert (@(Get-CenterSteps $p @() 'Backup').Count -eq 1) 'only the plain copy runs after the change'
 $plain=@((Get-CenterSteps $p @() 'Backup')[0].Arguments)
 Assert ((Get-CenterKeepDeleted $p) -eq 0 -and '-MoveExtras' -notin $plain) 'by default deleted files stay in the plain copy'
 $p|Add-Member -NotePropertyName KeepDeleted -NotePropertyValue 5 -Force
 $plain=@((Get-CenterSteps $p @() 'Backup')[0].Arguments);$checkArgs=@((Get-CenterSteps $p @() 'Verify')[0].Arguments)
 Assert ('-MoveExtras' -in $plain -and $plain[[array]::IndexOf($plain,'-KeepRecovery')+1] -eq '5' -and '-MoveExtras' -notin $checkArgs) 'Keep deleted moves deleted files aside on a backup, never on a content check'
 $p.KeepDeleted=0

 Remove-CenterSource $data $p.Id $s.Id
 Assert (@((Get-CenterProfile $data $p.Id).Sources).Count -eq 0 -and (Test-Path -LiteralPath $s.ConfigPath)) 'removing a source keeps its job file'
 Remove-CenterProfile $data $p.Id
 Assert ($data.Profiles.Count -eq 0) 'removing a profile forgets it'
 Write-Output 'All DevDriveBackup tests passed.'
}finally{
 foreach($c in $created){if(Test-Path -LiteralPath $c){Get-ChildItem -LiteralPath $c -Recurse -Force -File|ForEach-Object {$_.IsReadOnly=$false};[IO.Directory]::Delete($c,$true)}}
 $marker=Join-Path $env:LOCALAPPDATA ('DevDriveMirror\fast-mirror\last-success-'+((Get-Volume -DriveLetter $DestinationDrive).UniqueId -replace '[^A-Za-z0-9-]+','_').Trim('_')+'-'+$label+'-Mirror.json')
 if(Test-Path -LiteralPath $marker){Remove-Item -LiteralPath $marker}
 $link=Join-Path $dataRoot 'link';if(Test-Path -LiteralPath $link){[IO.Directory]::Delete($link)}  # the junction only, never its target
 foreach($d in @($source,$dataRoot)){if(Test-Path -LiteralPath $d){Get-ChildItem -LiteralPath $d -Recurse -Force -File -ErrorAction SilentlyContinue|ForEach-Object {$_.IsReadOnly=$false};[IO.Directory]::Delete($d,$true)}}
}
