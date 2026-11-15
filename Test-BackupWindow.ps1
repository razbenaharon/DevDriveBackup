#Requires -Version 7.2
# The DevDriveBackup window itself, without a drive: it is opened for a moment on a disposable data
# folder (-DataRoot), draws each page into a picture (-RenderPreview) and closes. Checked: a damaged
# settings file is reported by name instead of the window silently not appearing; an unreadable look
# file does not stop it; every page draws without an error in an event handler; no explanation is cut
# off at the smallest window size; nothing is written outside the data folder. The profile's "drive"
# is an identity no volume has, so the window shows it as not connected and can start nothing on it.
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'DevDriveBackup.Data.psm1') -Force
# Windows cuts every window down to the largest size the screen allows. On a screen smaller than the
# window at full size the sizes measured below would be the screen's, not the window's, so say that
# instead of reporting misleading failures.
Add-Type -AssemblyName System.Windows.Forms
$largest=[Windows.Forms.SystemInformation]::MaxWindowTrackSize
if($largest.Width -lt 1216 -or $largest.Height -lt 839){throw "The window tests need a screen that allows a window of 1216 x 839; this one allows $($largest.Width) x $($largest.Height). Use a larger screen resolution."}
$script:failed=0
function Check([string]$Message,[scriptblock]$Test){
 $ok=$false;$why=''
 try{$ok=[bool](& $Test)}catch{$why=' ('+$_.Exception.Message+')'}
 if($ok){Write-Output "PASS $Message"}else{$script:failed++;Write-Output "FAIL $Message$why"}
}
$pwsh=(Get-Process -Id $PID).Path;$window=Join-Path $PSScriptRoot 'DevDriveBackup.ps1'
function Open-Window([string]$DataRoot,[string[]]$More){
 # Returns the exit code and everything the window process printed.
 # -Quiet: off the screen and never the active window, so the test does not interrupt work at this computer.
 $out=& $pwsh -NoProfile -File $window -DataRoot $DataRoot -Quiet @More 2>&1|Out-String
 [pscustomobject]@{Code=$LASTEXITCODE;Text=$out}
}
$root=Join-Path ([IO.Path]::GetTempPath()) ('backup-window-test-'+[guid]::NewGuid().ToString('N').Substring(0,10))
$realLog=Join-Path $env:LOCALAPPDATA 'DevDriveMirror\center\ui-errors.log'
$realLogBefore=if(Test-Path -LiteralPath $realLog){(Get-Item -LiteralPath $realLog).LastWriteTimeUtc}else{$null}
try{
 # --- A damaged settings file ---
 $bad=Join-Path $root 'bad';New-Item -ItemType Directory -Path $bad -Force|Out-Null
 foreach($c in ([ordered]@{'an empty settings file'='';'a settings file cut off half-way'='{"Version":1,"Profiles":[{"Id":"ab';'a settings file without profiles'='{}'}).GetEnumerator()){
  [IO.File]::WriteAllText((Join-Path $bad 'profiles.local.json'),$c.Value)
  $r=Open-Window $bad @('-AutoCloseSeconds','2')
  Check "$($c.Key): the window says which file cannot be read and what to do, and ends" {$r.Code -eq 2 -and $r.Text -like '*profiles.local.json*' -and $r.Text -like '*What you can do*'}
  Check "$($c.Key): the file is left exactly as it was" {[IO.File]::ReadAllText((Join-Path $bad 'profiles.local.json')) -ceq $c.Value}
 }

 # --- A real-looking data folder: one drive that is not plugged in, two sources, some history ---
 $data=Join-Path $root 'data';$src=Join-Path $root 'src'
 New-Item -ItemType Directory -Path $data,(Join-Path $src 'Projects\app'),(Join-Path $src 'Projects\docs'),(Join-Path $src 'Photos\2025') -Force|Out-Null
 [void](Set-CenterPaths $data)
 $d=Read-CenterProfiles;$p=New-CenterProfile $d 'Test drive with a rather long name to shorten' 'NO-SUCH-VOLUME' 'Test model' 931.5
 $a=Add-CenterSource -Data $d -ProfileId $p.Id -Path (Join-Path $src 'Projects') -Label 'Projects' -DefaultMode Both
 $b=Add-CenterSource -Data $d -ProfileId $p.Id -Path (Join-Path $src 'Photos') -Label 'Photos' -DefaultMode Mirror
 Save-CenterProfiles $d
 $n=Get-Date
 foreach($e in @(
  @{SourceId=$a.Id;Label='Projects';Kind='Mirror';Finished=$n.AddHours(-30).ToString('o');Minutes=4.2;Seconds=251.3;Success=$true;CopiedFiles=1203;CopiedBytes=[long]8.4e9}
  @{SourceId=$a.Id;Label='Projects';Kind='Versioned';Finished=$n.AddHours(-29).ToString('o');Minutes=6.5;Seconds=390.0;Success=$true;CopiedFiles=310;CopiedBytes=[long]1.1e9;ProcessedBytes=[long]42e9}
  @{SourceId=$b.Id;Label='Photos';Kind='Mirror';Finished=$n.AddHours(-28).ToUniversalTime().ToString('o');Minutes=12.0;Success=$true;CopiedFiles=88;CopiedBytes=[long]30e9}   # an older entry: no Seconds, UTC time
  @{SourceId=$b.Id;Label='Photos';Kind='Mirror';Finished=$n.AddHours(-2).ToString('o');Minutes=0.4;Seconds=24.9;Success=$false;Stopped=$true;Error='Stopped by you before it finished.'}
  @{SourceId=$a.Id;Label='Projects';Kind='MirrorCheck';Finished=$n.AddHours(-1).ToString('o');Minutes=3.0;Seconds=180.2;Success=$true;CheckedFiles=45210}
 )){$e.ProfileId=$p.Id;Add-CenterHistory ([pscustomobject]$e)}
 # Lines that are damaged in ways a crash or an edit can leave behind.
 [IO.File]::AppendAllText((Get-CenterPaths).History,('{"ProfileId":"'+$p.Id+'","SourceId":"'+$a.Id+'","Kind":"Mirror","Finished":"not a date","Success":true}'+"`n"+'{"ProfileId":"'+$p.Id+'","SourceId":"'+$a.Id+'","Kind":"Mirror","Finished":null,"Success":true}'+"`n"+'{"ProfileId":"'+$p.Id+'","Sou'))
 [IO.File]::WriteAllText((Get-CenterPaths).Appearance,'null')

 $pages='Overview','What to back up','Speed and load','Drive check','Look','Help'
 for($i=0;$i -lt $pages.Count;$i++){
  $png=Join-Path $root "page-$i.png"
  $r=Open-Window $data @('-RenderPreview',$png,'-PreviewTab',"$i")
  Check "page '$($pages[$i])' opens and is drawn (history with damaged lines, a look file holding null)" {$r.Code -eq 0 -and (Test-Path -LiteralPath $png) -and (Get-Item -LiteralPath $png).Length -gt 20000}
  $cut=@(Get-Content -LiteralPath ($png+'.layout.txt') -ErrorAction SilentlyContinue|Where-Object {$_})
  Check "page '$($pages[$i])': no explanation is cut off at the smallest window size$(if($cut.Count){': '+($cut -join '; ')})" {(Test-Path -LiteralPath ($png+'.layout.txt')) -and -not $cut.Count}
 }
 $png=Join-Path $root 'dark-large.png'
 $r=Open-Window $data @('-RenderPreview',$png,'-PreviewTab','2','-PreviewTheme','Dark','-PreviewWidth','1500','-PreviewHeight','1000')
 Check 'a larger window in the Dark theme opens and is drawn' {$r.Code -eq 0 -and (Test-Path -LiteralPath $png)}
 Check 'at a larger size the explanations still fit' {-not @(Get-Content -LiteralPath ($png+'.layout.txt')|Where-Object {$_}).Count}
 # The smallest window is 80% of the size it is drawn for: every page still draws and no explanation is cut off.
 for($i=0;$i -lt $pages.Count;$i++){
  $png=Join-Path $root "small-$i.png"
  $r=Open-Window $data @('-RenderPreview',$png,'-PreviewTab',"$i",'-PreviewWidth','960','-PreviewHeight','640')
  $cut=@(Get-Content -LiteralPath ($png+'.layout.txt') -ErrorAction SilentlyContinue|Where-Object {$_})
  Check "page '$($pages[$i])' at 80% (960 x 640) is drawn and no explanation is cut off$(if($cut.Count){': '+($cut -join '; ')})" {$r.Code -eq 0 -and (Test-Path -LiteralPath $png) -and (Get-Item -LiteralPath $png).Length -gt 15000 -and (Test-Path -LiteralPath ($png+'.layout.txt')) -and -not $cut.Count}
 }
 $r=Open-Window $data @('-AutoCloseSeconds','3')
 Check 'the window runs for a few seconds and closes cleanly' {$r.Code -eq 0}
 Check 'no error in an event handler was logged' {-not (Test-Path -LiteralPath (Join-Path (Get-CenterPaths).Logs 'ui-errors.log'))}
 Check 'the look file holding null was not written over' {[IO.File]::ReadAllText((Get-CenterPaths).Appearance) -ceq 'null'}
 Check 'the settings and the history were not changed by looking at them' {@((Read-CenterProfiles).Profiles[0].Sources).Count -eq 2 -and @(Get-CenterHistory).Count -eq 5}
 Check 'nothing was written to the real error log' {$now=if(Test-Path -LiteralPath $realLog){(Get-Item -LiteralPath $realLog).LastWriteTimeUtc}else{$null};$now -eq $realLogBefore}

 function Read-State([string]$Path){if(Test-Path -LiteralPath $Path){Get-Content -LiteralPath $Path -Raw|ConvertFrom-Json}else{throw "The window wrote no state to $Path"}}
 # --- The latest run failed: said beside the age and in the drive list; why the buttons are off ---
 # (The newest run of Photos above was stopped; the drive is not plugged in.)
 $st=Join-Path $root 'state-overview.json'
 $r=Open-Window $data @('-AutoCloseSeconds','2','-TestState',$st);$s=Read-State $st
 Check 'the overview warns that the latest run of a source was stopped, and where to see the details' {$r.Code -eq 0 -and $s.Warning -like '*Photos*stopped*Recent runs*' -and $s.WarningLevel -eq 'Failed' -and $s.GridTop -gt 206}
 Check 'the drive list marks it too, beside the age' {$s.Drives[0].When -like 'Backed up*Latest run was stopped' -and $s.Drives[0].Alert -eq 'Stopped'}
 Check 'a drive that is not connected: the buttons are off and the status line says why' {-not $s.Backup -and -not $s.BackupOne -and -not $s.Verify -and -not $s.Repair -and -not $s.Speed -and $s.Status -like 'Connect this drive*'}
 Check 'a run that was stopped shows as stopped in Recent runs' {@($s.Runs|Where-Object {$_ -like 'Plain copy: Stopped by you.*'}).Count -eq 1 -and @($s.Runs|Where-Object {$_ -like 'Copy check: OK.*'}).Count -eq 1}

 # --- The size the window opens with ---
 Check 'on a screen with room (and in a test that names no screen) the window has its full size' {$s.ClientWidth -eq 1200 -and $s.ClientHeight -eq 800 -and $s.Zoom -eq 1}
 $st=Join-Path $root 'state-size.json'
 $r=Open-Window $data @('-AutoCloseSeconds','2','-TestArea','1100x700','-TestState',$st);$s=Read-State $st
 Check "on a screen without room for it, the window opens at the largest size that fits ($($s.ClientWidth) x $($s.ClientHeight)), in proportion, with everything scaled" {$r.Code -eq 0 -and $s.ClientWidth -lt 1100 -and $s.ClientWidth -ge 960 -and $s.ClientHeight -lt 700 -and $s.ClientHeight -ge 640 -and [math]::Abs($s.ClientWidth/$s.ClientHeight-1.5) -lt 0.01 -and $s.Zoom -lt 1 -and $s.Zoom -ge 0.8 -and [math]::Abs($s.Zoom-$s.ClientWidth/1200) -lt 0.002}
 $r=Open-Window $data @('-AutoCloseSeconds','2','-TestArea','640x480','-TestState',$st);$s=Read-State $st
 Check 'on a screen smaller than that it opens at 80%, never below' {$r.Code -eq 0 -and $s.ClientWidth -eq 960 -and $s.ClientHeight -eq 640 -and $s.Zoom -eq 0.8}

 # --- The refresh that runs by itself keeps the user's place ---
 $st=Join-Path $root 'state-refresh.json'
 $r=Open-Window $data @('-AutoCloseSeconds','2','-TestAction','Refresh','-TestState',$st);$s=Read-State $st
 Check 'the test selected the second source and row and changed a folder without saving' {$r.Code -eq 0 -and $s.Log.Before.SourceIndex -eq 1 -and $s.Log.Before.ModesSource -eq $b.Id -and $s.Log.Before.Dirty -and $s.Log.Before.FirstMode -eq 'Skip' -and $s.Log.Before.OverviewRow -eq $b.Id}
 Check 'the automatic refresh ran and kept the selected source, the selected row and the unsaved change' {$s.Log.Refreshed -and $s.Log.AfterAuto.SourceIndex -eq 1 -and $s.Log.AfterAuto.ModesSource -eq $b.Id -and $s.Log.AfterAuto.Dirty -and $s.Log.AfterAuto.FirstMode -eq 'Skip' -and $s.Log.AfterAuto.OverviewRow -eq $b.Id}
 Check 'a full refresh (after an action) keeps them as well' {$s.Log.AfterFull.SourceIndex -eq 1 -and $s.Log.AfterFull.Dirty -and $s.Log.AfterFull.FirstMode -eq 'Skip' -and $s.Log.AfterFull.OverviewRow -eq $b.Id}
 Check 'the unsaved change was not written by any of it' {@((Read-CenterJob $b.ConfigPath).Choices|Where-Object {$_.Mode -eq 'Skip'}).Count -eq 0}

 # --- Links act on the selected source, never silently on the first ---
 $st=Join-Path $root 'state-links.json'
 $r=Open-Window $data @('-AutoCloseSeconds','2','-TestAction','Links','-TestState',$st);$s=Read-State $st
 Check 'two sources and none selected: nothing is acted on and the status line asks to select one' {$r.Code -eq 0 -and -not $s.Log.NoneSelected.Source -and $s.Log.NoneSelected.Status -like 'Select a source*'}
 Check 'with a row selected the links act on that source' {$s.Log.SecondSelected.Source -eq 'Photos' -and $s.Log.FirstSelected.Source -eq 'Projects'}

 # --- The questions, drawn without being shown ---
 foreach($q in 'Verify','Repair'){
  $png=Join-Path $root "question-$q.png"
  $r=Open-Window $data @('-RenderPreview',$png,'-PreviewDialog',$q)
  Check "the one question of '$q' is drawn, with named answers instead of Yes and No" {$r.Code -eq 0 -and (Test-Path -LiteralPath $png) -and (Get-Item -LiteralPath $png).Length -gt 5000}
 }

 # --- A drive that is connected (the system drive stands in for it; the window only looks) ---
 $live=Join-Path $root 'live';New-Item -ItemType Directory -Path $live,(Join-Path $src 'One\a'),(Join-Path $src 'Two\a') -Force|Out-Null
 [void](Set-CenterPaths $live)
 $d2=Read-CenterProfiles;$p2=New-CenterProfile $d2 'Connected' 'NO-SUCH-VOLUME-2' 'Test model' 100
 $one=Add-CenterSource -Data $d2 -ProfileId $p2.Id -Path (Join-Path $src 'One') -Label 'One' -DefaultMode Mirror
 $two=Add-CenterSource -Data $d2 -ProfileId $p2.Id -Path (Join-Path $src 'Two') -Label 'Two' -DefaultMode Mirror
 $empty=New-CenterProfile $d2 'Empty' 'NO-SUCH-VOLUME-3' 'Test model' 100
 $p2.DestinationVolumeId=(Get-Volume -DriveLetter $env:SystemDrive.Substring(0,1)).UniqueId
 Save-CenterProfiles $d2
 foreach($e in @(
  @{SourceId=$one.Id;Label='One';Kind='Mirror';Finished=$n.AddHours(-5).ToString('o');Seconds=20.0;Success=$true;CopiedFiles=3;CopiedBytes=3000}
  @{SourceId=$two.Id;Label='Two';Kind='Mirror';Finished=$n.AddHours(-4).ToString('o');Seconds=20.0;Success=$true;CopiedFiles=3;CopiedBytes=3000;Note='2 files were skipped because an Exclude pattern also matches their short Windows name: a, b.'}
  @{SourceId=$two.Id;Label='Two';Kind='MirrorCheck';Finished=$n.AddHours(-1).ToString('o');Seconds=30.0;Success=$false;Error='3 files differ from the source; see verify-differences.txt in C:\runs\x';Differences=3;CheckedFiles=40;Note='A note of a failed run.'}
 )){$e.ProfileId=$p2.Id;Add-CenterHistory ([pscustomobject]$e)}
 $st=Join-Path $root 'state-live.json'
 $r=Open-Window $live @('-AutoCloseSeconds','2','-TestAction','Links','-TestState',$st);$s=Read-State $st
 Check 'a connected drive with nothing in the way: the buttons are on and the status line gives no reason' {$r.Code -eq 0 -and $s.Backup -and $s.BackupOne -and $s.Verify -and $s.Status -notlike 'Connect*' -and $s.Status -notlike 'Nothing*'}
 Check 'a content check that found differing files is a milder line of its own; the drive list marks it' {$s.Warning -like '*content check of Two*3 files differ*Recent runs*' -and $s.WarningLevel -eq 'Check' -and $s.Drives[0].Alert -eq 'Check' -and $s.Drives[0].When -like '*Content check found a problem'}
 Check '"Repair differing files" is on for the source whose check found differences, and off for the other' {$s.Log.NoneSelected.Repair -and $s.Log.SecondSelected.Source -eq 'Two' -and $s.Log.SecondSelected.Repair -and $s.Log.FirstSelected.Source -eq 'One' -and -not $s.Log.FirstSelected.Repair}
 Check 'Recent runs show a run''s note, also of a run that failed' {@($s.Runs|Where-Object {$_ -like 'Plain copy: OK. 2 files were skipped*'}).Count -eq 1 -and @($s.Runs|Where-Object {$_ -like 'Copy check: Failed: 3 files differ*A note of a failed run.'}).Count -eq 1}
 Check 'a second drive without folders is listed as not backed up yet, without a warning' {$s.Drives.Count -eq 2 -and $s.Drives[1].When -eq 'No complete backup yet' -and -not $s.Drives[1].Alert}
 Add-CenterHistory ([pscustomobject]@{ProfileId=$p2.Id;SourceId=$two.Id;Label='Two';Kind='MirrorRepair';Finished=$n.AddMinutes(-5).ToString('o');Seconds=5.0;Success=$true;Note='Repaired 3 files; their earlier copies are in X:\Two-Mirror-recovery\now.'})
 $d2=Read-CenterProfiles;Remove-CenterSource $d2 $p2.Id $one.Id;Remove-CenterSource $d2 $p2.Id $two.Id;Save-CenterProfiles $d2
 $r=Open-Window $live @('-AutoCloseSeconds','2','-TestState',$st);$s=Read-State $st
 Check 'a connected drive with nothing selected for backup: the buttons are off and the status line says why' {$r.Code -eq 0 -and -not $s.Backup -and -not $s.Verify -and -not $s.Repair -and $s.Status -like 'Nothing is selected for backup*' -and $s.Speed}
 Check 'a repair is listed as a repair, with its note' {@($s.Runs|Where-Object {$_ -like 'Copy repair: OK. Repaired 3 files*'}).Count -eq 1 -and -not $s.Warning}

 # --- A damaged settings file with a good copy beside it ---
 $fix=Join-Path $root 'fix';New-Item -ItemType Directory -Path $fix -Force|Out-Null
 [void](Set-CenterPaths $fix)
 $d3=Read-CenterProfiles;[void](New-CenterProfile $d3 'Kept drive' 'NO-SUCH-VOLUME-4' 'Test model' 100);Save-CenterProfiles $d3
 $fixFile=(Get-CenterPaths).Profiles;$cut='{"Version":1,"Profiles":[{"Id":"ab';[IO.File]::WriteAllText($fixFile,$cut)
 $r=Open-Window $fix @('-AutoCloseSeconds','2')
 Check 'damaged settings with a good copy: restoring it is offered with its date; unanswered, nothing changes and the window ends' {$r.Code -eq 2 -and $r.Text -like '*profiles.local.json*' -and $r.Text -like '*restore the last good copy*' -and $r.Text -like ('*{0:yyyy}*' -f (Get-Date)) -and [IO.File]::ReadAllText($fixFile) -ceq $cut -and @(Get-ChildItem -LiteralPath $fix -Filter 'profiles.damaged-*').Count -eq 0}
 $png=Join-Path $root 'question-Settings.png'
 $r=Open-Window $fix @('-RenderPreview',$png,'-PreviewDialog','Settings')
 Check 'the question about restoring is drawn, and drawing it restores nothing' {$r.Code -eq 2 -and (Test-Path -LiteralPath $png) -and (Get-Item -LiteralPath $png).Length -gt 5000 -and [IO.File]::ReadAllText($fixFile) -ceq $cut}
 $st=Join-Path $root 'state-fix.json'
 $r=Open-Window $fix @('-AutoCloseSeconds','2','-Answer','Restore','-TestState',$st);$s=Read-State $st
 Check 'answered with Restore: the window opens with the settings of the good copy and says what it did' {$r.Code -eq 0 -and $s.Status -like '*were restored*kept as*profiles.damaged-*' -and $s.Drives.Count -eq 1 -and @((Read-CenterProfiles).Profiles)[0].Name -eq 'Kept drive'}
 Check 'the damaged file is kept beside the settings, unchanged' {$kept=@(Get-ChildItem -LiteralPath $fix -Filter 'profiles.damaged-*.local.json');$kept.Count -eq 1 -and [IO.File]::ReadAllText($kept[0].FullName) -ceq $cut}
 [void](Set-CenterPaths $data)

 # --- Keep versions: earlier settings, the box, and the question before the first clean-up ---
 $keep=Join-Path $root 'keep';New-Item -ItemType Directory -Path $keep -Force|Out-Null
 $keepFile=Join-Path $keep 'profiles.local.json'
 $earlier='{"Version":1,"Profiles":[{"Id":"k1","Name":"Earlier","DestinationVolumeId":"NO-SUCH-VOLUME-5","DriveModel":"Test model","DriveSizeGB":100,"ReminderDays":7,"Load":"Balanced","CustomLoad":null,"KeepDeleted":4,"VersionRetention":{"Days":7,"Weeks":4,"Months":3},"Created":"2026-01-01T10:00:00.0000000+02:00","Sources":[]}]}'
 [IO.File]::WriteAllText($keepFile,$earlier)
 $read={([IO.File]::ReadAllText($keepFile)|ConvertFrom-Json).Profiles[0]}
 $st=Join-Path $root 'state-keep.json'
 $r=Open-Window $keep @('-AutoCloseSeconds','2','-TestState',$st);$s=Read-State $st
 Check 'settings with the earlier days, weeks and months open as 10 newest and 6 months, shown on the overview' {$q=& $read;$r.Code -eq 0 -and $s.KeepVersions -eq '10 newest + 6 months' -and $q.VersionRetention.Last -eq 10 -and $q.VersionRetention.Months -eq 6 -and $q.RetentionConfirmed -eq $false -and $q.KeepDeleted -eq 4}
 Check 'the settings as they were are kept beside them, once' {$k=@(Get-ChildItem -LiteralPath $keep -Filter 'profiles.before-retention-*.local.json');$k.Count -eq 1 -and [IO.File]::ReadAllText($k[0].FullName) -ceq $earlier}
 $r=Open-Window $data @('-AutoCloseSeconds','2','-TestState',$st);$s=Read-State $st
 Check 'a drive that keeps every version says so on the overview' {$r.Code -eq 0 -and $s.KeepVersions -eq 'every version'}
 $before=[IO.File]::ReadAllText($keepFile)
 foreach($q in 'KeepVersions','RetentionPreview'){
  $png=Join-Path $root "question-$q.png"
  $r=Open-Window $keep @('-RenderPreview',$png,'-PreviewDialog',$q)
  Check "the box of '$q' is drawn, and drawing it changes nothing" {$r.Code -eq 0 -and (Test-Path -LiteralPath $png) -and (Get-Item -LiteralPath $png).Length -gt 5000 -and [IO.File]::ReadAllText($keepFile) -ceq $before}
 }
 $r=Open-Window $keep @('-AutoCloseSeconds','2','-PreviewDialog','RetentionPreview','-TestState',$st);$s=Read-State $st
 Check 'the question before the first clean-up, unanswered: nothing is approved' {$r.Code -eq 0 -and $s.Log.Retention.Count -eq 4 -and -not $s.Log.Retention.Approved -and (& $read).RetentionConfirmed -eq $false}
 $r=Open-Window $keep @('-AutoCloseSeconds','2','-PreviewDialog','RetentionPreview','-Answer','Not now','-TestState',$st);$s=Read-State $st
 Check 'answered with Not now: the settings stay exactly as they were' {$r.Code -eq 0 -and -not $s.Log.Retention.Approved -and [IO.File]::ReadAllText($keepFile) -ceq $before}
 $r=Open-Window $keep @('-AutoCloseSeconds','2','-PreviewDialog','RetentionPreview','-Answer','Approve','-TestState',$st);$s=Read-State $st
 Check 'answered with Approve clean-up: exactly the list that was shown is saved, the profile is not handed over to the rule yet, and the window says what the next backup does' {$q=& $read;$r.Code -eq 0 -and $s.Log.Retention.Approved -and $q.RetentionConfirmed -eq $false -and @($q.RetentionApproved.Versions[0].Ids).Count -eq 2 -and @($q.RetentionApproved.RecoveryFolders[0].Names).Count -eq 2 -and $q.RetentionApproved.Last -eq 10 -and $q.RetentionApproved.KeepDeleted -eq 4 -and $s.Status -like '*Nothing was deleted now*next backup deletes what was listed and nothing else*' -and $q.VersionRetention.Last -eq 10}
 $r=Open-Window $keep @('-AutoCloseSeconds','2','-PreviewDialog','KeepVersions','-Answer','Save','-TestState',$st);$s=Read-State $st
 Check 'saving the Keep versions box with the same numbers keeps the approved list' {$q=& $read;$r.Code -eq 0 -and $q.RetentionConfirmed -eq $false -and @($q.RetentionApproved.Versions[0].Ids).Count -eq 2 -and $s.Status -like '*10 newest + 6 months*The clean-up you approved runs with the next backup*'}
 $r=Open-Window $keep @('-AutoCloseSeconds','2','-PreviewDialog','KeepVersions','-Answer','Save 5 3','-TestState',$st);$s=Read-State $st
 Check 'other numbers are saved, shown on the overview, the approved list is dropped and their first clean-up is shown for approval again' {$q=& $read;$r.Code -eq 0 -and $q.VersionRetention.Last -eq 5 -and $q.VersionRetention.Months -eq 3 -and $q.RetentionConfirmed -eq $false -and -not $q.PSObject.Properties['RetentionApproved'] -and $s.KeepVersions -eq '5 newest + 3 months' -and $s.Status -like '*5 newest + 3 months*first clean-up will be shown to you for approval*'}
 $r=Open-Window $keep @('-AutoCloseSeconds','2','-PreviewDialog','KeepVersions','-Answer','Save 0 0','-TestState',$st);$s=Read-State $st
 Check 'both numbers 0 keeps every version' {$q=& $read;$r.Code -eq 0 -and $q.VersionRetention.Last -eq 0 -and $q.VersionRetention.Months -eq 0 -and $s.KeepVersions -eq 'every version' -and $s.Status -like '*every version is kept*'}
 Check 'none of it made a second copy of the earlier settings or logged an error' {@(Get-ChildItem -LiteralPath $keep -Filter 'profiles.before-retention-*').Count -eq 1 -and -not (Test-Path -LiteralPath (Join-Path $keep 'logs\ui-errors.log'))}

 # --- After a run: the approved clean-up, a file always in use, a versions folder that is gone ---
 # The entries of a finished run are handed to the window from a file (-TestAction AfterRun); the drive
 # is not plugged in, so nothing can run. Photos2 uses the plain copy only, Projects2 both.
 $after=Join-Path $root 'after';New-Item -ItemType Directory -Path $after,(Join-Path $src 'Photos2\a'),(Join-Path $src 'Projects2\a') -Force|Out-Null
 [void](Set-CenterPaths $after)
 $d4=Read-CenterProfiles;$p4=New-CenterProfile $d4 'After' 'NO-SUCH-VOLUME-6' 'Test model' 100
 $ph=Add-CenterSource -Data $d4 -ProfileId $p4.Id -Path (Join-Path $src 'Photos2') -Label 'Photos2' -DefaultMode Mirror
 $pr=Add-CenterSource -Data $d4 -ProfileId $p4.Id -Path (Join-Path $src 'Projects2') -Label 'Projects2' -DefaultMode Both
 Set-CenterVersionRetention $p4 10 6;Set-CenterKeepDeleted $p4 3;Save-CenterProfiles $d4
 $read4={@((Read-CenterProfiles).Profiles)[0]}
 $part={param($sid,$kind,$more=@{})$h=[ordered]@{ProfileId=$p4.Id;SourceId=$sid;Label=$(if($sid -eq $ph.Id){'Photos2'}else{'Projects2'});Kind=$kind;Success=$true;Stopped=$false;RetentionPlanFailed=$false};foreach($k in $more.Keys){$h[$k]=$more[$k]};[pscustomobject]$h}
 $runFile={param($name,$entries)$f=Join-Path $root $name;[IO.File]::WriteAllText($f,(ConvertTo-Json @($entries) -Depth 8));$f}
 $st=Join-Path $root 'state-after.json'
 $listed=& $runFile 'run-listed.json' @((& $part $ph.Id 'Mirror'),(& $part $pr.Id 'Mirror' @{RetentionPreview=@{Versions=@();RecoveryFolders=@('20260102-101500')}}),(& $part $pr.Id 'Versioned' @{RetentionPreview=@{Versions=@(@{Id='aaaa1111';Time='2026-03-01T10:15:00';Partial=$false;Host='PC';Paths=@('E:\P')});RecoveryFolders=@()}}))
 $r=Open-Window $after @('-AutoCloseSeconds','2','-TestAction','AfterRun','-TestPath',$listed,'-Answer','Approve','-TestState',$st);$s=Read-State $st
 Check 'after a backup that listed what it would delete, Approve clean-up stores that list and deletes nothing' {$q=& $read4;$r.Code -eq 0 -and $q.RetentionConfirmed -eq $false -and $q.RetentionApproved.Versions[0].SourceId -eq $pr.Id -and (@($q.RetentionApproved.Versions[0].Ids) -join ',') -eq 'aaaa1111' -and (@($q.RetentionApproved.RecoveryFolders[0].Names) -join ',') -eq '20260102-101500' -and $s.Log.AfterRun.Status -like 'Approved. Nothing was deleted now*'}
 $approvedRun=@((& $part $ph.Id 'Mirror' @{RetentionPhase='Approved'}),(& $part $pr.Id 'Mirror' @{RetentionPhase='Approved'}),(& $part $pr.Id 'Versioned' @{RetentionPhase='Approved'}))
 $r=Open-Window $after @('-AutoCloseSeconds','2','-TestAction','AfterRun','-TestPath',(& $runFile 'run-one.json' @($approvedRun[0])),'-Answer','Approve','-TestState',$st);$s=Read-State $st
 Check 'a backup of one source during this phase leaves the approved list as it is and says that it goes on with the next backup' {$q=& $read4;$r.Code -eq 0 -and $q.RetentionConfirmed -eq $false -and (@($q.RetentionApproved.Versions[0].Ids) -join ',') -eq 'aaaa1111' -and $s.Log.AfterRun.Status -like '*not finished*next backup of all sources*'}
 $r=Open-Window $after @('-AutoCloseSeconds','2','-TestAction','AfterRun','-TestPath',(& $runFile 'run-whole.json' $approvedRun),'-TestState',$st);$s=Read-State $st
 Check 'after a whole backup that carried the approved list, the clean-up is handed over to the rule and the list is gone' {$q=& $read4;$r.Code -eq 0 -and $q.RetentionConfirmed -eq $true -and -not $q.PSObject.Properties['RetentionApproved'] -and $s.Log.AfterRun.Status -like '*was carried out*runs by itself after every backup*'}
 # A file in use: three failed plain copies of Photos2 in a row name it.
 $locked={param($mins)Add-CenterHistory ([pscustomobject]@{ProfileId=$p4.Id;SourceId=$ph.Id;Label='Photos2';Kind='Mirror';Finished=$n.AddMinutes($mins).ToString('o');Seconds=5.0;Success=$false;Stopped=$false;Error='1 files could not be copied; see copy-errors.txt in C:\runs\x';LockedFiles=@('cache\db.lock')})}
 foreach($m in -30,-20,-10){& $locked $m}
 $excludes={@((Read-CenterJob $ph.ConfigPath).Exclude)}
 $before=(& $excludes).Count;$lastRun=& $runFile 'run-locked.json' @(& $part $ph.Id 'Mirror' @{Success=$false})
 $r=Open-Window $after @('-AutoCloseSeconds','2','-TestAction','AfterRun','-TestPath',$lastRun,'-TestState',$st);$s=Read-State $st
 Check 'a file in use in three backups in a row, answered with Not now: nothing is excluded, and the answer is remembered with the source' {$q=@((& $read4).Sources|Where-Object {$_.Id -eq $ph.Id})[0];$r.Code -eq 0 -and (& $excludes).Count -eq $before -and @($q.LockedAsked).Count -eq 1 -and $q.LockedAsked[0].Path -eq 'cache\db.lock'}
 $r=Open-Window $after @('-AutoCloseSeconds','2','-TestAction','AfterRun','-TestPath',$lastRun,'-Answer','Exclude','-TestState',$st)
 Check 'the same three backups do not ask again: also an Exclude answer has nothing to act on' {$r.Code -eq 0 -and (& $excludes).Count -eq $before}
 $since=((Get-Date)-$n).TotalMinutes;foreach($m in 1,2,3){& $locked ($since+$m)}   # three further backups with the file in use, later than the answer above
 $r=Open-Window $after @('-AutoCloseSeconds','2','-TestAction','AfterRun','-TestPath',$lastRun,'-Answer','Exclude','-TestState',$st);$s=Read-State $st
 Check 'after three further such backups it is asked again; answered with Exclude from the backup, the file is added to the source''s Exclude list once' {$r.Code -eq 0 -and (& $excludes).Count -eq $before+1 -and (& $excludes)[-1] -eq 'cache\db.lock' -and $s.Log.AfterRun.Status -like 'Excluded from the backup of Photos2*cache\db.lock*'}
 Check 'the window lists it as not backed up, and Recent runs note the change' {$s.SourceInfo -like '*Not backed up (excluded): cache\db.lock*' -and @($s.Runs|Where-Object {$_ -like 'Change: Excluded from the backup at your request*cache\db.lock*not backed up.'}).Count -eq 1}
 # The versions folder is gone.
 $gone=& $runFile 'run-gone.json' @((& $part $pr.Id 'Versioned' @{Success=$false;RepositoryMissing=$true;Error='The versions folder was not found.'}))
 $r=Open-Window $after @('-AutoCloseSeconds','2','-TestAction','AfterRun','-TestPath',$gone,'-TestState',$st);$s=Read-State $st
 Check 'a versions folder that was not found, answered with Not now: no new folder is started' {$r.Code -eq 0 -and @($s.Log.NewVersions).Count -eq 0 -and $r.Text -notlike '*not connected*'}
 $r=Open-Window $after @('-AutoCloseSeconds','2','-TestAction','AfterRun','-TestPath',$gone,'-Answer','Create','-TestState',$st);$s=Read-State $st
 Check 'answered with Create a new, empty versions folder: a versioned backup of that source is started (here the drive is not connected, which it says)' {$r.Code -eq 0 -and (@($s.Log.NewVersions) -join ',') -eq $pr.Id -and $r.Text -like '*not connected*'}
 Check 'none of these questions logged an error in an event handler' {-not (Test-Path -LiteralPath (Join-Path $after 'logs\ui-errors.log'))}

 # --- Adding a folder that was backed up to this drive before: asked first ---
 $add=Join-Path $root 'add';New-Item -ItemType Directory -Path $add,(Join-Path $src 'Music\a') -Force|Out-Null
 [void](Set-CenterPaths $add)
 $d5=Read-CenterProfiles;$p5=New-CenterProfile $d5 'Add' 'NO-SUCH-VOLUME-7' 'Test model' 100
 $mu=Add-CenterSource -Data $d5 -ProfileId $p5.Id -Path (Join-Path $src 'Music') -Label 'Music' -DefaultMode Both
 Remove-CenterSource $d5 $p5.Id $mu.Id;Save-CenterProfiles $d5
 $oldJob=[IO.File]::ReadAllText($mu.ConfigPath);$read5={@((Read-CenterProfiles).Profiles)[0]}
 $st=Join-Path $root 'state-add.json'
 $r=Open-Window $add @('-AutoCloseSeconds','2','-TestAction','AddFolder','-TestPath',(Join-Path $src 'Music'),'-TestState',$st);$s=Read-State $st
 Check 'a folder that was backed up to this drive before is asked about first; unanswered, it is not added' {$r.Code -eq 0 -and @((& $read5).Sources).Count -eq 0 -and $s.Log.Added.Status -eq 'The folder was not added.' -and -not $s.Log.Added.Source}
 $r=Open-Window $add @('-AutoCloseSeconds','2','-TestAction','AddFolder','-TestPath',(Join-Path $src 'Music'),'-Answer','Start fresh','-TestState',$st);$s=Read-State $st
 Check 'Start fresh: added with new folder names; the earlier folders are named and the earlier settings file is untouched' {$q=@((& $read5).Sources);$q.Count -eq 1 -and $q[0].ConfigPath -ne $mu.ConfigPath -and $q[0].MirrorFolder -ine 'Music-Mirror' -and [string](Read-CenterJob $q[0].ConfigPath).RepositoryFolder -ine 'Music-Versions' -and (Read-CenterJob $q[0].ConfigPath).DefaultMode -eq 'Mirror' -and $s.Log.Added.Status -like '*as a new backup*stay on the drive untouched: \Music-Mirror and \Music-Versions*' -and [IO.File]::ReadAllText($mu.ConfigPath) -ceq $oldJob}
 # Recovery folders piled up beside its plain copy, and the drive has no keep rule: suggested, nothing more.
 $fresh=@((& $read5).Sources)[0]
 Add-CenterHistory ([pscustomobject]@{ProfileId=$p5.Id;SourceId=$fresh.Id;Label='Music';Kind='Mirror';Finished=$n.AddHours(-1).ToString('o');Seconds=20.0;Success=$true;CopiedFiles=3;CopiedBytes=3000;RecoveryFolderCount=14})
 $r=Open-Window $add @('-AutoCloseSeconds','2','-TestState',$st);$s=Read-State $st
 Check 'more than 10 recovery folders without a keep rule: the overview suggests one, quietly, and changes nothing' {$r.Code -eq 0 -and $s.Warning -eq "14 recovery folders have piled up beside the plain copy of Music. Set 'Keep deleted in' to keep only the newest ones." -and $s.WarningLevel -eq 'Advice' -and -not $s.Drives[0].Alert -and -not (& $read5).PSObject.Properties['KeepDeleted']}
 $d5=Read-CenterProfiles;Remove-CenterSource $d5 $p5.Id $fresh.Id;Save-CenterProfiles $d5
 $r=Open-Window $add @('-AutoCloseSeconds','2','-TestAction','AddFolder','-TestPath',(Join-Path $src 'Music'),'-Answer','Use the earlier','-TestState',$st);$s=Read-State $st
 Check 'Use the earlier settings: its settings file and folders are taken up again, and the window says so' {$q=@((& $read5).Sources);$q.Count -eq 1 -and $q[0].ConfigPath -in $mu.ConfigPath,$fresh.ConfigPath -and $s.Log.Added.Status -like '*with its earlier settings*is continued*'}
 Check 'adding folders logged no error in an event handler' {-not (Test-Path -LiteralPath (Join-Path $add 'logs\ui-errors.log'))}

 # --- The settings file is damaged or changed on disk while the window is open ---
 $live2=Join-Path $root 'live2';New-Item -ItemType Directory -Path $live2 -Force|Out-Null
 [void](Set-CenterPaths $live2)
 $d6=Read-CenterProfiles;[void](New-CenterProfile $d6 'Open drive' 'NO-SUCH-VOLUME-8' 'Test model' 100);Save-CenterProfiles $d6
 $file6=(Get-CenterPaths).Profiles;$good6=Join-Path $live2 'profiles.lastgood.local.json'
 $same6={[Linq.Enumerable]::SequenceEqual([byte[]][IO.File]::ReadAllBytes($good6),[byte[]][IO.File]::ReadAllBytes($file6))}
 $cutFile=Join-Path $root 'cut.json';[IO.File]::WriteAllText($cutFile,$cut)
 $st=Join-Path $root 'state-save.json'
 $r=Open-Window $live2 @('-AutoCloseSeconds','2','-TestAction','SaveAfter','-TestPath',$cutFile,'-TestState',$st);$s=Read-State $st
 Check 'a settings file damaged after the window read it is not written over: it is kept beside the settings, and the status line says so' {$k=@(Get-ChildItem -LiteralPath $live2 -Filter 'profiles.damaged-*.local.json');$r.Code -eq 0 -and $k.Count -eq 1 -and [IO.File]::ReadAllText($k[0].FullName) -ceq $cut -and $s.Status -like 'The settings file had been damaged outside DevDriveBackup; it was kept as profiles.damaged-*.local.json and the settings were saved again.'}
 Check 'the window''s settings were saved as the new file, and the last good copy is that file' {$q=@((Read-CenterProfiles).Profiles)[0];$q.Name -eq 'Open drive' -and $q.ReminderDays -eq 8 -and (& $same6)}
 $otherFile=Join-Path $root 'other.json';[IO.File]::WriteAllText($otherFile,'{"Version":1,"Profiles":[{"Id":"zz","Name":"Edited elsewhere","DestinationVolumeId":"VOL-OTHER","ReminderDays":7,"Sources":[]}]}')
 $r=Open-Window $live2 @('-AutoCloseSeconds','2','-TestAction','SaveAfter','-TestPath',$otherFile,'-TestState',$st);$s=Read-State $st
 Check 'a settings file changed elsewhere while the window was open is kept aside too, and the status line names the copy' {$k=@(Get-ChildItem -LiteralPath $live2 -Filter 'profiles.changed-*.local.json');$r.Code -eq 0 -and $k.Count -eq 1 -and [IO.File]::ReadAllText($k[0].FullName) -ceq [IO.File]::ReadAllText($otherFile) -and $s.Status -like 'The settings file had been changed outside DevDriveBackup; that version was kept as profiles.changed-*' -and @((Read-CenterProfiles).Profiles)[0].ReminderDays -eq 9 -and (& $same6)}
 [void](Set-CenterPaths $data)

 # --- One window only ---
 function Start-Window([string]$DataRoot,[string[]]$More){
  # Started without waiting; .Text is read after it has ended.
  $psi=[Diagnostics.ProcessStartInfo]::new($pwsh);foreach($a in @('-NoProfile','-File',$window,'-DataRoot',$DataRoot,'-Quiet')+$More){[void]$psi.ArgumentList.Add($a)}
  $psi.UseShellExecute=$false;$psi.CreateNoWindow=$true;$psi.RedirectStandardOutput=$true;$psi.RedirectStandardError=$true
  $p=[Diagnostics.Process]::Start($psi);[pscustomobject]@{Process=$p;Out=$p.StandardOutput.ReadToEndAsync();Err=$p.StandardError.ReadToEndAsync()}
 }
 $first=Start-Window $data @('-AutoCloseSeconds','14')
 Start-Sleep -Seconds 5
 $sw=[Diagnostics.Stopwatch]::StartNew();$second=Open-Window $data @('-AutoCloseSeconds','10');$took=$sw.Elapsed.TotalSeconds
 $other=Open-Window $live @('-AutoCloseSeconds','1')
 [void]$first.Process.WaitForExit(60000);$firstText=$first.Out.Result+$first.Err.Result
 Check "a second start on the same settings ends quietly at once ($([math]::Round($took,1)) s) and says the window is already open" {$second.Code -eq 0 -and $second.Text -like '*already open*' -and $took -lt 8}
 Check 'the first window was asked to come to the front, and kept running to its own end' {$first.Process.ExitCode -eq 0 -and $firstText -like '*asked to come to the front*'}
 Check 'a window on other settings (a test beside the real window) is neither stopped nor stops the first' {$other.Code -eq 0 -and $other.Text -notlike '*already open*'}
 $again=Open-Window $data @('-AutoCloseSeconds','1')
 Check 'after the first window has closed, the program starts normally again' {$again.Code -eq 0 -and $again.Text -notlike '*already open*'}
 Check 'none of these windows logged an error in an event handler' {-not @($data,$live,$fix|Where-Object {Test-Path -LiteralPath (Join-Path $_ 'logs\ui-errors.log')}).Count}

 # --- The taskbar helper ---
 Add-Type -Path (Join-Path $PSScriptRoot 'Backup.Taskbar.cs')
 $pv=[CenterTaskbar].GetNestedType('PropVariant',[Reflection.BindingFlags]'NonPublic')
 Check 'the value handed to Windows for the taskbar is as large as Windows reads (24 bytes on 64-bit)' {[Runtime.InteropServices.Marshal]::SizeOf([type]$pv) -ge $(if([IntPtr]::Size -eq 8){24}else{16})}
}finally{if(Test-Path -LiteralPath $root){[IO.Directory]::Delete($root,$true)}}
if($script:failed){Write-Output "$($script:failed) window tests FAILED.";exit 1}
Write-Output 'All window tests passed.'
