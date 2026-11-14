#Requires -Version 7.2
# Rules of the versioned engine that need no repository, no restic and no second drive: partial versions,
# the clean-up of old versions on a shared repository, deleting many versions at once, restore warnings,
# a pending password change after the drive letter changed, the wording of a locked repository, and which
# repository locks may be removed without asking (only one left by a run on this computer that has ended).
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'Backup.Status.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Backup.History.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Backup.Security.psm1') -Force
function Assert($ok,[string]$message){if(-not $ok){throw "FAIL $message"};Write-Output "PASS $message"}
function Assert-Throws([scriptblock]$Block,[string]$Like,[string]$message){
 try{& $Block;throw "FAIL $message (no error)"}catch{if($_.Exception.Message -like 'FAIL*'){throw};if($_.Exception.Message -notlike $Like){throw "FAIL $message (got: $($_.Exception.Message))"}}
 Write-Output "PASS $message"
}
function Id([int]$n){('{0:x2}' -f $n)*32}
function Snap([int]$n,[string]$time,[string]$computer='pc',[string[]]$tags=@('devdrive')){[pscustomobject]@{id=(Id $n);time=$time;hostname=$computer;paths=@('E:\');tags=$tags}}

# --- Partial versions (a backup that could not read every file) ----------------------------------
$complete=Snap 1 '2026-06-29T10:00:00Z';$partial=Snap 2 '2026-06-29T18:00:00Z' 'pc' @('devdrive-partial');$older=Snap 3 '2026-06-28T10:00:00Z'
Assert ((Test-PartialSnapshot $partial) -and -not (Test-PartialSnapshot $complete) -and -not (Test-PartialSnapshot ([pscustomobject]@{id=(Id 9);time='2026-01-01T00:00:00Z';hostname='pc';paths=@('E:\')}))) 'a partial version is recognised by its mark; unmarked and untagged versions are not partial'
$mark=Get-PartialMarkArguments (Id 2)
Assert ($mark[0] -eq 'tag' -and ($mark -join ' ') -like '*--remove devdrive*' -and ($mark -join ' ') -like '*--add devdrive-partial*' -and $mark[-1] -eq (Id 2)) 'marking a version partial takes it out of the versions the clean-up rule sees'
Assert-Throws {Get-PartialMarkArguments 'latest'} '*exact snapshot ID*' 'only an exact version can be marked partial'
$set=@($complete,$partial,$older)
Assert-Throws {Get-HistoryDeletionPlan $set @($complete.id)} '*protected*' 'the newest complete version is protected even when a newer partial version exists'
Assert-Throws {Get-HistoryDeletionPlan $set @($partial.id)} '*protected*' 'the newest version stays protected as before, also when it is partial'
Assert (@(Get-HistoryDeletionPlan $set @($older.id)).Count -eq 1) 'an older version can still be deleted'
$onlyPartial=@((Snap 4 '2026-06-29T18:00:00Z' 'pc' @('devdrive-partial')),(Snap 5 '2026-06-28T18:00:00Z' 'pc' @('devdrive-partial')))
Assert (@(Get-HistoryDeletionPlan $onlyPartial @((Id 5))).Count -eq 1) 'a set with only partial versions still lets an older one go'
# A plan that would delete a partial version (restic never plans one, because the mark replaces the tag).
Assert-Throws {Get-RetentionRemovals @([pscustomobject]@{keep=@($complete);remove=@($partial,$older)}) $complete.id @($complete,$partial,$older) 'pc'} '*partial*' 'the clean-up never deletes a partial version'
Assert-Throws {Get-RetentionRemovals @([pscustomobject]@{keep=@($partial,$complete);remove=@($older)}) $partial.id @($complete,$partial,$older) 'pc'} '*partial*' 'the clean-up never runs on behalf of a partial version'

# --- The version just made --------------------------------------------------------------------------
$future=Snap 6 '2027-01-01T00:00:00Z';$new=Snap 7 '2026-11-12T10:00:00Z'
$wrongClock=@([pscustomobject]@{keep=@($future);remove=@($new)})
Assert-Throws {Get-RetentionRemovals $wrongClock '' @($future,$new) 'pc'} '*not known*' 'without the ID of the version just made nothing is deleted'
Assert-Throws {Get-RetentionRemovals $wrongClock $null @($future,$new) 'pc'} '*not known*' 'a missing ID of the version just made is refused too'

# --- A repository shared by two computers -------------------------------------------------------------
$a=Get-RetentionArguments 7 4 3 'pc'
Assert (($a -join ' ') -like '*--host pc*' -and '--dry-run' -in $a) 'the clean-up rule is limited to this computer''s versions'
Assert (-not ((Get-RetentionArguments 7 4 3) -contains '--host')) 'without a computer name the rule is unchanged (older callers)'
$mine=@((Snap 10 '2026-06-30T12:00:00Z'),(Snap 11 '2026-01-01T12:00:00Z'));$theirs=@((Snap 12 '2026-06-01T12:00:00Z' 'laptop'),(Snap 13 '2025-06-01T12:00:00Z' 'laptop'))
Assert-Throws {Get-RetentionRemovals @([pscustomobject]@{keep=@($mine[0]);remove=@($mine[1])},[pscustomobject]@{keep=@($theirs[0]);remove=@($theirs[1])}) $mine[0].id @($mine+$theirs) 'pc'} '*another computer*' 'a plan that would delete another computer''s version is refused'
$r=@(Get-RetentionRemovals @([pscustomobject]@{keep=@($mine[0]);remove=@($mine[1])}) $mine[0].id @($mine+$theirs) 'pc')
Assert ($r.Count -eq 1 -and $r[0].id -eq $mine[1].id) 'this computer''s old version is still returned for deletion'

# --- Deleting many versions at once -----------------------------------------------------------------
$ids=@(1..520|ForEach-Object {[guid]::NewGuid().ToString('N')*2})
$batches=@(Split-SnapshotIdBatches $ids)
Assert ($batches.Count -eq 3 -and @($batches|Where-Object {@($_).Count -gt 200}).Count -eq 0) '520 versions are deleted in batches of at most 200'
Assert ((@($batches|ForEach-Object {$_}) -join ',') -ceq ($ids -join ',')) 'every version is in exactly one batch, in the same order'
# Windows refuses a command line over 32,767 characters; the worker's fixed arguments take a few hundred.
Assert (@($batches|Where-Object {((@($_) -join ' ').Length+2000) -ge 32767}).Count -eq 0) 'each batch fits a Windows command line with room for the other arguments'
$one=@(Split-SnapshotIdBatches @($ids[0]))
Assert ($one.Count -eq 1 -and @($one[0]).Count -eq 1 -and @($one[0])[0] -ceq $ids[0]) 'a single version is one batch'
Assert (@(Split-SnapshotIdBatches @()).Count -eq 0) 'nothing to delete gives no batch'

# --- Restore warnings ---------------------------------------------------------------------------------
$src='C:\Users\YOUR_USER\Documents\work\'
$stamp='{"message_type":"error","error":{"message":"failed to restore timestamp of \"D:\\\\out\\\\C\\\\Users\": Access is denied."},"during":"restore","item":"\\C\\Users"}'
$exit='{"message_type":"exit_error","code":1,"message":"Fatal: There were 1 errors"}'
$w=@(Get-RestoreParentWarnings ($stamp+"`n"+$exit) $src ([pscustomobject]@{total_files=14;files_restored=13}))
Assert ($w.Count -eq 1 -and $w[0] -like 'failed to restore timestamp*') 'a date that could not be set on a folder above the source is a warning'
$inside='{"message_type":"error","error":{"message":"failed to restore timestamp of \"D:\\\\out\\\\C\\\\Users\\\\someone\\\\Documents\\\\work\\\\sub\": Access is denied."},"during":"restore","item":"\\C\\Users\\someone\\Documents\\work\\sub"}'
Assert (@(Get-RestoreParentWarnings ($inside+"`n"+$exit) $src $null).Count -eq 0) 'the same error on a folder inside the source is a failure'
$content='{"message_type":"error","error":{"message":"open D:\\out\\C\\Users\\someone\\Documents\\work\\a.txt: Access is denied."},"during":"restore","item":"\\C\\Users\\someone\\Documents\\work\\a.txt"}'
Assert (@(Get-RestoreParentWarnings ($stamp+"`n"+$content+"`n"+$exit) $src $null).Count -eq 0) 'a file that could not be written is a failure, also beside a harmless warning'
Assert (@(Get-RestoreParentWarnings ("ignoring error for \C\Users: something`n"+$exit) $src $null).Count -eq 0) 'output that cannot be understood is a failure'
Assert (@(Get-RestoreParentWarnings $exit $src $null).Count -eq 0) 'a failure without any item error is a failure'
Assert (@(Get-RestoreParentWarnings ($stamp+"`n"+$exit) $src ([pscustomobject]@{total_files=14;files_restored=10})).Count -eq 0) 'more items missing than warnings is a failure'
Assert (@(Get-RestoreParentWarnings ($stamp+"`n"+$exit) 'C:\Users\' $null).Count -eq 0) 'the source folder itself is not a folder above the source'
# The folders above are judged by what the restored version itself backed up, not by today's settings.
Assert (@(Get-RestoreParentWarnings ($stamp+"`n"+$exit) @($src,'C:\Users') $null).Count -eq 0) 'a folder that the version backed up itself (an older, wider source) is not a folder above the source'
Assert (@(Get-RestoreParentWarnings ($stamp+"`n"+$exit) @('C:\Users\YOUR_USER\Documents\work','C:\Users\YOUR_USER\Pictures') $null).Count -eq 1) 'a version with several source folders accepts the folders above them'
Assert (@(Get-RestoreParentWarnings ($stamp+"`n"+$exit) @() $null).Count -eq 0) 'without the version''s source paths nothing is accepted'

# --- A pending password change after the drive letter changed -------------------------------------
$journal=[pscustomobject]@{Version=1;Repository='Y:\Work-Versions';ConfigPath='C:\tool\jobs\work.local.json';DestinationVolumeId='volume-1';RepositoryFolder='Work-Versions'}
Assert-RotationJournalTarget $journal 'volume-1' 'Work-Versions' 'Z:\Work-Versions'
Assert $true 'a pending password change is recognised by volume and folder after the drive letter changed'
Assert-Throws {Assert-RotationJournalTarget $journal 'volume-2' 'Work-Versions' 'Y:\Work-Versions'} '*another*' 'the same path on another volume is refused'
Assert-Throws {Assert-RotationJournalTarget $journal 'volume-1' 'Other-Versions' 'Y:\Other-Versions'} '*another*' 'another repository folder on the same volume is refused'
$oldJournal=[pscustomobject]@{Version=1;Repository='Y:\Work-Versions';ConfigPath='C:\tool\jobs\work.local.json'}
Assert-RotationJournalTarget $oldJournal 'volume-1' 'Work-Versions' 'Y:\Work-Versions'
Assert-RotationJournalTarget $oldJournal 'volume-1' 'Work-Versions' 'Z:\Work-Versions'
Assert $true 'a journal written by an earlier version resumes on the same path and after a drive-letter change'
Assert-Throws {Assert-RotationJournalTarget $oldJournal 'volume-1' 'Other-Versions' 'Y:\Other-Versions'} '*another*' 'an earlier journal for another folder is refused'

# --- A locked repository ------------------------------------------------------------------------------
$text=Get-EngineFailureText 'CheckingStructure' 11
Assert ($text -like '*exit code 11*' -and $text -like '*locked*' -and $text -like '*Nothing is damaged*' -and $text -like '*CheckingStructure.errors.log*' -and $text -notlike '*memory*') 'a locked repository is named as such, says nothing is damaged and does not blame memory'
Assert ((Get-EngineFailureText 'Verifying' 1) -like '*exit code 1*memory allocation*') 'other failures keep the general wording'
# --- Removing a lock left by a run that ended --------------------------------------------------------
# A lock as restic records it (cat lock), with what now runs on this computer under its process number:
# nothing ($null), or a process with its name and start time (no start time: it cannot be examined).
function Left([int]$n,$process=$null,[string]$computer='Work-PC',[string]$time='2026-11-14T10:00:00.1234567+02:00',$number=4242,$exclusive=$false){
 [pscustomobject]@{Id=(Id $n);Lock=[pscustomobject]@{time=$time;exclusive=$exclusive;hostname=$computer;username='Work-PC\me';pid=$number};Process=$process}
}
function Proc([string]$name,$started){[pscustomobject]@{Name=$name;StartedUtc=$(if($started){[DateTimeOffset]::Parse($started,[Globalization.CultureInfo]::InvariantCulture).UtcDateTime}else{$null})}}
$d=Get-LockReleaseDecision @((Left 1)) 'WORK-pc'
Assert ($d.Release -eq $true -and $d.Reason -eq '' -and @($d.Locks).Count -eq 1 -and $d.Locks[0].State -eq 'Ended') 'a lock of this computer (the name compared without regard to case) whose process is gone may be removed'
Assert ($d.Locks[0].Id -ceq (Id 1) -and $d.Locks[0].Pid -eq 4242 -and $d.Locks[0].CreatedUtc -ceq '2026-11-14T08:00:00.1234567Z' -and $d.Locks[0].Exclusive -eq $false -and $d.Locks[0].Computer -ceq 'Work-PC') 'the decision names the lock: its ID, process number, creation time (UTC) and kind'
$d=Get-LockReleaseDecision @((Left 2 $null 'Laptop')) 'Work-PC'
Assert ($d.Release -eq $false -and $d.Locks[0].State -eq 'OtherComputer' -and $d.Reason -like '*another computer (Laptop)*left in place*') 'a lock of another computer is never removed, and the reason names that computer'
$d=Get-LockReleaseDecision @((Left 3 (Proc 'restic_0.19.1_windows_amd64' '2026-11-14T07:59:58Z'))) 'Work-PC'
Assert ($d.Release -eq $false -and $d.Locks[0].State -eq 'Running' -and $d.Reason -like '*still running on this computer (process 4242)*') 'a lock whose restic process is still running is never removed'
$d=Get-LockReleaseDecision @((Left 4 (Proc 'notepad' '2026-11-14T08:20:00Z'))) 'Work-PC'
Assert ($d.Release -eq $true -and $d.Locks[0].State -eq 'Ended') 'a process number reused by another program that started after the lock was made: the run that made the lock has ended'
$d=Get-LockReleaseDecision @((Left 5 (Proc 'restic' '2026-11-14T08:20:00Z'))) 'Work-PC'
Assert ($d.Release -eq $false -and $d.Locks[0].State -eq 'Unclear' -and $d.Reason -like '*process number*4242*') 'a restic process under that number that seems to have started after the lock is unclear (the clock may have changed): not removed'
$d=Get-LockReleaseDecision @((Left 6 (Proc 'svchost' '2026-11-01T08:00:00Z'))) 'Work-PC'
Assert ($d.Release -eq $false -and $d.Locks[0].State -eq 'Unclear') 'another program that was already running under that number when the lock was made is unclear: not removed'
$d=Get-LockReleaseDecision @((Left 7 (Proc '' $null))) 'Work-PC'
Assert ($d.Release -eq $false -and $d.Locks[0].State -eq 'Unclear' -and $d.Reason -like '*process 4242*could not be examined*') 'a process that cannot be examined is unclear: not removed'
$unreadable=[pscustomobject]@{Id=(Id 8);Lock=$null;Process=$null}
$d=Get-LockReleaseDecision @($unreadable) 'Work-PC'
Assert ($d.Release -eq $false -and $d.Locks[0].State -eq 'Unclear' -and $d.Reason -like '*could not be read*') 'a lock that cannot be read is not removed'
foreach($broken in @((Left 9 $null 'Work-PC' 'yesterday'),(Left 9 $null 'Work-PC' '2026-11-14T10:00:00+02:00' 0),(Left 9 $null 'Work-PC' '2026-11-14T10:00:00+02:00' '4242x'),(Left 9 $null ''),[pscustomobject]@{Id='latest';Lock=(Left 9).Lock;Process=$null},[pscustomobject]@{Id=(Id 9);Lock=(Left 9).Lock},[pscustomobject]@{Id=(Id 9);Lock=[pscustomobject]@{hostname='Work-PC';pid=4242};Process=$null},[pscustomobject]@{Id=(Id 9);Lock=[pscustomobject]@{time='2026-11-14T10:00:00+02:00';hostname='Work-PC';pid=4242};Process=$null},(Left 9 $null 'Work-PC' '2026-11-14T10:00:00+02:00' 4242 'no'))){
 if((Get-LockReleaseDecision @($broken) 'Work-PC').Release){throw 'FAIL an incomplete lock record was accepted'}
}
Assert $true 'a lock without a usable time, process number, computer name, kind or ID, or one whose process was not looked up, is not removed'
Assert ((Get-LockReleaseDecision @((Left 1)) '').Release -eq $false) 'without this computer''s name nothing is removed'
$d=Get-LockReleaseDecision @((Left 10),(Left 11 $null 'Laptop'),(Left 12 $null 'Work-PC' '2026-11-14T10:05:00+02:00' 5151 $true)) 'Work-PC'
Assert ($d.Release -eq $false -and @($d.Locks).Count -eq 3 -and @($d.Locks|Where-Object {$_.State -eq 'Ended'}).Count -eq 2 -and $d.Reason -like '*Laptop*') 'one lock that may not be removed keeps every lock in place'
$d=Get-LockReleaseDecision @((Left 10),(Left 12 $null 'Work-PC' '2026-11-14T10:05:00+02:00' 5151 $true)) 'Work-PC'
Assert ($d.Release -eq $true -and @($d.Locks).Count -eq 2 -and $d.Locks[1].Exclusive -eq $true -and $d.Locks[1].Pid -eq 5151) 'several locks that all belong to ended runs of this computer may be removed together'
$d=Get-LockReleaseDecision @() 'Work-PC'
Assert ($d.Release -eq $false -and $d.Reason -eq '' -and @($d.Locks).Count -eq 0) 'no lock: nothing to remove and nothing to report'
$text=Get-EngineFailureText 'CheckingStructure' 11 'a backup is still running on this computer (process 4242). Wait until it has finished, then try again.'
Assert ($text -like '*exit code 11*locked: a backup is still running on this computer (process 4242).*Nothing is damaged*CheckingStructure.errors.log*' -and $text -notlike '*memory*' -and $text -notlike '*An earlier run was stopped*') 'a lock that was examined and left in place is reported with its own reason instead of the general guess'
Write-Output 'All versioned-engine rule tests passed.'
