#Requires -Version 7.2
# Keep versions from end to end: the real worker (Backup-Worker.ps1 -TestRoot) and real restic against a
# disposable repository under the temporary directory, holding versions dated back over eight months for
# two sets of folders of this computer, another computer and another program. Covers a preview (nothing
# deleted, the list equals what the next backup deletes), the clean-up itself, partial versions, the
# clean-up switched off, the newest complete version of every set, the earlier settings (days and
# weeks), which are refused, and the first clean-up after a preview, which deletes only the versions
# that were shown and approved (-RetentionApprovedFile). The rule itself is tested without restic in
# Test-BackupVersionsRules.ps1.
# Needs no backup drive. Skips when restic is not installed (Install-BackupEngine.ps1).
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'Backup.Status.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Backup.History.psm1') -Force
function Assert($ok,[string]$message){if(-not $ok){throw "FAIL $message"};Write-Output "PASS $message"}
function Same($a,$b){(@($a|Sort-Object) -join ',') -ceq (@($b|Sort-Object) -join ',')}
$engine=Join-Path $PSScriptRoot 'bin\restic_0.19.1_windows_amd64.exe'
if(-not(Test-Path -LiteralPath $engine)){Write-Output 'SKIP: bin\restic_0.19.1_windows_amd64.exe is not installed (Install-BackupEngine.ps1)';return}
$base=Join-Path ([IO.Path]::GetFullPath([IO.Path]::GetTempPath())) ('backup-retention-test-'+[guid]::NewGuid().ToString('N').Substring(0,10))
$drive=Join-Path $base 'drive';$work=Join-Path $base 'work';$source=Join-Path $work 'source';$second=Join-Path $work 'other-folders';$private=Join-Path $base 'private'
New-Item -ItemType Directory -Path $drive,$source,$second,$private|Out-Null
$config=Get-Content (Join-Path $PSScriptRoot 'config.example.json') -Raw|ConvertFrom-Json
$config.Source=$work+'\';$config.SourceVolumeId='test-source-volume';$config.DestinationVolumeId='test-backup-volume';$config.RepositoryFolder='Test-Retention'
$config.PasswordDpapiPath=Join-Path $private 'key.dpapi';$config.RecoveryKeyPath=Join-Path $private 'recovery.txt';$config.Include=@('source');$config.Choices=@([pscustomobject]@{Path='source';Mode='Versioned';Reason='Disposable test source'});$config.DefaultMode='Skip';$config.RateMBps=0;$config.MemoryMiB=512;$config.CpuThreads=1;$config.ReadConcurrency=1;$config.PackMiB=8
$configPath=Join-Path $private 'settings.json';$config|ConvertTo-Json -Depth 7|Set-Content -LiteralPath $configPath
$repo=Join-Path $drive $config.RepositoryFolder
function Run([hashtable]$extra=@{}){
 $run=Join-Path $private ('runs\Backup-'+[guid]::NewGuid().ToString('N').Substring(0,8))
 & (Join-Path $PSScriptRoot 'Backup-Worker.ps1') -ConfigPath $configPath -Action Backup -RunDirectory $run -TestRoot $drive @extra
 Read-BackupStatus (Join-Path $run 'result.json')
}
function Read-Password {[Net.NetworkCredential]::new('',(((Get-Content -LiteralPath $config.PasswordDpapiPath -Raw).Trim())|ConvertTo-SecureString)).Password}
function Restic([string[]]$arguments){
 # The engine on its own, to prepare dated versions and to check results independently of the worker.
 $psi=[Diagnostics.ProcessStartInfo]::new($engine);$psi.UseShellExecute=$false;$psi.CreateNoWindow=$true;$psi.RedirectStandardOutput=$true;$psi.RedirectStandardError=$true;$psi.Environment['RESTIC_PASSWORD']=(Read-Password)
 foreach($a in @('-r',$repo,'--cache-dir',(Join-Path $base 'direct-cache'))+$arguments){[void]$psi.ArgumentList.Add($a)}
 $p=[Diagnostics.Process]::Start($psi);$out=$p.StandardOutput.ReadToEndAsync();$err=$p.StandardError.ReadToEndAsync();$p.WaitForExit()
 $result=[pscustomobject]@{Code=$p.ExitCode;Out=$out.GetAwaiter().GetResult();Err=$err.GetAwaiter().GetResult()};$p.Dispose();$result
}
function Snapshots {@((Restic @('--json','snapshots')).Out|ConvertFrom-Json)}
function Saved {@(Snapshots|ForEach-Object {$_.id})}
# Every stored file of the repository: the packs with the data, the index and the versions themselves.
function Stored {@(Get-ChildItem -LiteralPath (Join-Path $repo 'data'),(Join-Path $repo 'index'),(Join-Path $repo 'snapshots') -Recurse -File|ForEach-Object {$_.FullName})}
function Content([string]$text){[IO.File]::WriteAllText((Join-Path $source 'file.txt'),$text)}
function Named($result){@($result.Retention.Candidates|ForEach-Object {$_.Id})}
$shape='Preview,Approved,Last,Months,Kept,Removed,PartialRemoved,Deferred,Candidates,Error'
try{
 Content 'the first version'
 $s0=Run
 Assert ($s0.State -eq 'Completed' -and -not $s0.PSObject.Properties['Retention']) 'a backup without Keep versions completes and reports no clean-up'
 Assert ($s0.RepositoryMissing -eq $false -and $s0.RepositoryCreated -eq $true -and $null -eq $s0.Note -and (Test-Path -LiteralPath (Join-Path $repo 'config'))) 'a first-ever backup creates its versions folder without being asked to, and says that it did'
 $first=@(Snapshots|Where-Object {$_.id -ceq $s0.Snapshot})[0];$computer=[string]$first.hostname;$folder=[string]@($first.paths)[0]
 Assert ($computer -and @($first.paths).Count -eq 1) 'the worker''s version names this computer and one source folder'

 # --- Versions dated back over eight months ------------------------------------------------------------
 # Days are counted from the first of this month, so the expected result is the same on every date.
 $month=[datetime]::new((Get-Date).Year,(Get-Date).Month,1);$ids=@{}
 function On([int]$monthsBack,[int]$day,[int]$hour=12){$month.AddMonths(-$monthsBack).AddDays($day-1).AddHours($hour)}
 function Seed([string]$name,$time,[string]$path=$folder,[string]$computerName=$computer,[switch]$Partial,[switch]$Foreign){
  [IO.File]::WriteAllText((Join-Path $path 'file.txt'),"version $name")
  $arguments=@('--json','backup','--host',$computerName);if(-not $Foreign){$arguments+=@('--tag','devdrive')}
  if($time){$arguments+=@('--time',([datetime]$time).ToString('yyyy-MM-dd HH:mm:ss'))}
  $o=Restic ($arguments+$path);if($o.Code -ne 0){throw "Preparing version '$name' ended with code $($o.Code): $($o.Err)"}
  $id=@($o.Out -split "`r?`n"|ForEach-Object {try{$_|ConvertFrom-Json}catch{}}|Where-Object {$_ -and $_.message_type -eq 'summary'})[0].snapshot_id
  # A partial version is told by its mark; these are marked the way the worker marks one.
  if($Partial){$m=Restic (@('--json')+(Get-PartialMarkArguments $id));if($m.Code -ne 0){throw "Marking '$name' failed: $($m.Err)"};$id=@($m.Out -split "`r?`n"|ForEach-Object {try{$_|ConvertFrom-Json}catch{}}|Where-Object {$_ -and $_.message_type -eq 'changed'})[0].new_snapshot_id}
  $ids[$name]=$id
 }
 # This computer, the worker's folder: two versions a month (three on one day), none 4 and 5 months back.
 foreach($back in 8,7,6,3,2,1){Seed "A-$back-10" (On $back 10);Seed "A-$back-20" (On $back 20)}
 Seed 'A-1-20-early' (On 1 20 8);Seed 'A-1-20-late' (On 1 20 18)
 Seed 'A-partial-old' (On 7 15) -Partial
 Seed 'A-foreign' (On 8 5) -Foreign
 Seed 'A-partial-new' $null -Partial   # made now: newer than the first backup
 # A partial version that could not be marked when it was made (the repository was locked): it still
 # carries the tag of a complete version and is noted beside the password file, to be marked later.
 Seed 'A-pending' $null
 $pendingPath=$config.PasswordDpapiPath+'.partial-pending.local.json'
 [void](Write-BackupStatus @($ids['A-pending']) $pendingPath)
 # This computer, another set of folders: its newest complete version is 2 months old, with partial versions after it.
 foreach($name in 'B-8-10','B-7-10','B-6-10','B-3-10','B-3-20','B-2-10','B-2-20'){$part=$name -split '-';Seed $name (On ([int]$part[1]) ([int]$part[2])) $second}
 Seed 'B-partial-old' (On 8 20) $second -Partial
 Seed 'B-partial-mid' (On 2 15) $second -Partial
 Seed 'B-partial-tail' (On 1 5) $second -Partial
 # Another computer that shares the repository.
 foreach($back in 8,7,6,5,1){Seed "O-$back" (On $back 10) $folder 'other-computer'}
 Seed 'O-partial' (On 8 20) $folder 'other-computer' -Partial
 $others=@('O-8','O-7','O-6','O-5','O-1','O-partial','A-foreign'|ForEach-Object {$ids[$_]})
 # Last 3 and 5 months. Folder A keeps its 3 newest and the newest version of each month back to 4 months
 # ago; folder B counts its months from its own newest complete version (2 months old), so its version of
 # 6 months ago is still inside. A partial version goes only where 3 complete versions are newer.
 $expected=@('A-1-20','A-1-20-early','A-1-10','A-2-10','A-3-10','A-6-10','A-6-20','A-7-10','A-7-20','A-8-10','A-8-20','A-partial-old','B-3-10','B-7-10','B-8-10','B-partial-old'|ForEach-Object {$ids[$_]})

 # --- Preview: the plan is reported, nothing is deleted ----------------------------------------------
 Content 'the preview''s version'
 $before=@(Saved);$filesBefore=@(Stored)
 $preview=Run @{KeepLast=3;KeepMonths=5;RetentionPreview=$true}
 $after=@(Saved)
 Assert ($preview.State -eq 'Completed' -and $preview.Snapshot -and $preview.BackupSummary.snapshot_id -eq $preview.Snapshot) 'a backup with a preview of the clean-up backs up as usual'
 Assert ((@($preview.Retention.PSObject.Properties.Name) -join ',') -ceq $shape) 'the result describes the clean-up with exactly these fields: Preview, Approved, Last, Months, Kept, Removed, PartialRemoved, Deferred, Candidates, Error'
 Assert ($preview.Retention.Preview -eq $true -and $preview.Retention.Last -eq 3 -and $preview.Retention.Months -eq 5 -and $preview.Retention.Removed -eq 0 -and $preview.Retention.PartialRemoved -eq 0 -and $preview.Retention.Approved -eq $false -and $preview.Retention.Deferred -eq 0 -and $null -eq $preview.Retention.Error) 'a preview reports its settings and that nothing was deleted'
 Assert (Same $after ($before+$preview.Snapshot)) 'after a preview every version is still there: the same IDs as before, and the new one'
 Assert (@($filesBefore|Where-Object {-not(Test-Path -LiteralPath $_)}).Count -eq 0 -and @('DeletingOldVersions','FreeingSpace','CheckingAfterCleanUp'|Where-Object {Test-Path -LiteralPath (Join-Path $preview.RunDirectory ($_+'.jsonl'))}).Count -eq 0) 'a preview with 16 versions to delete removes no file of the repository (no pack, index or version file) and runs no deleting, freeing or checking step'
 Assert (Same (Named $preview) $expected) 'the preview lists what would be deleted now: 16 versions of this computer''s two sets of folders'
 Assert ($preview.Retention.Kept -eq 9) 'and counts the complete versions that stay: 5 of one set of folders and 4 of the other'
 $old=@($preview.Retention.Candidates|Where-Object {$_.Id -ceq $ids['A-partial-old']})[0];$plain=@($preview.Retention.Candidates|Where-Object {$_.Id -ceq $ids['B-3-10']})[0]
 Assert ($old.Partial -eq $true -and $plain.Partial -eq $false -and $old.Host -ceq $computer -and $old.Paths -is [array] -and (@($old.Paths) -join '|') -ceq $folder -and (@($plain.Paths) -join '|') -ceq $second -and (ConvertTo-HistoryDate $old.Time).LocalDateTime -eq (On 7 15)) 'each listed version carries its ID, time, computer, folders and whether it is partial'
 Assert (@($preview.Retention.Candidates|Where-Object {$_.PSObject.Properties.Name -match 'Size|Bytes|Freed'}).Count -eq 0 -and @($preview.Retention.PSObject.Properties.Name -match 'Size|Bytes|Freed').Count -eq 0) 'no size is reported as space that deleting a version would free'
 $planned=@(Get-Content -LiteralPath (Join-Path $preview.RunDirectory 'clean-up-plan.json') -Raw|ConvertFrom-Json)
 $why={param([string]$name)@(@($planned|Where-Object {$_.Id -ceq $ids[$name]})[0].Reasons) -join ','}
 Assert ((& $why 'A-2-20') -ceq 'Monthly' -and (& $why 'A-1-20-late') -ceq 'LastN,Monthly' -and (& $why 'B-6-10') -ceq 'Monthly' -and (& $why 'A-partial-new') -ceq 'PartialKept' -and (& $why 'A-partial-old') -ceq 'PartialAfter3Complete' -and (& $why 'A-8-10') -ceq 'OutsideRules' -and @($planned|Where-Object {$_.Host -cne $computer}).Count -eq 0) 'the plan saved with the run gives the reason for every version of this computer, and names no other computer''s'
 $noted=@($planned|Where-Object {$_.Id -ceq $ids['A-pending']})[0]
 Assert ($noted.Partial -eq $true -and (@($noted.Reasons) -join ',') -ceq 'PartialKept' -and $ids['A-pending'] -in $after -and (Test-Path -LiteralPath $pendingPath) -and -not(Test-Path -LiteralPath (Join-Path $preview.RunDirectory 'MarkingPartial.jsonl'))) 'a partial version still waiting for its mark is planned as partial, but a preview does not mark it: its ID stays and the note stays'

 # --- The clean-up itself ------------------------------------------------------------------------------
 Content 'the version of the real clean-up'
 $before=@(Saved)
 $real=Run @{KeepLast=3;KeepMonths=5}
 $left=@(Saved)
 Assert ($real.State -eq 'Completed' -and (@($real.Retention.PSObject.Properties.Name) -join ',') -ceq $shape -and $real.Retention.Preview -eq $false -and $real.Retention.Approved -eq $false -and $real.Retention.Deferred -eq 0 -and $real.RepositoryCreated -eq $false -and $null -eq $real.Retention.Error) 'the next backup, without the preview, cleans up without an error'
 Assert ((Same (Named $real) (Named $preview)) -and (Same (Named $real) $expected)) 'it deletes exactly the versions the preview listed'
 Assert ($real.Retention.Removed -eq 16 -and $real.Retention.PartialRemoved -eq 2 -and $real.Retention.Kept -eq 10) 'the result counts 16 deleted versions, 2 of them partial, and 10 complete versions kept'
 # The real clean-up marks the waiting partial version first: the mark changes its ID.
 $marked=@(Snapshots|Where-Object {(Test-PartialSnapshot $_) -and $_.id -cnotin $before})
 Assert ($marked.Count -eq 1 -and $ids['A-pending'] -notin $left -and -not(Test-Path -LiteralPath $pendingPath) -and $marked[0].id -cnotin (Named $real)) 'the real clean-up marks the waiting partial version before it plans, and keeps it: only 2 complete versions are newer'
 Assert (Same $left (@($before|Where-Object {$_ -cnotin $expected -and $_ -cne $ids['A-pending']})+$real.Snapshot+$marked[0].id)) 'the repository holds every other version, and the new one'
 Assert (@($others|Where-Object {$_ -cnotin $left}).Count -eq 0) 'another computer''s versions (a partial one with 5 newer complete versions among them) and another program''s version are untouched'
 Assert ($ids['A-partial-new'] -in $left -and $ids['B-partial-mid'] -in $left -and $ids['B-partial-tail'] -in $left) 'partial versions with fewer than 3 newer complete versions of their own folders stay, whatever the other set of folders holds'
 Assert ($ids['B-6-10'] -in $left -and $ids['A-3-20'] -in $left -and $ids['A-1-20-late'] -in $left -and $s0.Snapshot -in $left) 'each set of folders keeps its month versions counted from its own newest complete version'
 Assert ((Test-Path -LiteralPath (Join-Path $real.RunDirectory 'FreeingSpace.jsonl')) -and (Test-Path -LiteralPath (Join-Path $real.RunDirectory 'CheckingAfterCleanUp.jsonl')) -and (Restic @('check')).Code -eq 0) 'space was freed and the repository checks clean afterwards'

 # --- Switched off: last 0 and months 0 ------------------------------------------------------------------
 $before=@(Saved)
 $off=Run
 Assert ($off.State -eq 'Completed' -and -not $off.PSObject.Properties['Retention'] -and (Same @(Saved) ($before+$off.Snapshot)) -and -not(Test-Path -LiteralPath (Join-Path $off.RunDirectory 'clean-up-plan.json'))) 'with last 0 and months 0 nothing is planned or deleted'
 $before=@(Saved)
 $offPreview=Run @{KeepLast=0;KeepMonths=0;RetentionPreview=$true}
 Assert ($offPreview.State -eq 'Completed' -and $offPreview.Retention.Preview -eq $true -and $offPreview.Retention.Candidates -is [array] -and @($offPreview.Retention.Candidates).Count -eq 0 -and $offPreview.Retention.Kept -eq 12 -and $null -eq $offPreview.Retention.Error -and (Same @(Saved) ($before+$offPreview.Snapshot))) 'a preview with the clean-up switched off lists nothing, although a partial version now has 4 newer complete versions'

 # --- Later backups: what the newer versions push out ------------------------------------------------
 $again=Run @{KeepLast=3;KeepMonths=5}
 Assert ($again.State -eq 'Completed' -and $null -eq $again.Retention.Error -and (Same (Named $again) @($s0.Snapshot,$preview.Snapshot,$real.Snapshot,$ids['A-partial-new'],$marked[0].id)) -and $again.Retention.Removed -eq 5 -and $again.Retention.PartialRemoved -eq 2 -and $again.Retention.Kept -eq 10) 'three backups later the three oldest of today are out of the last 3, and the two partial versions that 3 complete versions now follow go with them'
 Content 'the newest version'
 $before=@(Saved)
 $one=Run @{KeepLast=1;KeepMonths=0}
 $left=@(Saved)
 Assert ($one.State -eq 'Completed' -and $null -eq $one.Retention.Error -and $one.Retention.Removed -eq 9 -and $one.Retention.PartialRemoved -eq 0 -and $one.Retention.Kept -eq 2) 'last 1 and months 0: each set of folders keeps one complete version'
 Assert ($one.Snapshot -in $left -and $ids['B-2-20'] -in $left -and $ids['B-partial-mid'] -in $left -and $ids['B-partial-tail'] -in $left -and (Same $left (@($one.Snapshot,$ids['B-2-20'],$ids['B-partial-mid'],$ids['B-partial-tail'])+$others))) 'the newest complete version of a set of folders that only partial versions follow survives, and so do they'
 $inside='/'+$source.Replace(':','').Replace('\','/')+'/file.txt'
 Assert ((Restic @('dump',$one.Snapshot,$inside)).Out -ceq 'the newest version' -and (Restic @('check')).Code -eq 0) 'the newest version reads back intact and the repository checks clean'

 # --- A clean-up that cannot be planned: reported in the same shape, nothing deleted -----------------
 [IO.File]::WriteAllText($pendingPath,'not a list of versions {')
 foreach($asPreview in $true,$false){
  $before=@(Saved);$filesBefore=@(Stored)
  $failed=Run @{KeepLast=1;KeepMonths=0;RetentionPreview=$asPreview}
  if($failed.State -ne 'Completed' -or (@($failed.Retention.PSObject.Properties.Name) -join ',') -cne $shape -or $failed.Retention.Preview -ne $asPreview -or -not $failed.Retention.Error -or $failed.Retention.Removed -ne 0 -or $failed.Retention.PartialRemoved -ne 0 -or $failed.Retention.Candidates -isnot [array] -or @($failed.Retention.Candidates).Count -ne 0 -or -not (Same @(Saved) ($before+$failed.Snapshot)) -or @($filesBefore|Where-Object {-not(Test-Path -LiteralPath $_)}).Count -or (Test-Path -LiteralPath (Join-Path $failed.RunDirectory 'DeletingOldVersions.jsonl')) -or (Test-Path -LiteralPath (Join-Path $failed.RunDirectory 'FreeingSpace.jsonl'))){throw "FAIL a clean-up that could not be planned (preview: $asPreview): $($failed|ConvertTo-Json -Depth 6 -Compress)"}
 }
 Assert ($failed.Retention.Error -like '*not marked yet*nothing was cleaned up*') 'a clean-up that cannot be planned (the note of a waiting partial version is unreadable) is reported with the backup completed, in the same fields, and deletes nothing: as a preview and for real'
 Remove-Item -LiteralPath $pendingPath

 # --- The earlier settings ------------------------------------------------------------------------------
 $before=@(Saved)
 $earlier=Run @{KeepDays=7;KeepWeeks=4;KeepMonths=3}
 Assert ($earlier.State -eq 'Failed' -and $earlier.Error -like '*earlier Keep versions settings*' -and -not $earlier.PSObject.Properties['Retention'] -and (Same @(Saved) $before)) 'a run started with the earlier settings (days and weeks) fails with a plain message: nothing is backed up and nothing is deleted'

 # === The first clean-up after a preview: only what was shown and approved =============================
 # The preview is itself a backup, so the plan of the next run can hold more than was shown. That run gets
 # the list of the versions that were shown and approved and deletes only those; the rest waits for the
 # next clean-up. A repository of its own, so that every count is exact. Keep versions here: the last 2.
 $config.RepositoryFolder='Test-Approved';$config.PasswordDpapiPath=Join-Path $private 'approved-key.dpapi';$config.RecoveryKeyPath=Join-Path $private 'approved-recovery.txt'
 $configPath=Join-Path $private 'approved-settings.json';$config|ConvertTo-Json -Depth 7|Set-Content -LiteralPath $configPath
 $repo=Join-Path $drive $config.RepositoryFolder;$pendingPath=$config.PasswordDpapiPath+'.partial-pending.local.json';$two=@{KeepLast=2;KeepMonths=0}
 Content 'approved: the first version'
 $a0=Run
 foreach($back in 8,7,6,5,4,3){Seed "P-$back" (On $back 10)}
 Seed 'P-other-old' (On 8 12) $folder 'other-computer';Seed 'P-other' (On 7 12) $folder 'other-computer'
 $old=@(8,7,6,5,4,3|ForEach-Object {$ids["P-$_"]})
 Content 'approved: the preview''s version'
 $shown=Run ($two+@{RetentionPreview=$true})
 Assert ($a0.State -eq 'Completed' -and $shown.State -eq 'Completed' -and (Same (Named $shown) $old) -and $shown.Retention.Kept -eq 2 -and $shown.Retention.Approved -eq $false -and $shown.Retention.Deferred -eq 0) 'in a second repository the preview shows 6 versions: all but the last 2'
 # The list as a careless writer might leave it: a byte-order mark, blank lines, spaces and capital letters
 # around the IDs. It also names a version that the rule keeps (the preview's own), an older version of
 # another computer and a version that does not exist: none of them may go.
 $listPath=Join-Path $private 'approved-versions.txt';$i=0
 $lines=@('')+@(Named $shown|ForEach-Object {$i++;if($i % 2){"  $($_.ToUpperInvariant())`t"}else{$_}})+@('   ',$shown.Snapshot,$ids['P-other-old'],('f'*64),'')
 [IO.File]::WriteAllLines($listPath,[string[]]$lines,[Text.UTF8Encoding]::new($true))
 Content 'approved: the version of the first clean-up'
 $before=@(Saved)
 $ok=Run ($two+@{RetentionApprovedFile=$listPath})
 $left=@(Saved)
 Assert ($ok.State -eq 'Completed' -and (@($ok.Retention.PSObject.Properties.Name) -join ',') -ceq $shape -and $ok.Retention.Preview -eq $false -and $ok.Retention.Approved -eq $true -and $null -eq $ok.Retention.Error) 'the first clean-up, given the list of approved versions, runs without an error and says that the list was used'
 Assert ((Same (Named $ok) $old) -and $ok.Retention.Removed -eq 6 -and $ok.Retention.PartialRemoved -eq 0) 'it deletes exactly the 6 versions that were shown, also those listed in capital letters or with spaces around them'
 Assert ($ok.Retention.Deferred -eq 1 -and $a0.Snapshot -in $left -and $ok.Retention.Kept -eq 3) 'the version that this backup pushed out of the last 2 was never shown: it is counted as deferred and is still there'
 Assert (Same $left (@($before|Where-Object {$_ -cnotin $old})+$ok.Snapshot)) 'nothing else is gone: the listed version that the rule keeps and the listed version of another computer are still there'
 $planned=@(Get-Content -LiteralPath (Join-Path $ok.RunDirectory 'clean-up-plan.json') -Raw|ConvertFrom-Json);$waits=@($planned|Where-Object {$_.Id -ceq $a0.Snapshot})[0]
 Assert ($waits.Keep -eq $true -and (@($waits.Reasons) -join ',') -ceq 'OutsideRules,NotApproved' -and @($planned|Where-Object {-not $_.Keep}).Count -eq 6) 'the plan saved with the run says why that version stayed'
 Assert ((Test-Path -LiteralPath (Join-Path $ok.RunDirectory 'FreeingSpace.jsonl')) -and (Test-Path -LiteralPath (Join-Path $ok.RunDirectory 'CheckingAfterCleanUp.jsonl')) -and (Restic @('check')).Code -eq 0) 'space was freed and the repository checks clean afterwards'
 $n1=Run $two
 Assert ($n1.State -eq 'Completed' -and $null -eq $n1.Retention.Error -and $n1.Retention.Approved -eq $false -and $n1.Retention.Deferred -eq 0 -and (Same (Named $n1) @($a0.Snapshot,$shown.Snapshot)) -and $a0.Snapshot -notin @(Saved)) 'the next backup, without a list, follows the rule alone: it deletes the deferred version, and the one it pushed out itself'

 # --- A list that cannot be used: nothing is deleted, and the run says so ---------------------------
 # A partial version that still waits for its mark is in the repository meanwhile; it must be left as it is.
 Seed 'W-pending' (On 5 10)
 [void](Write-BackupStatus @($ids['W-pending']) $pendingPath)
 $missingList=Join-Path $private 'approved-missing.txt';$emptyList=Join-Path $private 'approved-empty.txt';[IO.File]::WriteAllText($emptyList," `r`n`r`n`t`r`n")
 $unused=@()
 foreach($case in @(,@($missingList,'*was not found*'))+@(,@($emptyList,'*is empty*'))){
  $before=@(Saved);$filesBefore=@(Stored)
  $bad=Run ($two+@{RetentionApprovedFile=$case[0]})
  $unused+=$bad.Snapshot
  if($bad.State -ne 'Completed' -or (@($bad.Retention.PSObject.Properties.Name) -join ',') -cne $shape -or $bad.Retention.Approved -ne $false -or $bad.Retention.Error -notlike $case[1] -or $bad.Retention.Error -notlike '*deleted nothing*' -or $bad.Retention.Removed -ne 0 -or $bad.Retention.PartialRemoved -ne 0 -or $bad.Retention.Deferred -ne 0 -or $bad.Retention.Candidates -isnot [array] -or @($bad.Retention.Candidates).Count -ne 0 -or -not (Same @(Saved) ($before+$bad.Snapshot)) -or @($filesBefore|Where-Object {-not(Test-Path -LiteralPath $_)}).Count -or @('MarkingPartial','DeletingOldVersions','FreeingSpace'|Where-Object {Test-Path -LiteralPath (Join-Path $bad.RunDirectory ($_+'.jsonl'))}).Count -or -not(Test-Path -LiteralPath $pendingPath)){throw "FAIL an approved list that cannot be used ($($case[1])): $($bad|ConvertTo-Json -Depth 6 -Compress)"}
 }
 Assert ($unused.Count -eq 2) 'a list of approved versions that is missing or empty never falls back to the whole plan: the backup completes, the clean-up says why it deleted nothing, and no version is deleted or marked although versions are outside the rule'
 $before=@(Saved)
 $shown2=Run ($two+@{RetentionPreview=$true;RetentionApprovedFile=$missingList})
 Assert ($shown2.State -eq 'Completed' -and $shown2.Retention.Preview -eq $true -and $shown2.Retention.Approved -eq $false -and $null -eq $shown2.Retention.Error -and $shown2.Retention.Removed -eq 0 -and $shown2.Retention.Deferred -eq 0 -and (Same @(Saved) ($before+$shown2.Snapshot))) 'together with a preview the list is not used at all: the preview wins and nothing is deleted'
 $waitingShown=@($shown2.Retention.Candidates|Where-Object {$_.Id -ceq $ids['W-pending']})
 Assert ((Same (Named $shown2) @($ok.Snapshot,$n1.Snapshot,$unused[0],$ids['W-pending'])) -and $waitingShown[0].Partial -eq $true) 'this preview shows 4 versions, one of them the partial version that waits for its mark, under the ID it still has'

 # --- A partial version that is marked after the preview has a new ID: deferred, not deleted ---------
 [IO.File]::WriteAllLines($listPath,[string[]]@(Named $shown2))
 $before=@(Saved)
 $ok2=Run ($two+@{RetentionApprovedFile=$listPath})
 $left=@(Saved);$marked=@(Snapshots|Where-Object {(Test-PartialSnapshot $_) -and $_.id -cnotin $before})
 Assert ($ok2.State -eq 'Completed' -and $null -eq $ok2.Retention.Error -and $ok2.Retention.Approved -eq $true -and (Same (Named $ok2) @($ok.Snapshot,$n1.Snapshot,$unused[0])) -and $ok2.Retention.Removed -eq 3 -and $ok2.Retention.PartialRemoved -eq 0) 'the clean-up with the new list deletes the 3 complete versions that were shown'
 Assert ($marked.Count -eq 1 -and $ids['W-pending'] -notin $left -and -not(Test-Path -LiteralPath $pendingPath) -and $marked[0].id -in $left -and $ok2.Retention.Deferred -eq 2 -and $unused[1] -in $left -and $ok2.Retention.Kept -eq 3) 'the waiting partial version was marked first and so has a new ID, which nobody approved: it is deferred like the version this backup pushed out, and both are still there'
 Assert (Same $left (@($before|Where-Object {$_ -cnotin (Named $ok2) -and $_ -cne $ids['W-pending']})+$ok2.Snapshot+$marked[0].id)) 'the repository holds every other version, and the new one'
 $n2=Run $two
 Assert ($n2.State -eq 'Completed' -and $null -eq $n2.Retention.Error -and $n2.Retention.Approved -eq $false -and (Same (Named $n2) @($unused[1],$shown2.Snapshot,$marked[0].id)) -and $n2.Retention.Removed -eq 3 -and $n2.Retention.PartialRemoved -eq 1 -and $n2.Retention.Deferred -eq 0) 'the next backup without a list deletes both deferred versions, the partial one among them, and the one it pushed out itself'
 $before=@(Saved)
 $offListed=Run @{RetentionApprovedFile=$listPath}
 Assert ($offListed.State -eq 'Completed' -and $offListed.Retention.Approved -eq $true -and $null -eq $offListed.Retention.Error -and $offListed.Retention.Removed -eq 0 -and $offListed.Retention.Deferred -eq 0 -and @($offListed.Retention.Candidates).Count -eq 0 -and (Same @(Saved) ($before+$offListed.Snapshot))) 'with the clean-up switched off a list changes nothing: the rule keeps every version, so none is deleted'
 Assert ((Same @(Saved) @($ok2.Snapshot,$n2.Snapshot,$offListed.Snapshot,$ids['P-other-old'],$ids['P-other'])) -and (Restic @('check')).Code -eq 0) 'in the end the repository holds this computer''s last versions and both versions of the other computer, and checks clean'
}finally{
 if(Test-Path -LiteralPath $base){Get-ChildItem -LiteralPath $base -Recurse -Force -File|ForEach-Object {$_.IsReadOnly=$false};Remove-Item -LiteralPath $base -Recurse -Force}
}
Write-Output 'All retention tests passed.'
