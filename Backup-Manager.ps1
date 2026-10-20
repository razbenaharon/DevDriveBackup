#Requires -Version 7.2
param([string]$ConfigPath=(Join-Path $PSScriptRoot 'backup.local.json'),[string]$RenderPreview,[string]$AttachRunDirectory)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'Backup.Status.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Backup.Selection.psm1') -Force
[Globalization.CultureInfo]::CurrentCulture=[Globalization.CultureInfo]::GetCultureInfo('en-US')
[Globalization.CultureInfo]::CurrentUICulture=[Globalization.CultureInfo]::GetCultureInfo('en-US')

Add-Type -AssemblyName System.Windows.Forms,System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()
if(-not(Test-Path -LiteralPath $ConfigPath)){throw 'Create backup.local.json from config.example.json. See BACKUP-SYSTEM.md.'}
$config=Get-Content -LiteralPath $ConfigPath -Raw|ConvertFrom-Json
$form=[Windows.Forms.Form]::new();$form.Text='Backup Center — Versioned backup (advanced)';$form.ClientSize=[Drawing.Size]::new(1040,760);$form.StartPosition='CenterScreen';$form.Font=[Drawing.Font]::new('Segoe UI',10);$form.RightToLeft='No';$form.RightToLeftLayout=$false
$iconFile=Join-Path $PSScriptRoot 'BackupCenter.ico';if(Test-Path -LiteralPath $iconFile){$form.Icon=[Drawing.Icon]::new($iconFile)}
function C($type,$x,$y,$w,$h,$text=''){$c=New-Object ('Windows.Forms.'+$type);$c.SetBounds($x,$y,$w,$h);$c.Text=$text;$form.Controls.Add($c);$c}
$title=C Label 20 16 1000 32 'Dev Drive — Encrypted Versioned Backup';$title.Font=[Drawing.Font]::new('Segoe UI',16,[Drawing.FontStyle]::Bold)
$subtitle=C Label 20 52 1000 30 ('Source: '+$config.Source+'    |    Repository: '+$config.RepositoryFolder+'    |    Existing mirror data is preserved')
$grid=C DataGridView 20 90 1000 290;$grid.AllowUserToAddRows=$false;$grid.AllowUserToDeleteRows=$false;$grid.RowHeadersVisible=$false;$grid.AutoSizeColumnsMode='Fill';$grid.BackgroundColor=[Drawing.Color]::White;$grid.SelectionMode='FullRowSelect';$grid.EditMode='EditOnEnter'
# One Mode per folder, shared with Invoke-FastMirror.ps1 (see Backup.Selection.psm1).
$modeColumn=[Windows.Forms.DataGridViewComboBoxColumn]::new();$modeColumn.Name='Mode';$modeColumn.HeaderText='Mode';$modeColumn.FillWeight=22;$modeColumn.FlatStyle='Flat';[void]$modeColumn.Items.AddRange([object[]]@(Get-BackupModeNames));[void]$grid.Columns.Add($modeColumn)
foreach($pair in @(@('Path','Folder',72),@('Size','Size (GiB)',20),@('Value','Priority and recommendation',95))){$col=[Windows.Forms.DataGridViewTextBoxColumn]::new();$col.Name=$pair[0];$col.HeaderText=$pair[1];$col.FillWeight=$pair[2];$col.ReadOnly=$true;[void]$grid.Columns.Add($col)}
$summaryPath=Join-Path $env:LOCALAPPDATA 'DevDriveMirror\audit\folder-summary.csv';$summary=@{};if(Test-Path -LiteralPath $summaryPath){Import-Csv $summaryPath|ForEach-Object {$summary[$_.Path]=$_}}
# An older configuration without modes opens with its Include entries as Versioned and the rest as Skip.
$selection=Get-BackupSelection $config
foreach($choice in $config.Choices){$size=if($summary.ContainsKey($choice.Path)){'{0:N2}' -f ([long]$summary[$choice.Path].Bytes/1GB)}else{'—'};[void]$grid.Rows.Add((Get-BackupMode $selection $choice.Path),$choice.Path,$size,$choice.Reason)}
[void](C Label 20 391 170 25 'Folders not listed')
$defaultMode=C ComboBox 190 387 130 30;$defaultMode.DropDownStyle='DropDownList';[void]$defaultMode.Items.AddRange([object[]]@(Get-BackupModeNames));$defaultMode.SelectedItem=$selection.DefaultMode
$modeHelp=C Label 335 391 685 25 'Mirror = plain copy (Invoke-FastMirror.ps1)   Versioned = encrypted history (this window)   Both   Skip'
[void](C Label 20 424 150 25 'Performance profile')
$profile=C ComboBox 180 420 190 30;$profile.DropDownStyle='DropDownList';[void]$profile.Items.AddRange([object[]]@('Quiet','Balanced','Fast'));$profile.SelectedIndex=1
[void](C Label 390 424 150 25 'MB/s (0 = unlimited)')
$rate=C NumericUpDown 550 420 100 30;$rate.Minimum=0;$rate.Maximum=2000;$rate.Value=[decimal]$config.RateMBps
[void](C Label 670 424 160 25 'Memory cap (MiB)')
$memory=C NumericUpDown 850 420 170 30;$memory.Minimum=512;$memory.Maximum=8192;$memory.Increment=256;$memory.Value=$config.MemoryMiB
$note=C Label 20 458 1000 46 'The cap applies to the backup process, not the Windows file cache. Exceeding it fails the run. Actual speed also depends on file count and storage.'
$skip=C CheckBox 20 507 600 28 'Apply configured cache, environment and test exclusions';$skip.Checked=$true
$force=C CheckBox 640 507 380 28 'Re-read all file contents (slower)'
$backup=C Button 20 548 155 37 'Start backup'
$preview=C Button 185 548 155 37 'Preview'
$verify=C Button 350 548 155 37 'Full verification'
$restore=C Button 515 548 155 37 'History and restore'
$report=C Button 680 548 155 37 'Report and recommendations'
$key=C Button 845 548 175 37 'Password and recovery'
$progress=C ProgressBar 20 602 1000 20;$progress.Minimum=0;$progress.Maximum=1000
$status=C Label 20 632 1000 75 'Ready. Choose a Mode for each folder and a profile. The first backup creates a separate repository and a local recovery key.'
$details=C LinkLabel 20 715 1000 25 ''
$script:worker=$null;$script:run=$null
function Apply-Profile {
 switch($profile.SelectedIndex){0{$rate.Value=15;$memory.Value=512;$config.Profile='Quiet';$config.CpuThreads=1;$config.ReadConcurrency=1;$config.PackMiB=8};1{$rate.Value=45;$memory.Value=1024;$config.Profile='Balanced';$config.CpuThreads=2;$config.ReadConcurrency=2;$config.PackMiB=16};2{$rate.Value=0;$memory.Value=2048;$config.Profile='Fast';$config.CpuThreads=4;$config.ReadConcurrency=4;$config.PackMiB=32}}
}
switch($config.Profile){'Quiet'{$profile.SelectedIndex=0};'Fast'{$profile.SelectedIndex=2};default{$profile.SelectedIndex=1}}
$profile.Add_SelectedIndexChanged({Apply-Profile})
function Save-Config {
 # Re-read the file under the lock and change only what this window edits, so changes made
 # elsewhere (Backup Center, a text editor) since this window opened are kept.
 [void]$grid.EndEdit()
 New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($config.PasswordDpapiPath)) -Force|Out-Null
 $settingsLock=[IO.File]::Open($config.PasswordDpapiPath+'.run.lock',[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
 try{
  $fresh=Get-Content -LiteralPath $ConfigPath -Raw|ConvertFrom-Json
  if($fresh.PasswordDpapiPath -ine $config.PasswordDpapiPath){throw 'Credential configuration changed. Reopen the backup manager.'}
  foreach($row in $grid.Rows){
   $choice=@($fresh.Choices|Where-Object {$_.Path -ieq [string]$row.Cells['Path'].Value})[0]
   if($choice){$choice|Add-Member -NotePropertyName Mode -NotePropertyValue ([string]$row.Cells['Mode'].Value) -Force}
  }
  $fresh|Add-Member -NotePropertyName DefaultMode -NotePropertyValue ([string]$defaultMode.SelectedItem) -Force
  # Include is kept for other readers; the worker derives the same list from the modes.
  $fresh.Include=@(Get-BackupRegions (Get-BackupSelection $fresh) 'Versioned'|ForEach-Object {if($_.Path){$_.Path}else{'.'}})
  if($fresh.Include.Count -eq 0){throw 'Mark at least one folder Versioned or Both'}
  foreach($k in @('Profile','CpuThreads','ReadConcurrency','PackMiB')){$fresh|Add-Member -NotePropertyName $k -NotePropertyValue $config.$k -Force}
  $fresh.RateMBps=[int]$rate.Value;$fresh.MemoryMiB=[int]$memory.Value
  # Unticking the box turns exclusions off; ticking it keeps the file's own list (filling it
  # with the recommended one only when it is empty).
  if(-not $skip.Checked){$fresh.Exclude=@()}elseif(-not @($fresh.Exclude).Count){$fresh.Exclude=@($fresh.RecommendedExclude)}
  [void](Write-BackupStatus $fresh $ConfigPath)
  $script:config=$fresh
 }finally{$settingsLock.Dispose()}
}
function Start-Action([string]$action,[string]$target=''){
 if($script:worker -and -not $script:worker.HasExited){throw 'A backup is already running'}
 Save-Config
 $script:run=Join-Path $env:LOCALAPPDATA ('DevDriveMirror\runs\'+(Get-Date -Format 'yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N'));New-Item -ItemType Directory -Path $script:run -Force|Out-Null
 $psi=[Diagnostics.ProcessStartInfo]::new((Get-Process -Id $PID).Path);$psi.UseShellExecute=$false;$psi.CreateNoWindow=$true
 foreach($a in @('-NoProfile','-File',(Join-Path $PSScriptRoot 'Backup-Worker.ps1'),'-ConfigPath',$ConfigPath,'-Action',$action,'-RunDirectory',$script:run)){[void]$psi.ArgumentList.Add($a)}
 if($action -eq 'Check'){[void]$psi.ArgumentList.Add('-ReadAllData')}
 if($force.Checked -and $action -in @('Backup','Preview')){[void]$psi.ArgumentList.Add('-ForceRead')}
 if($target){[void]$psi.ArgumentList.Add('-RestoreTarget');[void]$psi.ArgumentList.Add($target)}
 $script:worker=[Diagnostics.Process]::Start($psi);$status.Text='Starting...';$progress.Value=0;$timer.Start()
 foreach($c in @($backup,$preview,$verify,$restore,$grid,$defaultMode,$profile,$rate,$memory,$skip,$force)){$c.Enabled=$false}
}
function Show-Error($e){[void][Windows.Forms.MessageBox]::Show($form,[string]$e,'Dev Drive Backup')}
$backup.Add_Click({try{Start-Action 'Backup'}catch{Show-Error $_.Exception.Message}})
$preview.Add_Click({try{Start-Action 'Preview'}catch{Show-Error $_.Exception.Message}})
$verify.Add_Click({try{Start-Action 'Check'}catch{Show-Error $_.Exception.Message}})
$restore.Add_Click({try{$psi=[Diagnostics.ProcessStartInfo]::new((Get-Process -Id $PID).Path);$psi.UseShellExecute=$false;$psi.CreateNoWindow=$true;foreach($arg in @('-NoProfile','-File',(Join-Path $PSScriptRoot 'Backup-History.ps1'),'-ConfigPath',$ConfigPath)){[void]$psi.ArgumentList.Add($arg)};[void][Diagnostics.Process]::Start($psi)}catch{Show-Error $_.Exception.Message}})
$report.Add_Click({try{
 $file=Join-Path $PSScriptRoot 'audit\devdrive-report.html'
 if(-not(Test-Path -LiteralPath $file)){throw 'There is no report yet. Create one with Inspect-DevDrive.ps1 and Build-BackupReport.py, as described in BACKUP-SYSTEM.md.'}
 Start-Process $file
}catch{Show-Error $_.Exception.Message}})
$key.Add_Click({try{$psi=[Diagnostics.ProcessStartInfo]::new((Get-Process -Id $PID).Path);$psi.UseShellExecute=$false;$psi.CreateNoWindow=$true;foreach($arg in @('-NoProfile','-File',(Join-Path $PSScriptRoot 'Backup-Security.ps1'),'-ConfigPath',$ConfigPath)){[void]$psi.ArgumentList.Add($arg)};[void][Diagnostics.Process]::Start($psi)}catch{Show-Error $_.Exception.Message}})
$details.Add_LinkClicked({if($script:run){Start-Process explorer.exe -ArgumentList ('"'+$script:run+'"')}})
$timer=[Windows.Forms.Timer]::new();$timer.Interval=1000
$timer.Add_Tick({
 try{
  $file=Join-Path $script:run 'result.json';if(-not(Test-Path -LiteralPath $file)){$file=Join-Path $script:run 'status.json'}
  if(Test-Path -LiteralPath $file){
   $s=Read-BackupStatus $file;$p=$s.Progress;$text='Stage: '+$s.State+' | RAM: '+$s.MemoryMiB+' MiB | CPU: '+$s.CpuPercent+'%'
   if($p -and $p.PSObject.Properties['percent_done']){$progress.Value=[math]::Min(1000,[int]($p.percent_done*1000));$text+=' | '+[math]::Round($p.percent_done*100,1)+'%'}
   if($p -and $p.PSObject.Properties['seconds_remaining']){$text+=' | Approx. remaining: '+[TimeSpan]::FromSeconds([int]$p.seconds_remaining).ToString('hh\:mm\:ss')}
   if($p -and $p.PSObject.Properties['bytes_done'] -and $p.seconds_elapsed -gt 0){$text+=' | Average source read: '+[math]::Round($p.bytes_done/$p.seconds_elapsed/1e6,1)+' MB/s'}
   if($s.State -eq 'Completed'){$text='Completed successfully. '+$text;$progress.Value=1000}
   if($s.State -eq 'Failed'){$text='Failed: '+$s.Error}
   $status.Text=$text;$details.Text=$script:run
  }
  if($script:worker.HasExited){$timer.Stop();foreach($c in @($backup,$preview,$verify,$restore,$grid,$defaultMode,$profile,$rate,$memory,$skip,$force)){$c.Enabled=$true}}
 }catch{}
})
if($AttachRunDirectory){
 $running=@(Get-CimInstance Win32_Process|Where-Object {$_.Name -in @('pwsh.exe','powershell.exe') -and $_.CommandLine -and $_.CommandLine.Contains('Backup-Worker.ps1') -and $_.CommandLine.Contains($AttachRunDirectory)})
 if($running.Count -eq 1){$script:run=$AttachRunDirectory;$script:worker=Get-Process -Id $running[0].ProcessId;foreach($c in @($backup,$preview,$verify,$restore,$grid,$defaultMode,$profile,$rate,$memory,$skip,$force)){$c.Enabled=$false};$form.Add_Shown({$timer.Start()})}
}
$form.Add_FormClosing({param($sender,$e) if($script:worker -and -not $script:worker.HasExited){$e.Cancel=$true;Show-Error 'A backup is running. Wait for it to finish before closing this window.'}})
if($RenderPreview){$form.Add_Shown({$bitmap=[Drawing.Bitmap]::new($form.Width,$form.Height);$form.DrawToBitmap($bitmap,[Drawing.Rectangle]::new(0,0,$form.Width,$form.Height));$bitmap.Save($RenderPreview);$bitmap.Dispose();$form.Close()})}
[void]$form.ShowDialog()
