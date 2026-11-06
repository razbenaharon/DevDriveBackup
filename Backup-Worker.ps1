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
 # Backup only: afterwards keep one version per day / week / month for this long and delete the rest
 # (all 0: keep every version).
 [ValidateRange(0,3650)][int]$KeepDays=0,
 [ValidateRange(0,520)][int]$KeepWeeks=0,
 [ValidateRange(0,240)][int]$KeepMonths=0
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'Backup.Status.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Backup.History.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Backup.Security.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Backup.Selection.psm1') -Force
if(-not $RunDirectory){$RunDirectory=Join-Path $env:LOCALAPPDATA ('DevDriveMirror\runs\'+(Get-Date -Format 'yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N'))}
New-Item -ItemType Directory -Path $RunDirectory -Force | Out-Null
$script:status=[ordered]@{State='Starting';Action=$Action;WorkerPid=$PID;StartedUtc=[DateTime]::UtcNow.ToString('o');UpdatedUtc='';Progress=$null;MemoryMiB=0;PeakMemoryMiB=0;CpuPercent=0;Error=$null;Snapshot=$null;RunDirectory=$RunDirectory}
function Save-Status {
 $script:status.UpdatedUtc=[DateTime]::UtcNow.ToString('o')
 [void](Write-BackupStatus $script:status (Join-Path $RunDirectory 'status.json') -BestEffort)
}
function Assert-PlainAncestors([string]$Path) {
 $p=[IO.Path]::GetFullPath($Path)
 while($p){if(Test-Path -LiteralPath $p){if((Get-Item -LiteralPath $p -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw "Linked repository/root/restore path refused: $p"}};$parent=[IO.Directory]::GetParent($p);if(-not $parent){break};$p=$parent.FullName}
}
function Run-Engine([string[]]$EngineArguments,[string]$Stage,[string]$InputSecret) {
 $script:status.State=$Stage;Save-Status
 $psi=[Diagnostics.ProcessStartInfo]::new($script:engine);$psi.UseShellExecute=$false;$psi.CreateNoWindow=$true;$psi.RedirectStandardOutput=$true;$psi.RedirectStandardError=$true
 $connections=if($Stage -in 'DeletingHistory','DeletingOldVersions' -and $EngineArguments -contains '--prune'){[math]::Max(2,$script:backendConnections)}else{$script:backendConnections}
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
    try{$event=$line|ConvertFrom-Json;if($event.message_type -eq 'status'){$script:status.Progress=$event};if($event.message_type -eq 'summary'){$script:status.Progress=$event;if($event.PSObject.Properties['snapshot_id']){$script:status.Snapshot=$event.snapshot_id}}}catch{}
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
  # A restore below a protected folder (for example C:\Users) can restore every file but fail to set
  # the timestamps of the recreated parent folders. That is a warning, not a failed restore.
  $ignored=@($errorText -split "`r?`n"|Where-Object {$_ -match '^ignoring error for '})
  if($Stage -eq 'Restoring' -and $process.ExitCode -eq 1 -and $ignored.Count -and -not @($ignored|Where-Object {$_ -notmatch 'failed to restore (timestamp|attributes|security descriptor)'}).Count){
   $script:status|Add-Member -NotePropertyName Warnings -NotePropertyValue @($ignored) -Force
  }elseif($process.ExitCode -ne 0){
   $hint=if($Stage -eq 'DeletingHistory'){'History deletion may be partial. Refresh history before retrying.'}elseif($Stage -eq 'BackingUp'){'Code 3 means an incomplete snapshot.'}else{'The operation did not complete successfully.'}
   $engineError=[InvalidOperationException]::new("Restic $Stage returned exit code $($process.ExitCode). $hint See $Stage.errors.log. A memory allocation failure requires a higher memory budget.")
   $engineError.Data['ExitCode']=$process.ExitCode;throw $engineError
  }
 }finally{if($started -and -not $process.HasExited){$process.Kill($true)};$output.Dispose();$job.Dispose();$process.Dispose()}
}
function Save-RecoveryLocation([string]$Path) {
 $fresh=Get-Content -LiteralPath $ConfigPath -Raw|ConvertFrom-Json
 if($fresh.PasswordDpapiPath -ine $script:config.PasswordDpapiPath -or $fresh.DestinationVolumeId -cne $script:config.DestinationVolumeId -or $fresh.RepositoryFolder -cne $script:config.RepositoryFolder){throw 'Configuration changed during key management. Resume with the original repository configuration.'}
 $fresh.RecoveryKeyPath=$Path;[void](Write-BackupStatus $fresh $ConfigPath);$script:config=$fresh
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
  if($journal.Repository -ine $script:repository -or $journal.ConfigPath -ine [IO.Path]::GetFullPath($ConfigPath)){throw 'Password-change journal belongs to another configuration or repository'}
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
  $journal=[pscustomobject]@{Version=1;Repository=$script:repository;ConfigPath=[IO.Path]::GetFullPath($ConfigPath);RecoveryKeyPath=$export;OldKeyId=$current[0].id;NewKeyId=$null;OldPasswordDpapi=([IO.File]::ReadAllText($keyPath)).Trim();NewPasswordDpapi=$protectedNew.Trim();Phase='Prepared';CreatedUtc=[DateTime]::UtcNow.ToString('o')}
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
 $script:config=Get-Content -LiteralPath $ConfigPath -Raw|ConvertFrom-Json
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
 if($Action -in @('Backup','Preview')){Assert-PlainAncestors $source;if((Get-Volume -DriveLetter $source.Substring(0,1)).UniqueId -ne $script:config.SourceVolumeId){throw 'Source volume identity changed'}}
 $volume=@(Get-Volume -UniqueId $script:config.DestinationVolumeId|Where-Object {$_.DriveLetter})
 if($volume.Count -ne 1){throw 'Expected destination volume is missing or ambiguous'}
 if($volume[0].UniqueId -eq $script:config.SourceVolumeId){throw 'Backup must use a separate volume'}
 $folder=[string]$script:config.RepositoryFolder
 if($folder -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,79}$' -or $folder.EndsWith('.')){throw 'RepositoryFolder must be a single plain folder name'}
 $script:repository=Join-Path ($volume[0].DriveLetter+':\') $folder;Assert-PlainAncestors $script:repository
 if($Action -in @('Backup','Preview') -and $volume[0].SizeRemaining -lt 5GB){throw 'Less than 5 GiB free on the backup volume'}
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
  # Backup Center's private folders (protected passwords, run state, recovery keys of every source)
  # are never backed up, whatever the selection, as in the plain copy.
  $privateExcludes=@((Join-Path $env:LOCALAPPDATA 'DevDriveMirror'),(Join-Path $env:USERPROFILE 'Backup Center recovery keys')|ForEach-Object {
   [regex]::Replace([IO.Path]::GetFullPath($_).TrimEnd('\').Replace('\','/'),'[\[*?]',{param($m) '['+$m.Value+']'})
  })
  $script:status.Sources=$sources;$script:status.SelectionExcludes=$selectionExcludes
 }
 $script:cache=Join-Path $env:LOCALAPPDATA 'DevDriveMirror\restic-cache';New-Item -ItemType Directory -Path $script:cache -Force|Out-Null
 $keyPath=[IO.Path]::GetFullPath($script:config.PasswordDpapiPath);$exists=Test-Path -LiteralPath (Join-Path $script:repository 'config')
 $recoveryPath=[IO.Path]::GetFullPath($script:config.RecoveryKeyPath)
 if($keyPath -ieq $recoveryPath){throw 'Protected password and portable recovery key must be different files'}
 foreach($privatePath in @($keyPath,$recoveryPath)){Assert-PlainAncestors $privatePath;if($privatePath.StartsWith($source,[StringComparison]::OrdinalIgnoreCase) -or $privatePath.StartsWith($script:repository+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Keep password/recovery files outside source and repository'}}
 New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($keyPath)) -Force|Out-Null
 $script:runLock=[IO.File]::Open($keyPath+'.run.lock',[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
 if((Test-Path -LiteralPath ($keyPath+'.rotation.local.json')) -and $Action -ne 'ResumePasswordChange'){throw 'An interrupted password change must be resumed from Password and recovery before using this repository.'}
 if(Test-Path -LiteralPath $keyPath){$secure=(Get-Content -LiteralPath $keyPath -Raw).Trim()|ConvertTo-SecureString;$script:password=[Net.NetworkCredential]::new('',$secure).Password}
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
 }
 $base=@('backup','--read-concurrency',[string]$script:config.ReadConcurrency,'--tag','devdrive')
 if($ForceRead){$base+='--force'}
 foreach($exclude in @($script:config.Exclude)+$selectionExcludes+$privateExcludes){if($exclude){$base+=@('--iexclude',[string]$exclude)}}
 switch($Action){
  {$_ -in @('ExportKey','ChangePassword','ResumePasswordChange')} {Invoke-KeyManagement}
  'Backup' {
   Run-Engine ($base+@('--')+$sources) 'BackingUp';Run-Engine @('check') 'CheckingStructure'
   if($KeepDays+$KeepWeeks+$KeepMonths -gt 0){
    # The backup itself has succeeded and been checked. A failed clean-up is reported, not a failed backup.
    $new=$script:status.Snapshot
    try{
     Run-Engine (Get-RetentionArguments $KeepDays $KeepWeeks $KeepMonths) 'PlanningCleanUp'
     $plan=@(Get-Content -LiteralPath (Join-Path $RunDirectory 'PlanningCleanUp.jsonl') -Raw|ConvertFrom-Json)
     Run-Engine @('snapshots','--tag','devdrive') 'ReadingHistory'
     $available=@(Get-Content -LiteralPath (Join-Path $RunDirectory 'ReadingHistory.jsonl') -Raw|ConvertFrom-Json)
     $remove=@(Get-RetentionRemovals $plan $new $available)
     [IO.File]::WriteAllText((Join-Path $RunDirectory 'clean-up-plan.json'),(ConvertTo-Json @($remove) -Depth 8))
     if($remove.Count){Run-Engine (@('forget')+@($remove|ForEach-Object {$_.id})+'--prune') 'DeletingOldVersions';Run-Engine @('check') 'CheckingStructure'}
     $script:status.Retention=[ordered]@{Days=$KeepDays;Weeks=$KeepWeeks;Months=$KeepMonths;Removed=$remove.Count;Kept=($available.Count-$remove.Count)}
    }catch{
     $script:status.Retention=[ordered]@{Days=$KeepDays;Weeks=$KeepWeeks;Months=$KeepMonths;Removed=0;Error=$_.Exception.Message}
    }
   }
  }
  'Preview' {Run-Engine ($base+@('--dry-run','--')+$sources) 'Previewing'}
  'Check' {$args=@('check');if($ReadAllData){$args+='--read-data'};Run-Engine $args 'Verifying'}
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
   Run-Engine @('snapshots') 'ReadingHistory'
   $available=Get-Content -LiteralPath (Join-Path $RunDirectory 'ReadingHistory.jsonl') -Raw|ConvertFrom-Json
   $plan=@(Get-HistoryDeletionPlan $available @($request.SnapshotIds))
   [IO.File]::WriteAllText((Join-Path $RunDirectory 'deletion-plan.json'),($plan|ConvertTo-Json -Depth 8))
   $forgetArgs=@('forget')+@($plan.id)
   if($request.ReclaimSpace -eq $true){$forgetArgs+='--prune'}
   Run-Engine $forgetArgs 'DeletingHistory'
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
   Run-Engine $restoreArguments 'Restoring'
  }
 }
 $script:status.State='Completed';$script:status.UpdatedUtc=[DateTime]::UtcNow.ToString('o');[void](Write-BackupStatus $script:status (Join-Path $RunDirectory 'result.json'));Save-Status
}catch{$script:status.State='Failed';$script:status.Error=$_.Exception.Message;[IO.File]::WriteAllText((Join-Path $RunDirectory 'worker-error.txt'),($_|Out-String)+[Environment]::NewLine+$_.ScriptStackTrace);[void](Write-BackupStatus $script:status (Join-Path $RunDirectory 'result.json') -BestEffort);Save-Status;exit 1}
finally{$script:password=$null;if(Get-Variable -Scope Script -Name runLock -ErrorAction SilentlyContinue){if($script:runLock){$script:runLock.Dispose()}}}
