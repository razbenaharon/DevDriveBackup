#Requires -Version 7.2
param([Parameter(Mandatory)][string]$DestinationDrive)
$ErrorActionPreference='Stop'
if($DestinationDrive -notmatch '^[A-Za-z]$'){throw 'Expected one drive letter'}
$id=[guid]::NewGuid().ToString('N')
$root=Join-Path $PSScriptRoot ('.temporary-worker-test-v2-'+$id)
$private=Join-Path $env:LOCALAPPDATA ('DevDriveMirror\test-'+$id)
New-Item -ItemType Directory -Path $root,$private,(Join-Path $root 'source\node_modules') -Force|Out-Null
$source=Join-Path $root 'source'
[IO.File]::WriteAllText((Join-Path $source 'עברית [sample].txt'),'first version')
[IO.File]::WriteAllText((Join-Path $source 'עברית s.txt'),'must not match the bracket filename')
[IO.File]::WriteAllText((Join-Path $source 'node_modules\omit.txt'),'regenerable')
[IO.File]::WriteAllBytes((Join-Path $source 'random.bin'),[Security.Cryptography.RandomNumberGenerator]::GetBytes(8MB))
$config=Get-Content (Join-Path $PSScriptRoot 'config.example.json') -Raw|ConvertFrom-Json
$config.Source=$root+'\';$config.SourceVolumeId=(Get-Volume -DriveLetter $root.Substring(0,1)).UniqueId;$config.DestinationVolumeId=(Get-Volume -DriveLetter $DestinationDrive).UniqueId
$config.RepositoryFolder='DevDriveBackup-Test-'+$id;$config.PasswordDpapiPath=Join-Path $private 'key.dpapi';$config.RecoveryKeyPath=Join-Path $private 'recovery.txt';$config.Include=@('source');$config.Choices=@([pscustomobject]@{Path='source';Mode='Versioned';Reason='Disposable test source'});$config.DefaultMode='Skip';$config.RateMBps=8;$config.MemoryMiB=512;$config.ReadConcurrency=1;$config.CpuThreads=1;$config.PackMiB=8
$configPath=Join-Path $private 'settings.json';$config|ConvertTo-Json -Depth 7|Set-Content $configPath
function Assert($ok,$message){if(-not $ok){throw $message};Write-Output ('PASS '+$message)}
function Run($action,$extra=@{}){
 $run=Join-Path $private ($action+'-'+[guid]::NewGuid().ToString('N'))
 & (Join-Path $PSScriptRoot 'Backup-Worker.ps1') -ConfigPath $configPath -Action $action -RunDirectory $run @extra
 $state=Get-Content (Join-Path $run 'status.json') -Raw|ConvertFrom-Json
 if($state.State -ne 'Completed'){throw ('Worker failed: '+$state.Error+' '+$run)}
 $state
}
$first=Run 'Backup';Assert ($first.Snapshot.Length -gt 7) 'encrypted first snapshot created'
Assert ($first.PeakMemoryMiB -lt 512) '512 MiB memory budget observed'
$restored=Join-Path $private 'restored-first'
[void](Run 'Restore' @{RestoreTarget=$restored;Snapshot=$first.Snapshot})
$file=Get-ChildItem -LiteralPath $restored -Recurse -File|Where-Object {$_.Name -eq 'עברית [sample].txt'}
Assert ($file.Count -eq 1 -and [IO.File]::ReadAllText($file.FullName) -eq 'first version') 'Hebrew and bracket filename restored with content verification'
Assert (@(Get-ChildItem -LiteralPath $restored -Recurse -File|Where-Object {$_.Name -eq 'omit.txt'}).Count -eq 0) 'dependency cache excluded'
$random=Get-ChildItem -LiteralPath $restored -Recurse -File|Where-Object {$_.Name -eq 'random.bin'}
Assert ((Get-FileHash -LiteralPath $random.FullName).Hash -eq (Get-FileHash -LiteralPath (Join-Path $source 'random.bin')).Hash) 'binary source and restored SHA-256 match'
[IO.File]::WriteAllText((Join-Path $source 'עברית [sample].txt'),'second version')
$second=Run 'Backup';Assert ($second.Snapshot -ne $first.Snapshot) 'changed file creates another version'
[void](Run 'Preview');[void](Run 'Check' @{ReadAllData=$true})
$restoredOld=Join-Path $private 'restored-old'
[void](Run 'Restore' @{RestoreTarget=$restoredOld;Snapshot=$first.Snapshot})
$old=Get-ChildItem -LiteralPath $restoredOld -Recurse -File|Where-Object {$_.Name -eq 'עברית [sample].txt'}
Assert ([IO.File]::ReadAllText($old.FullName) -eq 'first version') 'old snapshot survives source overwrite'
Assert ([IO.File]::ReadAllText((Join-Path $source 'עברית [sample].txt')) -eq 'second version') 'restore never modifies source'
$changed=Join-Path $source 'עברית [sample].txt';$stamp=[IO.File]::GetLastWriteTimeUtc($changed)
[IO.File]::WriteAllText($changed,'forced version');[IO.File]::SetLastWriteTimeUtc($changed,$stamp)
$forced=Run 'Backup' @{ForceRead=$true};$forceTarget=Join-Path $private 'restored-forced'
[void](Run 'Restore' @{RestoreTarget=$forceTarget;Snapshot=$forced.Snapshot})
$forcedFile=Get-ChildItem -LiteralPath $forceTarget -Recurse -File|Where-Object {$_.Name -eq 'עברית [sample].txt'}
Assert ([IO.File]::ReadAllText($forcedFile.FullName) -eq 'forced version') 'forced reread captures same-size same-time changes'
$bad=$config.PSObject.Copy();$bad.SourceVolumeId='WRONG-VOLUME';$badPath=Join-Path $private 'bad-source.json';$bad|ConvertTo-Json -Depth 7|Set-Content $badPath
$badRun=Join-Path $private 'wrong-source'
& (Join-Path $PSScriptRoot 'Backup-Worker.ps1') -ConfigPath $badPath -Action Backup -RunDirectory $badRun
$badState=Get-Content (Join-Path $badRun 'status.json') -Raw|ConvertFrom-Json
Assert ($badState.State -eq 'Failed' -and $badState.Error -match 'identity') 'wrong source volume fails before backup'
$badRestore=Join-Path $private 'existing-restore-target'
& (Join-Path $PSScriptRoot 'Backup-Worker.ps1') -ConfigPath $configPath -Action Restore -RestoreTarget $forceTarget -RunDirectory $badRestore
$badState=Get-Content (Join-Path $badRestore 'status.json') -Raw|ConvertFrom-Json
Assert ($badState.State -eq 'Failed' -and $badState.Error -match 'nonexistent') 'restore refuses an existing target'
$historyRun=Run 'Snapshots'
$snapshots=@(Get-Content -LiteralPath (Join-Path $historyRun.RunDirectory 'ListingSnapshots.jsonl') -Raw|ConvertFrom-Json)
Assert ($snapshots.Count -eq 3 -and $first.Snapshot -in $snapshots.id) 'history lists exact snapshot IDs and dates'
$snapshotSource='/'+$source.Replace(':','').Replace('\','/')
$requestPath=Join-Path $private 'history-request.json'
@{Snapshot=$first.Snapshot;Path=$snapshotSource}|ConvertTo-Json|Set-Content -LiteralPath $requestPath
$filesRun=Run 'Files' @{RequestPath=$requestPath}
$entries=@([IO.File]::ReadLines((Join-Path $filesRun.RunDirectory 'ListingFiles.jsonl'))|ForEach-Object {$_|ConvertFrom-Json}|Where-Object {$_.type})
Assert (@($entries|Where-Object {$_.name -eq 'עברית [sample].txt'}).Count -eq 1) 'folder browser finds Unicode and bracket filenames'
Assert (@($entries|Where-Object {$_.path -like '*/node_modules/*'}).Count -eq 0) 'folder listing does not recursively expand child directories'
@{Snapshot=$first.Snapshot;Paths=@($snapshotSource+'/עברית [sample].txt')}|ConvertTo-Json|Set-Content -LiteralPath $requestPath
$selectedTarget=Join-Path $private 'selected-restore'
[void](Run 'Restore' @{RequestPath=$requestPath;RestoreTarget=$selectedTarget})
$selectedFiles=@(Get-ChildItem -LiteralPath $selectedTarget -Recurse -File)
Assert ($selectedFiles.Count -eq 1 -and $selectedFiles[0].Name -eq 'עברית [sample].txt' -and [IO.File]::ReadAllText($selectedFiles[0].FullName) -eq 'first version') 'selected restore treats brackets literally and restores only the old selected file'
Assert ([IO.File]::ReadAllText($changed) -eq 'forced version') 'selected restore leaves the source untouched'
function Expect-HistoryFailure($request,$message,$pattern){
 $request|ConvertTo-Json -Depth 5|Set-Content -LiteralPath $requestPath
 $runPath=Join-Path $private ('refused-history-'+[guid]::NewGuid().ToString('N'))
 & (Join-Path $PSScriptRoot 'Backup-Worker.ps1') -ConfigPath $configPath -Action Forget -RequestPath $requestPath -RunDirectory $runPath
 $result=Get-Content -LiteralPath (Join-Path $runPath 'result.json') -Raw|ConvertFrom-Json
 Assert ($result.State -eq 'Failed' -and $result.Error -match $pattern) $message
}
Expect-HistoryFailure @{SnapshotIds=@($first.Snapshot);Confirmation='';ReclaimSpace=$false} 'unconfirmed history deletion is blocked' 'confirmed'
Expect-HistoryFailure @{SnapshotIds=@($forced.Snapshot);Confirmation='DELETE SELECTED HISTORY';ReclaimSpace=$false} 'newest snapshot is protected from deletion' 'protected'
Expect-HistoryFailure @{SnapshotIds=@();Confirmation='DELETE SELECTED HISTORY';ReclaimSpace=$false} 'empty history selection cannot delete anything' 'Select at least'
@{SnapshotIds=@($first.Snapshot,$second.Snapshot);Confirmation='DELETE SELECTED HISTORY';ReclaimSpace=$true}|ConvertTo-Json|Set-Content -LiteralPath $requestPath
[void](Run 'Forget' @{RequestPath=$requestPath})
$remainingRun=Run 'Snapshots'
$remaining=@(Get-Content -LiteralPath (Join-Path $remainingRun.RunDirectory 'ListingSnapshots.jsonl') -Raw|ConvertFrom-Json)
Assert ($remaining.Count -eq 1 -and $remaining[0].id -eq $forced.Snapshot) 'explicit deletion and prune preserve the newest snapshot'
[void](Run 'Restore' @{Snapshot=$forced.Snapshot;RestoreTarget=(Join-Path $private 'after-prune')})
Assert ([IO.File]::ReadAllText($changed) -eq 'forced version') 'retained snapshot restores after history pruning without source changes'
Write-Output ('Artifacts: '+$private)
Write-Output ('Disposable source: '+$root)
Write-Output ('Disposable repository: '+$DestinationDrive+':\'+$config.RepositoryFolder)
