#Requires -Version 7.2
# Backup Center: one window for every backup drive, what goes on it, how fresh it is,
# drive speed and explanations. It runs the existing tools underneath:
# Invoke-FastMirror.ps1 (plain copy) and Backup-Worker.ps1 (versioned history).
param(
 [string]$DataRoot,          # tests: keep profiles, jobs and history in this folder
 [string]$RenderPreview,     # tests: save a picture of the window and close it
 [int]$PreviewTab=0,
 [int]$AutoCloseSeconds=0    # tests: run normally, then close after this many seconds
)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'BackupCenter.Data.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Backup.Selection.psm1') -Force
[void](Set-CenterPaths $DataRoot)
[Globalization.CultureInfo]::CurrentCulture=[Globalization.CultureInfo]::GetCultureInfo('en-GB')
[Globalization.CultureInfo]::CurrentUICulture=[Globalization.CultureInfo]::GetCultureInfo('en-US')
Add-Type -AssemblyName System.Windows.Forms,System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()
# Unexpected errors in event handlers: log where they happened and say so plainly.
# This must be set up before the first control is created.
$script:errorLog=Join-Path $env:LOCALAPPDATA 'DevDriveMirror\center\ui-errors.log'
[Windows.Forms.Application]::SetUnhandledExceptionMode([Windows.Forms.UnhandledExceptionMode]::CatchException)
[Windows.Forms.Application]::add_ThreadException({param($s,$e)
 $ex=$e.Exception;$where=if($ex -is [Management.Automation.RuntimeException] -and $ex.ErrorRecord){$ex.ErrorRecord.ScriptStackTrace}else{$ex.StackTrace}
 try{New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($script:errorLog)) -Force|Out-Null;Add-Content -LiteralPath $script:errorLog -Value ("[{0:o}] {1}`n{2}`n" -f (Get-Date),$ex.Message,$where)}catch{}
 [void][Windows.Forms.MessageBox]::Show("Something went wrong: $($ex.Message)`n`nThe details were saved to $($script:errorLog).",'Backup Center',[Windows.Forms.MessageBoxButtons]::OK,[Windows.Forms.MessageBoxIcon]::Warning)
})

# --- Texts ---------------------------------------------------------------------------------
$Help=[ordered]@{
 Modes=@'
Plain copy (mirror): an ordinary, uncompressed copy of the files on the backup drive. You can open and use the files directly from the drive, on any computer. Each run copies only files that are new or changed (compared by size and time). Files you delete here are not deleted from the copy; they stay there until you clean them up.

Versions (history): encrypted, compressed snapshots. Every run keeps a new version, so you can go back to how a file looked on an earlier date. Opening files needs this window (Versions and restore) or the restic program with the recovery key. Identical data is stored once, so many versions take little extra space.

Both: a plain copy and versions. The safest choice for important work.

Skip: not backed up.

"Folders not listed" applies to everything in the source that has no row of its own. Rebuildable folders (node_modules, virtual environments, caches) are always skipped.
'@
 Freshness=@'
Green: backed up within the last 24 hours.
Blue: older than a day, but not yet old.
Orange: older than the "Mark as old after" days you set.
Grey: never backed up, or nothing selected.

A drive is only as fresh as its oldest source. A source using Both is only as fresh as the older of its copy and its versions.
'@
 Overview=@'
Back up now runs every source of this drive, one after another: first the plain copy, then the versions, as each source's folder choices say. The drive must be connected.

Check backup content reads every file again on both sides and compares them (plain copy), or reads every stored piece back and checks it (versions). It takes much longer than a backup and changes nothing.
'@
 Load=@'
Load decides how much of this computer a backup may use, so you can keep working.

Light: a small part of the processor and memory, and your programs always come first. Use it while you work.
Balanced: a third of the processor, still behind your programs.
Strong: half of the processor, at normal priority.
Maximum: almost everything. Use it when you are away from the computer.
Custom: your own numbers.

Processor threads are used to compress and encrypt versions. Files at once is how many files a plain copy writes at the same time. The memory limit is a hard cap for the versions engine. Priority decides who wins when your own programs need the computer.

You can change the load while a backup runs. The priority changes at once; threads, memory and files at once apply from the next step.
'@
 Speed=@'
Speed test writes one temporary file (2 GB) to the backup drive, reads it back and deletes it. It also shows how the drive is connected: USB 2 is slow (about 40 MB/s), 5 Gbit/s USB reaches about 450 MB/s, 10 Gbit/s USB and Thunderbolt more.

Many small files are limited by the drive they are read from, not by the backup drive. A low MB/s during a backup of a code folder is normal.
'@
 General=@'
Profiles: each backup drive has its own profile, recognised by the drive itself rather than its letter. A profile lists the folders (sources) that go onto that drive, so different drives can hold different content.

Sources: any folder on this computer, such as a whole drive, a project or Documents. Inside each source you choose per folder how it is backed up.

Where things are on the backup drive: plain copies are in one folder per source (shown on the "What to back up" tab, for example DevDrive-Mirror). Versions are in one encrypted repository per source (for example DevDrive-Backup).

Keys: versions are encrypted. The first versioned backup of a source creates a recovery key file in the "Backup Center recovery keys" folder in your user folder. Copy it to a password manager or print it. Without it, versions cannot be opened on another computer.

Never copied: rebuildable folders (node_modules, virtual environments, caches), shortcuts (junctions and links; their real folders are copied where they really are), the recycle bin and Windows system folders, and the runner folder that holds credentials.
'@
}

# --- Window --------------------------------------------------------------------------------
# Look: cool archival paper, white work surfaces, slate ink. Bahnschrift (an industrial,
# label-like face shipped with Windows) for names and numbers; Segoe UI for reading.
# One loud element: the age of the last complete backup on the overview.
$ui=@{
 Paper=[Drawing.Color]::FromArgb(236,240,239);Surface=[Drawing.Color]::White;Ink=[Drawing.Color]::FromArgb(31,42,46)
 Muted=[Drawing.Color]::FromArgb(94,107,112);Line=[Drawing.Color]::FromArgb(206,214,216);Select=[Drawing.Color]::FromArgb(220,229,233)
}
$stateColor=@{Fresh=[Drawing.Color]::FromArgb(46,139,87);OK=[Drawing.Color]::FromArgb(92,124,143);Stale=[Drawing.Color]::FromArgb(199,130,42);Never=[Drawing.Color]::FromArgb(154,163,168);'Nothing selected'=[Drawing.Color]::FromArgb(154,163,168);Error=[Drawing.Color]::FromArgb(178,34,34)}
function Get-Face([string]$Name,[double]$Size,[Drawing.FontStyle]$Style=[Drawing.FontStyle]::Regular){
 $f=[Drawing.Font]::new($Name,[single]$Size,$Style);if($f.Name -ne $Name){$f=[Drawing.Font]::new('Segoe UI',[single]$Size,$Style)};$f
}
$font=Get-Face 'Segoe UI' 9.75
$small=Get-Face 'Segoe UI' 9
$bold=Get-Face 'Bahnschrift SemiBold' 11.5
$labelFace=Get-Face 'Bahnschrift' 10
$form=[Windows.Forms.Form]::new();$form.Text='Backup Center';$form.ClientSize=[Drawing.Size]::new(1200,800);$form.StartPosition='CenterScreen';$form.Font=$font;$form.MinimumSize=[Drawing.Size]::new(1216,839);$form.BackColor=$ui.Paper;$form.ForeColor=$ui.Ink
$iconFile=Join-Path $PSScriptRoot 'BackupCenter.ico';if(Test-Path -LiteralPath $iconFile){$form.Icon=[Drawing.Icon]::new($iconFile)}
function New-Control([string]$Type,$Parent,[int]$X,[int]$Y,[int]$W,[int]$H,[string]$Text=''){
 $c=New-Object ('Windows.Forms.'+$Type);$c.SetBounds($X,$Y,$W,$H);if($Text){$c.Text=$Text};$Parent.Controls.Add($c);$c
}
function New-Note($Parent,[int]$X,[int]$Y,[int]$W,[int]$H,[string]$Text){
 # Explanations read as quiet text on the page, not as boxed fields.
 $t=New-Control TextBox $Parent $X $Y $W $H;$t.Multiline=$true;$t.ReadOnly=$true;$t.BorderStyle='None';$t.BackColor=$Parent.BackColor;$t.ForeColor=$ui.Muted;$t.TabStop=$false
 $t.Text=$Text.Trim().Replace("`r`n","`n").Replace("`n","`r`n");$t.ScrollBars='Vertical';$t
}
function Set-Button($b,[switch]$Primary){
 $b.FlatStyle='Flat';$b.Cursor='Hand';$b.FlatAppearance.BorderSize=1
 if($Primary){$b.BackColor=$ui.Ink;$b.ForeColor=[Drawing.Color]::White;$b.FlatAppearance.BorderColor=$ui.Ink;$b.FlatAppearance.MouseOverBackColor=[Drawing.Color]::FromArgb(55,70,76);$b.Font=Get-Face 'Segoe UI Semibold' 9.75}
 else{$b.BackColor=$ui.Surface;$b.ForeColor=$ui.Ink;$b.FlatAppearance.BorderColor=$ui.Line;$b.FlatAppearance.MouseOverBackColor=$ui.Select}
 $b.Add_EnabledChanged({param($s,$e)$s.ForeColor=if($s.Enabled){if($s.BackColor -eq $ui.Ink){[Drawing.Color]::White}else{$ui.Ink}}else{$ui.Muted}})
 $b
}
function New-Button($Parent,[int]$X,[int]$Y,[int]$W,[int]$H,[string]$Text,[switch]$Primary){Set-Button (New-Control Button $Parent $X $Y $W $H $Text) -Primary:$Primary}
function New-Link($Parent,[int]$X,[int]$Y,[int]$W,[string]$Text){
 $l=New-Control LinkLabel $Parent $X $Y $W 22 $Text;$l.LinkColor=$ui.Ink;$l.ActiveLinkColor=$ui.Ink;$l.DisabledLinkColor=$ui.Muted;$l.LinkBehavior='HoverUnderline';$l
}
function Set-Grid($g){
 $g.BorderStyle='None';$g.BackgroundColor=$ui.Surface;$g.GridColor=$ui.Line;$g.CellBorderStyle='SingleHorizontal';$g.RowHeadersVisible=$false;$g.AllowUserToAddRows=$false;$g.AllowUserToResizeRows=$false
 $g.EnableHeadersVisualStyles=$false;$g.ColumnHeadersBorderStyle='None';$g.ColumnHeadersHeight=34;$g.ColumnHeadersHeightSizeMode='DisableResizing'
 $g.ColumnHeadersDefaultCellStyle.BackColor=$ui.Surface;$g.ColumnHeadersDefaultCellStyle.ForeColor=$ui.Muted;$g.ColumnHeadersDefaultCellStyle.Font=$small;$g.ColumnHeadersDefaultCellStyle.SelectionBackColor=$ui.Surface
 $g.DefaultCellStyle.SelectionBackColor=$ui.Select;$g.DefaultCellStyle.SelectionForeColor=$ui.Ink;$g.DefaultCellStyle.ForeColor=$ui.Ink;$g.DefaultCellStyle.Padding=[Windows.Forms.Padding]::new(6,0,6,0)
 $g.RowTemplate.Height=32;$g.AutoSizeColumnsMode='Fill';$g.SelectionMode='FullRowSelect';$g.MultiSelect=$false
}
function New-Surface($Parent,[int]$X,[int]$Y,[int]$W,[int]$H){$p=New-Control Panel $Parent $X $Y $W $H;$p.BackColor=$ui.Surface;$p}

$title=New-Control Label $form 24 18 600 34 'Backup Center';$title.Font=Get-Face 'Bahnschrift SemiBold' 19
$subtitle=New-Control Label $form 26 54 900 20 'Plain copies and versioned history of your folders. Each backup drive has its own profile and its own folders.';$subtitle.ForeColor=$ui.Muted

# Left rail: the drives, drawn like labels with a status stripe.
$rail=New-Surface $form 24 92 320 692
(New-Control Label $rail 16 14 288 24 'Backup drives').Font=$bold
$driveList=New-Control ListBox $rail 0 46 320 360;$driveList.DrawMode='OwnerDrawFixed';$driveList.ItemHeight=82;$driveList.BorderStyle='None';$driveList.BackColor=$ui.Surface;$driveList.IntegralHeight=$false
$script:driveRows=@()
$driveList.Add_DrawItem({param($s,$e)
 if($e.Index -lt 0 -or $e.Index -ge $script:driveRows.Count){return}
 $r=$script:driveRows[$e.Index];$g=$e.Graphics;$g.TextRenderingHint='ClearTypeGridFit'
 $selected=($e.State -band [Windows.Forms.DrawItemState]::Selected) -ne 0
 $bg=if($selected){$ui.Select}else{$ui.Surface};$g.FillRectangle([Drawing.SolidBrush]::new($bg),$e.Bounds)
 $g.FillRectangle([Drawing.SolidBrush]::new($stateColor[$r.State]),$e.Bounds.X+12,$e.Bounds.Y+12,4,$e.Bounds.Height-24)
 $g.DrawString($r.Name,$bold,[Drawing.SolidBrush]::new($ui.Ink),$e.Bounds.X+28,$e.Bounds.Y+11)
 $g.DrawString($r.Where,$small,[Drawing.SolidBrush]::new($ui.Muted),$e.Bounds.X+29,$e.Bounds.Y+36)
 $g.DrawString($r.When,$small,[Drawing.SolidBrush]::new($stateColor[$r.State]),$e.Bounds.X+29,$e.Bounds.Y+54)
 $g.DrawLine([Drawing.Pen]::new($ui.Line),$e.Bounds.X+12,$e.Bounds.Bottom-1,$e.Bounds.Right-12,$e.Bounds.Bottom-1)
})
$newProfile=New-Button $rail 16 414 140 34 'New profile...'
$removeProfile=New-Button $rail 164 414 140 34 'Remove profile'
(New-Control Label $rail 16 474 288 22 'Status colours').Font=$labelFace
$legend=New-Note $rail 16 500 292 184 $Help.Freshness;$legend.ScrollBars='None'

# Content: flat navigation with an underline under the open page.
$content=New-Control Panel $form 360 92 816 692;$content.BackColor=$ui.Paper
$navUnderline=New-Control Panel $content 0 34 10 3;$navUnderline.BackColor=$ui.Ink
$pageNames=@('Overview','What to back up','Speed and load','Help');$navButtons=@();$pages=@()
$x=0
foreach($n in $pageNames){
 $w=[Windows.Forms.TextRenderer]::MeasureText($n,$labelFace).Width+24
 $b=New-Control Button $content $x 0 $w 34 $n;$b.FlatStyle='Flat';$b.FlatAppearance.BorderSize=0;$b.FlatAppearance.MouseOverBackColor=$ui.Paper;$b.FlatAppearance.MouseDownBackColor=$ui.Paper;$b.Font=$labelFace;$b.ForeColor=$ui.Muted;$b.Cursor='Hand';$b.TextAlign='MiddleLeft';$b.Padding=[Windows.Forms.Padding]::new(0)
 $navButtons+=$b;$x+=$w+8
 $pg=New-Surface $content 0 46 816 646;$pg.Visible=$false;$pages+=$pg
}
$navLine=New-Control Panel $content 0 37 816 1;$navLine.BackColor=$ui.Line;$navUnderline.BringToFront()
function Show-Page([int]$Index){
 for($i=0;$i -lt $pages.Count;$i++){$pages[$i].Visible=($i -eq $Index);$navButtons[$i].ForeColor=if($i -eq $Index){$ui.Ink}else{$ui.Muted}}
 $navUnderline.SetBounds($navButtons[$Index].Left,34,[Windows.Forms.TextRenderer]::MeasureText($pageNames[$Index],$labelFace).Width,3)
}
for($i=0;$i -lt $navButtons.Count;$i++){$idx=$i;$navButtons[$i].Add_Click({Show-Page $idx}.GetNewClosure())}
$tOverview,$tSources,$tSpeed,$tHelp=$pages

# Overview
$ovTitle=New-Control Label $tOverview 24 20 520 30 '';$ovTitle.Font=Get-Face 'Bahnschrift SemiBold' 15
$ovDrive=New-Control Label $tOverview 25 52 520 20 '';$ovDrive.ForeColor=$ui.Muted
$ageNumber=New-Control Label $tOverview 18 80 200 76 '';$ageNumber.Font=Get-Face 'Bahnschrift SemiBold' 44;$ageNumber.AutoSize=$true
$ageUnit=New-Control Label $tOverview 140 96 640 26 '';$ageUnit.Font=Get-Face 'Bahnschrift' 15
$ageWhen=New-Control Label $tOverview 140 124 640 20 '';$ageWhen.ForeColor=$ui.Muted
(New-Control Label $tOverview 560 26 120 22 'Mark as old after').ForeColor=$ui.Muted
$oldDays=New-Control NumericUpDown $tOverview 682 22 52 26;$oldDays.Minimum=1;$oldDays.Maximum=365;$oldDays.BorderStyle='FixedSingle'
(New-Control Label $tOverview 740 26 50 22 'days').ForeColor=$ui.Muted
(New-Control Label $tOverview 560 58 120 22 'Computer load').ForeColor=$ui.Muted
$loadPick=New-Control ComboBox $tOverview 682 54 110 26;$loadPick.DropDownStyle='DropDownList';$loadPick.FlatStyle='Flat';[void]$loadPick.Items.AddRange([object[]]@('Light','Balanced','Strong','Maximum','Custom'))
$meter=New-Control Panel $tOverview 24 166 768 6;$meter.BackColor=$ui.Line
$meterFill=New-Control Panel $meter 0 0 0 6
$meterNote=New-Control Label $tOverview 24 176 768 20 '';$meterNote.ForeColor=$ui.Muted;$meterNote.Font=$small
$ovGrid=New-Control DataGridView $tOverview 24 206 768 162;Set-Grid $ovGrid;$ovGrid.ReadOnly=$true
foreach($c in @(@('Source',20),@('Folder',28),@('Plain copy',17),@('Versions',17),@('Status',18))){$i=$ovGrid.Columns.Add($c[0],$c[0]);$ovGrid.Columns[$i].FillWeight=$c[1]}
$btnBackup=New-Button $tOverview 24 384 180 38 'Back up now' -Primary
$btnBackupOne=New-Button $tOverview 214 384 190 38 'Back up selected source'
$btnVerify=New-Button $tOverview 414 384 180 38 'Check backup content'
$btnStop=New-Button $tOverview 692 384 100 38 'Stop';$btnStop.Enabled=$false
$btnOpen=New-Link $tOverview 24 434 170 'Open plain copy folder'
$btnRestore=New-Link $tOverview 204 434 160 'Versions and restore'
$btnKeys=New-Link $tOverview 374 434 200 'Password and recovery key'
$btnRefresh=New-Link $tOverview 732 434 60 'Refresh';$btnRefresh.TextAlign='TopRight'
$progress=New-Control ProgressBar $tOverview 24 468 768 6;$progress.Style='Continuous'
$runStatus=New-Control Label $tOverview 24 480 768 44 'Ready.'
$ovNote=New-Note $tOverview 24 532 640 106 $Help.Overview;$ovNote.ScrollBars='None'

# What to back up
(New-Control Label $tSources 24 20 260 24 'Sources on this drive').Font=$bold
$srcList=New-Control ListBox $tSources 24 50 260 284;$srcList.BorderStyle='FixedSingle';$srcList.ItemHeight=22;$srcList.IntegralHeight=$false
$btnAddSource=New-Button $tSources 24 342 126 32 'Add folder...'
$btnRemoveSource=New-Button $tSources 158 342 126 32 'Remove'
$srcInfo=New-Control Label $tSources 24 386 260 150 '';$srcInfo.ForeColor=$ui.Muted
(New-Control Label $tSources 304 20 488 24 'Folders and how each is backed up').Font=$bold
$modeGrid=New-Control DataGridView $tSources 304 50 488 284;Set-Grid $modeGrid;$modeGrid.EditMode='EditOnEnter';$modeGrid.BorderStyle='FixedSingle'
$colFolder=[Windows.Forms.DataGridViewTextBoxColumn]::new();$colFolder.Name='Folder';$colFolder.HeaderText='Folder';$colFolder.ReadOnly=$true;$colFolder.FillWeight=50;[void]$modeGrid.Columns.Add($colFolder)
$modeTable=[Data.DataTable]::new();[void]$modeTable.Columns.Add('Value');[void]$modeTable.Columns.Add('Display')
foreach($m in @(@('Mirror','Plain copy'),@('Versioned','Versions'),@('Both','Both'),@('Skip','Skip'))){[void]$modeTable.Rows.Add($m[0],$m[1])}
$colMode=[Windows.Forms.DataGridViewComboBoxColumn]::new();$colMode.Name='Mode';$colMode.HeaderText='Backed up as';$colMode.DataSource=$modeTable;$colMode.ValueMember='Value';$colMode.DisplayMember='Display';$colMode.FillWeight=24;$colMode.FlatStyle='Flat';[void]$modeGrid.Columns.Add($colMode)
$colNote=[Windows.Forms.DataGridViewTextBoxColumn]::new();$colNote.Name='Note';$colNote.HeaderText='Note';$colNote.FillWeight=26;[void]$modeGrid.Columns.Add($colNote)
(New-Control Label $tSources 304 348 120 22 'Folders not listed').ForeColor=$ui.Muted
$defaultMode=New-Control ComboBox $tSources 426 344 130 28;$defaultMode.DropDownStyle='DropDownList';$defaultMode.FlatStyle='Flat';$defaultMode.DataSource=$modeTable.Copy();$defaultMode.ValueMember='Value';$defaultMode.DisplayMember='Display'
$btnAddSub=New-Button $tSources 564 342 112 32 'Add subfolder...'
$btnSaveModes=New-Button $tSources 682 342 110 32 'Save changes' -Primary
[void](New-Note $tSources 304 390 488 248 $Help.Modes)

# Drive and speed
$driveInfo=New-Control Label $tSpeed 24 20 768 24 '';$driveInfo.Font=$bold
$driveFacts=New-Control Label $tSpeed 25 48 768 20 '';$driveFacts.ForeColor=$ui.Muted
$btnSpeed=New-Button $tSpeed 24 84 160 36 'Run speed test' -Primary
$speedWrite=New-Control Label $tSpeed 206 78 180 44 '';$speedWrite.Font=Get-Face 'Bahnschrift SemiBold' 22
$speedRead=New-Control Label $tSpeed 396 78 180 44 '';$speedRead.Font=Get-Face 'Bahnschrift SemiBold' 22
$speedResult=New-Control Label $tSpeed 206 122 586 44 'No speed test yet.';$speedResult.ForeColor=$ui.Muted
(New-Control Label $tSpeed 24 176 768 24 'This computer and how hard to work').Font=$bold
$hwInfo=New-Control Label $tSpeed 25 202 768 20 '';$hwInfo.ForeColor=$ui.Muted
(New-Control Label $tSpeed 24 234 60 22 'Load').ForeColor=$ui.Muted
$loadLevel=New-Control ComboBox $tSpeed 88 230 120 26;$loadLevel.DropDownStyle='DropDownList';$loadLevel.FlatStyle='Flat';[void]$loadLevel.Items.AddRange([object[]]@('Light','Balanced','Strong','Maximum','Custom'))
$loadText=New-Control Label $tSpeed 220 234 572 22 ''
(New-Control Label $tSpeed 24 270 116 22 'Processor threads').ForeColor=$ui.Muted
$customThreads=New-Control NumericUpDown $tSpeed 142 266 52 26;$customThreads.Minimum=1;$customThreads.Maximum=[Environment]::ProcessorCount
(New-Control Label $tSpeed 206 270 96 22 'Memory (MB)').ForeColor=$ui.Muted
$customMemory=New-Control NumericUpDown $tSpeed 302 266 72 26;$customMemory.Minimum=512;$customMemory.Maximum=8192;$customMemory.Increment=256
(New-Control Label $tSpeed 386 270 92 22 'Files at once').ForeColor=$ui.Muted
$customFiles=New-Control NumericUpDown $tSpeed 478 266 52 26;$customFiles.Minimum=1;$customFiles.Maximum=128
(New-Control Label $tSpeed 542 270 56 22 'Priority').ForeColor=$ui.Muted
$customPriority=New-Control ComboBox $tSpeed 600 266 110 26;$customPriority.DropDownStyle='DropDownList';$customPriority.FlatStyle='Flat';[void]$customPriority.Items.AddRange([object[]]@('Below normal','Normal'))
$btnSaveLoad=New-Button $tSpeed 718 264 74 30 'Save'
$loadAdvice=New-Control Label $tSpeed 24 302 768 20 '';$loadAdvice.ForeColor=$ui.Muted
(New-Control Label $tSpeed 24 334 400 24 'Recent runs on this drive').Font=$bold
$runsGrid=New-Control DataGridView $tSpeed 24 362 768 150;Set-Grid $runsGrid;$runsGrid.ReadOnly=$true
foreach($c in @(@('When',14),@('Source',14),@('Type',12),@('Duration',10),@('Copied',22),@('Speed',10),@('Result',18))){$i=$runsGrid.Columns.Add($c[0],$c[0]);$runsGrid.Columns[$i].FillWeight=$c[1]}
[void](New-Note $tSpeed 24 524 640 114 ($Help.Load+"`n`n"+$Help.Speed))

# Help
[void](New-Note $tHelp 24 20 640 618 ("How Backup Center works`n`n"+$Help.General+"`n`n`nHow each folder can be backed up`n`n"+$Help.Modes+"`n`n`nStatus colours`n`n"+$Help.Freshness+"`n`n`nComputer load`n`n"+$Help.Load+"`n`n`nDrive speed`n`n"+$Help.Speed))

# --- State and refresh -------------------------------------------------------------------
$script:data=Read-CenterProfiles
$script:queue=[Collections.Generic.Queue[object]]::new();$script:current=$null;$script:runResults=@();$script:runProfile=$null;$script:totalSteps=0
$script:lastFree=$null;$script:lastTick=$null;$script:loadingModes=$false
$stateText=@{Fresh='Fresh';OK='OK';Stale='Needs a backup';Never='Never backed up';'Nothing selected'='Nothing selected';Error='Settings cannot be read'}

function Get-SelectedProfile {
 $i=$driveList.SelectedIndex;if($i -lt 0 -or $i -ge $script:driveRows.Count){return $null}
 @($script:data.Profiles|Where-Object {$_.Id -eq $script:driveRows[$i].Id})[0]
}
function Get-SelectedSource {
 $p=Get-SelectedProfile;if(-not $p -or $srcList.SelectedIndex -lt 0){return $null}
 @($p.Sources)[$srcList.SelectedIndex]
}
function Format-When($When){if($When){'{0} ({1:d MMM yyyy HH:mm})' -f (Format-CenterAge $When),[datetime]$When}else{'never'}}
function Format-Size([double]$Bytes){if($Bytes -ge 1GB){'{0:N1} GB' -f ($Bytes/1GB)}elseif($Bytes -ge 1MB){'{0:N0} MB' -f ($Bytes/1MB)}else{'{0:N0} KB' -f ($Bytes/1KB)}}

function Split-Age($When){
 # The overview's large readout: a number and its unit.
 if(-not $When){return @('Never','')}
 $age=(Get-Date)-[datetime]$When
 if($age.TotalMinutes -lt 60){$n=[int][math]::Max(1,[math]::Floor($age.TotalMinutes));return @("$n",$(if($n -eq 1){'minute'}else{'minutes'}))}
 if($age.TotalHours -lt 48){$n=[int][math]::Floor($age.TotalHours);return @("$n",$(if($n -eq 1){'hour'}else{'hours'}))}
 $n=[int][math]::Floor($age.TotalDays);@("$n",'days')
}
function Update-ProfileList([string]$SelectId) {
 $history=@(Get-CenterHistory)
 $keep=if($SelectId){$SelectId}elseif((Get-SelectedProfile)){(Get-SelectedProfile).Id}else{$null}
 $rows=foreach($p in $script:data.Profiles){
  $d=Get-CenterDrive $p.DestinationVolumeId;$f=Get-CenterFreshness $p $history
  $where=if($d.Connected){"Connected as $($d.Letter):"}else{'Not connected'}
  $when=if($f.LastComplete){'backed up '+(Format-CenterAge $f.LastComplete)}else{'no complete backup yet'}
  [pscustomobject]@{Id=$p.Id;Name=[string]$p.Name;State=$f.State;Where=$where;When=($when.Substring(0,1).ToUpper()+$when.Substring(1))}
 }
 $script:suppress=$true
 try{
  $script:driveRows=@($rows);$driveList.Items.Clear();foreach($r in $script:driveRows){[void]$driveList.Items.Add($r.Name)}
  $idx=0;for($i=0;$i -lt $script:driveRows.Count;$i++){if($script:driveRows[$i].Id -eq $keep){$idx=$i}}
  if($script:driveRows.Count){$driveList.SelectedIndex=$idx}
 }finally{$script:suppress=$false}
 $driveList.Invalidate()
 Update-Details
}

function Update-Details {
 $p=Get-SelectedProfile
 $has=[bool]$p
 foreach($c in @($btnBackup,$btnBackupOne,$btnVerify,$btnOpen,$btnRestore,$btnKeys,$btnAddSource,$btnRemoveSource,$btnSaveModes,$btnAddSub,$btnSpeed,$btnSaveLoad,$oldDays,$removeProfile)){$c.Enabled=$has -and -not $script:current}
 $btnStop.Enabled=[bool]$script:current
 $ovGrid.Rows.Clear();$runsGrid.Rows.Clear();$srcList.Items.Clear();$modeGrid.Rows.Clear()
 if(-not $p){$ovTitle.Text='No backup drive yet';$ovDrive.Text='Connect a backup drive and choose New profile.';$ageNumber.Text='';$ageUnit.Text='';$ageWhen.Text='';$meterFill.Width=0;$meterNote.Text='';$driveInfo.Text='';$driveFacts.Text='';return}
 $history=@(Get-CenterHistory);$d=Get-CenterDrive $p.DestinationVolumeId;$f=Get-CenterFreshness $p $history
 $ovTitle.Text=$p.Name
 $ovDrive.Text=if($d.Connected){"Connected as $($d.Letter):   $($p.DriveModel), $($d.FreeGB) GB free of $($d.SizeGB) GB"}else{"$($p.DriveModel). Not connected: connect it to back up, test its speed or restore."}
 $n,$u=Split-Age $f.LastComplete
 $ageNumber.Text=$n;$ageNumber.ForeColor=$stateColor[$f.State]
 $ageUnit.Left=$ageNumber.Right+6;$ageWhen.Left=$ageUnit.Left
 if($f.LastComplete){
  $ageUnit.Text="$u since the last complete backup"
  $ageWhen.Text=('{0:dddd d MMMM yyyy, HH:mm}.  ' -f [datetime]$f.LastComplete)+$stateText[$f.State]+'.'
  $ageDays=((Get-Date)-[datetime]$f.LastComplete).TotalDays
  $meterFill.Width=[int]($meter.Width*[math]::Min(1,$ageDays/[double]$p.ReminderDays));$meterFill.BackColor=$stateColor[$f.State]
  $left=[double]$p.ReminderDays-$ageDays
  $meterNote.Text=if($left -gt 1){"Counts as old after $($p.ReminderDays) days, in about $([int][math]::Floor($left)) days."}elseif($left -gt 0){"Counts as old after $($p.ReminderDays) days, within a day."}else{"Older than $($p.ReminderDays) days. Back up when you can."}
 }else{
  $ageUnit.Text=if($f.State -eq 'Nothing selected'){'nothing is selected for backup'}else{'no complete backup yet'}
  $ageWhen.Text=if($f.State -eq 'Nothing selected'){'Choose folders on the "What to back up" page.'}else{'A drive is complete when every source has its plain copy and versions, as chosen.'}
  $meterFill.Width=0;$meterNote.Text=''
 }
 foreach($r in $f.Rows){
  $mirror=if($r.Mirror){Format-CenterAge $r.LastMirror}else{'not used'}
  $vers=if($r.Versioned){Format-CenterAge $r.LastVersioned}else{'not used'}
  $i=$ovGrid.Rows.Add($r.Source.Label,$r.Source.Path,$mirror,$vers,$stateText[$r.State]);$ovGrid.Rows[$i].Tag=$r.Source.Id
  $ovGrid.Rows[$i].Cells[4].Style.ForeColor=$stateColor[$r.State];$ovGrid.Rows[$i].Cells[4].Style.SelectionForeColor=$stateColor[$r.State]
 }
 $ovGrid.ClearSelection()
 if($p.PSObject.Properties['LastSpeedTest'] -and $p.LastSpeedTest){
  $t=$p.LastSpeedTest;$speedWrite.Text="$($t.WriteMBps) MB/s";$speedRead.Text="$($t.ReadMBps) MB/s"
  $speedResult.Text="Write, then read. Tested $(Format-CenterAge $t.When). Connection: $($t.Link)."
  if($t.PSObject.Properties['Notes'] -and $t.Notes){$speedResult.Text+="`n"+$t.Notes}
 }else{$speedWrite.Text='';$speedRead.Text='';$speedResult.Text='No speed test yet. It takes about half a minute and leaves nothing behind.'}
 $speedResult.Top=if($speedWrite.Text){122}else{93}
 if(-not $d.Connected){$btnBackup.Enabled=$false;$btnBackupOne.Enabled=$false;$btnVerify.Enabled=$false;$btnOpen.Enabled=$false;$btnRestore.Enabled=$false;$btnSpeed.Enabled=$false}
 foreach($s in $p.Sources){[void]$srcList.Items.Add($s.Label+'   ('+$s.Path+')')}
 if($srcList.Items.Count){$srcList.SelectedIndex=0}else{Update-Modes}
 $driveInfo.Text=$p.Name
 $driveFacts.Text=if($d.Connected){"Drive $($d.Letter):   $($p.DriveModel), $($d.FileSystem), $($d.FreeGB) GB free of $($d.SizeGB) GB"}else{"$($p.DriveModel). Not connected."}
 Update-LoadControls $p
 $script:loadingDays=$true;$oldDays.Value=[decimal]$p.ReminderDays;$script:loadingDays=$false
 foreach($h in @($history|Where-Object {$_.ProfileId -eq $p.Id}|Sort-Object {[datetime]$_.Finished} -Descending|Select-Object -First 40)){
  $type=switch($h.Kind){'Mirror'{'Plain copy'}'Versioned'{'Versions'}'MirrorCheck'{'Copy check'}'VersionedCheck'{'Versions check'}default{$h.Kind}}
  $copied=if($h.Kind -like '*Check' -and $h.CheckedFiles){'{0:N0} checked' -f $h.CheckedFiles}elseif($null -ne $h.CopiedFiles){'{0:N0} files, {1}' -f $h.CopiedFiles,(Format-Size $h.CopiedBytes)}elseif($h.CheckedFiles){'{0:N0} checked' -f $h.CheckedFiles}else{''}
  $speed=if($h.CopiedBytes -ge 100MB -and $h.Minutes -gt 0.05){'{0:N0} MB/s' -f ($h.CopiedBytes/1MB/($h.Minutes*60))}else{''}
  $result=if($h.Success){'OK'}else{'Failed: '+$h.Error}
  $i=$runsGrid.Rows.Add(('{0:d MMM HH:mm}' -f [datetime]$h.Finished),$h.Label,$type,('{0:N1} min' -f $h.Minutes),$copied,$speed,$result)
  if(-not $h.Success){$runsGrid.Rows[$i].DefaultCellStyle.ForeColor=[Drawing.Color]::Firebrick}
 }
}

function Format-Load($L){
 $prio=if($L.Priority -eq 'Normal'){'normal priority'}else{'your programs come first'}
 "$($L.CpuThreads) of $([Environment]::ProcessorCount) processor threads, up to $([math]::Round($L.MemoryMiB/1024,1)) GB memory, $($L.CopyThreads) files at once, $prio."
}
function Update-LoadControls($P){
 $script:loadingLoad=$true
 try{
  $hw=Get-CenterHardware;$L=Get-CenterLoad $P $hw
  $hwInfo.Text="$($hw.CpuName): $($hw.Cores) cores, $($hw.Threads) threads. $($hw.MemoryGB) GB memory, $($hw.FreeMemoryGB) GB free right now."
  $loadPick.SelectedItem=$L.Name;$loadLevel.SelectedItem=$L.Name
  $loadText.Text=Format-Load $L
  $customThreads.Value=[decimal]$L.CpuThreads;$customMemory.Value=[decimal]$L.MemoryMiB;$customFiles.Value=[decimal][math]::Min(128,$L.CopyThreads)
  $customPriority.SelectedItem=if($L.Priority -eq 'Normal'){'Normal'}else{'Below normal'}
  $custom=$L.Name -eq 'Custom';foreach($c in @($customThreads,$customMemory,$customFiles,$customPriority,$btnSaveLoad)){$c.Enabled=$custom}
  $loadAdvice.Text='Suggested: Light or Balanced while you work on this computer, Maximum when you leave it alone.'
 }finally{$script:loadingLoad=$false}
}
function Set-ProfileLoad([string]$Name){
 $p=Get-SelectedProfile;if(-not $p){return}
 $p|Add-Member -NotePropertyName Load -NotePropertyValue $Name -Force
 if($Name -eq 'Custom' -and -not($p.PSObject.Properties['CustomLoad'] -and $p.CustomLoad)){
  $current=Get-CenterLoad ([pscustomobject]@{Load='Balanced'})
  $p|Add-Member -NotePropertyName CustomLoad -NotePropertyValue ([pscustomobject]@{CpuThreads=$current.CpuThreads;MemoryMiB=$current.MemoryMiB;CopyThreads=$current.CopyThreads;Priority=$current.Priority}) -Force
 }
 Save-CenterProfiles $script:data
 # A running backup gets the new priority at once; the rest applies from its next step.
 if($script:current -and $script:runProfile -and $script:runProfile.Id -eq $p.Id){
  $L=Get-CenterLoad $p;Set-CenterRunPriority $script:current.Process $L.Priority
  $runStatus.Text="Load changed to $Name. Priority changed now; threads, memory and files at once apply from the next step."
 }
 Update-LoadControls $p
}

function Update-Modes {
 $script:loadingModes=$true
 try{
  $modeGrid.Rows.Clear();$s=Get-SelectedSource
  if(-not $s){$srcInfo.Text='Add a folder to back up to this drive.';return}
  $job=Read-CenterJob $s.ConfigPath
  foreach($c in @($job.Choices)){
   $note=if($c.PSObject.Properties['Reason']){[string]$c.Reason}else{''}
   $i=$modeGrid.Rows.Add($c.Path,[string]$c.Mode,$note)
  }
  $defaultMode.SelectedValue=if($job.PSObject.Properties['DefaultMode']){[string]$job.DefaultMode}else{'Skip'}
  $kinds=Get-CenterSourceKinds $s
  $srcInfo.Text="Folder: $($s.Path)`nPlain copy goes to: \$($s.MirrorFolder)`nVersions go to: \$($job.RepositoryFolder)`nUses: "+(@(if($kinds.Mirror){'plain copy'};if($kinds.Versioned){'versions'}) -join ' and ')
 }finally{$script:loadingModes=$false}
}

# --- Running -------------------------------------------------------------------------------
function Start-Run($Profile,[string[]]$SourceIds,[string]$Purpose){
 foreach($s in $Profile.Sources){Sync-CenterJob $Profile $s}
 $steps=@(Get-CenterSteps $Profile $SourceIds $Purpose)
 if(-not $steps.Count){[void][Windows.Forms.MessageBox]::Show('Nothing is selected for backup in these sources. Choose folders on the "What to back up" tab.','Backup Center');return}
 $script:queue.Clear();foreach($s in $steps){$script:queue.Enqueue($s)}
 $script:totalSteps=$steps.Count;$script:runResults=@();$script:runProfile=$Profile
 $progress.Style='Marquee';$progress.MarqueeAnimationSpeed=30
 Start-NextStep
}
function Start-NextStep {
 if($script:queue.Count -eq 0){Finish-Run;return}
 $step=$script:queue.Dequeue()
 $out=Join-Path $env:LOCALAPPDATA ('DevDriveMirror\center\step-'+(Get-Date -Format 'yyyyMMdd-HHmmss')+'.log')
 New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($out)) -Force|Out-Null
 $script:current=Start-CenterStep $step $out
 $script:lastFree=$null
 Update-Details;$timer.Start()
}
function Update-RunStatus {
 $c=$script:current;if(-not $c){return}
 $n=$script:totalSteps-$script:queue.Count
 $what=if($c.Step.Kind -eq 'Mirror'){'plain copy'}else{'versions'}
 if($c.Step.Purpose -eq 'Verify'){$what='checking '+$what}
 $elapsed=(Get-Date)-$c.Started
 $line="Step $n of $($script:totalSteps): $($c.Step.Label) - $what. Running for $([int]$elapsed.TotalMinutes) min $($elapsed.Seconds) s."
 $d=Get-CenterDrive $script:runProfile.DestinationVolumeId
 if($d.Connected){
  $free=(Get-Volume -DriveLetter $d.Letter).SizeRemaining;$now=Get-Date
  if($script:lastFree -and ($now-$script:lastTick).TotalSeconds -gt 0){$rate=($script:lastFree-$free)/1MB/($now-$script:lastTick).TotalSeconds;if($rate -ge 0){$line+="  Writing about {0:N0} MB/s." -f $rate}}
  $script:lastFree=$free;$script:lastTick=$now
 }
 if($c.Step.Kind -eq 'Versioned' -and $c.Step.RunDirectory){
  $st=Join-Path $c.Step.RunDirectory 'status.json'
  if(Test-Path -LiteralPath $st){try{$s=Get-Content -LiteralPath $st -Raw|ConvertFrom-Json;if($s.Progress -and $s.Progress.PSObject.Properties['percent_done']){$line+="  {0:P0} done." -f [double]$s.Progress.percent_done;if($s.Progress.PSObject.Properties['seconds_remaining']){$line+=' About {0} min left.' -f [math]::Ceiling([double]$s.Progress.seconds_remaining/60)}}}catch{}}
 }
 $runStatus.Text=$line
}
function Finish-Run {
 $timer.Stop();$script:current=$null;$progress.Style='Continuous';$progress.Value=0
 $ok=@($script:runResults|Where-Object {$_.Success}).Count;$bad=@($script:runResults|Where-Object {-not $_.Success})
 $msg="$ok of $($script:runResults.Count) steps finished successfully."
 foreach($b in $bad){$msg+="`n`n$($b.Label) ($($b.Kind)): $($b.Error)"}
 # A first versioned backup creates a recovery key; say where it is so it gets copied somewhere safe.
 foreach($r in @($script:runResults|Where-Object {$_.Kind -eq 'Versioned' -and $_.Success})){
  $src=@($script:runProfile.Sources|Where-Object {$_.Id -eq $r.SourceId})[0]
  if(-not $src){continue}
  $key=[string](Read-CenterJob $src.ConfigPath).RecoveryKeyPath
  if($key -and (Test-Path -LiteralPath $key) -and (Get-Item -LiteralPath $key).CreationTime -ge [datetime]$r.Started){
   $msg+="`n`nA new recovery key for $($src.Label) was saved to:`n$key`nCopy it to a password manager or print it. Without it, these versions cannot be opened on another computer."
  }
 }
 $runStatus.Text=$msg.Split("`n")[0]
 Update-ProfileList $script:runProfile.Id
 [void][Windows.Forms.MessageBox]::Show($msg,'Backup Center',[Windows.Forms.MessageBoxButtons]::OK,$(if($bad.Count){[Windows.Forms.MessageBoxIcon]::Warning}else{[Windows.Forms.MessageBoxIcon]::Information}))
}
$timer=[Windows.Forms.Timer]::new();$timer.Interval=1000
$timer.Add_Tick({
 try{
  if(-not $script:current){$timer.Stop();return}
  if($script:current.Process.HasExited){
   $r=Complete-CenterStep $script:current $script:runProfile.Id
   $script:runResults+=$r;$script:current=$null
   Start-NextStep
  }else{try{Update-RunStatus}catch{$runStatus.Text='Running. (Progress is not available right now.)'}}
 }catch{
  # Keep following the running tool; only a failure to record its result ends this step.
  $runStatus.Text='Could not read the progress this time: '+$_.Exception.Message
  if($script:current -and $script:current.Process.HasExited){$script:current=$null;$script:queue.Clear();$timer.Stop();Update-Details;[void][Windows.Forms.MessageBox]::Show('The step finished, but its result could not be recorded: '+$_.Exception.Message,'Backup Center')}
 }
})

# --- Dialogs -------------------------------------------------------------------------------
function Show-NewProfileDialog {
 $drives=@(Get-CenterCandidateDrives|Where-Object {$v=$_.VolumeId;-not @($script:data.Profiles|Where-Object {$_.DestinationVolumeId -eq $v}).Count})
 if(-not $drives.Count){[void][Windows.Forms.MessageBox]::Show('No connected drive without a profile was found. Connect the backup drive and try again.','Backup Center');return $null}
 $f=[Windows.Forms.Form]::new();$f.Text='New backup drive profile';$f.ClientSize=[Drawing.Size]::new(560,250);$f.Font=$font;$f.StartPosition='CenterParent';$f.FormBorderStyle='FixedDialog';$f.MaximizeBox=$false;$f.MinimizeBox=$false
 [void](New-Control Label $f 16 16 520 20 'Backup drive:')
 $combo=New-Control ComboBox $f 16 40 528 28;$combo.DropDownStyle='DropDownList'
 foreach($d in $drives){[void]$combo.Items.Add(('{0}:  {1}  -  {2}  -  {3} {4}, {5:N0} GB free of {6:N0} GB' -f $d.Letter,$(if($d.Label){$d.Label}else{'(no label)'}),$d.Model,$d.FileSystem,$d.BusType,$d.FreeGB,$d.SizeGB))}
 $combo.SelectedIndex=0
 [void](New-Control Label $f 16 80 520 20 'Profile name:')
 $name=New-Control TextBox $f 16 104 528 26;$name.Text=$drives[0].Model
 $combo.Add_SelectedIndexChanged({$name.Text=$drives[$combo.SelectedIndex].Model})
 [void](New-Control Label $f 16 138 528 46 'The profile recognises this drive by its identity, so a different drive letter later does not matter. The drive is not changed or formatted.')
 $ok=New-Control Button $f 344 200 96 32 'Create';$ok.DialogResult='OK';$cancel=New-Control Button $f 448 200 96 32 'Cancel';$cancel.DialogResult='Cancel';$f.AcceptButton=$ok;$f.CancelButton=$cancel
 if($f.ShowDialog($form) -ne 'OK'){return $null}
 $d=$drives[$combo.SelectedIndex]
 [pscustomobject]@{Name=$name.Text;Drive=$d}
}
function Show-SourceDialog([string]$Path){
 $f=[Windows.Forms.Form]::new();$f.Text='Add a folder to back up';$f.ClientSize=[Drawing.Size]::new(560,300);$f.Font=$font;$f.StartPosition='CenterParent';$f.FormBorderStyle='FixedDialog';$f.MaximizeBox=$false;$f.MinimizeBox=$false
 [void](New-Control Label $f 16 16 528 20 "Folder: $Path")
 [void](New-Control Label $f 16 48 528 20 'Name shown in this window:')
 $label=New-Control TextBox $f 16 72 528 26;$label.Text=if($Path.Length -le 3){'Drive '+$Path.Substring(0,1)}else{Split-Path -Leaf $Path.TrimEnd('\')}
 [void](New-Control Label $f 16 108 528 20 'Back up its folders as (you can change single folders afterwards):')
 $mode=New-Control ComboBox $f 16 132 260 28;$mode.DropDownStyle='DropDownList';$mode.DataSource=$modeTable.Copy();$mode.ValueMember='Value';$mode.DisplayMember='Display'
 [void](New-Control Label $f 16 168 528 70 'Plain copy: ordinary files you can open directly. Versions: encrypted history you can go back in. Both: a copy and a history. See the explanation on the "What to back up" tab.')
 $ok=New-Control Button $f 344 252 96 32 'Add';$ok.DialogResult='OK';$cancel=New-Control Button $f 448 252 96 32 'Cancel';$cancel.DialogResult='Cancel';$f.AcceptButton=$ok;$f.CancelButton=$cancel
 $f.Add_Shown({$mode.SelectedValue='Mirror'})
 if($f.ShowDialog($form) -ne 'OK'){return $null}
 [pscustomobject]@{Label=$label.Text;Mode=[string]$mode.SelectedValue}
}
function Show-Error($e){[void][Windows.Forms.MessageBox]::Show($e.Exception.Message,'Backup Center',[Windows.Forms.MessageBoxButtons]::OK,[Windows.Forms.MessageBoxIcon]::Warning)}

function Get-OverviewSource {
 $p=Get-SelectedProfile
 if(-not $p -or -not @($p.Sources).Count){throw 'This drive has no folders to back up yet. Add one on the "What to back up" page.'}
 $id=if($ovGrid.SelectedRows.Count){[string]$ovGrid.SelectedRows[0].Tag}else{@($p.Sources)[0].Id}
 @($p.Sources|Where-Object {$_.Id -eq $id})[0]
}
# --- Events --------------------------------------------------------------------------------
$driveList.Add_SelectedIndexChanged({if(-not $script:suppress){Update-Details}})
$srcList.Add_SelectedIndexChanged({try{Update-Modes}catch{Show-Error $_}})
$newProfile.Add_Click({try{
 $r=Show-NewProfileDialog;if(-not $r){return}
 $p=New-CenterProfile $script:data $r.Name $r.Drive.VolumeId $r.Drive.Model $r.Drive.SizeGB;Save-CenterProfiles $script:data
 Update-ProfileList $p.Id;Show-Page 1
}catch{Show-Error $_}})
$removeProfile.Add_Click({try{
 $p=Get-SelectedProfile;if(-not $p){return}
 if([Windows.Forms.MessageBox]::Show("Remove the profile '$($p.Name)'?`n`nOnly the profile is forgotten. Nothing on the backup drive or on this computer is deleted, and the folder settings and keys are kept.",'Backup Center','YesNo','Question') -ne 'Yes'){return}
 Remove-CenterProfile $script:data $p.Id;Save-CenterProfiles $script:data;Update-ProfileList
}catch{Show-Error $_}})
$btnAddSource.Add_Click({try{
 $p=Get-SelectedProfile;if(-not $p){return}
 $dlg=[Windows.Forms.FolderBrowserDialog]::new();$dlg.Description='Choose a folder or drive to back up';$dlg.UseDescriptionForTitle=$true
 if($dlg.ShowDialog($form) -ne 'OK'){return}
 $r=Show-SourceDialog $dlg.SelectedPath;if(-not $r){return}
 [void](Add-CenterSource -Data $script:data -ProfileId $p.Id -Path $dlg.SelectedPath -Label $r.Label -DefaultMode $r.Mode);Save-CenterProfiles $script:data
 Update-Details;$srcList.SelectedIndex=$srcList.Items.Count-1
}catch{Show-Error $_}})
$btnRemoveSource.Add_Click({try{
 $p=Get-SelectedProfile;$s=Get-SelectedSource;if(-not $s){return}
 if([Windows.Forms.MessageBox]::Show("Stop backing up '$($s.Label)' to this drive?`n`nExisting copies and versions on the drive are kept, and so are its settings and keys.",'Backup Center','YesNo','Question') -ne 'Yes'){return}
 Remove-CenterSource $script:data $p.Id $s.Id;Save-CenterProfiles $script:data;Update-Details
}catch{Show-Error $_}})
$btnAddSub.Add_Click({try{
 $s=Get-SelectedSource;if(-not $s){return}
 $dlg=[Windows.Forms.FolderBrowserDialog]::new();$dlg.SelectedPath=$s.Path;$dlg.Description='Choose a folder inside the source to give its own setting';$dlg.UseDescriptionForTitle=$true
 if($dlg.ShowDialog($form) -ne 'OK'){return}
 $full=$dlg.SelectedPath.TrimEnd('\')
 if(-not $full.StartsWith($s.Path.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Choose a folder inside '+$s.Path}
 $rel=$full.Substring($s.Path.TrimEnd('\').Length+1)
 foreach($row in $modeGrid.Rows){if([string]$row.Cells['Folder'].Value -ieq $rel){throw "$rel already has a row"}}
 [void]$modeGrid.Rows.Add($rel,[string]$defaultMode.SelectedValue,'')
}catch{Show-Error $_}})
$btnSaveModes.Add_Click({try{
 $s=Get-SelectedSource;if(-not $s){return}
 [void]$modeGrid.EndEdit()
 $job=Read-CenterJob $s.ConfigPath
 $old=@{};foreach($c in @($job.Choices)){$old[$c.Path.ToLowerInvariant()]=$c}
 $choices=foreach($row in $modeGrid.Rows){
  $path=[string]$row.Cells['Folder'].Value;$o=$old[$path.ToLowerInvariant()]
  [pscustomobject]@{Path=$path;Mode=[string]$row.Cells['Mode'].Value;Reason=[string]$row.Cells['Note'].Value}
 }
 $job.Choices=@($choices)
 if($job.PSObject.Properties['DefaultMode']){$job.DefaultMode=[string]$defaultMode.SelectedValue}else{$job|Add-Member -NotePropertyName DefaultMode -NotePropertyValue ([string]$defaultMode.SelectedValue)}
 [void](Get-BackupSelection $job)   # validates before saving
 Save-CenterJob $job $s.ConfigPath
 $keepSource=$srcList.SelectedIndex
 Update-ProfileList;if($keepSource -ge 0 -and $keepSource -lt $srcList.Items.Count){$srcList.SelectedIndex=$keepSource}
 $runStatus.Text="Saved the folder choices for $($s.Label)."
 [void][Windows.Forms.MessageBox]::Show("Saved. The next backup of '$($s.Label)' uses these choices.",'Backup Center')
}catch{Show-Error $_}})
$btnBackup.Add_Click({try{$p=Get-SelectedProfile;if($p){Start-Run $p @() 'Backup'}}catch{Show-Error $_;Update-Details}})
$btnBackupOne.Add_Click({try{
 $p=Get-SelectedProfile;if(-not $p -or $ovGrid.SelectedRows.Count -eq 0){[void][Windows.Forms.MessageBox]::Show('Select a source in the list first.','Backup Center');return}
 Start-Run $p @([string]$ovGrid.SelectedRows[0].Tag) 'Backup'
}catch{Show-Error $_;Update-Details}})
$btnVerify.Add_Click({try{
 $p=Get-SelectedProfile;if(-not $p){return}
 if([Windows.Forms.MessageBox]::Show('Check every backed-up file of this drive against its source? This reads everything again and can take much longer than a backup. Nothing is changed.','Backup Center','YesNo','Question') -ne 'Yes'){return}
 $ids=if($ovGrid.SelectedRows.Count -and [Windows.Forms.MessageBox]::Show('Only the selected source? (No = all sources)','Backup Center','YesNo','Question') -eq 'Yes'){@([string]$ovGrid.SelectedRows[0].Tag)}else{@()}
 Start-Run $p $ids 'Verify'
}catch{Show-Error $_;Update-Details}})
$btnStop.Add_Click({
 if(-not $script:current){return}
 if([Windows.Forms.MessageBox]::Show('Stop the running backup? Files already copied stay on the drive; the stopped step is recorded as not finished.','Backup Center','YesNo','Question') -ne 'Yes'){return}
 $script:queue.Clear();try{$script:current.Process.Kill($true)}catch{}
})
$btnOpen.Add_Click({try{
 $s=Get-OverviewSource;$d=Get-CenterDrive (Get-SelectedProfile).DestinationVolumeId
 if(-not $d.Connected){throw 'Connect the drive first.'}
 $path=$d.Letter+':\'+$s.MirrorFolder
 if(-not(Test-Path -LiteralPath $path)){throw "There is no plain copy of '$($s.Label)' yet ($path)."}
 Start-Process explorer.exe $path
}catch{Show-Error $_}})
$btnRestore.Add_Click({try{
 $s=Get-OverviewSource;if(-not (Get-CenterSourceKinds $s).Versioned){throw "'$($s.Label)' does not use versions. Its plain copy can be opened directly with Open plain copy folder."}
 Sync-CenterJob (Get-SelectedProfile) $s
 Start-Process (Get-Process -Id $PID).Path -ArgumentList @('-NoProfile','-WindowStyle','Hidden','-File',(Join-Path $PSScriptRoot 'Backup-History.ps1'),'-ConfigPath',$s.ConfigPath)
}catch{Show-Error $_}})
$btnKeys.Add_Click({try{
 $s=Get-OverviewSource;if(-not (Get-CenterSourceKinds $s).Versioned){throw "'$($s.Label)' does not use versions, so it has no password or recovery key."}
 Start-Process (Get-Process -Id $PID).Path -ArgumentList @('-NoProfile','-WindowStyle','Hidden','-File',(Join-Path $PSScriptRoot 'Backup-Security.ps1'),'-ConfigPath',$s.ConfigPath)
}catch{Show-Error $_}})
$btnRefresh.Add_Click({$script:data=Read-CenterProfiles;Update-ProfileList})
$btnSpeed.Add_Click({try{
 $p=Get-SelectedProfile;$d=Get-CenterDrive $p.DestinationVolumeId;if(-not $d.Connected){throw 'Connect the drive first.'}
 $speedResult.Text='Testing... this takes about half a minute. You can keep using the window.';$btnSpeed.Enabled=$false
 $args=@('-NoProfile','-File',(Join-Path $PSScriptRoot 'Set-BackupDestination.ps1'),'-DestinationDrive',$d.Letter,'-BenchmarkMiB','2048')
 if(@($p.Sources).Count){$args+=@('-ConfigPath',@($p.Sources)[0].ConfigPath)}
 $script:speedRun=Start-CenterStep ([pscustomobject]@{FilePath=(Get-Process -Id $PID).Path;Arguments=$args;Priority=$null}) $null
 $script:speedProfile=$p;$speedTimer.Start()
}catch{$speedResult.Text='Speed test failed: '+$_.Exception.Message;$btnSpeed.Enabled=$true}})
$speedTimer=[Windows.Forms.Timer]::new();$speedTimer.Interval=1000
$speedTimer.Add_Tick({
 if(-not $script:speedRun -or -not $script:speedRun.Process.HasExited){return}
 $speedTimer.Stop()
 try{
  $out=$script:speedRun.Out.GetAwaiter().GetResult()+$script:speedRun.Err.GetAwaiter().GetResult();$script:speedRun.Process.Dispose();$script:speedRun=$null
  $start=$out.IndexOf('{');$end=$out.IndexOf("`n}",$start)
  if($start -lt 0 -or $end -lt 0){throw ($out.Trim())}
  $r=$out.Substring($start,$end-$start+2)|ConvertFrom-Json
  $notes=@(@($r.Warnings)+@($r.Blockers)|Where-Object {$_}) -join ' '
  $script:speedProfile|Add-Member -NotePropertyName LastSpeedTest -NotePropertyValue ([pscustomobject]@{When=(Get-Date).ToString('o');Link=$r.Link;WriteMBps=$r.WriteMBps;ReadMBps=$r.ReadMBps;Notes=$notes}) -Force
  Save-CenterProfiles $script:data;Update-Details
 }catch{$speedResult.Text='Speed test failed: '+$_.Exception.Message}finally{$btnSpeed.Enabled=$true}
})
$loadPick.Add_SelectedIndexChanged({try{if(-not $script:loadingLoad -and $loadPick.SelectedItem){Set-ProfileLoad ([string]$loadPick.SelectedItem)}}catch{Show-Error $_}})
$loadLevel.Add_SelectedIndexChanged({try{if(-not $script:loadingLoad -and $loadLevel.SelectedItem){Set-ProfileLoad ([string]$loadLevel.SelectedItem)}}catch{Show-Error $_}})
$btnSaveLoad.Add_Click({try{
 $p=Get-SelectedProfile;if(-not $p){return}
 $p|Add-Member -NotePropertyName CustomLoad -NotePropertyValue ([pscustomobject]@{CpuThreads=[int]$customThreads.Value;MemoryMiB=[int]$customMemory.Value;CopyThreads=[int]$customFiles.Value;Priority=$(if([string]$customPriority.SelectedItem -eq 'Normal'){'Normal'}else{'BelowNormal'})}) -Force
 Set-ProfileLoad 'Custom'
 [void][Windows.Forms.MessageBox]::Show('Saved. '+(Format-Load (Get-CenterLoad $p)),'Backup Center')
}catch{Show-Error $_}})
$oldDays.Add_ValueChanged({try{
 if($script:loadingDays){return};$p=Get-SelectedProfile;if(-not $p){return}
 $p.ReminderDays=[int]$oldDays.Value;Save-CenterProfiles $script:data;Update-ProfileList $p.Id
}catch{Show-Error $_}})
$form.Add_FormClosing({param($s,$e)
 if($script:current -and [Windows.Forms.MessageBox]::Show('A backup is running. Stop it and close?','Backup Center','YesNo','Warning') -ne 'Yes'){$e.Cancel=$true;return}
 if($script:current){$script:queue.Clear();try{$script:current.Process.Kill($true)}catch{}}
})

$form.Add_Shown({
 Show-Page 0
 Update-ProfileList
 $stale=@(Get-CenterStaleProfiles)
 if($stale.Count -and -not $RenderPreview){$runStatus.Text='Needs a backup: '+(@($stale|ForEach-Object {$_.Profile.Name}) -join ', ')}
 if($RenderPreview){
  Show-Page $PreviewTab;[Windows.Forms.Application]::DoEvents()
  $bitmap=[Drawing.Bitmap]::new($form.Width,$form.Height);$form.DrawToBitmap($bitmap,[Drawing.Rectangle]::new(0,0,$form.Width,$form.Height));$bitmap.Save($RenderPreview);$bitmap.Dispose();$form.Close()
 }
})
if($AutoCloseSeconds -gt 0){$closer=[Windows.Forms.Timer]::new();$closer.Interval=$AutoCloseSeconds*1000;$closer.Add_Tick({$closer.Stop();$form.Close()});$closer.Start()}
[void]$form.ShowDialog()
