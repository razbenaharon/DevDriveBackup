#Requires -Version 7.2
# The plain copy (Invoke-FastMirror.ps1) without a backup drive: its rules as functions of
# Backup.Selection.psm1 (robocopy totals and exit codes, log names, clean-up of recovery folders, name
# comparison, Exclude patterns, the same-disk rule) and whole runs through the script's -TestRoot, which
# copies into a disposable folder below the temporary folder instead of onto a drive. Nothing outside
# that folder is written; it is removed at the end. -KeepGoing reports every failing check instead of
# stopping at the first.
param([switch]$KeepGoing)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'Backup.Selection.psm1') -Force
$tool=Join-Path $PSScriptRoot 'Invoke-FastMirror.ps1'
$script:failed=0
function Assert($ok,$message){if(-not $ok){if($KeepGoing){$script:failed++;Write-Output ('FAIL '+$message);return};throw "FAIL $message"};Write-Output ('PASS '+$message)}
function Section([string]$Name,[scriptblock]$Body){try{& $Body}catch{if(-not $KeepGoing){throw};$script:failed++;Write-Output ("FAIL $Name stopped: "+($_.Exception.Message -replace '\s+',' '))}}
function Throws([scriptblock]$Block,[string]$Pattern){try{& $Block|Out-Null;$false}catch{$_.Exception.Message -match $Pattern}}
$root=Join-Path ([IO.Path]::GetTempPath()) ('dev-drive-backup-mirror-'+[guid]::NewGuid().ToString('N'))
# \\?\ keeps a name that ends in a dot as it is written.
function Put([string]$Path,[string]$Text){[IO.Directory]::CreateDirectory('\\?\'+[IO.Path]::GetDirectoryName($Path))|Out-Null;[IO.File]::WriteAllText('\\?\'+$Path,$Text)}
function New-Case([string]$Name,$Files,[hashtable]$Config){
 $c=Join-Path $root $Name;$s=Join-Path $c 'source'
 foreach($k in $Files.Keys){Put ($s+'\'+$k) $Files[$k]}
 [pscustomobject]@{Root=$c;Source=$s;Copy=(Join-Path $c 'Copy');Recovery=(Join-Path $c 'Copy-recovery');Job=(Join-Path $c 'job.json');Success=(Join-Path $c 'state\last-success-test-Copy.json');Config=$Config}
}
function Mirror($Case,[hashtable]$Extra=@{}){
 $job=[ordered]@{Source=$Case.Source+'\'};foreach($k in $Case.Config.Keys){$job[$k]=$Case.Config[$k]}
 [IO.File]::WriteAllText($Case.Job,($job|ConvertTo-Json -Depth 8))
 $out=& $tool -ConfigPath $Case.Job -DestinationDrive Z -Folder Copy -TestRoot $Case.Root -Threads 4 @Extra
 ($out -join "`n")|ConvertFrom-Json
}
function InCopy($Case,[string]$Rel){[IO.File]::Exists('\\?\'+$Case.Copy+'\'+$Rel)}
function Files([string]$Folder){if(-not(Test-Path -LiteralPath $Folder)){return @()};$f=[string[]]@(Get-ChildItem -LiteralPath $Folder -Recurse -File -Force|ForEach-Object {$_.FullName.Substring($Folder.Length+1)});[Array]::Sort($f,[StringComparer]::Ordinal);$f}
$rlm=[string][char]0x200F;$zw=[string][char]0x200B   # a right-to-left mark and a zero-width space: invisible in a name

try{
 [IO.Directory]::CreateDirectory($root)|Out-Null

 # --- robocopy totals and exit codes ------------------------------------------------------
 Section 'totals and exit codes' {
  $totals="`r`n               Total    Copied   Skipped  Mismatch    FAILED    Extras`r`n    {3} :         5         4         1         {0}         0         0`r`n   {4} :         9         7         0         {1}         {2}         0`r`n   Bytes :       260       200         0        25        35         0`r`n   Times :   0:00:00   0:00:00                       0:00:00   0:00:00`r`n   Ended : Thursday`r`n"
  $log={param($name,$text)$p=Join-Path $root $name;[IO.File]::WriteAllText($p,$text,[Text.Encoding]::Unicode);$p}
  $clean=& $log 'clean.log' ("header`r`n"+($totals -f 0,0,0,'Dirs','Files'))
  $cut=& $log 'cut.log' "header`r`n`t    New File  `t`t   3`tC:\x\a.txt`r`n"
  $mixed=& $log 'mixed.log' ("header`r`n"+($totals -f 1,1,2,'Dirs','Files'))
  $other=& $log 'other.log' ("header`r`n"+($totals -f 0,0,3,'Verzeich.','Dateien'))
  $r=Get-RoboRunResult $clean 1
  Assert ($r.NotCopied -eq 0 -and $r.Complete -and ($r.Totals.Files -join ' ') -eq '9 7 0 0 0 0') 'a finished run with clean totals has nothing left uncopied'
  foreach($code in 0,1,3,7,-1,-1073741510){$r=Get-RoboRunResult $cut $code;Assert ($r.NotCopied -ge 1 -and -not $r.Complete) "a robocopy log without totals is a failed run (exit code $code)"}
  $r=Get-RoboRunResult $clean 8
  Assert ($r.NotCopied -ge 1 -and -not $r.Complete) 'exit code 8 never ends as nothing uncopied, even when the log read has clean totals'
  Assert ((Get-RoboRunResult $clean 4).NotCopied -ge 1) 'the mismatch exit code counts even with clean totals'
  $r=Get-RoboRunResult $mixed 12
  Assert ($r.NotCopied -eq 4 -and -not $r.Complete) 'mismatched and failed files and folders are added up'
  Assert ((Get-RoboRunResult $mixed 4).Complete) 'a run with only a file-or-folder mismatch still read the whole source'
  Assert ((Get-RoboRunResult $other 8).NotCopied -eq 3) 'totals are read in another Windows language'
 }

 # --- log names ----------------------------------------------------------------------------
 Section 'log names' {
  $used=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
  $names=@('','a\b','a_b','A_B','main'|ForEach-Object {Get-MirrorLogName $_ $used})
  Assert ($names[0] -eq 'copy-main.log' -and $names[1] -eq 'copy-a_b.log') 'log names stay as they were when nothing collides'
  Assert (@($names|ForEach-Object {$_.ToLowerInvariant()}|Sort-Object -Unique).Count -eq 5) ('selected folders whose names turn into the same file name get separate logs ('+($names -join ', ')+')')
 }

 # --- which recovery folders the clean-up deletes -------------------------------------------
 Section 'recovery clean-up rule' {
  $old='20200101-000000';$mid='20260101-000000';$later='20991231-235959';$own='20261112-120000'
  $del={param($names,$keep,$mine)(@(Get-RecoveryFoldersToRemove $names $keep $mine|Sort-Object) -join '|')}
  Assert ((& $del @($old,$mid,$later) 2 '') -eq $old) 'the newest folders by name are kept'
  Assert ((& $del @($old,$mid,$later,$own) 1 $own) -eq "$old|$mid|$later") "the folder this run made is kept even when another folder's name is later"
  Assert ((& $del @($old,$mid,$later,$own) 2 $own) -eq "$old|$mid") 'the folder this run made counts as one of the kept'
  Assert ((& $del @($old,$mid) 5 $own) -eq '' -and (& $del @($old,$mid,$later) 0 '') -eq '') 'nothing is deleted below the limit, or with no limit'
 }

 # --- names are compared as Windows compares them --------------------------------------------
 Section 'name comparison' {
  $choice={param($p,$m)[pscustomobject]@{Path=$p;Mode=$m}}
  $one=Get-BackupSelection ([pscustomobject]@{DefaultMode='Mirror';Choices=@((& $choice 'data' 'Skip'))})
  Assert ((Get-BackupMode $one 'DATA\x') -eq 'Skip') 'folder names are still compared in any case'
  Assert ((Get-BackupMode $one ('data'+$rlm)) -eq 'Mirror') 'a folder whose name differs by an invisible mark is another folder'
  Assert ((Get-BackupMode $one $zw) -eq 'Mirror' -and (Get-BackupMode $one ($zw+'\in.txt')) -eq 'Mirror') 'a name made only of an invisible character is a name, not an empty path part'
  $nfc='caf'+[char]0xE9;$nfd='cafe'+[char]0x301
  $acc=Get-BackupSelection ([pscustomobject]@{DefaultMode='Mirror';Choices=@((& $choice $nfc 'Skip'))})
  Assert ((Get-BackupMode $acc $nfc) -eq 'Skip' -and (Get-BackupMode $acc $nfd) -eq 'Mirror') 'two spellings of an accented name that Windows keeps apart are kept apart'
  $two=Get-BackupSelection ([pscustomobject]@{DefaultMode='Mirror';NeverBackUp=@('data');Choices=@((& $choice 'data' 'Skip'),(& $choice ('data'+$rlm) 'Both'))})
  Assert ((Get-BackupMode $two 'data') -eq 'Skip' -and (Get-BackupMode $two ('data'+$rlm)) -eq 'Both') 'two such folders can both be listed, also beside a NeverBackUp folder'
  Assert (Throws {Get-BackupSelection ([pscustomobject]@{DefaultMode='Mirror';Choices=@((& $choice 'data' 'Skip'),(& $choice 'DATA' 'Both'))})} 'twice') 'the same folder in another case is still refused as listed twice'
  Assert (Throws {ConvertTo-SelectionPath 'a\.\b'} 'relative') 'a path part that is a dot is still refused'
 }

 # --- Exclude paths with wildcards -----------------------------------------------------------
 Section 'Exclude path patterns' {
  $t=Join-Path $root 'patterns'
  foreach($f in 'app1\dist\o.js','app2\dist\o.js','app1\src\a.js','app1\src\b.tmp','deep\x\y\dist\z.js','br [x]\dist\q.js','logs\a.log','logs\b.txt'){Put ($t+'\'+$f) $f}
  $find={param($p)(@(Resolve-BackupExcludePath ($t+'\') $p|Sort-Object) -join '|')}
  Assert ((& $find '*\dist') -eq 'app1\dist|app2\dist|br [x]\dist') 'a star stands for one folder name'
  Assert ((& $find 'app?\src\*.tmp') -eq 'app1\src\b.tmp' -and (& $find 'logs\*.log') -eq 'logs\a.log') 'a pattern can end in a file name'
  Assert ((& $find 'deep\**\dist') -eq 'deep\x\y\dist' -and (& $find '**\y\dist') -eq 'deep\x\y\dist') 'two stars stand for any number of folders'
  Assert ((& $find 'br [[]x]\dist') -eq '' -and (& $find 'nothing\*\here') -eq '') 'square brackets are plain characters, and no match is no path'
 }

 # --- the same-disk rule -----------------------------------------------------------------------
 Section 'same-disk rule' {
  $disk={param($n,$bus,$where)[pscustomobject]@{Number=$n;BusType=$bus;Location=$where}}
  $disks=@{C=(& $disk 0 'NVMe' 'PCI Slot 1');G=(& $disk 2 'USB' 'USB port');E=(& $disk 1 'File Backed Virtual' 'C:\dev\drive.vhdx')
   V=(& $disk 5 'File Backed Virtual' 'E:\nested.vhdx');W=(& $disk 6 'File Backed Virtual' 'G:\backup.vhdx')}
  $of={param($letter)$disks[[string]$letter]}
  $why={param($s,$d)[string](Get-BackupSameDiskReason $disks[$s] $disks[$d] $of)}
  Assert (-not (& $why 'C' 'G') -and -not (& $why 'E' 'G') -and -not (& $why 'C' 'W') -and -not (& $why 'E' 'W')) 'separate physical disks are accepted, virtual or not'
  Assert ((& $why 'C' 'C') -match 'same physical disk') 'the source disk itself is refused'
  Assert ((& $why 'E' 'C') -match 'Dev Drive file') 'the disk that holds the Dev Drive file is refused'
  Assert ((& $why 'C' 'E') -match 'virtual disk') 'a virtual disk whose file is on the source disk is refused'
  Assert ((& $why 'C' 'V') -match 'virtual disk' -and (& $why 'E' 'V') -match 'virtual disk') 'also through a virtual disk inside a virtual disk'
 }

 # --- names on the always-skipped list ---------------------------------------------------------
 Section 'skipped names' {
  Assert ((Get-BackupSkippedName 'tools\venv\keep' @('venv','pytest-of-*') @() $true) -eq 'venv' -and (Get-BackupSkippedName 'pytest-of-me' @('venv','pytest-of-*') @() $true) -eq 'pytest-of-me') 'a folder name on the list is found anywhere along a path, wildcards included'
  Assert ((Get-BackupSkippedName 'docs\secret.key' @('venv') @('*.key') $false) -eq 'secret.key' -and -not (Get-BackupSkippedName 'docs\venv' @('venv') @() $false)) 'file names are checked against the personal names only'
  Assert (-not (Get-BackupSkippedName 'src\app\environment' @('venv','.next') @('*.key') $true)) 'other names are not skipped'
 }

 # --- whole runs -------------------------------------------------------------------------------
 Section 'test folder rule' {
  $c=New-Case 'seam' @{'keep\a.txt'='a'} @{DefaultMode='Mirror';Choices=@()}
  [void](Mirror $c)
  Assert (Throws {& $tool -ConfigPath $c.Job -DestinationDrive Z -Folder Copy -TestRoot (Join-Path $PSScriptRoot 'not-below-temp')} 'temporary folder') '-TestRoot is refused outside the temporary folder'
  Assert (-not(Test-Path -LiteralPath (Join-Path $PSScriptRoot 'not-below-temp'))) 'and nothing was created there'
  [IO.Directory]::CreateDirectory((Join-Path $root 'elsewhere'))|Out-Null
  New-Item -ItemType Junction -Path (Join-Path $root 'link') -Target (Join-Path $root 'elsewhere')|Out-Null
  Assert (Throws {& $tool -ConfigPath $c.Job -DestinationDrive Z -Folder Copy -TestRoot (Join-Path $root 'link\case')} 'link') '-TestRoot is refused when a link on the way could lead out of the temporary folder'
  Assert (@(Get-ChildItem -LiteralPath (Join-Path $root 'elsewhere') -Force).Count -eq 0) 'and nothing was created behind the link'
  # A link standing where the copy itself is written leads out just the same.
  $inner=Join-Path $root 'inner';[IO.Directory]::CreateDirectory($inner)|Out-Null
  New-Item -ItemType Junction -Path (Join-Path $inner 'Copy') -Target (Join-Path $root 'elsewhere')|Out-Null
  Assert (Throws {& $tool -ConfigPath $c.Job -DestinationDrive Z -Folder Copy -TestRoot $inner} 'link') '-TestRoot is refused when the copy folder inside it is a link'
  Assert (@(Get-ChildItem -LiteralPath (Join-Path $root 'elsewhere') -Force).Count -eq 0) 'and nothing was copied through it'
  [IO.Directory]::Delete((Join-Path $inner 'Copy'))   # the junction only
 }

 Section 'copy, check, deleted files' {
  $c=New-Case 'base' ([ordered]@{'both\a.txt'='a';'both\gone.txt'='deleted later';'both\inner [skip]\f.txt'='skipped';'both\inner [skip]\keep\k.txt'='kept';'both\node_modules\x.js'='cache'
   'skipped\d.txt'='d';'skipped\evidence\e.txt'='e';'unlisted\g.txt'='g';'credentials\secret.txt'='never';'note.md'='single file';'empty.bin'='';'עברית\ש.txt'='hebrew';'old\one.txt'='1';'old\sub\two.txt'='2'}) @{
   DefaultMode='Mirror';NeverBackUp=@('credentials');Exclude=@('node_modules');Choices=@(@{Path='both';Mode='Both'},@{Path='both\inner [skip]';Mode='Skip'},@{Path='both\inner [skip]\keep';Mode='Both'},@{Path='skipped';Mode='Skip'},@{Path='skipped\evidence';Mode='Both'},@{Path='note.md';Mode='Versioned'})}
  $r=Mirror $c
  Assert ($r.CopyErrors -eq 0 -and $r.Verify.Differences -eq 0 -and $r.Verify.FilesMatched -eq 9 -and (Test-Path -LiteralPath $c.Success)) 'the first copy is checked in full and recorded as complete'
  Assert (((Files $c.Copy) -join '|') -eq 'both\a.txt|both\gone.txt|both\inner [skip]\keep\k.txt|empty.bin|old\one.txt|old\sub\two.txt|skipped\evidence\e.txt|unlisted\g.txt|עברית\ש.txt') 'only the selected files are in the copy'
  [IO.File]::Delete((Join-Path $c.Source 'both\gone.txt'));[IO.Directory]::Delete((Join-Path $c.Source 'old'),$true)
  $r=Mirror $c @{MoveExtras=$true;Verify=$true}
  Assert ($r.ExtrasFound -eq 3 -and $r.ExtrasMoved -eq 3 -and @($r.ExtrasNotMoved).Count -eq 0) 'files gone from the source are counted as files, a deleted folder by its files'
  Assert (((Files $r.ExtrasMovedTo) -join '|') -eq 'both\gone.txt|old\one.txt|old\sub\two.txt' -and -not(Test-Path -LiteralPath (Join-Path $c.Copy 'old')) -and (InCopy $c 'both\a.txt')) 'they are moved to the recovery folder, and nothing else is'
  Assert ($r.Verify.Differences -eq 0 -and $r.Verify.FilesMatched -eq 6) 'the copy still matches the source'
 }

 Section 'old copy of a skipped folder inside a deleted folder' {
  $c=New-Case 'skipped-inside' @{'keep\a.txt'='a';'old\one.txt'='1';'old\sub\two.txt'='2';'old\private\p.txt'='stops being copied'} @{DefaultMode='Mirror';Choices=@()}
  [void](Mirror $c)
  $c.Config=@{DefaultMode='Mirror';Choices=@(@{Path='old\private';Mode='Skip'})}
  [IO.Directory]::Delete((Join-Path $c.Source 'old'),$true)
  $r=Mirror $c @{MoveExtras=$true}
  Assert ((InCopy $c 'old\private\p.txt') -and ((Files $c.Recovery) -join '|') -notmatch 'private') 'the old copy of a folder that is no longer selected stays in the copy when its parent folder is deleted from the source'
  Assert ($r.ExtrasFound -eq 2 -and $r.ExtrasMoved -eq 2 -and ((Files $r.ExtrasMovedTo) -join '|') -eq 'old\one.txt|old\sub\two.txt') 'the selected files of that folder are still moved aside'
 }

 Section 'two selected folders, one log name' {
  $c=New-Case 'logs' @{'a\b\db.bin'='v1';'a\b\ok.txt'='ok';'a_b\fine.txt'='fine'} @{DefaultMode='Skip';Choices=@(@{Path='a\b';Mode='Mirror'},@{Path='a_b';Mode='Mirror'})}
  $r=Mirror $c
  Assert ($r.CopyErrors -eq 0 -and $r.Verify.Differences -eq 0) 'both folders are copied'
  $before=(Get-FileHash -LiteralPath $c.Success).Hash
  [IO.File]::WriteAllText((Join-Path $c.Source 'a\b\db.bin'),'v2, changed and held open by another program')
  $hold=[IO.File]::Open((Join-Path $c.Source 'a\b\db.bin'),'Open','ReadWrite','None')
  try{$r=Mirror $c}finally{$hold.Dispose()}
  Assert (@($r.Runs|ForEach-Object {$_.Log}|Sort-Object -Unique).Count -eq 2) 'each selected folder has its own log'
  Assert ($r.CopyErrors -ge 1) 'a file that could not be copied is counted, whatever the other folder reports'
  Assert ((Get-FileHash -LiteralPath $c.Success).Hash -eq $before) 'and the run is not recorded as a complete copy'
 }

 Section 'clean-up of recovery folders' {
  $c=New-Case 'prune' @{'keep\a.txt'='a';'keep\gone.txt'='the only copy left'} @{DefaultMode='Mirror';Choices=@()}
  [void](Mirror $c)
  Put (Join-Path $c.Recovery '20200101-000000\old.txt') 'old';Put (Join-Path $c.Recovery '20991231-235959\later.txt') 'named later than now';Put (Join-Path $c.Recovery 'my-notes\n.txt') 'not ours'
  [IO.File]::Delete((Join-Path $c.Source 'keep\gone.txt'))
  $r=Mirror $c @{MoveExtras=$true;KeepRecovery=1}
  Assert (Test-Path -LiteralPath (Join-Path $r.ExtrasMovedTo 'keep\gone.txt')) 'the recovery folder made in this run is not deleted by its own clean-up'
  $dated=@(Get-ChildItem -LiteralPath $c.Recovery -Directory|Where-Object Name -match '^\d{8}-\d{6}$')
  Assert ($dated.Count -eq 1 -and $dated[0].FullName -eq $r.ExtrasMovedTo -and @($r.RecoveryRemoved).Count -eq 2 -and (Test-Path -LiteralPath (Join-Path $c.Recovery 'my-notes\n.txt'))) 'it is the one kept; older folders go, other folders are left alone'
 }

 Section 'file and folder that swapped kinds' {
  $c=New-Case 'swap' @{'ok\a.txt'='a';'swap\x'='x is a file';'swap2\y\inner.txt'='y is a folder';'swap2\y\deep\d.txt'='d'} @{DefaultMode='Mirror';Choices=@()}
  [void](Mirror $c)
  $before=(Get-FileHash -LiteralPath $c.Success).Hash
  [IO.File]::Delete((Join-Path $c.Source 'swap\x'));Put (Join-Path $c.Source 'swap\x\new.txt') 'x is now a folder'
  [IO.Directory]::Delete((Join-Path $c.Source 'swap2\y'),$true);Put (Join-Path $c.Source 'swap2\y') 'y is now a file'
  $r=Mirror $c @{VerifyOnly=$true}
  Assert ($r.Verify.Differences -eq 2 -and @($r.TypeSwapsHealed).Count -eq 0 -and (InCopy $c 'swap\x') -and (InCopy $c 'swap2\y\inner.txt') -and -not(Test-Path -LiteralPath $c.Recovery)) 'a content check reports the two as differences and moves nothing'
  $r=Mirror $c @{Verify=$true}
  Assert ($r.CopyErrors -eq 0 -and @($r.TypeConflicts).Count -eq 0 -and (InCopy $c 'swap\x\new.txt') -and (InCopy $c 'swap2\y')) 'a backup copies the new folder and the new file in the same run, without -MoveExtras'
  Assert ((@($r.TypeSwapsHealed|ForEach-Object {$_.Source}|Sort-Object) -join '|') -eq ((Join-Path $c.Source 'swap\x')+'|'+(Join-Path $c.Source 'swap2\y'))) 'the summary names both'
  $to=@{};foreach($h in $r.TypeSwapsHealed){$to[$h.Copy.Substring($c.Copy.Length+1)]=$h.MovedTo}
  Assert ($to['swap\x'] -eq (Join-Path $r.RecoveryFolder 'swap\x') -and [IO.Path]::GetDirectoryName($r.RecoveryFolder) -eq $c.Recovery -and [IO.Path]::GetFileName($r.RecoveryFolder) -match '^\d{8}-\d{6}$') 'the old items went to the dated recovery folder of this run, under their own paths'
  Assert ([IO.File]::ReadAllText($to['swap\x']) -eq 'x is a file' -and ((Files $to['swap2\y']) -join '|') -eq 'deep\d.txt|inner.txt') 'and nothing of them is lost'
  Assert ($r.Verify.Differences -eq 0 -and $r.Verify.FilesMatched -eq 3 -and (Get-FileHash -LiteralPath $c.Success).Hash -ne $before) 'the copy matches the source again and the run counts as a complete backup'
  Assert (@($r.Runs).Count -eq 2 -and @($r.Runs|Where-Object {$_.Repeated}).Count -eq 1 -and $r.Runs[0].Repeated -and $r.Runs[1].NotCopied -eq 0 -and $r.Runs[0].Log -ne $r.Runs[1].Log) 'the folder was copied a second time after healing, and that run tells what is left uncopied'
  # Together with -MoveExtras: one recovery folder for the run.
  [IO.File]::Delete((Join-Path $c.Source 'swap\x\new.txt'));[IO.Directory]::Delete((Join-Path $c.Source 'swap\x'));Put (Join-Path $c.Source 'swap\x') 'x is a file again';[IO.File]::Delete((Join-Path $c.Source 'ok\a.txt'))
  $r=Mirror $c @{MoveExtras=$true;Verify=$true}
  Assert ($r.CopyErrors -eq 0 -and @($r.TypeSwapsHealed).Count -eq 1 -and $r.ExtrasMoved -eq 1 -and $r.ExtrasMovedTo -eq $r.RecoveryFolder -and ((Files $r.RecoveryFolder) -join '|') -eq 'ok\a.txt|swap\x\new.txt' -and $r.Verify.Differences -eq 0) 'with -MoveExtras the healed item and the files gone from the source share the recovery folder of the run'
  # The same at a selected folder or file itself.
  $c=New-Case 'swap-root' @{'note.md'='n';'dir\f.txt'='f';'keep\a.txt'='a'} @{DefaultMode='Skip';Choices=@(@{Path='note.md';Mode='Mirror'},@{Path='dir';Mode='Mirror'},@{Path='keep';Mode='Mirror'})}
  [IO.Directory]::CreateDirectory((Join-Path $c.Copy 'note.md\old'))|Out-Null;Put (Join-Path $c.Copy 'dir') 'a file where the selected folder belongs'
  $r=Mirror $c
  Assert ($r.CopyErrors -eq 0 -and @($r.TypeSwapsHealed).Count -eq 2 -and @($r.TypeConflicts).Count -eq 0 -and (InCopy $c 'note.md') -and (InCopy $c 'dir\f.txt') -and (InCopy $c 'keep\a.txt') -and $r.Verify.Differences -eq 0) 'a selected folder or file whose place in the copy is taken by the other kind is healed the same way'
  Assert ([IO.File]::ReadAllText((Join-Path $r.RecoveryFolder 'dir')) -eq 'a file where the selected folder belongs' -and (Test-Path -LiteralPath (Join-Path $r.RecoveryFolder 'note.md\old') -PathType Container)) 'and the old items are in the recovery folder'
  # An old item that cannot be moved (another program holds it open) is reported as before.
  $c=New-Case 'swap-held' @{'s\x\new.txt'='a folder now';'keep\a.txt'='a'} @{DefaultMode='Mirror';Choices=@()}
  Put (Join-Path $c.Copy 's\x') 'the old file'
  $hold=[IO.File]::Open((Join-Path $c.Copy 's\x'),'Open','Read','None')
  try{$r=Mirror $c @{SkipVerify=$true}}finally{$hold.Dispose()}
  $text=[IO.File]::ReadAllText((Join-Path $r.RunFolder 'copy-errors.txt'))
  Assert ($r.CopyErrors -ge 1 -and @($r.TypeSwapsHealed).Count -eq 0 -and (@($r.TypeConflicts) -join '|') -eq (Join-Path $c.Copy 's\x') -and $text.Contains((Join-Path $c.Copy 's\x')) -and $text.Contains((Join-Path $c.Source 's\x'))) 'an old item that cannot be moved stays a counted error, named with both paths'
  Assert ((InCopy $c 's\x') -and (InCopy $c 'keep\a.txt') -and -not $r.RecoveryFolder -and @(Get-ChildItem -LiteralPath $c.Recovery -Directory -ErrorAction SilentlyContinue).Count -eq 0 -and -not(Test-Path -LiteralPath $c.Success)) 'it stays in the copy, the rest is copied, no empty recovery folder is left and the run is not complete'
  $r=Mirror $c @{SkipVerify=$true}
  Assert ($r.CopyErrors -eq 0 -and @($r.TypeSwapsHealed).Count -eq 1 -and (InCopy $c 's\x\new.txt') -and (Test-Path -LiteralPath $c.Success)) 'the next run heals it'
  # A folder in the copy that holds the old copy of a folder no longer selected is kept where it is.
  $c=New-Case 'swap-kept' @{'p\x'='a file now';'keep\a.txt'='a'} @{DefaultMode='Mirror';Choices=@(@{Path='p\x\private';Mode='Skip'})}
  Put (Join-Path $c.Copy 'p\x\private\old.txt') 'old copy of a folder that is no longer selected'
  $r=Mirror $c @{SkipVerify=$true}
  Assert ($r.CopyErrors -ge 1 -and @($r.TypeSwapsHealed).Count -eq 0 -and (InCopy $c 'p\x\private\old.txt') -and (@($r.TypeConflicts) -join '|') -eq (Join-Path $c.Copy 'p\x')) 'a folder in the copy that holds the old copy of a folder no longer selected is not moved, and is named as before'
 }

 Section 'moving a swapped item aside' {
  $t=Join-Path $root 'move-rule';$s=Join-Path $t 'source';$m=Join-Path $t 'copy';$rec=Join-Path $t 'rec'
  Put "$s\a\in.txt" 'folder';Put "$m\a" 'file';Put "$m\gone" 'file';Put "$s\same" 's';Put "$m\same" 'm';Put "$s\b" 'file';Put "$m\b\in.txt" 'folder';Put "$m\link" 'file'
  New-Item -ItemType Junction -Path "$s\link" -Target "$s\a"|Out-Null
  Assert (-not(Move-BackupTypeSwap "$s\gone" "$m\gone" "$rec\gone") -and (Test-Path -LiteralPath "$m\gone") -and -not(Test-Path -LiteralPath $rec)) 'nothing is moved when the source item no longer exists'
  Assert (-not(Move-BackupTypeSwap "$s\same" "$m\same" "$rec\same") -and (Test-Path -LiteralPath "$m\same")) 'nor when both are the same kind'
  Assert (-not(Move-BackupTypeSwap "$s\link" "$m\link" "$rec\link") -and (Test-Path -LiteralPath "$m\link")) 'nor when the source item is a link'
  Assert ((Move-BackupTypeSwap "$s\a" "$m\a" "$rec\a") -and [IO.File]::ReadAllText("$rec\a") -eq 'file' -and -not(Test-Path -LiteralPath "$m\a")) 'a file in the way of a folder is moved'
  Assert ((Move-BackupTypeSwap "$s\b" "$m\b" "$rec\deep\b") -and (Test-Path -LiteralPath "$rec\deep\b\in.txt") -and -not(Test-Path -LiteralPath "$m\b")) 'a folder in the way of a file is moved whole'
  # What lies behind a link is not part of the source or of the copy: nothing is moved from there.
  [IO.Directory]::CreateDirectory("$t\elsewhere\sub")|Out-Null;New-Item -ItemType Junction -Path "$m\j" -Target "$t\elsewhere"|Out-Null
  Assert ((Test-BackupLinkOnPath $m 'j\sub\x') -and (Test-BackupLinkOnPath $m 'j\x') -and (Test-BackupLinkOnPath ($s+'\') 'link\in.txt')) 'a link or junction on the way to an item is found'
  Assert (-not(Test-BackupLinkOnPath $m 'j') -and -not(Test-BackupLinkOnPath $s 'a\in.txt') -and -not(Test-BackupLinkOnPath $s 'x')) 'the item itself and ordinary folders are not'
  # A source folder that keeps letter case apart holds a file and a folder of one name: the copy can
  # hold only one of them, so neither is moved out of the way of the other.
  [IO.Directory]::CreateDirectory("$s\cs")|Out-Null;& fsutil.exe file setCaseSensitiveInfo "$s\cs" enable 2>&1|Out-Null
  $made=$LASTEXITCODE -eq 0
  if($made){try{[IO.File]::WriteAllText("$s\cs\Both",'file');[IO.Directory]::CreateDirectory("$s\cs\both")|Out-Null;$made=@(Get-ChildItem -LiteralPath "$s\cs" -Force).Count -eq 2}catch{$made=$false}}
  if($made){
   Put "$m\cs\Both" 'the copy holds the file'
   Assert (-not(Move-BackupTypeSwap "$s\cs\both" "$m\cs\both" "$rec\cs\both") -and (Test-Path -LiteralPath "$m\cs\Both" -PathType Leaf)) 'nothing is moved where the source holds the name twice in different letter case'
  }else{Write-Output 'SKIP one name as file and folder: this Windows cannot make a folder that keeps letter case apart here'}
 }

 Section 'healing and the clean-up of recovery folders' {
  $c=New-Case 'heal-prune' @{'a\one\n.txt'='1';'a\two'='2';'a\three'='3';'keep\k.txt'='k'} @{DefaultMode='Mirror';Choices=@()}
  Put (Join-Path $c.Copy 'a\one') 'an old file'
  Put (Join-Path $c.Recovery '20200101-000000\old.txt') 'old';Put (Join-Path $c.Recovery '20991231-235959\later.txt') 'named later than now'
  $swap={param($name)[IO.File]::Delete((Join-Path $c.Source "a\$name"));Put (Join-Path $c.Source "a\$name\n.txt") $name}
  $dated={@(Get-ChildItem -LiteralPath $c.Recovery -Directory|ForEach-Object {$_.Name}|Sort-Object)}
  $r=Mirror $c @{SkipVerify=$true};$h1=[IO.Path]::GetFileName($r.RecoveryFolder)
  Assert (@($r.TypeSwapsHealed).Count -eq 1 -and @($r.RecoveryRemoved).Count -eq 0 -and @(& $dated).Count -eq 3) 'healing alone deletes no recovery folder'
  & $swap 'two'
  $r=Mirror $c @{MoveExtras=$true};$h2=[IO.Path]::GetFileName($r.RecoveryFolder)
  Assert (@($r.TypeSwapsHealed).Count -eq 1 -and $h2 -ne $h1 -and @($r.RecoveryRemoved).Count -eq 0 -and @(& $dated).Count -eq 4) 'nor with -MoveExtras when no number of folders to keep is given'
  $r=Mirror $c @{KeepRecovery=1}
  Assert (@($r.RecoveryRemoved).Count -eq 0 -and @(& $dated).Count -eq 4) 'a number to keep without -MoveExtras deletes nothing either, as before'
  & $swap 'three'
  $r=Mirror $c @{MoveExtras=$true;KeepRecovery=2};$h3=[IO.Path]::GetFileName($r.RecoveryFolder)
  Assert ((Test-Path -LiteralPath (Join-Path $r.RecoveryFolder 'a\three')) -and (@(& $dated) -join '|') -eq (@($h3,'20991231-235959'|Sort-Object) -join '|')) 'with the keep rule, the folder this run healed into is never deleted and counts as one of the kept'
  Assert ((@($r.RecoveryRemoved|Sort-Object) -join '|') -eq (@('20200101-000000',$h1,$h2|Sort-Object) -join '|')) 'and folders made by earlier healing are cleaned up like any other recovery folder'
 }

 Section 'repair from the last content check' {
  $c=New-Case 'repair' ([ordered]@{'d\good.txt'='good';'d\damaged.txt'='the right content';'d\resized.txt'='the right size';'d\missing.txt'='was lost from the copy';'d\fixed.txt'='put right by hand';'d\gone.txt'='deleted from the source later';'later\skipped.txt'='its folder is set to skip later'}) @{DefaultMode='Mirror';Choices=@()}
  Assert (Throws {Mirror $c @{Repair=$true}} 'no plain copy') 'a repair without a copy says so'
  [void](Mirror $c @{SkipVerify=$true})
  Assert (Throws {Mirror $c @{Repair=$true}} 'no earlier content check') 'a repair without an earlier content check says so'
  Assert (Throws {Mirror $c @{Repair=$true;VerifyOnly=$true}} 'one of') 'a repair and a content check are not asked for together'
  $before=(Get-FileHash -LiteralPath $c.Success).Hash
  foreach($f in 'd\damaged.txt','d\fixed.txt','d\gone.txt','later\skipped.txt'){[IO.File]::WriteAllText((Join-Path $c.Copy $f),[IO.File]::ReadAllText((Join-Path $c.Copy $f)).ToUpperInvariant())}
  [IO.File]::WriteAllText((Join-Path $c.Copy 'd\resized.txt'),'short');[IO.File]::Delete((Join-Path $c.Copy 'd\missing.txt'));Put (Join-Path $c.Copy 'd\only-in-copy.txt') 'only in the copy'
  $r=Mirror $c @{VerifyOnly=$true}
  Assert ($r.Verify.Differences -eq 6 -and $r.Verify.OnlyInMirror -eq 1) 'the content check finds the damaged, resized and missing files'
  # Between the check and the repair: one file is put right by hand, one is deleted from the source,
  # one changes in the source, and one folder is set to Skip.
  [IO.File]::WriteAllText((Join-Path $c.Copy 'd\fixed.txt'),'put right by hand');[IO.File]::Delete((Join-Path $c.Source 'd\gone.txt'));[IO.File]::WriteAllText((Join-Path $c.Source 'd\resized.txt'),'changed in the source since the check')
  $c.Config=@{DefaultMode='Mirror';Choices=@(@{Path='later';Mode='Skip'})}
  Put (Join-Path $c.Recovery '20200101-000000\old.txt') 'old';Put (Join-Path $c.Recovery '20200102-000000\old.txt') 'old'
  $global:LASTEXITCODE=0
  $r=Mirror $c @{Repair=$true;MoveExtras=$true;KeepRecovery=1};$p=$r.Repair
  Assert ($p.Requested -eq 6 -and $p.Repaired -eq 3 -and $p.StillDifferent -eq 0 -and $p.Failed -eq 0 -and $p.AlreadyMatching -eq 1 -and $p.Skipped -eq 2 -and $r.CopyErrors -eq 0 -and $LASTEXITCODE -eq 0) 'the repair copies again what still differs, and only that'
  Assert (@('d\damaged.txt','d\resized.txt','d\missing.txt'|Where-Object {[IO.File]::ReadAllText((Join-Path $c.Copy $_)) -cne [IO.File]::ReadAllText((Join-Path $c.Source $_))}).Count -eq 0) 'the repaired files match the source, a file changed since the check included'
  Assert (((Files $p.MovedTo) -join '|') -eq 'd\damaged.txt|d\resized.txt' -and [IO.File]::ReadAllText((Join-Path $p.MovedTo 'd\damaged.txt')) -ceq 'THE RIGHT CONTENT' -and [IO.Path]::GetDirectoryName($p.MovedTo) -eq $c.Recovery -and [IO.Path]::GetFileName($p.MovedTo) -match '^\d{8}-\d{6}$') 'the old versions were moved to the dated recovery folder of this run'
  Assert ((InCopy $c 'd\only-in-copy.txt') -and [IO.File]::ReadAllText((Join-Path $c.Copy 'd\gone.txt')) -ceq 'DELETED FROM THE SOURCE LATER' -and [IO.File]::ReadAllText((Join-Path $c.Copy 'later\skipped.txt')) -ceq 'ITS FOLDER IS SET TO SKIP LATER') 'files only in the copy and files no longer selected are not touched'
  Assert (@(Get-ChildItem -LiteralPath (Join-Path $c.Copy 'd') -Force).Count -eq 7) 'and no working file is left in the copy'
  Assert ((Get-FileHash -LiteralPath $c.Success).Hash -eq $before -and -not $r.PSObject.Properties['Verify'] -and @($r.Runs).Count -eq 0) 'a repair is not recorded as a complete backup'
  Assert (@($r.RecoveryRemoved).Count -eq 0 -and (Test-Path -LiteralPath (Join-Path $c.Recovery '20200101-000000\old.txt')) -and (Test-Path -LiteralPath (Join-Path $c.Recovery '20200102-000000\old.txt'))) 'a repair deletes no recovery folder, whatever it is told to keep'
  $r=Mirror $c @{Repair=$true}
  Assert ($r.Repair.Requested -eq 0 -and $r.CopyErrors -eq 0 -and -not $r.Repair.MovedTo) 'a second repair finds nothing left to do'
  $r=Mirror $c @{VerifyOnly=$true}
  Assert ($r.Verify.Differences -eq 0) 'and the next content check finds no difference'
  # A file that cannot be repaired, run the way the window runs the tool.
  [IO.File]::WriteAllText((Join-Path $c.Copy 'd\good.txt'),'GOOD')
  [void](Mirror $c @{VerifyOnly=$true})
  $hold=[IO.File]::Open((Join-Path $c.Source 'd\good.txt'),'Open','ReadWrite','None')
  try{$out=& (Get-Process -Id $PID).Path -NoProfile -File $tool -ConfigPath $c.Job -DestinationDrive Z -Folder Copy -Repair -CopyThreads 2 -TestRoot $c.Root;$code=$LASTEXITCODE}finally{$hold.Dispose()}
  $r=($out -join "`n")|ConvertFrom-Json
  Assert ($code -ne 0 -and $r.CopyErrors -ge 1 -and $r.Repair.Requested -eq 1 -and $r.Repair.Failed -eq 1 -and $r.Repair.Repaired -eq 0 -and -not $r.Repair.MovedTo) 'a file that cannot be repaired is counted, and the tool ends with an error code'
  Assert ([IO.File]::ReadAllText((Join-Path $c.Copy 'd\good.txt')) -ceq 'GOOD' -and @(Get-ChildItem -LiteralPath (Join-Path $c.Copy 'd') -Force).Count -eq 7 -and @(Get-ChildItem -LiteralPath $c.Recovery -Directory).Count -eq 3) 'its old version stays in the copy and nothing is left half done'
  $r=Mirror $c @{Repair=$true}
  Assert ($r.Repair.Repaired -eq 1 -and $r.CopyErrors -eq 0 -and [IO.File]::ReadAllText((Join-Path $c.Copy 'd\good.txt')) -ceq 'good') 'the next repair, from the same check, puts it right'
  # A file of the copy that the check could not read is on the list as well.
  $hold=[IO.File]::Open((Join-Path $c.Copy 'd\good.txt'),'Open','Read','None')
  try{
   $r=Mirror $c @{VerifyOnly=$true}
   Assert ($r.Verify.Differences -eq 1) 'a file of the copy that cannot be read is a difference'
   $r=Mirror $c @{Repair=$true}
   Assert ($r.Repair.Requested -eq 1 -and $r.Repair.Failed -eq 1 -and $r.CopyErrors -eq 1 -and -not $r.Repair.MovedTo -and @(Get-ChildItem -LiteralPath (Join-Path $c.Copy 'd') -Force).Count -eq 7) 'while it is still held, the repair fails for it and leaves the copy as it was'
  }finally{$hold.Dispose()}
  $r=Mirror $c @{Repair=$true}
  Assert ($r.Repair.Requested -eq 1 -and $r.Repair.AlreadyMatching -eq 1 -and $r.Repair.Repaired -eq 0 -and $r.CopyErrors -eq 0) 'once it can be read and matches, the repair leaves it alone'
 }

 Section 'files copied at once' {
  $c=New-Case 'threads' @{'keep\a.txt'='a'} @{DefaultMode='Mirror';Choices=@()}
  [IO.File]::WriteAllText($c.Job,([ordered]@{Source=$c.Source+'\';DefaultMode='Mirror';Choices=@()}|ConvertTo-Json -Depth 8))
  $r=((& $tool -ConfigPath $c.Job -DestinationDrive Z -Folder Copy -TestRoot $c.Root -CopyThreads 128 -SkipVerify) -join "`n")|ConvertFrom-Json
  Assert ($r.CopyErrors -eq 0 -and (InCopy $c 'keep\a.txt')) 'the number of files copied at once can be given as -CopyThreads, up to the 128 the window offers'
 }

 Section 'names skipped through their short name' {
  Add-Type -Path (Join-Path $PSScriptRoot 'Backup.MirrorVerifier.cs')
  $c=New-Case 'short' @{'web\page.html'='its short name ends in .HTM';'web\index.htm'='skipped by its own name';'web\notes.txt'='n';'web\old.html\in.txt'='a folder whose short name ends in .HTM'} @{DefaultMode='Mirror';Choices=@();Exclude=@('*.htm')}
  $short=[MirrorVerifier]::ShortName((Join-Path $c.Source 'web\page.html'))
  $r=Mirror $c @{SkipVerify=$true}
  Assert ((InCopy $c 'web\notes.txt') -and -not(InCopy $c 'web\index.htm') -and $r.CopyErrors -eq 0) 'a wildcard name from Exclude skips the files it names'
  if($short){
   Assert (-not(InCopy $c 'web\page.html') -and -not(InCopy $c 'web\old.html\in.txt')) "robocopy also skips a file and a folder whose short name ($short) fits the wildcard"
   Assert ((@($r.SkippedByShortName) -join '|') -eq 'web\old.html\|web\page.html' -and $r.SkippedByShortNameCount -eq 2 -and $r.CopyErrors -eq 0) 'the summary names them as a warning, not as a copy error, and leaves out what its own name skips'
   Assert ([IO.File]::ReadAllText((Join-Path $r.RunFolder 'skipped-by-short-name.txt')).Contains("web\page.html`t$short`t*.htm")) 'the run folder keeps the short name and the Exclude name of each'
  }else{
   Write-Output 'SKIP short names: this drive gives files no short (8.3) names, so robocopy cannot skip a file through one'
   Assert ((InCopy $c 'web\page.html') -and @($r.SkippedByShortName).Count -eq 0) 'without short names nothing is skipped through one, and nothing is reported'
  }
  $c=New-Case 'short-none' @{'web\page.html'='p';'web\notes.txt'='n'} @{DefaultMode='Mirror';Choices=@();Exclude=@('notes.txt')}
  $r=Mirror $c @{SkipVerify=$true}
  Assert ((InCopy $c 'web\page.html') -and @($r.SkippedByShortName).Count -eq 0 -and $r.SkippedByShortNameCount -eq 0) 'without a wildcard name in Exclude nothing is reported'
 }

 Section 'names that differ only by letter case' {
  Add-Type -Path (Join-Path $PSScriptRoot 'Backup.MirrorVerifier.cs')
  Assert ((@([MirrorVerifier]::SameNames([string[]]@('Makefile','b.txt','makefile','MAKEFILE','B.TXT','c'))) -join '|') -eq "Makefile`tmakefile|Makefile`tMAKEFILE|b.txt`tB.TXT") 'names that differ only by the case of their letters are paired with the first of them'
  Assert (@([MirrorVerifier]::SameNames([string[]]@('a','b','a1',('a'+$zw)))).Count -eq 0) 'other names are not'
  $c=New-Case 'case' @{'plain\a.txt'='a'} @{DefaultMode='Mirror';Choices=@()}
  $dir=Join-Path $c.Source 'cs';[IO.Directory]::CreateDirectory($dir)|Out-Null
  & fsutil.exe file setCaseSensitiveInfo $dir enable 2>&1|Out-Null
  $made=$LASTEXITCODE -eq 0
  if($made){try{[IO.File]::WriteAllText("$dir\Makefile",'upper');[IO.File]::WriteAllText("$dir\makefile",'lower');$made=@(Get-ChildItem -LiteralPath $dir -Force).Count -eq 2}catch{$made=$false}}
  if($made){
   $r=Mirror $c @{SkipVerify=$true}
   Assert ((@($r.CaseCollisions) -join '|') -eq 'cs\Makefile | cs\makefile' -and $r.CaseCollisionsCount -eq 1) 'a folder that holds two names differing only by case is named in the summary'
  }else{
   Write-Output 'SKIP case-sensitive folder: this Windows cannot make one here, so only the rule is tested'
  }
  $c=New-Case 'case-none' @{'plain\a.txt'='a';'plain\b.txt'='b'} @{DefaultMode='Mirror';Choices=@()}
  $r=Mirror $c @{SkipVerify=$true}
  Assert (@($r.CaseCollisions).Count -eq 0 -and $r.CaseCollisionsCount -eq 0) 'an ordinary folder is not'
 }

 Section 'selected folder with a cache name' {
  $files=@{'venv\important.txt'='not a cache';'keep\a.txt'='a';'tools\node_modules\pkg\x.js'='x'}
  $choices=@(@{Path='venv';Mode='Both'},@{Path='keep';Mode='Both'},@{Path='tools\node_modules\pkg';Mode='Mirror'})
  $c=New-Case 'cache-inside' $files @{DefaultMode='Mirror';Choices=$choices}
  $r=Mirror $c
  Assert (-not(InCopy $c 'venv\important.txt') -and (@($r.SelectionsSkippedByName|Sort-Object) -join '|') -eq 'tools\node_modules\pkg|venv') 'a selected folder that is left out because of its name is named in the summary'
  $c=New-Case 'cache-root' $files @{DefaultMode='Skip';Exclude=@('tools/node_modules');Choices=$choices}
  $r=Mirror $c
  Assert ((InCopy $c 'venv\important.txt') -and (InCopy $c 'tools\node_modules\pkg\x.js') -and @($r.SelectionsSkippedByName).Count -eq 0) 'a folder selected on its own is copied whatever its name'
  Assert ($r.Verify.FilesMatched -eq 3 -and $r.Verify.Differences -eq 0) 'and everything copied is checked'
  [IO.File]::WriteAllText((Join-Path $c.Copy 'venv\important.txt'),'NOT A CACHE')
  $r=Mirror $c @{VerifyOnly=$true}
  Assert ($r.Verify.Differences -eq 1) 'a damaged file in such a folder is found by the content check'
 }

 Section 'names ending in a dot' {
  $c=New-Case 'dots' @{'odd\normal.txt'='n';'odd\trail.'='file name ends in a dot';'odd\dir.\in.txt'='folder name ends in a dot'} @{DefaultMode='Mirror';Choices=@()}
  $r=Mirror $c
  Assert ((InCopy $c 'odd\trail.') -and (InCopy $c 'odd\dir.\in.txt') -and $r.CopyErrors -eq 0) 'robocopy copies names that end in a dot'
  Assert ($r.Verify.Differences -eq 0 -and $r.Verify.FilesMatched -eq 3) 'and the check finds them on both sides'
 }

 Section 'invisible characters in names' {
  $c=New-Case 'marks' @{'data\skip.txt'='s';('data'+$rlm+'\copied.txt')='c';($zw+'\inside.txt')='i';'keep\a.txt'='a'} @{DefaultMode='Mirror';Choices=@(@{Path='data';Mode='Skip'})}
  $r=Mirror $c
  Assert ($r.CopyErrors -eq 0 -and $r.Verify.FilesMatched -eq 3 -and $r.Verify.Differences -eq 0) 'a folder named with an invisible character does not stop the run'
  Assert (@($r.NotSelectedButInMirror).Count -eq 0) 'a copied folder is not reported as no longer selected'
 }

 Section 'Exclude with wildcards in a path' {
  $c=New-Case 'patterns-run' @{'app1\dist\o.js'='1';'app2\dist\o.js'='2';'app1\src\a.js'='a';'deep\x\dist\o.js'='3';'logs\run.tmp'='t';'logs\keep.txt'='k';'any\where\cache2\c.bin'='c'} @{DefaultMode='Mirror';Choices=@();Exclude=@('*/dist','logs/*.tmp','**/cache2')}
  $r=Mirror $c
  Assert (((Files $c.Copy) -join '|') -eq 'app1\src\a.js|deep\x\dist\o.js|logs\keep.txt') 'the plain copy takes the path patterns the versioned backup takes'
  Assert ($r.CopyErrors -eq 0 -and $r.Verify.Differences -eq 0 -and $r.Verify.FilesMatched -eq 3) 'and the check skips the same paths'
 }

 Section 'more skipped paths than one command can hold' {
  $files=[ordered]@{'keep\a.txt'='a'};foreach($i in 1..120){$files["p$i\"+('n'*60)+'\dist\o.js']='o'}
  $c=New-Case 'many' $files @{DefaultMode='Mirror';Choices=@();Exclude=@('*/*/dist')}
  Assert (Throws {Mirror $c} 'Too many folders are skipped by path') 'a pattern that matches more paths than one robocopy command can hold is refused in plain words'
  Assert (-not(Test-Path -LiteralPath (Join-Path $c.Copy 'keep'))) 'before anything is copied'
 }

 Section 'a file in the copy that cannot be moved aside' {
  $c=New-Case 'held' @{'keep\a.txt'='a';'keep\single.txt'='s';'keep\held.txt'='h';'gone\one.txt'='1';'gone\sub\two.txt'='2'} @{DefaultMode='Mirror';Choices=@()}
  [void](Mirror $c)
  foreach($f in 'keep\single.txt','keep\held.txt'){[IO.File]::Delete((Join-Path $c.Source $f))};[IO.Directory]::Delete((Join-Path $c.Source 'gone'),$true)
  $hold=[IO.File]::Open((Join-Path $c.Copy 'keep\held.txt'),'Open','Read','None')
  try{$r=Mirror $c @{MoveExtras=$true}}finally{$hold.Dispose()}
  Assert ($r.ExtrasFound -eq 4 -and $r.ExtrasMoved -eq 3) 'the run goes on and reports how many files were really moved'
  Assert (@($r.ExtrasNotMoved).Count -eq 1 -and $r.ExtrasNotMoved[0] -eq (Join-Path $c.Copy 'keep\held.txt') -and (InCopy $c 'keep\held.txt')) 'the file that could not be moved is named and stays in the copy'
  Assert (((Files $r.ExtrasMovedTo) -join '|') -eq 'gone\one.txt|gone\sub\two.txt|keep\single.txt' -and (Test-Path -LiteralPath (Join-Path $r.RunFolder 'summary.json'))) 'the others are in the recovery folder and the run has its summary'
  $r=Mirror $c @{MoveExtras=$true}
  Assert ($r.ExtrasMoved -eq 1 -and -not(InCopy $c 'keep\held.txt')) 'the next run moves it'
  # A run that could move nothing aside made no recovery folder, so it must not push an earlier one out.
  $c=New-Case 'held-only' @{'keep\a.txt'='a';'keep\held.txt'='h'} @{DefaultMode='Mirror';Choices=@()}
  [void](Mirror $c)
  Put (Join-Path $c.Recovery '20200101-000000\earlier.txt') 'files moved aside by an earlier run'
  [IO.File]::Delete((Join-Path $c.Source 'keep\held.txt'))
  $hold=[IO.File]::Open((Join-Path $c.Copy 'keep\held.txt'),'Open','Read','None')
  try{$r=Mirror $c @{MoveExtras=$true;KeepRecovery=1}}finally{$hold.Dispose()}
  Assert ((Test-Path -LiteralPath (Join-Path $c.Recovery '20200101-000000\earlier.txt')) -and @($r.RecoveryRemoved).Count -eq 0) 'a run that could move nothing aside deletes no earlier recovery folder'
  Assert ($r.ExtrasMoved -eq 0 -and @(Get-ChildItem -LiteralPath $c.Recovery -Directory).Count -eq 1) 'and leaves no empty recovery folder behind'
 }
}finally{
 if([IO.Directory]::Exists($root)){[IO.Directory]::Delete('\\?\'+$root,$true)}
}
if($script:failed){Write-Output "$($script:failed) check(s) failed";exit 1}
