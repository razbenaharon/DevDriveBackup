#Requires -Version 7.2
# The versioned worker against a disposable repository, with real restic and no second drive: everything
# (source, repository, password files, run folders, engine cache) lives in one new folder under the
# temporary directory, which Backup-Worker.ps1 -TestRoot uses in place of the backup drive.
# Covers: a partial version (a file that cannot be read), the clean-up of old versions (Keep versions:
# the last N and one a month) beside partial versions and another computer's versions, a preview of
# that clean-up, deleting versions, a restore below protected folders, saving
# the recovery key, a pending password change after the repository moved, a lock left in the repository
# (by a run that was killed: removed; by a backup that is still running: left alone), a versions folder
# that is gone (the backup stops; -CreateNewRepository starts a new one), and plaintext passwords in files.
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
 # Keep versions here: the last 3 and one a month for 12 months. The old versions are dated from the
 # first of this month, so what the rule keeps is the same on every date.
 $month=[datetime]::new($today.Year,$today.Month,1)
 Seed 'old-13-months' $month.AddMonths(-13).AddDays(9).AddHours(10) $computer 'important, 13 months ago'
 Seed 'old-partial' $month.AddMonths(-12).AddDays(14).AddHours(10) $computer 'important, 12 months ago, being edited' -Unreadable
 Seed 'old-10-months' $month.AddMonths(-10).AddDays(9).AddHours(10) $computer 'important, 10 months ago'
 Seed 'other-200' $today.AddDays(-200).AddHours(10) 'other-computer' 'another computer, 200 days ago'
 Seed 'other-50' $today.AddDays(-50).AddHours(10) 'other-computer' 'another computer, 50 days ago'
 Seed 'day-1-early' $today.AddDays(-1).AddHours(8) $computer 'important, early yesterday'
 Seed 'day-1-complete' $today.AddDays(-1).AddHours(10) $computer 'important, yesterday morning: the only copy of this text'
 Seed 'day-1-partial' $today.AddDays(-1).AddHours(18) $computer 'important, being edited' -Unreadable
 [IO.File]::WriteAllText($important,'important, today')
 $kept=Run 'Backup' @{KeepLast=3;KeepMonths=12}
 $left=@(Snapshots|ForEach-Object {$_.id})
 Assert ($kept.State -eq 'Completed' -and $kept.Retention.Preview -eq $false -and $kept.Retention.Last -eq 3 -and $kept.Retention.Months -eq 12 -and $null -eq $kept.Retention.Error) 'a backup with Keep versions completes and cleans up without an error'
 Assert ($ids['day-1-complete'] -in $left -and (Restic @('dump',$ids['day-1-complete'],($inside+'/important.txt'))).Out -eq 'important, yesterday morning: the only copy of this text') 'the complete version of a day survives a later partial version of that day: it is one of the last 3 complete versions'
 Assert ($ids['day-1-partial'] -in $left -and $partialRun.Snapshot -in $left) 'partial versions that fewer than 3 complete versions follow are left alone, and do not count among the last 3'
 Assert ($ids['old-partial'] -notin $left) 'a partial version that 3 or more complete versions follow is deleted'
 Assert ($ids['other-200'] -in $left -and $ids['other-50'] -in $left) 'another computer''s versions are left alone, also those outside this computer''s rule'
 Assert ($ids['old-13-months'] -notin $left -and $ids['day-1-early'] -notin $left -and $ids['old-10-months'] -in $left -and $completeRun.Snapshot -in $left -and $kept.Snapshot -in $left) 'this computer''s versions outside the rule are deleted (13 months old; an earlier one of yesterday); the one of 10 months ago stays as its month''s version'
 Assert ($kept.Retention.Removed -eq 3 -and $kept.Retention.PartialRemoved -eq 1 -and $kept.Retention.Kept -eq 4 -and (@($kept.Retention.Candidates|ForEach-Object {$_.Id}|Sort-Object) -join ',') -ceq (@($ids['old-13-months'],$ids['old-partial'],$ids['day-1-early']|Sort-Object) -join ',')) 'the result names the 3 deleted versions (1 partial) and counts the 4 complete versions kept'
 Assert ($kept.BackupSummary.snapshot_id -eq $kept.Snapshot) 'the backup''s summary is kept through the clean-up'

 # --- Deleting versions by hand ----------------------------------------------------------------------
 $refused=Run 'Forget' @{} @{SnapshotIds=@($kept.Snapshot);Confirmation='DELETE SELECTED HISTORY';ReclaimSpace=$false}
 Assert ($refused.State -eq 'Failed' -and $refused.Error -like '*protected*') 'the newest version cannot be deleted'
 $deleted=Run 'Forget' @{} @{SnapshotIds=@($ids['other-200'],$partialRun.Snapshot);Confirmation='DELETE SELECTED HISTORY';ReclaimSpace=$true}
 $left=@(Snapshots|ForEach-Object {$_.id})
 Assert ($deleted.State -eq 'Completed' -and $ids['other-200'] -notin $left -and $partialRun.Snapshot -notin $left -and $left.Count -eq 6) 'chosen older versions, a partial one among them, are deleted and their space freed'

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
 # Killing a tree returns before every process in it is really gone. restic releases a lock only when
 # the process that made it can no longer be opened, and Windows keeps a process openable for as long
 # as anything still holds it, which on a slow computer outlasts the kill. So the engine processes are
 # noted before the kill and waited for until Windows no longer knows them. Now and then Windows gives
 # the number of a process that ended to a new program straight away (busy computers do); the lock then
 # looks like one of a running program and is rightly kept, by restic and by the worker alike. That is
 # the case tested further down ("lock kept by restic"). It can happen before the wait above ends (the
 # number is still taken) or just after it (the number is given out again before the next run looks).
 # So the next run ($Action) decides, and only two outcomes are right: the lock is removed by itself
 # ($Removed checks the details), or it is kept, nothing is removed, and the run says so in plain words,
 # naming the number that is in use. Then the removal itself is named as skipped, the lock is removed
 # from this disposable repository by hand, and the test goes on. Anything else fails with the result.
 function Test-KilledLock([string]$What,[string]$Action,[int[]]$Numbers,[int]$Taken,[scriptblock]$Removed){
  $before=@(Lock-Names);$r=Run $Action @{} $null $moved;$after=@(Lock-Names)
  $freed=$before.Count -eq 1 -and $r.State -eq 'Completed' -and $r.LockReleased -and @($r.LockReleased.Locks|ForEach-Object {$_.Id}) -ccontains $before[0] -and $before[0] -cnotin $after
  if($freed){& $Removed $r $before;return}
  $named=@($Numbers|Where-Object {$_ -gt 0 -and $r.Error -match "$_"}).Count -gt 0
  $kept=$before.Count -eq 1 -and $r.State -eq 'Failed' -and $r.Error -like '*locked*Nothing is damaged*' -and $null -eq $r.LockReleased -and $before[0] -cin $after -and ($Taken -or $named)
  if(-not $kept){throw "FAIL $What (locks before: $($before -join ','); after: $($after -join ','); result: $($r|ConvertTo-Json -Depth 5 -Compress))"}
  Write-Output "PASS while Windows had given the number of the ended run to another program, $Action kept its lock, removed nothing and said so in plain words"
  Write-Output "SKIP $What (Windows gave the number of the ended process to another program, so its lock was rightly kept)";foreach($n in @(Lock-Names)){Remove-Item -LiteralPath (Join-Path $repo "locks\$n") -Force}
 }
 Add-Type -Namespace BackupTest -Name Native -MemberDefinition '[DllImport("kernel32.dll",SetLastError=true)] public static extern System.IntPtr OpenProcess(uint access,bool inherit,int id);[DllImport("kernel32.dll")] public static extern bool CloseHandle(System.IntPtr handle);'
 function Get-EngineIds {@(Get-Process -Name 'restic*' -ErrorAction SilentlyContinue|ForEach-Object {$_.Id})}
 function Wait-EngineGone([int[]]$Ids){
  $until=(Get-Date).AddSeconds(90)
  do{$open=0;foreach($id in @($Ids)){$h=[BackupTest.Native]::OpenProcess(0x1000,$false,$id);if($h -ne [IntPtr]::Zero){[void][BackupTest.Native]::CloseHandle($h);$open++}};if($open){Start-Sleep -Milliseconds 250}}while($open -and (Get-Date) -lt $until)
  # Said aloud, so a failure of the check that follows is understood (not an error: another backup of this computer may be running)
  $open
 }
 function Start-Engine([string[]]$arguments){Start-Hidden $engine (@('-r',$repo,'--cache-dir',(Join-Path $base 'direct-cache'),'--quiet')+$arguments) @{RESTIC_PASSWORD=(Read-Password)}}
 Assert ($after.PSObject.Properties['LockReleased'] -and $null -eq $after.LockReleased -and -not(Test-Path -LiteralPath (Join-Path $after.RunDirectory 'ReadingLocks.jsonl'))) 'a run that meets no lock looks for none and reports none'
 [IO.File]::WriteAllBytes((Join-Path $source 'large.bin'),[Security.Cryptography.RandomNumberGenerator]::GetBytes(6MB))
 # The worker itself, slowed down so that it is still backing up when it is killed with its whole tree.
 $slowPath=Join-Path $private 'settings-slow.json';$config.RateMBps=0.05;$config|ConvertTo-Json -Depth 7|Set-Content -LiteralPath $slowPath;$config.RateMBps=0
 $killedRun=Join-Path $private 'runs\Backup-killed'
 $worker=Start-Hidden ([Environment]::ProcessPath) @('-NoProfile','-NonInteractive','-File',(Join-Path $PSScriptRoot 'Backup-Worker.ps1'),'-ConfigPath',$slowPath,'-Action','Backup','-RunDirectory',$killedRun,'-TestRoot',$moved)
 try{Wait-Lock}finally{$engines=Get-EngineIds;$worker.Kill($true);$worker.WaitForExit();$worker.Dispose();$taken=Wait-EngineGone $engines}
 $left=@(Lock-Names)
 Assert ($left.Count -eq 1 -and (Read-BackupStatus (Join-Path $killedRun 'status.json')).State -eq 'BackingUp' -and -not(Test-Path -LiteralPath (Join-Path $killedRun 'result.json'))) 'a backup whose worker is killed part way leaves its lock in the repository'
 # While the number is known to be taken, a check (which changes nothing) meets the lock instead of a backup.
 $healAction=if($taken){'Check'}else{'Backup'};$healStage=if($taken){'Verifying'}else{'CheckingStructure'}
 Test-KilledLock 'the next backup removes the lock of the killed run by itself' $healAction $engines $taken {param($healed,$left)
  Assert ($healed.State -eq 'Completed' -and $healed.LockReleased.Stage -eq $healStage -and @($healed.LockReleased.Locks).Count -eq 1 -and $healed.LockReleased.Locks[0].Id -ceq $left[0] -and $healed.LockReleased.Locks[0].Pid -gt 0 -and $healed.LockReleased.Locks[0].Exclusive -eq $false -and $healed.LockReleased.Locks[0].CreatedUtc) 'the next run removes the lock of the killed backup by itself, completes, and records which lock it removed'
  Assert (@(Lock-Names).Count -eq 0 -and [IO.File]::ReadAllText((Join-Path $healed.RunDirectory ($healStage+'.locked.errors.log'))) -like '*already locked*' -and [IO.File]::ReadAllText((Join-Path $healed.RunDirectory ($healStage+'.errors.log'))) -notlike '*already locked*') 'the step that met the lock was tried once more and passed; what its first try reported is kept beside it'
 }
 # A check that was killed leaves a lock of the other kind (exclusive), which stops even listing the versions.
 $check=Start-Engine @('--limit-download','20','check','--read-data')
 try{Wait-Lock}finally{$engines=@(Get-EngineIds)+@($check.Id);$check.Kill($true);$check.WaitForExit();$check.Dispose();$taken=Wait-EngineGone $engines}
 Test-KilledLock 'the lock of a killed check is removed the same way when the versions are listed' 'Snapshots' $engines $taken {param($listed,$left)
  Assert ($left.Count -eq 1 -and $listed.State -eq 'Completed' -and $listed.LockReleased.Stage -eq 'ListingSnapshots' -and $listed.LockReleased.Locks[0].Id -ceq $left[0] -and $listed.LockReleased.Locks[0].Exclusive -eq $true -and @(Lock-Names).Count -eq 0) 'the lock of a killed check is removed the same way when the versions are listed'
 }

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
  $refused=Run 'Forget' @{} @{SnapshotIds=@($ids['old-10-months']);Confirmation='DELETE SELECTED HISTORY';ReclaimSpace=$false} $moved
  Assert ($refused.State -eq 'Failed' -and $refused.Error -like '*not marked yet*' -and $ids['old-10-months'] -in @(Snapshots|ForEach-Object {$_.id})) 'until it is marked, nothing is deleted'
  Assert (-not $running.HasExited -and ((Lock-Names) -join ',') -ceq ($held -join ',')) 'the other backup was running, with its lock, all the while'
  # The backup has ended, but restic itself still sees its process (here because this test keeps it
  # open; a program that took over its process number has the same effect). restic then keeps the lock
  # until 30 minutes after it was made, and so does the worker.
  $running.Kill($true);$running.WaitForExit()
  $keptLock=Run 'Check' @{} $null $moved
  Assert ($keptLock.State -eq 'Failed' -and $keptLock.Error -like '*locked: the run that made the lock has ended*30 minutes*Nothing is damaged*' -and $null -eq $keptLock.LockReleased -and ((Lock-Names) -join ',') -ceq ($held -join ',')) 'a lock that restic itself still keeps is not removed behind its back, and the run says when to try again'
 }finally{if(-not $running.HasExited){$running.Kill($true);$running.WaitForExit()};$ended=$running.Id;$running.Dispose()}
 [IO.File]::WriteAllText($important,'important, after the lock')
 $final=Run 'Backup' @{KeepLast=3;KeepMonths=12} $null $moved
 $now=@(Snapshots);$partialNow=@($now|Where-Object {Test-PartialSnapshot $_})
 Assert ($final.State -eq 'Completed' -and @($final.LockReleased.Locks).Count -eq 1 -and $final.LockReleased.Locks[0].Id -ceq $held[0] -and $final.LockReleased.Locks[0].Pid -eq $ended -and @(Lock-Names).Count -eq 0) 'once that backup has really ended, the next run removes its lock and completes'
 # The noted version is marked (its ID changes) and, with one newer complete version, stays. Yesterday's
 # partial version has by now more than 3 newer complete versions and goes.
 Assert ($null -eq $final.Retention.Error -and -not(Test-Path -LiteralPath $pendingPath) -and $unmarked.Snapshot -notin @($now|ForEach-Object {$_.id}) -and $partialsBefore -eq 1 -and $partialNow.Count -eq 1 -and $partialNow[0].id -cne $ids['day-1-partial'] -and $partialNow[0].id -cnotin @($final.Retention.Candidates|ForEach-Object {$_.Id})) 'the noted partial version is marked before the next clean-up and, with fewer than 3 newer complete versions, stays'
 Assert ($final.Retention.PartialRemoved -eq 1 -and $ids['day-1-partial'] -in @($final.Retention.Candidates|Where-Object {$_.Partial}|ForEach-Object {$_.Id}) -and $final.Snapshot -in @($now|ForEach-Object {$_.id}) -and $ids['old-10-months'] -in @($now|ForEach-Object {$_.id})) 'the older partial version, which 3 complete versions now follow, is deleted; the month''s version of 10 months ago stays'

 # --- A preview of the clean-up deletes nothing ----------------------------------------------------------
 $before=@($now|ForEach-Object {$_.id})
 $previewed=Run 'Backup' @{KeepLast=1;KeepMonths=0;RetentionPreview=$true} $null $moved
 $after=@(Snapshots|ForEach-Object {$_.id});$listed=@($previewed.Retention.Candidates|ForEach-Object {$_.Id})
 Assert ($previewed.State -eq 'Completed' -and $previewed.Retention.Preview -eq $true -and $previewed.Retention.Removed -eq 0 -and $null -eq $previewed.Retention.Error -and ((@($after|Sort-Object) -join ',') -ceq (@($before+$previewed.Snapshot|Sort-Object) -join ','))) 'a backup with a preview of the clean-up deletes nothing: every version is still there, and the new one'
 Assert ($listed.Count -ge 4 -and $final.Snapshot -in $listed -and $ids['old-10-months'] -in $listed -and $previewed.Snapshot -notin $listed -and $partialNow[0].id -notin $listed -and @($listed|Where-Object {$_ -notin $after}).Count -eq 0 -and -not(Test-Path -LiteralPath (Join-Path $previewed.RunDirectory 'DeletingOldVersions.jsonl')) -and -not(Test-Path -LiteralPath (Join-Path $previewed.RunDirectory 'FreeingSpace.jsonl'))) 'it lists what last 1 and months 0 would delete: every complete version but the newest, and not the partial version that 2 complete versions follow'

 # --- The versions folder is gone: the backup stops and lets the user decide -------------------------
 # (Before, a backup that found no repository where one had been quietly started a new, empty one.)
 Assert ($partialRun.RepositoryMissing -eq $false -and $partialRun.RepositoryCreated -eq $true -and $completeRun.RepositoryMissing -eq $false -and $completeRun.RepositoryCreated -eq $false -and $null -eq $completeRun.Note) 'the first-ever backup created the versions folder without being asked to; later backups create nothing'
 $name=[string]$config.RepositoryFolder;$aside=$repo+'-renamed';$versionsBefore=@(Snapshots|ForEach-Object {$_.id});$passwordBefore=Read-Password
 Rename-Item -LiteralPath $repo -NewName ($name+'-renamed')
 # Everything on the stand-in for the backup drive: every folder and file, with each file's size and date.
 $onDrive={@(Get-ChildItem -LiteralPath $moved -Recurse -Force|ForEach-Object {$_.FullName+$(if(-not $_.PSIsContainer){'*'+$_.Length+'*'+$_.LastWriteTimeUtc.Ticks})}|Sort-Object) -join '|'};$driveBefore=& $onDrive
 $gone=Run 'Backup' @{} $null $moved
 Assert ($gone.State -eq 'Failed' -and $gone.RepositoryMissing -eq $true -and $gone.Error -ceq "The versions folder $name was not found on the backup drive. It may have been renamed, moved or deleted. Nothing was changed.") 'a backup whose versions folder was renamed fails, says so in plain words and reports RepositoryMissing'
 Assert (-not(Test-Path -LiteralPath $repo) -and (& $onDrive) -ceq $driveBefore -and $gone.RepositoryCreated -eq $false -and @('Initializing','BackingUp'|Where-Object {Test-Path -LiteralPath (Join-Path $gone.RunDirectory ($_+'.jsonl'))}).Count -eq 0) 'it creates and changes nothing: no folder of that name, no new or changed file on the backup drive, no repository'
 $others=@(
  @('Snapshots',@{},$null),@('Check',@{},$null),@('Preview',@{CreateNewRepository=$true},$null),
  @('Restore',@{Snapshot=$versionsBefore[0];RestoreTarget=(Join-Path $base 'restored-from-nothing')},$null),
  @('Forget',@{},@{SnapshotIds=@($versionsBefore[0]);Confirmation='DELETE SELECTED HISTORY';ReclaimSpace=$false}),
  @('ExportKey',@{},@{RecoveryKeyPath=(Join-Path $private 'recovery-from-nothing.txt')}))
 foreach($other in $others){
  $r=Run $other[0] $other[1] $other[2] $moved
  if($r.State -ne 'Failed' -or $r.RepositoryMissing -ne $true -or $r.RepositoryCreated -ne $false -or $r.Error -notlike "The versions folder $name was not found on the backup drive*Nothing was changed." -or (Test-Path -LiteralPath $repo) -or (& $onDrive) -cne $driveBefore){throw "FAIL $($other[0]) without its versions folder: $($r|ConvertTo-Json -Depth 4 -Compress)"}
 }
 Assert (-not(Test-Path -LiteralPath (Join-Path $private 'recovery-from-nothing.txt')) -and -not(Test-Path -LiteralPath (Join-Path $base 'restored-from-nothing'))) 'listing, checking, restoring, deleting versions and saving the recovery key report the missing folder the same way and create nothing; the switch counts for a backup only'
 $fresh=Run 'Backup' @{CreateNewRepository=$true} $null $moved
 $new=@(Snapshots)
 Assert ($fresh.State -eq 'Completed' -and $fresh.RepositoryMissing -eq $false -and $fresh.RepositoryCreated -eq $true -and $fresh.Note -like "A new, empty versions folder $name was created*" -and (Test-Path -LiteralPath (Join-Path $fresh.RunDirectory 'Initializing.jsonl'))) 'with -CreateNewRepository the backup starts a new versions folder where none is, completes and says that it did'
 Assert ($new.Count -eq 1 -and $new[0].id -ceq $fresh.Snapshot -and (Read-Password) -ceq $passwordBefore -and (Restic @('check')).Code -eq 0) 'the new repository holds one version and opens with the password that was already stored'
 Rename-Item -LiteralPath $repo -NewName ($name+'-new')
 New-Item -ItemType Directory -Path $repo|Out-Null
 $hollow=Run 'Backup' @{} $null $moved
 Assert ($hollow.State -eq 'Failed' -and $hollow.RepositoryMissing -eq $true -and $hollow.RepositoryCreated -eq $false -and $hollow.Error -like "The versions folder $name on the backup drive is empty or incomplete*Nothing was changed." -and @(Get-ChildItem -LiteralPath $repo -Force).Count -eq 0) 'an empty folder of that name is not taken for a new start either, and stays empty'
 $filled=Run 'Backup' @{CreateNewRepository=$true} $null $moved
 $new=@(Snapshots)
 Assert ($filled.State -eq 'Completed' -and $filled.RepositoryMissing -eq $false -and $filled.RepositoryCreated -eq $true -and $filled.Note -like "A new, empty versions folder $name was created*" -and $new.Count -eq 1 -and $new[0].id -ceq $filled.Snapshot) 'with the switch, an empty folder of that name gets a new repository with one version'
 Rename-Item -LiteralPath $repo -NewName ($name+'-new-2');Rename-Item -LiteralPath $aside -NewName $name
 $back=Run 'Backup' @{} $null $moved
 Assert ($back.State -eq 'Completed' -and $back.RepositoryMissing -eq $false -and $back.RepositoryCreated -eq $false -and $null -eq $back.Note -and (@(Snapshots|ForEach-Object {$_.id}|Sort-Object) -join ',') -ceq (@($versionsBefore+$back.Snapshot|Sort-Object) -join ',')) 'once the folder has its name back a normal backup works again, and every earlier version is still there'
 $again=Run 'Backup' @{CreateNewRepository=$true} $null $moved
 Assert ($again.State -eq 'Completed' -and $again.RepositoryCreated -eq $false -and $null -eq $again.Note -and -not(Test-Path -LiteralPath (Join-Path $again.RunDirectory 'Initializing.jsonl')) -and (@(Snapshots|ForEach-Object {$_.id}|Sort-Object) -join ',') -ceq (@($versionsBefore+$back.Snapshot+$again.Snapshot|Sort-Object) -join ',')) 'while the versions folder is there the switch changes nothing: no repository is ever created over an existing one'
 $reported=@($partialRun,$completeRun,$gone,$r,$fresh,$hollow,$filled,$back,$again)
 Assert (@($reported|Where-Object {$result=$_;@('RepositoryMissing','RepositoryCreated','Note'|Where-Object {-not $result.PSObject.Properties[$_]}).Count -or $result.RepositoryMissing -isnot [bool] -or $result.RepositoryCreated -isnot [bool]}).Count -eq 0) 'every result, failed or completed, carries RepositoryMissing, RepositoryCreated and Note'

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
