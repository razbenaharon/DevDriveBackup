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
# are tested without hardware. Statuses: OK, Warning, Problem, Unavailable, NotRun. The exceptions
# are named where they stand: the full scan's saved position, stop request and reader, the health
# tool's checksum, and Read-DriveCheckPathAccess, which reads who may change the files the check runs.
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
# Places on the disk are counted in binary units, so they are labelled that way (1 GiB = 1024 MiB).
function Format-DriveOffset([long]$Offset){if($Offset -ge 1GB){'{0:N1} GiB' -f ($Offset/1GB)}else{'{0:N0} MiB' -f ($Offset/1MB)}}

function Test-DriveSmartAnswer($Smart) {
 # True when the drive's own counters came through, not only the USB box in front of it. A box that
 # passes on just the overall "passed" flag gives nothing to judge, so that is no answer; a drive
 # that says it is failing always is.
 if(-not $Smart){return $false}
 ((Get-Field $Smart 'smart_status','passed') -eq $false) -or [bool](Get-Field $Smart 'ata_smart_attributes','table') -or [bool](Get-Field $Smart 'nvme_smart_health_information_log')
}
function Test-DriveSmartFlagOnly($Smart){[bool]$Smart -and -not (Test-DriveSmartAnswer $Smart) -and ((Get-Field $Smart 'smart_status','passed') -eq $true)}
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
   $kind=switch -Regex ([string](Get-Field $e 'type','string')){'Extended|Long'{'Long';break}'Short'{'Short';break}'Selective'{'Selective';break}'Conveyance'{'Conveyance';break}default{'Other'}}
   [pscustomobject]@{Kind=$kind;Outcome=$outcome;Text=[string](Get-Field $e 'status','string');Hours=Get-Field $e 'lifetime_hours'}
  }
 }else{
  foreach($e in $nvme){
   $code=[int](Get-Field $e 'self_test_result','value')
   $outcome=switch($code){0{'Passed'}{$_ -in 5,6,7}{'Failed'}default{'Interrupted'}}
   [pscustomobject]@{Kind=switch([int](Get-Field $e 'self_test_code','value')){2{'Long'}1{'Short'}default{'Other'}};Outcome=$outcome;Text=[string](Get-Field $e 'self_test_result','string');Hours=Get-Field $e 'power_on_hours'}
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
 # Selective, conveyance and maker-specific tests: the newest finished one of each kind, so one that
 # failed is not hidden by a short test that passed after it.
 $others=@(foreach($k in @($entries|ForEach-Object {$_.Kind}|Where-Object {$_ -notin 'Short','Long'}|Select-Object -Unique)){@($entries|Where-Object {$_.Kind -eq $k -and $_.Outcome -in 'Passed','Failed'})|Select-Object -First 1})
 $supported=[bool](Get-Field $Smart 'ata_smart_data','capabilities','self_tests_supported') -or [bool](Get-Field $Smart 'nvme_optional_admin_commands','self_test')
 [pscustomobject]@{Supported=$supported;Running=$now;Last=$last;LastShort=$lastShort;LastLong=$lastLong;Others=$others;ShortInterrupted=$shortInterrupted;LongInterrupted=$longInterrupted;ShortMinutes=Get-Field $Smart 'ata_smart_data','self_test','polling_minutes','short';LongMinutes=Get-Field $Smart 'ata_smart_data','self_test','polling_minutes','extended'}
}

function Get-DriveHealthFindings($Smart,[string]$Unavailable='') {
 # Unavailable: why there is no report (no tool installed, or the box does not pass the request on).
 if(-not (Test-DriveSmartAnswer $Smart)){
  $why=if(Test-DriveSmartFlagOnly $Smart){'The USB box passed on only the drive''s overall "passed" flag, not its counters or self-tests, so the drive''s health cannot be judged through this box.'}elseif($Unavailable){$Unavailable}else{'The drive did not answer. Its USB box or adapter probably does not pass the request on.'}
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
 $tests=@(@($t.LongInterrupted,$t.LastLong,$t.ShortInterrupted,$t.LastShort)+@($t.Others)|Where-Object {$_})
 foreach($test in $tests){
  $kind=switch($test.Kind){'Long'{'Long self-test'}'Short'{'Short self-test'}'Other'{'Self-test of another kind'}default{"$($test.Kind) self-test"}}
  $when=if($null -ne $test.Hours -and $null -ne $hours){$ago=[double]$hours-[double]$test.Hours;if($ago -lt 1){', just now'}else{' {0:N0} running hours ago' -f $ago}}else{''}
  switch($test.Outcome){
   'Passed'{$info.Add("${kind}: passed$when.")}
   'Failed'{$bad.Add("${kind}: failed$when ($($test.Text)).$(if($test.Kind -eq 'Long'){' This counts until a newer long self-test passes.'}elseif($test.Kind -ne 'Short'){' This counts until a newer self-test of the same kind passes.'})")}
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
 # A quick check stopped before its first read leaves a sample without regions: that is no sample.
 $regions=@(@(Get-Field $Sample 'Regions')|Where-Object {$_})
 if($regions.Count){
  $speeds=($regions|ForEach-Object {'{0:N0}' -f $_.MBps}) -join ', '
  $errors=[long]0;$again=[long]0;foreach($r in $regions){$errors+=[long](Get-Field $r 'BadCount');$again+=[long](Get-Field $r 'RecoveredCount')}
  if($errors){$bad.Add("Sample reads at the start, middle and end: $errors unreadable areas.")}
  else{$info.Add("Sample reads at the start, middle and end: no errors ($speeds MB/s).")}
  if($again){$warn.Add("Sample reads: $again places could be read only at the second try. That is often an early sign of damage, or of a loose cable.")}
 }
 $known=Test-DriveScanRecord $Scan
 if($known){
  $pct=if($Scan.Size){[math]::Floor(100*[double]$Scan.NextOffset/[double]$Scan.Size)}else{0}
  $found=Get-DriveScanLines $Scan 'Full scan' ''
  foreach($l in $found.Bad){$bad.Add($l)};foreach($l in $found.Warn){$warn.Add($l)}
  if($Scan.Complete){
   if(-not $found.Bad.Count){$info.Add("Full scan: finished $(Format-DriveAge (Get-Field $Scan 'Finished')), every part could be read.")}
  }else{
   $info.Add("Full scan: stopped at $pct%. Continue it any time; it goes on from there.")
   # A scan that has not finished says nothing about the parts it has not reached, so what the last
   # finished scan found still counts until this one is through.
   $before=Get-Field $Scan 'Previous'
   if(Test-DriveScanRecord $before){
    $found=Get-DriveScanLines $before 'Earlier full scan' ' This counts until a new full scan finishes.'
    foreach($l in $found.Bad){$bad.Add($l)};foreach($l in $found.Warn){$warn.Add($l)}
   }
  }
 }else{$info.Add('Full scan: not run yet. It reads the whole drive and takes hours.')}
 $status=if($bad.Count){'Problem'}elseif($warn.Count){'Warning'}elseif($regions.Count -or ($known -and $Scan.Complete)){'OK'}else{'NotRun'}
 New-DriveGroup $status @(@($bad)+@($warn)+@($info))
}
function Test-DriveScanRecord($Scan) {
 # A scan record with the fields every version wrote. Newer fields (RecoveredCount, Previous) are
 # read with Get-Field, so a record saved by an older version keeps working.
 $Scan -is [pscustomobject] -and $Scan -isnot [Array] -and $null -ne (Get-Field $Scan 'Size') -and $null -ne (Get-Field $Scan 'NextOffset') -and $null -ne (Get-Field $Scan 'Complete')
}
function Get-DriveScanLines($Scan,[string]$Name,[string]$Until) {
 # What one scan record found, as problem lines (Bad) and warning lines (Warn).
 $bad=@();$warn=@()
 $n=[long](Get-Field $Scan 'BadCount');$very=[long](Get-Field $Scan 'VerySlowCount');$slow=[long](Get-Field $Scan 'SlowCount');$again=[long](Get-Field $Scan 'RecoveredCount')
 if($n){
  $first=@(@(Get-Field $Scan 'Bad')|Where-Object {$_}|Select-Object -First 3|ForEach-Object {Format-DriveOffset $_.Offset}) -join ', '
  $bad+="${Name}: $n areas could not be read (first at $first). Do not trust this drive with your only copy.$Until"
 }
 # A read that failed and then worked in smaller pieces: the drive, or the way to it, needed a second try.
 if($again){$warn+="${Name}: $again places could be read only at the second try. That is often an early sign of damage, or of a loose cable.$Until"}
 if($very){$warn+="${Name}: $very places took over a second to read. The drive had to try hard there; that is often an early sign of damage.$Until"}
 # Some slow places come from Windows or other programs using the drive at the same moment; many do not.
 elseif($slow -gt [math]::Max(20,[double]$Scan.NextOffset/4MB/500)){$warn+="${Name}: $slow places were much slower than the rest.$Until"}
 [pscustomobject]@{Bad=@($bad);Warn=@($warn)}
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

function Get-DriveConnectionKey([string]$Serial,[string]$Model,$Capacity) {
 # The same drive under any disk number: its serial number, or model and size when it reports none.
 $s=$Serial.Trim().TrimEnd('.').Trim()
 if($s -and $s -ne 'NULL'){'S:'+$s}else{'M:'+$Model.Trim()+'|'+$Capacity}
}
function Get-DriveEventFindings($Events,[int]$DiskNumber,[string]$Letter,[bool]$Usb,$Connections=@(),[string]$BusType='') {
 # Events name the disk as \Device\Harddisk<N>\ (in their data, in every Windows language) and
 # volumes by letter. Disk numbers move between drives as they are plugged in, so an entry counts
 # only when this drive held that number at the time. Connections: Windows' record of every drive
 # arrival (Time, DiskNumber, Key); the newest one for this number is this drive's own arrival.
 # Without that record only the number is compared. Letters and controller resets (129) name no
 # disk, so they count only after this drive arrived, and a reset only when it was written by the
 # driver of this drive's own kind of connection (BusType): a reset of the internal drive says
 # nothing about a USB drive. Without BusType, Usb alone decides as far as it can.
 $isUsb=if($BusType){$BusType -eq 'USB'}else{$Usb}
 $resetFrom=@(switch -Regex ($BusType){'^USB$'{'uaspstor','USBSTOR';break}'^NVMe$'{'stornvme';break}'^(SATA|ATA|ATAPI|RAID)$'{'storahci';break}'^$'{if($Usb){'uaspstor','USBSTOR'}else{'stornvme','storahci'};break}})
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
  }elseif([int]$e.Id -eq 129 -and $e.ProviderName -in $resetFrom -and $when -ge $since){
   $kind=@{Group='Connection';Status='Warning';Text=if($isUsb){'a USB drive stopped answering and Windows reset the connection'}else{'the connection to a drive was reset'}}
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
 # checked: something about the connection was really read. A line saying that the link speed
 # could not be read is no check, so alone it gives "not available", never "no problems".
 $checked=$false
 if($BusType -eq 'USB'){
  if($Link -and $Link.PSObject.Properties['Speed']){
   $checked=$true
   if(-not $Link.SuperSpeedActive){$warn.Add("Connected at USB 2 speed ($($Link.Speed)). Use a USB 3 port and the drive's own cable, without a hub.")}
   elseif([string]$Link.Speed -match 'SuperSpeedPlus'){$info.Add('Connected at full speed (10 Gbit/s or more).')}
   else{$info.Add('Connected at 5 Gbit/s. That is fine for most drives.')}
  }else{$info.Add('The USB link speed could not be read.')}
 }elseif($BusType){$checked=$true;$info.Add("Connected directly ($BusType), not through USB.")}
 $crc=$null;foreach($a in @(Get-Field $Smart 'ata_smart_attributes','table')){if($a -and [int]$a.id -eq 199){$crc=[long](Get-Field $a 'raw','value')}}
 if($null -ne $crc){$checked=$true;if($crc -gt 0){$warn.Add("The drive counted $crc damaged transfers over its life. They usually come from a cable or port, not the drive; if this number grows, change the cable.")}else{$info.Add('Damaged transfers counted by the drive: none.')}}
 if($Counters){
  $failed=[long]$Counters.ReadErrorsUncorrected+[long]$Counters.WriteErrorsUncorrected
  if($failed -gt 0){$warn.Add("Windows counted $failed reads or writes that failed on this drive.")}
  elseif($null -ne $Counters.ReadErrorsTotal){$checked=$true;$info.Add('Failed reads and writes counted by Windows: none.')}
 }
 $status=if($warn.Count){'Warning'}elseif($checked){'OK'}else{'Unavailable'}
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
 $overall=Get-WorstStatus @($groups.Values.Status)
 # Unchecked: the parts with no verdict. Summary: the one line for the overview, which must not read
 # "no problems" as if the whole drive had been checked when a part could not be.
 $plain=@{Health='the drive''s own health report';Surface='reading the disk';Connection='the connection';FileSystem='the file system'}
 $unchecked=@($groups.Keys|Where-Object {$groups[$_].Status -in 'Unavailable','NotRun'}|ForEach-Object {$plain[$_]})
 $summary=switch($overall){'Problem'{'problem found'}'Warning'{'worth a look'}'OK'{if($unchecked.Count){'no problems in what could be checked; not checked: '+($unchecked -join ', ')}else{'no problems'}}default{'not checked yet'}}
 [pscustomobject]@{Groups=$groups;Overall=$overall;Unchecked=$unchecked;Summary=$summary;When=if($Report){$Report.Finished}else{$null}}
}

# --- The full scan: its saved position, stopping, and the reader ----------------------------------
# These read or move files (and the reader reads a disk), unlike the rules above. They live here so
# that they are tested without a drive; Invoke-DriveCheck.ps1 only puts them together.

function New-DriveScanState([string]$Identity,[long]$Size,$Previous=$null) {
 # Previous: what the last scan of this drive found (Read-DriveScanState), kept until this one finishes.
 [pscustomobject]@{Identity=$Identity;Size=$Size;NextOffset=[long]0;Complete=$false;Started=(Get-Date).ToString('o');Finished=$null;Seconds=0.0;BadCount=0;VerySlowCount=0;SlowCount=0;RecoveredCount=0;Bad=@();Slow=@();Recovered=@();Previous=$Previous}
}
function Read-DriveScanState([string]$Path,[string]$Identity) {
 # Reads surface.json before a scan starts or continues. State: the unfinished scan of this very
 # drive, to continue; $null starts a new one. Previous: the findings of this drive's finished scan,
 # for the new record, so that starting again does not erase known bad areas. SetAside: where a file
 # that cannot be read was moved. It is never deleted, and never stops the scan from starting.
 $r=[pscustomobject]@{State=$null;Previous=$null;SetAside=$null}
 if(-not (Test-Path -LiteralPath $Path)){return $r}
 $old=$null;try{$old=Get-Content -LiteralPath $Path -Raw|ConvertFrom-Json}catch{}
 $ok=(Test-DriveScanRecord $old) -and (Get-Field $old 'Identity') -is [string]
 if($ok){try{$ok=[double]$old.Size -ge 0 -and [double]$old.NextOffset -ge 0 -and [double]$old.NextOffset -le [double]$old.Size}catch{$ok=$false}}
 if(-not $ok){
  $aside=Join-Path (Split-Path -Parent $Path) ('surface.damaged-'+(Get-Date -Format 'yyyyMMdd-HHmmss')+'.json')
  for($i=2;Test-Path -LiteralPath $aside;$i++){$aside=Join-Path (Split-Path -Parent $Path) ('surface.damaged-'+(Get-Date -Format 'yyyyMMdd-HHmmss')+"-$i.json")}
  Move-Item -LiteralPath $Path -Destination $aside
  $r.SetAside=$aside;return $r
 }
 if($old.Identity -ne $Identity){return $r}
 if($old.Complete){
  $r.Previous=[pscustomobject]@{Size=$old.Size;NextOffset=$old.NextOffset;Complete=$true;Finished=Get-Field $old 'Finished';BadCount=[long](Get-Field $old 'BadCount');VerySlowCount=[long](Get-Field $old 'VerySlowCount');SlowCount=[long](Get-Field $old 'SlowCount');RecoveredCount=[long](Get-Field $old 'RecoveredCount');Bad=@(@(Get-Field $old 'Bad')|Where-Object {$_}|Select-Object -First 200)}
  return $r
 }
 # An unfinished scan saved by an older version lacks the newer fields.
 $new=New-DriveScanState $Identity ([long]$old.Size)
 foreach($p in $new.PSObject.Properties){if(-not $old.PSObject.Properties[$p.Name]){$old|Add-Member -NotePropertyName $p.Name -NotePropertyValue $p.Value}}
 $r.State=$old;$r
}
function Test-DriveStopRequest([string]$Path,[datetime]$Since) {
 # Since: when Windows started the check's process. A stop.request left by an earlier run is older
 # and does not count; one made while this check was still starting does.
 try{(Test-Path -LiteralPath $Path) -and (Get-Item -LiteralPath $Path).LastWriteTime -ge $Since}catch{$false}
}

$script:ScannerSource=@'
using System; using System.Collections.Generic; using System.ComponentModel; using System.Diagnostics; using System.Globalization; using System.IO; using System.Runtime.InteropServices; using System.Text; using Microsoft.Win32.SafeHandles;
public static class BackupDriveScanner {
 [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern SafeFileHandle CreateFile(string n,uint a,uint s,IntPtr sa,uint d,uint f,IntPtr t);
 [DllImport("kernel32.dll",SetLastError=true)] static extern bool ReadFile(SafeFileHandle h,IntPtr b,uint n,out uint done,IntPtr o);
 [DllImport("kernel32.dll",SetLastError=true)] static extern bool SetFilePointerEx(SafeFileHandle h,long d,out long np,uint m);
 [DllImport("kernel32.dll",SetLastError=true)] static extern IntPtr VirtualAlloc(IntPtr a,UIntPtr n,uint t,uint p);
 [DllImport("kernel32.dll")] static extern bool VirtualFree(IntPtr a,UIntPtr n,uint t);
 [DllImport("kernel32.dll")] static extern uint SetThreadExecutionState(uint flags);
 // These mean the drive is gone (unplugged, asleep, box reset), not that an area is bad.
 static readonly int[] Gone={2,3,6,21,55,433,1167};
 // For tests only: the error one read (position, length) should end with instead of being read; 0 reads it.
 public static Func<long,int,int> Fault;
 static string N(double v){return v.ToString("0.###",CultureInfo.InvariantCulture);}
 public static void KeepAwake(bool on){SetThreadExecutionState(on?0x80000001u:0x80000000u);}
 static int ReadAt(SafeFileHandle h,IntPtr buf,long pos,int n){
  if(Fault!=null){int f=Fault(pos,n);if(f!=0)return f;}
  long np;if(!SetFilePointerEx(h,pos,out np,0))return Marshal.GetLastWin32Error();
  uint got;if(!ReadFile(h,buf,(uint)n,out got,IntPtr.Zero))return Marshal.GetLastWin32Error();
  return got==(uint)n?0:38;
 }
 // A stop.request written since the check's process started (stopSince, local ticks).
 static bool StopAsked(string file,long since){
  try{return !string.IsNullOrEmpty(file)&&File.Exists(file)&&File.GetLastWriteTime(file).Ticks>=since;}catch(Exception){return false;}
 }
 // Reads [start, start+length) of a physical disk without the Windows cache, 4 MiB at a time.
 // A chunk that fails is read again in 64 KiB pieces so the report names the damaged place; one
 // whose pieces then all read is counted as Recovered (the drive needed a second try).
 // VerySlow: a chunk over verySlowMs (the drive retried hard). Slow: over 10x the median and 250 ms.
 // A stop request is looked for before every chunk and every piece, so a stretch on a failing drive,
 // where one read can take many seconds, does not have to finish first. Bytes then ends at the last
 // whole chunk, and nothing of the chunk that was cut short is counted.
 public static string Read(string device,long start,long length,int sector,double verySlowMs,string stopFile,long stopSince){
  const int chunk=4*1024*1024;int piece=Math.Max(sector,64*1024);
  IntPtr buf=VirtualAlloc(IntPtr.Zero,(UIntPtr)chunk,0x3000,4);if(buf==IntPtr.Zero)throw new Win32Exception();
  var times=new List<double>();var where=new List<long>();var bad=new StringBuilder();var again=new StringBuilder();int badCount=0,againCount=0;long done=0;bool stopped=false;var total=Stopwatch.StartNew();
  try{
   using(var h=CreateFile(device,0x80000000,3,IntPtr.Zero,3,0x20000000,IntPtr.Zero)){
    if(h.IsInvalid)throw new Win32Exception(Marshal.GetLastWin32Error());
    long end=start+length;
    for(long pos=start;pos<end;pos+=chunk){
     if(StopAsked(stopFile,stopSince)){stopped=true;break;}
     int n=(int)Math.Min(chunk,end-pos);var w=Stopwatch.StartNew();int err=ReadAt(h,buf,pos,n);double ms=w.Elapsed.TotalMilliseconds;
     if(err==0){times.Add(ms);where.Add(pos);}
     else{
      if(Array.IndexOf(Gone,err)>=0)throw new Win32Exception(err,"The drive stopped answering ("+err+"). Check that it is still connected.");
      var found=new List<string>();
      for(long p=pos;p<pos+n;p+=piece){
       if(StopAsked(stopFile,stopSince)){stopped=true;break;}
       int m=(int)Math.Min(piece,pos+n-p);int e=ReadAt(h,buf,p,m);if(e==0)continue;
       if(Array.IndexOf(Gone,e)>=0)throw new Win32Exception(e,"The drive stopped answering ("+e+"). Check that it is still connected.");
       found.Add("{\"Offset\":"+p+",\"Length\":"+m+",\"Code\":"+e+"}");
      }
      if(stopped)break;
      if(found.Count==0){if(againCount<200){if(again.Length>0)again.Append(',');again.Append("{\"Offset\":"+pos+",\"Code\":"+err+"}");}againCount++;}
      foreach(string f in found){if(badCount<200){if(bad.Length>0)bad.Append(',');bad.Append(f);}badCount++;}
     }
     done+=n;
    }
   }
  }finally{VirtualFree(buf,UIntPtr.Zero,0x8000);}
  double[] sorted=times.ToArray();Array.Sort(sorted);double median=sorted.Length>0?sorted[sorted.Length/2]:0;double max=sorted.Length>0?sorted[sorted.Length-1]:0;
  var slow=new StringBuilder();int slowCount=0,verySlow=0;double slowMs=Math.Max(250,10*median);
  for(int i=0;i<times.Count;i++){
   bool very=times[i]>=verySlowMs;if(very)verySlow++;
   if(very||times[i]>=slowMs){if(slowCount<200){if(slow.Length>0)slow.Append(',');slow.Append("{\"Offset\":"+where[i]+",\"Ms\":"+N(times[i])+"}");}slowCount++;}
  }
  return "{\"Bytes\":"+done+",\"Stopped\":"+(stopped?"true":"false")+",\"Seconds\":"+N(total.Elapsed.TotalSeconds)+",\"MedianMs\":"+N(median)+",\"MaxMs\":"+N(max)+",\"BadCount\":"+badCount+",\"Bad\":["+bad+"],\"RecoveredCount\":"+againCount+",\"Recovered\":["+again+"],\"SlowCount\":"+slowCount+",\"VerySlowCount\":"+verySlow+",\"Slow\":["+slow+"]}";
 }
}
'@
function Add-DriveScannerType{if(-not ('BackupDriveScanner' -as [type])){Add-Type -TypeDefinition $script:ScannerSource}}

function Open-DriveCheckSmartTool([string]$Path,[string]$ToolHash=(Get-DriveCheckSmartToolHash),[string]$DatabaseHash=(Get-DriveCheckDatabaseHash)) {
 # smartctl runs as administrator, so whichever copy is asked for, the bundled one or another path,
 # must be the official 7.5 build. Hold: the file kept open (others may only read it) for as long as
 # the check runs, so the file that was checked is the file that runs. Problem: why it will not run.
 # (-ToolHash and -DatabaseHash are for the tests, which have no real smartctl.)
 $no={param($why)[pscustomobject]@{Problem=$why;Hold=$null;DatabaseHold=$null}}
 if(-not (Test-Path -LiteralPath $Path -PathType Leaf)){return & $no 'The health tool is not installed. Use "Install health tool" on this page, then check again.'}
 $hold=[IO.File]::Open($Path,'Open','Read','Read')
 $official=try{(Get-FileHash -InputStream $hold -Algorithm SHA256).Hash -eq $ToolHash}catch{$false}
 if(-not $official){
  $hold.Dispose()
  return & $no 'The health tool is not the official smartctl 7.5, so it was not run. Use "Install health tool" on this page again, then check again.'
 }
 # What lies beside it is loaded by it, as administrator too. A library there would be loaded in
 # place of Windows' own, and the official installation puts none there, so any is refused. The
 # drive database (drivedb.h) is read at every start: it must be the installer's, and is held open
 # the same way. Without that file smartctl uses the database built into it.
 $folder=[IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Path))
 $libraries=@(Get-ChildItem -LiteralPath $folder -Filter '*.dll' -File -Force -ErrorAction SilentlyContinue)
 if($libraries.Count){$hold.Dispose();return & $no ("The health tool was not run, because its folder holds a file that does not belong to it: $(@($libraries|ForEach-Object Name) -join ', '). Remove it, or use `"Install health tool`" on this page again.")}
 $dbHold=$null;$db=Join-Path $folder 'drivedb.h'
 if(Test-Path -LiteralPath $db -PathType Leaf){
  # A database that cannot be opened or read is as unknown as a changed one; nothing stays held open.
  $same=try{$dbHold=[IO.File]::Open($db,'Open','Read','Read');(Get-FileHash -InputStream $dbHold -Algorithm SHA256).Hash -eq $DatabaseHash}catch{$false}
  if(-not $same){
   if($dbHold){$dbHold.Dispose()};$hold.Dispose()
   return & $no 'The health tool was not run, because the drive database beside it (drivedb.h) could not be read or is not the one from the official 7.5 installer. Use "Install health tool" on this page again, then check again.'
  }
 }
 [pscustomobject]@{Problem='';Hold=$hold;DatabaseHold=$dbHold}
}

# --- Running as administrator -----------------------------------------------------------------
# The check runs as administrator. Whoever can change a file it runs or loads, put a file next to
# smartctl.exe, or rename a folder above them could make it run anything as administrator.

# SHA-256 of bin\smartctl.exe (64-bit) inside the official smartmontools 7.5 installer, whose own
# hash Install-DriveTools.ps1 checks before it runs it.
function Get-DriveCheckSmartToolHash {'B5DB94E5082C042BE44994B7A4FA8F7B5C8E713B2AB1C9A560D8F7A7995EA27D'}
# SHA-256 of bin\drivedb.h as the same installer puts it beside smartctl.exe. A database updated
# later (update-smart-drivedb) no longer matches, and the health report then asks for a reinstall.
function Get-DriveCheckDatabaseHash {'DD39C6A520D38895DA61923FE26FE7C9C5EB3F42325F2E4477A06ED7A61966D0'}

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

Export-ModuleMember -Function Get-Field,New-DriveGroup,Get-WorstStatus,Test-DriveSmartAnswer,Get-DriveSelfTest,Get-DriveHealthFindings,Get-DriveSurfaceFindings,Get-DriveConnectionKey,Get-DriveEventFindings,Get-DriveConnectionFindings,Get-DriveFileSystemFindings,Merge-DriveEvents,Get-DriveCheckView,Format-DriveOffset,Format-DriveAge,Test-DriveSmartFlagOnly,Test-DriveScanRecord,New-DriveScanState,Read-DriveScanState,Test-DriveStopRequest,Add-DriveScannerType,Open-DriveCheckSmartTool,Get-DriveCheckSmartToolHash,Get-DriveCheckDatabaseHash,Get-DriveCheckPathRisks,Read-DriveCheckPathAccess
