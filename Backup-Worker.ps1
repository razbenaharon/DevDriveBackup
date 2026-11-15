#Requires -Version 7.2
param(
 [Parameter(Mandatory)][string]$ConfigPath,
 [ValidateSet('Backup','Preview','Check','Snapshots','Files','Restore','Forget','ExportKey','ChangePassword','ResumePasswordChange')][string]$Action='Backup',
 [string]$RunDirectory,
 [string]$Snapshot='latest',
 [string]$RestoreTarget,
 [string[]]$RestoreInclude=@(),
 [switch]$ReadAllData,
 [switch]$ForceRead,
 [string]$RequestPath,
 # Backup only, Keep versions: afterwards keep the KeepLast newest complete versions and the newest
 # complete version of each month for KeepMonths months, and delete the rest (both 0: keep every
 # version). The rule is Get-VersionRetentionPlan in Backup.History.psm1.
 [ValidateRange(0,10000)][int]$KeepLast=0,
 [ValidateRange(0,240)][int]$KeepMonths=0,
 # Backup only: work the clean-up out as usual and report it, but delete nothing and free no space.
 [switch]$RetentionPreview,
 # Backup only, the first clean-up after the user approved a preview: a UTF-8 text file with one full
 # version ID a line (blank lines ignored; spaces around an ID and capital letters make no difference).
 # The clean-up is planned as usual and then deletes only the versions that are both in its plan and in
 # this file; whatever else the plan would delete stays for the next clean-up (Retention.Deferred). The
 # file only narrows: a listed version that the rule keeps, or that no longer exists, is not deleted. A
 # file that is missing, unreadable, empty or holds anything but full IDs deletes nothing
 # (Retention.Error), never the whole plan. With -RetentionPreview the preview wins and the file is not used.
 [string]$RetentionApprovedFile,
 # Backup only: the versions folder is gone although this source was backed up before (see
 # RepositoryMissing below), and the user chose to start a new, empty one. Without it such a backup
 # stops and changes nothing. Not needed for a first-ever backup; ignored while the repository exists.
 [switch]$CreateNewRepository,
 # The earlier rule (one version a day / a week). Still accepted only so that a run started by an older
 # window fails with a plain message instead of applying another rule than the one that was chosen.
 [int]$KeepDays=0,
 [int]$KeepWeeks=0,
 # Test suite only: an existing folder under the temporary directory that stands in for the backup
 # drive (repository, engine cache, run folders), so the tests need no second drive and never touch
 # the real state. A real run never passes it and keeps every volume check.
 [string]$TestRoot
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'Backup.Status.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Backup.History.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Backup.Security.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Backup.Selection.psm1') -Force
if($TestRoot){
 $TestRoot=[IO.Path]::GetFullPath($TestRoot).TrimEnd('\')
 if(-not ($TestRoot+'\').StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase) -or -not(Test-Path -LiteralPath $TestRoot -PathType Container)){throw 'TestRoot is for the test suite only: an existing folder under the temporary directory'}
}
if(-not $RunDirectory){$RunDirectory=Join-Path $(if($TestRoot){$TestRoot}else{Join-Path $env:LOCALAPPDATA 'DevDriveMirror'}) ('runs\'+(Get-Date -Format 'yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N'))}
New-Item -ItemType Directory -Path $RunDirectory -Force | Out-Null
# BackupSummary: restic's own summary of the backup step (Progress ends up holding the summary of the
# check that follows). Partial: the backup saved a version but could not read every file. LockReleased:
# nothing, or the locks of an earlier run that this run removed before trying a step again (Run-Engine).
# RepositoryMissing: the run stopped because the versions folder holds no repository although this source
# was backed up before (its protected password file exists): the folder was renamed, moved, deleted or
# emptied. Nothing is created then; only a Backup with -CreateNewRepository starts a new one.
# RepositoryCreated: this run created the repository (a first-ever backup, or -CreateNewRepository; Note
# then says that the earlier versions are not in it).
$script:lockExamined=$false
$script:status=[ordered]@{State='Starting';Action=$Action;WorkerPid=$PID;StartedUtc=[DateTime]::UtcNow.ToString('o');UpdatedUtc='';Progress=$null;MemoryMiB=0;PeakMemoryMiB=0;CpuPercent=0;Error=$null;Snapshot=$null;RunDirectory=$RunDirectory;BackupSummary=$null;Partial=$false;LockReleased=$null;RepositoryMissing=$false;RepositoryCreated=$false;Note=$null}
function Save-Status {
 $script:status.UpdatedUtc=[DateTime]::UtcNow.ToString('o')
 [void](Write-BackupStatus $script:status (Join-Path $RunDirectory 'status.json') -BestEffort)
}
function Assert-PlainAncestors([string]$Path) {
 $p=[IO.Path]::GetFullPath($Path)
 while($p){if(Test-Path -LiteralPath $p){if((Get-Item -LiteralPath $p -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw "Linked repository/root/restore path refused: $p"}};$parent=[IO.Directory]::GetParent($p);if(-not $parent){break};$p=$parent.FullName}
}
function Invoke-EngineStep([string[]]$EngineArguments,[string]$Stage,[string]$InputSecret) {
 $script:status.State=$Stage;Save-Status
 $psi=[Diagnostics.ProcessStartInfo]::new($script:engine);$psi.UseShellExecute=$false;$psi.CreateNoWindow=$true;$psi.RedirectStandardOutput=$true;$psi.RedirectStandardError=$true
 # Pruning needs at least two connections, whether it runs with forget or on its own.
 $connections=if(($Stage -in 'DeletingHistory','DeletingOldVersions' -and $EngineArguments -contains '--prune') -or $Stage -eq 'FreeingSpace'){[math]::Max(2,$script:backendConnections)}else{$script:backendConnections}
 foreach($a in @('-r',$script:repository,'--json','--cache-dir',$script:cache,'--pack-size',[string]$script:config.PackMiB,'--compression','auto','--limit-upload',[string][int]($script:config.RateMBps*1000000/1024),'--limit-download',[string][int]($script:config.RateMBps*1000000/1024),'-o',('local.connections='+$connections))+$EngineArguments){[void]$psi.ArgumentList.Add($a)}
 $psi.Environment['RESTIC_PASSWORD']=$script:password
 foreach($name in @('RESTIC_PASSWORD_FILE','RESTIC_PASSWORD_COMMAND','RESTIC_REPOSITORY_FILE','RESTIC_KEY_HINT')){[void]$psi.Environment.Remove($name)}
 $psi.RedirectStandardInput=$true
 $psi.StandardInputEncoding=[Text.UTF8Encoding]::new($false)
 $psi.Environment['GOMAXPROCS']=[string]$script:config.CpuThreads
 $psi.Environment['GOMEMLIMIT']=([int]($script:config.MemoryMiB*0.70)).ToString()+'MiB'
 $psi.Environment['RESTIC_PROGRESS_FPS']='0.5'
 $process=[Diagnostics.Process]::new();$process.StartInfo=$psi
 $job=[BackupMemoryJob]::new([long]$script:config.MemoryMiB*1MB)
 $output=[IO.StreamWriter]::new((Join-Path $RunDirectory ($Stage+'.jsonl')),$false,[Text.UTF8Encoding]::new($false))
 $lastCpu=0.0;$watch=[Diagnostics.Stopwatch]::StartNew();$lastSeconds=0.0;$lastSave=-5.0;$started=$false
 try {
  [void]$process.Start();$started=$true
  try{$job.Add($process);$process.PriorityClass=if($script:config.PSObject.Properties['Priority'] -and $script:config.Priority -in @('BelowNormal','Normal','Idle')){[string]$script:config.Priority}elseif($script:config.Profile -eq 'Fast'){'Normal'}else{'BelowNormal'}}catch{$process.Kill($true);throw}
  $errors=$process.StandardError.ReadToEndAsync();$lineTask=$process.StandardOutput.ReadLineAsync()
  if($PSBoundParameters.ContainsKey('InputSecret')){$process.StandardInput.WriteLine($InputSecret)}
  $process.StandardInput.Close()
  while($true){
   if($lineTask.Wait(200)){
    $line=$lineTask.Result
    if($null -eq $line){break}
    $output.WriteLine($line);$output.Flush()
    try{$event=$line|ConvertFrom-Json;if($event.message_type -eq 'status'){$script:status.Progress=$event};if($event.message_type -eq 'summary'){$script:status.Progress=$event;if($event.PSObject.Properties['snapshot_id']){$script:status.Snapshot=$event.snapshot_id}
     if($Stage -eq 'BackingUp'){$own=[ordered]@{};foreach($name in @('files_new','files_changed','data_added','total_files_processed','total_bytes_processed','snapshot_id')){$own[$name]=if($event.PSObject.Properties[$name]){$event.$name}else{$null}};$script:status.BackupSummary=$own}}}catch{}
    $lineTask=$process.StandardOutput.ReadLineAsync()
   }
   if($watch.Elapsed.TotalSeconds-$lastSave -ge 2){
    $process.Refresh();$script:status.MemoryMiB=[math]::Round($process.WorkingSet64/1MB,1);$script:status.PeakMemoryMiB=[math]::Max($script:status.PeakMemoryMiB,[math]::Round($process.PeakWorkingSet64/1MB,1))
    $cpu=$process.TotalProcessorTime.TotalSeconds;$sec=$watch.Elapsed.TotalSeconds
    if($sec -gt $lastSeconds){$script:status.CpuPercent=[math]::Round(100*($cpu-$lastCpu)/($sec-$lastSeconds)/[Environment]::ProcessorCount,1)}
    $lastSeconds=$sec;$lastCpu=$cpu;$lastSave=$sec;Save-Status
   }
  }
  $process.WaitForExit();$errorText=$errors.GetAwaiter().GetResult();[IO.File]::WriteAllText((Join-Path $RunDirectory ($Stage+'.errors.log')),$errorText)
  if($process.ExitCode -ne 0){
   $engineError=[InvalidOperationException]::new((Get-EngineFailureText $Stage $process.ExitCode))
   $engineError.Data['ExitCode']=$process.ExitCode;throw $engineError
  }
 }finally{if($started -and -not $process.HasExited){$process.Kill($true)};$output.Dispose();$job.Dispose();$process.Dispose()}
}
function Read-RepositoryLockIds([string]$Stage) {
 Invoke-EngineStep @('list','locks','--no-lock') $Stage
 @([IO.File]::ReadAllLines((Join-Path $RunDirectory ($Stage+'.jsonl')))|ForEach-Object {$_.Trim()}|Where-Object {$_})
}
function Clear-EndedLocks {
 # Reads every lock in the repository and removes them only when all of them were left by runs on this
 # computer that have ended (Get-LockReleaseDecision). Removing is left to restic's own "unlock", never
 # with --remove-all: it lets go of a lock of this computer whose process is gone, or of one that is
 # over 30 minutes old, and keeps every other one, so a lock goes only when both tests agree. Returns
 # the locks that are gone afterwards and, when none is, why. The worker's own run lock is held here.
 $found=@(foreach($id in @(Read-RepositoryLockIds 'ReadingLocks')){
  $record=$null;$process=$null
  if($id -cmatch '^[0-9a-f]{64}$'){try{Invoke-EngineStep @('cat','lock',$id,'--no-lock') 'ReadingLock';$record=Get-Content -LiteralPath (Join-Path $RunDirectory 'ReadingLock.jsonl') -Raw|ConvertFrom-Json}catch{$record=$null}}
  if($record -is [pscustomobject] -and $record.PSObject.Properties['pid']){$process=Get-LockProcess $record.pid}
  [pscustomobject]@{Id=$id;Lock=$record;Process=$process}
 })
 # restic records the computer's DNS host name, as this returns it.
 $decision=Get-LockReleaseDecision $found ([Net.Dns]::GetHostName())
 if(-not $decision.Release){return [pscustomobject]@{Released=@();Reason=$decision.Reason}}
 Invoke-EngineStep @('unlock') 'ReleasingLock'
 $left=@(Read-RepositoryLockIds 'ReadingLocksAgain')
 $gone=@($decision.Locks|Where-Object {$_.Id -cnotin $left})
 $kept=@($decision.Locks|Where-Object {$_.Id -cin $left})
 [pscustomobject]@{Released=$gone;Reason=$(if($kept.Count){"the run that made the lock has ended, but restic still sees a process under its number ($($kept[0].Pid)) and keeps the lock until $(([DateTimeOffset]::Parse($kept[0].CreatedUtc,[Globalization.CultureInfo]::InvariantCulture)).ToLocalTime().AddMinutes(30).ToString('HH:mm')), 30 minutes after it was made. Try again after that."}else{''})}
}
function Run-Engine([string[]]$EngineArguments,[string]$Stage,[string]$InputSecret) {
 # One restic step. A run that was stopped, crashed or was ended by the memory cap leaves its lock in the
 # repository, and every later step that needs the repository then ends with exit code 11. The first
 # time that happens in a run the locks are examined; when they were all left by ended runs of this
 # computer they are removed, the result records it (LockReleased) and the step is tried once more.
 # Otherwise nothing is removed and the failure says whose lock it is. A step that is locked out later
 # in the same run fails as it is: one removal and one second try per run.
 try{Invoke-EngineStep @PSBoundParameters;return}catch{if($_.Exception.Data['ExitCode'] -ne 11 -or $script:lockExamined){throw};$locked=$_}
 $script:lockExamined=$true;$outcome=$null
 try{$outcome=Clear-EndedLocks}catch{}
 if(-not $outcome -or (-not @($outcome.Released).Count -and -not $outcome.Reason)){throw $locked}
 if(-not @($outcome.Released).Count){
  $stillLocked=[InvalidOperationException]::new((Get-EngineFailureText $Stage 11 $outcome.Reason));$stillLocked.Data['ExitCode']=11;throw $stillLocked
 }
 $script:status.LockReleased=[ordered]@{Stage=$Stage;Locks=@($outcome.Released|ForEach-Object {[ordered]@{Id=$_.Id;Pid=$_.Pid;CreatedUtc=$_.CreatedUtc;Exclusive=$_.Exclusive}})}
 # What the first try reported stays beside the second try's files.
 try{[IO.File]::Move((Join-Path $RunDirectory ($Stage+'.errors.log')),(Join-Path $RunDirectory ($Stage+'.locked.errors.log')),$true)}catch{}
 Invoke-EngineStep @PSBoundParameters
}
function Save-RecoveryLocation([string]$Path) {
 $fresh=Get-Content -LiteralPath $ConfigPath -Raw|ConvertFrom-Json
 if($fresh.PasswordDpapiPath -ine $script:config.PasswordDpapiPath -or $fresh.DestinationVolumeId -cne $script:config.DestinationVolumeId -or $fresh.RepositoryFolder -cne $script:config.RepositoryFolder){throw 'Configuration changed during key management. Resume with the original repository configuration.'}
 $fresh.RecoveryKeyPath=$Path;[void](Write-BackupStatus $fresh $ConfigPath);$script:config=$fresh
}
function Set-PartialMark([string]$Id) {
 # Marks a version partial and returns its new ID (changing the tag changes the ID).
 Run-Engine (Get-PartialMarkArguments $Id) 'MarkingPartial'
 $changed=@([IO.File]::ReadAllLines((Join-Path $RunDirectory 'MarkingPartial.jsonl'))|ForEach-Object {try{$_|ConvertFrom-Json}catch{}}|Where-Object {$_ -and $_ -is [pscustomobject] -and $_.PSObject.Properties['message_type'] -and $_.message_type -eq 'changed'})
 if($changed.Count -ne 1 -or $changed[0].new_snapshot_id -cnotmatch '^[0-9a-f]{64}$'){throw 'the engine did not report the marked version'}
 $changed[0].new_snapshot_id
}
# A partial version that could not be marked (for example while the repository is locked) still looks
# like a complete one. It is noted beside the password file and marked on a later run, before anything
# is deleted: until then neither the clean-up nor a deletion by hand goes ahead.
function Save-PendingPartialMark([string]$Id) {
 $path=$keyPath+'.partial-pending.local.json'
 $ids=@(if(Test-Path -LiteralPath $path){Get-Content -LiteralPath $path -Raw|ConvertFrom-Json})+$Id
 [void](Write-BackupStatus @($ids|Select-Object -Unique) $path)
}
function Get-PendingPartialMarks {
 # The IDs of the partial versions that are still waiting for their mark.
 $path=$keyPath+'.partial-pending.local.json'
 if(Test-Path -LiteralPath $path){@(Get-Content -LiteralPath $path -Raw|ConvertFrom-Json|ForEach-Object {[string]$_})}
}
function Complete-PendingPartialMarks {
 $path=$keyPath+'.partial-pending.local.json'
 if(-not(Test-Path -LiteralPath $path)){return}
 $pending=@(Get-Content -LiteralPath $path -Raw|ConvertFrom-Json)
 Run-Engine @('snapshots') 'ReadingPartialMarks'
 $saved=@(Get-Content -LiteralPath (Join-Path $RunDirectory 'ReadingPartialMarks.jsonl') -Raw|ConvertFrom-Json)
 foreach($id in $pending){
  $version=@($saved|Where-Object {$_.id -ceq $id})
  if($version.Count -and -not (Test-PartialSnapshot $version[0])){[void](Set-PartialMark $id)}
 }
 [IO.File]::Delete($path)
}
function Read-RepositoryKeys([string]$Stage) {
 Run-Engine @('key','list') $Stage
 @(Get-Content -LiteralPath (Join-Path $RunDirectory ($Stage+'.jsonl')) -Raw|ConvertFrom-Json)
}
function Invoke-KeyManagement {
 $journalPath=$keyPath+'.rotation.local.json'
 if($Action -eq 'ResumePasswordChange'){
  if(-not(Test-Path -LiteralPath $journalPath)){throw 'There is no interrupted password change to resume'}
  $journal=Get-Content -LiteralPath $journalPath -Raw|ConvertFrom-Json
  if($journal.Version -ne 1 -or $journal.OldKeyId -cnotmatch '^[0-9a-f]{64}$'){throw 'Password-change journal is invalid; keep the existing protected credential and recovery files'}
  Assert-RotationJournalTarget $journal ([string]$script:config.DestinationVolumeId) ([string]$script:config.RepositoryFolder) $script:repository
  if($RequestPath){
   $request=Get-Content -LiteralPath $RequestPath -Raw|ConvertFrom-Json
   if($request.RecoveryKeyPath -ine $journal.RecoveryKeyPath){
    $replacement=Assert-PrivateExportPath $request.RecoveryKeyPath @($source,$script:repository,$PSScriptRoot) @($keyPath,$ConfigPath,$journalPath)
    if(Test-Path -LiteralPath $replacement){throw 'Choose a new recovery-key file when resuming'}
    $journal.RecoveryKeyPath=$replacement;Set-PrivateTextFile $journalPath ($journal|ConvertTo-Json -Depth 6)
   }
  }
 }else{
  if(-not $RequestPath){throw 'A key-management request is required'}
  $request=Get-Content -LiteralPath $RequestPath -Raw|ConvertFrom-Json
  $export=Assert-PrivateExportPath $request.RecoveryKeyPath @($source,$script:repository,$PSScriptRoot) @($keyPath,$ConfigPath,$journalPath)
  if(Test-Path -LiteralPath $export){throw 'The recovery-key destination already exists. Choose a new file; existing files are never overwritten.'}
  if($Action -eq 'ExportKey'){
   # A recovery key that does not open the repository is worse than none: check the stored password first.
   try{[void](Read-RepositoryKeys 'CheckingPassword')}catch{if($_.Exception.Data['ExitCode'] -eq 12){throw 'The password stored on this computer does not open this backup repository, so no recovery key was saved. Use an earlier recovery key file to regain access.'};throw}
   New-PrivateTextFile $export (Get-RecoveryKeyText $script:repository $script:password)
   Save-RecoveryLocation $export
   $script:status|Add-Member -NotePropertyName RecoveryKeyPath -NotePropertyValue $export -Force
   return
  }
  $protectedNew=(Get-Content -LiteralPath $request.NewPasswordDpapiPath -Raw).Trim()
  $newPassword=[Net.NetworkCredential]::new('',($protectedNew|ConvertTo-SecureString)).Password
  Assert-NewBackupPassword $newPassword
  if($newPassword -ceq $script:password){throw 'The new password must differ from the current password'}
  $keys=@(Read-RepositoryKeys 'ReadingAccessKeys');$current=@($keys|Where-Object {$_.current -eq $true})
  if($current.Count -ne 1 -or $current[0].id -cnotmatch '^[0-9a-f]{64}$'){throw 'Cannot identify the currently used repository access key'}
  $journal=[pscustomobject]@{Version=1;Repository=$script:repository;ConfigPath=[IO.Path]::GetFullPath($ConfigPath);DestinationVolumeId=[string]$script:config.DestinationVolumeId;RepositoryFolder=[string]$script:config.RepositoryFolder;RecoveryKeyPath=$export;OldKeyId=$current[0].id;NewKeyId=$null;OldPasswordDpapi=([IO.File]::ReadAllText($keyPath)).Trim();NewPasswordDpapi=$protectedNew.Trim();Phase='Prepared';CreatedUtc=[DateTime]::UtcNow.ToString('o')}
  New-PrivateTextFile $journalPath ($journal|ConvertTo-Json -Depth 6)
 }
 $oldPassword=[Net.NetworkCredential]::new('',($journal.OldPasswordDpapi|ConvertTo-SecureString)).Password
 $newPassword=[Net.NetworkCredential]::new('',($journal.NewPasswordDpapi|ConvertTo-SecureString)).Password
 Assert-NewBackupPassword $newPassword
 $export=Assert-PrivateExportPath $journal.RecoveryKeyPath @($source,$script:repository,$PSScriptRoot) @($keyPath,$ConfigPath,$journalPath)
 # First add and authenticate the new key. The old key remains valid until
 # the portable key, local credential and configuration are safely saved.
 $script:password=$newPassword;$keys=@();$needsKey=$false
 try{$keys=@(Read-RepositoryKeys 'TestingNewPassword')}catch{if($_.Exception.Data['ExitCode'] -eq 12){$needsKey=$true}else{throw}}
 if($needsKey){$script:password=$oldPassword;Run-Engine @('key','add') 'AddingAccessKey' -InputSecret $newPassword;$script:password=$newPassword;$keys=@(Read-RepositoryKeys 'VerifyingNewPassword')}
 $newKey=@($keys|Where-Object {$_.current -eq $true})
 if($newKey.Count -ne 1 -or $newKey[0].id -cnotmatch '^[0-9a-f]{64}$' -or $newKey[0].id -ceq $journal.OldKeyId){throw 'New repository access key could not be verified. The old key has not been removed.'}
 $journal.NewKeyId=$newKey[0].id;$journal.Phase='NewKeyVerified';Set-PrivateTextFile $journalPath ($journal|ConvertTo-Json -Depth 6)
 $recoveryText=Get-RecoveryKeyText $script:repository $newPassword
 if(Test-Path -LiteralPath $export){if([IO.File]::ReadAllText($export) -cne $recoveryText){throw 'Recovery-key destination changed. The old key has not been removed.'}}else{New-PrivateTextFile $export $recoveryText}
 Set-PrivateTextFile $keyPath $journal.NewPasswordDpapi
 Save-RecoveryLocation $export
 # Read back both saved credentials before retiring the original access key.
 $saved=[Net.NetworkCredential]::new('',(([IO.File]::ReadAllText($keyPath))|ConvertTo-SecureString)).Password
 if($saved -cne $newPassword -or [IO.File]::ReadAllText($export) -cne $recoveryText){throw 'Saved credential verification failed; the old key is retained'}
 $journal.Phase='CredentialsSaved';Set-PrivateTextFile $journalPath ($journal|ConvertTo-Json -Depth 6)
 if($journal.OldKeyId -cin @($keys.id)){Run-Engine @('key','remove',$journal.OldKeyId) 'RetiringOldAccessKey'}
 [void](Read-RepositoryKeys 'VerifyingSavedPassword')
 $journal.Phase='Completed';Set-PrivateTextFile $journalPath ($journal|ConvertTo-Json -Depth 6)
 [IO.File]::Move($journalPath,($journalPath+'.completed-'+[guid]::NewGuid().ToString('N')+'.local.json'))
 $script:status|Add-Member -NotePropertyName RecoveryKeyPath -NotePropertyValue $export -Force
 $script:status|Add-Member -NotePropertyName PasswordChanged -NotePropertyValue $true -Force
 $oldPassword=$null;$newPassword=$null;$saved=$null
}
try {
 Save-Status
 if($PSBoundParameters.ContainsKey('KeepDays') -or $PSBoundParameters.ContainsKey('KeepWeeks')){throw 'This run was started with the earlier Keep versions settings (days and weeks), which no longer exist: the rule is now the last N versions and one version a month. Nothing was backed up and nothing was deleted. Update every file of DevDriveBackup, set Keep versions again and run the backup again.'}
 $script:config=Get-Content -LiteralPath $ConfigPath -Raw|ConvertFrom-Json
 # The test folder never goes together with real settings or key files.
 if($TestRoot){$temporary=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\';foreach($testPath in @($ConfigPath,$script:config.PasswordDpapiPath,$script:config.RecoveryKeyPath)){if(-not [IO.Path]::GetFullPath([string]$testPath).StartsWith($temporary,[StringComparison]::OrdinalIgnoreCase)){throw 'TestRoot is for the test suite only: the settings and key files must be under the temporary directory too'}}}
 $script:engine=Join-Path $PSScriptRoot 'bin\restic_0.19.1_windows_amd64.exe'
 if(-not(Test-Path -LiteralPath $script:engine)){throw 'Run Install-BackupEngine.ps1 first'}
 if($script:config.MemoryMiB -lt 512 -or $script:config.MemoryMiB -gt 8192){throw 'Memory budget must be 512..8192 MiB'}
 if($script:config.CpuThreads -lt 1){throw 'Invalid CPU thread budget'}
 # A preset made on a bigger computer must not fail here: use at most every processor this one has.
 if($script:config.CpuThreads -gt [Environment]::ProcessorCount){$script:config.CpuThreads=[Environment]::ProcessorCount}
 if($script:config.ReadConcurrency -lt 1 -or $script:config.ReadConcurrency -gt 8 -or $script:config.PackMiB -lt 4 -or $script:config.PackMiB -gt 64 -or $script:config.RateMBps -lt 0 -or $script:config.RateMBps -gt 2000){throw 'Invalid I/O settings'}
 # Optional: 1 keeps a rotational disk's writes sequential; an SSD benefits from 2-4 parallel writers.
 $script:backendConnections=if($script:config.PSObject.Properties['BackendConnections']){[int]$script:config.BackendConnections}else{1}
 if($script:backendConnections -lt 1 -or $script:backendConnections -gt 8){throw 'BackendConnections must be 1..8'}
 $source=[IO.Path]::GetFullPath($script:config.Source).TrimEnd('\')+'\'
 if($Action -in @('Backup','Preview')){Assert-PlainAncestors $source;if(-not $TestRoot -and (Get-Volume -DriveLetter $source.Substring(0,1)).UniqueId -ne $script:config.SourceVolumeId){throw 'Source volume identity changed'}}
 if($TestRoot){$destinationRoot=$TestRoot;$free=[IO.DriveInfo]::new([IO.Path]::GetPathRoot($TestRoot)).AvailableFreeSpace}
 else{
  $volume=@(Get-Volume -UniqueId $script:config.DestinationVolumeId|Where-Object {$_.DriveLetter})
  if($volume.Count -ne 1){throw 'Expected destination volume is missing or ambiguous'}
  if($volume[0].UniqueId -eq $script:config.SourceVolumeId){throw 'Backup must use a separate volume'}
  $destinationRoot=$volume[0].DriveLetter+':\';$free=$volume[0].SizeRemaining
 }
 $folder=[string]$script:config.RepositoryFolder
 if($folder -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,79}$' -or $folder.EndsWith('.')){throw 'RepositoryFolder must be a single plain folder name'}
 $script:repository=Join-Path $destinationRoot $folder;Assert-PlainAncestors $script:repository
 if($Action -in @('Backup','Preview') -and $free -lt 5GB){throw 'Less than 5 GiB free on the backup volume'}
 # What to back up comes from the per-folder Mode shared with the plain mirror (Versioned or Both).
 $sources=@();$selectionExcludes=@();$privateExcludes=@()
 if($Action -in @('Backup','Preview')){
  $regions=@(Get-BackupRegions (Get-BackupSelection $script:config) 'Versioned')
  $sources=@($regions|ForEach-Object {
   $p=if($_.Path){[IO.Path]::GetFullPath((Join-Path $source $_.Path))}else{$source}
   if(-not $p.StartsWith($source,[StringComparison]::OrdinalIgnoreCase)){throw "Source selection escaped root: $($_.Path)"}
   if(-not(Test-Path -LiteralPath $p)){throw "Selected source is missing: $p"};Assert-PlainAncestors $p;$p
  })
  if($sources.Count -eq 0){throw 'Select at least one source: mark a folder Versioned or Both'}
  # Entries inside a selected folder that are marked Mirror or Skip, as literal absolute patterns.
  # Go filepath.Match has no backslash escape on Windows; a one-character class makes [ * ? literal.
  # restic drops everything below an excluded folder, including a selected folder inside it, so an
  # excluded folder that contains a selected one is replaced by its other contents along the way.
  $kept=@($regions|Where-Object {$_.Path}|ForEach-Object {$_.Path})
  function Expand-Excluded([string]$Rel){
   $inside=@($kept|Where-Object {$_.StartsWith($Rel+'\',[StringComparison]::OrdinalIgnoreCase)})
   if(-not $inside.Count){return $Rel}
   foreach($child in @(Get-ChildItem -LiteralPath (Join-Path $source $Rel) -Force)){
    $c=$Rel+'\'+$child.Name
    if($kept -icontains $c){continue}
    if(@($inside|Where-Object {$_.StartsWith($c+'\',[StringComparison]::OrdinalIgnoreCase)}).Count){Expand-Excluded $c}else{$c}
   }
  }
  # ForEach-Object rather than $regions.Excluded: under strict mode an empty result of the
  # shorthand counts as a missing property.
  $selectionExcludes=@($regions|ForEach-Object {$_.Excluded}|Where-Object {$_}|Sort-Object -Unique|ForEach-Object {Expand-Excluded $_}|ForEach-Object {
   [regex]::Replace([IO.Path]::GetFullPath((Join-Path $source $_)).Replace('\','/'),'[\[*?]',{param($m) '['+$m.Value+']'})
  })
  # DevDriveBackup's private folders (protected passwords, run state, recovery keys of every source)
  # are never backed up, whatever the selection, as in the plain copy.
  $privateExcludes=@((Join-Path $env:LOCALAPPDATA 'DevDriveMirror'),(Join-Path $env:USERPROFILE 'DevDriveBackup recovery keys'),(Join-Path $env:USERPROFILE 'Backup Center recovery keys')|ForEach-Object {
   [regex]::Replace([IO.Path]::GetFullPath($_).TrimEnd('\').Replace('\','/'),'[\[*?]',{param($m) '['+$m.Value+']'})
  })
  $script:status.Sources=$sources;$script:status.SelectionExcludes=$selectionExcludes
 }
 $script:cache=if($TestRoot){Join-Path $TestRoot 'engine-cache'}else{Join-Path $env:LOCALAPPDATA 'DevDriveMirror\restic-cache'}
 $keyPath=[IO.Path]::GetFullPath($script:config.PasswordDpapiPath);$exists=Test-Path -LiteralPath (Join-Path $script:repository 'config')
 $recoveryPath=[IO.Path]::GetFullPath($script:config.RecoveryKeyPath)
 if($keyPath -ieq $recoveryPath){throw 'Protected password and portable recovery key must be different files'}
 foreach($privatePath in @($keyPath,$recoveryPath)){Assert-PlainAncestors $privatePath;if($privatePath.StartsWith($source,[StringComparison]::OrdinalIgnoreCase) -or $privatePath.StartsWith($script:repository+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Keep password/recovery files outside source and repository'}}
 New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($keyPath)) -Force|Out-Null
 $script:runLock=[IO.File]::Open($keyPath+'.run.lock',[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
 if((Test-Path -LiteralPath ($keyPath+'.rotation.local.json')) -and $Action -ne 'ResumePasswordChange'){throw 'An interrupted password change must be resumed from Password and recovery before using this repository.'}
 $missing=$false
 if(Test-Path -LiteralPath $keyPath){
  $secure=(Get-Content -LiteralPath $keyPath -Raw).Trim()|ConvertTo-SecureString;$script:password=[Net.NetworkCredential]::new('',$secure).Password
  # The protected password file says that this source was backed up before. When the versions folder
  # then holds no repository, it was renamed, moved, deleted or emptied. Starting a new, empty one here
  # would look like a healthy backup with every earlier version gone, so the run stops before anything
  # is created (no folder, no recovery-key file, no engine cache) and the user decides: bring the folder
  # back, or run a Backup with -CreateNewRepository.
  if(-not $exists){
   $missing=$true;$script:status.RepositoryMissing=$true
   if($Action -ne 'Backup' -or -not $CreateNewRepository){
    if(Test-Path -LiteralPath $script:repository){throw "The versions folder $folder on the backup drive is empty or incomplete: the saved versions are not in it. They may have been moved or deleted. Nothing was changed."}
    throw "The versions folder $folder was not found on the backup drive. It may have been renamed, moved or deleted. Nothing was changed."
   }
  }
 }
 elseif($exists){throw 'Repository already exists but its protected password file is missing'}
 else {
  if($Action -ne 'Backup'){throw 'Repository is not initialized; the first Backup creates it'}
  $recovery=[IO.Path]::GetFullPath($script:config.RecoveryKeyPath)
  if(Test-Path -LiteralPath $recovery){throw 'Recovery file already exists; refusing to overwrite'}
  New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($recovery)) -Force|Out-Null
  $script:password=[Convert]::ToBase64String([Security.Cryptography.RandomNumberGenerator]::GetBytes(32))
  New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($keyPath)) -Force|Out-Null
  New-PrivateTextFile $keyPath ($script:password|ConvertTo-SecureString -AsPlainText -Force|ConvertFrom-SecureString)
  New-PrivateTextFile $recovery (Get-RecoveryKeyText $script:repository $script:password)
 }
 New-Item -ItemType Directory -Path $script:cache -Force|Out-Null
 if(-not $exists -and -not(Test-Path -LiteralPath $recoveryPath)){
  New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($recoveryPath)) -Force|Out-Null
  New-PrivateTextFile $recoveryPath (Get-RecoveryKeyText $script:repository $script:password)
 }
 Add-Type -Path (Join-Path $PSScriptRoot 'Backup.Process.cs')
 if($Action -in @('ExportKey','ChangePassword','ResumePasswordChange') -and -not $exists){throw 'Create a backup repository before managing its password or recovery key'}
 if(-not $exists){
  # Only a backup may create a repository. Anything else finding none must say so, not create an
  # empty one (a wiped or renamed backup folder would otherwise look like a healthy empty history).
  if($Action -ne 'Backup'){throw "No backup repository was found at $($script:repository). Check that the right drive is connected and that the folder was not renamed or deleted."}
  Run-Engine @('init') 'Initializing'
  $script:status.RepositoryCreated=$true
  # Created on the user's choice in place of one that is gone: it opens with the password already stored.
  if($missing){$script:status.RepositoryMissing=$false;$script:status.Note="A new, empty versions folder $folder was created, as chosen, because the earlier one was not found. The versions saved before are not in it."}
 }
 $base=@('backup','--read-concurrency',[string]$script:config.ReadConcurrency,'--tag','devdrive')
 if($ForceRead){$base+='--force'}
 foreach($exclude in @($script:config.Exclude)+$selectionExcludes+$privateExcludes){if($exclude){$base+=@('--iexclude',[string]$exclude)}}
 switch($Action){
  {$_ -in @('ExportKey','ChangePassword','ResumePasswordChange')} {Invoke-KeyManagement}
  'Backup' {
   # The first clean-up after an approved preview is limited to the list of approved versions. The list
   # is read now, as it was when the run started; one that cannot be used is reported with the clean-up
   # (Retention.Error) and deletes nothing. A preview wins: the list is then not used at all.
   $approving=$PSBoundParameters.ContainsKey('RetentionApprovedFile') -and -not $RetentionPreview
   $approvedIds=@();$approvedProblem=$null
   if($approving){
    try{
     if(-not ([string]$RetentionApprovedFile).Trim()){throw 'No list of approved versions was named, so the clean-up deleted nothing.'}
     $approvedPath=$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($RetentionApprovedFile)
     if(-not(Test-Path -LiteralPath $approvedPath -PathType Leaf)){throw "The list of approved versions was not found ($approvedPath), so the clean-up deleted nothing."}
     try{$approvedText=[IO.File]::ReadAllText($approvedPath)}catch{throw "The list of approved versions could not be read ($approvedPath), so the clean-up deleted nothing. $($_.Exception.GetBaseException().Message)"}
     $approvedIds=@(Get-RetentionApprovedIds $approvedText)
    }catch{$approvedProblem=$_.Exception.Message;$approvedIds=@()}
   }
   try{Run-Engine ($base+@('--')+$sources) 'BackingUp'}
   catch{
    # Exit code 3: restic saved a version although some files could not be read. Mark it (the tag
    # changes, and with it the version's ID) so the clean-up rule and the newest-complete protection
    # never treat it as a complete version, then fail the run as before.
    if($_.Exception.Data['ExitCode'] -ne 3 -or -not $script:status.Snapshot){throw}
    $script:status.Partial=$true;$markError=$null
    try{
     $marked=Set-PartialMark $script:status.Snapshot
     $script:status.Snapshot=$marked;if($script:status.BackupSummary){$script:status.BackupSummary.snapshot_id=$marked}
    }catch{$markError=$_.Exception.Message;try{Save-PendingPartialMark $script:status.Snapshot}catch{$markError+=' It could not be noted for later either: '+$_.Exception.Message}}
    $partialText='Some files could not be read, so this version is incomplete (restic exit code 3). '
    if($markError){throw ($partialText+"It was saved, but could not be marked as partial yet, so for now the history shows it like a complete version; it is marked on a later run, before any version is deleted. See BackingUp.errors.log for the files that were skipped, then back up again. ($markError)")}
    throw ($partialText+'It was saved and marked as partial: the history shows it as partial, it never counts as one of the versions to keep, and the automatic clean-up of old versions deletes it only after three complete versions were made after it. See BackingUp.errors.log for the files that were skipped (for example files another program keeps open), then back up again.')
   }
   try{Run-Engine @('check') 'CheckingStructure'}
   catch{if($_.Exception.Data['ExitCode'] -eq 11){throw ('The new version was saved, but it could not be checked. '+$_.Exception.Message)};throw}
   if($KeepLast -gt 0 -or $KeepMonths -gt 0 -or $RetentionPreview -or $approving){
    # Keep versions. The backup itself has succeeded and been checked: a clean-up that fails is reported
    # (Retention.Error), not a failed backup. The plan is worked out from the list of versions
    # (Get-VersionRetentionPlan), checked (Get-RetentionRemovals) and saved with the run before anything
    # is deleted. A preview stops there. Otherwise the versions are deleted by exact ID and their space
    # is freed in a second step, so the result says how far it got. Once versions were deleted the
    # repository is checked again, outside that report: a repository that fails this check fails the
    # run, since it may be damaged.
    # Retention in the result: Kept = complete versions of this computer that stay; Candidates = the
    # versions a preview would delete now, or the ones this run really deleted (Removed of them,
    # PartialRemoved of those partial). No size is given: deleting a version frees only the data that no
    # remaining version needs, and restic 0.19 does not report that amount in a form that can be read.
    # With a list of approved versions (-RetentionApprovedFile, the first clean-up after a preview) the
    # plan is narrowed to that list before anything is deleted: Approved = the list was read and the plan
    # was narrowed to it; Deferred = the versions the rule would delete now that were not on the list,
    # which stay for the next clean-up (they count in Kept while they are complete and still there).
    $new=$script:status.Snapshot
    $retention=[ordered]@{Preview=[bool]$RetentionPreview;Approved=$false;Last=$KeepLast;Months=$KeepMonths;Kept=$null;Removed=0;PartialRemoved=0;Deferred=0;Candidates=@();Error=$null}
    $remove=@();$gone=@();$deleting=$false
    try{
     # Before anything else: without a usable list nothing is marked, planned or deleted.
     if($approving -and ($approvedProblem -or -not $approvedIds.Count)){throw $(if($approvedProblem){$approvedProblem}else{'The list of approved versions is empty, so the clean-up deleted nothing.'})}
     # A partial version that is still waiting for its mark would pass for a complete one. It is marked
     # first (the mark changes its ID). A preview changes no version: it only plans such a version as
     # the partial one it is, under the ID it still has.
     $waiting=@()
     if($RetentionPreview){try{$waiting=@(Get-PendingPartialMarks)}catch{throw "The note of an earlier partial version that is not marked yet could not be read, so nothing was planned. $($_.Exception.Message)"}}
     else{try{Complete-PendingPartialMarks}catch{throw "An earlier partial version is not marked yet, so nothing was cleaned up. $($_.Exception.Message)"}}
     # Every version in the repository: the rule needs the partial ones too, and the checks need to see
     # what belongs to another computer or another program. The computer name is read from the version
     # just made, as restic recorded it.
     Run-Engine @('snapshots') 'ReadingHistory'
     $available=@(Get-Content -LiteralPath (Join-Path $RunDirectory 'ReadingHistory.jsonl') -Raw|ConvertFrom-Json)
     if($waiting.Count){$available=@($available|ForEach-Object {
      if($_.id -cin $waiting -and $_.PSObject.Properties['tags'] -and -not (Test-PartialSnapshot $_)){$as=$_.PSObject.Copy();$as.tags=@(Get-PartialTags $_.tags);$as}else{$_}
     })}
     $made=@($available|Where-Object {$new -and $_.id -ceq $new})
     if($made.Count -ne 1 -or -not $made[0].hostname){throw 'The version this backup just made was not found among the saved versions, so the clean-up cannot protect it. Nothing was deleted.'}
     $computer=[string]$made[0].hostname
     $plan=@(Get-VersionRetentionPlan $available $KeepLast $KeepMonths $computer $new)
     $remove=@(Get-RetentionRemovals $plan $new $available $computer)
     if($approving){
      # Only what was shown and approved: the plan is narrowed to the list, and the checks run again on
      # what is left. A version goes only when the rule, the checks and the list all agree.
      $wanted=@($remove|ForEach-Object {[string]$_.id})
      $plan=@(Get-ApprovedRetentionPlan $plan $approvedIds)
      $remove=@(Get-RetentionRemovals $plan $new $available $computer)
      if(@($remove|Where-Object {[string]$_.id -cnotin $approvedIds -or [string]$_.id -cnotin $wanted}).Count){throw 'The clean-up would delete a version that was not approved. Nothing was deleted.'}
      $retention.Approved=$true;$retention.Deferred=$wanted.Count-$remove.Count
     }
     [IO.File]::WriteAllText((Join-Path $RunDirectory 'clean-up-plan.json'),(ConvertTo-Json @($plan|ForEach-Object {[ordered]@{Id=$_.Id;Time=$_.Time.UtcDateTime.ToString('o');Month=$_.Month;Host=$_.Host;Paths=$_.Paths;Partial=$_.Partial;Keep=$_.Keep;Reasons=$_.Reasons}}) -Depth 6))
     $retention.Kept=@($plan|Where-Object {$_.Keep -and -not $_.Partial}).Count
     if($RetentionPreview){$gone=$remove}
     elseif($remove.Count){
      $deleting=$true
      # In batches: one command line cannot hold more than about 500 IDs.
      foreach($batch in @(Split-SnapshotIdBatches @($remove|ForEach-Object {$_.id}))){Run-Engine (@('forget')+@($batch)) 'DeletingOldVersions';$gone+=@($remove|Where-Object {$_.id -cin @($batch)})}
      Run-Engine @('prune') 'FreeingSpace'
     }
    }catch{
     $retention.Error=$_.Exception.Message
     # Deleting may have stopped part way through a batch: see which versions are really gone.
     if($deleting -and $gone.Count -lt $remove.Count){
      try{
       Run-Engine @('snapshots') 'ReadingHistoryAgain'
       $still=@(Get-Content -LiteralPath (Join-Path $RunDirectory 'ReadingHistoryAgain.jsonl') -Raw|ConvertFrom-Json|ForEach-Object {$_.id})
       # A list without the version just made is not the list of this repository.
       if($new -cnotin $still){throw 'The saved versions could not be listed.'}
       $gone=@($remove|Where-Object {$_.id -cnotin $still})
      }catch{$retention.Error+=' How many versions were deleted could not be confirmed: the count given is the least, and more may be gone. Refresh the history to see what is left.'}
     }
    }
    $retention.Candidates=@($gone|ForEach-Object {[ordered]@{Id=[string]$_.id;Time=(ConvertTo-HistoryDate $_.time).UtcDateTime.ToString('o');Partial=(Test-PartialSnapshot $_);Host=[string]$_.hostname;Paths=[string[]]@($_.paths)}})
    if(-not $RetentionPreview){
     $retention.Removed=$gone.Count;$retention.PartialRemoved=@($gone|Where-Object {Test-PartialSnapshot $_}).Count
     # A complete version that was to go and is still there is still kept.
     if($null -ne $retention.Kept){$retention.Kept+=@($remove|Where-Object {$_.id -cnotin @($gone|ForEach-Object {$_.id}) -and -not (Test-PartialSnapshot $_)}).Count}
    }
    $script:status.Retention=$retention
    # Checked whenever deleting started, also when how far it got is unknown.
    if($deleting){
     try{Run-Engine @('check') 'CheckingAfterCleanUp'}
     catch{throw "The new version was saved, but the repository check after deleting old versions failed, so the repository may be damaged. Run a full check of the versions before relying on them. $($_.Exception.Message)"}
    }
   }
  }
  'Preview' {Run-Engine ($base+@('--dry-run','--')+$sources) 'Previewing'}
  'Check' {$checkArgs=@('check');if($ReadAllData){$checkArgs+='--read-data'};Run-Engine $checkArgs 'Verifying'}
  'Snapshots' {Run-Engine @('snapshots') 'ListingSnapshots'}
  'Files' {
   if(-not $RequestPath){throw 'A history request is required'}
   $request=Get-Content -LiteralPath $RequestPath -Raw|ConvertFrom-Json
   Assert-SnapshotId $request.Snapshot;Assert-SnapshotPath $request.Path
   Run-Engine @('ls',$request.Snapshot,$request.Path) 'ListingFiles'
  }
  'Forget' {
   if(-not $RequestPath){throw 'An explicit history deletion request is required'}
   $request=Get-Content -LiteralPath $RequestPath -Raw|ConvertFrom-Json
   if($request.Confirmation -cne 'DELETE SELECTED HISTORY'){throw 'History deletion was not confirmed'}
   try{Complete-PendingPartialMarks}catch{throw "An earlier partial version is not marked yet, so nothing was deleted. $($_.Exception.Message)"}
   Run-Engine @('snapshots') 'ReadingHistory'
   $available=Get-Content -LiteralPath (Join-Path $RunDirectory 'ReadingHistory.jsonl') -Raw|ConvertFrom-Json
   $plan=@(Get-HistoryDeletionPlan $available @($request.SnapshotIds))
   [IO.File]::WriteAllText((Join-Path $RunDirectory 'deletion-plan.json'),($plan|ConvertTo-Json -Depth 8))
   # In batches: one command line cannot hold more than about 500 IDs. Space is reclaimed with the last.
   $batches=@(Split-SnapshotIdBatches @($plan|ForEach-Object {$_.id}))
   for($i=0;$i -lt $batches.Count;$i++){
    $forgetArgs=@('forget')+@($batches[$i])
    if($request.ReclaimSpace -eq $true -and $i -eq $batches.Count-1){$forgetArgs+='--prune'}
    Run-Engine $forgetArgs 'DeletingHistory'
   }
   Run-Engine @('check') 'CheckingStructure'
  }
  'Restore' {
   $literalPaths=@()
   if($RequestPath){
    $request=Get-Content -LiteralPath $RequestPath -Raw|ConvertFrom-Json
    Assert-SnapshotId $request.Snapshot;$Snapshot=$request.Snapshot
    $literalPaths=@($request.Paths)
    if($literalPaths.Count -eq 0){throw 'Select at least one file or folder to restore'}
    foreach($path in $literalPaths){Assert-SnapshotPath $path}
   }
   $script:status.Snapshot=$Snapshot
   if(-not $RestoreTarget){throw 'RestoreTarget is required'}
   $target=[IO.Path]::GetFullPath($RestoreTarget).TrimEnd('\');Assert-PlainAncestors $target
   if($target.Length -lt 4 -or ($target+'\').StartsWith($source,[StringComparison]::OrdinalIgnoreCase) -or ($target+'\').StartsWith($script:repository+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Restore into a new folder outside source and repository'}
   if(Test-Path -LiteralPath $target){throw 'Restore target must be a new, nonexistent folder'}
   $restoreArguments=@('restore',$Snapshot,'--target',$target,'--verify','--overwrite','never')
   if($literalPaths.Count){
    $includeFile=Join-Path $RunDirectory 'restore-includes.txt'
    [IO.File]::WriteAllLines($includeFile,[string[]]@($literalPaths|ForEach-Object {(ConvertTo-ResticLiteralPattern $_).Replace('$','$$')}),[Text.UTF8Encoding]::new($false))
    $restoreArguments+=@('--include-file',$includeFile)
   }
   foreach($path in $RestoreInclude){$restoreArguments+=@('--include',$path)}
   try{Run-Engine $restoreArguments 'Restoring'}
   catch{
    # A restore below a protected folder (for example C:\Users) can restore every file but fail to set
    # the dates of the recreated parent folders; restic then ends with exit code 1 and skips its content
    # check. That is a warning, not a failed restore, but the restore is reported as not verified. Which
    # folders are parents is read from the restored version itself.
    if($_.Exception.Data['ExitCode'] -ne 1){throw}
    $failure=$_;$summary=$script:status.Progress;$warnings=@()
    try{
     Run-Engine @('snapshots',$Snapshot) 'ReadingVersion'
     $version=@(Get-Content -LiteralPath (Join-Path $RunDirectory 'ReadingVersion.jsonl') -Raw|ConvertFrom-Json)
     if($version.Count -eq 1){$warnings=@(Get-RestoreParentWarnings ([IO.File]::ReadAllText((Join-Path $RunDirectory 'Restoring.errors.log'))) @($version[0].paths) $summary)}
    }catch{}
    if(-not $warnings.Count){throw $failure}
    $script:status.Warnings=$warnings
   }
   $script:status.ContentVerified=-not $script:status.Contains('Warnings')
  }
 }
 $script:status.State='Completed';$script:status.UpdatedUtc=[DateTime]::UtcNow.ToString('o');[void](Write-BackupStatus $script:status (Join-Path $RunDirectory 'result.json'));Save-Status
}catch{$script:status.State='Failed';$script:status.Error=$_.Exception.Message;[IO.File]::WriteAllText((Join-Path $RunDirectory 'worker-error.txt'),($_|Out-String)+[Environment]::NewLine+$_.ScriptStackTrace);[void](Write-BackupStatus $script:status (Join-Path $RunDirectory 'result.json') -BestEffort);Save-Status;exit 1}
finally{$script:password=$null;if(Get-Variable -Scope Script -Name runLock -ErrorAction SilentlyContinue){if($script:runLock){$script:runLock.Dispose()}}}
