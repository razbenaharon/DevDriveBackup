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
Export-ModuleMember -Function Assert-SnapshotId,Assert-SnapshotPath,ConvertTo-ResticLiteralPattern,ConvertTo-HistoryDate,Get-HistoryDeletionPlan
