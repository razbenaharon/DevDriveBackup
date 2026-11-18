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
 Check 'speed is over the time the copy ran, not the whole run: 1.39 GB copied in 10 s of a 204 s run is 139 MB/s' {(Get-CenterRunSpeed ([pscustomobject]@{Kind='Mirror';CopiedBytes=1387789076;CopySeconds=10.0;Seconds=203.6})) -eq '139 MB/s'}
 Check 'an entry from before the copy time was recorded shows no speed' {(Get-CenterRunSpeed ([pscustomobject]@{Kind='Mirror';CopiedBytes=[long]50e9;Seconds=3600;Minutes=60})) -eq '' -and (Get-CenterRunSpeed ([pscustomobject]@{Kind='Mirror';CopiedBytes=629145600;Minutes=0.1})) -eq ''}
 Check 'no speed for small amounts, under a second, checks or repairs' {(Get-CenterRunSpeed ([pscustomobject]@{Kind='Mirror';CopiedBytes=5e6;CopySeconds=60})) -eq '' -and (Get-CenterRunSpeed ([pscustomobject]@{Kind='Mirror';CopiedBytes=[long]9e9;CopySeconds=0.5})) -eq '' -and (Get-CenterRunSpeed ([pscustomobject]@{Kind='MirrorCheck';CopiedBytes=[long]9e9;CopySeconds=60})) -eq '' -and (Get-CenterRunSpeed ([pscustomobject]@{Kind='MirrorRepair';CopiedBytes=[long]9e9;CopySeconds=60})) -eq '' -and (Get-CenterRunSpeed ([pscustomobject]@{Kind='Mirror';CopiedBytes=$null;CopySeconds=60})) -eq ''}
 Check 'versions show no speed: restic passes most files without reading them' {(Get-CenterRunSpeed ([pscustomobject]@{Kind='Versioned';CopiedBytes=871093093;ProcessedBytes=12547883974;Seconds=31.6})) -eq ''}

 # --- Progress of a running step ---
 $log="`t  *EXTRA File `t`t     360`tG:\M\a.txt`r`n`t    New File  `t`t    1000`tE:\a.txt`r`n`t    Newer     `t`t     500`tE:\b.txt`t    Changed   `t`t      20`tE:\c.txt`r`n               Total    Copied`r`n    Bytes :   99999   1520`r`n"
 Check 'copied files are counted from robocopy records, two on one line included; extras and totals are not' {$m=Measure-CenterCopyLog $log;$m.Files -eq 3 -and $m.Bytes -eq 1520}
 Check 'a running copy log is read in parts: a line still being written waits for the next look' {
  $fm=Join-Path $root 'fast-mirror';$run=Join-Path $fm '20261118-083353';New-Item -ItemType Directory -Path $run -Force|Out-Null
  $f=Join-Path $run 'copy-main.log';$enc=[Text.Encoding]::Unicode
  $first="`t    New File  `t`t    1000`tE:\a.txt`r`n`t    Newer     `t`t     5"
  [IO.File]::WriteAllBytes($f,$enc.GetPreamble()+$enc.GetBytes($first))
  $st=New-CenterCopyProgress (Get-Date).AddSeconds(-2) $fm;[void](Update-CenterCopyProgress $st);$a=$st.Bytes
  $fs=[IO.File]::Open($f,'Append');$b=$enc.GetBytes("00`tE:\b.txt`r`n");$fs.Write($b,0,$b.Length);$fs.Dispose()
  [void](Update-CenterCopyProgress $st);[void](Update-CenterCopyProgress $st)
  $a -eq 1000 -and $st.Bytes -eq 1500 -and $st.Files -eq 2 -and $st.Folder -eq $run
 }
 Check 'no run folder made since the step started: nothing is read' {$st=New-CenterCopyProgress (Get-Date).AddMinutes(5) (Join-Path $root 'fast-mirror');[void](Update-CenterCopyProgress $st);$null -eq $st.Folder -and $st.Bytes -eq 0}
 Check 'speed is over the last ten seconds, and nothing until two seconds have passed' {
  $st=New-CenterCopyProgress $now;$t=$now
  $r0=Add-CenterRateSample $st $t 0;$r1=Add-CenterRateSample $st $t.AddSeconds(1) 100e6;$r2=Add-CenterRateSample $st $t.AddSeconds(2) 200e6
  for($i=3;$i -le 20;$i++){$last=Add-CenterRateSample $st $t.AddSeconds($i) 200e6}   # copying stopped at 2 s
  $null -eq $r0 -and $null -eq $r1 -and $r2 -eq 100e6 -and $last -eq 0
 }
 $hist=@(
  [pscustomobject]@{SourceId='s';Kind='Mirror';Purpose='Backup';Finished=$now.AddDays(-9);Success=$true;Minutes=25.2}
  [pscustomobject]@{SourceId='s';Kind='Mirror';Finished=$now.AddDays(-6);Success=$true;Minutes=2.5}
  [pscustomobject]@{SourceId='s';Kind='Mirror';Purpose='Backup';Finished=$now.AddDays(-5);Success=$true;Seconds=192;Minutes=3.2}
  [pscustomobject]@{SourceId='s';Kind='Mirror';Purpose='Backup';Finished=$now.AddDays(-4);Success=$false;Seconds=5}
  [pscustomobject]@{SourceId='s';Kind='Mirror';Purpose='Backup';Finished=$now.AddDays(-3);Success=$true;Stopped=$true;Seconds=7}
  [pscustomobject]@{SourceId='s';Kind='MirrorCheck';Purpose='Verify';Finished=$now.AddDays(-2);Success=$true;Seconds=900}
  [pscustomobject]@{SourceId='s';Kind='Mirror';Purpose='Backup';Finished=$now.AddDays(-1);Success=$true;Seconds=204}
 )
 Check 'usual length: the middle of the last three runs that went through, of the same kind and purpose' {(Get-CenterUsualSeconds $hist ([pscustomobject]@{SourceId='s';Kind='Mirror';Purpose='Backup'})) -eq 192}
 Check 'a content check goes by earlier content checks, which the history names MirrorCheck' {(Get-CenterUsualSeconds $hist ([pscustomobject]@{SourceId='s';Kind='Mirror';Purpose='Verify'})) -eq 900}
 Check 'the run folder of the step before is not taken for this one' {
  $fm=Join-Path $root 'fast-mirror-before';$old=Join-Path $fm '20261118-090000';New-Item -ItemType Directory -Path $old -Force|Out-Null
  $st=New-CenterCopyProgress ((Get-Item -LiteralPath $old).CreationTime.AddSeconds(1)) $fm;[void](Update-CenterCopyProgress $st);$null -eq $st.Folder
 }
 Check 'no usual length for a step that never went through' {$null -eq (Get-CenterUsualSeconds $hist ([pscustomobject]@{SourceId='s';Kind='Versioned';Purpose='Backup'})) -and $null -eq (Get-CenterUsualSeconds @() ([pscustomobject]@{SourceId='s';Kind='Mirror';Purpose='Backup'}))}
 Check 'time left: the usual length minus what passed, weighted with the tool''s own guess by how far the tool is' {(Get-CenterStepLeft 60 200 $null $null) -eq 140 -and (Get-CenterStepLeft 10 30 0.25 40) -eq 25 -and (Get-CenterStepLeft 10 $null 0.25 40) -eq 40}
 Check 'time left: nothing to go by once a step takes longer than usual and the tool says nothing' {$null -eq (Get-CenterStepLeft 250 200 $null $null) -and $null -eq (Get-CenterStepLeft 10 $null $null $null) -and (Get-CenterStepLeft 250 200 0.9 12) -eq 12}
 Check 'time left reads in whole minutes, and under a minute is not counted in seconds' {(Format-CenterTimeLeft 20) -eq 'Less than a minute left.' -and (Format-CenterTimeLeft 61) -eq 'About 1 min left.' -and (Format-CenterTimeLeft 222) -eq 'About 4 min left.' -and (Format-CenterTimeLeft 7380) -eq 'About 2 h 3 min left.'}
 Check 'amounts copied are in MB and GB of a million and a billion bytes' {(Format-CenterBytes 1387789076) -eq '1.4 GB' -and (Format-CenterBytes 52e6) -eq '52 MB'}
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

 # --- Keep versions: the two numbers, and settings saved with the earlier three (days, weeks, months) ---
 $ret={param($v,$confirmed)$o=[ordered]@{Id='x';Name='n'};if($null -ne $v){$o.VersionRetention=$v};if($null -ne $confirmed){$o.RetentionConfirmed=$confirmed};[pscustomobject]$o}
 Check 'keep versions: the newest N and one a month for M months; both 0, or nothing set, keeps every version' {$r=Get-CenterVersionRetention (& $ret ([pscustomobject]@{Last=10;Months=6}));$r.Enabled -and $r.Last -eq 10 -and $r.Months -eq 6 -and -not (Get-CenterVersionRetention (& $ret ([pscustomobject]@{Last=0;Months=0}))).Enabled -and -not (Get-CenterVersionRetention (& $ret $null)).Enabled}
 Check 'numbers out of range are brought into it, and a value that is no setting at all keeps every version' {$r=Get-CenterVersionRetention (& $ret ([pscustomobject]@{Last=-4;Months=9999}));$r.Last -eq 0 -and $r.Months -eq 240 -and -not (Get-CenterVersionRetention (& $ret 'soon')).Enabled -and -not (Get-CenterVersionRetention (& $ret ([pscustomobject]@{Last='x';Months=$null}))).Enabled}
 Check 'a setting still in the earlier shape reads as 10 and 6 when it was on, and as off when it was off' {$r=Get-CenterVersionRetention (& $ret ([pscustomobject]@{Days=7;Weeks=0;Months=0}));$r.Last -eq 10 -and $r.Months -eq 6 -and -not (Get-CenterVersionRetention (& $ret ([pscustomobject]@{Days=0;Weeks=0;Months=0}))).Enabled}
 Check 'the overview names the rule briefly' {$f={param($l,$m)Format-CenterVersionRetention (Get-CenterVersionRetention (& $ret ([pscustomobject]@{Last=$l;Months=$m})))};(& $f 10 6) -eq '10 newest + 6 months' -and (& $f 0 0) -eq 'every version' -and (& $f 3 0) -eq '3 newest' -and (& $f 0 1) -eq '1 month' -and (& $f 1 1) -eq '1 newest + 1 month'}
 Check 'the three things the Keep versions box says, with the numbers chosen' {$t=@(Get-CenterRetentionPoints 10 6);$t.Count -eq 3 -and $t[0] -eq 'Up to 16 complete versions for each computer and set of folders (10 newest + 6 monthly). This is not a limit for the whole backup; partial versions can add to it.' -and $t[1] -eq 'A partial version is deleted once 3 complete versions are newer. That can remove content that exists only in it.' -and $t[2] -eq 'Deleting a version frees only the data no remaining version needs, after the clean-up; not the size the version had.' -and (Get-CenterRetentionPoints 4 0)[0] -like 'Up to 4 complete versions*(4 newest)*'}
 Check 'a clean-up is approved only when the profile says so: a new profile and one without the mark are not' {-not (Test-CenterRetentionConfirmed (& $ret $null $null)) -and -not (Test-CenterRetentionConfirmed (& $ret $null $false)) -and -not (Test-CenterRetentionConfirmed (& $ret $null 'yes')) -and (Test-CenterRetentionConfirmed (& $ret $null $true)) -and (Get-CenterRetentionState (& $ret $null $false)) -eq 'The first clean-up will be shown to you for approval.' -and (Get-CenterRetentionState (& $ret $null $true)) -eq 'Clean-up runs automatically.'}
 $q=& $ret ([pscustomobject]@{Last=10;Months=6}) $true
 Check 'saving the same numbers in the box keeps the approval; other numbers need a new one' {Set-CenterVersionRetention $q 10 6;$same=Test-CenterRetentionConfirmed $q;Set-CenterVersionRetention $q 5 6;$same -and -not (Test-CenterRetentionConfirmed $q) -and $q.VersionRetention.Last -eq 5 -and $q.VersionRetention.Months -eq 6 -and @($q.VersionRetention.PSObject.Properties).Count -eq 2}
 $conv=Join-Path $root 'conv';New-Item -ItemType Directory -Path $conv|Out-Null;[void](Set-CenterPaths $conv);$cp=(Get-CenterPaths).Profiles
 $mk={param($ret,$more='')'{"Version":1,"Profiles":[{"Id":"a","Name":"n","DestinationVolumeId":"v","ReminderDays":7,"KeepDeleted":3'+$(if($ret){',"VersionRetention":'+$ret})+$more+',"Sources":[]}]}'}
 $copies={@(Get-ChildItem -LiteralPath $conv -Filter 'profiles.before-retention-*.local.json'|Sort-Object Name)}
 $oldOn=& $mk '{"Days":7,"Weeks":4,"Months":3}';[IO.File]::WriteAllText($cp,$oldOn)
 $c=Read-CenterProfiles;$onDisk=[IO.File]::ReadAllText($cp)|ConvertFrom-Json
 Check 'earlier settings that deleted old versions become 10 newest and 6 months, in the window and in the file' {$v=$c.Profiles[0].VersionRetention;$w=$onDisk.Profiles[0].VersionRetention;$v.Last -eq 10 -and $v.Months -eq 6 -and $w.Last -eq 10 -and $w.Months -eq 6 -and -not $w.PSObject.Properties['Days'] -and -not $w.PSObject.Properties['Weeks'] -and $onDisk.Profiles[0].KeepDeleted -eq 3}
 Check 'the settings as they were are kept beside them under a dated name' {$k=& $copies;$k.Count -eq 1 -and $k[0].Name -match '^profiles\.before-retention-\d{8}-\d{6}\.local\.json$' -and [IO.File]::ReadAllText($k[0].FullName) -ceq $oldOn}
 Check 'a converted profile waits for its first clean-up to be approved' {$onDisk.Profiles[0].PSObject.Properties['RetentionConfirmed'] -and $onDisk.Profiles[0].RetentionConfirmed -eq $false -and -not (Test-CenterRetentionConfirmed $c.Profiles[0])}
 $after=[IO.File]::ReadAllText($cp);$stamp=[IO.File]::GetLastWriteTimeUtc($cp)
 Check 'the conversion happens once: reading again writes nothing' {$again=Read-CenterProfiles;$again.Profiles[0].VersionRetention.Last -eq 10 -and [IO.File]::ReadAllText($cp) -ceq $after -and [IO.File]::GetLastWriteTimeUtc($cp) -eq $stamp -and (& $copies).Count -eq 1}
 $oldOn2=& $mk '{"Days":0,"Weeks":2,"Months":0}';[IO.File]::WriteAllText($cp,$oldOn2);[void](Read-CenterProfiles)
 Check 'a copy made in the same second never takes the place of an earlier one' {$k=& $copies;$k.Count -eq 2 -and @($k|Where-Object {[IO.File]::ReadAllText($_.FullName) -ceq $oldOn}).Count -eq 1 -and @($k|Where-Object {[IO.File]::ReadAllText($_.FullName) -ceq $oldOn2}).Count -eq 1}
 & $copies|Remove-Item
 foreach($case in ([ordered]@{'earlier settings that kept every version (three zeros)'=(& $mk '{"Days":0,"Weeks":0,"Months":0}');'settings without Keep versions'=(& $mk '');'settings already in the new shape'=(& $mk '{"Last":4,"Months":2}' ',"RetentionConfirmed":true')}).GetEnumerator()){
  [IO.File]::WriteAllText($cp,$case.Value);$stamp=[IO.File]::GetLastWriteTimeUtc($cp);$c=Read-CenterProfiles
  Check "$($case.Key): the file is not written and no copy is made" {[IO.File]::ReadAllText($cp) -ceq $case.Value -and [IO.File]::GetLastWriteTimeUtc($cp) -eq $stamp -and (& $copies).Count -eq 0}
 }
 Check 'the new shape is read as it is, with its approval' {$r=Get-CenterVersionRetention $c.Profiles[0];$r.Last -eq 4 -and $r.Months -eq 2 -and (Test-CenterRetentionConfirmed $c.Profiles[0])}
 [IO.File]::WriteAllText($cp,(& $mk '{"Days":0,"Weeks":0,"Months":0}'));$c=Read-CenterProfiles
 Check 'earlier settings that kept every version still keep every version, and are saved in the new shape with the next change' {$on=(Get-CenterVersionRetention $c.Profiles[0]).Enabled;Save-CenterProfiles $c;$w=([IO.File]::ReadAllText($cp)|ConvertFrom-Json).Profiles[0].VersionRetention;-not $on -and $w.Last -eq 0 -and $w.Months -eq 0 -and -not $w.PSObject.Properties['Days'] -and (& $copies).Count -eq 0}
 $cut2=$oldOn.Substring(0,$oldOn.Length-9);[IO.File]::WriteAllText($cp,$cut2)
 Check 'damaged settings in the earlier shape are reported as damaged, left as they are, and no copy is made' {(Throws {Read-CenterProfiles} '*profiles.local.json*damaged*') -and [IO.File]::ReadAllText($cp) -ceq $cut2 -and (& $copies).Count -eq 0}
 [IO.File]::WriteAllText($cp,(& $mk '{"Last":10,"Months":6}'));$c=Read-CenterProfiles
 Check 'approving the clean-up is saved with the profile' {$before=Test-CenterRetentionConfirmed $c.Profiles[0];Confirm-CenterRetention $c 'a';-not $before -and (Test-CenterRetentionConfirmed (Read-CenterProfiles).Profiles[0]) -and (Throws {Confirm-CenterRetention $c 'gone'} '*')}
 $np=New-CenterProfile $c 'Fresh' 'VOL-FRESH' 'Model' 10
 Check 'a new profile keeps every version and has no approved clean-up' {-not (Get-CenterVersionRetention $np).Enabled -and $np.PSObject.Properties['RetentionConfirmed'] -and -not (Test-CenterRetentionConfirmed $np)}
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
 Check 'a source that has never run (a folder just added) gives no warning, no repair and no error' {-not @(Get-CenterRunWarnings $p2 @() $n).Count -and -not @(Get-CenterRunWarnings $p2 @(& $R $f1.Id 'Mirror' $true $n.AddMinutes(-5)) $n).Count -and -not (Get-CenterRepairState @() $f2.Id).Needed}
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
  # Keep versions and Keep deleted: what the tools are told, and that nothing is deleted before the first approval.
  $arg={param($st,$kind)@(@($st|Where-Object {$_.Kind -eq $kind})[0].Arguments)};$val={param($a,$n)$a[[array]::IndexOf($a,$n)+1]}
  $b=@(Get-CenterSteps $p2 @() 'Backup')
  Check 'by default every version is kept and deleted files stay in the plain copy' {-not @($b|Where-Object {@($_.Arguments|Where-Object {$_ -in '-KeepLast','-KeepMonths','-RetentionPreview','-MoveExtras','-PreviewRecovery'}).Count}).Count}
  $p2|Add-Member -NotePropertyName VersionRetention -NotePropertyValue ([pscustomobject]@{Last=10;Months=6}) -Force;$p2|Add-Member -NotePropertyName KeepDeleted -NotePropertyValue 5 -Force
  $b=@(Get-CenterSteps $p2 @() 'Backup');$va=& $arg $b 'Versioned';$ma=& $arg $b 'Mirror'
  Check 'Keep versions hands the two numbers to a versioned backup, never days or weeks' {(& $val $va '-KeepLast') -eq '10' -and (& $val $va '-KeepMonths') -eq '6' -and '-KeepDays' -notin $va -and '-KeepWeeks' -notin $va}
  Check 'before the first clean-up is approved, versions are only planned and old recovery folders are not deleted' {'-RetentionPreview' -in $va -and '-PreviewRecovery' -in $ma -and '-MoveExtras' -in $ma -and (& $val $ma '-KeepRecovery') -eq '5' -and @($b|Where-Object {$_.Kind -eq 'Mirror' -and '-PreviewRecovery' -in $_.Arguments}).Count -eq 2}
  Check 'a content check and a repair are never told to keep, delete or preview anything' {-not @(@(Get-CenterSteps $p2 @() 'Verify')+@(Get-CenterSteps $p2 @() 'Repair')|Where-Object {@($_.Arguments|Where-Object {$_ -in '-KeepLast','-KeepMonths','-RetentionPreview','-MoveExtras','-KeepRecovery','-PreviewRecovery'}).Count}).Count}
  $p2|Add-Member -NotePropertyName RetentionConfirmed -NotePropertyValue $true -Force
  $b=@(Get-CenterSteps $p2 @() 'Backup');$va=& $arg $b 'Versioned';$ma=& $arg $b 'Mirror'
  Check 'once approved, the same rule runs without the preview' {'-RetentionPreview' -notin $va -and '-PreviewRecovery' -notin $ma -and (& $val $va '-KeepLast') -eq '10' -and (& $val $ma '-KeepRecovery') -eq '5'}
  $p2.VersionRetention=[pscustomobject]@{Last=3;Months=0};$p2.KeepDeleted=0;$p2.RetentionConfirmed=$false
  $b=@(Get-CenterSteps $p2 @() 'Backup');$va=& $arg $b 'Versioned'
  Check 'one of the two numbers alone is a rule too; with Keep deleted off the plain copy previews nothing' {(& $val $va '-KeepLast') -eq '3' -and (& $val $va '-KeepMonths') -eq '0' -and '-RetentionPreview' -in $va -and '-PreviewRecovery' -notin (& $arg $b 'Mirror')}
  $p2.VersionRetention=[pscustomobject]@{Last=0;Months=0}
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
 function Invoke-Fake([string]$Command,[string]$Kind='Mirror',[string]$Purpose='Backup',[switch]$Stop,[string]$RunDirectory,[hashtable]$More=@{}){
  # -More: what Get-CenterSteps notes on a step beside its arguments (KeepDeleted, RetentionPhase, NewRepository...).
  $step=[pscustomobject]@{SourceId='s';Label='L';Kind=$Kind;Purpose=$Purpose;FilePath=$pw;Arguments=@('-NoProfile','-Command',$Command);RunDirectory=$RunDirectory;Priority='BelowNormal'}
  foreach($k in $More.Keys){$step|Add-Member -NotePropertyName $k -NotePropertyValue $More[$k] -Force}
  $r=Start-CenterStep $step (Join-Path $root 'step.log')
  if($Stop){Start-Sleep -Milliseconds 1500;$r.Process.Kill($true);Complete-CenterStep $r 'p' -Stopped}else{Complete-CenterStep $r 'p'}
 }
 $json='{"RunFolder":"X","CopyErrors":0,"Runs":[{"Files":"Files : 10 3 7 0 0 0","Bytes":"Bytes : 5000 629145600 0 0 0 0"}],"Verify":{"FilesMatched":10,"Differences":0}}'
 $e=Invoke-Fake "Write-Output '$json'"
 Check 'a plain copy: files and bytes copied, files checked, exact seconds' {$e.Success -and $e.Kind -eq 'Mirror' -and $e.CopiedFiles -eq 3 -and $e.CopiedBytes -eq 629145600 -and $e.CheckedFiles -eq 10 -and $e.Seconds -gt 0 -and $e.Seconds -lt 60 -and $null -ne $e.Minutes}
 $e=Invoke-Fake "Write-Output 'WARNING: skipped {temp} folder';Write-Output '$json'"
 Check 'a line with a brace before the result does not fail the plain copy' {$e.Success -and $e.CopiedFiles -eq 3}
 Check 'a result from a tool that did not time its runs records no copy time' {$null -eq $e.CopySeconds}
 $timed='{"RunFolder":"X","CopyErrors":0,"Runs":[{"Files":"Files : 9 2 7 0 0 0","Bytes":"Bytes : 9 600000000 0 0 0 0","Seconds":8.4},{"Files":"Files : 99 0 99 0 0 0","Bytes":"Bytes : 99 0 99 0 0 0","Seconds":70},{"Files":"Files : 5 1 4 0 0 0","Bytes":"Bytes : 5 1000 4 0 0 0","Seconds":1.6}]}'
 $e=Invoke-Fake "Write-Output '$timed'"
 Check 'copy time is the time of the runs that copied something; a run that only compared files is left out' {$e.CopiedBytes -eq 600001000 -and $e.CopySeconds -eq 10 -and (Get-CenterRunSpeed $e) -eq '60 MB/s'}
 $e=Invoke-Fake ("Write-Output '"+$timed.Replace(',"Seconds":1.6','')+"'")
 Check 'a run that copied something but has no time leaves the copy time unknown' {$e.CopiedBytes -eq 600001000 -and $null -eq $e.CopySeconds -and (Get-CenterRunSpeed $e) -eq ''}
 $e=Invoke-Fake ("Write-Output '"+$json.Replace('Files : 10 3 7 0 0 0','').Replace('Bytes : 5000 629145600 0 0 0 0','')+"'")
 Check 'totals that could not be read are recorded as unknown, not as 0 files' {$e.Success -and $null -eq $e.CopiedFiles -and $null -eq $e.CopiedBytes -and $null -eq $e.CopySeconds}
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
 # The clean-up of old versions: what was deleted, and the preview before the first approval.
 $retJson={param($r)[IO.File]::WriteAllText((Join-Path $rd 'result.json'),'{"State":"Completed","Retention":'+$r+'}');Invoke-Fake 'exit 0' -Kind Versioned -RunDirectory $rd}
 $e=& $retJson '{"Preview":false,"Last":10,"Months":6,"Removed":3,"PartialRemoved":1,"Kept":12,"Candidates":[],"Error":null}'
 Check 'a clean-up says how many versions it deleted, how many of them were partial, and how many stay' {$e.Success -and $e.Note -eq 'Deleted 3 old versions (1 partial); 12 kept.' -and $null -eq $e.RetentionPreview}
 $e=& $retJson '{"Removed":1,"PartialRemoved":0,"Kept":16,"SpaceFreed":true}'
 Check 'one version is one version, and no freed size is claimed without a number for it' {$e.Note -eq 'Deleted 1 old version; 16 kept.' -and $e.Note -notlike '*freed*'}
 $e=& $retJson '{"Removed":2,"PartialRemoved":2,"Kept":16,"PrunedBytes":1610612736}'
 Check 'a freed size is said only from the number the clean-up reports' {$e.Note -eq 'Deleted 2 old versions (2 partial); 16 kept. The clean-up freed 1.5 GB.'}
 $e=& $retJson '{"Removed":0,"PartialRemoved":0,"Kept":7,"PrunedBytes":0}'
 Check 'nothing to delete is said as that' {$e.Note -eq 'No old versions to delete; 7 kept.'}
 $e=& $retJson '{"Removed":1,"Kept":9,"Error":"The drive was disconnected"}'
 Check 'a clean-up that did not finish says what it did delete' {$e.Success -and $e.Note -like 'Deleted 1 old version; 9 kept, but the clean-up did not finish: The drive was disconnected'}
 $cand='[{"Id":"abc12345","Time":"2026-03-01T10:15:00","Partial":false,"Host":"PC","Paths":["E:\\Projects"]},{"Id":"def67890","Time":"2026-02-01T09:30:00","Partial":true,"Host":"PC","Paths":["E:\\Projects","E:\\Docs"]}]'
 $ev=& $retJson ('{"Preview":true,"Last":10,"Months":6,"Kept":12,"Removed":0,"PartialRemoved":0,"Candidates":'+$cand+',"Error":null}')
 Check 'a preview puts the versions that would be deleted on the history entry and says that nothing was deleted' {$ev.Success -and @($ev.RetentionPreview.Versions).Count -eq 2 -and $ev.RetentionPreview.Versions[1].Partial -and $ev.RetentionPreview.Versions[0].Id -eq 'abc12345' -and @($ev.RetentionPreview.RecoveryFolders).Count -eq 0 -and $ev.Note -eq 'The clean-up would delete 2 old versions (1 partial); 12 would be kept. Nothing was deleted.' -and $ev.Note -notlike 'Deleted*'}
 $e=& $retJson '{"Preview":true,"Last":10,"Months":6,"Kept":4,"Removed":0,"PartialRemoved":0,"Candidates":[],"Error":null}'
 Check 'a preview with nothing to delete adds nothing to the entry and no note' {$e.Success -and $null -eq $e.RetentionPreview -and -not $e.Note}
 $e=& $retJson '{"Preview":true,"Kept":null,"Removed":0,"Candidates":[],"Error":"The list of versions could not be read"}'
 Check 'a preview that could not be made says so and lists nothing' {$e.Success -and $null -eq $e.RetentionPreview -and $e.Note -eq 'Backed up, but the clean-up of old versions could not be planned: The list of versions could not be read'}
 $e=& $retJson ('{"Preview":false,"Removed":0,"Kept":3,"Candidates":'+$cand+'}')
 Check 'candidates of a run that was no preview are not offered for approval' {$null -eq $e.RetentionPreview}
 $em=Invoke-Fake ("Write-Output '"+$json.Replace('"Verify":{','"RecoveryWouldRemove":["2026-01-02_101500","2026-01-09_101500"],"Verify":{')+"'")
 Check 'a plain copy lists the recovery folders it would have deleted, and says that it deleted none' {$em.Success -and @($em.RetentionPreview.RecoveryFolders).Count -eq 2 -and $em.RetentionPreview.RecoveryFolders[0] -eq '2026-01-02_101500' -and @($em.RetentionPreview.Versions).Count -eq 0 -and $em.Note -like '*2 older recovery folders would be deleted (2026-01-02_101500, 2026-01-09_101500). Nothing was deleted.*'}
 $e=Invoke-Fake ("Write-Output '"+$json.Replace('"Verify":{','"RecoveryWouldRemove":[],"Verify":{')+"'")
 Check 'a plain copy with no recovery folder to delete lists none' {$e.Success -and $null -eq $e.RetentionPreview -and -not $e.Note}
 # The list may be approved only when it is the whole list: every part of every source was backed up
 # in this run and each plan was made. Approval counts for the whole drive, so a list that leaves a
 # source out, or one whose plan failed, must not be offered.
 $two=@([pscustomobject]@{SourceId='s1';Kind='Mirror'},[pscustomobject]@{SourceId='s1';Kind='Versioned'},[pscustomobject]@{SourceId='s2';Kind='Versioned'})
 $part={param($sid,$kind,$more=@{})$h=@{SourceId=$sid;Kind=$kind;Success=$true;Stopped=$false;RetentionPlanFailed=$false};foreach($k in $more.Keys){$h[$k]=$more[$k]};[pscustomobject]$h}
 Check 'a list from a run of every source, all planned, is the whole list' {Test-CenterRetentionPreviewWhole $two @((& $part 's1' 'Mirror'),(& $part 's1' 'Versioned'),(& $part 's2' 'Versioned'))}
 Check 'a list from a run of one source only is not offered for approval' {-not (Test-CenterRetentionPreviewWhole $two @((& $part 's1' 'Mirror'),(& $part 's1' 'Versioned')))}
 Check 'nor when a step failed or was stopped' {-not (Test-CenterRetentionPreviewWhole $two @((& $part 's1' 'Mirror'),(& $part 's1' 'Versioned' @{Success=$false}),(& $part 's2' 'Versioned'))) -and -not (Test-CenterRetentionPreviewWhole $two @((& $part 's1' 'Mirror' @{Stopped=$true}),(& $part 's1' 'Versioned'),(& $part 's2' 'Versioned')))}
 Check 'nor when the clean-up of one source could not be planned' {-not (Test-CenterRetentionPreviewWhole $two @((& $part 's1' 'Mirror'),(& $part 's1' 'Versioned'),(& $part 's2' 'Versioned' @{RetentionPlanFailed=$true})))}
 Check 'entries without the newer fields, or nothing to compare with, are never the whole list' {-not (Test-CenterRetentionPreviewWhole $two @([pscustomobject]@{SourceId='s1';Kind='Mirror';Success=$true},[pscustomobject]@{SourceId='s1';Kind='Versioned';Success=$true},[pscustomobject]@{SourceId='s2';Kind='Versioned';Success=$true})) -and -not (Test-CenterRetentionPreviewWhole @() @()) -and -not (Test-CenterRetentionPreviewWhole $two $null)}
 $ef=& $retJson '{"Preview":true,"Kept":null,"Removed":0,"Candidates":[],"Error":"The list of versions could not be read"}'
 Check 'a preview that could not be made is marked on the entry, and one that was made is not' {$ef.RetentionPlanFailed -eq $true -and $ev.RetentionPlanFailed -eq $false -and $em.RetentionPlanFailed -eq $false}
 $none=Get-CenterRetentionPreview @($e,[pscustomobject]@{Label='x';Success=$false},$null)
 Check 'a run without candidates has nothing to approve' {$none.Count -eq 0 -and @($none.Versions).Count -eq 0 -and @($none.RecoveryFolders).Count -eq 0 -and -not (Format-CenterRetentionPreview $none 10 6)}
 $pv=Get-CenterRetentionPreview @($ev,$em,$e)
 Check 'the candidates of every step of a run are collected, each with the name of its source' {$pv.Count -eq 4 -and @($pv.Versions).Count -eq 2 -and @($pv.RecoveryFolders).Count -eq 2 -and $pv.Versions[0].Label -eq 'L' -and $pv.RecoveryFolders[1].Name -eq '2026-01-09_101500' -and $pv.Versions[0].Time -is [datetime]}
 $text=Format-CenterRetentionPreview $pv 10 6
 Check 'the preview lists each version with its date and time, marks partial ones and names the folders' {$text -like '*1 Feb 2026, 09:30, partial*E:\Projects, E:\Docs*' -and $text -like '*1 Mar 2026, 10:15*E:\Projects*' -and $text -notlike '*1 Mar 2026, 10:15, partial*'}
 Check 'it lists the recovery folders, says that nothing was deleted yet and what approving does' {$text -like '*2026-01-02_101500*2026-01-09_101500*' -and $text -like '*Nothing has been deleted yet.*' -and $text -like '*next backup*'}
 Check 'a recovery folder named by the tool is shown with its date and time' {(Format-CenterRetentionPreview (Get-CenterRetentionPreview @([pscustomobject]@{Label='L';SourceId='s';RetentionPreview=[pscustomobject]@{Versions=@();RecoveryFolders=@('20260314-093000')}})) 10 6) -like '*- L: 14 Mar 2026, 09:30 (20260314-093000)*'}
 Check 'it carries the three explanations, with the numbers of this profile' {$t=@(Get-CenterRetentionPoints 10 6);$text.Contains($t[0]) -and $text.Contains($t[1]) -and $text.Contains($t[2])}
 $text=Format-CenterRetentionPreview (Get-CenterRetentionPreview @($em)) 10 6
 Check 'with recovery folders only, the explanations about versions are left out' {$text -like '*2026-01-02_101500*' -and $text -like '*Nothing has been deleted yet.*' -and $text -notlike '*partial*' -and $text -notlike '*complete versions*'}
 $one=$ev.RetentionPreview.Versions[0];$text=Format-CenterRetentionPreview (Get-CenterRetentionPreview @([pscustomobject]@{Label='L';SourceId='s';RetentionPreview=[pscustomobject]@{Versions=@($one);RecoveryFolders=@()}})) 10 6
 Check 'without a partial version in the list, the sentence about partial versions is left out' {$text -notlike '*A partial version is deleted*' -and $text -like '*Deleting a version frees only*'}
 $many=Get-CenterRetentionPreview @([pscustomobject]@{Label='L';SourceId='s';RetentionPreview=[pscustomobject]@{Versions=@(1..30|ForEach-Object {[pscustomobject]@{Id="v$_";Time=([datetime]'2026-01-01').AddDays($_).ToString('o');Partial=$false;Host='PC';Paths=@('E:\P')}});RecoveryFolders=@(1..30|ForEach-Object {"2025-01-{0:d2}" -f $_})}})
 Check 'a long list is shortened and says how many more there are' {$t=Format-CenterRetentionPreview $many 10 6;$many.Count -eq 60 -and $t -like '*and 20 more versions*' -and $t -like '*and 24 more*' -and @($t -split "`n").Count -lt 45}
 Check 'the shortened question says where the full list is' {(Format-CenterRetentionPreview $many 10 6) -like '*Show the full list*all 60 items*'}
 $listText=Format-CenterRetentionList $many
 $fullLines=@($listText -split "`n")
 Check 'the full list names every item the clean-up would delete, each once, with its ID or folder name' {@(1..30|Where-Object {$n=$_;@($fullLines|Where-Object {$_ -match "\(v$n\)$"}).Count -ne 1}).Count -eq 0 -and @(1..30|Where-Object {$n='2025-01-{0:d2}' -f $_;@($fullLines|Where-Object {$_.EndsWith($n)}).Count -ne 1}).Count -eq 0}
 Check 'it says how many there are and that nothing is deleted yet, and has no "more" line' {$listText -like '*Old versions (30)*Recovery folders*(30)*' -and $listText -like '*Nothing has been deleted yet*' -and $listText -notlike '*more versions*' -and $listText -notlike '*and 24 more*'}
 Check 'the full list of a short preview holds what the question shows' {$t=Format-CenterRetentionList $pv;$t -like '*1 Feb 2026, 09:30, partial*E:\Projects, E:\Docs*' -and $t -like '*2026-01-02_101500*2026-01-09_101500*' -and -not (Format-CenterRetentionList $none)}
 Check 'a long version ID is shown by its first 8 characters, as the history shows it' {(Format-CenterRetentionList (Get-CenterRetentionPreview @([pscustomobject]@{Label='L';SourceId='s';RetentionPreview=[pscustomobject]@{Versions=@([pscustomobject]@{Id=('ab12'*16);Time='2026-01-05T10:00:00';Partial=$false;Host='PC';Paths=@('E:\P')});RecoveryFolders=@()}}))) -like '*(ab12ab12)*'}
 $h=@(Get-CenterHistory)
 Check 'every run above is in the history, readable, stopped ones marked' {$h.Count -eq 45 -and @($h|Where-Object {$_.PSObject.Properties['Stopped'] -and $_.Stopped}).Count -eq 3 -and @($h|Where-Object {$_.Finished -isnot [datetime]}).Count -eq 0}

 # --- The settings file was damaged, removed or changed on disk after this window read it ---
 # A save never writes over what it does not know: the file on disk is kept aside under a dated name,
 # the settings in memory are saved as the new file, and only that new file becomes the last good copy.
 $sv=Join-Path $root 'save';New-Item -ItemType Directory -Path $sv|Out-Null;[void](Set-CenterPaths $sv);$sp=(Get-CenterPaths).Profiles;$sg=Join-Path $sv 'profiles.lastgood.local.json'
 $aside={param($kind)@(Get-ChildItem -LiteralPath $sv -Filter "profiles.$kind-*.local.json"|Sort-Object Name)}
 $sameBytes={param($a,$b)[Linq.Enumerable]::SequenceEqual([byte[]][IO.File]::ReadAllBytes($a),[byte[]][IO.File]::ReadAllBytes($b))}
 $sd=Read-CenterProfiles;$sq=New-CenterProfile $sd 'Saved' 'VOL-SAVE' 'Model' 10;Save-CenterProfiles $sd
 Check 'an ordinary save reports nothing and keeps nothing aside' {$sr=Get-CenterSaveReport;-not $sr.What -and -not $sr.KeptAs -and -not $sr.Message -and -not (& $aside 'damaged').Count -and -not (& $aside 'changed').Count -and (& $sameBytes $sg $sp)}
 [IO.File]::WriteAllText($sp,$cut);$sq.Name='After damage';$goodBefore=[IO.File]::ReadAllBytes($sg)
 $held=[IO.File]::Open($sp,'Open','Read','Read')
 try{Check 'a damaged file that cannot be moved aside is not written over: the save fails, and the file and the last good copy stay as they are' {(Throws {Save-CenterProfiles $sd} '*not saved*') -and [IO.File]::ReadAllText($sg) -ceq [Text.Encoding]::UTF8.GetString($goodBefore) -and -not (& $aside 'damaged').Count}}finally{$held.Dispose()}
 Check 'and the damaged file is still there, unchanged' {[IO.File]::ReadAllText($sp) -ceq $cut}
 Save-CenterProfiles $sd;$sr=Get-CenterSaveReport
 Check 'a settings file damaged on disk after it was read is kept aside under a dated name, unchanged' {$k=& $aside 'damaged';$sr.What -eq 'Damaged' -and $k.Count -eq 1 -and $sr.KeptAs -eq $k[0].FullName -and $k[0].Name -match '^profiles\.damaged-\d{8}-\d{6}\.local\.json$' -and [IO.File]::ReadAllText($k[0].FullName) -ceq $cut}
 Check 'the settings of the window are saved as the new file, and the save says what happened' {(Read-CenterProfiles).Profiles[0].Name -eq 'After damage' -and $sr.Message -like 'The settings file had been damaged outside DevDriveBackup; it was kept as profiles.damaged-*.local.json and the settings were saved again.'}
 Check 'after a damaged file the last good copy is the newly saved file, byte for byte' {& $sameBytes $sg $sp}
 [IO.File]::WriteAllText($sp,'');$sq.Name='After empty';Save-CenterProfiles $sd
 Check 'a second damaged file gets a name of its own beside the first' {$k=& $aside 'damaged';$k.Count -eq 2 -and @($k|Where-Object {[IO.File]::ReadAllText($_.FullName) -ceq $cut}).Count -eq 1 -and @($k|Where-Object {[IO.File]::ReadAllText($_.FullName) -ceq ''}).Count -eq 1 -and (& $sameBytes $sg $sp)}
 Remove-Item -LiteralPath $sp;$sq.Name='After missing';Save-CenterProfiles $sd;$sr=Get-CenterSaveReport
 Check 'a settings file that is gone from the disk is saved again, and the save says so' {$sr.What -eq 'Missing' -and -not $sr.KeptAs -and $sr.Message -like '*was missing*saved again*' -and (Read-CenterProfiles).Profiles[0].Name -eq 'After missing' -and (& $aside 'damaged').Count -eq 2 -and (& $sameBytes $sg $sp)}
 $edited='{"Version":1,"Profiles":[{"Id":"zz","Name":"Edited elsewhere","DestinationVolumeId":"VOL-OTHER","ReminderDays":7,"Sources":[]}]}'
 [IO.File]::WriteAllText($sp,$edited);$sq.Name='After change';Save-CenterProfiles $sd;$sr=Get-CenterSaveReport
 Check 'a valid file that was changed outside this window is kept aside too, unchanged, before the save' {$k=& $aside 'changed';$sr.What -eq 'Changed' -and $k.Count -eq 1 -and $sr.KeptAs -eq $k[0].FullName -and $k[0].Name -match '^profiles\.changed-\d{8}-\d{6}\.local\.json$' -and [IO.File]::ReadAllText($k[0].FullName) -ceq $edited}
 Check 'the window''s settings are saved, the save names the copy, and the last good copy is the saved file' {(Read-CenterProfiles).Profiles[0].Name -eq 'After change' -and $sr.Message -like 'The settings file had been changed outside DevDriveBackup; that version was kept as profiles.changed-*.local.json and the settings of this window were saved.' -and (& $sameBytes $sg $sp)}
 [IO.File]::WriteAllText($sp,$edited);$sd=Read-CenterProfiles;$sd.Profiles[0].Name='Read again';Save-CenterProfiles $sd
 Check 'a file changed elsewhere and then read again by this window (Refresh) is saved over as usual, without a copy' {-not (Get-CenterSaveReport).What -and (& $aside 'changed').Count -eq 1 -and (Read-CenterProfiles).Profiles[0].Name -eq 'Read again' -and (& $sameBytes $sg $sp)}
 Check 'saves are numbered, so what one save found is told once' {$a=(Get-CenterSaveReport).Number;Save-CenterProfiles $sd;(Get-CenterSaveReport).Number -eq $a+1}
 Check 'a save right after a save, or after reading, reports nothing' {Save-CenterProfiles $sd;$a=(Get-CenterSaveReport).What;$sd=Read-CenterProfiles;Save-CenterProfiles $sd;-not $a -and -not (Get-CenterSaveReport).What -and (& $aside 'changed').Count -eq 1 -and (& $aside 'damaged').Count -eq 2}
 [void](Set-CenterPaths $data)

 # --- Adding a folder that was backed up to this drive before: asked first, two ways to go on ---
 $rf=(New-Item -ItemType Directory -Path (Join-Path $src 'Again')).FullName
 $o=Add-CenterSource -Data $d -ProfileId $p.Id -Path $rf -Label 'Again' -DefaultMode Both
 Check 'a folder that is a source now, or never was one, has no earlier settings to ask about' {$null -eq (Find-CenterEarlierSource -Data $d -ProfileId $p.Id -Path $rf) -and $null -eq (Find-CenterEarlierSource -Data $d -ProfileId $p.Id -Path (Join-Path $src 'Never'))}
 Remove-CenterSource $d $p.Id $o.Id
 $m=Find-CenterEarlierSource -Data $d -ProfileId $p.Id -Path ($rf.ToUpperInvariant()+'\')
 Check 'a removed folder is found again, with its plain copy folder, versions folder and mode' {$m -and $m.ConfigPath -eq $o.ConfigPath -and $m.MirrorFolder -eq 'Again-Mirror' -and $m.RepositoryFolder -eq 'Again-Versions' -and $m.DefaultMode -eq 'Both'}
 $oldJob=[IO.File]::ReadAllBytes($o.ConfigPath);$oldTime=[IO.File]::GetLastWriteTimeUtc($o.ConfigPath);$oldKey=[string](Read-CenterJob $o.ConfigPath).PasswordDpapiPath
 $nf=Add-CenterSource -Data $d -ProfileId $p.Id -Path $rf -Label 'Again' -DefaultMode Mirror -Earlier Fresh
 Check 'Start fresh: a new job with the mode chosen now, and a plain copy folder and versions folder with new names' {$j=Read-CenterJob $nf.ConfigPath;$nf.ConfigPath -ne $o.ConfigPath -and $nf.MirrorFolder -ine 'Again-Mirror' -and [string]$j.RepositoryFolder -ine 'Again-Versions' -and [string]$j.RepositoryFolder -like 'Again-*-Versions' -and $j.DefaultMode -eq 'Mirror' -and $j.MirrorFolder -eq $nf.MirrorFolder -and [string]$j.PasswordDpapiPath -ne $oldKey}
 Check 'Start fresh never touches the earlier job file' {[Linq.Enumerable]::SequenceEqual([byte[]][IO.File]::ReadAllBytes($o.ConfigPath),[byte[]]$oldJob) -and [IO.File]::GetLastWriteTimeUtc($o.ConfigPath) -eq $oldTime}
 $rf2=(New-Item -ItemType Directory -Path (Join-Path $src 'Again2')).FullName
 $o2=Add-CenterSource -Data $d -ProfileId $p.Id -Path $rf2 -Label 'Again2' -DefaultMode Both;Remove-CenterSource $d $p.Id $o2.Id
 Check 'Use the earlier settings (and a caller that does not ask) continues the earlier backup, as before' {$a=Add-CenterSource -Data $d -ProfileId $p.Id -Path $rf2 -Label 'Typed' -DefaultMode Mirror -Earlier Restore;$a.ConfigPath -eq $o2.ConfigPath -and $a.MirrorFolder -eq 'Again2-Mirror' -and (Read-CenterJob $a.ConfigPath).DefaultMode -eq 'Both' -and $a.Label -eq 'Typed'}
 # The versions and recovery folders of an earlier backup were never shown in a list. Continuing it on a
 # drive whose clean-up runs by the rule would delete them unseen, so its first clean-up is shown again.
 $wasConfirmed=Test-CenterRetentionConfirmed $p
 try{
  $rf3=(New-Item -ItemType Directory -Path (Join-Path $src 'Again3')).FullName
  $o3=Add-CenterSource -Data $d -ProfileId $p.Id -Path $rf3 -Label 'Again3' -DefaultMode Both;Remove-CenterSource $d $p.Id $o3.Id
  $p|Add-Member -NotePropertyName RetentionConfirmed -NotePropertyValue $true -Force
  $p|Add-Member -NotePropertyName RetentionApproved -NotePropertyValue ([pscustomobject]@{When=(Get-Date).ToString('o');Last=10;Months=6;KeepDeleted=5;Versions=@();RecoveryFolders=@()}) -Force
  $a3=Add-CenterSource -Data $d -ProfileId $p.Id -Path $rf3 -Label 'Again3' -DefaultMode Both -Earlier Restore
  Check 'continuing an earlier backup of this drive has the first clean-up shown again: an approval or a list approved before are dropped' {$a3.ConfigPath -eq $o3.ConfigPath -and -not (Test-CenterRetentionConfirmed $p) -and -not $p.PSObject.Properties['RetentionApproved'] -and (Get-CenterRetentionState $p) -eq 'The first clean-up will be shown to you for approval.'}
  $p|Add-Member -NotePropertyName RetentionConfirmed -NotePropertyValue $true -Force
  $rf4=(New-Item -ItemType Directory -Path (Join-Path $src 'Brand-new')).FullName
  [void](Add-CenterSource -Data $d -ProfileId $p.Id -Path $rf4 -Label 'Brand new' -DefaultMode Both)
  $o5=Add-CenterSource -Data $d -ProfileId $p.Id -Path (New-Item -ItemType Directory -Path (Join-Path $src 'Again5')).FullName -Label 'Again5' -DefaultMode Both;Remove-CenterSource $d $p.Id $o5.Id
  [void](Add-CenterSource -Data $d -ProfileId $p.Id -Path $o5.Path -Label 'Again5' -DefaultMode Both -Earlier Fresh)
  Check 'a folder that starts a new backup (never a source, or Start fresh) keeps the approval: it has nothing old to delete' {Test-CenterRetentionConfirmed $p}
 }finally{$p|Add-Member -NotePropertyName RetentionConfirmed -NotePropertyValue $wasConfirmed -Force;[void](Remove-CenterRetentionApproved $p)}

 # --- The size the window opens with ---
 Check 'a screen with room opens the window at its full size' {$f=Get-CenterWindowFit 1200 800 1904 1040;$f.Factor -eq 1 -and $f.Width -eq 1200 -and $f.Height -eq 800}
 Check 'a smaller screen gets the largest size that fits, in proportion' {$f=Get-CenterWindowFit 1200 800 1350 720;$f.Factor -eq 0.9 -and $f.Width -eq 1080 -and $f.Height -eq 720}
 Check 'never below 80%, also on a screen smaller than that' {$f=Get-CenterWindowFit 1200 800 800 600;$f.Factor -eq 0.8 -and $f.Width -eq 960 -and $f.Height -eq 640}

 # --- The first clean-up deletes only what was shown and approved ---
 # (F1 uses plain copy and versions, F2 the plain copy only; the system drive stands in for the backup drive.)
 $realId=$p2.DestinationVolumeId;$p2.DestinationVolumeId=(Get-Volume -DriveLetter $env:SystemDrive.Substring(0,1)).UniqueId
 try{
  $p2.RetentionConfirmed=$false;Set-CenterVersionRetention $p2 10 6;Set-CenterKeepDeleted $p2 5
  $shown=Get-CenterRetentionPreview @(
   [pscustomobject]@{Label='F1';SourceId=$f1.Id;RetentionPreview=[pscustomobject]@{Versions=@([pscustomobject]@{Id='aaaa1111';Time='2026-03-01T10:15:00'},[pscustomobject]@{Id='bbbb2222';Time='2026-02-01T09:30:00'});RecoveryFolders=@()}}
   [pscustomobject]@{Label='F1';SourceId=$f1.Id;RetentionPreview=[pscustomobject]@{Versions=@();RecoveryFolders=@('20260102-101500','20260109-101500')}})
  Check 'a profile that waits for its first list says so' {(Get-CenterRetentionState $p2) -eq 'The first clean-up will be shown to you for approval.' -and $null -eq (Get-CenterRetentionApproved $p2)}
  Set-CenterRetentionApproved $d $p2.Id $shown;$ap=Get-CenterRetentionApproved $p2
  Check 'approving stores exactly what was shown, with the rule it was shown for, and does not confirm the profile' {$ap -and -not (Test-CenterRetentionConfirmed $p2) -and $ap.Last -eq 10 -and $ap.Months -eq 6 -and $ap.KeepDeleted -eq 5 -and (ConvertTo-CenterTime $ap.When) -and @($ap.Versions).Count -eq 1 -and $ap.Versions[0].SourceId -eq $f1.Id -and (@($ap.Versions[0].Ids) -join ',') -eq 'bbbb2222,aaaa1111' -and @($ap.RecoveryFolders).Count -eq 1 -and $ap.RecoveryFolders[0].SourceId -eq $f1.Id -and (@($ap.RecoveryFolders[0].Names) -join ',') -eq '20260102-101500,20260109-101500'}
  Check 'the approved list is saved with the profile, and the profile says what happens next' {$q=@((Read-CenterProfiles).Profiles|Where-Object {$_.Id -eq $p2.Id})[0];@($q.RetentionApproved.Versions[0].Ids).Count -eq 2 -and $q.RetentionConfirmed -eq $false -and (Get-CenterRetentionState $p2) -eq 'The clean-up you approved runs with the next backup.'}
  $b=@(Get-CenterSteps $p2 @() 'Backup');$va=& $arg $b 'Versioned'
  $m1=@(@($b|Where-Object {$_.Kind -eq 'Mirror' -and $_.SourceId -eq $f1.Id})[0].Arguments);$m2=@(@($b|Where-Object {$_.Kind -eq 'Mirror' -and $_.SourceId -eq $f2.Id})[0].Arguments)
  $idFile=if('-RetentionApprovedFile' -in $va){& $val $va '-RetentionApprovedFile'}else{''}
  Check 'the next backup hands the versions step a file with exactly the approved IDs, one per line, and no preview' {'-RetentionPreview' -notin $va -and (& $val $va '-KeepLast') -eq '10' -and (& $val $va '-KeepMonths') -eq '6' -and $idFile -and (Split-Path $idFile -Parent) -eq (Get-CenterPaths).Logs -and ([IO.File]::ReadAllText($idFile).Replace("`r",'').TrimEnd("`n") -ceq "bbbb2222`naaaa1111") -and [IO.File]::ReadAllBytes($idFile)[0] -eq [byte][char]'b'}
  Check 'the plain copy of that source is told the approved recovery folders by name, with the usual rule and no preview' {'-PreviewRecovery' -notin $m1 -and '-MoveExtras' -in $m1 -and (& $val $m1 '-KeepRecovery') -eq '5' -and (& $val $m1 '-RecoveryApproved') -eq '20260102-101500,20260109-101500'}
  Check 'a source with nothing approved for it only previews, as before: nothing unapproved is deleted' {'-PreviewRecovery' -in $m2 -and '-MoveExtras' -in $m2 -and '-RecoveryApproved' -notin $m2}
  Check 'every step of that backup is marked as part of the approved clean-up' {$b.Count -eq 3 -and -not @($b|Where-Object {$_.RetentionPhase -ne 'Approved'}).Count}
  Check 'a content check and a repair never get the approved lists' {-not @(@(Get-CenterSteps $p2 @() 'Verify')+@(Get-CenterSteps $p2 @() 'Repair')|Where-Object {$_.RetentionPhase -eq 'Approved' -or @($_.Arguments|Where-Object {$_ -in '-RetentionApprovedFile','-RecoveryApproved','-RetentionPreview','-PreviewRecovery','-KeepLast'}).Count}).Count}
  # When that backup has finished.
  $done={param($sid,$kind,$more=@{})$h=@{SourceId=$sid;Kind=$kind;Success=$true;Stopped=$false;RetentionPlanFailed=$false;RetentionPhase='Approved'};foreach($k in $more.Keys){$h[$k]=$more[$k]};[pscustomobject]$h}
  $whole=@((& $done $f1.Id 'Mirror'),(& $done $f1.Id 'Versioned'),(& $done $f2.Id 'Mirror'))
  $still={[bool](Get-CenterRetentionApproved $p2) -and -not (Test-CenterRetentionConfirmed $p2) -and (Test-Path -LiteralPath $idFile)}
  Check '"Back up selected source" during this phase does not confirm the profile' {(Complete-CenterRetentionRun $d $p2.Id @($whole[0],$whole[1])) -eq 'Kept' -and (& $still)}
  Check 'a backup in which a part failed or was stopped keeps the approved list for the next backup' {(Complete-CenterRetentionRun $d $p2.Id @($whole[0],(& $done $f1.Id 'Versioned' @{Success=$false}),$whole[2])) -eq 'Kept' -and (Complete-CenterRetentionRun $d $p2.Id @((& $done $f1.Id 'Mirror' @{Stopped=$true}),$whole[1],$whole[2])) -eq 'Kept' -and (& $still)}
  Check 'a clean-up that did not finish keeps it too' {(Complete-CenterRetentionRun $d $p2.Id @($whole[0],(& $done $f1.Id 'Versioned' @{RetentionPlanFailed=$true}),$whole[2])) -eq 'Kept' -and (& $still)}
  Check 'a run that was not started with the approved lists (the one that was just approved) changes nothing' {(Complete-CenterRetentionRun $d $p2.Id @($whole|ForEach-Object {$c=$_.PSObject.Copy();$c.RetentionPhase=$null;$c})) -eq 'None' -and (Complete-CenterRetentionRun $d $p2.Id @($whole|Select-Object SourceId,Kind,Success,Stopped,RetentionPlanFailed)) -eq 'None' -and (& $still)}
  Check 'after a whole backup that succeeded the clean-up runs by the rule from then on: confirmed, and the approved list and its file are gone' {(Complete-CenterRetentionRun $d $p2.Id $whole) -eq 'Confirmed' -and (Test-CenterRetentionConfirmed $p2) -and -not $p2.PSObject.Properties['RetentionApproved'] -and -not (Test-Path -LiteralPath $idFile) -and $($q=@((Read-CenterProfiles).Profiles|Where-Object {$_.Id -eq $p2.Id})[0];$q.RetentionConfirmed -eq $true -and -not $q.PSObject.Properties['RetentionApproved']) -and (Get-CenterRetentionState $p2) -eq 'Clean-up runs automatically.'}
  $b=@(Get-CenterSteps $p2 @() 'Backup')
  Check 'from then on the steps carry the rule alone: no preview, no approved lists' {-not @($b|Where-Object {$_.RetentionPhase -eq 'Approved' -or @($_.Arguments|Where-Object {$_ -in '-RetentionApprovedFile','-RecoveryApproved','-RetentionPreview','-PreviewRecovery'}).Count}).Count -and (& $val (& $arg $b 'Versioned') '-KeepLast') -eq '10' -and (& $val (& $arg $b 'Mirror') '-KeepRecovery') -eq '5'}
  Check 'with no approved list there is nothing to finish' {(Complete-CenterRetentionRun $d $p2.Id $whole) -eq 'None'}
  # Changing the rule.
  $p2.RetentionConfirmed=$false;Set-CenterRetentionApproved $d $p2.Id $shown
  Check 'saving the same Keep versions numbers keeps the approved list; other numbers clear it' {Set-CenterVersionRetention $p2 10 6;$same=[bool](Get-CenterRetentionApproved $p2);Set-CenterVersionRetention $p2 5 6;$same -and -not $p2.PSObject.Properties['RetentionApproved'] -and -not (Test-CenterRetentionConfirmed $p2)}
  Set-CenterVersionRetention $p2 10 6;Set-CenterRetentionApproved $d $p2.Id $shown
  Check 'the same Keep deleted number keeps the approved list; another number clears it' {Set-CenterKeepDeleted $p2 5;$same=[bool](Get-CenterRetentionApproved $p2);Set-CenterKeepDeleted $p2 3;$same -and -not $p2.PSObject.Properties['RetentionApproved'] -and (Get-CenterKeepDeleted $p2) -eq 3}
  Set-CenterRetentionApproved $d $p2.Id $shown;$p2.KeepDeleted=7
  $b=@(Get-CenterSteps $p2 @() 'Backup')
  Check 'an approved list for other numbers than the profile has now is not used: the backup previews again' {$null -eq (Get-CenterRetentionApproved $p2) -and '-RetentionPreview' -in (& $arg $b 'Versioned') -and @($b|Where-Object {$_.Kind -eq 'Mirror' -and '-PreviewRecovery' -in $_.Arguments}).Count -eq 2 -and -not @($b|Where-Object {$_.RetentionPhase -eq 'Approved' -or '-RetentionApprovedFile' -in $_.Arguments -or '-RecoveryApproved' -in $_.Arguments}).Count -and (Get-CenterRetentionState $p2) -eq 'The first clean-up will be shown to you for approval.'}
  Check 'such a list is dropped when asked, once' {(Remove-CenterRetentionApproved $p2) -and -not $p2.PSObject.Properties['RetentionApproved'] -and -not (Remove-CenterRetentionApproved $p2)}
  Check 'turning Keep deleted on, or to another number, has its first clean-up shown again; turning it off does not' {$p2.RetentionConfirmed=$true;Set-CenterKeepDeleted $p2 7;$a=Test-CenterRetentionConfirmed $p2;Set-CenterKeepDeleted $p2 0;$z=Test-CenterRetentionConfirmed $p2;Set-CenterKeepDeleted $p2 4;$a -and $z -and -not (Test-CenterRetentionConfirmed $p2) -and (Get-CenterKeepDeleted $p2) -eq 4}
  # The versions folder is gone: only an approved step may start a new one.
  $nr=@(Get-CenterSteps $p2 @($f1.Id) 'Backup' -Kind Versioned -NewRepositoryFor @($f1.Id))
  Check 'starting a new versions folder is one versioned backup of that source with -CreateNewRepository' {$nr.Count -eq 1 -and $nr[0].Kind -eq 'Versioned' -and $nr[0].SourceId -eq $f1.Id -and '-CreateNewRepository' -in $nr[0].Arguments -and $nr[0].NewRepository -eq $true -and $nr[0].RepositoryFolder -eq 'F1-Versions' -and (& $val $nr[0].Arguments '-Action') -eq 'Backup'}
  Check 'no other step ever gets that switch: not an ordinary backup, a check, a repair, or another source' {-not @(@(Get-CenterSteps $p2 @() 'Backup')+@(Get-CenterSteps $p2 @() 'Verify' -NewRepositoryFor @($f1.Id))+@(Get-CenterSteps $p2 @() 'Repair' -NewRepositoryFor @($f1.Id))+@(Get-CenterSteps $p2 @() 'Backup' -NewRepositoryFor @($f2.Id,'gone'))|Where-Object {'-CreateNewRepository' -in $_.Arguments}).Count}
  Check 'plain copy steps say whether a keep rule is set, so a pile of recovery folders can be noted' {$p2.KeepDeleted=0;$x=@(Get-CenterSteps $p2 @() 'Backup'|Where-Object {$_.Kind -eq 'Mirror'});$p2.KeepDeleted=4;$y=@(Get-CenterSteps $p2 @() 'Backup'|Where-Object {$_.Kind -eq 'Mirror'});$x[0].KeepDeleted -eq 0 -and $y[0].KeepDeleted -eq 4}
 }finally{$p2.DestinationVolumeId=$realId;$p2.VersionRetention=[pscustomobject]@{Last=0;Months=0};$p2.KeepDeleted=0;$p2.RetentionConfirmed=$false;[void](Remove-CenterRetentionApproved $p2)}
 # What the run that carried the approved lists says in the history.
 $e=& $retJson ('{"Preview":false,"Approved":true,"Removed":2,"PartialRemoved":1,"Kept":12,"Deferred":3,"Candidates":'+$cand+',"Error":null}')
 Check 'the approved clean-up says what it deleted, and how many more wait for the next backup' {$e.Success -and $e.Note -eq 'Deleted 2 old versions (1 partial), as you approved (1 Mar 2026 10:15, 1 Feb 2026 09:30); 12 kept. 3 more will be cleaned up with the next backup.' -and $null -eq $e.RetentionPreview}
 $e=& $retJson '{"Preview":false,"Approved":true,"Removed":0,"PartialRemoved":0,"Kept":12,"Deferred":1,"Candidates":[],"Error":null}'
 Check 'approved versions that were no longer there: nothing deleted, said as that' {$e.Note -eq 'Nothing was deleted: the versions you approved were no longer there; 12 kept. 1 more will be cleaned up with the next backup.'}
 $e=& $retJson '{"Preview":false,"Approved":false,"Removed":3,"PartialRemoved":1,"Kept":12,"Deferred":0,"Candidates":[],"Error":null}'
 Check 'a clean-up by the rule reads as before, also with the newer fields' {$e.Note -eq 'Deleted 3 old versions (1 partial); 12 kept.'}
 [IO.File]::WriteAllText((Join-Path $rd 'result.json'),'{"State":"Completed","Retention":{"Preview":false,"Approved":true,"Removed":1,"Kept":9,"Deferred":1,"Error":"The drive was disconnected"}}')
 $e=Invoke-Fake 'exit 0' -Kind Versioned -RunDirectory $rd -More @{RetentionPhase='Approved'}
 Check 'an approved clean-up that did not finish is marked, so the approved list stays for the next backup' {$e.Success -and $e.RetentionPhase -eq 'Approved' -and $e.RetentionPlanFailed -eq $true -and $e.Note -like 'Deleted 1 old version*did not finish: The drive was disconnected*'}
 $e=Invoke-Fake 'exit 0' -Kind Versioned -RunDirectory $rd
 Check 'the same result outside the approved phase is not marked' {$e.RetentionPlanFailed -eq $false -and -not $e.RetentionPhase}
 $e=Invoke-Fake ("Write-Output '"+$json.Replace('"Verify":{','"RecoveryRemoved":["20260102-101500","20260109-101500"],"RecoveryDeferred":["20260201-101500"],"RecoveryFolderCount":6,"Verify":{')+"'") -More @{RetentionPhase='Approved';KeepDeleted=5}
 Check 'a plain copy says which recovery folders it deleted, and how many more wait for the next backup' {$e.Success -and $e.RetentionPhase -eq 'Approved' -and $e.Note -eq 'Deleted 2 older recovery folders (20260102-101500, 20260109-101500). 1 more will be cleaned up with the next backup.' -and $e.RecoveryFolderCount -eq 6}
 $e=Invoke-Fake ("Write-Output '"+$json.Replace('"Verify":{','"RecoveryRemoved":[],"RecoveryDeferred":[],"RecoveryWouldRemove":[],"Verify":{')+"'")
 Check 'a plain copy that deleted no recovery folder says nothing about it' {$e.Success -and -not $e.Note -and $null -eq $e.RecoveryFolderCount}

 # --- Recovery folders piled up beside a plain copy that has no keep rule ---
 $pile={param($count,$keep)Invoke-Fake ("Write-Output '"+$json.Replace('"Verify":{','"RecoveryFolderCount":'+$count+',"Verify":{')+"'") -More @{KeepDeleted=$keep}}
 $e=& $pile 14 0
 Check 'more than 10 recovery folders and no keep rule: counted on the entry and said in the run''s note' {$e.Success -and $e.RecoveryFolderCount -eq 14 -and $e.Note -eq "14 recovery folders have piled up beside the plain copy of L. Set 'Keep deleted in' to keep only the newest ones."}
 Check 'not said with a keep rule, or with 10 folders or fewer' {$a=& $pile 14 5;$z=& $pile 10 0;$a.RecoveryFolderCount -eq 14 -and -not $a.Note -and $z.RecoveryFolderCount -eq 10 -and -not $z.Note}
 $piled=& $R $f2.Id 'Mirror' $true $n.AddMinutes(-30) '' $false @{RecoveryFolderCount=14}
 $adv=@(Get-CenterRecoveryAdvice $p2 ($full+@($piled)))
 Check 'the overview suggests a keep rule, naming the source and the number' {$adv.Count -eq 1 -and $adv[0].Level -eq 'Advice' -and $adv[0].SourceId -eq $f2.Id -and $adv[0].Count -eq 14 -and $adv[0].Text -eq "14 recovery folders have piled up beside the plain copy of F2. Set 'Keep deleted in' to keep only the newest ones"}
 Check 'the line for the overview is the suggestion alone; a failed run is still named first' {$f=Format-CenterRunWarnings $adv;$g=Format-CenterRunWarnings (@(Get-CenterRunWarnings $p2 ($full+@($piled,(& $R $f1.Id 'Mirror' $false $n.AddMinutes(-5) 'x'))) $n)+$adv);$f.Level -eq 'Advice' -and $f.Text -eq ($adv[0].Text+'.') -and $g.Level -eq 'Failed' -and $g.Text -like '*F1*failed*1 more*Recent runs*' -and $g.Full -like '*piled up*'}
 Check 'no suggestion with a keep rule, with few folders, once a newer run counts fewer, or for runs without the number' {$p2.KeepDeleted=3;$a=@(Get-CenterRecoveryAdvice $p2 ($full+@($piled))).Count;$p2.KeepDeleted=0;-not $a -and -not @(Get-CenterRecoveryAdvice $p2 ($full+@(& $R $f2.Id 'Mirror' $true $n.AddMinutes(-30) '' $false @{RecoveryFolderCount=10}))).Count -and -not @(Get-CenterRecoveryAdvice $p2 ($full+@($piled,(& $R $f2.Id 'Mirror' $true $n.AddMinutes(-5) '' $false @{RecoveryFolderCount=2})))).Count -and -not @(Get-CenterRecoveryAdvice $p2 $full).Count}
 Check 'a newer run that does not report the number keeps the suggestion of the last one that did' {@(Get-CenterRecoveryAdvice $p2 ($full+@($piled,(& $R $f2.Id 'Mirror' $true $n.AddMinutes(-5))))).Count -eq 1}

 # --- A file that was in use in three backups in a row ---
 $e=Invoke-Fake ("Write-Output '"+$json.Replace('"CopyErrors":0','"CopyErrors":1').Replace('"Verify":{','"LockedFiles":["db\\data.mdf","logs\\app.log"],"LockedFilesCount":2,"Verify":{')+"'")
 Check 'files that were in use are kept on the history entry; the run stays a failed run' {-not $e.Success -and $e.Error -like '1 files could not be copied*' -and @($e.LockedFiles).Count -eq 2 -and $e.LockedFiles[0] -eq 'db\data.mdf' -and @(Get-CenterHistory)[-1].LockedFiles[1] -eq 'logs\app.log'}
 $e=Invoke-Fake "Write-Output '$json'"
 Check 'a run without files in use records none' {$e.Success -and -not @($e.LockedFiles|Where-Object {$_}).Count}
 $L={param($mins,$files,[bool]$ok=$false,[string]$kind='Mirror',[bool]$stopped=$false,[string]$sid=$f2.Id)& $R $sid $kind $ok $n.AddMinutes(-$mins) $(if($ok){''}else{'1 files could not be copied'}) $stopped @{LockedFiles=@($files)}}
 $mdf='db\data.mdf'
 Check 'in use in two backups in a row: nothing is offered' {-not @(Get-CenterLockedOffer $f2 @((& $L 30 $mdf),(& $L 20 $mdf))).Count}
 Check 'in use in three backups in a row: offered once, whatever the letter case' {$o=@(Get-CenterLockedOffer $f2 @((& $L 30 $mdf),(& $L 20 'DB\Data.MDF'),(& $L 10 $mdf)));$o.Count -eq 1 -and $o[0] -eq $mdf}
 Check 'three backups with different files in use: nothing is offered' {-not @(Get-CenterLockedOffer $f2 @((& $L 30 'a.txt'),(& $L 20 'b.txt'),(& $L 10 'c.txt'))).Count}
 Check 'only the files in all three are offered' {$o=@(Get-CenterLockedOffer $f2 @((& $L 30 @('a.txt',$mdf)),(& $L 20 @($mdf,'c.txt')),(& $L 10 @($mdf,'a.txt'))));$o.Count -eq 1 -and $o[0] -eq $mdf}
 Check 'a successful backup in between starts the count again' {-not @(Get-CenterLockedOffer $f2 @((& $L 40 $mdf),(& $L 30 @() $true),(& $L 20 $mdf),(& $L 10 $mdf))).Count -and -not @(Get-CenterLockedOffer $f2 @((& $L 40 $mdf),(& $L 30 $mdf),(& $L 20 $mdf),(& $L 10 @() $true))).Count}
 Check 'a content check, a repair or a stopped run in between is no backup and does not count either way' {@(Get-CenterLockedOffer $f2 @((& $L 50 $mdf),(& $L 40 $mdf),(& $L 30 @() $true 'MirrorCheck'),(& $L 25 @() $true 'MirrorRepair'),(& $L 20 @() $false 'Mirror' $true),(& $L 10 $mdf))).Count -eq 1}
 Check 'runs of another source, of versions, and older entries without the list do not make three' {-not @(Get-CenterLockedOffer $f2 @((& $L 30 $mdf),(& $L 20 $mdf $false 'Mirror' $false $f1.Id),(& $L 10 $mdf))).Count -and -not @(Get-CenterLockedOffer $f2 @((& $L 30 $mdf),(& $L 20 $mdf $false 'Versioned'),(& $L 10 $mdf))).Count -and -not @(Get-CenterLockedOffer $f2 @((& $L 30 $mdf),(& $R $f2.Id 'Mirror' $false $n.AddMinutes(-20) 'x'),(& $L 10 $mdf))).Count}
 Check 'the question names the files and says that an excluded file is not backed up' {$t=Format-CenterLockedOffer 'F2' @($mdf,'logs\app.log');$t -like '*F2*three backups in a row*' -and $t -like "*- db\data.mdf*`n*- logs\app.log*" -and $t -like '*not backed up*'}
 # Not now: asked again only after three further backups with the file in use.
 Set-CenterLockedAsked $d $p2.Id $f2.Id @($mdf) $n.AddMinutes(-25)
 Check 'a file that was declined is remembered with the source, in the settings' {$q=@(@((Read-CenterProfiles).Profiles|Where-Object {$_.Id -eq $p2.Id})[0].Sources|Where-Object {$_.Id -eq $f2.Id})[0];@($q.LockedAsked).Count -eq 1 -and $q.LockedAsked[0].Path -eq $mdf -and (ConvertTo-CenterTime $q.LockedAsked[0].When)}
 Check 'after Not now it is not offered again by the same runs, nor after one or two more' {-not @(Get-CenterLockedOffer $f2 @((& $L 50 $mdf),(& $L 40 $mdf),(& $L 30 $mdf))).Count -and -not @(Get-CenterLockedOffer $f2 @((& $L 40 $mdf),(& $L 30 $mdf),(& $L 20 $mdf),(& $L 10 $mdf))).Count}
 Check 'after three further backups with the file in use it is offered again; another file is offered at once' {@(Get-CenterLockedOffer $f2 @((& $L 30 $mdf),(& $L 20 $mdf),(& $L 15 $mdf),(& $L 10 $mdf))).Count -eq 1 -and (@(Get-CenterLockedOffer $f2 @((& $L 50 @($mdf,'x.log')),(& $L 40 @($mdf,'x.log')),(& $L 30 @($mdf,'x.log')))) -join ',') -eq 'x.log'}
 Check 'declining the same file again keeps one note of it, with the newer time' {Set-CenterLockedAsked $d $p2.Id $f2.Id @('DB\DATA.MDF') $n.AddMinutes(-5);@($f2.LockedAsked).Count -eq 1 -and (ConvertTo-CenterTime $f2.LockedAsked[0].When) -eq $n.AddMinutes(-5)}
 # Exclude from the backup: only on approval, once, under the job's lock, and noted in the history.
 $before=@((Read-CenterJob $f2.ConfigPath).Exclude).Count;$hc=@(Get-CenterHistory).Count
 $added=@(Add-CenterLockedExclude $p2 $f2 @('logs\app.log'))
 Check 'approval adds the file to the source''s Exclude list' {$x=@((Read-CenterJob $f2.ConfigPath).Exclude);$added.Count -eq 1 -and $x.Count -eq $before+1 -and $x[-1] -eq 'logs\app.log'}
 Check 'adding it again, in any letter case, adds nothing' {$again=@(Add-CenterLockedExclude $p2 $f2 @('LOGS\App.log','logs\app.log'));-not $again.Count -and @((Read-CenterJob $f2.ConfigPath).Exclude).Count -eq $before+1}
 Check 'the history notes it once, as a change and not as a backup, and says the file is not backed up' {$h=@(Get-CenterHistory);$new=@($h|Select-Object -Skip $hc);$new.Count -eq 1 -and $new[0].Kind -eq 'Setting' -and $new[0].SourceId -eq $f2.Id -and $new[0].ProfileId -eq $p2.Id -and $new[0].Note -eq 'Excluded from the backup at your request, because it was in use in three backups in a row: logs\app.log. It is not backed up.' -and $null -eq (Get-LastSuccess $h $f2.Id 'Mirror')}
 Check 'an excluded file is not offered again, and is listed as not backed up' {-not @(Get-CenterLockedOffer $f2 @((& $L 30 'logs\app.log'),(& $L 20 'logs\app.log'),(& $L 10 'Logs\App.log'))).Count -and (@(Get-CenterPersonalExcludes $f2) -join ',') -eq 'logs\app.log' -and -not @(Get-CenterPersonalExcludes $f1).Count}
 $lock=[IO.File]::Open(([IO.Path]::GetFullPath([string](Read-CenterJob $f2.ConfigPath).PasswordDpapiPath)+'.run.lock'),'OpenOrCreate','ReadWrite','None')
 try{Check 'while the source is in use nothing is excluded and the history gets no note' {$hc2=@(Get-CenterHistory).Count;(Throws {Add-CenterLockedExclude $p2 $f2 @('other.bin') -WaitMilliseconds 200} '*busy*') -and @((Read-CenterJob $f2.ConfigPath).Exclude).Count -eq $before+1 -and @(Get-CenterHistory).Count -eq $hc2}}finally{$lock.Dispose()}

 # --- The versions folder is gone from the backup drive ---
 [IO.File]::WriteAllText((Join-Path $rd 'result.json'),'{"State":"Failed","Error":"The versions folder F1-Versions was not found on the backup drive.","RepositoryMissing":true}')
 $e=Invoke-Fake 'exit 1' -Kind Versioned -RunDirectory $rd
 Check 'a backup that found no versions folder is a failed run marked as that' {-not $e.Success -and $e.RepositoryMissing -eq $true -and $e.Error -like '*was not found*'}
 [IO.File]::WriteAllText((Join-Path $rd 'result.json'),'{"State":"Failed","Error":"The repository is locked"}')
 Check 'any other failure is not marked' {(Invoke-Fake 'exit 1' -Kind Versioned -RunDirectory $rd).RepositoryMissing -eq $false -and (Invoke-Fake 'exit 1').RepositoryMissing -eq $false}
 $gone={param($sid,$kind='Versioned',$missing=$true)[pscustomobject]@{SourceId=$sid;Label='old label';Kind=$kind;Success=$false;RepositoryMissing=$missing}}
 $ask=@(Get-CenterMissingRepositories $p2 @((& $gone $f1.Id),(& $gone $f2.Id 'Mirror'),[pscustomobject]@{SourceId=$f1.Id;Kind='Mirror';Success=$true}))
 Check 'the one question names the source and the folder that was not found' {$ask.Count -eq 1 -and $ask[0].SourceId -eq $f1.Id -and $ask[0].Folder -eq 'F1-Versions' -and $ask[0].Text -eq 'The versions of F1 were not found on the backup drive (folder F1-Versions). It may have been renamed, moved or deleted.'}
 Check 'nothing is asked after a content check, for a source that was removed, or when the folder was found' {-not @(Get-CenterMissingRepositories $p2 @((& $gone $f1.Id 'VersionedCheck'),(& $gone 'removed'),(& $gone $f1.Id 'Versioned' $false),[pscustomobject]@{SourceId=$f1.Id;Kind='Versioned';Success=$false},$null)).Count}
 [IO.File]::WriteAllText((Join-Path $rd 'result.json'),'{"State":"Completed","Progress":{"percent_done":1}}')
 $e=Invoke-Fake 'exit 0' -Kind Versioned -RunDirectory $rd -More @{NewRepository=$true;RepositoryFolder='F1-Versions'}
 Check 'the backup that started a new versions folder says so in the history' {$e.Success -and $e.Note -eq 'A new, empty versions folder was started (F1-Versions), because the earlier versions were not found on the backup drive.'}
 [IO.File]::WriteAllText((Join-Path $rd 'result.json'),'{"State":"Failed","Error":"x"}')
 Check 'and does not say so when that backup failed' {$e=Invoke-Fake 'exit 1' -Kind Versioned -RunDirectory $rd -More @{NewRepository=$true;RepositoryFolder='F1-Versions'};-not $e.Success -and -not $e.Note}
}finally{if(Test-Path -LiteralPath $root){[IO.Directory]::Delete($root,$true)}}
if($script:failed){Write-Output "$($script:failed) data tests FAILED.";exit 1}
Write-Output 'All data tests passed.'
