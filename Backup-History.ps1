#Requires -Version 7.2
param([string]$ConfigPath=(Join-Path $PSScriptRoot 'backup.local.json'),[string]$RenderPreview,[switch]$NoAutoLoad)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'Backup.Status.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Backup.History.psm1') -Force
[Globalization.CultureInfo]::CurrentCulture=[Globalization.CultureInfo]::GetCultureInfo('en-US')
[Globalization.CultureInfo]::CurrentUICulture=[Globalization.CultureInfo]::GetCultureInfo('en-US')
Add-Type -AssemblyName System.Windows.Forms,System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()
$form=[Windows.Forms.Form]::new();$form.Text='DevDriveBackup — Versions and restore';$form.ClientSize=[Drawing.Size]::new(1150,820);$form.StartPosition='CenterScreen';$form.Font=[Drawing.Font]::new('Segoe UI',10);$form.RightToLeft='No';$form.FormBorderStyle='FixedDialog';$form.MaximizeBox=$false
$iconFile=Join-Path $PSScriptRoot 'DevDriveBackup.ico';if(Test-Path -LiteralPath $iconFile){$form.Icon=[Drawing.Icon]::new($iconFile)}
function C($type,$x,$y,$w,$h,$text=''){$c=New-Object ('Windows.Forms.'+$type);$c.SetBounds($x,$y,$w,$h);$c.Text=$text;$form.Controls.Add($c);$c}
function Columns($grid,$specs){foreach($spec in $specs){$col=[Windows.Forms.DataGridViewTextBoxColumn]::new();$col.Name=$spec[0];$col.HeaderText=$spec[1];$col.FillWeight=$spec[2];$col.ReadOnly=$true;[void]$grid.Columns.Add($col)}}
function Grid($x,$y,$w,$h){$g=C DataGridView $x $y $w $h;$g.AllowUserToAddRows=$false;$g.AllowUserToDeleteRows=$false;$g.RowHeadersVisible=$false;$g.AutoSizeColumnsMode='Fill';$g.BackgroundColor=[Drawing.Color]::White;$g.SelectionMode='FullRowSelect';$g.MultiSelect=$false;$g}
$heading=C Label 20 12 1110 32 'Backup History';$heading.Font=[Drawing.Font]::new('Segoe UI',17,[Drawing.FontStyle]::Bold)
[void](C Label 20 49 1110 24 'Choose a backup date, open folders, and add files or folders to your restore selection.')
$refresh=C Button 20 82 135 32 'Refresh history'
[void](C Label 175 87 45 24 'From')
$from=C DateTimePicker 220 82 190 30;$from.Format='Short';$from.ShowCheckBox=$true;$from.Checked=$false
[void](C Label 430 87 30 24 'To')
$to=C DateTimePicker 470 82 190 30;$to.Format='Short';$to.ShowCheckBox=$true;$to.Checked=$false
$selectOlder=C Button 680 82 205 32 'Select older versions'
$delete=C Button 900 82 230 32 'Delete selected history...'
$versions=Grid 20 124 1110 185
$check=[Windows.Forms.DataGridViewCheckBoxColumn]::new();$check.Name='Delete';$check.HeaderText='Delete';$check.FillWeight=12;[void]$versions.Columns.Add($check)
Columns $versions @(@('Date','Backup date (local time)',40),@('Host','Computer',30),@('Paths','Source folders',65),@('Id','Snapshot ID',25))
$browse=C Button 20 321 180 32 'Browse selected version'
$up=C Button 215 321 70 32 'Up'
$location=C TextBox 300 322 830 30 '/';$location.ReadOnly=$true
$files=Grid 20 367 1110 270
Columns $files @(@('Name','Name',65),@('Type','Type',16),@('Size','Size (bytes)',25),@('Modified','Modified (local time)',40))
$files.MultiSelect=$true
$previous=C Button 20 648 90 30 'Previous';$next=C Button 120 648 90 30 'Next'
$pageLabel=C Label 225 653 270 24 'No folder loaded'
$add=C Button 520 648 230 32 'Add selected files / folders'
$clear=C Button 765 648 165 32 'Clear selection'
$restore=C Button 945 648 185 32 'Restore selected...'
$selectionLabel=C Label 20 691 1110 24 'Restore selection: 0 items. Folders include their contents. Double-click a folder to open it.'
$status=C Label 20 725 1110 48 'Ready. Refresh history to load saved versions. The newest version of each computer/source set is protected from deletion.'
$logs=C LinkLabel 20 782 1110 25 ''
$script:history=@();$script:entries=@();$script:page=0;$script:pageSize=500;$script:currentPath='/';$script:snapshot=$null;$script:worker=$null;$script:run=$null;$script:operation=$null;$script:target=$null
$script:basket=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
$busyControls=@($refresh,$from,$to,$selectOlder,$delete,$versions,$browse,$up,$files,$previous,$next,$add,$clear,$restore)
function Error-Message($message){[void][Windows.Forms.MessageBox]::Show($form,[string]$message,'Backup History','OK','Error')}
function Selected-Snapshot {if(-not $versions.CurrentRow){throw 'Select a backup version first'};$versions.CurrentRow.Tag}
function Reset-Selection {$script:basket.Clear();$selectionLabel.Text='Restore selection: 0 items. Folders include their contents. Double-click a folder to open it.'}
function Show-Versions {
 $versions.Rows.Clear()
 foreach($snapshot in @($script:history|Sort-Object {(ConvertTo-HistoryDate $_.time).UtcTicks} -Descending)){
  $date=(ConvertTo-HistoryDate $snapshot.time).LocalDateTime
  if($from.Checked -and $date.Date -lt $from.Value.Date){continue};if($to.Checked -and $date.Date -gt $to.Value.Date){continue}
  $i=$versions.Rows.Add($false,$date.ToString('yyyy-MM-dd HH:mm:ss'),$snapshot.hostname,(@($snapshot.paths)-join '; '),$snapshot.id.Substring(0,12));$versions.Rows[$i].Tag=$snapshot
 }
}
function Show-Files {
 $files.Rows.Clear();$start=$script:page*$script:pageSize;$end=[math]::Min($start+$script:pageSize,$script:entries.Count)
 for($i=$start;$i -lt $end;$i++){$entry=$script:entries[$i];$size=if($entry.type -eq 'file'){$entry.size}else{''};$date=if($entry.mtime){(ConvertTo-HistoryDate $entry.mtime).LocalDateTime.ToString('yyyy-MM-dd HH:mm:ss')}else{''};$row=$files.Rows.Add($entry.name,$entry.type,$size,$date);$files.Rows[$row].Tag=$entry}
 $previous.Enabled=$script:page -gt 0;$next.Enabled=$end -lt $script:entries.Count
 $pageLabel.Text=if($script:entries.Count){'Items '+($start+1)+'–'+$end+' of '+$script:entries.Count}else{'Empty folder'}
 $location.Text=$script:currentPath
}
function Start-HistoryAction([string]$action,$request=$null,[string]$target='') {
 if($script:worker -and -not $script:worker.HasExited){throw 'A repository operation is already running'}
 $script:run=Join-Path $env:LOCALAPPDATA ('DevDriveMirror\runs\history-'+[guid]::NewGuid().ToString('N'));New-Item -ItemType Directory -Path $script:run|Out-Null
 $psi=[Diagnostics.ProcessStartInfo]::new((Get-Process -Id $PID).Path);$psi.UseShellExecute=$false;$psi.CreateNoWindow=$true
 foreach($arg in @('-NoProfile','-File',(Join-Path $PSScriptRoot 'Backup-Worker.ps1'),'-ConfigPath',$ConfigPath,'-Action',$action,'-RunDirectory',$script:run)){[void]$psi.ArgumentList.Add($arg)}
 if($null -ne $request){$requestFile=Join-Path $script:run 'request.json';[IO.File]::WriteAllText($requestFile,($request|ConvertTo-Json -Depth 6));[void]$psi.ArgumentList.Add('-RequestPath');[void]$psi.ArgumentList.Add($requestFile)}
 if($target){[void]$psi.ArgumentList.Add('-RestoreTarget');[void]$psi.ArgumentList.Add($target)}
 $script:operation=$action;$script:target=$target;$script:worker=[Diagnostics.Process]::Start($psi)
 foreach($control in $busyControls){$control.Enabled=$false};$status.Text='Starting '+$action+'...';$logs.Text=$script:run;$timer.Start()
}
function Open-Folder([string]$path) {if(-not $script:snapshot){throw 'Browse a backup version first'};$script:currentPath=$path;$script:entries=@();$script:page=0;Show-Files;Start-HistoryAction 'Files' @{Snapshot=$script:snapshot;Path=$path}}
function Confirm-Deletion($plan) {
 $dialog=[Windows.Forms.Form]::new();$dialog.Text='Delete backup history';$dialog.ClientSize=[Drawing.Size]::new(740,470);$dialog.StartPosition='CenterParent';$dialog.Font=$form.Font;$dialog.RightToLeft='No';$dialog.FormBorderStyle='FixedDialog';$dialog.MaximizeBox=$false
 $label=[Windows.Forms.Label]::new();$label.SetBounds(20,15,700,58);$label.Text='This permanently removes the listed backup versions. Their unique file versions will no longer be recoverable. Your source files are not deleted.';$dialog.Controls.Add($label)
 $list=[Windows.Forms.TextBox]::new();$list.SetBounds(20,80,700,180);$list.Multiline=$true;$list.ReadOnly=$true;$list.ScrollBars='Both';$list.WordWrap=$false;$list.Text=(@($plan|ForEach-Object {(ConvertTo-HistoryDate $_.time).LocalDateTime.ToString('yyyy-MM-dd HH:mm:ss')+'  '+$_.id})-join [Environment]::NewLine);$dialog.Controls.Add($list)
 $reclaim=[Windows.Forms.CheckBox]::new();$reclaim.SetBounds(20,274,700,28);$reclaim.Text='Also reclaim unused storage (prune; may take time and temporarily need free space)';$dialog.Controls.Add($reclaim)
 $hint=[Windows.Forms.Label]::new();$hint.SetBounds(20,311,700,25);$hint.Text='Type DELETE to confirm deletion of '+$plan.Count+' selected version(s):';$dialog.Controls.Add($hint)
 $input=[Windows.Forms.TextBox]::new();$input.SetBounds(20,341,700,28);$dialog.Controls.Add($input)
 $ok=[Windows.Forms.Button]::new();$ok.SetBounds(470,402,120,35);$ok.Text='Delete history';$ok.Enabled=$false;$ok.DialogResult='OK';$dialog.Controls.Add($ok)
 $cancel=[Windows.Forms.Button]::new();$cancel.SetBounds(600,402,120,35);$cancel.Text='Cancel';$cancel.DialogResult='Cancel';$dialog.Controls.Add($cancel);$dialog.CancelButton=$cancel
 $input.Add_TextChanged({$ok.Enabled=$input.Text -ceq 'DELETE'})
 try{if($dialog.ShowDialog($form) -eq 'OK'){return @{SnapshotIds=@($plan.id);Confirmation='DELETE SELECTED HISTORY';ReclaimSpace=$reclaim.Checked}};return $null}finally{$dialog.Dispose()}
}
$refresh.Add_Click({try{Start-HistoryAction 'Snapshots'}catch{Error-Message $_.Exception.Message}})
$from.Add_ValueChanged({Show-Versions});$to.Add_ValueChanged({Show-Versions})
$browse.Add_Click({try{$selected=Selected-Snapshot;if($script:snapshot -cne $selected.id){Reset-Selection};$script:snapshot=$selected.id;Open-Folder '/'}catch{Error-Message $_.Exception.Message}})
$up.Add_Click({try{$parent=$script:currentPath.TrimEnd('/');$index=$parent.LastIndexOf('/');if($index -le 0){$parent='/'}else{$parent=$parent.Substring(0,$index)};Open-Folder $parent}catch{Error-Message $_.Exception.Message}})
$files.Add_CellDoubleClick({param($sender,$event) if($event.RowIndex -ge 0){try{$entry=$files.Rows[$event.RowIndex].Tag;if($entry.type -eq 'dir'){Open-Folder $entry.path}}catch{Error-Message $_.Exception.Message}}})
$previous.Add_Click({$script:page--;Show-Files});$next.Add_Click({$script:page++;Show-Files})
$add.Add_Click({try{if(-not $script:snapshot -or $files.SelectedRows.Count -eq 0){throw 'Browse a version and select files or folders first'};foreach($row in $files.SelectedRows){[void]$script:basket.Add([string]$row.Tag.path)};$selectionLabel.Text='Restore selection: '+$script:basket.Count+' items from snapshot '+$script:snapshot.Substring(0,12)+'. Selection is kept while browsing this version.'}catch{Error-Message $_.Exception.Message}})
$clear.Add_Click({Reset-Selection})
$restore.Add_Click({try{
 if($script:basket.Count -eq 0){throw 'Add at least one file or folder to the restore selection'}
 $pick=[Windows.Forms.FolderBrowserDialog]::new();$pick.Description='Choose a parent folder outside the source drive and backup repository. A new folder will be created; original paths are preserved inside it.'
 try{if($pick.ShowDialog($form) -eq 'OK'){$target=Join-Path $pick.SelectedPath ('DevDrive-Restore-'+(Get-Date -Format 'yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N').Substring(0,6));Start-HistoryAction 'Restore' @{Snapshot=$script:snapshot;Paths=@($script:basket)} $target}}finally{$pick.Dispose()}
 }catch{Error-Message $_.Exception.Message}})
$selectOlder.Add_Click({[void]$versions.EndEdit();foreach($row in $versions.Rows){try{$plan=@(Get-HistoryDeletionPlan $script:history @($row.Tag.id));$row.Cells['Delete'].Value=$plan.Count -eq 1}catch{$row.Cells['Delete'].Value=$false}}})
$delete.Add_Click({try{[void]$versions.EndEdit();$ids=@($versions.Rows|Where-Object {$_.Cells['Delete'].Value -eq $true}|ForEach-Object {$_.Tag.id});$plan=@(Get-HistoryDeletionPlan $script:history $ids);$request=Confirm-Deletion $plan;if($request){Start-HistoryAction 'Forget' $request}}catch{Error-Message $_.Exception.Message}})
$logs.Add_LinkClicked({if($script:run){Start-Process explorer.exe -ArgumentList ('"'+$script:run+'"')}})
$timer=[Windows.Forms.Timer]::new();$timer.Interval=700
$timer.Add_Tick({try{
 $path=Join-Path $script:run 'result.json';if(-not(Test-Path -LiteralPath $path)){$path=Join-Path $script:run 'status.json'}
 if(Test-Path -LiteralPath $path){$s=Read-BackupStatus $path;$status.Text='Stage: '+$s.State+' | RAM: '+$s.MemoryMiB+' MiB';if($s.State -eq 'Failed'){$status.Text='Failed: '+$s.Error+' If the repository is busy, wait for the other operation to finish, then retry.'}}
 if(-not $script:worker.HasExited){return}
 $timer.Stop();foreach($control in $busyControls){$control.Enabled=$true}
 $result=Join-Path $script:run 'result.json';if(-not(Test-Path -LiteralPath $result)){throw 'Worker stopped without a final result. See the run folder.'};$s=Read-BackupStatus $result;if($s.State -ne 'Completed'){return}
 switch($script:operation){
  'Snapshots' {$script:history=@(Get-Content -LiteralPath (Join-Path $script:run 'ListingSnapshots.jsonl') -Raw|ConvertFrom-Json);Show-Versions;$status.Text='Loaded '+$script:history.Count+' backup version(s). Select a row and choose Browse selected version.'}
  'Files' {$items=[Collections.Generic.List[object]]::new();foreach($line in [IO.File]::ReadLines((Join-Path $script:run 'ListingFiles.jsonl'))){$item=$line|ConvertFrom-Json;if($item.type -and $item.path -ne $script:currentPath){$items.Add($item)}};$script:entries=@($items|Sort-Object @{Expression={if($_.type -eq 'dir'){0}else{1}}},name);$script:page=0;Show-Files;$status.Text='Browsing snapshot '+$script:snapshot.Substring(0,12)+'. Files are loaded one folder at a time.'}
  'Restore' {$status.Text='Restore completed and contents verified. Restored to: '+$script:target;[void][Windows.Forms.MessageBox]::Show($form,$status.Text,'Restore completed')}
  'Forget' {$script:entries=@();$script:snapshot=$null;Reset-Selection;Show-Files;Start-HistoryAction 'Snapshots'}
 }
 }catch{$timer.Stop();foreach($control in $busyControls){$control.Enabled=$true};Error-Message $_.Exception.Message}})
$form.Add_FormClosing({param($sender,$event) if($script:worker -and -not $script:worker.HasExited){$event.Cancel=$true;Error-Message 'Wait for the repository operation to finish before closing.'}})
if($RenderPreview){$form.Add_Shown({$bitmap=[Drawing.Bitmap]::new($form.Width,$form.Height);$form.DrawToBitmap($bitmap,[Drawing.Rectangle]::new(0,0,$form.Width,$form.Height));$bitmap.Save($RenderPreview);$bitmap.Dispose();$form.Close()})}elseif($NoAutoLoad){$status.Text='History was not loaded automatically. Refresh history when the backup drive is ready.'}else{$form.Add_Shown({try{Start-HistoryAction 'Snapshots'}catch{Error-Message $_.Exception.Message}})}
[void]$form.ShowDialog()
