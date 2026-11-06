#Requires -Version 7.2
# Automatic clean-up of old versions (Backup.History.psm1): the checks around restic's plan always run;
# with restic in bin\ it also builds a disposable repository with versions dated over 200 days and checks
# what a 7 days / 4 weeks / 3 months rule keeps and deletes. Needs no backup drive.
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'Backup.History.psm1') -Force
function Assert($ok,[string]$message){if(-not $ok){throw "FAIL $message"};Write-Output "PASS $message"}
function Assert-Throws([scriptblock]$Block,[string]$Like,[string]$message){
 try{& $Block;throw "FAIL $message (no error)"}catch{if($_.Exception.Message -like 'FAIL*'){throw};if($_.Exception.Message -notlike $Like){throw "FAIL $message (got: $($_.Exception.Message))"}}
 Write-Output "PASS $message"
}
function Id([int]$n){('{0:x2}' -f $n)*32}
function Snap([int]$n,[string]$time){[pscustomobject]@{id=(Id $n);time=$time;hostname='pc';paths=@('E:\')}}

# --- The rule's arguments ------------------------------------------------------------------------
$a=Get-RetentionArguments 7 4 3
Assert ('--dry-run' -in $a -and ($a -join ' ') -like '*--tag devdrive*' -and ($a -join ' ') -like '*--keep-last 1*') 'the rule is always a dry run, only for this tool''s versions, and keeps the newest'
Assert (($a -join ' ') -like '*--keep-within-daily 7d*--keep-within-weekly 28d*--keep-within-monthly 3m*') '7 days, 4 weeks (28 days) and 3 months, counted from the newest version'
Assert (-not (($(Get-RetentionArguments 0 0 2) -join ' ') -like '*daily*')) 'a line set to 0 is left out'
Assert-Throws {Get-RetentionArguments 0 0 0} '*at least one*' 'all zero is refused (that would keep only the newest version)'
Assert-Throws {Get-RetentionArguments -1 4 3} '*out of range*' 'negative numbers are refused'

# --- Checks on restic's plan ----------------------------------------------------------------------
$all=@((Snap 1 '2026-06-30T12:00:00Z'),(Snap 2 '2026-06-29T12:00:00Z'),(Snap 3 '2026-01-01T12:00:00Z'))
$plan=@([pscustomobject]@{keep=@($all[0],$all[1]);remove=@($all[2])})
$r=@(Get-RetentionRemovals $plan (Id 1) $all)
Assert ($r.Count -eq 1 -and $r[0].id -eq (Id 3)) 'an old version in the plan is returned for deletion'
Assert ((@(Get-RetentionRemovals @([pscustomobject]@{keep=@($all);remove=$null}) (Id 1) $all)).Count -eq 0) 'nothing to delete returns nothing'
Assert-Throws {Get-RetentionRemovals @([pscustomobject]@{keep=@($all[1]);remove=@($all[0],$all[2])}) (Id 1) $all} '*just made*' 'a plan that would delete the version just made is refused'
Assert-Throws {Get-RetentionRemovals @([pscustomobject]@{keep=@();remove=@($all)}) $null $all} '*every version*' 'a plan that would empty a folder set is refused'
Assert-Throws {Get-RetentionRemovals @([pscustomobject]@{keep=@($all[1],$all[2]);remove=@($all[0])}) (Id 2) $all} '*protected*' 'the newest version stays protected even if the plan says otherwise'

# --- Real restic, disposable repository ---------------------------------------------------------
$engine=Join-Path $PSScriptRoot 'bin\restic_0.19.1_windows_amd64.exe'
if(-not(Test-Path -LiteralPath $engine)){Write-Output 'SKIP real restic run: bin\restic_0.19.1_windows_amd64.exe is not installed (Install-BackupEngine.ps1)';Write-Output 'All retention tests passed.';return}
$root=Join-Path ([IO.Path]::GetTempPath()) ('backup-retention-test-'+[guid]::NewGuid().ToString('N').Substring(0,10))
$repo=Join-Path $root 'repo';$src=Join-Path $root 'src';$cache=Join-Path $root 'cache'
New-Item -ItemType Directory -Path $src,$cache -Force|Out-Null
$env:RESTIC_PASSWORD='retention-test-'+[guid]::NewGuid().ToString('N')
function Invoke-Restic([string[]]$Arguments){$o=& $engine -r $repo --cache-dir $cache @Arguments 2>&1;if($LASTEXITCODE -ne 0){throw "restic $($Arguments[0]) failed: $o"};$o}
try{
 [void](Invoke-Restic @('init'))
 # Days before the newest version: every day for two weeks, then thinning out to 200 days.
 $newest=[datetime]'2026-06-30 12:00:00'
 $ages=@(0..13)+@(20,27,34,41,60,75,120,200)
 $ids=@{}
 foreach($d in @($ages|Sort-Object -Descending)){
  [IO.File]::WriteAllText((Join-Path $src 'file.txt'),"version from $d days before")
  $out=Invoke-Restic @('backup','--json','--host','pc','--tag','devdrive','--time',$newest.AddDays(-$d).ToString('yyyy-MM-dd HH:mm:ss'),$src)
  $sum=@($out|ForEach-Object {try{[string]$_|ConvertFrom-Json}catch{}}|Where-Object {$_ -and $_.message_type -eq 'summary'})[0]
  $ids[$d]=$sum.snapshot_id
 }
 # Another program's version (no devdrive tag) must never be touched.
 [void](Invoke-Restic @('backup','--json','--host','pc','--time',$newest.AddDays(-300).ToString('yyyy-MM-dd HH:mm:ss'),$src))
 $planJson=(Invoke-Restic ((Get-RetentionArguments 7 4 3)+'--json'))|Where-Object {"$_".StartsWith('[')}|Select-Object -First 1
 $plan=@($planJson|ConvertFrom-Json)
 $snapshots=@((Invoke-Restic @('snapshots','--json','--tag','devdrive'))|Where-Object {"$_".StartsWith('[')}|Select-Object -First 1|ConvertFrom-Json)
 $remove=@(Get-RetentionRemovals $plan $ids[0] $snapshots)
 $gone=@($remove|ForEach-Object {$_.id})
 $keptAges=@($ages|Where-Object {$ids[$_] -notin $gone})
 Write-Output ("  kept, days before the newest: "+(($keptAges|Sort-Object) -join ', '))
 Assert (@(0..6|Where-Object {$ids[$_] -in $gone}).Count -eq 0) 'every daily version of the last 7 days is kept'
 Assert (@(8..13|Where-Object {$ids[$_] -in $gone}).Count -ge 3) 'older daily versions thin out to one a week'
 Assert ($ids[20] -notin $gone -and $ids[27] -notin $gone) 'one version a week is kept for the last 4 weeks'
 # 34 days before is 27 May, 41 is 20 May, 60 is 1 May, 75 is 16 April: the latest of each month stays.
 Assert ($ids[34] -notin $gone -and $ids[75] -notin $gone -and $ids[41] -in $gone -and $ids[60] -in $gone) 'one version a month (the latest in it) is kept for the last 3 months'
 Assert ($ids[120] -in $gone -and $ids[200] -in $gone) 'versions older than 3 months are deleted'
 [void](Invoke-Restic (@('forget')+$gone+'--prune'))
 [void](Invoke-Restic @('check'))
 $left=@((Invoke-Restic @('snapshots','--json'))|Where-Object {"$_".StartsWith('[')}|Select-Object -First 1|ConvertFrom-Json)
 Assert ($left.Count -eq ($keptAges.Count+1) -and @($left|Where-Object {-not $_.tags}).Count -eq 1) 'after deleting and freeing space the repository checks clean, and the untagged version is untouched'
 # Read the file straight out of the newest version (a restore would recreate the folder permissions too).
 $inside='/'+$src.Replace(':','').Replace('\','/')+'/file.txt'
 Assert ((@(Invoke-Restic @('dump',$ids[0],$inside)) -join '') -eq 'version from 0 days before') 'the newest version still reads back intact'
}finally{
 Remove-Item Env:\RESTIC_PASSWORD -ErrorAction SilentlyContinue
 if(Test-Path -LiteralPath $root){Get-ChildItem -LiteralPath $root -Recurse -Force -File|ForEach-Object {$_.IsReadOnly=$false};Remove-Item -LiteralPath $root -Recurse -Force}
}
Write-Output 'All retention tests passed.'
