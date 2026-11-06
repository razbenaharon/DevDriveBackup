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
function Get-HistoryDeletionPlan($Snapshots,[string[]]$Ids) {
 $all=@($Snapshots);$selected=@($Ids|Select-Object -Unique)
 if($selected.Count -eq 0){throw 'Select at least one older snapshot'}
 foreach($id in $selected){Assert-SnapshotId $id;if($id -cnotin @($all.id)){throw 'A selected snapshot no longer exists. Refresh history.'}}
 # Preserve the newest snapshot of each host/source set, including equal-time ties.
 foreach($group in @($all|Group-Object {([string]$_.hostname)+'|'+((@($_.paths)|Sort-Object)-join '|')})){
  $latest=$group.Group|ForEach-Object {(ConvertTo-HistoryDate $_.time).UtcTicks}|Sort-Object -Descending|Select-Object -First 1
  foreach($snapshot in $group.Group){if((ConvertTo-HistoryDate $snapshot.time).UtcTicks -eq $latest -and $snapshot.id -cin $selected){throw 'The newest snapshot for each computer/source set is protected. Select older versions.'}}
 }
 @($all|Where-Object {$_.id -cin $selected})
}
function Get-RetentionArguments([int]$Days,[int]$Weeks,[int]$Months) {
 # Automatic clean-up after a backup: one version per day for $Days days, per week for $Weeks weeks and
 # per month for $Months months. restic counts these windows back from the newest version, not from
 # today, so a long pause between backups never empties the history; --keep-last 1 keeps the newest
 # version whatever the numbers. Only this tool's own versions (tag devdrive) are considered. Always a
 # dry run: the versions to delete are checked first and then deleted by exact ID.
 if($Days -lt 0 -or $Weeks -lt 0 -or $Months -lt 0 -or $Days -gt 3650 -or $Weeks -gt 520 -or $Months -gt 240){throw 'Retention numbers are out of range'}
 if($Days+$Weeks+$Months -eq 0){throw 'Retention needs at least one of days, weeks or months'}
 $a=@('forget','--dry-run','--tag','devdrive','--group-by','host,paths','--keep-last','1')
 if($Days){$a+=@('--keep-within-daily',"$($Days)d")}
 if($Weeks){$a+=@('--keep-within-weekly',"$($Weeks*7)d")}
 if($Months){$a+=@('--keep-within-monthly',"$($Months)m")}
 $a
}
function Get-RetentionRemovals($Plan,[string]$NewSnapshot,$Snapshots) {
 # The versions a retention dry run would delete, after our own checks: the version this backup just
 # made must be kept, every group keeps at least one version, and the newest version of each
 # computer/source set stays protected (Get-HistoryDeletionPlan). Returns the snapshots to delete.
 $groups=@($Plan|Where-Object {$_})
 $remove=@();$keep=@()
 foreach($g in $groups){
  $k=@(if($g.PSObject.Properties['keep'] -and $g.keep){$g.keep});$r=@(if($g.PSObject.Properties['remove'] -and $g.remove){$g.remove})
  if($r.Count -and -not $k.Count){throw 'The clean-up would delete every version of a folder set. Nothing was deleted.'}
  $keep+=@($k|ForEach-Object {[string]$_.id});$remove+=@($r|ForEach-Object {[string]$_.id})
 }
 if($NewSnapshot -and $NewSnapshot -cnotin $keep){throw 'The clean-up would not keep the version this backup just made. Nothing was deleted.'}
 $remove=@($remove|Where-Object {$_}|Select-Object -Unique)
 if(-not $remove.Count){return @()}
 if(@($remove|Where-Object {$_ -cin $keep}).Count){throw 'The clean-up plan both keeps and deletes one version. Nothing was deleted.'}
 @(Get-HistoryDeletionPlan $Snapshots $remove)
}
Export-ModuleMember -Function Assert-SnapshotId,Assert-SnapshotPath,ConvertTo-ResticLiteralPattern,ConvertTo-HistoryDate,Get-HistoryDeletionPlan,Get-RetentionArguments,Get-RetentionRemovals
