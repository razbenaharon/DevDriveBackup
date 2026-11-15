#Requires -Version 7.2
# Rules of the versioned engine that need no repository, no restic and no second drive: partial versions,
# the clean-up of old versions on a shared repository, deleting many versions at once, restore warnings,
# a pending password change after the drive letter changed, the wording of a locked repository, and which
# repository locks may be removed without asking (only one left by a run on this computer that has ended).
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'Backup.Status.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Backup.History.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Backup.Security.psm1') -Force
function Assert($ok,[string]$message){if(-not $ok){throw "FAIL $message"};Write-Output "PASS $message"}
function Assert-Throws([scriptblock]$Block,[string]$Like,[string]$message){
 try{& $Block;throw "FAIL $message (no error)"}catch{if($_.Exception.Message -like 'FAIL*'){throw};if($_.Exception.Message -notlike $Like){throw "FAIL $message (got: $($_.Exception.Message))"}}
 Write-Output "PASS $message"
}
function Id([int]$n){('{0:x4}' -f $n)*16}
function Snap([int]$n,[string]$time,[string]$computer='pc',[string[]]$tags=@('devdrive')){[pscustomobject]@{id=(Id $n);time=$time;hostname=$computer;paths=@('E:\');tags=$tags}}
# A version for the clean-up rule: complete unless -Partial; -Foreign is another program's version (no tag).
function Ver([int]$n,[string]$time,[switch]$Partial,[switch]$Foreign,[string]$Computer='pc',[string[]]$Paths=@('E:\')){
 $v=[pscustomobject]@{id=(Id $n);time=$time;hostname=$Computer;paths=$Paths}
 if(-not $Foreign){$v|Add-Member -NotePropertyName tags -NotePropertyValue @($(if($Partial){'devdrive-partial'}else{'devdrive'}))}
 $v
}
function Ids([int[]]$n){@($n|ForEach-Object {Id $_})}
function Same($a,$b){(@($a|Sort-Object) -join ',') -ceq (@($b|Sort-Object) -join ',')}
# The rule reads months on this computer's clock; the tests fix the clock (UTC unless said otherwise) so
# that they give the same answer on every computer.
function Plan($versions,[int]$last,[int]$months,[int]$new,[string]$computer='pc',[TimeZoneInfo]$zone=[TimeZoneInfo]::Utc){@(Get-VersionRetentionPlan $versions $last $months $computer (Id $new) $zone)}
function Kept($plan){@($plan|Where-Object {$_.Keep}|ForEach-Object {$_.Id})}
function Gone($plan){@($plan|Where-Object {-not $_.Keep}|ForEach-Object {$_.Id})}
function Why($plan,[int]$n){@(@($plan|Where-Object {$_.Id -ceq (Id $n)})[0].Reasons)}
function Decision([int]$n,[bool]$keep){[pscustomobject]@{Id=(Id $n);Keep=$keep}}

# --- Partial versions (a backup that could not read every file) ----------------------------------
$complete=Snap 1 '2026-06-29T10:00:00Z';$partial=Snap 2 '2026-06-29T18:00:00Z' 'pc' @('devdrive-partial');$older=Snap 3 '2026-06-28T10:00:00Z'
Assert ((Test-PartialSnapshot $partial) -and -not (Test-PartialSnapshot $complete) -and -not (Test-PartialSnapshot ([pscustomobject]@{id=(Id 9);time='2026-01-01T00:00:00Z';hostname='pc';paths=@('E:\')}))) 'a partial version is recognised by its mark; unmarked and untagged versions are not partial'
$mark=Get-PartialMarkArguments (Id 2)
Assert ($mark[0] -eq 'tag' -and ($mark -join ' ') -like '*--remove devdrive*' -and ($mark -join ' ') -like '*--add devdrive-partial*' -and $mark[-1] -eq (Id 2)) 'marking a version partial replaces its tag, so it never passes for a complete version'
Assert-Throws {Get-PartialMarkArguments 'latest'} '*exact snapshot ID*' 'only an exact version can be marked partial'
Assert (((Get-PartialTags @('devdrive','mine')) -join ',') -ceq 'mine,devdrive-partial' -and ((Get-PartialTags @('devdrive')) -join ',') -ceq 'devdrive-partial' -and (Test-PartialSnapshot ([pscustomobject]@{tags=@(Get-PartialTags $complete.tags)}))) 'the tags of a version once it is marked: the same change the mark makes, for a preview that plans a version still waiting for its mark'
$set=@($complete,$partial,$older)
Assert-Throws {Get-HistoryDeletionPlan $set @($complete.id)} '*protected*' 'the newest complete version is protected even when a newer partial version exists'
Assert-Throws {Get-HistoryDeletionPlan $set @($partial.id)} '*protected*' 'the newest version stays protected as before, also when it is partial'
Assert (@(Get-HistoryDeletionPlan $set @($older.id)).Count -eq 1) 'an older version can still be deleted'
$onlyPartial=@((Snap 4 '2026-06-29T18:00:00Z' 'pc' @('devdrive-partial')),(Snap 5 '2026-06-28T18:00:00Z' 'pc' @('devdrive-partial')))
Assert (@(Get-HistoryDeletionPlan $onlyPartial @((Id 5))).Count -eq 1) 'a set with only partial versions still lets an older one go'

# === Keep versions: the last N complete versions and the newest complete version of each month ========
# (Get-VersionRetentionPlan works the plan out from the list of versions; restic only lists and deletes.)

# --- Irregular backups: gaps of 17, 2 and 3 days, then three a day, then a pause of four months -------
$stamps=@('2026-01-05T12:00:00Z','2026-01-22T12:00:00Z','2026-01-24T12:00:00Z','2026-01-27T12:00:00Z')
foreach($day in '2026-01-28','2026-01-29','2026-01-30','2026-02-02'){foreach($hour in '08','12','18'){$stamps+="$($day)T$($hour):00:00Z"}}
$stamps+='2026-06-10T12:00:00Z'
$irregular=@(for($i=0;$i -lt $stamps.Count;$i++){Ver ($i+1) $stamps[$i]})   # 1..17, oldest first; 13 = 30 January 18:00, 16 = 2 February 18:00
$p=Plan $irregular 10 6 17
Assert ($p.Count -eq 17 -and (Same (Kept $p) (Ids @(8..17))) -and (Same (Gone $p) (Ids @(1..7)))) 'irregular backups, last 10 and 6 months: the 10 newest stay whatever their dates, the 7 older ones go'
Assert ((Same (Why $p 17) @('JustMade','NewestComplete','LastN','Monthly')) -and (Same (Why $p 16) @('LastN','Monthly')) -and (Same (Why $p 9) @('LastN')) -and (Same (Why $p 7) @('OutsideRules'))) 'every version carries the reasons it is kept, or that no rule keeps it'
$p=Plan $irregular 3 6 17
Assert (Same (Kept $p) (Ids 17,16,15,13)) 'last 3 and 6 months: the 3 newest, and the newest version of January (30 January 18:00) as that month''s version'
Assert ((Same (Why $p 13) @('Monthly')) -and (Same (Why $p 12) @('OutsideRules')) -and (Same (Why $p 4) @('OutsideRules'))) 'earlier versions of the same day and month go'
Assert (Same (Kept (Plan $irregular 0 6 17)) (Ids 17,16,13)) 'months only: one version for each of June, February and January'
Assert (Same (Kept (Plan $irregular 10 0 17)) (Ids @(8..17))) 'last 10 only: the 10 newest'
Assert (Same (Kept (Plan $irregular 0 2 17)) (Ids 17)) 'after a pause longer than the months kept, the newest version is still there: months count back from it, not from today'
# The months count back from the newest complete version: before the pause ended, January was inside 2 months.
Assert (Same (Kept (Plan @($irregular[0..15]) 0 2 16)) (Ids 16,13)) 'before the pause the same rule kept February and January'

# --- The two rules together ---------------------------------------------------------------------------
$newest=[DateTimeOffset]::Parse('2026-11-14T12:00:00Z',[Globalization.CultureInfo]::InvariantCulture)
$daily=@(1..300|ForEach-Object {Ver $_ $newest.AddDays($_-300).UtcDateTime.ToString('o')})   # one a day, 300 = 14 November
$p=Plan $daily 10 6 300
$stay=@(Kept $p)
Assert ($p.Count -eq 300 -and @($p|ForEach-Object {$_.Id}|Sort-Object -Unique).Count -eq 300) 'every version is in the plan exactly once'
Assert ((Same (Why $p 300) @('JustMade','NewestComplete','LastN','Monthly')) -and @($stay|Where-Object {$_ -ceq (Id 300)}).Count -eq 1) 'a version that is among the last 10 and also its month''s newest is kept once'
# 14 Nov is both; the months before it end on 31 Oct (286), 30 Sep (255), 31 Aug (225), 31 Jul (194), 30 Jun (163).
Assert (Same $stay (Ids (@(291..300)+@(286,255,225,194,163)))) 'a year of daily backups, last 10 and 6 months: the last 10 days and the last day of each of the 5 months before'
Assert ($stay.Count -eq 15) 'with 10 and 6 a group keeps at most 15 complete versions while the clock is right: the newest one is always both among the last 10 and its month''s version'
# The 16th: only when versions dated later than the one just made exist (a clock that was wrong). The
# version just made (1 November, 06:00) is then neither among the last 10 nor its month's newest, and stays anyway.
$late=$daily+@(Ver 301 '2026-11-01T06:00:00Z')
$p=Plan $late 10 6 301
Assert (@(Kept $p).Count -eq 16 -and (Same (Why $p 301) @('JustMade')) -and (Same (Kept $p) (@($stay)+(Id 301)))) 'with 10 and 6 a group never keeps more than 16 complete versions: 15 by the two rules and the version just made'
$random=[Random]::new(20261114);$most=0
foreach($round in 1..25){
 $at=$newest;$history=@(1..80|ForEach-Object {$v=Ver $_ $at.UtcDateTime.ToString('o');$at=$at.AddHours(-$random.Next(1,24*45));$v})   # 1 is the newest
 $last=$random.Next(0,13);$months=$random.Next(0,9);if($last+$months -eq 0){$last=1}
 $p=Plan $history $last $months 1;$stay=@(Kept $p)
 # The newest version is always both among the last N and its month's version, so the two rules overlap by at least one.
 $limit=$last+$months-$(if($last -and $months){1}else{0})
 if($stay.Count -gt $limit -or (Id 1) -cnotin $stay -or @(1..80|Where-Object {$_ -le $last -and (Id $_) -cnotin $stay}).Count){throw "FAIL random history $round (last $last, months $months) kept $($stay.Count)"}
 $most=[math]::Max($most,$stay.Count)
}
Assert ($most -gt 10) '25 random histories: never more than last + months complete versions, always the newest and the last N'
$few=@(Ver 1 '2024-12-03T12:00:00Z'),(Ver 2 '2025-03-09T12:00:00Z'),(Ver 3 '2025-03-10T12:00:00Z'),(Ver 4 '2025-08-20T12:00:00Z'),(Ver 5 '2026-01-15T12:00:00Z'),(Ver 6 '2026-01-16T12:00:00Z'),(Ver 7 '2026-11-14T12:00:00Z')
Assert (@(Gone (Plan $few 10 6 7)).Count -eq 0) 'with fewer than 10 versions nothing complete is deleted, however old'

# --- One version a month ------------------------------------------------------------------------------
$monthly=@(
 (Ver 1 '2026-02-14T12:00:00Z'),
 (Ver 2 '2026-03-10T12:00:00Z'),(Ver 3 '2026-03-20T12:00:00Z'),(Ver 4 '2026-03-25T12:00:00Z' -Partial),
 (Ver 5 '2026-04-05T12:00:00Z'),(Ver 6 '2026-04-28T12:00:00Z'),
 (Ver 7 '2026-08-03T12:00:00Z'),(Ver 8 '2026-08-12T12:00:00Z'))
$p=Plan $monthly 2 6 8
Assert (Same (Kept $p) (Ids 3,6,7,8)) 'months: the newest complete version of March and of April stays beside the last 2'
Assert ((Same (Why $p 3) @('Monthly')) -and (Same (Why $p 2) @('OutsideRules')) -and -not @($p|Where-Object {$_.Id -ceq (Id 4)})[0].Keep) 'a partial version that is the newest of its month is not the month''s version: the newest complete one is'
Assert ((Same (Why $p 1) @('OutsideRules'))) 'a month older than 6 months back from the newest complete version (August: March to August) is dropped'
Assert (Same (Kept (Plan $monthly 2 5 8)) (Ids 6,7,8)) 'with 5 months, March is dropped too'
$p=Plan $monthly 6 1 8
Assert ((Same (Gone $p) (Ids 1,4)) -and (Same (Why $p 2) @('LastN'))) 'a version of an older month stays when it is among the last N'

# --- Midnight at a month''s end: months are read on this computer''s clock, as the history shows them ---
$plus2=[TimeZoneInfo]::CreateCustomTimeZone('test +2',[TimeSpan]::FromHours(2),'test +2','test +2')
$plus3=[TimeZoneInfo]::CreateCustomTimeZone('test +3',[TimeSpan]::FromHours(3),'test +3','test +3')
# 2 was made at 21:30 UTC on 30 June: 23:30 on 30 June where the clock is 2 hours ahead, 00:30 on 1 July where it is 3.
$edge=@((Ver 1 '2026-06-30T12:00:00Z'),(Ver 2 '2026-06-30T21:30:00Z'),(Ver 3 '2026-07-20T12:00:00Z'),(Ver 4 '2026-08-10T12:00:00Z'))
Assert (Same (Kept (Plan $edge 1 3 4 'pc' $plus2)) (Ids 2,3,4)) 'a version made at 23:30 on 30 June belongs to June and is June''s version'
Assert (Same (Kept (Plan $edge 1 3 4 'pc' $plus3)) (Ids 1,3,4)) 'the same moment read as 00:30 on 1 July belongs to July, where a newer version exists'
$recorded=@($edge[0],(Ver 2 '2026-07-01T00:30:00+03:00'),$edge[2],$edge[3])
Assert (Same (Kept (Plan $recorded 1 3 4 'pc' $plus2)) (Ids 2,3,4)) 'the clock of the computer that reads the history decides, not the offset written in the version'
$typed=@($recorded|ConvertTo-Json -Depth 5|ConvertFrom-Json)
Assert (Same (Kept (Plan $typed 1 3 4 'pc' $plus2)) (Ids 2,3,4)) 'the same after the dates went through JSON'
Assert (Same (Kept @(Get-VersionRetentionPlan $edge 1 3 'pc' (Id 4))) (Kept (Plan $edge 1 3 4 'pc' ([TimeZoneInfo]::Local)))) 'without a clock given, this computer''s own time zone is used'

# --- Partial versions -----------------------------------------------------------------------------------
$mixed=@((Ver 1 '2026-06-01T12:00:00Z'),(Ver 2 '2026-06-02T12:00:00Z'),(Ver 3 '2026-06-03T12:00:00Z'),(Ver 5 '2026-06-03T18:00:00Z' -Partial),(Ver 4 '2026-06-04T12:00:00Z'))
$p=Plan $mixed 2 0 4
Assert ((Same (Kept $p) (Ids 3,4,5)) -and (Same (Why $p 5) @('PartialKept')) -and (Same (Why $p 3) @('LastN'))) 'a partial version does not count among the last N: the 2 newest complete versions stay'
foreach($newer in 0..4){
 $set=@((Ver 1 '2026-06-01T12:00:00Z'),(Ver 50 '2026-06-05T12:00:00Z' -Partial))+@(1..4|Where-Object {$_ -le $newer}|ForEach-Object {Ver (1+$_) "2026-06-1$($_)T12:00:00Z"})
 $p=Plan $set 10 6 (1+$newer)
 $stays=@($p|Where-Object {$_.Id -ceq (Id 50)})[0].Keep
 if($stays -ne ($newer -lt 3)){throw "FAIL a partial version with $newer newer complete versions: kept=$stays"}
 if($newer -ge 3 -and -not (Same (Why $p 50) @('PartialAfter3Complete'))){throw 'FAIL the reason for deleting a partial version'}
}
Assert $true 'a partial version stays with 0, 1 or 2 newer complete versions and goes with 3 or more'
$sameTime=@((Ver 1 '2026-06-05T12:00:00Z'),(Ver 50 '2026-06-05T12:00:00Z' -Partial),(Ver 2 '2026-06-06T12:00:00Z'),(Ver 3 '2026-06-07T12:00:00Z'))
Assert ((Kept (Plan $sameTime 10 0 3)) -ccontains (Id 50)) 'a complete version made at the same moment is not newer'
$old=@((Ver 50 '2020-01-01T12:00:00Z' -Partial),(Ver 1 '2026-06-01T12:00:00Z'),(Ver 2 '2026-06-02T12:00:00Z'))
Assert ((Kept (Plan $old 1 1 2)) -ccontains (Id 50)) 'age alone never deletes a partial version: six years old with 2 newer complete versions, it stays'
$off=@((Ver 50 '2026-01-01T12:00:00Z' -Partial))+@(1..12|ForEach-Object {Ver $_ ('2026-{0:d2}-10T12:00:00Z' -f $_)})
$p=Plan $off 0 0 12
Assert (@(Gone $p).Count -eq 0 -and $p.Count -eq 13 -and @($p|Where-Object {-not (Same $_.Reasons @('CleanUpOff'))}).Count -eq 0) 'with last 0 and months 0 nothing is planned: every version stays, a partial one with 12 newer complete versions too'
Assert (@(Get-RetentionRemovals $p (Id 12) $off 'pc').Count -eq 0) 'and nothing is handed over for deletion'
Assert ((Gone (Plan $off 1 0 12)) -ccontains (Id 50)) 'the same partial version goes as soon as the clean-up is on'

# --- Each computer and set of folders on its own ------------------------------------------------------
$both=@('E:\','D:\data');$swapped=@('D:\data','E:\')
$shared=@(
 (Ver 1 '2026-06-01T12:00:00Z'),(Ver 2 '2026-06-02T12:00:00Z'),(Ver 3 '2026-06-03T12:00:00Z'),(Ver 4 '2026-06-04T12:00:00Z'),(Ver 5 '2026-06-05T12:00:00Z'),
 (Ver 11 '2026-05-01T12:00:00Z' -Paths $both),(Ver 12 '2026-05-02T12:00:00Z' -Paths $swapped),(Ver 13 '2026-05-03T12:00:00Z' -Paths $both),
 (Ver 14 '2026-05-02T18:00:00Z' -Partial -Paths $both),
 (Ver 21 '2025-01-01T12:00:00Z' -Computer 'laptop'),(Ver 22 '2025-01-02T12:00:00Z' -Computer 'laptop'),(Ver 23 '2025-01-03T12:00:00Z' -Computer 'laptop'),(Ver 24 '2025-01-04T12:00:00Z' -Computer 'laptop'),(Ver 25 '2025-01-05T12:00:00Z' -Computer 'laptop'),
 (Ver 26 '2024-12-31T12:00:00Z' -Partial -Computer 'laptop'),
 (Ver 31 '2020-01-01T12:00:00Z' -Foreign),
 (Ver 41 '2026-06-01T12:00:00Z' -Computer 'PC'))
$p=Plan $shared 2 0 5
Assert (Same (Gone $p) (Ids 1,2,3,11)) 'two sets of folders on one computer: each keeps its own last 2 (the order of the folders does not matter)'
Assert ((Same (Why $p 14) @('PartialKept'))) 'a partial version is judged by its own set of folders: one newer complete version there, however many the other set has'
Assert (@($p|Where-Object {$_.Host -cne 'pc'}).Count -eq 0 -and $p.Count -eq 9) 'another computer''s versions (also one whose name differs only in capitals) and another program''s are not in the plan at all'
$r=@(Get-RetentionRemovals $p (Id 5) $shared 'pc')
Assert ((Same @($r|ForEach-Object {$_.id}) (Ids 1,2,3,11)) -and @($r|Where-Object {$_.hostname -cne 'pc'}).Count -eq 0) 'what is handed over for deletion is this computer''s only'
$capitals=@((Ver 1 '2026-06-01T12:00:00Z' -Paths 'E:\a','e:\A'),(Ver 2 '2026-06-02T12:00:00Z' -Paths 'e:\A','E:\a'),(Ver 3 '2026-06-03T12:00:00Z' -Paths 'E:\a','e:\A'),(Ver 4 '2026-06-04T12:00:00Z' -Paths 'e:\A','E:\a'))
$q=Plan $capitals 1 0 4
Assert ((Same (Gone $q) (Ids 1,2,3)) -and @(Get-RetentionRemovals $q (Id 4) $capitals 'pc').Count -eq 3) 'two folders that differ only in capitals, listed in either order, are one set, and the last check agrees'
$joined=@((Ver 1 '2026-06-01T12:00:00Z' -Paths "E:\a`nE:\b"),(Ver 2 '2026-06-02T12:00:00Z' -Paths 'E:\a','E:\b'),(Ver 3 '2026-06-03T12:00:00Z' -Paths 'E:\a','E:\b'))
Assert (@(Gone (Plan $joined 1 0 3)).Count -eq 1) 'one odd folder name is never taken for two folders: it stays a set of its own'
$p=Plan $shared 2 0 25 'laptop'
Assert ((Same (Gone $p) (Ids 21,22,23,26)) -and $p.Count -eq 6) 'the other computer cleans its own versions with its own rule, and only those'

# --- What always stays --------------------------------------------------------------------------------
$tail=@((Ver 1 '2026-06-01T12:00:00Z'),(Ver 2 '2026-06-02T12:00:00Z'),
 (Ver 11 '2026-03-01T12:00:00Z' -Paths $both),(Ver 12 '2026-03-02T12:00:00Z' -Paths $both),(Ver 13 '2026-03-03T12:00:00Z' -Partial -Paths $both),(Ver 14 '2026-03-04T12:00:00Z' -Partial -Paths $both),(Ver 15 '2026-06-03T12:00:00Z' -Partial -Paths $both))
$p=Plan $tail 1 0 2
Assert ((Same (Gone $p) (Ids 1,11)) -and (Same (Why $p 12) @('NewestComplete','LastN'))) 'last 1, months 0: a set of folders whose newest complete version is followed only by partial versions keeps it, and them'
foreach($rule in @(@(1,0),@(0,1),@(1,1),@(3,0),@(0,6),@(10,6))){
 $stay=@(Kept (Plan $tail $rule[0] $rule[1] 2))
 if((Id 2) -cnotin $stay -or (Id 12) -cnotin $stay){throw "FAIL the newest complete version was not kept with last $($rule[0]), months $($rule[1])"}
}
Assert $true 'the newest complete version of every set of folders survives every setting'
$wrongClock=@((Ver 1 '2027-01-01T12:00:00Z'),(Ver 2 '2027-01-02T12:00:00Z'),(Ver 3 '2026-11-12T10:00:00Z'))
$p=Plan $wrongClock 1 0 3
Assert ((Same (Gone $p) (Ids 1)) -and (Same (Why $p 3) @('JustMade')) -and (Same (Why $p 2) @('NewestComplete','LastN'))) 'the version just made stays even when versions dated later exist (a clock that was wrong)'
# One version saved while the clock was a year ahead must not move the months away from today's: the
# months before the version just made still keep their version. (Counting only from the newest version,
# the 6 months were Jun 2027 to Nov 2027, nothing real was in them, and every month's version went.)
$ahead=@(foreach($m in 3..10){foreach($day in 1,8,15,22){Ver ($m*100+$day) ('2026-{0:d2}-{1:d2}T10:00:00Z' -f $m,$day)}})+@((Ver 1 '2026-11-15T10:00:00Z'),(Ver 2 '2027-11-01T10:00:00Z'))
$p=Plan $ahead 10 6 1
Assert ((Same (Kept $p) (Ids (@(1,2,1022,1015,1008,1001,922,915,908,901,822)+@(722,622)))) -and (Same (Why $p 622) @('Monthly')) -and (Same (Why $p 2) @('NewestComplete','LastN','Monthly'))) 'a version dated a year ahead (a wrong clock) does not cost the months before the version just made their versions'
# A clock that was behind when the version was made: the months before the newest version still count,
# and the months between the two windows do not.
$behind=@(foreach($m in 3..10){Ver ($m*100) ('2026-{0:d2}-20T10:00:00Z' -f $m)})+@((Ver 1 '2025-01-15T10:00:00Z'),(Ver 3 '2025-06-15T10:00:00Z'),(Ver 4 '2024-12-15T10:00:00Z'))
$p=Plan $behind 1 6 1
Assert ((Same (Kept $p) (Ids @(1,4,1000,900,800,700,600,500))) -and (Same (Why $p 1) @('JustMade','Monthly')) -and (Same (Gone $p) (Ids @(3,300,400)))) 'a version just made with a clock that was behind keeps the months before the newest version and the months up to its own, and nothing between them'
Assert ((Same (Kept (Plan $ahead 10 0 1)) (Ids @(1,2,1022,1015,1008,1001,922,915,908,901)))) 'with 0 months no month keeps a version, also with a wrong clock'

# --- What the plan refuses ----------------------------------------------------------------------------
Assert-Throws {Get-VersionRetentionPlan $mixed 2 0 'pc' ''} '*not known*' 'without the ID of the version just made nothing is planned'
Assert-Throws {Get-VersionRetentionPlan $mixed 2 0 'pc' (Id 99)} '*not found*' 'a version just made that is not among the saved versions is refused'
Assert-Throws {Get-VersionRetentionPlan $shared 2 0 'pc' (Id 21)} '*not found*' 'so is one that belongs to another computer'
Assert-Throws {Get-VersionRetentionPlan $mixed 2 0 'pc' (Id 5)} '*partial*' 'the clean-up never runs on behalf of a partial version'
Assert-Throws {Get-VersionRetentionPlan $mixed 2 0 '' (Id 4)} '*computer*' 'without this computer''s name nothing is planned'
Assert-Throws {Get-VersionRetentionPlan $mixed -1 0 'pc' (Id 4)} '*out of range*' 'negative numbers are refused'

# --- The checks before anything is deleted (independent of how the plan was worked out) -----------------
$c=@((Ver 1 '2026-06-01T12:00:00Z'),(Ver 2 '2026-06-02T12:00:00Z'),(Ver 3 '2026-06-03T12:00:00Z'),(Ver 4 '2026-06-04T12:00:00Z'),(Ver 5 '2026-06-02T18:00:00Z' -Partial),
 (Ver 11 '2026-05-01T12:00:00Z' -Partial -Paths $both),(Ver 12 '2026-05-02T12:00:00Z' -Partial -Paths $both),
 (Ver 21 '2025-01-01T12:00:00Z' -Computer 'laptop'),(Ver 22 '2025-01-02T12:00:00Z' -Computer 'laptop'),(Ver 31 '2020-01-01T12:00:00Z' -Foreign))
$r=@(Get-RetentionRemovals @((Decision 1 $false),(Decision 2 $true),(Decision 3 $true),(Decision 4 $true),(Decision 5 $true)) (Id 4) $c 'pc')
Assert ($r.Count -eq 1 -and $r[0].id -ceq (Id 1) -and $r[0].hostname -eq 'pc') 'an old version in the plan is returned for deletion, as the saved version itself'
Assert (@(Get-RetentionRemovals @((Decision 1 $true),(Decision 4 $true)) (Id 4) $c 'pc').Count -eq 0) 'a plan that deletes nothing returns nothing'
Assert-Throws {Get-RetentionRemovals @((Decision 1 $false),(Decision 4 $true)) '' $c 'pc'} '*not known*' 'without the ID of the version just made nothing is deleted'
Assert-Throws {Get-RetentionRemovals @((Decision 1 $false),(Decision 4 $true)) $null $c 'pc'} '*not known*' 'a missing ID of the version just made is refused too'
Assert-Throws {Get-RetentionRemovals @((Decision 3 $false),(Decision 4 $true)) (Id 3) $c 'pc'} '*just made*' 'a plan that would delete the version just made is refused'
Assert-Throws {Get-RetentionRemovals @((Decision 1 $false),(Decision 5 $true)) (Id 5) $c 'pc'} '*partial*' 'a partial version just made is refused'
Assert-Throws {Get-RetentionRemovals @((Decision 4 $false),(Decision 3 $true)) (Id 3) $c 'pc'} '*newest complete*' 'a plan that would delete the newest complete version of a set of folders is refused'
Assert-Throws {Get-RetentionRemovals @((Decision 11 $false),(Decision 12 $false),(Decision 4 $true)) (Id 4) $c 'pc'} '*every version*' 'a plan that would empty a set of folders is refused'
Assert-Throws {Get-RetentionRemovals @((Decision 5 $false),(Decision 4 $true)) (Id 4) $c 'pc'} '*partial*fewer than three*' 'a plan that would delete a partial version with only 2 newer complete versions is refused'
Assert-Throws {Get-RetentionRemovals @((Decision 21 $false),(Decision 4 $true)) (Id 4) $c 'pc'} '*another computer*' 'a plan that would delete another computer''s version is refused'
Assert-Throws {Get-RetentionRemovals @((Decision 31 $false),(Decision 4 $true)) (Id 4) $c 'pc'} '*did not make*' 'a plan that would delete another program''s version is refused'
Assert-Throws {Get-RetentionRemovals @((Decision 99 $false),(Decision 4 $true)) (Id 4) $c 'pc'} '*not among*' 'a plan that names a version that is not saved is refused'
Assert-Throws {Get-RetentionRemovals @((Decision 1 $false),(Decision 1 $true),(Decision 4 $true)) (Id 4) $c 'pc'} '*both keeps and deletes*' 'a plan that keeps and deletes one version is refused'
Assert-Throws {Get-RetentionRemovals @((Decision 1 $false),(Decision 4 $true)) (Id 4) $c ''} '*computer*' 'without this computer''s name nothing is deleted'
$more=$c+@((Ver 6 '2026-06-05T12:00:00Z'))
$r=@(Get-RetentionRemovals @((Decision 5 $false),(Decision 6 $true)) (Id 6) $more 'pc')
Assert ($r.Count -eq 1 -and (Test-PartialSnapshot $r[0])) 'a partial version with 3 newer complete versions may be deleted'

# --- The first clean-up: only what the user saw and approved ------------------------------------------
# The list of approved versions (Get-RetentionApprovedIds) only ever narrows the plan
# (Get-ApprovedRetentionPlan): the rule still decides, and the checks above run again on what is left.
$letters=Id 43981   # abcd...
$read=@(Get-RetentionApprovedIds ("`r`n  "+(Id 1)+"  `r`n`r`n`t"+$letters.ToUpperInvariant()+" `n"+(Id 1)+"`n"))
Assert (($read -join ',') -ceq (@((Id 1),$letters) -join ',')) 'the approved list holds one full ID a line: blank lines, spaces around an ID, capital letters and a repeated ID make no difference'
Assert ((@(Get-RetentionApprovedIds (([char]0xFEFF)+(Id 2)+"`r"+(Id 3))) -join ',') -ceq ((Ids 2,3) -join ',')) 'a byte-order mark and old line endings are read too'
Assert-Throws {Get-RetentionApprovedIds ''} '*is empty*deleted nothing*' 'an empty approved list is refused'
Assert-Throws {Get-RetentionApprovedIds " `r`n`t`n "} '*is empty*deleted nothing*' 'so is one with only blank lines'
Assert-Throws {Get-RetentionApprovedIds ((Id 1)+"`n"+(Id 2).Substring(0,8))} '*not a full version ID*deleted nothing*' 'a shortened ID makes the whole list unusable: nothing is guessed'
Assert-Throws {Get-RetentionApprovedIds ((Id 1)+' '+(Id 2))} '*not a full version ID*' 'two IDs on one line are refused'
Assert-Throws {Get-RetentionApprovedIds "latest`n"} '*not a full version ID*' 'a name such as latest is refused'
$six=@(1..6|ForEach-Object {Ver $_ "2026-06-0$($_)T12:00:00Z"})
$shown=Plan @($six[0..4]) 2 0 5        # the preview: 1, 2 and 3 would go
$approved=@(Gone $shown)
$later=Plan $six 2 0 6                 # one backup later the plan holds one more: 4
$narrow=@(Get-ApprovedRetentionPlan $later $approved)
Assert ((Same $approved (Ids 1,2,3)) -and (Same (Gone $later) (Ids 1,2,3,4)) -and (Same (Gone $narrow) (Ids 1,2,3)) -and $narrow.Count -eq $later.Count) 'a plan that grew by one version since the preview is narrowed to the versions that were shown'
Assert ((Same (Why $narrow 4) @('OutsideRules','NotApproved')) -and (Same (Why $narrow 1) @('OutsideRules')) -and (Same (Why $narrow 6) (Why $later 6)) -and (Same (Gone $later) (Ids 1,2,3,4)) -and (Same (Why $later 4) @('OutsideRules'))) 'the version that was not shown stays for now, with the reason; nothing else changes, and the plan handed in is left as it was'
Assert (Same @(Get-RetentionRemovals $narrow (Id 6) $six 'pc'|ForEach-Object {$_.id}) (Ids 1,2,3)) 'the checks before deleting pass on the narrowed plan and hand over exactly the approved versions'
foreach($record in @(Get-ApprovedRetentionPlan $later $approved)){$record.Keep=$false;$record.Reasons=[string[]]@('Changed')}
Assert ((Same (Gone $later) (Ids 1,2,3,4)) -and (Same (Why $later 6) @('JustMade','NewestComplete','LastN')) -and (Same (Why $later 4) @('OutsideRules')) -and (Same (Why $later 1) @('OutsideRules'))) 'every record handed back is a copy: changing them changes nothing in the plan they were made from'
$narrow=@(Get-ApprovedRetentionPlan $later (Ids 1,5,6,99))
Assert ((Same (Gone $narrow) (Ids 1)) -and (Same (Why $narrow 5) (Why $later 5)) -and (Same (Why $narrow 6) (Why $later 6)) -and $narrow.Count -eq 6) 'an approved version that the plan keeps stays kept, and one that no longer exists is not added: the list never widens the plan'
$narrow=@(Get-ApprovedRetentionPlan (Plan $shared 2 0 5) (Ids 1,21,26,31,41))
Assert ((Same (Gone $narrow) (Ids 1)) -and $narrow.Count -eq 9 -and @($narrow|Where-Object {$_.Host -cne 'pc'}).Count -eq 0) 'another computer''s versions and another program''s on the list are never deleted: they are not in the plan'
Assert (@(Gone (Get-ApprovedRetentionPlan $later @())).Count -eq 0 -and @(Gone (Get-ApprovedRetentionPlan $later $null)).Count -eq 0 -and @(Gone (Get-ApprovedRetentionPlan $later (Ids 98,99))).Count -eq 0) 'with nothing approved, or only versions that are not in the plan, nothing goes'
Assert (@(Gone (Get-ApprovedRetentionPlan $later @((Id 1).Substring(0,8),(' '+(Id 2)),(Id 3).Replace('0','O')))).Count -eq 0) 'the plan is matched by exact full ID only (reading the list is what trims it and lowers its letters)'
# A partial version that was waiting for its mark is previewed under the ID it had; the mark gives it a new one.
$waitingShown=Plan (@((Ver 50 '2026-05-01T12:00:00Z' -Partial))+$six[0..4]) 10 0 5
$markedNow=Plan (@((Ver 51 '2026-05-01T12:00:00Z' -Partial))+$six) 10 0 6
$narrow=@(Get-ApprovedRetentionPlan $markedNow @(Gone $waitingShown))
Assert ((Same (Gone $waitingShown) (Ids 50)) -and (Same (Gone $markedNow) (Ids 51)) -and @(Gone $narrow).Count -eq 0 -and (Same (Why $narrow 51) @('PartialAfter3Complete','NotApproved'))) 'a partial version that was marked after the preview has a new ID: it was not approved under it, so it stays for the next clean-up'
$random=[Random]::new(20261115)
foreach($round in 1..25){
 $at=$newest;$history=@(1..40|ForEach-Object {$v=Ver $_ $at.UtcDateTime.ToString('o') -Partial:($random.Next(0,6) -eq 0 -and $_ -gt 1);$at=$at.AddHours(-$random.Next(1,24*45));$v})   # 1 is the newest
 $p=Plan $history $random.Next(1,6) $random.Next(0,5) 1
 $pick=@(1..45|Where-Object {$random.Next(0,2)}|ForEach-Object {Id $_})
 $n=@(Get-ApprovedRetentionPlan $p $pick)
 $want=@(Gone $p|Where-Object {$_ -cin $pick})
 if(-not (Same (Gone $n) $want) -or -not (Same @(Get-RetentionRemovals $n (Id 1) $history 'pc'|ForEach-Object {$_.id}) $want) -or @(Kept $p|Where-Object {$_ -cnotin (Kept $n)}).Count){throw "FAIL random approved list $round"}
}
Assert $true '25 random histories and lists: what goes is exactly what is both in the plan and on the list, the checks agree, and nothing the plan keeps is ever deleted'

# --- Deleting many versions at once -----------------------------------------------------------------
$ids=@(1..520|ForEach-Object {[guid]::NewGuid().ToString('N')*2})
$batches=@(Split-SnapshotIdBatches $ids)
Assert ($batches.Count -eq 3 -and @($batches|Where-Object {@($_).Count -gt 200}).Count -eq 0) '520 versions are deleted in batches of at most 200'
Assert ((@($batches|ForEach-Object {$_}) -join ',') -ceq ($ids -join ',')) 'every version is in exactly one batch, in the same order'
# Windows refuses a command line over 32,767 characters; the worker's fixed arguments take a few hundred.
Assert (@($batches|Where-Object {((@($_) -join ' ').Length+2000) -ge 32767}).Count -eq 0) 'each batch fits a Windows command line with room for the other arguments'
$one=@(Split-SnapshotIdBatches @($ids[0]))
Assert ($one.Count -eq 1 -and @($one[0]).Count -eq 1 -and @($one[0])[0] -ceq $ids[0]) 'a single version is one batch'
Assert (@(Split-SnapshotIdBatches @()).Count -eq 0) 'nothing to delete gives no batch'

# --- Restore warnings ---------------------------------------------------------------------------------
$src='C:\Users\YOUR_USER\Documents\work\'
$stamp='{"message_type":"error","error":{"message":"failed to restore timestamp of \"D:\\\\out\\\\C\\\\Users\": Access is denied."},"during":"restore","item":"\\C\\Users"}'
$exit='{"message_type":"exit_error","code":1,"message":"Fatal: There were 1 errors"}'
$w=@(Get-RestoreParentWarnings ($stamp+"`n"+$exit) $src ([pscustomobject]@{total_files=14;files_restored=13}))
Assert ($w.Count -eq 1 -and $w[0] -like 'failed to restore timestamp*') 'a date that could not be set on a folder above the source is a warning'
$inside='{"message_type":"error","error":{"message":"failed to restore timestamp of \"D:\\\\out\\\\C\\\\Users\\\\someone\\\\Documents\\\\work\\\\sub\": Access is denied."},"during":"restore","item":"\\C\\Users\\someone\\Documents\\work\\sub"}'
Assert (@(Get-RestoreParentWarnings ($inside+"`n"+$exit) $src $null).Count -eq 0) 'the same error on a folder inside the source is a failure'
$content='{"message_type":"error","error":{"message":"open D:\\out\\C\\Users\\someone\\Documents\\work\\a.txt: Access is denied."},"during":"restore","item":"\\C\\Users\\someone\\Documents\\work\\a.txt"}'
Assert (@(Get-RestoreParentWarnings ($stamp+"`n"+$content+"`n"+$exit) $src $null).Count -eq 0) 'a file that could not be written is a failure, also beside a harmless warning'
Assert (@(Get-RestoreParentWarnings ("ignoring error for \C\Users: something`n"+$exit) $src $null).Count -eq 0) 'output that cannot be understood is a failure'
Assert (@(Get-RestoreParentWarnings $exit $src $null).Count -eq 0) 'a failure without any item error is a failure'
Assert (@(Get-RestoreParentWarnings ($stamp+"`n"+$exit) $src ([pscustomobject]@{total_files=14;files_restored=10})).Count -eq 0) 'more items missing than warnings is a failure'
Assert (@(Get-RestoreParentWarnings ($stamp+"`n"+$exit) 'C:\Users\' $null).Count -eq 0) 'the source folder itself is not a folder above the source'
# The folders above are judged by what the restored version itself backed up, not by today's settings.
Assert (@(Get-RestoreParentWarnings ($stamp+"`n"+$exit) @($src,'C:\Users') $null).Count -eq 0) 'a folder that the version backed up itself (an older, wider source) is not a folder above the source'
Assert (@(Get-RestoreParentWarnings ($stamp+"`n"+$exit) @('C:\Users\YOUR_USER\Documents\work','C:\Users\YOUR_USER\Pictures') $null).Count -eq 1) 'a version with several source folders accepts the folders above them'
Assert (@(Get-RestoreParentWarnings ($stamp+"`n"+$exit) @() $null).Count -eq 0) 'without the version''s source paths nothing is accepted'

# --- A pending password change after the drive letter changed -------------------------------------
$journal=[pscustomobject]@{Version=1;Repository='Y:\Work-Versions';ConfigPath='C:\tool\jobs\work.local.json';DestinationVolumeId='volume-1';RepositoryFolder='Work-Versions'}
Assert-RotationJournalTarget $journal 'volume-1' 'Work-Versions' 'Z:\Work-Versions'
Assert $true 'a pending password change is recognised by volume and folder after the drive letter changed'
Assert-Throws {Assert-RotationJournalTarget $journal 'volume-2' 'Work-Versions' 'Y:\Work-Versions'} '*another*' 'the same path on another volume is refused'
Assert-Throws {Assert-RotationJournalTarget $journal 'volume-1' 'Other-Versions' 'Y:\Other-Versions'} '*another*' 'another repository folder on the same volume is refused'
$oldJournal=[pscustomobject]@{Version=1;Repository='Y:\Work-Versions';ConfigPath='C:\tool\jobs\work.local.json'}
Assert-RotationJournalTarget $oldJournal 'volume-1' 'Work-Versions' 'Y:\Work-Versions'
Assert-RotationJournalTarget $oldJournal 'volume-1' 'Work-Versions' 'Z:\Work-Versions'
Assert $true 'a journal written by an earlier version resumes on the same path and after a drive-letter change'
Assert-Throws {Assert-RotationJournalTarget $oldJournal 'volume-1' 'Other-Versions' 'Y:\Other-Versions'} '*another*' 'an earlier journal for another folder is refused'

# --- A locked repository ------------------------------------------------------------------------------
$text=Get-EngineFailureText 'CheckingStructure' 11
Assert ($text -like '*exit code 11*' -and $text -like '*locked*' -and $text -like '*Nothing is damaged*' -and $text -like '*CheckingStructure.errors.log*' -and $text -notlike '*memory*') 'a locked repository is named as such, says nothing is damaged and does not blame memory'
Assert ((Get-EngineFailureText 'Verifying' 1) -like '*exit code 1*memory allocation*') 'other failures keep the general wording'
# --- Removing a lock left by a run that ended --------------------------------------------------------
# A lock as restic records it (cat lock), with what now runs on this computer under its process number:
# nothing ($null), or a process with its name and start time (no start time: it cannot be examined).
function Left([int]$n,$process=$null,[string]$computer='Work-PC',[string]$time='2026-11-14T10:00:00.1234567+02:00',$number=4242,$exclusive=$false){
 [pscustomobject]@{Id=(Id $n);Lock=[pscustomobject]@{time=$time;exclusive=$exclusive;hostname=$computer;username='Work-PC\me';pid=$number};Process=$process}
}
function Proc([string]$name,$started){[pscustomobject]@{Name=$name;StartedUtc=$(if($started){[DateTimeOffset]::Parse($started,[Globalization.CultureInfo]::InvariantCulture).UtcDateTime}else{$null})}}
$d=Get-LockReleaseDecision @((Left 1)) 'WORK-pc'
Assert ($d.Release -eq $true -and $d.Reason -eq '' -and @($d.Locks).Count -eq 1 -and $d.Locks[0].State -eq 'Ended') 'a lock of this computer (the name compared without regard to case) whose process is gone may be removed'
Assert ($d.Locks[0].Id -ceq (Id 1) -and $d.Locks[0].Pid -eq 4242 -and $d.Locks[0].CreatedUtc -ceq '2026-11-14T08:00:00.1234567Z' -and $d.Locks[0].Exclusive -eq $false -and $d.Locks[0].Computer -ceq 'Work-PC') 'the decision names the lock: its ID, process number, creation time (UTC) and kind'
$d=Get-LockReleaseDecision @((Left 2 $null 'Laptop')) 'Work-PC'
Assert ($d.Release -eq $false -and $d.Locks[0].State -eq 'OtherComputer' -and $d.Reason -like '*another computer (Laptop)*left in place*') 'a lock of another computer is never removed, and the reason names that computer'
$d=Get-LockReleaseDecision @((Left 3 (Proc 'restic_0.19.1_windows_amd64' '2026-11-14T07:59:58Z'))) 'Work-PC'
Assert ($d.Release -eq $false -and $d.Locks[0].State -eq 'Running' -and $d.Reason -like '*still running on this computer (process 4242)*') 'a lock whose restic process is still running is never removed'
$d=Get-LockReleaseDecision @((Left 4 (Proc 'notepad' '2026-11-14T08:20:00Z'))) 'Work-PC'
Assert ($d.Release -eq $true -and $d.Locks[0].State -eq 'Ended') 'a process number reused by another program that started after the lock was made: the run that made the lock has ended'
$d=Get-LockReleaseDecision @((Left 5 (Proc 'restic' '2026-11-14T08:20:00Z'))) 'Work-PC'
Assert ($d.Release -eq $false -and $d.Locks[0].State -eq 'Unclear' -and $d.Reason -like '*process number*4242*') 'a restic process under that number that seems to have started after the lock is unclear (the clock may have changed): not removed'
$d=Get-LockReleaseDecision @((Left 6 (Proc 'svchost' '2026-11-01T08:00:00Z'))) 'Work-PC'
Assert ($d.Release -eq $false -and $d.Locks[0].State -eq 'Unclear') 'another program that was already running under that number when the lock was made is unclear: not removed'
$d=Get-LockReleaseDecision @((Left 7 (Proc '' $null))) 'Work-PC'
Assert ($d.Release -eq $false -and $d.Locks[0].State -eq 'Unclear' -and $d.Reason -like '*process 4242*could not be examined*') 'a process that cannot be examined is unclear: not removed'
$unreadable=[pscustomobject]@{Id=(Id 8);Lock=$null;Process=$null}
$d=Get-LockReleaseDecision @($unreadable) 'Work-PC'
Assert ($d.Release -eq $false -and $d.Locks[0].State -eq 'Unclear' -and $d.Reason -like '*could not be read*') 'a lock that cannot be read is not removed'
foreach($broken in @((Left 9 $null 'Work-PC' 'yesterday'),(Left 9 $null 'Work-PC' '2026-11-14T10:00:00+02:00' 0),(Left 9 $null 'Work-PC' '2026-11-14T10:00:00+02:00' '4242x'),(Left 9 $null ''),[pscustomobject]@{Id='latest';Lock=(Left 9).Lock;Process=$null},[pscustomobject]@{Id=(Id 9);Lock=(Left 9).Lock},[pscustomobject]@{Id=(Id 9);Lock=[pscustomobject]@{hostname='Work-PC';pid=4242};Process=$null},[pscustomobject]@{Id=(Id 9);Lock=[pscustomobject]@{time='2026-11-14T10:00:00+02:00';hostname='Work-PC';pid=4242};Process=$null},(Left 9 $null 'Work-PC' '2026-11-14T10:00:00+02:00' 4242 'no'))){
 if((Get-LockReleaseDecision @($broken) 'Work-PC').Release){throw 'FAIL an incomplete lock record was accepted'}
}
Assert $true 'a lock without a usable time, process number, computer name, kind or ID, or one whose process was not looked up, is not removed'
Assert ((Get-LockReleaseDecision @((Left 1)) '').Release -eq $false) 'without this computer''s name nothing is removed'
$d=Get-LockReleaseDecision @((Left 10),(Left 11 $null 'Laptop'),(Left 12 $null 'Work-PC' '2026-11-14T10:05:00+02:00' 5151 $true)) 'Work-PC'
Assert ($d.Release -eq $false -and @($d.Locks).Count -eq 3 -and @($d.Locks|Where-Object {$_.State -eq 'Ended'}).Count -eq 2 -and $d.Reason -like '*Laptop*') 'one lock that may not be removed keeps every lock in place'
$d=Get-LockReleaseDecision @((Left 10),(Left 12 $null 'Work-PC' '2026-11-14T10:05:00+02:00' 5151 $true)) 'Work-PC'
Assert ($d.Release -eq $true -and @($d.Locks).Count -eq 2 -and $d.Locks[1].Exclusive -eq $true -and $d.Locks[1].Pid -eq 5151) 'several locks that all belong to ended runs of this computer may be removed together'
$d=Get-LockReleaseDecision @() 'Work-PC'
Assert ($d.Release -eq $false -and $d.Reason -eq '' -and @($d.Locks).Count -eq 0) 'no lock: nothing to remove and nothing to report'
# --- The same rule against real processes, looked up the way the worker looks them up ------------------
# Windows hands the number of an ended process to the next program now and then. That cannot be caused on
# purpose, but what the worker then sees can: a lock that names the number of a program that is running
# now, written a little before or after that program started. The lock times are taken from the
# program's own start time, so nothing here depends on timing. ping stands in for "another program"; a
# copy of it named restic-standin stands in for another restic run.
$stand=Join-Path ([IO.Path]::GetTempPath()) ('devdrive-lock-test-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $stand|Out-Null
$programs=[Collections.Generic.List[Diagnostics.Process]]::new()
function Start-Waiting([string]$file){$psi=[Diagnostics.ProcessStartInfo]::new($file);$psi.UseShellExecute=$false;$psi.CreateNoWindow=$true;$psi.RedirectStandardOutput=$true;foreach($a in '-n','120','127.0.0.1'){[void]$psi.ArgumentList.Add($a)};$p=[Diagnostics.Process]::Start($psi);$programs.Add($p);$p}
# What the worker sees under the program's number; the test stops when the program could not be seen.
function Seen($program,[string]$name){
 $seen=Get-LockProcess $program.Id
 if($program.HasExited -or $null -eq $seen -or $seen.Name -ine $name -or $null -eq $seen.StartedUtc){throw "FAIL the stand-in $name could not be looked up while it ran: $($seen|ConvertTo-Json -Compress)"}
 $seen
}
# A lock that names the program's number, written $seconds after (or, when negative, before) it started.
function LockAt($program,$seen,[int]$seconds){
 [pscustomobject]@{Id=(Id 20);Lock=[pscustomobject]@{time=([DateTimeOffset]$seen.StartedUtc).AddSeconds($seconds).ToString('o');exclusive=$false;hostname='Work-PC';username='Work-PC\me';pid=$program.Id};Process=$seen}
}
try{
 $ping=Join-Path ([Environment]::SystemDirectory) 'ping.exe';$standin=Join-Path $stand 'restic-standin.exe';Copy-Item -LiteralPath $ping -Destination $standin
 $other=Start-Waiting $ping;$engineLike=Start-Waiting $standin
 $seen=Seen $other 'ping'
 $d=Get-LockReleaseDecision @((LockAt $other $seen -5)) 'Work-PC'
 Assert ($d.Release -eq $true -and $d.Locks[0].State -eq 'Ended' -and $d.Locks[0].Pid -eq $other.Id) 'a real program that started after the lock was made now has its process number (Windows reused it): the run that made the lock has ended, and the lock may go'
 $d=Get-LockReleaseDecision @((LockAt $other $seen 5)) 'Work-PC'
 Assert ($d.Release -eq $false -and $d.Locks[0].State -eq 'Unclear' -and $d.Reason -like "*process $($other.Id)*already running*") 'a real program that was already running under that number when the lock was made keeps the lock'
 $seenEngine=Seen $engineLike 'restic-standin'
 $d=Get-LockReleaseDecision @((LockAt $engineLike $seenEngine -5)) 'Work-PC'
 Assert ($d.Release -eq $false -and $d.Locks[0].State -eq 'Unclear' -and $d.Reason -like "*another backup program*($($engineLike.Id))*") 'a real restic program that started after the lock under its number cannot be told from the run that made it: the lock stays'
 $d=Get-LockReleaseDecision @((LockAt $engineLike $seenEngine 5)) 'Work-PC'
 Assert ($d.Release -eq $false -and $d.Locks[0].State -eq 'Running' -and $d.Reason -like "*still running*process $($engineLike.Id)*") 'a real restic program that was running when the lock was made is the run that made it: the lock stays'
}finally{
 foreach($p in $programs){try{if(-not $p.HasExited){$p.Kill()};[void]$p.WaitForExit(10000)}catch{};$p.Dispose()}
 Remove-Item -LiteralPath $stand -Recurse -Force -ErrorAction SilentlyContinue
}
$text=Get-EngineFailureText 'CheckingStructure' 11 'a backup is still running on this computer (process 4242). Wait until it has finished, then try again.'
Assert ($text -like '*exit code 11*locked: a backup is still running on this computer (process 4242).*Nothing is damaged*CheckingStructure.errors.log*' -and $text -notlike '*memory*' -and $text -notlike '*An earlier run was stopped*') 'a lock that was examined and left in place is reported with its own reason instead of the general guess'
Write-Output 'All versioned-engine rule tests passed.'
