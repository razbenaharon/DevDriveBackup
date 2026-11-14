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
# it by replacing the tag devdrive with this one, so it never passes for a complete version (it is not
# one of the last N, not a month's version and not the newest complete one) and history can label it.
# The clean-up deletes it only once three complete versions of the same computer and folders are newer
# (Get-VersionRetentionPlan). Versions saved before this mark existed cannot be recognised.
$script:PartialTag='devdrive-partial'
function Test-PartialSnapshot($Snapshot) {
 [bool]($Snapshot -and $Snapshot.PSObject.Properties['tags'] -and @($Snapshot.tags) -ccontains $script:PartialTag)
}
function Test-OwnSnapshot($Snapshot) {
 # This tool's versions carry the tag devdrive (complete) or devdrive-partial (partial). Anything else in
 # the repository was saved by another program and is never counted, kept or deleted by the clean-up.
 [bool]($Snapshot -and $Snapshot.PSObject.Properties['tags'] -and (@($Snapshot.tags) -ccontains 'devdrive' -or @($Snapshot.tags) -ccontains $script:PartialTag))
}
function Get-SnapshotGroupKey($Snapshot) {
 # A group is one computer and one set of source folders, told apart exactly as restic does
 # (--group-by host,paths): the paths in sorted order, capital and small letters kept apart, and a list
 # that names one folder twice a set of its own (restic saves and groups it that way; this tool never
 # passes a folder twice). Telling more sets apart only ever keeps more versions. The parts are joined
 # with a character no path or computer name can hold, so two sets never share a key.
 $paths=[string[]]@(@(if($Snapshot.PSObject.Properties['paths']){$Snapshot.paths})|Where-Object {$null -ne $_}|ForEach-Object {[string]$_})
 [Array]::Sort($paths,[StringComparer]::Ordinal)
 ([string]$Snapshot.hostname)+"`0"+($paths -join "`0")
}
function Get-PartialMarkArguments([string]$Id) {
 Assert-SnapshotId $Id
 @('tag','--remove','devdrive','--add',$script:PartialTag,$Id)
}
function Get-PartialTags($Tags) {
 # The tags a version carries once it is marked partial (what Get-PartialMarkArguments makes restic
 # do). A preview of the clean-up uses them to plan a version that is still waiting for its mark.
 @(@($Tags|Where-Object {$_ -and $_ -cne 'devdrive' -and $_ -cne $script:PartialTag})+$script:PartialTag)
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
function Get-VersionRetentionPlan($Snapshots,[int]$Last,[int]$Months,[string]$HostName,[string]$NewSnapshot,[TimeZoneInfo]$TimeZone=[TimeZoneInfo]::Local) {
 # Keep versions, the automatic clean-up after a backup. Worked out here from the list of versions;
 # restic only lists the versions and deletes the ones named, by exact ID. (restic's own
 # --keep-within-monthly keeps a version in up to $Months+1 calendar months and knows nothing of
 # partial versions, so it cannot plan this rule.)
 #
 # The rule, applied separately to each group = one computer and one set of source folders. Only the
 # groups of $HostName are planned, and only this tool's versions (Test-OwnSnapshot): another computer
 # that shares the repository cleans its own versions, with its own rule.
 #  - LastN: the $Last newest complete versions stay, whatever their dates.
 #  - Monthly: the newest complete version of each calendar month stays, for $Months months: the month
 #    of the group's newest complete version and the $Months-1 months before it. Counting back from that
 #    version and not from today, a long pause between backups never empties the history.
 #  - A version that any rule keeps stays. NewestComplete (the newest complete version of the group)
 #    and JustMade ($NewSnapshot, the version this backup made) stay whatever the numbers.
 #  - A partial version never counts for LastN, Monthly or NewestComplete. It stays (PartialKept) until
 #    at least three complete versions of its own group are newer than it; then it goes
 #    (PartialAfter3Complete). Its age alone is never a reason.
 #  - $Last = 0 and $Months = 0: the clean-up is off and every version stays (CleanUpOff).
 # With both rules on, a group keeps at most $Last+$Months-1 complete versions by the two rules (the
 # newest one is always both among the last N and its month's version: 15 with 10 and 6), and never
 # more than $Last+$Months: the one more is the version just made when versions dated later than it
 # exist, after a clock that was wrong. Partial versions come on top.
 #
 # Month boundaries: a version belongs to the calendar month of the moment it was made as THIS computer's
 # clock shows it ($TimeZone, by default the computer's own time zone), which is the date the history
 # window and restic's own list show. The offset written in the version (the clock of the computer that
 # made it, at that time) is not used: a version made at 23:30 on 30 June here belongs to June.
 # Versions made at exactly the same moment are equally new: they are kept or dropped together.
 #
 # Returns one record for every version of this computer: Id, Time, Month, Host, Paths, Partial, Keep,
 # Reasons and the version itself (Snapshot). Nothing is planned without the ID of the version just made,
 # which must be a complete version of this computer.
 if($Last -lt 0 -or $Months -lt 0 -or $Last -gt 10000 -or $Months -gt 240){throw 'Retention numbers are out of range'}
 if(-not $NewSnapshot){throw 'The version this backup just made is not known, so the clean-up cannot protect it. Nothing was deleted.'}
 if(-not $HostName){throw 'The name of this computer is not known, so the clean-up cannot tell its versions from another computer''s. Nothing was deleted.'}
 $enabled=$Last -gt 0 -or $Months -gt 0
 $all=[Collections.Generic.List[object]]::new();$groups=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
 foreach($s in @($Snapshots|Where-Object {$_})){
  if([string]$s.hostname -cne $HostName -or -not (Test-OwnSnapshot $s)){continue}
  $when=ConvertTo-HistoryDate $s.time;$local=[TimeZoneInfo]::ConvertTime($when,$TimeZone)
  $d=[pscustomobject]@{Id=[string]$s.id;Time=$when;Month=('{0:d4}-{1:d2}' -f $local.Year,$local.Month);Host=[string]$s.hostname;Paths=[string[]]@($s.paths);Partial=(Test-PartialSnapshot $s);Keep=$true;Reasons=[string[]]@();Snapshot=$s;Ticks=$when.UtcTicks;MonthNumber=$local.Year*12+$local.Month}
  $key=Get-SnapshotGroupKey $s
  if(-not $groups.ContainsKey($key)){$groups[$key]=[Collections.Generic.List[object]]::new()}
  $groups[$key].Add($d);$all.Add($d)
 }
 $made=@($all|Where-Object {$_.Id -ceq $NewSnapshot})
 if($made.Count -ne 1){throw 'The version this backup just made was not found among this computer''s saved versions, so the clean-up cannot protect it. Nothing was deleted.'}
 if($made[0].Partial){throw 'The version this backup just made is partial, so nothing is cleaned up on its account. Nothing was deleted.'}
 foreach($group in $groups.Values){
  if(-not $enabled){foreach($d in $group){$d.Reasons=[string[]]@('CleanUpOff')};continue}
  # Newest first.
  $complete=@($group|Where-Object {-not $_.Partial}|Sort-Object @{Expression={$_.Ticks};Descending=$true},@{Expression={$_.Id}})
  if($complete.Count){
   $newest=$complete[0].Ticks
   $lastFrom=if($Last -gt 0){$complete[[math]::Min($Last,$complete.Count)-1].Ticks}else{$null}
   $monthFrom=$complete[0].MonthNumber-$Months   # months after this one are inside the rule
   $monthNewest=@{}
   foreach($d in $complete){if($d.MonthNumber -gt $monthFrom -and -not $monthNewest.ContainsKey($d.MonthNumber)){$monthNewest[$d.MonthNumber]=$d.Ticks}}
   foreach($d in $complete){
    $why=@()
    if($d.Id -ceq $NewSnapshot){$why+='JustMade'}
    if($d.Ticks -eq $newest){$why+='NewestComplete'}
    if($null -ne $lastFrom -and $d.Ticks -ge $lastFrom){$why+='LastN'}
    if($monthNewest.ContainsKey($d.MonthNumber) -and $monthNewest[$d.MonthNumber] -eq $d.Ticks){$why+='Monthly'}
    $d.Keep=[bool]$why.Count;$d.Reasons=[string[]]$(if($why.Count){$why}else{@('OutsideRules')})
   }
  }
  foreach($d in @($group|Where-Object {$_.Partial})){
   # Three complete versions are newer exactly when the third newest complete one is.
   $followed=$complete.Count -ge 3 -and $complete[2].Ticks -gt $d.Ticks
   $d.Keep=-not $followed;$d.Reasons=[string[]]@($(if($followed){'PartialAfter3Complete'}else{'PartialKept'}))
  }
 }
 $all.ToArray()|Select-Object Id,Time,Month,Host,Paths,Partial,Keep,Reasons,Snapshot
}
function Get-RetentionRemovals($Plan,[string]$NewSnapshot,$Snapshots,[string]$HostName) {
 # The versions a clean-up plan (Get-VersionRetentionPlan: records with Id and Keep) deletes, after
 # checks that do not depend on how the plan was worked out. Refused, with nothing deleted: a plan made
 # without knowing the version this backup just made, or one that does not keep it; a version just made
 # that is partial; a plan that deletes a version of another computer or of another program, every
 # version of a set of folders, the newest complete version of a set, or a partial version that fewer
 # than three complete versions follow. The newest version of each computer/source set stays protected
 # as for a deletion by hand (Get-HistoryDeletionPlan). Returns the saved versions to delete.
 if(-not $NewSnapshot){throw 'The version this backup just made is not known, so the clean-up cannot protect it. Nothing was deleted.'}
 if(-not $HostName){throw 'The name of this computer is not known, so the clean-up cannot tell its versions from another computer''s. Nothing was deleted.'}
 $decisions=@($Plan|Where-Object {$_})
 $keep=@($decisions|Where-Object {$_.Keep}|ForEach-Object {[string]$_.Id})
 $remove=@($decisions|Where-Object {-not $_.Keep}|ForEach-Object {[string]$_.Id}|Where-Object {$_}|Select-Object -Unique)
 if($NewSnapshot -cnotin $keep){throw 'The clean-up would not keep the version this backup just made. Nothing was deleted.'}
 $known=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
 foreach($s in @($Snapshots|Where-Object {$_})){$known[[string]$s.id]=$s}
 if(-not $known.ContainsKey($NewSnapshot)){throw 'The version this backup just made was not found among the saved versions, so the clean-up cannot protect it. Nothing was deleted.'}
 if(Test-PartialSnapshot $known[$NewSnapshot]){throw 'The version this backup just made is partial, so nothing is cleaned up on its account. Nothing was deleted.'}
 if(-not $remove.Count){return @()}
 if(@($remove|Where-Object {$_ -cin $keep}).Count){throw 'The clean-up plan both keeps and deletes one version. Nothing was deleted.'}
 $gone=[Collections.Generic.HashSet[string]]::new([string[]]$remove,[StringComparer]::Ordinal)
 foreach($id in $remove){
  if(-not $known.ContainsKey($id)){throw 'The clean-up plan names a version that is not among the saved versions. Refresh and try again. Nothing was deleted.'}
  if([string]$known[$id].hostname -cne $HostName){throw 'The clean-up plan would delete a version of another computer. Nothing was deleted.'}
  if(-not (Test-OwnSnapshot $known[$id])){throw 'The clean-up plan would delete a version that this tool did not make. Nothing was deleted.'}
 }
 $groups=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
 foreach($s in $known.Values){
  if([string]$s.hostname -cne $HostName -or -not (Test-OwnSnapshot $s)){continue}
  $key=Get-SnapshotGroupKey $s
  if(-not $groups.ContainsKey($key)){$groups[$key]=[Collections.Generic.List[object]]::new()}
  $groups[$key].Add([pscustomobject]@{Id=[string]$s.id;Ticks=(ConvertTo-HistoryDate $s.time).UtcTicks;Partial=(Test-PartialSnapshot $s)})
 }
 foreach($group in $groups.Values){
  $leaving=@($group|Where-Object {$gone.Contains($_.Id)})
  if(-not $leaving.Count){continue}
  if($leaving.Count -eq $group.Count){throw 'The clean-up would delete every version of a folder set. Nothing was deleted.'}
  $complete=@($group|Where-Object {-not $_.Partial}|Sort-Object @{Expression={$_.Ticks};Descending=$true})
  if($complete.Count -and @($leaving|Where-Object {-not $_.Partial -and $_.Ticks -eq $complete[0].Ticks}).Count){throw 'The clean-up would delete the newest complete version of a folder set. Nothing was deleted.'}
  foreach($partial in @($leaving|Where-Object {$_.Partial})){
   if($complete.Count -lt 3 -or $complete[2].Ticks -le $partial.Ticks){throw 'The clean-up would delete a partial version that fewer than three complete versions follow. Nothing was deleted.'}
  }
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
Export-ModuleMember -Function Assert-SnapshotId,Assert-SnapshotPath,ConvertTo-ResticLiteralPattern,ConvertTo-HistoryDate,Test-PartialSnapshot,Get-PartialMarkArguments,Get-PartialTags,Split-SnapshotIdBatches,Get-RestoreParentWarnings,Get-HistoryDeletionPlan,Get-VersionRetentionPlan,Get-RetentionRemovals,Get-LockReleaseDecision
