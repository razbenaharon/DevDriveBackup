#Requires -Version 7.2
param([Parameter(Mandatory)][ValidatePattern('^[A-Za-z]$')][string]$DestinationDrive)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'Backup.Security.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Backup.Status.psm1') -Force
$id=[guid]::NewGuid().ToString('N');$private=Join-Path $env:LOCALAPPDATA ('DevDriveMirror\security-test-'+$id);$root=Join-Path $PSScriptRoot ('.temporary-worker-test-security-'+$id)
New-Item -ItemType Directory -Path $private,$root,(Join-Path $root 'source')|Out-Null
[IO.File]::WriteAllText((Join-Path $root 'source\sample.txt'),'Data that must survive credential changes.')
$config=Get-Content (Join-Path $PSScriptRoot 'config.example.json') -Raw|ConvertFrom-Json
$config.Source=$root+'\';$config.SourceVolumeId=(Get-Volume -DriveLetter $root.Substring(0,1)).UniqueId;$config.DestinationVolumeId=(Get-Volume -DriveLetter $DestinationDrive).UniqueId
$config.RepositoryFolder='DevDriveBackup-SecurityTest-'+$id;$config.PasswordDpapiPath=Join-Path $private 'key.dpapi';$config.RecoveryKeyPath=Join-Path $private 'original-recovery.txt';$config.Include=@('source');$config.Choices=@([pscustomobject]@{Path='source';Mode='Versioned';Reason='Disposable test source'});$config.DefaultMode='Skip';$config.RateMBps=0;$config.MemoryMiB=512;$config.CpuThreads=1;$config.ReadConcurrency=1;$config.PackMiB=8
$configPath=Join-Path $private 'config.local.json';$config|ConvertTo-Json -Depth 7|Set-Content -LiteralPath $configPath
$repo=$DestinationDrive+':\'+$config.RepositoryFolder;$engine=Join-Path $PSScriptRoot 'bin\restic_0.19.1_windows_amd64.exe'
function Assert($ok,$message){if(-not $ok){throw $message};Write-Output ('PASS '+$message)}
function Run($action,$request=$null,$extra=@{},[switch]$ExpectFailure){
 $run=Join-Path $private ($action+'-'+[guid]::NewGuid().ToString('N'))
 if($null -ne $request){$requestPath=Join-Path $private ('request-'+[guid]::NewGuid().ToString('N')+'.local.json');$request|ConvertTo-Json -Depth 6|Set-Content -LiteralPath $requestPath;$extra.RequestPath=$requestPath}
 & (Join-Path $PSScriptRoot 'Backup-Worker.ps1') -ConfigPath $configPath -Action $action -RunDirectory $run @extra
 $result=Read-BackupStatus (Join-Path $run 'result.json')
 if(-not $ExpectFailure -and $result.State -ne 'Completed'){throw ('Worker failed: '+$result.Error+' '+$run)}
 $result
}
function Authenticate([string]$password){
 $psi=[Diagnostics.ProcessStartInfo]::new($engine);$psi.UseShellExecute=$false;$psi.CreateNoWindow=$true;$psi.RedirectStandardOutput=$true;$psi.RedirectStandardError=$true;$psi.Environment['RESTIC_PASSWORD']=$password
 foreach($arg in @('-r',$repo,'--json','key','list')){[void]$psi.ArgumentList.Add($arg)}
 $process=[Diagnostics.Process]::Start($psi);$stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync();$process.WaitForExit();$text=$stdout.GetAwaiter().GetResult();[void]$stderr.GetAwaiter().GetResult();$result=@{Code=$process.ExitCode;Keys=if($process.ExitCode -eq 0){@($text|ConvertFrom-Json)}else{@()}};$process.Dispose();$result
}
function Read-Password { [Net.NetworkCredential]::new('',(((Get-Content -LiteralPath $config.PasswordDpapiPath -Raw).Trim())|ConvertTo-SecureString)).Password }
$first=Run 'Backup';$old=Read-Password;$oldAuth=Authenticate $old
Assert ($oldAuth.Code -eq 0 -and $oldAuth.Keys.Count -eq 1) 'original repository password authenticates'
$originalPackHashes=@(Get-ChildItem -LiteralPath (Join-Path $repo 'data') -Recurse -File|Get-FileHash|Sort-Object Path|ForEach-Object {$_.Hash})
$export=Join-Path $private 'chosen-recovery.txt';[void](Run 'ExportKey' @{RecoveryKeyPath=$export})
Assert ([IO.File]::ReadAllText($export).Contains('Password: '+$old)) 'chosen recovery export contains the working credential without changing it'
$acl=Get-Acl -LiteralPath $export
Assert ($acl.AreAccessRulesProtected -and $acl.Access.Count -eq 2) 'recovery export ACL is restricted to current user and SYSTEM'
$exportHash=(Get-FileHash -LiteralPath $export).Hash
$blocked=Run 'ExportKey' @{RecoveryKeyPath=$export} @{} -ExpectFailure
Assert ($blocked.State -eq 'Failed' -and (Get-FileHash -LiteralPath $export).Hash -eq $exportHash) 'existing recovery files are never overwritten'
$blocked=Run 'ExportKey' @{RecoveryKeyPath=(Join-Path $root 'source\unsafe.txt')} @{} -ExpectFailure
Assert ($blocked.State -eq 'Failed') 'recovery export inside the source is refused'
$new='מפתח-Test-'+[Convert]::ToBase64String([Security.Cryptography.RandomNumberGenerator]::GetBytes(32));$newSecret=Join-Path $private 'new-password.dpapi';New-PrivateTextFile $newSecret ($new|ConvertTo-SecureString -AsPlainText -Force|ConvertFrom-SecureString)
$newExport=Join-Path $private 'new-recovery.txt'
[void](Run 'ChangePassword' @{RecoveryKeyPath=$newExport;NewPasswordDpapiPath=$newSecret})
$newAuth=Authenticate $new;$oldAfter=Authenticate $old
Assert ($newAuth.Code -eq 0 -and $newAuth.Keys.Count -eq 1 -and $oldAfter.Code -eq 12) 'new password works and replaced old password is retired'
Assert ((Read-Password) -ceq $new -and [IO.File]::ReadAllText($newExport).Contains('Password: '+$new)) 'local protected credential and portable recovery key match the new password'
$latestConfig=Get-Content -LiteralPath $configPath -Raw|ConvertFrom-Json
Assert ($latestConfig.RecoveryKeyPath -eq $newExport -and (Test-Path -LiteralPath $export)) 'chosen key location is saved and prior recovery files are preserved'
$listing=Run 'Snapshots';$snapshots=@(Get-Content -LiteralPath (Join-Path $listing.RunDirectory 'ListingSnapshots.jsonl') -Raw|ConvertFrom-Json)
Assert ($snapshots.Count -eq 1 -and $snapshots[0].id -eq $first.Snapshot) 'existing snapshot IDs survive password changes'
$afterPackHashes=@(Get-ChildItem -LiteralPath (Join-Path $repo 'data') -Recurse -File|Get-FileHash|Sort-Object Path|ForEach-Object {$_.Hash})
Assert (($afterPackHashes -join ',') -ceq ($originalPackHashes -join ',')) 'backup data packs remain byte-for-byte unchanged'
$restored=Join-Path $private 'restored-after-password-change';[void](Run 'Restore' $null @{Snapshot=$first.Snapshot;RestoreTarget=$restored})
$file=@(Get-ChildItem -LiteralPath $restored -Recurse -File)
Assert ($file.Count -eq 1 -and [IO.File]::ReadAllText($file[0].FullName) -eq 'Data that must survive credential changes.') 'existing backup restores and verifies after password change'
# Simulate an interrupted operation whose chosen export path became occupied.
$next=[Convert]::ToBase64String([Security.Cryptography.RandomNumberGenerator]::GetBytes(32));$occupied=Join-Path $private 'occupied-recovery.txt';[IO.File]::WriteAllText($occupied,'Preserve this unrelated file.')
$journalPath=$config.PasswordDpapiPath+'.rotation.local.json'
$journal=@{Version=1;Repository=$repo;ConfigPath=$configPath;RecoveryKeyPath=$occupied;OldKeyId=@($newAuth.Keys|Where-Object {$_.current})[0].id;NewKeyId=$null;OldPasswordDpapi=([IO.File]::ReadAllText($config.PasswordDpapiPath)).Trim();NewPasswordDpapi=($next|ConvertTo-SecureString -AsPlainText -Force|ConvertFrom-SecureString);Phase='Prepared';CreatedUtc=[DateTime]::UtcNow.ToString('o')}
New-PrivateTextFile $journalPath ($journal|ConvertTo-Json -Depth 6)
$failed=Run 'ResumePasswordChange' $null @{} -ExpectFailure
Assert ($failed.State -eq 'Failed' -and $failed.Error -match 'destination changed' -and (Authenticate $new).Code -eq 0) 'failed export after new-key creation retains working old credentials'
$blocked=Run 'Snapshots' $null @{} -ExpectFailure
Assert ($blocked.State -eq 'Failed' -and $blocked.Error -match 'resumed') 'unfinished credential transaction blocks normal operations until resumed'
$resumedExport=Join-Path $private 'resumed-recovery.txt';[void](Run 'ResumePasswordChange' @{RecoveryKeyPath=$resumedExport})
Assert ((Authenticate $next).Code -eq 0 -and (Authenticate $new).Code -eq 12 -and (Read-Password) -ceq $next) 'interrupted password change resumes using a newly chosen recovery location'
Assert ([IO.File]::ReadAllText($occupied) -ceq 'Preserve this unrelated file.' -and -not(Test-Path -LiteralPath $journalPath)) 'resume preserves unrelated files and completes the transaction'
[void](Run 'Restore' $null @{Snapshot=$first.Snapshot;RestoreTarget=(Join-Path $private 'restored-after-resume')})
$second=Run 'Backup';Assert ($second.Snapshot) 'incremental backup still works after password rotation and resume'
$secretLeak=$false
# Every file of any kind, as UTF-8 and as UTF-16; only the recovery key files may hold a password.
foreach($log in Get-ChildItem -LiteralPath $private -Recurse -File -Force|Where-Object {$_.Name -notlike '*recovery*.txt'}){$body=[Text.Encoding]::Latin1.GetString([IO.File]::ReadAllBytes($log.FullName));foreach($secret in @($new,$next,$old)){foreach($encoding in @([Text.Encoding]::UTF8,[Text.Encoding]::Unicode)){if($body.Contains([Text.Encoding]::Latin1.GetString($encoding.GetBytes($secret)))){$secretLeak=$true}}}}
Assert (-not $secretLeak) 'passwords never appear in plain text in any file written, recovery keys aside'
Write-Output ('Artifacts: '+$private)
