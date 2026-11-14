#Requires -Version 7.2
# The versioned worker against a disposable repository, with real restic and no second drive: everything
# (source, repository, password files, run folders, engine cache) lives in one new folder under the
# temporary directory, which Backup-Worker.ps1 -TestRoot uses in place of the backup drive.
# Covers: a partial version (a file that cannot be read), the clean-up of old versions beside partial
# versions and another computer's versions, deleting versions, a restore below protected folders, saving
# the recovery key, a pending password change after the repository moved, a lock left in the repository
# (by a run that was killed: removed; by a backup that is still running: left alone), and plaintext
# passwords in files.
# Skips when restic is not installed (Install-BackupEngine.ps1).
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'Backup.Status.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Backup.History.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Backup.Security.psm1') -Force
function Assert($ok,[string]$message){if(-not $ok){throw "FAIL $message"};Write-Output "PASS $message"}
$engine=Join-Path $PSScriptRoot 'bin\restic_0.19.1_windows_amd64.exe'
if(-not(Test-Path -LiteralPath $engine)){Write-Output 'SKIP: bin\restic_0.19.1_windows_amd64.exe is not installed (Install-BackupEngine.ps1)';return}
$base=Join-Path ([IO.Path]::GetFullPath([IO.Path]::GetTempPath())) ('backup-versions-test-'+[guid]::NewGuid().ToString('N').Substring(0,10))
$drive=Join-Path $base 'drive';$moved=Join-Path $base 'drive-moved';$work=Join-Path $base 'work';$source=Join-Path $work 'source';$private=Join-Path $base 'private'
New-Item -ItemType Directory -Path $drive,$moved,$source,$private|Out-Null
$config=Get-Content (Join-Path $PSScriptRoot 'config.example.json') -Raw|ConvertFrom-Json
$config.Source=$work+'\';$config.SourceVolumeId='test-source-volume';$config.DestinationVolumeId='test-backup-volume';$config.RepositoryFolder='Test-Versions'
$config.PasswordDpapiPath=Join-Path $private 'key.dpapi';$config.RecoveryKeyPath=Join-Path $private 'recovery-first.txt';$config.Include=@('source');$config.Choices=@([pscustomobject]@{Path='source';Mode='Versioned';Reason='Disposable test source'});$config.DefaultMode='Skip';$config.RateMBps=0;$config.MemoryMiB=512;$config.CpuThreads=1;$config.ReadConcurrency=1;$config.PackMiB=8
$configPath=Join-Path $private 'settings.json';$config|ConvertTo-Json -Depth 7|Set-Content -LiteralPath $configPath
$repo=Join-Path $drive $config.RepositoryFolder;$journalPath=$config.PasswordDpapiPath+'.rotation.local.json'
$passwords=[Collections.Generic.List[string]]::new()
function Run([string]$action,[hashtable]$extra=@{},$request=$null,[string]$testRoot=$drive){
 $run=Join-Path $private ('runs\'+$action+'-'+[guid]::NewGuid().ToString('N').Substring(0,8))
 if($null -ne $request){$requestPath=Join-Path $private ('request-'+[guid]::NewGuid().ToString('N').Substring(0,8)+'.json');$request|ConvertTo-Json -Depth 6|Set-Content -LiteralPath $requestPath;$extra.RequestPath=$requestPath}
 & (Join-Path $PSScriptRoot 'Backup-Worker.ps1') -ConfigPath $configPath -Action $action -RunDirectory $run -TestRoot $testRoot @extra
 Read-BackupStatus (Join-Path $run 'result.json')
}
function Read-Password {[Net.NetworkCredential]::new('',(((Get-Content -LiteralPath $config.PasswordDpapiPath -Raw).Trim())|ConvertTo-SecureString)).Password}
function Restic([string[]]$arguments,[string]$password=(Read-Password),[string]$repository=$repo){
 # The engine on its own, to prepare dated versions and to check results independently of the worker.
 $psi=[Diagnostics.ProcessStartInfo]::new($engine);$psi.UseShellExecute=$false;$psi.CreateNoWindow=$true;$psi.RedirectStandardOutput=$true;$psi.RedirectStandardError=$true;$psi.Environment['RESTIC_PASSWORD']=$password
 foreach($a in @('-r',$repository,'--cache-dir',(Join-Path $base 'direct-cache'))+$arguments){[void]$psi.ArgumentList.Add($a)}
 $p=[Diagnostics.Process]::Start($psi);$out=$p.StandardOutput.ReadToEndAsync();$err=$p.StandardError.ReadToEndAsync();$p.WaitForExit()
 $result=[pscustomobject]@{Code=$p.ExitCode;Out=$out.GetAwaiter().GetResult();Err=$err.GetAwaiter().GetResult()};$p.Dispose();$result
}
function Snapshots {@((Restic @('--json','snapshots')).Out|ConvertFrom-Json)}
function Lock-File([string]$path,[scriptblock]$while){$handle=[IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None);try{& $while}finally{$handle.Dispose()}}
$inside='/'+$source.Replace(':','').Replace('\','/')
try{
 # --- The test folder cannot be pointed at real settings or outside the temporary directory ----------
 $outside=$null;try{& (Join-Path $PSScriptRoot 'Backup-Worker.ps1') -ConfigPath $configPath -Action Snapshots -RunDirectory (Join-Path $private 'runs\outside') -TestRoot $PSScriptRoot}catch{$outside=$_.Exception.Message}
 Assert ($outside -like '*test suite only*' -and -not(Test-Path -LiteralPath (Join-Path $private 'runs\outside'))) 'a test folder outside the temporary directory is refused before anything is written'
 $realSettings=Join-Path $private 'runs\real-settings';& (Join-Path $PSScriptRoot 'Backup-Worker.ps1') -ConfigPath (Join-Path $PSScriptRoot 'config.example.json') -Action Snapshots -RunDirectory $realSettings -TestRoot $drive
 Assert ((Read-BackupStatus (Join-Path $realSettings 'result.json')).Error -like '*test suite only*') 'the test folder is refused together with settings outside the temporary directory'

 # --- A file that cannot be read: the version is saved, marked partial, and the run fails -----------
 [IO.File]::WriteAllText((Join-Path $source 'a.txt'),'a');$important=Join-Path $source 'important.txt';[IO.File]::WriteAllText($important,'important v1')
 $partialRun=Lock-File $important {Run 'Backup'}
 $passwords.Add((Read-Password))
 $all=@(Snapshots)
 Assert ($partialRun.State -eq 'Failed' -and $partialRun.Partial -eq $true -and $partialRun.Error -like '*marked as partial*') 'a backup that could not read a file fails and reports a partial version'
 Assert ($all.Count -eq 1 -and (Test-PartialSnapshot $all[0]) -and @($all[0].tags) -notcontains 'devdrive' -and $all[0].id -eq $partialRun.Snapshot -and $partialRun.BackupSummary.snapshot_id -eq $partialRun.Snapshot) 'the partial version is marked in the repository and the run names its final ID'
 $completeRun=Run 'Backup'
 Assert ($completeRun.State -eq 'Completed' -and $completeRun.Partial -eq $false) 'the next backup, with the file readable, completes'
 Assert ($completeRun.BackupSummary.snapshot_id -eq $completeRun.Snapshot -and $completeRun.BackupSummary.total_files_processed -eq 2 -and $completeRun.BackupSummary.files_new -ge 1 -and $completeRun.BackupSummary.data_added -gt 0 -and $null -ne $completeRun.BackupSummary.files_changed -and $completeRun.BackupSummary.total_bytes_processed -gt 0) 'the result carries the backup''s own summary (files, bytes, version)'
 Assert (-not $completeRun.Progress.PSObject.Properties['files_new']) 'Progress still ends with the summary of the check, as before'

 # --- Clean-up of old versions beside partial versions and another computer's versions ---------------
 $computer=(Snapshots|Where-Object {$_.id -eq $completeRun.Snapshot}).hostname;$today=(Get-Date).Date;$ids=@{}
 function Seed([string]$name,[datetime]$time,[string]$computerName,[string]$content,[switch]$Unreadable){
  [IO.File]::WriteAllText($important,$content)
  $arguments=@('--json','backup','--host',$computerName,'--tag','devdrive','--time',$time.ToString('yyyy-MM-dd HH:mm:ss'),$source)
  $o=if($Unreadable){Lock-File $important {Restic $arguments}}else{Restic $arguments}
  if($o.Code -ne $(if($Unreadable){3}else{0})){throw "Preparing version '$name' ended with code $($o.Code): $($o.Err)"}
  $id=@($o.Out -split "`r?`n"|ForEach-Object {try{$_|ConvertFrom-Json}catch{}}|Where-Object {$_ -and $_.message_type -eq 'summary'})[0].snapshot_id
  if($Unreadable){$m=Restic (@('--json')+(Get-PartialMarkArguments $id));if($m.Code -ne 0){throw "Marking '$name' failed: $($m.Err)"};$id=@($m.Out -split "`r?`n"|ForEach-Object {try{$_|ConvertFrom-Json}catch{}}|Where-Object {$_ -and $_.message_type -eq 'changed'})[0].new_snapshot_id}
  $ids[$name]=$id
 }
 Seed 'old-400' $today.AddDays(-400).AddHours(10) $computer 'important, 400 days ago'
 Seed 'old-300' $today.AddDays(-300).AddHours(10) $computer 'important, 300 days ago'
 Seed 'other-200' $today.AddDays(-200).AddHours(10) 'other-computer' 'another computer, 200 days ago'
 Seed 'other-50' $today.AddDays(-50).AddHours(10) 'other-computer' 'another computer, 50 days ago'
 Seed 'day-2' $today.AddDays(-2).AddHours(10) $computer 'important, two days ago'
 Seed 'day-1-complete' $today.AddDays(-1).AddHours(10) $computer 'important, yesterday morning: the only copy of this text'
 Seed 'day-1-partial' $today.AddDays(-1).AddHours(18) $computer 'important, being edited' -Unreadable
 [IO.File]::WriteAllText($important,'important, today')
 $kept=Run 'Backup' @{KeepDays=7;KeepWeeks=4;KeepMonths=3}
 $left=@(Snapshots|ForEach-Object {$_.id})
 Assert ($kept.State -eq 'Completed' -and -not $kept.Retention.PSObject.Properties['Error']) 'a backup with Keep versions completes and cleans up without an error'
 Assert ($ids['day-1-complete'] -in $left -and (Restic @('dump',$ids['day-1-complete'],($inside+'/important.txt'))).Out -eq 'important, yesterday morning: the only copy of this text') 'the complete version of a day survives a later partial version of that day'
 Assert ($ids['day-1-partial'] -in $left -and $partialRun.Snapshot -in $left) 'partial versions are left alone by the clean-up'
 Assert ($ids['other-200'] -in $left -and $ids['other-50'] -in $left) 'another computer''s versions are left alone, also those outside this computer''s rule'
 Assert ($ids['old-400'] -notin $left -and $ids['old-300'] -notin $left -and $completeRun.Snapshot -notin $left -and $ids['day-2'] -in $left -and $kept.Snapshot -in $left) 'this computer''s versions outside the rule are deleted: the two old ones and today''s earlier one'
 Assert ($kept.Retention.Removed -eq 3 -and $kept.Retention.Kept -eq 3 -and $kept.Retention.SpaceFreed -eq $true) 'the result counts this computer''s complete versions only: 3 deleted, 3 kept'
 Assert ($kept.BackupSummary.snapshot_id -eq $kept.Snapshot) 'the backup''s summary is kept through the clean-up'

 # --- Deleting versions by hand ----------------------------------------------------------------------
 $refused=Run 'Forget' @{} @{SnapshotIds=@($kept.Snapshot);Confirmation='DELETE SELECTED HISTORY';ReclaimSpace=$false}
 Assert ($refused.State -eq 'Failed' -and $refused.Error -like '*protected*') 'the newest version cannot be deleted'
 $deleted=Run 'Forget' @{} @{SnapshotIds=@($ids['other-200'],$partialRun.Snapshot);Confirmation='DELETE SELECTED HISTORY';ReclaimSpace=$true}
 $left=@(Snapshots|ForEach-Object {$_.id})
 Assert ($deleted.State -eq 'Completed' -and $ids['other-200'] -notin $left -and $partialRun.Snapshot -notin $left -and $left.Count -eq 5) 'chosen older versions, a partial one among them, are deleted and their space freed'

 # --- Restore: verified, or honestly reported as not verified ----------------------------------------
 $target=Join-Path $base 'restored'
 $restored=Run 'Restore' @{Snapshot=$kept.Snapshot;RestoreTarget=$target}
 Assert ($restored.State -eq 'Completed') 'a restore whose only trouble is the date of protected parent folders completes'
 $same=$true;foreach($file in Get-ChildItem -LiteralPath $source -File){$copy=Join-Path (Join-Path $target $source.Replace(':','')) $file.Name;if(-not(Test-Path -LiteralPath $copy) -or (Get-FileHash -LiteralPath $copy).Hash -ne (Get-FileHash -LiteralPath $file.FullName).Hash){$same=$false}}
 Assert $same 'every restored file has the same SHA-256 as its source'
 # Below a user folder an ordinary account cannot set the date of the recreated C:\Users, and restic
 # then skips its content check. An administrator (as on a build server) can, and the check runs.
 if($restored.PSObject.Properties['Warnings'] -and @($restored.Warnings).Count){Assert ($restored.ContentVerified -eq $false -and @($restored.Warnings|Where-Object {$_ -notlike 'failed to restore timestamp*' -and $_ -notlike 'failed to restore attributes*'}).Count -eq 0) 'with such warnings the restore is reported as not verified, never as verified'}
 else{Assert ($restored.ContentVerified -eq $true) 'without warnings the restore is reported as verified'}

 # --- Saving the recovery key ------------------------------------------------------------------------
 $export=Join-Path $private 'recovery-saved.txt'
 $saved=Run 'ExportKey' @{} @{RecoveryKeyPath=$export}
 Assert ($saved.State -eq 'Completed' -and [IO.File]::ReadAllText($export).Contains('Password: '+(Read-Password))) 'a recovery key is saved when the stored password opens the repository'
 $goodKey=[IO.File]::ReadAllText($config.PasswordDpapiPath);$wrong='not-the-password-'+[guid]::NewGuid().ToString('N');$passwords.Add($wrong)
 Set-PrivateTextFile $config.PasswordDpapiPath ($wrong|ConvertTo-SecureString -AsPlainText -Force|ConvertFrom-SecureString)
 try{$bad=Join-Path $private 'recovery-wrong.txt';$refused=Run 'ExportKey' @{} @{RecoveryKeyPath=$bad}}finally{Set-PrivateTextFile $config.PasswordDpapiPath $goodKey}
 Assert ($refused.State -eq 'Failed' -and $refused.Error -like '*does not open*' -and -not(Test-Path -LiteralPath $bad)) 'no recovery key is saved when the stored password does not open the repository'

 # --- Password change, and resuming it after the repository came back somewhere else ------------------
 function New-Secret([string]$name){$p='test-'+$name+'-'+[Convert]::ToBase64String([Security.Cryptography.RandomNumberGenerator]::GetBytes(24));$passwords.Add($p);$f=Join-Path $private ($name+'.dpapi');New-PrivateTextFile $f ($p|ConvertTo-SecureString -AsPlainText -Force|ConvertFrom-SecureString);[pscustomobject]@{Password=$p;File=$f}}
 function Current-KeyId([string]$repository=$repo){@((Restic @('--json','key','list') (Read-Password) $repository).Out|ConvertFrom-Json|Where-Object {$_.current})[0].id}
 function New-Journal([string]$name,[string]$repository,[hashtable]$more){
  # What an interrupted change leaves behind right after it was prepared.
  $next=New-Secret $name
  $journal=[ordered]@{Version=1;Repository=$repository;ConfigPath=$configPath;RecoveryKeyPath=(Join-Path $private ('recovery-'+$name+'.txt'));OldKeyId=(Current-KeyId $repository);NewKeyId=$null;OldPasswordDpapi=([IO.File]::ReadAllText($config.PasswordDpapiPath)).Trim();NewPasswordDpapi=([IO.File]::ReadAllText($next.File)).Trim();Phase='Prepared';CreatedUtc=[DateTime]::UtcNow.ToString('o')}
  foreach($k in $more.Keys){$journal[$k]=$more[$k]}
  New-PrivateTextFile $journalPath ($journal|ConvertTo-Json -Depth 6);$next
 }
 $first=New-Secret 'changed';$before=Read-Password
 $change=Run 'ChangePassword' @{} @{RecoveryKeyPath=(Join-Path $private 'recovery-changed.txt');NewPasswordDpapiPath=$first.File}
 $completedJournal=Get-Content -LiteralPath (Get-ChildItem -LiteralPath $private -Filter '*.completed-*'|Select-Object -First 1).FullName -Raw|ConvertFrom-Json
 Assert ($change.State -eq 'Completed' -and (Read-Password) -ceq $first.Password -and (Restic @('--json','key','list') $before).Code -eq 12) 'a password change completes and retires the old password'
 Assert ($completedJournal.DestinationVolumeId -ceq $config.DestinationVolumeId -and $completedJournal.RepositoryFolder -ceq $config.RepositoryFolder) 'the journal of a password change records the volume and folder of its repository'
 $earlier=New-Journal 'earlier-format' $repo @{}
 $resumed=Run 'ResumePasswordChange'
 Assert ($resumed.State -eq 'Completed' -and (Read-Password) -ceq $earlier.Password -and -not(Test-Path -LiteralPath $journalPath)) 'a journal written by an earlier version (path only) still resumes'
 $foreign=New-Journal 'other-volume' $repo @{DestinationVolumeId='some-other-volume';RepositoryFolder=$config.RepositoryFolder}
 $refused=Run 'ResumePasswordChange'
 Assert ($refused.State -eq 'Failed' -and $refused.Error -like '*another*' -and (Read-Password) -ceq $earlier.Password) 'a journal of another volume is refused and changes nothing'
 Remove-Item -LiteralPath $journalPath
 $pending=New-Journal 'after-move' $repo @{DestinationVolumeId=$config.DestinationVolumeId;RepositoryFolder=$config.RepositoryFolder}
 Move-Item -LiteralPath $repo -Destination (Join-Path $moved $config.RepositoryFolder);$repo=Join-Path $moved $config.RepositoryFolder
 $blocked=Run 'Snapshots' @{} $null $moved
 Assert ($blocked.State -eq 'Failed' -and $blocked.Error -like '*resumed*') 'a pending password change still blocks other work'
 $resumed=Run 'ResumePasswordChange' @{} $null $moved
 Assert ($resumed.State -eq 'Completed' -and (Read-Password) -ceq $pending.Password -and (Restic @('--json','key','list') $earlier.Password).Code -eq 12 -and -not(Test-Path -LiteralPath $journalPath)) 'a pending password change resumes after the repository came back at another path (new drive letter)'
 $after=Run 'Backup' @{} $null $moved
 Assert ($after.State -eq 'Completed') 'backups continue after the resumed password change'

 # --- A lock left by a run that was killed: the next run removes it by itself and carries on ---------
 function Lock-Names {@(Get-ChildItem -LiteralPath (Join-Path $repo 'locks') -File|ForEach-Object {$_.Name})}
 function Wait-Lock {for($i=0;$i -lt 300 -and -not @(Lock-Names).Count;$i++){Start-Sleep -Milliseconds 200}}
 function Start-Hidden([string]$file,[string[]]$arguments,[hashtable]$environment=@{}){
  $psi=[Diagnostics.ProcessStartInfo]::new($file);$psi.UseShellExecute=$false;$psi.CreateNoWindow=$true
  foreach($k in $environment.Keys){$psi.Environment[$k]=$environment[$k]};foreach($a in $arguments){[void]$psi.ArgumentList.Add($a)}
  [Diagnostics.Process]::Start($psi)
 }
 function Start-Engine([string[]]$arguments){Start-Hidden $engine (@('-r',$repo,'--cache-dir',(Join-Path $base 'direct-cache'),'--quiet')+$arguments) @{RESTIC_PASSWORD=(Read-Password)}}
 Assert ($after.PSObject.Properties['LockReleased'] -and $null -eq $after.LockReleased -and -not(Test-Path -LiteralPath (Join-Path $after.RunDirectory 'ReadingLocks.jsonl'))) 'a run that meets no lock looks for none and reports none'
 [IO.File]::WriteAllBytes((Join-Path $source 'large.bin'),[Security.Cryptography.RandomNumberGenerator]::GetBytes(6MB))
 # The worker itself, slowed down so that it is still backing up when it is killed with its whole tree.
 $slowPath=Join-Path $private 'settings-slow.json';$config.RateMBps=0.05;$config|ConvertTo-Json -Depth 7|Set-Content -LiteralPath $slowPath;$config.RateMBps=0
 $killedRun=Join-Path $private 'runs\Backup-killed'
 $worker=Start-Hidden ([Environment]::ProcessPath) @('-NoProfile','-NonInteractive','-File',(Join-Path $PSScriptRoot 'Backup-Worker.ps1'),'-ConfigPath',$slowPath,'-Action','Backup','-RunDirectory',$killedRun,'-TestRoot',$moved)
 try{Wait-Lock}finally{$worker.Kill($true);$worker.WaitForExit();$worker.Dispose()}
 $left=@(Lock-Names)
 Assert ($left.Count -eq 1 -and (Read-BackupStatus (Join-Path $killedRun 'status.json')).State -eq 'BackingUp' -and -not(Test-Path -LiteralPath (Join-Path $killedRun 'result.json'))) 'a backup whose worker is killed part way leaves its lock in the repository'
 $healed=Run 'Backup' @{} $null $moved
 Assert ($healed.State -eq 'Completed' -and $healed.LockReleased.Stage -eq 'CheckingStructure' -and @($healed.LockReleased.Locks).Count -eq 1 -and $healed.LockReleased.Locks[0].Id -ceq $left[0] -and $healed.LockReleased.Locks[0].Pid -gt 0 -and $healed.LockReleased.Locks[0].Exclusive -eq $false -and $healed.LockReleased.Locks[0].CreatedUtc) 'the next backup removes the lock of the killed run by itself, completes, and records which lock it removed'
 Assert (@(Lock-Names).Count -eq 0 -and [IO.File]::ReadAllText((Join-Path $healed.RunDirectory 'CheckingStructure.locked.errors.log')) -like '*already locked*' -and [IO.File]::ReadAllText((Join-Path $healed.RunDirectory 'CheckingStructure.errors.log')) -notlike '*already locked*') 'the step that met the lock was tried once more and passed; what its first try reported is kept beside it'
 # A check that was killed leaves a lock of the other kind (exclusive), which stops even listing the versions.
 $check=Start-Engine @('--limit-download','20','check','--read-data')
 try{Wait-Lock}finally{$check.Kill($true);$check.WaitForExit();$check.Dispose()}
 $left=@(Lock-Names)
 $listed=Run 'Snapshots' @{} $null $moved
 Assert ($left.Count -eq 1 -and $listed.State -eq 'Completed' -and $listed.LockReleased.Stage -eq 'ListingSnapshots' -and $listed.LockReleased.Locks[0].Id -ceq $left[0] -and $listed.LockReleased.Locks[0].Exclusive -eq $true -and @(Lock-Names).Count -eq 0) 'the lock of a killed check is removed the same way when the versions are listed'

 # --- A lock of a backup that is still running is never removed; a partial version that cannot be marked meanwhile ---
 [IO.File]::WriteAllBytes((Join-Path $source 'large2.bin'),[Security.Cryptography.RandomNumberGenerator]::GetBytes(8MB))
 $running=Start-Engine @('--limit-upload','30','backup',$source)
 try{
  Wait-Lock;$held=@(Lock-Names)
  $lockedRun=Run 'Backup' @{} $null $moved
  Assert ($held.Count -eq 1 -and $lockedRun.State -eq 'Failed' -and $lockedRun.Error -like "The new version was saved, but it could not be checked.*locked: a backup is still running on this computer (process $($running.Id))*Nothing is damaged*" -and $lockedRun.Error -notlike '*memory*') 'beside a backup that is still running, the next backup says in plain words that the version was saved, who holds the lock and that nothing is damaged'
  Assert ($null -eq $lockedRun.LockReleased -and ((Lock-Names) -join ',') -ceq ($held -join ',') -and -not(Test-Path -LiteralPath (Join-Path $lockedRun.RunDirectory 'ReleasingLock.jsonl'))) 'the lock of the running backup is left alone'
  [IO.File]::WriteAllText($important,'important, while the repository is locked')
  $partialsBefore=@(Snapshots|Where-Object {Test-PartialSnapshot $_}).Count
  $unmarked=Lock-File $important {Run 'Backup' @{} $null $moved}
  $pendingPath=$config.PasswordDpapiPath+'.partial-pending.local.json'
  Assert ($unmarked.State -eq 'Failed' -and $unmarked.Partial -eq $true -and $unmarked.Error -like '*could not be marked as partial yet*' -and (Test-Path -LiteralPath $pendingPath)) 'a partial version that cannot be marked on a locked repository is noted for later'
  $refused=Run 'Forget' @{} @{SnapshotIds=@($ids['day-2']);Confirmation='DELETE SELECTED HISTORY';ReclaimSpace=$false} $moved
  Assert ($refused.State -eq 'Failed' -and $refused.Error -like '*not marked yet*' -and $ids['day-2'] -in @(Snapshots|ForEach-Object {$_.id})) 'until it is marked, nothing is deleted'
  Assert (-not $running.HasExited -and ((Lock-Names) -join ',') -ceq ($held -join ',')) 'the other backup was running, with its lock, all the while'
  # The backup has ended, but restic itself still sees its process (here because this test keeps it
  # open; a program that took over its process number has the same effect). restic then keeps the lock
  # until 30 minutes after it was made, and so does the worker.
  $running.Kill($true);$running.WaitForExit()
  $keptLock=Run 'Check' @{} $null $moved
  Assert ($keptLock.State -eq 'Failed' -and $keptLock.Error -like '*locked: the run that made the lock has ended*30 minutes*Nothing is damaged*' -and $null -eq $keptLock.LockReleased -and ((Lock-Names) -join ',') -ceq ($held -join ',')) 'a lock that restic itself still keeps is not removed behind its back, and the run says when to try again'
 }finally{if(-not $running.HasExited){$running.Kill($true);$running.WaitForExit()};$ended=$running.Id;$running.Dispose()}
 [IO.File]::WriteAllText($important,'important, after the lock')
 $final=Run 'Backup' @{KeepDays=7;KeepWeeks=4;KeepMonths=3} $null $moved
 $now=@(Snapshots)
 Assert ($final.State -eq 'Completed' -and @($final.LockReleased.Locks).Count -eq 1 -and $final.LockReleased.Locks[0].Id -ceq $held[0] -and $final.LockReleased.Locks[0].Pid -eq $ended -and @(Lock-Names).Count -eq 0) 'once that backup has really ended, the next run removes its lock and completes'
 Assert (-not $final.Retention.PSObject.Properties['Error'] -and -not(Test-Path -LiteralPath $pendingPath) -and $unmarked.Snapshot -notin @($now|ForEach-Object {$_.id}) -and @($now|Where-Object {Test-PartialSnapshot $_}).Count -eq $partialsBefore+1) 'the noted partial version is marked before the next clean-up, which then leaves it alone'

 # --- No plaintext password in anything written -------------------------------------------------------
 $leaks=@()
 foreach($file in Get-ChildItem -LiteralPath $base -Recurse -File -Force|Where-Object {$_.Name -notlike 'recovery-*.txt'}){
  $bytes=[Text.Encoding]::Latin1.GetString([IO.File]::ReadAllBytes($file.FullName))
  foreach($p in $passwords){foreach($encoding in @([Text.Encoding]::UTF8,[Text.Encoding]::Unicode)){if($bytes.Contains([Text.Encoding]::Latin1.GetString($encoding.GetBytes($p)))){$leaks+=$file.FullName}}}
 }
 Assert ($passwords.Count -ge 6 -and $leaks.Count -eq 0) 'no file of any kind holds a password in plain text (UTF-8 or UTF-16), recovery keys aside'
 Assert ([IO.File]::ReadAllText((Join-Path $private 'recovery-after-move.txt')).Contains('Password: '+$pending.Password)) 'the recovery key of the last change holds the password that now opens the repository'
}finally{
 if(Test-Path -LiteralPath $base){
  # A restore recreates protected folders with their original permissions: reset them so the folder can go.
  if(Test-Path -LiteralPath (Join-Path $base 'restored')){& icacls (Join-Path $base 'restored') /reset /T /C /Q 2>&1|Out-Null}
  Get-ChildItem -LiteralPath $base -Recurse -Force -File|ForEach-Object {$_.IsReadOnly=$false};Remove-Item -LiteralPath $base -Recurse -Force
 }
}
Write-Output 'All versioned worker tests passed.'
