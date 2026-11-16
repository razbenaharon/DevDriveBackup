#Requires -Version 7.2
# Checks the drive-check rules (Backup.DriveCheck.psm1) on made-up reports shaped like smartctl's
# JSON, Windows log entries and scan records. No drive is read and no administrator rights are needed.
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'Backup.DriveCheck.psm1') -Force
function Assert($ok,$message){if(-not $ok){throw "FAIL $message"};Write-Output ('PASS '+$message)}
function Json([string]$Text){$Text|ConvertFrom-Json}
function Ata([hashtable]$Raw,[int]$TestStatus=0,[string]$Passed='true'){
 $rows=($Raw.GetEnumerator()|ForEach-Object {'{{"id":{0},"raw":{{"value":{1}}}}}' -f $_.Key,$_.Value}) -join ','
 Json ('{"smart_status":{"passed":'+$Passed+'},"power_on_time":{"hours":20000},"temperature":{"current":34},"ata_smart_data":{"self_test":{"status":{"value":0},"polling_minutes":{"short":2,"extended":300}},"capabilities":{"self_tests_supported":true}},"ata_smart_attributes":{"table":['+$rows+']},"ata_smart_self_test_log":{"standard":{"table":[{"type":{"string":"Short offline"},"status":{"value":'+$TestStatus+',"string":"x"},"lifetime_hours":19990}]}}}')
}
Set-StrictMode -Version Latest

# --- What the drive reports about itself -------------------------------------------------
$h=Get-DriveHealthFindings (Ata @{5=0;197=0;198=0;187=0;199=0})
Assert ($h.Status -eq 'OK') 'a clean hard drive report is OK'
Assert (($h.Lines -join ' ') -match 'Short self-test: passed 10 running hours ago' -and ($h.Lines -join ' ') -match '20,000 hours') 'the newest self-test and the running time are named'
Assert ((Get-DriveHealthFindings (Ata @{5=8;197=0;198=0})).Status -eq 'Warning') 'replaced areas alone are a warning'
Assert ((Get-DriveHealthFindings (Ata @{5=0;197=3;198=0})).Status -eq 'Problem') 'suspect areas are a problem'
Assert ((Get-DriveHealthFindings (Ata @{5=0;197=0;198=2})).Status -eq 'Problem') 'unreadable areas are a problem'
Assert ((Get-DriveHealthFindings (Ata @{5=0} 0 'false')).Status -eq 'Problem') 'a drive that reports failing is a problem'
Assert ((Get-DriveHealthFindings (Ata @{5=0} 0x70)).Status -eq 'Problem') 'a failed self-test (read failure) is a problem'
$i=Get-DriveHealthFindings (Ata @{5=0} 0x10)
Assert ($i.Status -eq 'OK' -and ($i.Lines -join ' ') -match 'did not finish') 'an interrupted self-test is reported but not held against the drive'
$run=Ata @{5=0};$run.ata_smart_data.self_test.status.value=0xF6;$run.ata_smart_data.self_test.status|Add-Member remaining_percent 60
Assert ((Get-DriveSelfTest $run).Running.Remaining -eq 60) 'a running self-test and its remaining part are recognised'
$hot=Ata @{5=0};$hot.temperature.current=58
Assert ((Get-DriveHealthFindings $hot).Status -eq 'Warning') 'a hot hard drive is a warning'
$nvme=Json '{"smart_status":{"passed":true},"temperature":{"current":66},"nvme_composite_temperature_threshold":{"warning":78},"power_on_time":{"hours":100},"nvme_optional_admin_commands":{"self_test":true},"nvme_smart_health_information_log":{"critical_warning":0,"media_errors":0,"available_spare":100,"available_spare_threshold":10,"percentage_used":8,"num_err_log_entries":82},"nvme_self_test_log":{"current_self_test_operation":{"value":0}}}'
Assert ((Get-DriveHealthFindings $nvme).Status -eq 'OK') 'a healthy NVMe drive at 66 °C (limit 78) is OK'
$nvme.nvme_smart_health_information_log.media_errors=4
Assert ((Get-DriveHealthFindings $nvme).Status -eq 'Problem') 'NVMe media errors are a problem'
$nvme.nvme_smart_health_information_log.media_errors=0;$nvme.nvme_smart_health_information_log.available_spare=9
Assert ((Get-DriveHealthFindings $nvme).Status -eq 'Problem') 'NVMe spare area at the maker limit is a problem'
$nvme.nvme_smart_health_information_log.available_spare=100;$nvme|Add-Member nvme_self_test_log ([pscustomobject]@{current_self_test_operation=[pscustomobject]@{value=0};table=@([pscustomobject]@{self_test_code=[pscustomobject]@{value=2};self_test_result=[pscustomobject]@{value=7;string='Completed: failed segments'};power_on_hours=90})}) -Force
Assert ((Get-DriveHealthFindings $nvme).Status -eq 'Problem' -and ((Get-DriveHealthFindings $nvme).Lines -join ' ') -match 'Long self-test: failed') 'a failed NVMe long self-test is a problem'
$box=Json '{"smartctl":{"exit_status":2,"messages":[{"string":"Unknown USB bridge","severity":"error"}]}}'
Assert ((Get-DriveHealthFindings $box).Status -eq 'Unavailable' -and -not (Test-DriveSmartAnswer $box)) 'a box that answers without the drive is unavailable, not healthy'
Assert ((Get-DriveHealthFindings $null 'Install the health tool.').Lines[0] -eq 'Install the health tool.') 'the reason for a missing report is shown'

# --- Reading the disk --------------------------------------------------------------------
$sample=[pscustomobject]@{Regions=@([pscustomobject]@{Name='start';MBps=180;BadCount=0},[pscustomobject]@{Name='middle';MBps=160;BadCount=0},[pscustomobject]@{Name='end';MBps=110;BadCount=0})}
Assert ((Get-DriveSurfaceFindings $sample $null).Status -eq 'OK') 'clean samples without a full scan are OK'
Assert ((Get-DriveSurfaceFindings $null $null).Status -eq 'NotRun') 'nothing read is not a verdict'
$scan=[pscustomobject]@{Size=1TB;NextOffset=1TB;Complete=$true;Finished=(Get-Date).AddDays(-2).ToString('o');BadCount=0;VerySlowCount=0;SlowCount=3;Bad=@()}
Assert ((Get-DriveSurfaceFindings $sample $scan).Status -eq 'OK') 'a finished clean scan is OK'
$scan.VerySlowCount=4
Assert ((Get-DriveSurfaceFindings $sample $scan).Status -eq 'Warning') 'places that took seconds to read are a warning'
$scan.BadCount=2;$scan.Bad=@([pscustomobject]@{Offset=5GB;Length=64KB;Code=23})
$s=Get-DriveSurfaceFindings $sample $scan
Assert ($s.Status -eq 'Problem' -and $s.Lines[0] -match 'first at 5.0 GiB') 'unreadable areas are a problem and say where, in the unit the number is counted in'
$part=[pscustomobject]@{Size=1TB;NextOffset=0.37TB;Complete=$false;Finished=$null;BadCount=0;VerySlowCount=0;SlowCount=0;Bad=@()}
Assert (((Get-DriveSurfaceFindings $sample $part).Lines -join ' ') -match 'stopped at 37%') 'a stopped scan shows how far it got'

# --- Windows log ---------------------------------------------------------------------------
$now=Get-Date
$events=@(
 [pscustomobject]@{ProviderName='disk';Id=157;TimeCreated=$now.AddDays(-3);Message='Disk 2 has been surprise removed. \Device\Harddisk2\DR7'}
 [pscustomobject]@{ProviderName='disk';Id=157;TimeCreated=$now.AddDays(-1);Message='Disk 2 has been surprise removed. \Device\Harddisk2\DR9'}
 [pscustomobject]@{ProviderName='disk';Id=7;TimeCreated=$now;Message='הדיסק \Device\Harddisk12\DR3 מכיל בלוק פגום.'}
 [pscustomobject]@{ProviderName='disk';Id=7;TimeCreated=$now;Message='\Device\Harddisk2\DR9 has a bad block.'}
 [pscustomobject]@{ProviderName='Ntfs';Id=55;TimeCreated=$now;Message='A corruption was discovered in the file system structure on volume E:.'}
 [pscustomobject]@{ProviderName='Ntfs';Id=140;TimeCreated=$now;Message='The system failed to flush data to the transaction log. VolumeId: F:'}
 [pscustomobject]@{ProviderName='Ntfs';Id=98;TimeCreated=$now;Message='Volume E: (\Device\HarddiskVolume9) is healthy. No action is needed.'}
 [pscustomobject]@{ProviderName='uaspstor';Id=129;TimeCreated=$now;Message='Reset to device, \Device\RaidPort3, was issued.'}
)
$found=@(Get-DriveEventFindings $events 2 'E' $true)
Assert ($found.Count -eq 4) 'only entries about this disk, its letter and USB resets are kept'
Assert ((@($found|Where-Object Group -eq 'Connection'|ForEach-Object Line) -join ' ') -match 'without safe removal, 2 times') 'repeated log entries are counted'
Assert (@($found|Where-Object {$_.Group -eq 'Surface' -and $_.Status -eq 'Problem'}).Count -eq 1) 'a bad block on this disk is a reading problem; disk 12 is not disk 2'
Assert (@(Get-DriveEventFindings $events 2 'E' $false|Where-Object Line -match 'USB').Count -eq 0) 'USB resets are not held against a drive that is not on USB'
# Disk numbers move between drives: only entries from while this drive held the number count.
$conn=@([pscustomobject]@{Time=$now.AddDays(-10);DiskNumber=2;Key=(Get-DriveConnectionKey 'OTHER1' 'm' 1)},[pscustomobject]@{Time=$now.AddDays(-2);DiskNumber=2;Key=(Get-DriveConnectionKey 'MINE1.' 'm' 1)},[pscustomobject]@{Time=$now.AddDays(-20);DiskNumber=2;Key=(Get-DriveConnectionKey 'MINE1' 'm' 1)})
$moved=@(
 [pscustomobject]@{ProviderName='disk';Id=7;TimeCreated=$now.AddDays(-5);Message='\Device\Harddisk2\DR3 bad block'}
 [pscustomobject]@{ProviderName='disk';Id=7;TimeCreated=$now.AddDays(-15);Message='\Device\Harddisk2\DR3 bad block'}
 [pscustomobject]@{ProviderName='disk';Id=154;TimeCreated=$now.AddHours(-1);Message='The IO operation for Disk 2 failed. \Device\Harddisk2\DR9 0x1 2'}
 [pscustomobject]@{ProviderName='Ntfs';Id=55;TimeCreated=$now.AddDays(-4);Message='corruption on volume E:'}
)
$m=@(Get-DriveEventFindings $moved 2 'E' $true $conn)
Assert ($m.Count -eq 2 -and (@($m.Line) -join ' ') -match 'damaged area while using the drive, once' -and (@($m.Line) -join ' ') -match 'hardware error, once') 'entries from another drive under the same number are left out; this drive''s earlier connection counts'
Assert (-not (@($m.Line) -join ' ').Contains('file system')) 'a letter entry from before this drive arrived is left out'
Assert ((Get-DriveConnectionKey '' 'Model X' 500) -eq (Get-DriveConnectionKey 'NULL' 'Model X' 500)) 'a drive without a serial number is known by model and size'
# Entries older than the oldest arrival Windows still records for this disk number: nobody can say
# which drive they were about. They are counted in a note of their own and change no verdict.
Assert (-not @($m|Where-Object {$_.Line -match 'could not be matched'}).Count) 'entries that can all be matched to a drive leave no note'
$older=@(
 [pscustomobject]@{ProviderName='disk';Id=7;TimeCreated=$now.AddDays(-25);Message='\Device\Harddisk2\DR1 bad block'}
 [pscustomobject]@{ProviderName='disk';Id=153;TimeCreated=$now.AddDays(-28);Message='The IO operation was retried. \Device\Harddisk2\DR1'}
 [pscustomobject]@{ProviderName='disk';Id=7;TimeCreated=$now.AddDays(-27);Message='\Device\Harddisk5\DR1 bad block'}
 [pscustomobject]@{ProviderName='Ntfs';Id=55;TimeCreated=$now.AddDays(-26);Message='corruption on volume E:'}
)
$u=@(Get-DriveEventFindings (@($moved)+$older) 2 'E' $true $conn)
$note=@($u|Where-Object {$_.Line -match 'could not be matched'})
Assert ($note.Count -eq 1 -and $note[0].Group -eq 'Connection' -and $note[0].Line -match '^Windows log: 2 older disk entries could not be matched to a drive' -and $note[0].Line -match 'not counted for or against this drive') 'disk entries older than every arrival Windows still records for that number are counted in one note; another disk number and a letter are not'
Assert ((@($u|Where-Object {$_.Line -notmatch 'could not be matched'}|ForEach-Object {$_.Line}|Sort-Object) -join '|') -eq (@($m|ForEach-Object {$_.Line}|Sort-Object) -join '|')) 'the entries that are matched count exactly as before'
$one=@(Get-DriveEventFindings @($older[0]) 2 'E' $true $conn)
Assert ($one.Count -eq 1 -and $one[0].Line -match '^Windows log: 1 older disk entry could not be matched to a drive' -and $one[0].Line -match 'it is not counted') 'a single such entry reads as one'
Assert (@(Get-DriveEventFindings $older 2 'E' $true|Where-Object {$_.Line -match 'could not be matched'}).Count -eq 0) 'without any arrival record only the disk number is compared, as before, and there is no note'
foreach($status in 'OK','Warning','Unavailable','NotRun'){
 $g=Merge-DriveEvents (New-DriveGroup $status 'own line') $one 'Connection'
 Assert ($g.Status -eq $status -and (@($g.Lines) -join '|') -eq ('own line|'+$one[0].Line)) "the note changes no verdict (a connection group that is $status stays $status) and stands after the group's own lines"
}
$g=Merge-DriveEvents (New-DriveGroup 'OK' 'own line') $u 'Connection'
Assert ($g.Status -eq 'OK' -and $g.Lines[-1] -eq $note[0].Line -and $g.Lines.Count -eq 2) 'beside matched entries of other groups it still changes nothing'
$view=Get-DriveCheckView ([pscustomobject]@{Finished=$now.ToString('o');Sample=$sample;Events=$one;Health=(New-DriveGroup 'OK' 'x');Connection=(Merge-DriveEvents (New-DriveGroup 'OK' 'y') $one 'Connection');FileSystem=(New-DriveGroup 'OK' 'z')}) $null
Assert ($view.Overall -eq 'OK' -and $view.Summary -eq 'no problems' -and @($view.Groups.Values|Where-Object {$_.Status -ne 'OK'}).Count -eq 0) 'and no group of the view is worse for it'
$view=Get-DriveCheckView ([pscustomobject]@{Finished=$now.ToString('o');Sample=$sample;Events=$found;Health=(New-DriveGroup 'OK' 'x');Connection=(New-DriveGroup 'OK' 'y');FileSystem=(New-DriveGroup 'OK' 'z')}) $null
Assert ($view.Groups.Surface.Status -eq 'Problem' -and $view.Overall -eq 'Problem') 'a log entry can make a group and the whole check worse'
Assert ((Get-DriveCheckView $null $null).Overall -eq 'NotRun') 'a drive never checked has no verdict'

# --- Connection and file system ---------------------------------------------------------
Assert ((Get-DriveConnectionFindings ([pscustomobject]@{Speed='High (480 Mbit/s)';SuperSpeedActive=$false}) 'USB' $null $null).Status -eq 'Warning') 'USB 2 speed is a warning'
Assert ((Get-DriveConnectionFindings ([pscustomobject]@{Speed='SuperSpeedPlus (10 Gbit/s+)';SuperSpeedActive=$true}) 'USB' (Ata @{199=0}) $null).Status -eq 'OK') 'a full-speed link without transfer errors is OK'
Assert ((Get-DriveConnectionFindings ([pscustomobject]@{Speed='SuperSpeed (5 Gbit/s+)';SuperSpeedActive=$true}) 'USB' (Ata @{199=41}) $null).Status -eq 'Warning') 'damaged transfers counted by the drive are a warning'
Assert ((Get-DriveConnectionFindings $null 'NVMe' $null ([pscustomobject]@{ReadErrorsTotal=0;ReadErrorsUncorrected=2;WriteErrorsUncorrected=0})).Status -eq 'Warning') 'failed reads counted by Windows are a warning'
Assert ((Get-DriveFileSystemFindings 'E' 'NTFS' 'NoErrorsFound' '' 'Healthy').Status -eq 'OK') 'a clean NTFS scan is OK'
$fix=Get-DriveFileSystemFindings 'E' 'NTFS' 'SpotFixNeeded' '' 'Healthy'
Assert ($fix.Status -eq 'Warning' -and $fix.Lines[0] -match 'chkdsk E: /spotfix') 'a small repair is a warning and names the command'
Assert ((Get-DriveFileSystemFindings 'E' 'NTFS' 'FullRepairNeeded' '' 'Healthy').Status -eq 'Problem') 'a full repair is a problem'
Assert ((Get-DriveFileSystemFindings 'E' 'exFAT' '' '' 'Healthy').Status -eq 'Unavailable') 'a file system Windows cannot scan online is unavailable'
# --- Self-tests: the newest of each kind counts --------------------------------------------------
function SelfTest([string]$Type,[int]$Status,[int]$Hours){[pscustomobject]@{type=[pscustomobject]@{string=$Type};status=[pscustomobject]@{value=$Status;string=$(if($Status){'Completed: read failure'}else{'Completed without error'})};lifetime_hours=$Hours}}
$masked=Ata @{5=0};$masked.ata_smart_self_test_log.standard.table=@((SelfTest 'Short offline' 0 19999),(SelfTest 'Extended offline' 0x70 19900))
$m=Get-DriveHealthFindings $masked
Assert ($m.Status -eq 'Problem' -and ($m.Lines -join ' ') -match 'Long self-test: failed' -and ($m.Lines -join ' ') -match 'Short self-test: passed') 'a short self-test that passed does not hide a long one that failed before it'
$healed=Ata @{5=0};$healed.ata_smart_self_test_log.standard.table=@((SelfTest 'Extended offline' 0 19999),(SelfTest 'Extended offline' 0x70 19900))
Assert ((Get-DriveHealthFindings $healed).Status -eq 'OK') 'a newer long self-test that passed replaces an older one that failed'
$shorts=Ata @{5=0};$shorts.ata_smart_self_test_log.standard.table=@((SelfTest 'Short offline' 0 19999),(SelfTest 'Short offline' 0x70 19900))
Assert ((Get-DriveHealthFindings $shorts).Status -eq 'OK') 'only the newest short self-test counts'
$cut=Ata @{5=0};$cut.ata_smart_self_test_log.standard.table=@((SelfTest 'Extended offline' 0x10 19999),(SelfTest 'Extended offline' 0x70 19900))
$c=Get-DriveHealthFindings $cut
Assert ($c.Status -eq 'Problem' -and ($c.Lines -join ' ') -match 'did not finish') 'an interrupted long self-test does not hide an earlier one that failed'
$noLog=Ata @{5=0};$noLog.ata_smart_self_test_log.standard.table=@()
$n=Get-DriveSelfTest $noLog
Assert ($null -eq $n.Last -and $null -eq $n.LastShort -and $null -eq $n.LastLong -and (Get-DriveHealthFindings $noLog).Status -eq 'OK') 'a drive with an empty self-test log is fine'
$nvme.nvme_self_test_log.table=@([pscustomobject]@{self_test_code=[pscustomobject]@{value=1};self_test_result=[pscustomobject]@{value=0;string='Completed without error'};power_on_hours=99},[pscustomobject]@{self_test_code=[pscustomobject]@{value=2};self_test_result=[pscustomobject]@{value=7;string='Completed: failed segments'};power_on_hours=90})
Assert ((Get-DriveHealthFindings $nvme).Status -eq 'Problem') 'on NVMe too, a short self-test that passed does not hide a failed long one'

# --- Controller resets name no disk: only the drive's own kind of connection counts ---------------
$reset=@('storahci','stornvme','uaspstor'|ForEach-Object {[pscustomobject]@{ProviderName=$_;Id=129;TimeCreated=$now;Message='Reset to device, \Device\RaidPort0, was issued.'}})
Assert (@(Get-DriveEventFindings @($reset[0],$reset[1]) 2 'E' $true @() 'USB').Count -eq 0) 'a reset of an internal drive is not held against a USB drive'
Assert (@(Get-DriveEventFindings @($reset[1],$reset[2]) 2 'E' $false @() 'SATA').Count -eq 0) 'an NVMe or USB reset is not held against a SATA drive'
Assert (@(Get-DriveEventFindings $reset 2 'E' $false @() 'NVMe').Count -eq 1 -and @(Get-DriveEventFindings $reset 2 'E' $true @() 'USB').Count -eq 1) 'a reset on the drive''s own kind of connection still counts'

# --- Nothing checked is not "no problems" ---------------------------------------------------------
Assert ((Get-DriveConnectionFindings ([pscustomobject]@{Error='Hub interface error 13'}) 'USB' $null $null).Status -eq 'Unavailable') 'a USB link that could not be read, with no counters at all, is not available rather than OK'
Assert ((Get-DriveConnectionFindings $null 'USB' (Ata @{199=0}) $null).Status -eq 'OK') 'the drive''s own transfer counter is a check even when the link speed could not be read'
$flag=Json '{"smart_status":{"passed":true}}'
$f=Get-DriveHealthFindings $flag
Assert ($f.Status -eq 'Unavailable' -and -not (Test-DriveSmartAnswer $flag) -and $f.Lines[0] -match 'only') 'a box that passes on only the overall "passed" flag gives no health verdict'
Assert ((Get-DriveHealthFindings (Json '{"smart_status":{"passed":false}}')).Status -eq 'Problem') 'a drive that says it is failing is a problem even with nothing else reported'
$un=New-DriveGroup 'Unavailable' 'u'
$view=Get-DriveCheckView ([pscustomobject]@{Finished=$now.ToString('o');Sample=$sample;Events=@();Health=$un;Connection=(New-DriveGroup 'OK' 'y');FileSystem=$un}) $null
Assert ($view.Overall -eq 'OK' -and $view.Summary -match 'not checked: .*health report.*file system' -and $view.Unchecked.Count -eq 2) 'the one-line summary names the parts that could not be checked'
$view=Get-DriveCheckView ([pscustomobject]@{Finished=$now.ToString('o');Sample=$sample;Events=@();Health=(New-DriveGroup 'OK' 'x');Connection=(New-DriveGroup 'OK' 'y');FileSystem=(New-DriveGroup 'OK' 'z')}) $null
Assert ($view.Summary -eq 'no problems' -and $view.Unchecked.Count -eq 0) 'the summary is plain when every part was checked'

# --- A failed self-test of any kind counts ----------------------------------------------------------
$sel=Ata @{5=0};$sel.ata_smart_self_test_log.standard.table=@((SelfTest 'Short offline' 0 19999),(SelfTest 'Selective offline' 0x70 19990))
$m=Get-DriveHealthFindings $sel
Assert ($m.Status -eq 'Problem' -and ($m.Lines -join ' ') -match 'Selective self-test: failed') 'a short self-test that passed does not hide a selective one that failed before it'
$sel.ata_smart_self_test_log.standard.table=@((SelfTest 'Selective offline' 0 19999),(SelfTest 'Selective offline' 0x70 19990),(SelfTest 'Conveyance offline' 0x70 19000))
$m=Get-DriveHealthFindings $sel
Assert ($m.Status -eq 'Problem' -and ($m.Lines -join ' ') -match 'Conveyance self-test: failed' -and ($m.Lines -join ' ') -notmatch 'Selective self-test: failed') 'each kind of self-test is judged by its own newest result'

# --- The full scan's saved position -----------------------------------------------------------------
$work=Join-Path ([IO.Path]::GetTempPath()) ('drive-check-state-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work -Force|Out-Null
try{
 $state=Join-Path $work 'surface.json'
 # A record as the version before this one wrote it: no Previous, no RecoveredCount.
 $doneBad='{"Identity":"SER|1","Size":1099511627776,"NextOffset":1099511627776,"Complete":true,"Started":"2026-01-01T00:00:00","Finished":"2026-01-02T00:00:00","Seconds":9.5,"BadCount":2,"VerySlowCount":0,"SlowCount":0,"Bad":[{"Offset":5368709120,"Length":65536,"Code":23}],"Slow":[]}'
 Set-Content -LiteralPath $state -Value $doneBad
 $read=Read-DriveScanState $state 'SER|1'
 Assert ($null -eq $read.State -and $read.Previous.BadCount -eq 2 -and -not $read.SetAside) 'a finished scan is not continued, and what it found is handed to the next scan'
 $new=New-DriveScanState 'SER|1' 1TB $read.Previous;$new.NextOffset=512MB
 $s=Get-DriveSurfaceFindings $sample ($new|ConvertTo-Json -Depth 8|ConvertFrom-Json)
 Assert ($s.Status -eq 'Problem' -and ($s.Lines -join ' ') -match 'Earlier full scan: 2 areas could not be read \(first at 5.0 GiB\)') 'starting a new full scan does not erase the bad areas the last one found'
 $new.NextOffset=1TB;$new.Complete=$true;$new.Finished=(Get-Date).ToString('o');$new.Previous=$null
 Assert ((Get-DriveSurfaceFindings $sample ($new|ConvertTo-Json -Depth 8|ConvertFrom-Json)).Status -eq 'OK') 'a new scan that finished clean replaces the earlier findings'
 Assert ($null -eq (Read-DriveScanState $state 'OTHER|1').Previous) 'another drive''s scan is not held against this drive'
 Set-Content -LiteralPath $state -Value ($doneBad -replace '"NextOffset":1099511627776,"Complete":true','"NextOffset":536870912,"Complete":false')
 $read=Read-DriveScanState $state 'SER|1'
 Assert ($read.State.NextOffset -eq 512MB -and $read.State.RecoveredCount -eq 0 -and $null -eq $read.State.Previous -and (Test-Path -LiteralPath $state)) 'an unfinished scan saved by the previous version continues where it stopped'
 foreach($damaged in '','{"Identity":"SER|1","Size":10','{}','[1,2]','{"Identity":"SER|1","Size":100,"NextOffset":500,"Complete":false}'){
  Set-Content -LiteralPath $state -Value $damaged -NoNewline
  $read=Read-DriveScanState $state 'SER|1'
  Assert ($null -eq $read.State -and $read.SetAside -and (Test-Path -LiteralPath $read.SetAside) -and -not (Test-Path -LiteralPath $state) -and (Get-Content -LiteralPath $read.SetAside -Raw) -eq $(if($damaged){$damaged}else{$null})) "a damaged saved position ($($damaged.Length) characters) is set aside, not deleted, and the scan starts again"
 }
 Assert (-not (Read-DriveScanState $state 'SER|1').SetAside) 'no saved position is simply a first scan'
 Assert ((Get-DriveSurfaceFindings ([pscustomobject]@{Regions=@()}) $null).Status -eq 'NotRun') 'a quick check stopped before its first sample read is not a verdict and does not fail'
 Assert ((Get-DriveSurfaceFindings $sample ([pscustomobject]@{})).Status -eq 'OK' -and (Get-DriveCheckView $null ('[]'|ConvertFrom-Json)).Overall -eq 'NotRun') 'a scan record without its fields is shown as no scan'

 # --- Stopping ------------------------------------------------------------------------------------
 $stop=Join-Path $work 'stop.request'
 Assert (-not (Test-DriveStopRequest $stop (Get-Date))) 'no stop file is no request'
 Set-Content -LiteralPath $stop -Value '';(Get-Item -LiteralPath $stop).LastWriteTime=(Get-Date).AddMinutes(-5)
 Assert (-not (Test-DriveStopRequest $stop (Get-Date).AddMinutes(-1))) 'a stop request left by an earlier run does not count'
 Assert (Test-DriveStopRequest $stop (Get-Date).AddMinutes(-10)) 'a stop request made since the check''s process started counts, even before the check was ready'

 # --- The reader, on an ordinary file instead of a disk ---------------------------------------------
 Add-DriveScannerType
 $disk=Join-Path $work 'disk.bin';[IO.File]::WriteAllBytes($disk,[byte[]]::new(12MB))
 $old=(Get-Date).AddMinutes(-1).Ticks
 $r=[BackupDriveScanner]::Read($disk,0,12MB,512,1000,$stop,(Get-Date).Ticks)|ConvertFrom-Json
 Assert ($r.Bytes -eq 12MB -and $r.BadCount -eq 0 -and $r.RecoveredCount -eq 0 -and -not $r.Stopped) 'three chunks are read; the old stop request is ignored'
 $r=[BackupDriveScanner]::Read($disk,0,16MB,512,1000,$stop,(Get-Date).Ticks)|ConvertFrom-Json
 Assert ($r.BadCount -eq 64 -and $r.Bad[0].Offset -eq 12MB -and $r.Bad[0].Length -eq 64KB -and $r.Bytes -eq 16MB) 'a chunk that cannot be read is named in 64 KiB pieces'
 # A chunk that fails once and then reads in pieces: the drive needed a second try there.
 [BackupDriveScanner]::Fault=[Func[long,int,int]]{param($pos,$n) if($pos -eq 4MB -and $n -eq 4MB){23}else{0}}
 $r=[BackupDriveScanner]::Read($disk,0,12MB,512,1000,$stop,(Get-Date).Ticks)|ConvertFrom-Json
 Assert ($r.BadCount -eq 0 -and $r.RecoveredCount -eq 1 -and $r.Recovered[0].Offset -eq 4MB -and $r.Recovered[0].Code -eq 23 -and $r.Bytes -eq 12MB) 'a chunk that reads only at the second try is recorded, not forgotten'
 $again=New-DriveScanState 'SER|1' 12MB $null;$again.NextOffset=12MB;$again.Complete=$true;$again.Finished=(Get-Date).ToString('o');$again.RecoveredCount=$r.RecoveredCount
 $s=Get-DriveSurfaceFindings $sample $again
 Assert ($s.Status -eq 'Warning' -and ($s.Lines -join ' ') -match '1 places? could be read only at the second try') 'places that needed a second try are a warning'
 # A stop asked for in the middle of a stretch ends it after the chunk being read, with the position kept.
 [BackupDriveScanner]::Fault=[Func[long,int,int]]{param($pos,$n) if($pos -eq 4MB){Set-Content -LiteralPath $stop -Value ''};0}
 $r=[BackupDriveScanner]::Read($disk,0,12MB,512,1000,$stop,$old)|ConvertFrom-Json
 Assert ($r.Stopped -and $r.Bytes -eq 8MB) 'a stop request is honoured inside a stretch, not only after 512 MiB'
 [BackupDriveScanner]::Fault=$null
 $r=[BackupDriveScanner]::Read($disk,0,12MB,512,1000,$stop,$old)|ConvertFrom-Json
 Assert ($r.Stopped -and $r.Bytes -eq 0) 'a stop request made before the first read stops at once'

 # --- A drive that stops answering in the middle of the scan -----------------------------------------
 # 1117 (I/O device error) and 31 (device not functioning) come from a damaged place and from a drive
 # that was disconnected alike. What tells them apart: a disconnected drive answers nowhere any more.
 Remove-Item -LiteralPath $stop
 $script:dead=$false
 # The drive goes away while the second chunk is read: from then on every read fails.
 [BackupDriveScanner]::Fault=[Func[long,int,int]]{param($pos,$n) if($pos -ge 4MB){$script:dead=$true};if($script:dead){1117}else{0}}
 $r=[BackupDriveScanner]::Read($disk,0,12MB,512,1000,$stop,$old)|ConvertFrom-Json
 Assert ($r.Disconnected -and $r.DisconnectCode -eq 1117 -and -not $r.Stopped) 'a whole chunk that fails with an I/O device error, on a drive that answers nowhere any more, ends the scan as disconnected'
 Assert ($r.BadCount -eq 0 -and @($r.Bad).Count -eq 0 -and $r.RecoveredCount -eq 0) 'and nothing of that chunk is recorded as a bad area'
 Assert ($r.Bytes -eq 4MB) 'the position stays at the chunk that could not be read, so the scan continues there'
 $script:dead=$false
 [BackupDriveScanner]::Fault=[Func[long,int,int]]{param($pos,$n) if($pos -ge 4MB){$script:dead=$true};if($script:dead){31}else{0}}
 $r=[BackupDriveScanner]::Read($disk,0,12MB,512,1000,$stop,$old)|ConvertFrom-Json
 Assert ($r.Disconnected -and $r.DisconnectCode -eq 31 -and $r.BadCount -eq 0 -and $r.Bytes -eq 4MB) 'the same for the error that says the device is not functioning'
 # The first pieces fail with an I/O device error, then Windows says outright that the drive is gone.
 [BackupDriveScanner]::Fault=[Func[long,int,int]]{param($pos,$n) if($pos -lt 4MB){0}elseif($pos -lt 4MB+128KB -or $n -eq 4MB){1117}else{21}}
 $r=[BackupDriveScanner]::Read($disk,0,12MB,512,1000,$stop,$old)|ConvertFrom-Json
 Assert ($r.Disconnected -and $r.DisconnectCode -eq 21 -and $r.BadCount -eq 0 -and $r.Bytes -eq 4MB) 'a drive that turns out to be gone after nothing but such errors in the chunk ends the scan the same way'
 [BackupDriveScanner]::Fault=[Func[long,int,int]]{param($pos,$n) if($pos -ge 4MB){21}else{0}}
 $gone=try{[void][BackupDriveScanner]::Read($disk,0,12MB,512,1000,$stop,$old);''}catch{$_.Exception.GetBaseException().Message}
 Assert ($gone -match 'stopped answering \(21\)') 'a drive that Windows reports as gone at once still ends the check with that error, as before'
 # The drive goes away in the middle of a chunk: its first piece still reads, the rest fail, and
 # the drive answers nowhere afterwards. Nothing of that chunk is a bad area either.
 $script:dead=$false
 [BackupDriveScanner]::Fault=[Func[long,int,int]]{param($pos,$n) if($script:dead){return 1117};if($pos -eq 4MB -and $n -eq 4MB){return 23};if($pos -ge 4MB+64KB){$script:dead=$true;return 1117};0}
 $r=[BackupDriveScanner]::Read($disk,0,12MB,512,1000,$stop,$old)|ConvertFrom-Json
 Assert ($r.Disconnected -and $r.DisconnectCode -eq 1117 -and $r.BadCount -eq 0 -and $r.Bytes -eq 4MB) 'a drive that goes away in the middle of a chunk ends the scan as disconnected too, with nothing recorded as bad'
 # Only some pieces fail: that is a place on the disk, not the connection.
 [BackupDriveScanner]::Fault=[Func[long,int,int]]{param($pos,$n) if($pos -ge 4MB -and $pos -lt 8MB -and ($n -eq 4MB -or $pos -lt 4MB+192KB)){1117}else{0}}
 $r=[BackupDriveScanner]::Read($disk,0,12MB,512,1000,$stop,$old)|ConvertFrom-Json
 Assert (-not $r.Disconnected -and $r.BadCount -eq 3 -and $r.Bad[0].Offset -eq 4MB -and $r.Bad[0].Code -eq 1117 -and $r.Bytes -eq 12MB) 'a chunk where only some pieces fail with an I/O device error is recorded as bad areas, as before'
 # Every piece fails with an ordinary read error.
 [BackupDriveScanner]::Fault=[Func[long,int,int]]{param($pos,$n) if($pos -ge 4MB -and $pos -lt 8MB){23}else{0}}
 $r=[BackupDriveScanner]::Read($disk,0,12MB,512,1000,$stop,$old)|ConvertFrom-Json
 Assert (-not $r.Disconnected -and $r.BadCount -eq 64 -and $r.Bad[0].Code -eq 23 -and $r.Bytes -eq 12MB) 'a whole chunk that fails with an ordinary read error is recorded as bad areas, as before'
 # Every piece fails with an I/O device error, twice, while the rest of the drive still reads: a
 # damaged stretch. Ending the scan there would end it there every time it is continued.
 $script:reads=0
 [BackupDriveScanner]::Fault=[Func[long,int,int]]{param($pos,$n) if($pos -ge 4MB -and $pos -lt 8MB){$script:reads++;1117}else{0}}
 $r=[BackupDriveScanner]::Read($disk,0,12MB,512,1000,$stop,$old)|ConvertFrom-Json
 Assert (-not $r.Disconnected -and $r.BadCount -eq 64 -and $r.Bad[0].Code -eq 1117 -and $r.Bytes -eq 12MB) 'a whole chunk that fails with an I/O device error while the drive still answers elsewhere is a damaged stretch: recorded, and the scan goes on'
 Assert ($script:reads -eq 129) 'after it was read a second time, to be sure'
 # The same on the first chunk of a scan that is continued: the drive is asked at its start and further on.
 [BackupDriveScanner]::Fault=[Func[long,int,int]]{param($pos,$n) if($pos -ge 4MB -and $pos -lt 8MB){1117}else{0}}
 $r=[BackupDriveScanner]::Read($disk,4MB,8MB,512,1000,$stop,$old)|ConvertFrom-Json
 Assert (-not $r.Disconnected -and $r.BadCount -eq 64 -and $r.Bytes -eq 8MB) 'also when the scan starts at that stretch'
 # A short break in the connection: the chunk fails once whole and reads at the second look.
 $script:reads=0
 [BackupDriveScanner]::Fault=[Func[long,int,int]]{param($pos,$n) if($pos -ge 4MB -and $pos -lt 8MB -and $script:reads -lt 65){$script:reads++;1117}else{0}}
 $r=[BackupDriveScanner]::Read($disk,0,12MB,512,1000,$stop,$old)|ConvertFrom-Json
 Assert (-not $r.Disconnected -and $r.BadCount -eq 0 -and $r.RecoveredCount -eq 1 -and $r.Recovered[0].Offset -eq 4MB -and $r.Bytes -eq 12MB) 'a chunk that failed whole during a short break and reads afterwards is a place that needed a second try, not a bad area'
 [BackupDriveScanner]::Fault=$null

 # What the scan record and the view make of it.
 $cut=New-DriveScanState 'SER|1' 12MB $null
 Update-DriveScanState $cut ([pscustomobject]@{Bytes=4MB;Stopped=$false;Seconds=1.5;BadCount=0;Bad=@();RecoveredCount=0;Recovered=@();SlowCount=0;VerySlowCount=0;Slow=@();Disconnected=$true;DisconnectCode=1117}) 0
 $cut=$cut|ConvertTo-Json -Depth 8|ConvertFrom-Json
 Assert ($cut.Disconnected -and $cut.DisconnectOffset -eq 4MB -and $cut.DisconnectCode -eq 1117 -and $cut.NextOffset -eq 4MB -and -not $cut.Complete -and $cut.BadCount -eq 0) 'the scan record says how the scan ended and keeps the place to continue from'
 $s=Get-DriveSurfaceFindings $sample $cut
 Assert ($s.Status -eq 'NotRun' -and ($s.Lines -join ' ') -match 'not completed' -and ($s.Lines -join ' ') -match 'may have been disconnected \(cable, USB box, power\)' -and ($s.Lines -join ' ') -notmatch 'could not be read') 'a scan that ended that way is neither fine nor damaged: reading the disk counts as not checked, and the line says the drive may have been disconnected'
 $view=Get-DriveCheckView ([pscustomobject]@{Finished=$now.ToString('o');Sample=$sample;Events=@();Health=(New-DriveGroup 'OK' 'x');Connection=(New-DriveGroup 'OK' 'y');FileSystem=(New-DriveGroup 'OK' 'z')}) $cut
 Assert ($view.Groups.Surface.Status -eq 'NotRun' -and $view.Summary -match 'not checked: reading the disk' -and $view.Summary -ne 'no problems') 'and the one-line summary does not call the drive fine'
 $before=[pscustomobject]@{Size=12MB;NextOffset=12MB;Complete=$true;Finished=$now.AddDays(-9).ToString('o');BadCount=2;VerySlowCount=0;SlowCount=0;RecoveredCount=0;Bad=@([pscustomobject]@{Offset=5MB;Length=64KB;Code=23})}
 $cut2=New-DriveScanState 'SER|1' 12MB $before
 Update-DriveScanState $cut2 ([pscustomobject]@{Bytes=4MB;Stopped=$false;Seconds=1;BadCount=0;Bad=@();RecoveredCount=0;Recovered=@();SlowCount=0;VerySlowCount=0;Slow=@();Disconnected=$true;DisconnectCode=31}) 0
 $s=Get-DriveSurfaceFindings $sample $cut2
 Assert ($s.Status -eq 'Problem' -and ($s.Lines -join ' ') -match 'Earlier full scan: 2 areas could not be read' -and ($s.Lines -join ' ') -match 'may have been disconnected') 'what an earlier finished scan found still counts beside it'
 # The scan goes on: a stretch that reads clears the note; bad areas found before it are kept.
 Update-DriveScanState $cut2 ([pscustomobject]@{Bytes=4MB;Stopped=$false;Seconds=1;BadCount=1;Bad=@([pscustomobject]@{Offset=6MB;Length=64KB;Code=23});RecoveredCount=0;Recovered=@();SlowCount=0;VerySlowCount=0;Slow=@()}) 4MB
 Assert (-not $cut2.Disconnected -and $null -eq $cut2.DisconnectOffset -and $cut2.NextOffset -eq 8MB -and $cut2.BadCount -eq 1 -and @($cut2.Bad).Count -eq 1 -and $cut2.Seconds -eq 2) 'once the scan continues and reads, the record no longer says disconnected; a stretch read by the version before, without that field, counts as read'
 $part=[pscustomobject]@{Size=1TB;NextOffset=0.37TB;Complete=$false;Finished=$null;BadCount=0;VerySlowCount=0;SlowCount=0;Bad=@()}
 Assert ((Get-DriveSurfaceFindings $sample $part).Status -eq 'OK' -and ((Get-DriveSurfaceFindings $sample $part).Lines -join ' ') -notmatch 'disconnected') 'a scan record of the version before, stopped by the user, reads as before'

 # --- The health tool that runs as administrator ----------------------------------------------------
 $fake=Join-Path $work 'smartctl.exe';Set-Content -LiteralPath $fake -Value 'not smartctl'
 $t=Open-DriveCheckSmartTool $fake
 Assert ($t.Problem -match 'not the official smartctl 7\.5' -and $null -eq $t.Hold) 'a health tool given by path is refused too when it is not the official build'
 Assert ((Open-DriveCheckSmartTool (Join-Path $work 'missing.exe')).Problem -match 'not installed') 'a missing health tool is named as not installed'
 # What lies beside the tool is loaded by it as administrator too: its drive database, and any library.
 # The made-up tool below stands in for the official one by handing in its own checksum.
 $side=Join-Path $work 'side';New-Item -ItemType Directory -Path $side|Out-Null
 $exe=Join-Path $side 'smartctl.exe';Set-Content -LiteralPath $exe -Value 'stand-in tool';$exeHash=(Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash
 $db=Join-Path $side 'drivedb.h';Set-Content -LiteralPath $db -Value 'stand-in database';$dbHash=(Get-FileHash -LiteralPath $db -Algorithm SHA256).Hash
 $t=Open-DriveCheckSmartTool $exe -ToolHash $exeHash -DatabaseHash $dbHash
 Assert (-not $t.Problem -and $t.Hold -and $t.DatabaseHold) 'the tool with its own drive database beside it is accepted, and both stay open while the check runs'
 $t.Hold.Dispose();$t.DatabaseHold.Dispose()
 Add-Content -LiteralPath $db -Value 'changed'
 $t=Open-DriveCheckSmartTool $exe -ToolHash $exeHash -DatabaseHash $dbHash
 Assert ($t.Problem -match 'drive database' -and $null -eq $t.Hold) 'a drive database that is not the one from the official installer stops the tool from running'
 Remove-Item -LiteralPath $db
 $t=Open-DriveCheckSmartTool $exe -ToolHash $exeHash -DatabaseHash $dbHash
 Assert (-not $t.Problem -and $t.Hold -and $null -eq $t.DatabaseHold) 'without a database file the tool runs on its built-in one'
 $t.Hold.Dispose()
 # A database that cannot be opened (another program holds it) must not leave the tool itself held open.
 Set-Content -LiteralPath $db -Value 'stand-in database';$busy=[IO.File]::Open($db,'Open','ReadWrite','None')
 try{$t=Open-DriveCheckSmartTool $exe -ToolHash $exeHash -DatabaseHash $dbHash}finally{$busy.Dispose()}
 $free=try{$w=[IO.File]::Open($exe,'Open','ReadWrite','None');$w.Dispose();$true}catch{$false}
 Assert ($t.Problem -match 'drive database' -and $null -eq $t.Hold -and $free) 'a drive database that cannot be read stops the tool, and nothing is left held open'
 Remove-Item -LiteralPath $db
 Set-Content -LiteralPath (Join-Path $side 'version.dll') -Value 'x'
 $t=Open-DriveCheckSmartTool $exe -ToolHash $exeHash -DatabaseHash $dbHash
 Assert ($t.Problem -match 'version\.dll' -and $null -eq $t.Hold) 'a library placed beside the tool stops it from running, and is named'
}finally{if('BackupDriveScanner' -as [type]){[BackupDriveScanner]::Fault=$null};Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue}
Assert ((Format-DriveOffset 300MB) -eq '300 MiB' -and (Format-DriveOffset 5GB) -eq '5.0 GiB') 'sizes counted in binary units are labelled MiB and GiB'

# --- Running as administrator: who could change what the check runs ---------------------------
$me='S-1-5-21-1-2-3-1001'
function Rule([string]$Sid,[long]$Rights,[switch]$Deny,[switch]$InheritOnly){[pscustomobject]@{Sid=$Sid;Allow=-not $Deny;Rights=$Rights;InheritOnly=[bool]$InheritOnly}}
function Item([string]$Path,[string]$Role,[string]$Owner,$Rules){[pscustomobject]@{Path=$Path;Role=$Role;Owner=$Owner;Rules=@($Rules)}}
$modify=0x1301BF;$readOnly=0x1200A9;$full=0x1F01FF
$safe=@((Rule 'S-1-5-18' $full),(Rule 'S-1-5-32-544' $full),(Rule $me $full),(Rule 'S-1-5-32-545' $readOnly))
Assert (@(Get-DriveCheckPathRisks @(Item 'C:\Tool' 'Run' $me $safe) $me).Count -eq 0) 'only this user, SYSTEM and Administrators may change it and everyone may read: safe'
$open=@(Get-DriveCheckPathRisks @(Item 'E:\Tool\Invoke-DriveCheck.ps1' 'Run' $me ($safe+@(Rule 'S-1-5-11' $modify))) $me)
Assert ($open.Count -eq 1 -and $open[0].Sids -contains 'S-1-5-11') 'a file every signed-in account may change is reported with that account'
Assert (@(Get-DriveCheckPathRisks @(Item 'E:\Projects' 'Above' $me ($safe+@(Rule 'S-1-5-11' $modify))) $me).Count -eq 1) 'a folder above that other accounts may rename is reported'
Assert (@(Get-DriveCheckPathRisks @(Item 'E:\' 'Root' 'S-1-5-32-544' ($safe+@(Rule 'S-1-5-11' $modify))) $me).Count -eq 0) 'change rights on the drive root itself cannot swap a folder below it'
Assert (@(Get-DriveCheckPathRisks @(Item 'E:\' 'Root' 'S-1-5-32-544' ($safe+@(Rule 'S-1-5-11' $full))) $me).Count -eq 1) 'full control of the drive root can delete the folder below it'
Assert (@(Get-DriveCheckPathRisks @(Item 'C:\Tool\bin' 'Run' $me ($safe+@(Rule 'S-1-5-11' $modify -InheritOnly))) $me).Count -eq 0) 'a rule only for new files below does not count for the folder itself'
Assert (@(Get-DriveCheckPathRisks @(Item 'C:\Tool' 'Run' $me ($safe+@(Rule 'S-1-5-11' $modify -Deny))) $me).Count -eq 0) 'a deny rule is never a risk'
Assert (@(Get-DriveCheckPathRisks @(Item 'C:\Tool' 'Run' 'S-1-5-21-1-2-3-1003' $safe) $me).Count -eq 1) 'a file owned by another account is reported, since an owner can change its permissions'
$linked=Item 'E:\Tool' 'Run' $me $safe;$linked|Add-Member Link $true
Assert (@(Get-DriveCheckPathRisks @($linked) $me).Count -eq 1) 'a junction or link on the way counts as a risk, since what it leads to is not checked'
Assert ((Get-DriveCheckSmartToolHash) -match '^[0-9A-F]{64}$') 'the pinned smartctl hash is a SHA-256'
# The same rule on a real folder. Its permissions are set first: the temporary folder's own vary between computers.
$tool=Join-Path ([IO.Path]::GetTempPath()) ('drive-check-acl-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path (Join-Path $tool 'bin\smartmontools\bin') -Force|Out-Null
Set-Content -LiteralPath (Join-Path $tool 'Invoke-DriveCheck.ps1') -Value '# test'
try{
 $user=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
 # The folder gets its own rules; everything inside inherits them.
 & icacls.exe $tool /inheritance:r /grant:r "*${user}:(OI)(CI)F" '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' /Q|Out-Null
 & icacls.exe (Join-Path $tool '*') /reset /T /Q|Out-Null
 $mine=@(Get-DriveCheckPathRisks (Read-DriveCheckPathAccess $tool) $user|Where-Object {$_.Role -eq 'Run'})
 Assert ($mine.Count -eq 0) 'a tool folder only this user and administrators may change is safe to run as administrator'
 & icacls.exe $tool /grant '*S-1-5-11:(OI)(CI)M' /Q|Out-Null
 $opened=@(Get-DriveCheckPathRisks (Read-DriveCheckPathAccess $tool) $user|Where-Object {$_.Role -eq 'Run'})
 Assert ((@($opened|Where-Object {$_.Path -eq $tool}).Sids -contains 'S-1-5-11') -and @($opened|Where-Object {$_.Path -like '*\Invoke-DriveCheck.ps1'}).Count) 'once every signed-in account may change it, the folder and its files are reported'
}finally{if(Test-Path -LiteralPath $tool){& icacls.exe $tool /reset /T /Q|Out-Null;Remove-Item -LiteralPath $tool -Recurse -Force}}
Write-Output 'All drive-check rule tests passed.'
