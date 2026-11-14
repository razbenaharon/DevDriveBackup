#Requires -Version 7.2
# The DevDriveBackup window itself, without a drive: it is opened for a moment on a disposable data
# folder (-DataRoot), draws each page into a picture (-RenderPreview) and closes. Checked: a damaged
# settings file is reported by name instead of the window silently not appearing; an unreadable look
# file does not stop it; every page draws without an error in an event handler; no explanation is cut
# off at the smallest window size; nothing is written outside the data folder. The profile's "drive"
# is an identity no volume has, so the window shows it as not connected and can start nothing on it.
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'DevDriveBackup.Data.psm1') -Force
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
