#Requires -Version 7.2
# DevDriveBackup data layer without a drive: age and freshness boundaries, damaged settings and history,
# load levels on small computers, names of copy and versions folders, restoring a removed source, and how
# a finished, failed or stopped tool run is recorded. Everything is kept in a disposable folder; the
# profile's "drive" is an identity no volume has. Fake tools (short PowerShell commands) stand in for
# the real ones.
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'DevDriveBackup.Data.psm1') -Force
$script:failed=0
function Check([string]$Message,[scriptblock]$Test){
 $ok=$false;$why=''
 try{$ok=[bool](& $Test)}catch{$why=' ('+$_.Exception.Message+')'}
 if($ok){Write-Output "PASS $Message"}else{$script:failed++;Write-Output "FAIL $Message$why"}
}
function Throws([scriptblock]$Block,[string]$Like){try{[void](& $Block);$false}catch{$_.Exception.Message -like $Like}}

$root=Join-Path ([IO.Path]::GetTempPath()) ('backup-data-test-'+[guid]::NewGuid().ToString('N').Substring(0,10))
$data=Join-Path $root 'data';$src=Join-Path $root 'src'
New-Item -ItemType Directory -Path $data,(Join-Path $src 'A\sub'),(Join-Path $src 'B\sub'),(Join-Path $src 'C\sub'),(Join-Path $src 'A2') -Force|Out-Null
[void](Set-CenterPaths $data)
try{
 $now=[datetime]'2026-11-12T12:00:00'
 # --- Ages and freshness ---
 Check 'under 24 hours is Fresh, exactly 24 hours is OK' {(Get-FreshnessState $now.AddSeconds(-86399) 7 $now) -eq 'Fresh' -and (Get-FreshnessState $now.AddHours(-24) 7 $now) -eq 'OK'}
 Check 'one second before the N days is OK, exactly N days is Stale' {(Get-FreshnessState $now.AddDays(-7).AddSeconds(1) 7 $now) -eq 'OK' -and (Get-FreshnessState $now.AddDays(-7) 7 $now) -eq 'Stale'}
 Check 'with 1 day, 23 hours is Fresh and 25 hours is Stale' {(Get-FreshnessState $now.AddHours(-23) 1 $now) -eq 'Fresh' -and (Get-FreshnessState $now.AddHours(-25) 1 $now) -eq 'Stale'}
 Check 'no backup is Never; a time that cannot be read is Never, not an error' {(Get-FreshnessState $null 7 $now) -eq 'Never' -and (Get-FreshnessState 'yesterday-ish' 7 $now) -eq 'Never'}
 Check 'ages: just now below 2 minutes, then whole minutes rounded down' {(Format-CenterAge $now.AddSeconds(-119) $now) -eq 'just now' -and (Format-CenterAge $now.AddSeconds(-210) $now) -eq '3 minutes ago' -and (Format-CenterAge $now.AddSeconds(-3576) $now) -eq '59 minutes ago'}
 Check 'ages: hours up to 48, then days' {(Format-CenterAge $now.AddMinutes(-60) $now) -eq '1 hour ago' -and (Format-CenterAge $now.AddMinutes(-119) $now) -eq '1 hour ago' -and (Format-CenterAge $now.AddMinutes(-2879) $now) -eq '47 hours ago' -and (Format-CenterAge $now.AddMinutes(-2880) $now) -eq '2 days ago'}
 Check 'a time in the future (clock set back) reads as just now' {(Format-CenterAge $now.AddDays(2) $now) -eq 'just now' -and (Get-FreshnessState $now.AddDays(2) 7 $now) -eq 'Fresh'}
 Check 'a time that cannot be read has no age instead of an error' {(Format-CenterAge 'not a date' $now) -eq 'unknown' -and (Format-CenterAge $null $now) -eq 'never'}
 $utcHourAgo=[datetime]::UtcNow.AddHours(-1).ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ')
 Check 'a UTC time ("...Z") is aged like a local one' {$t=ConvertTo-CenterTime (('{"T":"'+$utcHourAgo+'"}'|ConvertFrom-Json).T);[math]::Abs(((Get-Date)-$t).TotalMinutes-60) -lt 1 -and (Format-CenterAge (('{"T":"'+$utcHourAgo+'"}'|ConvertFrom-Json).T)) -eq '1 hour ago'}
 Check 'a time with another offset (written in summer time) is the same moment' {$t=ConvertTo-CenterTime '2026-07-01T12:00:00.0000000+03:00';$t.ToUniversalTime() -eq [datetime]::new(2026,7,1,9,0,0,[DateTimeKind]::Utc)}
 Check 'elapsed time is rounded down: 100 seconds is 1 min 40 s' {(Format-CenterElapsed ([timespan]::FromSeconds(100))) -eq '1 min 40 s' -and (Format-CenterElapsed ([timespan]::FromSeconds(59.9))) -eq '0 min 59 s' -and (Format-CenterElapsed ([timespan]::FromSeconds(3725))) -eq '62 min 5 s'}

 # --- History ---
 $hp=(Get-CenterPaths).History;New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($hp)) -Force|Out-Null
 [IO.File]::WriteAllText($hp,(@(
  '{"SourceId":"s","Kind":"Mirror","Finished":"2026-11-12T10:00:00.0000000+02:00","Success":true}'
  '{broken','[1,2]','"text"'
  '{"SourceId":"s","Kind":"Mirror","Finished":"not a date","Success":true}'
  '{"SourceId":"s","Kind":"Mirror","Finished":null,"Success":true}'
  '{"SourceId":"s","Kind":"Mirror","Fin') -join "`n"))
 Check 'damaged lines and lines without a readable finish time are skipped' {@(Get-CenterHistory).Count -eq 1}
 Check 'the last success is found in a damaged history' {(Get-LastSuccess @(Get-CenterHistory) 's' 'Mirror') -is [datetime]}
 Check 'an entry with an unreadable time handed in directly is skipped, not an error' {$good=$now.AddHours(-3);(Get-LastSuccess @([pscustomobject]@{SourceId='s';Kind='Mirror';Success=$true;Finished='yesterday-ish'},[pscustomobject]@{SourceId='s';Kind='Mirror';Success=$true;Finished=$null},[pscustomobject]@{SourceId='s';Kind='Mirror';Success=$true;Finished=$good.ToString('o')}) 's' 'Mirror') -eq $good}
 Check 'failed runs, content checks and other sources do not count as a backup' {
  $h=@([pscustomobject]@{SourceId='s';Kind='Mirror';Success=$false;Finished=$now.AddHours(-1).ToString('o')},[pscustomobject]@{SourceId='s';Kind='MirrorCheck';Success=$true;Finished=$now.AddHours(-2).ToString('o')},
   [pscustomobject]@{SourceId='s';Kind='Mirror';Success=$true;Finished=$now.AddDays(-9).ToString('o')},[pscustomobject]@{SourceId='other';Kind='Mirror';Success=$true;Finished=$now.AddHours(-3).ToString('o')})
  (Get-LastSuccess $h 's' 'Mirror') -eq $now.AddDays(-9)}
 Remove-Item -LiteralPath $hp

 # --- Run numbers shown in "Recent runs" ---
 Check 'speed uses the exact seconds: 600 MiB in 3.1 s is 203 MB/s' {(Get-CenterRunSpeed ([pscustomobject]@{Kind='Mirror';CopiedBytes=629145600;Seconds=3.1;Minutes=0.1})) -eq '203 MB/s'}
 Check 'an old entry with only rounded minutes shows no speed for a short run' {(Get-CenterRunSpeed ([pscustomobject]@{Kind='Mirror';CopiedBytes=629145600;Minutes=0.1})) -eq ''}
 Check 'an old entry of a long run still shows its speed' {(Get-CenterRunSpeed ([pscustomobject]@{Kind='Mirror';CopiedBytes=[long]50e9;Minutes=60})) -eq '14 MB/s'}
 Check 'no speed for small amounts, checks, or versions without the amount read' {(Get-CenterRunSpeed ([pscustomobject]@{Kind='Mirror';CopiedBytes=5e6;Seconds=60})) -eq '' -and (Get-CenterRunSpeed ([pscustomobject]@{Kind='MirrorCheck';CopiedBytes=[long]9e9;Seconds=60})) -eq '' -and (Get-CenterRunSpeed ([pscustomobject]@{Kind='Versioned';CopiedBytes=[long]9e9;Seconds=60})) -eq '' -and (Get-CenterRunSpeed ([pscustomobject]@{Kind='Mirror';CopiedBytes=$null;Seconds=60})) -eq ''}
 Check 'versions show the speed of what was read' {(Get-CenterRunSpeed ([pscustomobject]@{Kind='Versioned';CopiedBytes=1000;ProcessedBytes=[long]6e9;Seconds=60})) -eq '100 MB/s'}
 Check 'duration: exact for new entries, minutes for old ones' {(Format-CenterRunDuration ([pscustomobject]@{Seconds=100.4;Minutes=1.7})) -eq '1 min 40 s' -and (Format-CenterRunDuration ([pscustomobject]@{Minutes=1.7})) -eq '1.7 min' -and (Format-CenterRunDuration ([pscustomobject]@{Seconds=24.9;Minutes=0.4})) -eq '24 s'}

 # --- Load levels ---
 foreach($hw in @(@(1,4),@(2,4),@(2,8),@(3,8),@(4,3.9),@(12,40),@(256,1024),@(8,0.5))){
  $l=Get-CenterLoadPresets ([pscustomobject]@{Threads=$hw[0];MemoryGB=$hw[1]});$t=@($l.Values|ForEach-Object {$_.CpuThreads});$m=@($l.Values|ForEach-Object {$_.MemoryMiB})
  Check "load levels never shrink from Light to Maximum on $($hw[0]) threads, $($hw[1]) GB ($($t -join '/') threads)" {$t[0] -ge 1 -and $t[0] -le $t[1] -and $t[1] -le $t[2] -and $t[2] -le $t[3] -and $t[3] -le $hw[0] -and $m[0] -ge 512 -and $m[0] -le $m[1] -and $m[1] -le $m[2] -and $m[2] -le $m[3] -and $m[3] -le 8192}
 }
 $l=Get-CenterLoadPresets ([pscustomobject]@{Threads=12;MemoryGB=40})
 Check 'the README example: 12 threads and 40 GB' {$l.Light.CpuThreads -eq 2 -and $l.Light.MemoryMiB -eq 1024 -and $l.Light.CopyThreads -eq 4 -and $l.Light.Priority -eq 'BelowNormal' -and $l.Maximum.CpuThreads -eq 11 -and $l.Maximum.MemoryMiB -eq 8192 -and $l.Maximum.CopyThreads -eq 32 -and $l.Maximum.Priority -eq 'Normal'}

 # --- Settings file ---
 $pp=(Get-CenterPaths).Profiles
 $damaged=[ordered]@{'an empty file'='';'only spaces'="  `n";'a file cut off half-way'='{"Version":1,"Profiles":[{"Id":"ab';'no list of profiles'='{}';'a list instead of settings'='[]';'profiles set to nothing'='{"Version":1,"Profiles":null}';'a profile without its sources'='{"Version":1,"Profiles":[{"Id":"a","Name":"n","DestinationVolumeId":"v","ReminderDays":7}]}';'a source that is empty'='{"Version":1,"Profiles":[{"Id":"a","Name":"n","DestinationVolumeId":"v","ReminderDays":7,"Sources":[{}]}]}';'an empty place in the list of sources'='{"Version":1,"Profiles":[{"Id":"a","Name":"n","DestinationVolumeId":"v","ReminderDays":7,"Sources":[null]}]}';'a source that is not a source'='{"Version":1,"Profiles":[{"Id":"a","Name":"n","DestinationVolumeId":"v","ReminderDays":7,"Sources":["x"]}]}'}
 foreach($c in $damaged.GetEnumerator()){
  [IO.File]::WriteAllText($pp,$c.Value)
  Check "damaged settings ($($c.Key)): the error names the file and the file is left as it is" {(Throws {Read-CenterProfiles} '*profiles.local.json*') -and [IO.File]::ReadAllText($pp) -ceq $c.Value}
 }
 [IO.File]::WriteAllText($pp,([char]0xFEFF+'{"Version":1,"Profiles":[]}'))
 Check 'settings with no profiles (and a byte order mark) are read' {@((Read-CenterProfiles).Profiles).Count -eq 0}
 Remove-Item -LiteralPath $pp

 # --- Settings file: the copy of the last good one ---
 $good=Join-Path $data 'profiles.lastgood.local.json';$cut='{"Version":1,"Profiles":[{"Id":"ab'
 $d0=Read-CenterProfiles;[void](New-CenterProfile $d0 'Kept' 'VOL-KEPT' 'Model' 10);Save-CenterProfiles $d0
 Check 'saving the settings keeps a copy of the last good file beside them' {(Test-Path -LiteralPath $good) -and [IO.File]::ReadAllText($good) -ceq [IO.File]::ReadAllText($pp)}
 $goodText=[IO.File]::ReadAllText($good)
 Check 'settings that read well need no rescue' {$r=Get-CenterSettingsRecovery;-not $r.Damaged -and -not $r.Message}
 [IO.File]::WriteAllText($pp,$cut)
 $r=Get-CenterSettingsRecovery
 Check 'damaged settings with a good copy: the copy is offered with its date and what it holds' {$r.Damaged -and $r.CanRestore -and $r.LastGoodWhen -is [datetime] -and $r.LastGoodProfiles -eq 1 -and $r.Message -like '*profiles.local.json*' -and $r.Message -like '*What you can do*' -and $r.Message -like ('*{0:d MMM yyyy}*' -f $r.LastGoodWhen) -and $r.Message -like '*kept*'}
 Check 'looking at the damage changes neither file' {[IO.File]::ReadAllText($pp) -ceq $cut -and [IO.File]::ReadAllText($good) -ceq $goodText}
 $done=Restore-CenterLastGood
 Check 'restoring puts the good copy back and the settings read again' {$back=Read-CenterProfiles;@($back.Profiles).Count -eq 1 -and $back.Profiles[0].Name -eq 'Kept' -and [IO.File]::ReadAllText($good) -ceq $goodText}
 Check 'the damaged file is kept beside it under a dated name, unchanged' {$done.KeptAs -ne $pp -and (Split-Path $done.KeptAs -Leaf) -like 'profiles.damaged-*.local.json' -and [IO.File]::ReadAllText($done.KeptAs) -ceq $cut}
 [IO.File]::WriteAllText($pp,'')
 $done2=Restore-CenterLastGood
 Check 'a second damaged file never takes the place of the first one kept aside' {$done2.KeptAs -ne $done.KeptAs -and [IO.File]::ReadAllText($done.KeptAs) -ceq $cut -and [IO.File]::ReadAllText($done2.KeptAs) -ceq ''}
 [IO.File]::WriteAllText($pp,'{}');[void](Save-CenterLastGood)
 Check 'a damaged settings file never replaces the good copy' {[IO.File]::ReadAllText($good) -ceq $goodText}
 [IO.File]::WriteAllText($good,'{"Version":1,"Profi')
 $r=Get-CenterSettingsRecovery
 Check 'a good copy that is itself damaged is not offered, and both files stay as they are' {$r.Damaged -and -not $r.CanRestore -and $r.Message -like '*cannot be read either*' -and $r.Message -like '*What you can do*' -and (Throws {Restore-CenterLastGood} '*good copy*') -and [IO.File]::ReadAllText($pp) -ceq '{}' -and [IO.File]::ReadAllText($good) -ceq '{"Version":1,"Profi'}
 Remove-Item -LiteralPath $good
 $r=Get-CenterSettingsRecovery
 Check 'damaged settings without a good copy: said plainly, nothing is restored or changed' {$r.Damaged -and -not $r.CanRestore -and $r.Message -like '*no earlier good copy*' -and $r.Message -like '*What you can do*' -and (Throws {Restore-CenterLastGood} '*good copy*') -and [IO.File]::ReadAllText($pp) -ceq '{}'}
 [IO.File]::WriteAllText($pp,$goodText);[void](Save-CenterLastGood)
 Check 'settings that were read as valid get a good copy when there is none yet' {[IO.File]::ReadAllText($good) -ceq $goodText}
 Get-ChildItem -LiteralPath $data -Filter 'profiles.*' -File|Remove-Item
 $odd=Join-Path $root 'odd {0} {name}';New-Item -ItemType Directory -Path $odd|Out-Null;[void](Set-CenterPaths $odd)
 $d0=Read-CenterProfiles;[void](New-CenterProfile $d0 'Kept' 'VOL-KEPT' 'Model' 10);Save-CenterProfiles $d0;[IO.File]::WriteAllText((Get-CenterPaths).Profiles,'{"Profiles":[{')
 Check 'a folder name or a reason with braces in it does not break the offer to restore' {$r=Get-CenterSettingsRecovery;$r.CanRestore -and $r.Message -like '*odd {0} {name}*What you can do: restore*'}
 [void](Set-CenterPaths $data)

 # --- Detailed step logs are deleted after 30 days; nothing else is ---
 $logs=(Get-CenterPaths).Logs;New-Item -ItemType Directory -Path $logs,(Join-Path $logs 'sub') -Force|Out-Null
 $age={param($path,$days)[IO.File]::WriteAllText($path,'x');[IO.File]::SetLastWriteTime($path,(Get-Date).AddDays(-$days));$path}
 $oldLog=& $age (Join-Path $logs 'step-20260101-101010-abcdef.log') 31;$newLog=& $age (Join-Path $logs 'step-20261101-101010-123abc.log') 29
 $others=@((& $age (Join-Path $logs 'ui-errors.log') 400),(& $age (Join-Path $logs 'step-notes.log') 400),(& $age (Join-Path $logs 'step-20260101-101010-abcdef.log.txt') 400),(& $age (Join-Path $logs 'sub\step-20260101-101010-abcdef.log') 400),(& $age (Join-Path $logs 'history.jsonl') 400),(& $age (Join-Path $logs 'summary.json') 400),(& $age (Get-CenterPaths).History 400))
 $removed=Remove-CenterOldStepLogs
 Check 'a step log older than 30 days is deleted, a newer one stays' {$removed -eq 1 -and -not (Test-Path -LiteralPath $oldLog) -and (Test-Path -LiteralPath $newLog)}
 Check 'the run history, summaries, other logs and anything not named like a step log are never touched' {-not @($others|Where-Object {-not (Test-Path -LiteralPath $_)}).Count}
 Check 'cleaning up again, or without a logs folder, is not an error' {(Remove-CenterOldStepLogs) -eq 0 -and $(Remove-Item -LiteralPath $logs -Recurse;(Remove-CenterOldStepLogs) -eq 0)}
 Remove-Item -LiteralPath (Get-CenterPaths).History

 # --- Custom load: a warning, never a limit ---
 $pc=[pscustomobject]@{Threads=8;MemoryGB=8.0;FreeMemoryGB=3.0}
 Check 'memory above half of what this computer has gets a warning that names both numbers' {$w=Get-CenterLoadWarning 6144 $pc;$w -like '*6,144 MB*' -and $w -like '*8 GB*' -and $w -like '*4,096 MB*'}
 Check 'memory up to half of the computer gets no warning' {-not (Get-CenterLoadWarning 4096 $pc) -and -not (Get-CenterLoadWarning 512 $pc) -and -not (Get-CenterLoadWarning 8192 ([pscustomobject]@{Threads=8;MemoryGB=64.0}))}
 Check 'the value itself is not lowered: the custom load keeps what was typed' {(Get-CenterLoad ([pscustomobject]@{Load='Custom';CustomLoad=[pscustomobject]@{CpuThreads=2;MemoryMiB=6144;CopyThreads=8;Priority='Normal'}}) $pc).MemoryMiB -eq 6144}
 Check 'a computer whose memory is unknown gets no warning instead of an error' {-not (Get-CenterLoadWarning 8192 ([pscustomobject]@{Threads=8;MemoryGB=0.0}))}

 # --- Why a button is off ---
 Check 'backup buttons: a running or waiting backup, of this drive or another, is named' {(Get-CenterDisabledReason -For Backup -ProfileId 'a' -RunProfileId 'a') -like '*backup of this drive is running*' -and (Get-CenterDisabledReason -For Backup -ProfileId 'a' -RunProfileId 'b') -like '*another drive*' -and (Get-CenterDisabledReason -For Backup -ProfileId 'a' -WaitProfileId 'a') -like '*waiting for AI sessions*' -and (Get-CenterDisabledReason -For Backup -ProfileId 'a' -WaitProfileId 'b') -like '*another drive*waiting*'}
 Check 'backup buttons: drive not connected, drive check, speed test, nothing selected' {(Get-CenterDisabledReason -For Backup -ProfileId 'a' -Connected $false) -like 'Connect this drive*' -and (Get-CenterDisabledReason -For Backup -ProfileId 'a' -CheckProfileId 'a') -like '*drive check*' -and (Get-CenterDisabledReason -For Backup -ProfileId 'a' -SpeedProfileId 'a') -like '*speed test*' -and (Get-CenterDisabledReason -For Backup -ProfileId 'a' -NothingSelected $true) -like '*Nothing is selected*What to back up*'}
 Check 'backup buttons: nothing in the way gives no reason; work on another drive does not count' {-not (Get-CenterDisabledReason -For Backup -ProfileId 'a') -and -not (Get-CenterDisabledReason -For Backup -ProfileId 'a' -CheckProfileId 'b' -SpeedProfileId 'b') -and -not (Get-CenterDisabledReason -For Backup -ProfileId '')}
 Check 'a running backup is named before a missing drive, and a missing drive before nothing selected' {(Get-CenterDisabledReason -For Backup -ProfileId 'a' -RunProfileId 'b' -Connected $false) -like '*another drive*' -and (Get-CenterDisabledReason -For Backup -ProfileId 'a' -Connected $false -NothingSelected $true) -like 'Connect*'}
 Check 'drive check buttons: not connected, another drive being checked, a backup running or waiting, a speed test' {(Get-CenterDisabledReason -For Check -ProfileId 'a' -Connected $false) -like 'Connect*' -and (Get-CenterDisabledReason -For Check -ProfileId 'a' -CheckProfileId 'b') -like '*another drive*' -and (Get-CenterDisabledReason -For Check -ProfileId 'a' -RunProfileId 'a') -like '*backup of this drive*' -and (Get-CenterDisabledReason -For Check -ProfileId 'a' -WaitProfileId 'a') -like '*waiting*' -and (Get-CenterDisabledReason -For Check -ProfileId 'a' -SpeedProfileId 'a') -like '*speed test*' -and -not (Get-CenterDisabledReason -For Check -ProfileId 'a' -RunProfileId 'b')}
 Check 'speed test button: not connected, a backup anywhere, a drive check, another speed test' {(Get-CenterDisabledReason -For Speed -ProfileId 'a' -Connected $false) -like 'Connect*' -and (Get-CenterDisabledReason -For Speed -ProfileId 'a' -RunProfileId 'a') -like '*backup of this drive*' -and (Get-CenterDisabledReason -For Speed -ProfileId 'a' -RunProfileId 'b') -like '*another drive*' -and (Get-CenterDisabledReason -For Speed -ProfileId 'a' -CheckProfileId 'a') -like '*drive check*' -and (Get-CenterDisabledReason -For Speed -ProfileId 'a' -SpeedProfileId 'b') -like '*speed test of another drive*' -and -not (Get-CenterDisabledReason -For Speed -ProfileId 'a')}

 # --- Which source a link acts on ---
 $one=[pscustomobject]@{Sources=@([pscustomobject]@{Id='s1';Label='One'})};$two=[pscustomobject]@{Sources=@([pscustomobject]@{Id='s1';Label='One'},[pscustomobject]@{Id='s2';Label='Two'})}
 Check 'with one source it is used without selecting it' {$r=Resolve-CenterSource $one '';$r.Source.Id -eq 's1' -and -not $r.Message}
 Check 'with several sources and none selected, it asks to select one and acts on none' {$r=Resolve-CenterSource $two '';$null -eq $r.Source -and $r.Message -like 'Select a source*'}
 Check 'the selected source is used, also when it is not the first' {(Resolve-CenterSource $two 's2').Source.Label -eq 'Two'}
 Check 'a drive without sources, or a selection that is gone, acts on nothing and says why' {$r=Resolve-CenterSource ([pscustomobject]@{Sources=@()}) '';$null -eq $r.Source -and $r.Message -like '*no folders*' -and $null -eq (Resolve-CenterSource $two 'gone').Source}

 # --- Sources: names on the drive ---
 $d=Read-CenterProfiles
 $p=New-CenterProfile $d 'Fake' 'NO-SUCH-VOLUME' 'Model' 100
 $repo={param($s)[string](Read-CenterJob $s.ConfigPath).RepositoryFolder}
 $s1=Add-CenterSource -Data $d -ProfileId $p.Id -Path (Join-Path $src 'A') -Label 'Work' -DefaultMode Mirror
 $s2=Add-CenterSource -Data $d -ProfileId $p.Id -Path (Join-Path $src 'B') -Label 'Work' -DefaultMode Both
 $s3=Add-CenterSource -Data $d -ProfileId $p.Id -Path (Join-Path $src 'C') -Label 'work' -DefaultMode Both
 Check 'three folders with the same name get three copy folders and three versions folders' {@($s1,$s2,$s3|ForEach-Object {$_.MirrorFolder.ToLowerInvariant()}|Sort-Object -Unique).Count -eq 3 -and @($s1,$s2,$s3|ForEach-Object {(& $repo $_).ToLowerInvariant()}|Sort-Object -Unique).Count -eq 3}
 Remove-CenterSource $d $p.Id $s1.Id
 $s4=Add-CenterSource -Data $d -ProfileId $p.Id -Path (Join-Path $src 'A2') -Label 'Work' -DefaultMode Mirror
 Check 'another folder never gets the copy or versions folder of a removed source' {$s4.MirrorFolder -ine $s1.MirrorFolder -and (& $repo $s4) -ine 'Work-Versions'}
 $restored=$null
 $s5=Add-CenterSource -Data $d -ProfileId $p.Id -Path (Join-Path $src 'A') -Label 'Other' -DefaultMode Versioned -Restored ([ref]$restored)
 Check 'adding a removed folder again restores its settings, copy folder and versions folder' {$s5.ConfigPath -eq $s1.ConfigPath -and $s5.MirrorFolder -eq $s1.MirrorFolder -and (Read-CenterJob $s5.ConfigPath).DefaultMode -eq 'Mirror'}
 Check 'and says so, so the window can tell the user their new choice was not applied' {$restored -and $restored.MirrorFolder -eq 'Work-Mirror' -and $restored.RepositoryFolder -eq 'Work-Versions' -and $restored.DefaultMode -eq 'Mirror'}
 $fresh=$null;[void](Add-CenterSource -Data $d -ProfileId $p.Id -Path (New-Item -ItemType Directory -Path (Join-Path $src 'New')).FullName -Label 'New' -Restored ([ref]$fresh))
 Check 'a folder added for the first time is not reported as restored' {$null -eq $fresh}
 foreach($label in 'פרויקטים','..','CON','a/b:c*?','My Docs','My-Docs',('x'*80)){
  [void](Add-CenterSource -Data $d -ProfileId $p.Id -Path (New-Item -ItemType Directory -Path (Join-Path $src ('L'+[guid]::NewGuid().ToString('N').Substring(0,6)))).FullName -Label $label)
 }
 $all=@($p.Sources)
 Check 'Hebrew, odd and very long names all get folders of their own with safe names' {@($all.MirrorFolder|ForEach-Object {$_.ToLowerInvariant()}|Sort-Object -Unique).Count -eq $all.Count -and @($all|ForEach-Object {(& $repo $_).ToLowerInvariant()}|Sort-Object -Unique).Count -eq $all.Count -and -not @($all.MirrorFolder|Where-Object {$_ -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*-Mirror$' -or $_.Length -gt 80}).Count}
 Check 'a folder inside or around a source, or the same folder in other letter case, is refused' {(Throws {Add-CenterSource -Data $d -ProfileId $p.Id -Path (Join-Path $src 'B\sub')} '*Overlaps*') -and (Throws {Add-CenterSource -Data $d -ProfileId $p.Id -Path $src} '*Overlaps*') -and (Throws {Add-CenterSource -Data $d -ProfileId $p.Id -Path (Join-Path $src 'b').ToUpperInvariant()} '*Overlaps*')}
 Check 'a network folder is refused in plain words' {Throws {Add-CenterSource -Data $d -ProfileId $p.Id -Path '\\localhost\c$\Windows' -Label 'net'} '*network*'}
 Check 'a profile whose drive is not plugged in is not connected, and nothing can run on it' {-not (Get-CenterDrive 'NO-SUCH-VOLUME').Connected -and (Throws {Get-CenterSteps $p} '*not connected*')}

 # --- Freshness of a drive ---
 $p2=New-CenterProfile $d 'Fake2' 'NO-SUCH-VOLUME-2' 'Model' 100
 New-Item -ItemType Directory -Path (Join-Path $src 'F1\d'),(Join-Path $src 'F2\d')|Out-Null
 $f1=Add-CenterSource -Data $d -ProfileId $p2.Id -Path (Join-Path $src 'F1') -Label 'F1' -DefaultMode Both
 $f2=Add-CenterSource -Data $d -ProfileId $p2.Id -Path (Join-Path $src 'F2') -Label 'F2' -DefaultMode Mirror
 $n=Get-Date
 $E={param($sid,$kind,$ok,$when)[pscustomobject]@{ProfileId=$p2.Id;SourceId=$sid;Kind=$kind;Success=$ok;Finished=$when.ToString('o')}}
 $full=@((& $E $f1.Id 'Mirror' $true $n.AddHours(-1)),(& $E $f1.Id 'Versioned' $true $n.AddDays(-3)),(& $E $f2.Id 'Mirror' $true $n.AddHours(-2)))
 Check 'a drive with one source never backed up is Never' {(Get-CenterFreshness $p2 @((& $E $f1.Id 'Mirror' $true $n),(& $E $f1.Id 'Versioned' $true $n)) $n).State -eq 'Never'}
 Check 'a drive is as old as its oldest part; later failures and checks change nothing' {$f=Get-CenterFreshness $p2 ($full+@((& $E $f1.Id 'Versioned' $false $n.AddMinutes(-5)),(& $E $f1.Id 'VersionedCheck' $true $n.AddMinutes(-4)))) $n;$f.State -eq 'OK' -and [math]::Abs(($n-$f.LastComplete).TotalHours-72) -lt 0.01}
 Check 'runs of a source that was removed do not count' {(Get-CenterFreshness $p2 @((& $E 'gone' 'Mirror' $true $n)) $n).State -eq 'Never'}
 $keep=[IO.File]::ReadAllText($f2.ConfigPath)
 foreach($bad in '{ "Source": ',''){[IO.File]::WriteAllText($f2.ConfigPath,$bad);Check "a source whose settings cannot be read ($(if($bad){'cut off'}else{'empty'})) shows as an error and keeps the drive from looking fresh" {$f=Get-CenterFreshness $p2 $full $n;$f.State -eq 'Error' -and -not $f.LastComplete -and @($f.Rows|Where-Object {$_.State -eq 'Error' -and $_.Problem}).Count -eq 1}}
 [IO.File]::WriteAllText($f2.ConfigPath,$keep)

 # --- The latest run failed ---
 # F1 uses plain copy and versions, F2 the plain copy only.
 $R={param($sid,$kind,$ok,$when,$err='',[bool]$stopped=$false,$more=@{})$o=[ordered]@{ProfileId=$p2.Id;SourceId=$sid;Label='old label';Kind=$kind;Success=$ok;Stopped=$stopped;Error=$err;Finished=$when.ToString('o')};foreach($k in $more.Keys){$o[$k]=$more[$k]};[pscustomobject]$o}
 Check 'no warning while the latest run of every source succeeded' {-not @(Get-CenterRunWarnings $p2 $full $n).Count -and -not (Format-CenterRunWarnings @()).Text}
 $w=@(Get-CenterRunWarnings $p2 ($full+@(& $R $f2.Id 'Mirror' $false $n.AddMinutes(-30) '3 files could not be copied; see copy-errors.txt in C:\runs\x')) $n)
 Check 'a failure after a success: warned with the source, when and a short reason' {$w.Count -eq 1 -and $w[0].Level -eq 'Failed' -and $w[0].SourceId -eq $f2.Id -and $w[0].Text -like '*F2*plain copy*failed 30 minutes ago: 3 files could not be copied*' -and $w[0].Text -notlike '*copy-errors*'}
 Check 'the line for the overview says where the details are' {$f=Format-CenterRunWarnings $w;$f.Level -eq 'Failed' -and $f.Text -like '*F2*failed*Recent runs*Speed and load*' -and $f.Text -notmatch "`n"}
 Check 'age and colour of the drive stay as they were' {$f=Get-CenterFreshness $p2 ($full+@(& $R $f2.Id 'Mirror' $false $n.AddMinutes(-30) 'x')) $n;$f.State -eq 'OK' -and [math]::Abs(($n-$f.LastComplete).TotalHours-72) -lt 0.01}
 $w=@(Get-CenterRunWarnings $p2 ($full+@(& $R $f2.Id 'Mirror' $false $n.AddMinutes(-30) 'Stopped by you before it finished.' $true)) $n)
 Check 'a run that was stopped is warned about as stopped, not as failed' {$w.Count -eq 1 -and $w[0].Level -eq 'Stopped' -and $w[0].Text -like '*F2*stopped*30 minutes ago*' -and $w[0].Text -notlike '*failed*'}
 Check 'a success after the failure clears the warning' {-not @(Get-CenterRunWarnings $p2 ($full+@((& $R $f2.Id 'Mirror' $false $n.AddMinutes(-30) 'x'),(& $R $f2.Id 'Mirror' $true $n.AddMinutes(-10)))) $n).Count}
 $w=@(Get-CenterRunWarnings $p2 ($full+@((& $R $f1.Id 'Versioned' $false $n.AddMinutes(-20) 'The repository is locked. An earlier run left its lock behind.'),(& $R $f1.Id 'Mirror' $true $n.AddMinutes(-25)))) $n)
 Check 'failed versions are warned about although the plain copy of the same source succeeded' {$w.Count -eq 1 -and $w[0].Kind -eq 'Versioned' -and $w[0].Text -like '*F1*versions*failed*The repository is locked*' -and $w[0].Text -notlike '*left its lock*'}
 $w=@(Get-CenterRunWarnings $p2 ($full+@((& $R $f1.Id 'Mirror' $false $n.AddMinutes(-20) 'a'),(& $R $f2.Id 'Mirror' $false $n.AddMinutes(-5) 'b'))) $n)
 Check 'two sources failed: the newest is named first and the line counts the other' {$w.Count -eq 2 -and $w[0].SourceId -eq $f2.Id -and (Format-CenterRunWarnings $w).Text -like '*F2*1 more*' -and (Format-CenterRunWarnings $w).Full -like '*F1*'}
 $checkFail=& $R $f2.Id 'MirrorCheck' $false $n.AddMinutes(-15) '4 files differ from the source; see verify-differences.txt in C:\runs\y'
 $w=@(Get-CenterRunWarnings $p2 ($full+@($checkFail)) $n)
 Check 'a failed content check is its own, milder line: it is not a failed backup' {$w.Count -eq 1 -and $w[0].Level -eq 'Check' -and $w[0].Text -like '*content check*F2*4 files differ*' -and (Format-CenterRunWarnings $w).Level -eq 'Check'}
 Check 'a failed backup is named before a failed content check' {$w=@(Get-CenterRunWarnings $p2 ($full+@($checkFail,(& $R $f1.Id 'Mirror' $false $n.AddMinutes(-40) 'a'))) $n);$w.Count -eq 2 -and $w[0].Level -eq 'Failed' -and $w[1].Level -eq 'Check'}
 Check 'a later successful check, or a repair, clears the content check line; a stopped check is not shown' {-not @(Get-CenterRunWarnings $p2 ($full+@($checkFail,(& $R $f2.Id 'MirrorCheck' $true $n.AddMinutes(-5)))) $n).Count -and -not @(Get-CenterRunWarnings $p2 ($full+@($checkFail,(& $R $f2.Id 'MirrorRepair' $true $n.AddMinutes(-5)))) $n).Count -and -not @(Get-CenterRunWarnings $p2 ($full+@(& $R $f2.Id 'MirrorCheck' $false $n.AddMinutes(-5) 'Stopped by you before it finished.' $true)) $n).Count}
 Check 'runs of a removed source, and of a kind the source no longer uses, are ignored' {-not @(Get-CenterRunWarnings $p2 ($full+@((& $R 'gone' 'Mirror' $false $n.AddMinutes(-5) 'x'),(& $R $f2.Id 'Versioned' $false $n.AddMinutes(-5) 'x'))) $n).Count}
 $bare=@([pscustomobject]@{SourceId=$f2.Id;Kind='Mirror';Success=$false;Finished=$n.AddMinutes(-9).ToString('o')},[pscustomobject]@{SourceId=$f2.Id;Kind='MirrorCheck';Success=$false;Finished=$n.AddMinutes(-8).ToString('o')})
 Check 'old entries without an error text or other newer fields are warned about without an error' {$w=@(Get-CenterRunWarnings $p2 ($full+$bare) $n);$w.Count -eq 2 -and $w[0].Text -like '*F2*failed 9 minutes ago' -and -not (Get-CenterRepairState ($full+$bare) $f2.Id).Needed}
 Check 'a failed repair is not a failed backup' {-not @(Get-CenterRunWarnings $p2 ($full+@(& $R $f2.Id 'MirrorRepair' $false $n.AddMinutes(-5) 'x')) $n|Where-Object {$_.Level -eq 'Failed'}).Count}

 # --- When "Repair differing files" is offered ---
 $st=Get-CenterRepairState ($full+@($checkFail)) $f2.Id
 Check 'offered when the latest content check of the plain copy found different files' {$st.Needed -and $st.Differences -eq 4 -and $st.When -is [datetime] -and $st.Details -like '*runs\y*'}
 Check 'the number of files is read from the new history field too' {(Get-CenterRepairState ($full+@(& $R $f2.Id 'MirrorCheck' $false $n.AddMinutes(-15) 'anything' $false @{Differences=7})) $f2.Id).Differences -eq 7}
 Check 'not offered without a check, after a clean check, or for another source' {-not (Get-CenterRepairState $full $f2.Id).Needed -and -not (Get-CenterRepairState ($full+@($checkFail,(& $R $f2.Id 'MirrorCheck' $true $n.AddMinutes(-5)))) $f2.Id).Needed -and -not (Get-CenterRepairState ($full+@($checkFail)) $f1.Id).Needed}
 Check 'not offered once a later repair succeeded, or a later backup compared every file' {-not (Get-CenterRepairState ($full+@($checkFail,(& $R $f2.Id 'MirrorRepair' $true $n.AddMinutes(-5)))) $f2.Id).Needed -and -not (Get-CenterRepairState ($full+@($checkFail,(& $R $f2.Id 'Mirror' $true $n.AddMinutes(-5) '' $false @{CheckedFiles=100}))) $f2.Id).Needed}
 Check 'still offered after a repair that failed, a backup that compared nothing, or a check that was stopped' {(Get-CenterRepairState ($full+@($checkFail,(& $R $f2.Id 'MirrorRepair' $false $n.AddMinutes(-5) 'x'))) $f2.Id).Needed -and (Get-CenterRepairState ($full+@($checkFail,(& $R $f2.Id 'Mirror' $true $n.AddMinutes(-5)))) $f2.Id).Needed -and (Get-CenterRepairState ($full+@($checkFail,(& $R $f2.Id 'MirrorCheck' $false $n.AddMinutes(-5) 'Stopped by you before it finished.' $true))) $f2.Id).Needed}
 Check 'a check that failed for another reason (files that could not be read) offers no repair' {-not (Get-CenterRepairState ($full+@(& $R $f2.Id 'MirrorCheck' $false $n.AddMinutes(-5) '2 files could not be copied; see copy-errors.txt')) $f2.Id).Needed}

 # --- The steps of a repair (the system drive stands in for a connected backup drive; nothing runs) ---
 $realId=$p2.DestinationVolumeId;$p2.DestinationVolumeId=(Get-Volume -DriveLetter $env:SystemDrive.Substring(0,1)).UniqueId
 try{
  $steps=@(Get-CenterSteps $p2 @() 'Repair')
  Check 'a repair runs the plain copy tool with -Repair for every source that has a plain copy, and nothing for versions' {$steps.Count -eq 2 -and -not @($steps|Where-Object {$_.Kind -ne 'Mirror' -or $_.Purpose -ne 'Repair' -or '-Repair' -notin $_.Arguments -or '-VerifyOnly' -in $_.Arguments -or '-MoveExtras' -in $_.Arguments -or ($_.Arguments -join ' ') -notlike '*Invoke-FastMirror.ps1*'}).Count}
  Check 'a repair of one source has one step, with its copy folder' {$one=@(Get-CenterSteps $p2 @($f2.Id) 'Repair');$one.Count -eq 1 -and $one[0].SourceId -eq $f2.Id -and $one[0].Arguments[[array]::IndexOf($one[0].Arguments,'-Folder')+1] -eq $f2.MirrorFolder}
  Check 'a backup and a content check are built as before' {$b=@(Get-CenterSteps $p2 @() 'Backup');$v=@(Get-CenterSteps $p2 @() 'Verify');$b.Count -eq 3 -and $v.Count -eq 3 -and -not @($b+$v|Where-Object {'-Repair' -in $_.Arguments}).Count -and @($v|Where-Object {'-VerifyOnly' -in $_.Arguments}).Count -eq 2}
 }finally{$p2.DestinationVolumeId=$realId}

 # --- A source that is in use ---
 $job=Read-CenterJob $f1.ConfigPath;$lockPath=[IO.Path]::GetFullPath([string]$job.PasswordDpapiPath)+'.run.lock'
 New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($lockPath)) -Force|Out-Null
 $lock=[IO.File]::Open($lockPath,'OpenOrCreate','ReadWrite','None')
 try{
  $sw=[Diagnostics.Stopwatch]::StartNew()
  $busy=Throws {Sync-CenterJob $p2 $f1 ([pscustomobject]@{Name='Light';CpuThreads=1;MemoryMiB=512;ReadConcurrency=1;Priority='BelowNormal'}) -WaitMilliseconds 300} '*busy*'
  Check "the window gives up on a source in use within a second ($($sw.ElapsedMilliseconds) ms)" {$busy -and $sw.ElapsedMilliseconds -lt 1500}
 }finally{$lock.Dispose()}

 # --- What may run on a drive at once ---
 Check 'a backup may not start on a drive that is being checked or speed-tested' {(Get-CenterBusyReason -ProfileId 'a' -For Backup -CheckProfileId 'a') -like '*drive check*' -and (Get-CenterBusyReason -ProfileId 'a' -For Backup -SpeedProfileId 'a') -like '*speed test*' -and -not (Get-CenterBusyReason -ProfileId 'a' -For Backup -CheckProfileId 'b' -SpeedProfileId 'b')}
 Check 'a drive check or speed test may not start while a backup of that drive runs or waits' {(Get-CenterBusyReason -ProfileId 'a' -For Check -RunProfileId 'a') -like '*backup*' -and (Get-CenterBusyReason -ProfileId 'a' -For Check -WaitProfileId 'a') -like '*waiting*' -and (Get-CenterBusyReason -ProfileId 'a' -For Speed -WaitProfileId 'a') -like '*waiting*' -and (Get-CenterBusyReason -ProfileId 'a' -For Check -SpeedProfileId 'a') -like '*speed test*' -and -not (Get-CenterBusyReason -ProfileId 'a' -For Check)}

 # --- Drives: asking Windows less often ---
 Check 'free space of a drive is read without listing every volume' {$c=Get-CenterVolumeQueryCount;(Get-CenterFreeBytes $env:SystemDrive.Substring(0,1)) -gt 0 -and $null -eq (Get-CenterFreeBytes '1') -and (Get-CenterVolumeQueryCount) -eq $c}
 [void](Get-CenterDrive 'NO-SUCH-VOLUME');$c=Get-CenterVolumeQueryCount;Start-Sleep -Seconds 4;[void](Get-CenterDrive 'NO-SUCH-VOLUME')
 Check 'refreshing the window does not list the volumes again while the same drives are plugged in' {(Get-CenterVolumeQueryCount) -eq $c}
 [void](Get-CenterDrive 'NO-SUCH-VOLUME' -Fresh)
 Check 'before something starts on a drive the volumes are always listed again' {(Get-CenterVolumeQueryCount) -eq $c+1}

 # --- Results of tool runs ---
 Check 'a result is found after other output, also output with braces' {(ConvertFrom-CenterToolJson ("WARNING: skipped {temp} folder`r`n{ not json`r`n{`r`n  `"A`": 1,`r`n  `"B`": {`r`n    `"C`": 2`r`n  }`r`n}`r`ntrailing words")).B.C -eq 2 -and (ConvertFrom-CenterToolJson '{"A":5}').A -eq 5}
 Check 'of several objects in the output, the one with the expected content is taken' {(ConvertFrom-CenterToolJson "{`n `"Note`": 1`n}`n{`n `"CopyErrors`": 0,`n `"X`": 7`n}`n{`n `"Other`": 2`n}" 'CopyErrors').X -eq 7 -and (Throws {ConvertFrom-CenterToolJson "{`n `"Note`": 1`n}" 'CopyErrors'} '*Note*')}
 Check 'output without a result gives the tool''s own words, not an index error' {(Throws {ConvertFrom-CenterToolJson 'Access denied to drive X'} '*Access denied to drive X*') -and (Throws {ConvertFrom-CenterToolJson ''} '*no result*')}
 $pw=(Get-Process -Id $PID).Path
 function Invoke-Fake([string]$Command,[string]$Kind='Mirror',[string]$Purpose='Backup',[switch]$Stop,[string]$RunDirectory){
  $step=[pscustomobject]@{SourceId='s';Label='L';Kind=$Kind;Purpose=$Purpose;FilePath=$pw;Arguments=@('-NoProfile','-Command',$Command);RunDirectory=$RunDirectory;Priority='BelowNormal'}
  $r=Start-CenterStep $step (Join-Path $root 'step.log')
  if($Stop){Start-Sleep -Milliseconds 1500;$r.Process.Kill($true);Complete-CenterStep $r 'p' -Stopped}else{Complete-CenterStep $r 'p'}
 }
 $json='{"RunFolder":"X","CopyErrors":0,"Runs":[{"Files":"Files : 10 3 7 0 0 0","Bytes":"Bytes : 5000 629145600 0 0 0 0"}],"Verify":{"FilesMatched":10,"Differences":0}}'
 $e=Invoke-Fake "Write-Output '$json'"
 Check 'a plain copy: files and bytes copied, files checked, exact seconds' {$e.Success -and $e.Kind -eq 'Mirror' -and $e.CopiedFiles -eq 3 -and $e.CopiedBytes -eq 629145600 -and $e.CheckedFiles -eq 10 -and $e.Seconds -gt 0 -and $e.Seconds -lt 60 -and $null -ne $e.Minutes}
 $e=Invoke-Fake "Write-Output 'WARNING: skipped {temp} folder';Write-Output '$json'"
 Check 'a line with a brace before the result does not fail the plain copy' {$e.Success -and $e.CopiedFiles -eq 3}
 $e=Invoke-Fake ("Write-Output '"+$json.Replace('Files : 10 3 7 0 0 0','').Replace('Bytes : 5000 629145600 0 0 0 0','')+"'")
 Check 'totals that could not be read are recorded as unknown, not as 0 files' {$e.Success -and $null -eq $e.CopiedFiles -and $null -eq $e.CopiedBytes}
 $e=Invoke-Fake ("Write-Output '"+$json.Replace('Files :','Dateien:')+"'")
 Check 'totals in an unexpected form are recorded as unknown too' {$e.Success -and $null -eq $e.CopiedFiles -and $null -eq $e.CopiedBytes}
 $e=Invoke-Fake ("Write-Output '"+'{"RunFolder":"X","CopyErrors":0,"Runs":[]}'+"'")
 Check 'a result that lists no copy run at all records no totals either' {$null -eq $e.CopiedFiles -and $null -eq $e.CopiedBytes}
 $e=Invoke-Fake "Write-Output '$json'" -Purpose Verify
 Check 'a content check is recorded as a check, never as a backup' {$e.Success -and $e.Kind -eq 'MirrorCheck'}
 $e=Invoke-Fake "Write-Output '$json';exit 3"
 Check 'a result with a failing exit code is a failure' {-not $e.Success -and $e.Error -like '*exit code 3*'}
 $e=Invoke-Fake ("Write-Output '"+$json.Replace('"CopyErrors":0','"CopyErrors":2')+"'")
 Check 'files that could not be copied fail the plain copy' {-not $e.Success -and $e.Error -like '2 files could not be copied*'}
 $e=Invoke-Fake ("Write-Output '"+$json.Replace('"Differences":0','"Differences":4')+"'")
 Check 'files that differ fail the plain copy, and their number is recorded' {-not $e.Success -and $e.Error -like '4 files differ*' -and $e.Differences -eq 4}
 # A repair of differing files: recorded as its own kind, never as a backup.
 $rep={param($requested,$repaired,$still,$failed)$json.Replace('"Verify":{','"Repair":{"Requested":'+$requested+',"Repaired":'+$repaired+',"StillDifferent":'+$still+',"Failed":'+$failed+',"MovedTo":"X:\\Copy-recovery\\2026-11-14"},"Verify":{')}
 $e=Invoke-Fake "Write-Output '$(& $rep 3 3 0 0)'" -Purpose Repair
 Check 'a repair is recorded as a repair, never as a backup, and says where the earlier copies are' {$e.Success -and $e.Kind -eq 'MirrorRepair' -and $e.Note -eq 'Repaired 3 files; their earlier copies are in X:\Copy-recovery\2026-11-14.' -and -not @(Get-CenterHistory|Where-Object {$_.Kind -eq 'Mirror' -and $_.Purpose -eq 'Repair'}).Count}
 $e=Invoke-Fake "Write-Output '$(& $rep 5 3 1 1)'" -Purpose Repair
 Check 'a repair that left files different or could not repair some is a failure that says how many' {-not $e.Success -and $e.Kind -eq 'MirrorRepair' -and $e.Error -like '*1 of 5 files still differ*1 could not be repaired*' -and $e.Note -like 'Repaired 3 files*'}
 $e=Invoke-Fake "Write-Output '$(& $rep 0 0 0 0)'" -Purpose Repair
 Check 'a repair with nothing to do says so' {$e.Success -and $e.Note -like 'No differing files*'}
 $e=Invoke-Fake "Write-Output '$json'" -Purpose Repair
 Check 'a tool that does not report a repair is never recorded as a successful repair' {-not $e.Success -and $e.Kind -eq 'MirrorRepair' -and $e.Error -like '*did not report*'}
 $e=Invoke-Fake ("Write-Output '"+$json.Replace('"Verify":{','"Repair":{},"Verify":{')+"'") -Purpose Repair
 Check 'a repair report without its numbers is not a successful repair either' {-not $e.Success -and $e.Error -like '*did not report*'}
 $e=Invoke-Fake ("Write-Output '"+$json.Replace('"Verify":{','"Repair":{"Requested":3,"Repaired":1},"Verify":{')+"'") -Purpose Repair
 Check 'fewer files repaired than asked for is a failure, also when the rest is not mentioned' {-not $e.Success -and $e.Error -like '2 of 3 files still differ*'}
 # Notes the tools hand on.
 $noted=$json.Replace('"Verify":{','"TypeSwapsHealed":["docs\\plan"],"RecoveryFolder":"X:\\Copy-recovery\\now","SkippedByShortName":["a\\LONGFI~1.TXT","b\\OTHERF~1.TXT"],"CaseCollisions":[["Read.me","READ.ME"]],"Verify":{')
 $e=Invoke-Fake "Write-Output '$noted'"
 Check 'a plain copy hands on its notes: a folder in place of a file, short-name skips, names that differ by case' {$e.Success -and $e.Note -like '*A folder took the place of a file of the same name*docs\plan*moved to X:\Copy-recovery\now*' -and $e.Note -like '*2 files were skipped because an Exclude pattern also matches their short Windows name: a\LONGFI~1.TXT, b\OTHERF~1.TXT*' -and $e.Note -like '*Two names differ only by upper/lower case and cannot both be kept: Read.me / READ.ME*'}
 $e=Invoke-Fake ("Write-Output '"+$noted.Replace('"Differences":0','"Differences":4').Replace('"CopyErrors":0','"CopyErrors":2')+"'") -Purpose Verify
 Check 'files that differ are counted also when the error names files that could not be read; a failed run keeps its notes' {-not $e.Success -and $e.Differences -eq 4 -and $e.Error -like '2 files could not be copied*' -and $e.Note -like '*short Windows name*'}
 Check 'notes in other shapes are read too: a count, objects, other spellings' {$t=(Get-CenterResultNotes ([pscustomobject]@{SkippedByShortName=7;TypeSwaps=@([pscustomobject]@{Path='x\y';MovedTo='R:\rec'});CaseConflicts=@([pscustomobject]@{Names=@('a','A')},'b / B')}) 'Mirror') -join ' ';$t -like '*7 files were skipped*' -and $t -notlike '*name: *' -and $t -like '*x\y*moved to R:\rec*' -and $t -like '*a / A, b / B*'}
 Check 'many names are shortened, and a result without any of these fields gives no note and no error' {$t=(Get-CenterResultNotes ([pscustomobject]@{SkippedByShortName=@(1..9|ForEach-Object {"f$_"})}) 'Mirror') -join ' ';$t -like '9 files were skipped*f1, f2, f3, f4, f5 and 4 more*' -and -not @(Get-CenterResultNotes ([pscustomobject]@{CopyErrors=0}) 'Mirror').Count -and -not @(Get-CenterResultNotes ([pscustomobject]@{TypeSwapsHealed=@();SkippedByShortName=0;CaseCollisions=$null;LockReleased=$false}) 'Versioned').Count -and -not @(Get-CenterResultNotes $null 'Mirror').Count}
 $e=Invoke-Fake '[Console]::Error.WriteLine(''The drive is full'');exit 1'
 Check 'a tool that ends without a result reports its own error' {-not $e.Success -and $e.Error -eq 'The drive is full'}
 $e=Invoke-Fake 'exit 1'
 Check 'a tool that ends silently reports its exit code' {-not $e.Success -and $e.Error -like '*exit code 1*' -and -not $e.Stopped}
 $e=Invoke-Fake 'Start-Sleep 30' -Stop
 Check 'a plain copy stopped by the user is recorded as stopped, not as a tool failure' {-not $e.Success -and $e.Stopped -and $e.Error -like 'Stopped*' -and $e.Error -notlike '*exit code*'}
 $rd=Join-Path $root 'run1';New-Item -ItemType Directory -Path $rd|Out-Null
 $e=Invoke-Fake 'Start-Sleep 30' -Kind Versioned -Stop -RunDirectory $rd
 Check 'versions stopped by the user are recorded as stopped' {-not $e.Success -and $e.Stopped -and $e.Error -like 'Stopped*'}
 [IO.File]::WriteAllText((Join-Path $rd 'result.json'),'{"State":"Completed","Progress":{"percent_done":1},"BackupSummary":{"files_new":2,"files_changed":1,"files_unmodified":40,"data_added":12345,"total_bytes_processed":6000000000,"total_files_processed":43}}')
 $e=Invoke-Fake 'Start-Sleep 30' -Kind Versioned -Stop -RunDirectory $rd
 Check 'a stopped step is never a success, even when a finished result is lying there' {-not $e.Success -and $e.Stopped}
 $e=Invoke-Fake 'exit 0' -Kind Versioned -RunDirectory $rd
 Check 'versions: files and bytes come from the backup summary' {$e.Success -and $e.CopiedFiles -eq 3 -and $e.CopiedBytes -eq 12345 -and $e.ProcessedBytes -eq 6000000000}
 [IO.File]::WriteAllText((Join-Path $rd 'result.json'),'{"State":"Completed","Progress":{"files_new":2,"files_changed":1,"data_added":777}}')
 $e=Invoke-Fake 'exit 0' -Kind Versioned -RunDirectory $rd
 Check 'versions without a summary (older worker) still read the progress numbers' {$e.Success -and $e.CopiedFiles -eq 3 -and $e.CopiedBytes -eq 777}
 [IO.File]::WriteAllText((Join-Path $rd 'result.json'),'{"State":"Completed","Progress":{"percent_done":1}}')
 $e=Invoke-Fake 'exit 0' -Kind Versioned -RunDirectory $rd
 Check 'versions with no numbers at all record none' {$e.Success -and $null -eq $e.CopiedFiles -and $null -eq $e.CopiedBytes}
 $e=Invoke-Fake 'exit 1' -Kind Versioned -RunDirectory $rd
 Check 'versions whose tool ended with a failing exit code are a failure, whatever result is lying there' {-not $e.Success -and $e.Error -like '*exit code 1*'}
 [IO.File]::WriteAllText((Join-Path $rd 'result.json'),'{"State":"Completed","BackupSummary":{"files_new":"broken","files_changed":1,"data_added":"x","total_bytes_processed":5}}')
 $e=Invoke-Fake 'exit 0' -Kind Versioned -RunDirectory $rd
 Check 'summary numbers that cannot be read are recorded as unknown: no error on a successful run' {$e.Success -and -not $e.Error -and $null -eq $e.CopiedFiles -and $null -eq $e.CopiedBytes -and $e.ProcessedBytes -eq 5}
 [IO.File]::WriteAllText((Join-Path $rd 'result.json'),'{"State":"Completed","Retention":{"Removed":"many"}}')
 $e=Invoke-Fake 'exit 0' -Kind Versioned -RunDirectory $rd
 Check 'a run never ends as a success that carries an error' {-not ($e.Success -and $e.Error)}
 [IO.File]::WriteAllText((Join-Path $rd 'result.json'),'{"State":"Failed"}')
 $e=Invoke-Fake 'exit 1' -Kind Versioned -RunDirectory $rd
 Check 'failed versions without an error text report the exit code' {-not $e.Success -and $e.Error -like '*exit code 1*'}
 [IO.File]::WriteAllText((Join-Path $rd 'result.json'),'{"State":"Failed","Error":"The repository is locked"}')
 $e=Invoke-Fake 'exit 1' -Kind Versioned -Purpose Verify -RunDirectory $rd
 Check 'a failed check of versions keeps the worker''s error' {-not $e.Success -and $e.Kind -eq 'VersionedCheck' -and $e.Error -eq 'The repository is locked'}
 [IO.File]::WriteAllText((Join-Path $rd 'result.json'),'{"State":"Completed","LockReleased":true,"Retention":{"Removed":2,"Kept":9}}')
 $e=Invoke-Fake 'exit 0' -Kind Versioned -RunDirectory $rd
 Check 'versions: a lock left by an earlier run that was removed is noted, beside the clean-up note' {$e.Success -and $e.Note -like '*A lock left by an earlier run that had ended was removed and the run was tried again.*' -and $e.Note -like '*Deleted 2 old versions; 9 kept.*'}
 $h=@(Get-CenterHistory)
 Check 'every run above is in the history, readable, stopped ones marked' {$h.Count -eq 31 -and @($h|Where-Object {$_.PSObject.Properties['Stopped'] -and $_.Stopped}).Count -eq 3 -and @($h|Where-Object {$_.Finished -isnot [datetime]}).Count -eq 0}
}finally{if(Test-Path -LiteralPath $root){[IO.Directory]::Delete($root,$true)}}
if($script:failed){Write-Output "$($script:failed) data tests FAILED.";exit 1}
Write-Output 'All data tests passed.'
