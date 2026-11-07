#Requires -Version 7.2
# Drive check: turns what the drive, Windows and a read scan report into four plain verdicts.
#
#  Health      what the drive reports about itself (smartctl): replaced and suspect areas,
#              errors it could not fix, hours, temperature, wear, its own self-tests
#  Surface     reading the disk itself: sample reads and the full scan
#  Connection  the way to the drive: link speed, transfer errors, resets and disconnections
#  FileSystem  the file system's own structures (Windows online scan)
#
# Pure functions over data that Invoke-DriveCheck.ps1 collects as administrator, so the rules
# are tested without hardware. Statuses: OK, Warning, Problem, Unavailable, NotRun. The one
# exception, Read-DriveCheckPathAccess, reads who may change the files the check runs.
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'

$script:Rank=@{NotRun=0;Unavailable=1;OK=2;Warning=3;Problem=4}

function Get-Field($Node,[string[]]$Path) {
 # Nested lookup that returns $null for anything missing (smartctl leaves out what a drive lacks).
 foreach($k in $Path){if($null -eq $Node -or $Node -is [Array] -or -not $Node.PSObject.Properties[$k]){return $null};$Node=$Node.$k}
 $Node
}
function New-DriveGroup([string]$Status,[string[]]$Lines=@()){[pscustomobject]@{Status=$Status;Lines=@($Lines|Where-Object {$_})}}
function Get-WorstStatus([string[]]$Statuses) {
 $worst='NotRun';foreach($s in $Statuses){if($s -and $script:Rank[$s] -gt $script:Rank[$worst]){$worst=$s}};$worst
}
function Format-DriveHours($Hours) {
 $h=[double]$Hours;$text='{0:N0} hours' -f $h
 if($h -ge 24*365){$text+=' (about {0:N1} years of running)' -f ($h/24/365)}elseif($h -ge 48){$text+=' (about {0:N0} days of running)' -f ($h/24)}
 $text
}
function Format-DriveOffset([long]$Offset){if($Offset -ge 1GB){'{0:N1} GB' -f ($Offset/1GB)}else{'{0:N0} MB' -f ($Offset/1MB)}}

function Test-DriveSmartAnswer($Smart) {
 # True when the drive really answered, not only the USB box in front of it.
 if(-not $Smart){return $false}
 ($null -ne (Get-Field $Smart 'smart_status','passed')) -or [bool](Get-Field $Smart 'ata_smart_attributes','table') -or [bool](Get-Field $Smart 'nvme_smart_health_information_log')
}
function Get-DriveSelfTest($Smart) {
 # The self-test running now, if any, and from the drive's own log (newest first) the newest entry
 # (Last) and the newest finished short and long test (LastShort, LastLong). Each kind is judged on
 # its own: a short test that passes says nothing about a long one that failed before it.
 $now=$null
 $ataNow=Get-Field $Smart 'ata_smart_data','self_test','status','value'
 if($null -ne $ataNow -and ([int]$ataNow -band 0xF0) -eq 0xF0){$now=[pscustomobject]@{Remaining=[int](Get-Field $Smart 'ata_smart_data','self_test','status','remaining_percent')}}
 $nvmeNow=Get-Field $Smart 'nvme_self_test_log','current_self_test_operation','value'
 if($nvmeNow){$now=[pscustomobject]@{Remaining=100-[int](Get-Field $Smart 'nvme_self_test_log','current_self_test_completion_percent')}}
 $ata=@(Get-Field $Smart 'ata_smart_self_test_log','standard','table'|Where-Object {$_})
 $nvme=@(Get-Field $Smart 'nvme_self_test_log','table'|Where-Object {$_})
 $entries=@(if($ata.Count){
  foreach($e in $ata){
   $code=[int](Get-Field $e 'status','value') -shr 4
   $outcome=switch($code){0{'Passed'}{$_ -in 1,2}{'Interrupted'}15{'Running'}default{'Failed'}}
   [pscustomobject]@{Kind=if([string](Get-Field $e 'type','string') -match 'Extended|Long'){'Long'}else{'Short'};Outcome=$outcome;Text=[string](Get-Field $e 'status','string');Hours=Get-Field $e 'lifetime_hours'}
  }
 }else{
  foreach($e in $nvme){
   $code=[int](Get-Field $e 'self_test_result','value')
   $outcome=switch($code){0{'Passed'}{$_ -in 5,6,7}{'Failed'}default{'Interrupted'}}
   [pscustomobject]@{Kind=if([int](Get-Field $e 'self_test_code','value') -eq 2){'Long'}else{'Short'};Outcome=$outcome;Text=[string](Get-Field $e 'self_test_result','string');Hours=Get-Field $e 'power_on_hours'}
  }
 })
 $last=if($entries.Count){$entries[0]}else{$null}
 # A test that was interrupted proves nothing either way, so the verdict of each kind comes from its
 # newest test that passed or failed; a newer interrupted one is only mentioned (ShortInterrupted, LongInterrupted).
 $lastShort=@($entries|Where-Object {$_.Kind -eq 'Short' -and $_.Outcome -in 'Passed','Failed'})|Select-Object -First 1
 $lastLong=@($entries|Where-Object {$_.Kind -eq 'Long' -and $_.Outcome -in 'Passed','Failed'})|Select-Object -First 1
 $newestShort=@($entries|Where-Object {$_.Kind -eq 'Short' -and $_.Outcome -ne 'Running'})|Select-Object -First 1
 $newestLong=@($entries|Where-Object {$_.Kind -eq 'Long' -and $_.Outcome -ne 'Running'})|Select-Object -First 1
 $shortInterrupted=if($newestShort -and $newestShort.Outcome -eq 'Interrupted'){$newestShort}else{$null}
 $longInterrupted=if($newestLong -and $newestLong.Outcome -eq 'Interrupted'){$newestLong}else{$null}
 $supported=[bool](Get-Field $Smart 'ata_smart_data','capabilities','self_tests_supported') -or [bool](Get-Field $Smart 'nvme_optional_admin_commands','self_test')
 [pscustomobject]@{Supported=$supported;Running=$now;Last=$last;LastShort=$lastShort;LastLong=$lastLong;ShortInterrupted=$shortInterrupted;LongInterrupted=$longInterrupted;ShortMinutes=Get-Field $Smart 'ata_smart_data','self_test','polling_minutes','short';LongMinutes=Get-Field $Smart 'ata_smart_data','self_test','polling_minutes','extended'}
}

function Get-DriveHealthFindings($Smart,[string]$Unavailable='') {
 # Unavailable: why there is no report (no tool installed, or the box does not pass the request on).
 if(-not (Test-DriveSmartAnswer $Smart)){
  $why=if($Unavailable){$Unavailable}else{'The drive did not answer. Its USB box or adapter probably does not pass the request on.'}
  return New-DriveGroup 'Unavailable' @($why)
 }
 $bad=[Collections.Generic.List[string]]::new();$warn=[Collections.Generic.List[string]]::new();$info=[Collections.Generic.List[string]]::new()
 if((Get-Field $Smart 'smart_status','passed') -eq $false){$bad.Add('The drive itself reports that it is failing. Copy what you need from it and replace it.')}
 $nvme=Get-Field $Smart 'nvme_smart_health_information_log'
 if($nvme){
  $critical=[int](Get-Field $nvme 'critical_warning');$media=[long](Get-Field $nvme 'media_errors')
  $spare=Get-Field $nvme 'available_spare';$spareMin=Get-Field $nvme 'available_spare_threshold';$used=Get-Field $nvme 'percentage_used'
  if($critical){$bad.Add("The drive raised a critical warning (code $critical).")}
  if($media){$bad.Add("Areas it could not read: $media.")}else{$info.Add('Areas it could not read: none.')}
  if($null -ne $spare){
   $line="Spare area left for replacing worn parts: $spare%."
   if($null -ne $spareMin -and [int]$spare -le [int]$spareMin){$bad.Add($line+' That is at the limit the maker sets.')}else{$info.Add($line)}
  }
  if($null -ne $used){
   $line="Wear: $used% of its rated life used."
   if([int]$used -ge 100){$bad.Add($line)}elseif([int]$used -ge 90){$warn.Add($line)}else{$info.Add($line)}
  }
 }else{
  $raw=@{};foreach($a in @(Get-Field $Smart 'ata_smart_attributes','table')){if($a){$raw[[int]$a.id]=[long](Get-Field $a 'raw','value')}}
  # Attributes 5, 197, 198 and 187 are the ones that go up before most drive failures.
  if($raw.ContainsKey(5)){$line="Areas already replaced because they went bad: $($raw[5])."; if($raw[5] -gt 0){$warn.Add($line+' A few can be normal; watch whether the number grows.')}else{$info.Add($line)}}
  if($raw.ContainsKey(197)){$line="Areas suspected bad, waiting to be replaced: $($raw[197])."; if($raw[197] -gt 0){$bad.Add($line)}else{$info.Add($line)}}
  if($raw.ContainsKey(198)){$line="Areas it could not read at all: $($raw[198])."; if($raw[198] -gt 0){$bad.Add($line)}else{$info.Add($line)}}
  if($raw.ContainsKey(187)){$line="Read errors it could not fix: $($raw[187])."; if($raw[187] -gt 0){$warn.Add($line)}else{$info.Add($line)}}
  if(-not ($raw.ContainsKey(5) -or $raw.ContainsKey(197) -or $raw.ContainsKey(198))){$info.Add('This drive does not report replaced or suspect areas.')}
 }
 $hours=Get-Field $Smart 'power_on_time','hours'
 if($null -ne $hours){$info.Add('Running time: '+(Format-DriveHours $hours)+'.')}
 $temp=Get-Field $Smart 'temperature','current'
 if($null -ne $temp){
  $limit=Get-Field $Smart 'nvme_composite_temperature_threshold','warning'
  if(-not $limit){$limit=if($nvme){70}else{55}}
  $line="Temperature: $temp °C."
  if([int]$temp -ge [int]$limit){$warn.Add($line+" That is hot for this drive (warning from $limit °C). Give it air, or check it after it cools down.")}else{$info.Add($line)}
 }
 $t=Get-DriveSelfTest $Smart
 if($t.Running){$info.Add("A self-test is running now, about $($t.Running.Remaining)% left.")}
 # The newest finished test of each kind counts, so a quick check's short test cannot hide a long
 # test that failed: that stays a problem until a newer long test passes.
 $tests=@(@($t.LongInterrupted,$t.LastLong,$t.ShortInterrupted,$t.LastShort)|Where-Object {$_})
 foreach($test in $tests){
  $kind=if($test.Kind -eq 'Long'){'Long self-test'}else{'Short self-test'}
  $when=if($null -ne $test.Hours -and $null -ne $hours){$ago=[double]$hours-[double]$test.Hours;if($ago -lt 1){', just now'}else{' {0:N0} running hours ago' -f $ago}}else{''}
  switch($test.Outcome){
   'Passed'{$info.Add("${kind}: passed$when.")}
   'Failed'{$bad.Add("${kind}: failed$when ($($test.Text)).$(if($test.Kind -eq 'Long'){' This counts until a newer long self-test passes.'})")}
   'Interrupted'{$info.Add("${kind}: did not finish$when ($($test.Text)). Run it again when the drive can stay on.")}
  }
 }
 if(-not $tests.Count -and -not $t.Supported){$info.Add('This drive does not offer self-tests.')}
 $status=if($bad.Count){'Problem'}elseif($warn.Count){'Warning'}else{'OK'}
 New-DriveGroup $status @(@($bad)+@($warn)+@($info))
}

function Get-DriveSurfaceFindings($Sample,$Scan) {
 # Sample: the start/middle/end reads of the last quick check. Scan: the full scan record.
 $bad=[Collections.Generic.List[string]]::new();$warn=[Collections.Generic.List[string]]::new();$info=[Collections.Generic.List[string]]::new()
 if($Sample){
  $regions=@($Sample.Regions)
  $speeds=($regions|ForEach-Object {'{0:N0}' -f $_.MBps}) -join ', '
  $errors=($regions|Measure-Object -Property BadCount -Sum).Sum
  if($errors){$bad.Add("Sample reads at the start, middle and end: $errors unreadable areas.")}
  else{$info.Add("Sample reads at the start, middle and end: no errors ($speeds MB/s).")}
 }
 if($Scan){
  $pct=if($Scan.Size){[math]::Floor(100*[double]$Scan.NextOffset/[double]$Scan.Size)}else{0}
  $first=@($Scan.Bad|Select-Object -First 3|ForEach-Object {Format-DriveOffset $_.Offset}) -join ', '
  if($Scan.BadCount){$bad.Add("Full scan: $($Scan.BadCount) areas could not be read (first at $first). Do not trust this drive with your only copy.")}
  if($Scan.VerySlowCount){$warn.Add("Full scan: $($Scan.VerySlowCount) places took over a second to read. The drive had to try hard there; that is often an early sign of damage.")}
  # Some slow places come from Windows or other programs using the drive at the same moment; many do not.
  elseif($Scan.SlowCount -gt [math]::Max(20,[double]$Scan.NextOffset/4MB/500)){$warn.Add("Full scan: $($Scan.SlowCount) places were much slower than the rest.")}
  if($Scan.Complete){
   if(-not $Scan.BadCount){$info.Add("Full scan: finished $(Format-DriveAge $Scan.Finished), every part could be read.")}
  }else{$info.Add("Full scan: stopped at $pct%. Continue it any time; it goes on from there.")}
 }else{$info.Add('Full scan: not run yet. It reads the whole drive and takes hours.')}
 $status=if($bad.Count){'Problem'}elseif($warn.Count){'Warning'}elseif($Sample -or ($Scan -and $Scan.Complete)){'OK'}else{'NotRun'}
 New-DriveGroup $status @(@($bad)+@($warn)+@($info))
}

# Windows event log entries about disks (warnings and errors only). Kind decides the group;
# Problem/Warning the verdict.
$script:DiskEvents=@(
 @{Provider='disk';Id=7;Group='Surface';Status='Problem';Text='Windows found a damaged area while using the drive'}
 @{Provider='disk';Id=52;Group='Health';Status='Problem';Text='Windows was warned that the drive is about to fail'}
 @{Provider='disk';Id=154;Group='Surface';Status='Problem';Text='a read or write failed because of a hardware error'}
 @{Provider='disk';Id=11;Group='Connection';Status='Warning';Text='transfer errors between the computer and the drive'}
 @{Provider='disk';Id=15;Group='Connection';Status='Warning';Text='the drive was not ready when asked'}
 @{Provider='disk';Id=51;Group='Connection';Status='Warning';Text='an error while moving data to or from the drive'}
 @{Provider='disk';Id=153;Group='Connection';Status='Warning';Text='reads or writes had to be repeated'}
 @{Provider='disk';Id=157;Group='Connection';Status='Warning';Text='the drive was disconnected without safe removal'}
 @{Provider='Ntfs';Id=50;Group='FileSystem';Status='Warning';Text='Windows could not finish saving data to the drive'}
 @{Provider='Ntfs';Id=55;Group='FileSystem';Status='Problem';Text='Windows found damage in the file system'}
 @{Provider='Ntfs';Id=140;Group='FileSystem';Status='Warning';Text='a write to the file system failed'}
)
$script:ResetProviders=@('uaspstor','USBSTOR','stornvme','storahci')

function Get-DriveConnectionKey([string]$Serial,[string]$Model,$Capacity) {
 # The same drive under any disk number: its serial number, or model and size when it reports none.
 $s=$Serial.Trim().TrimEnd('.').Trim()
 if($s -and $s -ne 'NULL'){'S:'+$s}else{'M:'+$Model.Trim()+'|'+$Capacity}
}
function Get-DriveEventFindings($Events,[int]$DiskNumber,[string]$Letter,[bool]$Usb,$Connections=@()) {
 # Events name the disk as \Device\Harddisk<N>\ (in their data, in every Windows language) and
 # volumes by letter. Disk numbers move between drives as they are plugged in, so an entry counts
 # only when this drive held that number at the time. Connections: Windows' record of every drive
 # arrival (Time, DiskNumber, Key); the newest one for this number is this drive's own arrival.
 # Without that record only the number is compared. Letters and controller resets (129) name no
 # disk, so they count only after this drive arrived.
 $byNumber=@{};foreach($c in @($Connections|Where-Object {$_}|Sort-Object {[datetime]$_.Time})){$n=[int]$c.DiskNumber;if(-not $byNumber.ContainsKey($n)){$byNumber[$n]=[Collections.Generic.List[object]]::new()};$byNumber[$n].Add($c)}
 $own=if($byNumber.ContainsKey($DiskNumber)){$byNumber[$DiskNumber][$byNumber[$DiskNumber].Count-1]}else{$null}
 $since=if($own){[datetime]$own.Time}else{[datetime]::MinValue}
 $found=@{}
 foreach($e in @($Events)){
  if(-not $e){continue}
  $text=[string]$e.Message;$when=[datetime]$e.TimeCreated
  $kind=$script:DiskEvents|Where-Object {$_.Provider -eq $e.ProviderName -and $_.Id -eq [int]$e.Id}|Select-Object -First 1
  if($kind){
   if($text -match '\\Harddisk(\d+)\\|PhysicalDrive(\d+)\b'){
    $n=[int]$(if($Matches[1]){$Matches[1]}else{$Matches[2]})
    if($n -ne $DiskNumber){continue}
    if($own -and $when -lt $since){
     $then=$null;foreach($c in $byNumber[$n]){if([datetime]$c.Time -le $when){$then=$c}else{break}}
     if(-not $then -or $then.Key -ne $own.Key){continue}
    }
   }elseif($Letter -and $when -ge $since -and $text -match "(^|[^A-Za-z])$([regex]::Escape($Letter.ToUpperInvariant())):"){}
   else{continue}
  }elseif([int]$e.Id -eq 129 -and $e.ProviderName -in $script:ResetProviders -and $when -ge $since -and ($Usb -or $e.ProviderName -notin 'uaspstor','USBSTOR')){
   $kind=@{Group='Connection';Status='Warning';Text=if($Usb){'a USB drive stopped answering and Windows reset the connection'}else{'the connection to a drive was reset'}}
  }else{continue}
  $key=$kind.Text
  if(-not $found.ContainsKey($key)){$found[$key]=[pscustomobject]@{Group=$kind.Group;Status=$kind.Status;Text=$kind.Text;Count=0;Last=$null}}
  $f=$found[$key];$f.Count++;if(-not $f.Last -or $when -gt [datetime]$f.Last){$f.Last=$when}
 }
 foreach($f in $found.Values){
  $times=if($f.Count -eq 1){'once'}else{"$($f.Count) times"}
  [pscustomobject]@{Group=$f.Group;Status=$f.Status;Line=[string]::Format([Globalization.CultureInfo]::GetCultureInfo('en-GB'),'Windows log: {0}, {1} in the last 30 days (last on {2:d MMM HH:mm}).',($f.Text.Substring(0,1).ToUpper()+$f.Text.Substring(1)),$times,$f.Last)}
 }
}

function Get-DriveConnectionFindings($Link,[string]$BusType,$Smart,$Counters) {
 $warn=[Collections.Generic.List[string]]::new();$info=[Collections.Generic.List[string]]::new()
 if($BusType -eq 'USB'){
  if($Link -and $Link.PSObject.Properties['Speed']){
   if(-not $Link.SuperSpeedActive){$warn.Add("Connected at USB 2 speed ($($Link.Speed)). Use a USB 3 port and the drive's own cable, without a hub.")}
   elseif([string]$Link.Speed -match 'SuperSpeedPlus'){$info.Add('Connected at full speed (10 Gbit/s or more).')}
   else{$info.Add('Connected at 5 Gbit/s. That is fine for most drives.')}
  }else{$info.Add('The USB link speed could not be read.')}
 }elseif($BusType){$info.Add("Connected directly ($BusType), not through USB.")}
 $crc=$null;foreach($a in @(Get-Field $Smart 'ata_smart_attributes','table')){if($a -and [int]$a.id -eq 199){$crc=[long](Get-Field $a 'raw','value')}}
 if($null -ne $crc){if($crc -gt 0){$warn.Add("The drive counted $crc damaged transfers over its life. They usually come from a cable or port, not the drive; if this number grows, change the cable.")}else{$info.Add('Damaged transfers counted by the drive: none.')}}
 if($Counters){
  $failed=[long]$Counters.ReadErrorsUncorrected+[long]$Counters.WriteErrorsUncorrected
  if($failed -gt 0){$warn.Add("Windows counted $failed reads or writes that failed on this drive.")}
  elseif($null -ne $Counters.ReadErrorsTotal){$info.Add('Failed reads and writes counted by Windows: none.')}
 }
 $status=if($warn.Count){'Warning'}elseif($info.Count){'OK'}else{'Unavailable'}
 New-DriveGroup $status @(@($warn)+@($info))
}

function Get-DriveFileSystemFindings([string]$Letter,[string]$FileSystem,[string]$ScanResult,[string]$ScanError,[string]$VolumeHealth) {
 $bad=[Collections.Generic.List[string]]::new();$warn=[Collections.Generic.List[string]]::new();$info=[Collections.Generic.List[string]]::new()
 switch($ScanResult){
  'NoErrorsFound'{$info.Add("The $FileSystem file system is intact: Windows checked its tables and found no errors.")}
  {$_ -in 'ScanNeeded','SpotFixNeeded'}{$warn.Add("Windows found a small file system problem. A short repair fixes it: open Terminal as administrator and run  chkdsk $($Letter): /spotfix")}
  'FullRepairNeeded'{$bad.Add("The file system needs a full repair. Copy what you need first, then run  chkdsk $($Letter): /f  as administrator.")}
  ''{if($ScanError){$info.Add("Windows could not scan this file system: $ScanError")}elseif($FileSystem -ne 'NTFS'){$info.Add("Windows can scan only NTFS while the drive is in use; this drive uses $FileSystem.")}}
  default{$warn.Add("Windows reported: $ScanResult.")}
 }
 if($VolumeHealth -and $VolumeHealth -ne 'Healthy'){$warn.Add("Windows marks this volume as $VolumeHealth.")}
 $status=if($bad.Count){'Problem'}elseif($warn.Count){'Warning'}elseif($ScanResult -eq 'NoErrorsFound'){'OK'}else{'Unavailable'}
 New-DriveGroup $status @(@($bad)+@($warn)+@($info))
}

function Merge-DriveEvents($Group,$Events,[string]$Name) {
 # Adds the log lines that belong to this group; a log entry can only make the verdict worse.
 $mine=@($Events|Where-Object {$_ -and $_.Group -eq $Name})
 if(-not $mine.Count){return $Group}
 $status=Get-WorstStatus (@($Group.Status)+@($mine.Status))
 New-DriveGroup $status (@($mine.Line)+@($Group.Lines))
}

function Get-DriveCheckView($Report,$Scan) {
 # The four groups as the window shows them: the last quick check plus the newest full scan.
 $events=@(if($Report){$Report.Events})
 $sample=if($Report){$Report.Sample}else{$null}
 $health=if($Report){$Report.Health}else{New-DriveGroup 'NotRun' @('Not checked yet.')}
 $surface=Merge-DriveEvents (Get-DriveSurfaceFindings $sample $Scan) $events 'Surface'
 $connection=if($Report){$Report.Connection}else{New-DriveGroup 'NotRun' @('Not checked yet.')}
 $fs=if($Report){$Report.FileSystem}else{New-DriveGroup 'NotRun' @('Not checked yet.')}
 $groups=[ordered]@{Health=$health;Surface=$surface;Connection=$connection;FileSystem=$fs}
 [pscustomobject]@{Groups=$groups;Overall=Get-WorstStatus @($groups.Values.Status);When=if($Report){$Report.Finished}else{$null}}
}

# --- Running as administrator -----------------------------------------------------------------
# The check runs as administrator. Whoever can change a file it runs or loads, put a file next to
# smartctl.exe, or rename a folder above them could make it run anything as administrator.

# SHA-256 of bin\smartctl.exe (64-bit) inside the official smartmontools 7.5 installer, whose own
# hash Install-DriveTools.ps1 checks before it runs it.
function Get-DriveCheckSmartToolHash {'B5DB94E5082C042BE44994B7A4FA8F7B5C8E713B2AB1C9A560D8F7A7995EA27D'}

function Get-DriveCheckPathRisks($Items,[string]$UserSid) {
 # Pure rule over what Read-DriveCheckPathAccess reads. Items: Path, Role, Owner (a SID) and Rules
 # (Sid, Allow, Rights as a number, InheritOnly). Role Run: a file the check runs or loads, or a
 # folder holding them. Above: a folder further up the path, which must not be renamed. Root: the
 # drive's root folder, which cannot be renamed itself. Returns each path that an account other than
 # this user, SYSTEM, Administrators, TrustedInstaller or the owner placeholders could change, with
 # those accounts. Deny rules are ignored, which can only report more, never less.
 $trusted=@('S-1-5-18','S-1-5-32-544','S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464','S-1-3-0','S-1-3-4',$UserSid)
 $masks=@{
  # Add a file or folder, delete children or itself, change permissions or owner, generic all/write.
  Run=(0x2 -bor 0x4 -bor 0x40 -bor 0x10000 -bor 0x40000 -bor 0x80000 -bor 0x10000000 -bor 0x40000000)
  # Rename it (delete) or the folder below it (delete children), or take it over.
  Above=(0x40 -bor 0x10000 -bor 0x40000 -bor 0x80000 -bor 0x10000000)
  Root=(0x40 -bor 0x40000 -bor 0x80000 -bor 0x10000000)}
 foreach($i in @($Items)){
  if(-not $masks.ContainsKey([string]$i.Role)){throw "Unknown role $($i.Role) for $($i.Path)"}
  $mask=[long]$masks[[string]$i.Role];$who=@()
  if($i.Owner -and $i.Owner -notin $trusted){$who+=[string]$i.Owner}
  foreach($r in @($i.Rules)){if($r.Allow -and -not $r.InheritOnly -and $r.Sid -notin $trusted -and (([long]$r.Rights -band $mask) -ne 0)){$who+=[string]$r.Sid}}
  # A junction or symbolic link leads somewhere whose folders above are not checked here, so a link
  # anywhere on the way counts as a risk by itself.
  $link=[bool]($i.PSObject.Properties['Link'] -and $i.Link)
  if($who.Count -or $link){[pscustomobject]@{Path=[string]$i.Path;Role=[string]$i.Role;Sids=@($who|Sort-Object -Unique);Link=$link}}
 }
}

function Read-DriveCheckPathAccess([string]$ToolRoot) {
 # The one function here that reads the computer: owner and access rules of what the check runs or
 # loads (Invoke-DriveCheck.ps1, its modules, Measure-BackupDisk.ps1, smartctl and its folder), and
 # of every folder above the tool's folder.
 $root=[IO.Path]::GetFullPath($ToolRoot).TrimEnd('\')
 $run=@($root)+@('Invoke-DriveCheck.ps1','Backup.Status.psm1','Backup.DriveCheck.psm1','Measure-BackupDisk.ps1','bin','bin\smartmontools','bin\smartmontools\bin','bin\smartmontools\bin\smartctl.exe','bin\smartmontools\bin\drivedb.h'|ForEach-Object {Join-Path $root $_})
 $read={param($Path,$Role)
  $acl=Get-Acl -LiteralPath $Path
  $isLink=[bool]((Get-Item -LiteralPath $Path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)
  [pscustomobject]@{Path=$Path;Role=$Role;Link=$isLink;Owner=$acl.GetOwner([Security.Principal.SecurityIdentifier]).Value
   Rules=@($acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier])|ForEach-Object {[pscustomobject]@{Sid=$_.IdentityReference.Value;Allow=($_.AccessControlType -eq 'Allow');Rights=[long]$_.FileSystemRights;InheritOnly=[bool]($_.PropagationFlags -band [Security.AccessControl.PropagationFlags]::InheritOnly)}})}
 }
 foreach($p in $run){if(Test-Path -LiteralPath $p){& $read $p 'Run'}}
 $d=[IO.DirectoryInfo]::new($root).Parent
 while($d){& $read $d.FullName $(if($d.Parent){'Above'}else{'Root'});$d=$d.Parent}
}

function Format-DriveAge($When) {
 if(-not $When){return 'at an unknown time'}
 $span=(Get-Date)-[datetime]$When
 if($span.TotalMinutes -lt 2){'just now'}elseif($span.TotalHours -lt 1){'{0:N0} minutes ago' -f $span.TotalMinutes}elseif($span.TotalHours -lt 36){'{0:N0} hours ago' -f $span.TotalHours}else{'{0:N0} days ago' -f $span.TotalDays}
}

Export-ModuleMember -Function Get-Field,New-DriveGroup,Get-WorstStatus,Test-DriveSmartAnswer,Get-DriveSelfTest,Get-DriveHealthFindings,Get-DriveSurfaceFindings,Get-DriveConnectionKey,Get-DriveEventFindings,Get-DriveConnectionFindings,Get-DriveFileSystemFindings,Merge-DriveEvents,Get-DriveCheckView,Format-DriveOffset,Format-DriveAge,Get-DriveCheckSmartToolHash,Get-DriveCheckPathRisks,Read-DriveCheckPathAccess
