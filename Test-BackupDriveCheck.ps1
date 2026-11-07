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
Assert ($s.Status -eq 'Problem' -and $s.Lines[0] -match 'first at 5.0 GB') 'unreadable areas are a problem and say where'
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
