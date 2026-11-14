function Assert-SnapshotId([string]$Id) {
 if($Id -cnotmatch '^[0-9a-f]{64}$'){throw 'Choose an exact snapshot ID. Refresh history and try again.'}
}
function Assert-SnapshotPath([string]$Path) {
 if(-not $Path.StartsWith('/') -or $Path.Contains('\') -or $Path -match '[\r\n\x00]' -or @($Path.Split('/')|Where-Object {$_ -in @('.','..')}).Count){throw 'Invalid absolute snapshot path'}
}
function ConvertTo-ResticLiteralPattern([string]$Path) {
 Assert-SnapshotPath $Path
 # Go filepath.Match disables backslash escaping on Windows. A closing
 # bracket outside a character class is already literal.
 [regex]::Replace($Path,'[\[*? ]',{param($m) '['+$m.Value+']'})
}
function ConvertTo-HistoryDate($Value) {
 if($Value -is [DateTimeOffset]){return $Value}
 if($Value -is [DateTime]){return [DateTimeOffset]::new($Value)}
 [DateTimeOffset]::Parse([string]$Value,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind)
}
# A backup that could not read every file (restic exit code 3) still saves a version. The worker marks
# it by replacing the tag devdrive with this one, so the clean-up rule (which only sees devdrive) never
# counts, keeps or deletes it, and history can label it. Versions saved before this mark existed cannot
# be recognised.
$script:PartialTag='devdrive-partial'
function Test-PartialSnapshot($Snapshot) {
 [bool]($Snapshot -and $Snapshot.PSObject.Properties['tags'] -and @($Snapshot.tags) -ccontains $script:PartialTag)
}
function Get-PartialMarkArguments([string]$Id) {
 Assert-SnapshotId $Id
 @('tag','--remove','devdrive','--add',$script:PartialTag,$Id)
}
function Split-SnapshotIdBatches([string[]]$Ids,[int]$Size=200) {
 # Versions are deleted by exact ID on the command line, and Windows refuses a command line over 32,767
 # characters (about 500 IDs). 200 IDs are 13,000 characters.
 if($Size -lt 1){throw 'Batch size must be at least 1'}
 $all=@($Ids|Where-Object {$_})
 for($i=0;$i -lt $all.Count;$i+=$Size){,@($all[$i..([math]::Min($i+$Size,$all.Count)-1)])}
}
function Get-RestoreParentWarnings([string]$ErrorText,[string[]]$SourcePaths,$Summary=$null) {
 # restic ends a restore with exit code 1 when any item reported an error, and then skips checking the
 # restored content. The only errors accepted as warnings are dates or attributes that could not be set
 # on the folders ABOVE what the version backed up ($SourcePaths: the version's own source paths, not
 # today's settings): restic recreates them inside the restore folder with their original, protected
 # permissions (for example C:\Users). Returns those messages; nothing when anything else went wrong,
 # when the output cannot be understood, or when more items are missing than there are warnings.
 $roots=@($SourcePaths|Where-Object {$_}|ForEach-Object {'/'+([string]$_).TrimEnd('\','/').Replace(':','').Replace('\','/')})
 if(-not $roots.Count){return}
 $warnings=@()
 foreach($line in @($ErrorText -split "`r?`n"|Where-Object {$_.Trim()})){
  $e=$null;try{$e=$line|ConvertFrom-Json}catch{return}
  if(-not $e -or $e -isnot [pscustomobject] -or -not $e.PSObject.Properties['message_type']){return}
  if($e.message_type -eq 'exit_error'){continue}
  if($e.message_type -ne 'error' -or -not $e.PSObject.Properties['during'] -or $e.during -ne 'restore' -or -not $e.PSObject.Properties['item'] -or -not $e.PSObject.Properties['error']){return}
  $item=([string]$e.item).Replace('\','/').TrimEnd('/');$message=[string]$e.error.message
  if($message -notmatch '^failed to restore (timestamp|attributes) of ' -or -not $item){return}
  # Above at least one backed-up path, and neither one of them nor inside one.
  $above=@($roots|Where-Object {$_.StartsWith($item+'/',[StringComparison]::OrdinalIgnoreCase)}).Count
  $content=@($roots|Where-Object {$item -ieq $_ -or $item.StartsWith($_+'/',[StringComparison]::OrdinalIgnoreCase)}).Count
  if(-not $above -or $content){return}
  $warnings+=$message
 }
 if($Summary -and $Summary.PSObject.Properties['total_files'] -and $Summary.PSObject.Properties['files_restored'] -and ([long]$Summary.total_files-[long]$Summary.files_restored) -gt $warnings.Count){return}
 $warnings
}
function Get-HistoryDeletionPlan($Snapshots,[string[]]$Ids) {
 $all=@($Snapshots);$selected=@($Ids|Select-Object -Unique)
 if($selected.Count -eq 0){throw 'Select at least one older snapshot'}
 foreach($id in $selected){Assert-SnapshotId $id;if($id -cnotin @($all.id)){throw 'A selected snapshot no longer exists. Refresh history.'}}
 # Preserve the newest snapshot of each host/source set, including equal-time ties, and also the newest
 # complete one: a newer partial version must never be what is left of a set.
 foreach($group in @($all|Group-Object {([string]$_.hostname)+'|'+((@($_.paths)|Sort-Object)-join '|')})){
  $latest=$group.Group|ForEach-Object {(ConvertTo-HistoryDate $_.time).UtcTicks}|Sort-Object -Descending|Select-Object -First 1
  $latestComplete=$group.Group|Where-Object {-not (Test-PartialSnapshot $_)}|ForEach-Object {(ConvertTo-HistoryDate $_.time).UtcTicks}|Sort-Object -Descending|Select-Object -First 1
  foreach($snapshot in $group.Group){
   if($snapshot.id -cnotin $selected){continue}
   $ticks=(ConvertTo-HistoryDate $snapshot.time).UtcTicks
   if($ticks -eq $latest){throw 'The newest snapshot for each computer/source set is protected. Select older versions.'}
   if($null -ne $latestComplete -and $ticks -eq $latestComplete -and -not (Test-PartialSnapshot $snapshot)){throw 'The newest complete snapshot for each computer/source set is protected: the newer ones are partial. Select older versions.'}
  }
 }
 @($all|Where-Object {$_.id -cin $selected})
}
function Get-RetentionArguments([int]$Days,[int]$Weeks,[int]$Months,[string]$HostName='') {
 # Automatic clean-up after a backup: one version per day for $Days days, per week for $Weeks weeks and
 # per month for $Months months. restic counts these windows back from the newest version, not from
 # today, so a long pause between backups never empties the history; --keep-last 1 keeps the newest
 # version whatever the numbers. Only this tool's own complete versions (tag devdrive) are considered,
 # and with $HostName only this computer's: another computer sharing the repository has its own rule.
 # Always a dry run: the versions to delete are checked first and then deleted by exact ID.
 if($Days -lt 0 -or $Weeks -lt 0 -or $Months -lt 0 -or $Days -gt 3650 -or $Weeks -gt 520 -or $Months -gt 240){throw 'Retention numbers are out of range'}
 if($Days+$Weeks+$Months -eq 0){throw 'Retention needs at least one of days, weeks or months'}
 $a=@('forget','--dry-run','--tag','devdrive')
 if($HostName){$a+=@('--host',$HostName)}
 $a+=@('--group-by','host,paths','--keep-last','1')
 if($Days){$a+=@('--keep-within-daily',"$($Days)d")}
 if($Weeks){$a+=@('--keep-within-weekly',"$($Weeks*7)d")}
 if($Months){$a+=@('--keep-within-monthly',"$($Months)m")}
 $a
}
function Get-RetentionRemovals($Plan,[string]$NewSnapshot,$Snapshots,[string]$HostName='') {
 # The versions a retention dry run would delete, after our own checks: the version this backup just
 # made must be known, complete and kept, every group keeps at least one version, no partial version
 # and (with $HostName) no other computer's version is deleted, and the newest version of each
 # computer/source set stays protected (Get-HistoryDeletionPlan). Returns the snapshots to delete.
 $groups=@($Plan|Where-Object {$_})
 $remove=@();$keep=@()
 foreach($g in $groups){
  $k=@(if($g.PSObject.Properties['keep'] -and $g.keep){$g.keep});$r=@(if($g.PSObject.Properties['remove'] -and $g.remove){$g.remove})
  if($r.Count -and -not $k.Count){throw 'The clean-up would delete every version of a folder set. Nothing was deleted.'}
  $keep+=@($k|ForEach-Object {[string]$_.id});$remove+=@($r|ForEach-Object {[string]$_.id})
 }
 if(-not $NewSnapshot){throw 'The version this backup just made is not known, so the clean-up cannot protect it. Nothing was deleted.'}
 if($NewSnapshot -cnotin $keep){throw 'The clean-up would not keep the version this backup just made. Nothing was deleted.'}
 $known=@{};foreach($s in @($Snapshots)){$known[[string]$s.id]=$s}
 if($known.ContainsKey($NewSnapshot) -and (Test-PartialSnapshot $known[$NewSnapshot])){throw 'The version this backup just made is partial, so nothing is cleaned up on its account. Nothing was deleted.'}
 $remove=@($remove|Where-Object {$_}|Select-Object -Unique)
 if(-not $remove.Count){return @()}
 if(@($remove|Where-Object {$_ -cin $keep}).Count){throw 'The clean-up plan both keeps and deletes one version. Nothing was deleted.'}
 foreach($id in $remove){
  if(-not $known.ContainsKey($id)){continue}
  if(Test-PartialSnapshot $known[$id]){throw 'The clean-up plan would delete a partial version. Nothing was deleted.'}
  if($HostName -and [string]$known[$id].hostname -cne $HostName){throw 'The clean-up plan would delete a version of another computer. Nothing was deleted.'}
 }
 @(Get-HistoryDeletionPlan $Snapshots $remove)
}
function Get-LockReleaseDecision($Locks,[string]$ComputerName) {
 # Which locks in the repository may be removed without asking: only when EVERY lock present was made on
 # this computer by a process that has ended. A run that was stopped, crashed or was ended by the memory
 # cap leaves such a lock behind, and restic then refuses its next steps (exit code 11).
 # $Locks: one record per lock file, with Id, Lock (what restic's "cat lock" printed: time, hostname,
 # pid, exclusive; nothing when it could not be read, and a record that lacks one of them counts as
 # unreadable) and Process (what runs on this computer under that process number now: nothing, or its
 # Name and StartedUtc; no start time when it cannot be examined).
 # The process has ended when nothing runs under its number, or when what does started after the lock was
 # made and is not restic (Windows hands process numbers out again). A restic process that started before
 # the lock is its maker and still running. Everything else is unclear and stays: another program that
 # was already running under that number, a restic process that seems to have started after the lock
 # (the clock may have been set back), a process or a lock that cannot be read.
 $judged=@(foreach($l in @($Locks|Where-Object {$_})){
  $r=if($l.PSObject.Properties['Lock']){$l.Lock}else{$null};$p=$null;if($r -is [pscustomobject]){$p=$r.PSObject.Properties}
  $state='Unclear';$why='the lock in the repository could not be read, so it was left in place.';$number=$null;$created=$null;$computer=$null;$exclusive=$null
  if([string]$l.Id -cmatch '^[0-9a-f]{64}$' -and $l.PSObject.Properties['Process'] -and $ComputerName -and $p -and $p['hostname'] -and $p['pid'] -and $p['time'] -and $p['exclusive'] -and $r.exclusive -is [bool] -and ([string]$r.hostname).Trim() -and ($r.pid -is [int] -or $r.pid -is [long]) -and $r.pid -gt 0 -and $r.pid -le [int]::MaxValue){
   try{$created=(ConvertTo-HistoryDate $r.time).UtcDateTime}catch{$created=$null}
  }
  if($null -ne $created){
   $number=[int]$r.pid;$computer=[string]$r.hostname;$exclusive=$r.exclusive;$process=$l.Process
   if($computer -ine $ComputerName){$state='OtherComputer';$why="another computer ($computer) is using this backup, or stopped while it was using it. This computer cannot tell which, so the lock was left in place."}
   elseif($null -eq $process){$state='Ended';$why=''}
   else{
    $started=$null;try{if($null -ne $process.StartedUtc){$started=(ConvertTo-HistoryDate $process.StartedUtc).UtcDateTime}}catch{$started=$null}
    $engine=([string]$process.Name) -like 'restic*'
    if($null -eq $started){$why="process $number on this computer may still be using this backup: it could not be examined, so the lock was left in place."}
    elseif($started -le $created){
     if($engine){$state='Running';$why="a backup is still running on this computer (process $number). Wait until it has finished, then try again."}
     else{$why="process $number on this computer was already running when the lock was made and may be using this backup, so the lock was left in place."}
    }
    elseif($engine){$why="another backup program now runs on this computer under the process number of the run that made the lock ($number), and the two cannot be told apart, so the lock was left in place."}
    else{$state='Ended';$why=''}
   }
  }
  [pscustomobject]@{Id=[string]$l.Id;Pid=$number;CreatedUtc=$(if($null -ne $created){$created.ToString('o')}else{$null});Exclusive=$exclusive;Computer=$computer;State=$state;Why=$why}
 })
 $blocking=@($judged|Where-Object {$_.State -ne 'Ended'})
 [pscustomobject]@{Release=[bool]($judged.Count -and -not $blocking.Count);Reason=$(if($blocking.Count){$blocking[0].Why}else{''});Locks=$judged}
}
Export-ModuleMember -Function Assert-SnapshotId,Assert-SnapshotPath,ConvertTo-ResticLiteralPattern,ConvertTo-HistoryDate,Test-PartialSnapshot,Get-PartialMarkArguments,Split-SnapshotIdBatches,Get-RestoreParentWarnings,Get-HistoryDeletionPlan,Get-RetentionArguments,Get-RetentionRemovals,Get-LockReleaseDecision
