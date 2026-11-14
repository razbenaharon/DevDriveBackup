#Requires -Version 7.2
# Fast plain-file mirror of the Dev Drive with robocopy, followed by a content check.
#
# Copies only what the shared selection marks Mirror or Both: the Mode of each entry in
# Choices in backup.local.json (see Backup.Selection.psm1), with DefaultMode for anything
# not listed. Each run compares every file by size and modification time (no content read)
# and copies only new or changed files. Files that disappeared from the source are not
# deleted: with -MoveExtras they are moved to a dated recovery folder beside the mirror, and
# -KeepRecovery N then deletes all but the newest N recovery folders; otherwise they are only reported. Folders that are no longer selected keep their old copy
# in the mirror and are listed in the summary. -Verify (default on the first run) re-reads
# both copies and compares SHA-256 for every selected file; a selected source file missing from
# the mirror is a difference. A selected folder that is missing or became a link fails the run.
# DevDriveBackup's own password, key and state folders are never copied, even when one of them is
# selected itself; an older copy of one found on the backup drive is reported.
#
# A folder in the source where the copy holds a file of the same name (or the reverse) heals itself
# in a backup: the old item is moved out of the copy into this run's dated recovery folder, with or
# without -MoveExtras, and the new one is copied in the same run (TypeSwapsHealed in the summary).
#
# Every content check also writes last-check-<drive>-<folder>.json beside the run folders: when it
# ran, for which source, and the lines of verify-differences.txt that name a file of the source
# (CONTENT, SIZE, MISSING-IN-MIRROR, ERROR). -Repair reads that file and copies only those files
# again; see the Repair part below. It copies nothing else, deletes nothing and is not a backup.
#
# The summary also warns about names robocopy treats differently from what the lists say
# (SkippedByShortName, CaseCollisions); see the last part before the summary is written.
param(
 [string]$ConfigPath=(Join-Path $PSScriptRoot 'backup.local.json'),
 [string]$Source,
 [Parameter(Mandatory)][ValidatePattern('^[A-Za-z]$')][string]$DestinationDrive,
 # One folder name, or two separated by a backslash (for example Drive-C-Mirror\Projects).
 [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]{0,79}(\\[A-Za-z0-9][A-Za-z0-9._-]{0,79})?$')][string]$Folder='DevDrive-Mirror',
 # Files copied at once (robocopy takes up to 128); the window calls it CopyThreads.
 [ValidateRange(1,128)][Alias('CopyThreads')][int]$Threads=16,
 [switch]$MoveExtras,
 # With -MoveExtras: keep only this many dated recovery folders (the newest) and delete older
 # ones from the backup drive. 0 keeps every recovery folder.
 [ValidateRange(0,100)][int]$KeepRecovery=0,
 # With -KeepRecovery: delete no recovery folder, only name the ones the rule would delete
 # (RecoveryWouldRemove). The window uses it until the first clean-up has been approved.
 [switch]$PreviewRecovery,
 [switch]$Verify,
 [switch]$SkipVerify,
 # Compare the mirror with the source without copying anything.
 [switch]$VerifyOnly,
 # Copy again the files the last content check of this copy found different, unreadable or missing
 # in the copy, and nothing else. The old version of each is first moved to this run's dated
 # recovery folder, and the new copy is compared with the source by SHA-256. Not a backup: the
 # copy is not recorded as complete, and no recovery folder is cleaned up.
 [switch]$Repair,
 # For the tests only: copy into this folder instead of onto a drive and keep the run records there.
 # It must lie below the temporary folder, so it can never stand in for a backup drive; the drive
 # checks, which need two real disks, are skipped. -DestinationDrive is then not used.
 [Parameter(DontShow)][string]$TestRoot
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'Backup.Selection.psm1') -Force

if(-not(Test-Path -LiteralPath $ConfigPath)){throw "Configuration not found: $ConfigPath"}
$config=Get-Content -LiteralPath $ConfigPath -Raw|ConvertFrom-Json
$selection=Get-BackupSelection $config
if(-not $selection.HasModes){throw 'Give each entry in Choices a Mode (Mirror, Versioned, Both or Skip) before mirroring. See README.md.'}
$regions=@(Get-BackupRegions $selection 'Mirror')
if($regions.Count -eq 0){throw 'Nothing is marked Mirror or Both'}
if(-not $Source){$Source=[string]$config.Source}

# Always skipped by folder name at any depth: system folders, caches and environments that rebuild.
$skipNames=@('$RECYCLE.BIN','System Volume Information','node_modules','.venv','venv','__pycache__','.pytest_cache',
 '.next','.turbo','.pnpm-store','.mypy_cache','.ruff_cache','pytest-of-*','.temporary-worker-test-*')
$skipPaths=@();$personalNames=@()
# Personal skips come from the configuration's Exclude list, which the versioned backup also uses:
# a bare name (wildcards allowed) skips that folder name anywhere; a path skips one folder, given
# relative to the source root or as a full path below it (for example E:/Projects/app/build/cache).
# A path may hold wildcards, as the versioned backup allows (*/dist, logs/*.tmp, ** for any number of
# folders): robocopy refuses wildcards inside a path, so such a path is matched here against the
# names really in the source, and every match is skipped as a path of its own.
$srcRoot=[IO.Path]::GetFullPath($(if($Source){$Source}else{[string]$config.Source})).TrimEnd('\')+'\'
foreach($entry in @(if($config.PSObject.Properties['Exclude']){$config.Exclude})){
 $e=([string]$entry).Trim();if(-not $e){continue}
 if($e -match '^\*\*[\\/]([^\\/]+)$'){$e=$Matches[1]}   # **/name is a name at any depth
 if($e -notmatch '[\\/]'){if(-not @($skipNames|Where-Object {[string]::Equals($_,$e,[StringComparison]::OrdinalIgnoreCase)}).Count){$skipNames+=$e;$personalNames+=$e};continue}
 $e=$e.Replace('/','\').TrimEnd('\')
 if($e -match '^[A-Za-z]:\\'){
  if(-not $e.StartsWith($srcRoot,[StringComparison]::OrdinalIgnoreCase)){continue}  # belongs to another source
  $e=$e.Substring($srcRoot.Length)
 }
 $e=$e.TrimStart('\');if(-not $e){continue}
 if($e -match '[*?]'){$skipPaths+=@(Resolve-BackupExcludePath $srcRoot $e)}else{$skipPaths+=$e}
}
# DevDriveBackup's private folders (protected passwords, run state, plaintext recovery keys) are never
# copied, whatever the selection: the copy would not keep their private permissions. The job's own key
# files count too, in case the configuration keeps them somewhere else.
$privatePaths=@((Join-Path $env:LOCALAPPDATA 'DevDriveMirror'),(Join-Path $env:USERPROFILE 'DevDriveBackup recovery keys'),(Join-Path $env:USERPROFILE 'Backup Center recovery keys'))+@('PasswordDpapiPath','RecoveryKeyPath'|Where-Object {$config.PSObject.Properties[$_] -and $config.$_}|ForEach-Object {[string]$config.$_})
$privateRoots=@($privatePaths|ForEach-Object {[IO.Path]::GetFullPath($_).TrimEnd('\')})
$privateInSource=@()
foreach($p in $privateRoots){
 if($srcRoot.StartsWith($p+'\',[StringComparison]::OrdinalIgnoreCase)){throw "The source is inside $p, which holds DevDriveBackup's passwords and recovery keys and is never copied"}
 if($p.StartsWith($srcRoot,[StringComparison]::OrdinalIgnoreCase)){$skipPaths+=$p.Substring($srcRoot.Length);$privateInSource+=$p.Substring($srcRoot.Length)}
}

$src=[IO.Path]::GetFullPath($Source).TrimEnd('\')+'\'
if($TestRoot){
 $temp=[IO.Path]::GetTempPath().TrimEnd('\');$TestRoot=[IO.Path]::GetFullPath($TestRoot).TrimEnd('\')
 if(-not $TestRoot.StartsWith($temp+'\',[StringComparison]::OrdinalIgnoreCase)){throw '-TestRoot is for the tests only and must be a folder below the temporary folder'}
 # A link on the way could lead out of the temporary folder, onto a real drive.
 for($p=$TestRoot;$p.Length -gt $temp.Length;$p=[IO.Path]::GetDirectoryName($p)){
  if((Test-Path -LiteralPath $p) -and ((Get-Item -LiteralPath $p -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)){throw '-TestRoot is for the tests only and must not lie behind a link or junction'}
 }
 $volumeKey='test';$dst=Join-Path $TestRoot $Folder;$stateRoot=Join-Path $TestRoot 'state'
 # The same for the folders written below it: a link standing in for one of them leads out as well.
 foreach($inner in @($dst,($dst+'-recovery'),$stateRoot)){
  for($p=[IO.Path]::GetFullPath($inner).TrimEnd('\');$p.Length -gt $TestRoot.Length;$p=[IO.Path]::GetDirectoryName($p)){
   if((Test-Path -LiteralPath $p) -and ((Get-Item -LiteralPath $p -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)){throw '-TestRoot is for the tests only and must not hold a link or junction where the copy is written'}
  }
 }
}else{
 $srcVolume=Get-Volume -DriveLetter $src.Substring(0,1)
 $dstVolume=Get-Volume -DriveLetter $DestinationDrive
 if($srcVolume.UniqueId -eq $dstVolume.UniqueId){throw 'Destination is the source volume'}
 # The copy goes only to the backup drive this configuration was made for, not another drive that took its letter.
 if($config.PSObject.Properties['DestinationVolumeId'] -and $config.DestinationVolumeId -and $dstVolume.UniqueId -ne $config.DestinationVolumeId){throw "Drive $($DestinationDrive.ToUpperInvariant()): is not the backup drive this configuration was made for (its volume identity differs). Check which drive has this letter now."}
 # The configured source must still be the same volume, not another drive that took its letter.
 $configured=if($config.PSObject.Properties['Source'] -and $config.Source){[IO.Path]::GetFullPath([string]$config.Source).TrimEnd('\')+'\'}else{''}
 if($config.PSObject.Properties['SourceVolumeId'] -and $config.SourceVolumeId -and $configured -and $src.StartsWith($configured,[StringComparison]::OrdinalIgnoreCase) -and $srcVolume.UniqueId -ne $config.SourceVolumeId){throw 'The source drive is not the one this configuration was made for (its volume identity changed). Check which drive has this letter now.'}
 # Never onto the disk the source lies on, in either direction: a Dev Drive is a file on another
 # disk, and so is a destination that is a virtual disk.
 $diskOf={param($letter)Get-Partition -DriveLetter $letter|Get-Disk}
 $sameDisk=Get-BackupSameDiskReason (& $diskOf $src.Substring(0,1)) (& $diskOf $DestinationDrive) $diskOf
 if($sameDisk){throw $sameDisk}
 $dst=$DestinationDrive.ToUpperInvariant()+':\'+$Folder
 # Keyed by the drive's volume identity, so another drive that takes this letter still gets its first full check.
 $volumeKey=($dstVolume.UniqueId -replace '[^A-Za-z0-9-]+','_').Trim('_');$stateRoot=Join-Path $env:LOCALAPPDATA 'DevDriveMirror\fast-mirror'
}
$recoveryRoot=$dst+'-recovery'
$lastSuccess=Join-Path $stateRoot ('last-success-'+$volumeKey+'-'+($Folder -replace '\\','_')+'.json')
# What the last content check of this copy found; -Repair works from it.
$lastCheck=Join-Path $stateRoot ('last-check-'+$volumeKey+'-'+($Folder -replace '\\','_')+'.json')
if($Repair -and $VerifyOnly){throw 'Give one of -Repair and -VerifyOnly, not both'}
# A content check and a repair work on an existing copy: they never create one, never run robocopy
# and never count as a backup.
$noCopy=$VerifyOnly -or $Repair
if($noCopy -and -not(Test-Path -LiteralPath $dst -PathType Container)){throw "There is no plain copy at $dst to $(if($Repair){'repair'}else{'check'}). Back up first."}
$check=$null
if($Repair){
 if(-not(Test-Path -LiteralPath $lastCheck)){throw "There is no earlier content check of the plain copy at $dst to repair from. Check the content first, then repair."}
 $check=Get-Content -LiteralPath $lastCheck -Raw|ConvertFrom-Json
 if(-not [string]::Equals([string]$check.Source,$src,[StringComparison]::OrdinalIgnoreCase)){throw "The last content check of the plain copy at $dst was made for another source ($($check.Source)). Check the content first, then repair."}
}
# Named to the second; a run that starts in the same second as another gets a folder of its own.
$run=Join-Path $stateRoot (Get-Date -Format 'yyyyMMdd-HHmmss')
for($n=2;Test-Path -LiteralPath $run;$n++){$run=(Join-Path $stateRoot (Get-Date -Format 'yyyyMMdd-HHmmss'))+'-'+$n}
New-Item -ItemType Directory -Path $run -Force|Out-Null
if(-not $noCopy){New-Item -ItemType Directory -Path $dst -Force|Out-Null}
$firstRun=-not(Test-Path -LiteralPath $lastSuccess)
if(($firstRun -and -not $SkipVerify) -or $VerifyOnly){$Verify=$true}
# A repair compares each file it copies; the check of the whole copy is a run of its own.
if($Repair){$Verify=$false}

function Join-Rel([string]$Root,[string]$Relative){if($Relative){Join-Path $Root $Relative}else{$Root.TrimEnd('\')}}
# 'E:' alone means the current directory on E:, and 'E:\' would escape the closing quote; use 'E:\.' for a root.
function Format-RoboDir([string]$Path){if($Path.TrimEnd('\').Length -eq 2){$Path.TrimEnd('\')+'\.'}else{$Path.TrimEnd('\')}}
function Get-RoboArgs([string]$From,[string]$To,[string]$Log,[string[]]$Excluded=@(),[string[]]$Extra=@()){
 $a=@((Format-RoboDir $From),$To,'/E','/COPY:DAT','/DCOPY:DAT','/XJ','/R:1','/W:1','/NP','/NDL','/FP','/BYTES',('/MT:'+$Threads),('/UNILOG:'+$Log))
 # Unselected entries are listed on both sides so the extras check does not report their old copies.
 $paths=@($skipPaths+$Excluded|ForEach-Object {(Join-Rel $src $_),(Join-Rel $dst $_)})
 $a+='/XD';$a+=@($skipNames)+$paths
 # Personal names from Exclude skip files with that name too, as the versioned backup does.
 $a+='/XF';$a+=$paths+@($personalNames)
 $a+$Extra
}
function Invoke-Robo([string[]]$RoboArgs,[string]$Label){
 # 8 means some files could not be copied (for example a file another program keeps locked); the
 # run goes on and they are counted below. 16 and above means robocopy could not work at all.
 # Windows starts no program with a command line of more than about 32,000 characters, and every
 # path skipped below this folder is on it four times.
 if((($RoboArgs|Measure-Object -Property Length -Sum).Sum+3*$RoboArgs.Count) -gt 30000){throw "Too many folders are skipped by path for one copy of $Label. In Exclude, use a folder name instead of a path pattern, or skip a folder higher up."}
 & robocopy.exe @RoboArgs|Out-Null
 $code=$LASTEXITCODE
 if($code -ge 16){throw "robocopy $Label failed with exit code $code. See $($RoboArgs|Where-Object {$_ -like '/UNILOG:*'})"}
 $code
}
# A folder in the source where the copy has a file of the same name, or the reverse. robocopy copies
# nothing there and names at most one side, so each one found is kept with both paths. A backup then
# moves the item in the copy aside (Move-TypeSwap); what could not be moved stays on this list and is
# reported. Returns the pair, or nothing.
$conflicts=[Collections.Generic.List[object]]::new()
function Test-TypeConflict([string]$Relative){
 $s=Join-Rel $src $Relative;$m=Join-Rel $dst $Relative;$folder=[IO.Directory]::Exists($s)
 if(-not(($folder -and [IO.File]::Exists($m)) -or ([IO.File]::Exists($s) -and [IO.Directory]::Exists($m)))){return}
 $known=@($conflicts|Where-Object {[string]::Equals($_.Copy,$m,[StringComparison]::OrdinalIgnoreCase)})
 if($known.Count){return $known[0]}
 $pair=[pscustomobject]@{Source=$s;Copy=$m;Relative=$Relative;SourceIsFolder=$folder};$conflicts.Add($pair);$pair
}
# The dated recovery folder of this run, beside the copy. Whatever a run moves out of the copy goes
# there under its own path, and nothing is ever deleted: files gone from the source (-MoveExtras), an
# item that changed between file and folder, the old version of a repaired file. It is named to the
# second, when the first item is about to be moved. A folder of that name left by a run a moment ago
# is not shared: this run waits for the next second, so the folder is this run's alone.
$script:recovery='';$script:recoveryMoves=0
function Get-RunRecovery{
 while(-not $script:recovery){
  $p=Join-Path $recoveryRoot (Get-Date -Format 'yyyyMMdd-HHmmss')
  if(Test-Path -LiteralPath $p){Start-Sleep -Milliseconds 200}else{$script:recovery=$p}
 }
 $script:recovery
}
# Heals one such pair in a backup: the item in the copy is moved to the recovery folder, so the next
# copy of that folder brings the new item. Never in a content check or a repair. Whether it was moved.
$healed=[Collections.Generic.List[object]]::new()
function Move-TypeSwap($Pair){
 if($noCopy -or -not $Pair -or -not $Pair.Relative){return $false}
 # A folder in the copy can hold the old copy of a folder that is no longer selected. Such a copy
 # stays where it is (as when its parent folder is deleted from the source), so the folder is not moved.
 if([IO.Directory]::Exists($Pair.Copy) -and @($selection.Entries|Where-Object {-not(Test-BackupModeIncludes $_.Mode 'Mirror') -and $_.Path.StartsWith($Pair.Relative+'\',[StringComparison]::OrdinalIgnoreCase)}).Count){return $false}
 # Nor anything that lies behind a link or junction, on either side.
 if((Test-BackupLinkOnPath $src $Pair.Relative) -or (Test-BackupLinkOnPath $dst $Pair.Relative)){return $false}
 $target=(Get-RunRecovery)+'\'+$Pair.Relative
 if(-not(Move-BackupTypeSwap $Pair.Source $Pair.Copy $target)){return $false}
 $script:recoveryMoves++;[void]$conflicts.Remove($Pair)
 $healed.Add([ordered]@{Source=$Pair.Source;Copy=$Pair.Copy;MovedTo=$target});$true
}

$started=Get-Date
$summary=[ordered]@{Source=$src;Destination=$dst;Started=$started.ToString('o');DefaultMode=$selection.DefaultMode;Selected=@($regions|ForEach-Object {if($_.Path){$_.Path}else{'(source root)'}});Runs=@();SelectionsMissing=@();SelectionsSkippedAsLinks=@();SelectionsSkippedAsPrivate=@()}
$copied=@();$rootConflicts=0
$logNames=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
function Invoke-CopyRun([string[]]$RoboArgs,[string]$Part,[string]$Log){
 # One robocopy run, added to the summary. The totals are read as soon as the run ends, from the log
 # of this run alone. Repeated marks a run whose folder was copied again after a file-or-folder swap
 # in it was healed: the later run tells what is left uncopied there.
 $code=Invoke-Robo $RoboArgs $Part;$result=Get-RoboRunResult $Log $code;$t=$result.Totals
 $entry=[ordered]@{Part=$Part;ExitCode=$code;Log=$Log;Files=$(if($t){'Files : '+($t.Files -join ' ')}else{''});Bytes=$(if($t){'Bytes : '+($t.Bytes -join ' ')}else{''});NotCopied=$result.NotCopied;Complete=$result.Complete;Repeated=$false}
 $summary.Runs+=$entry
 [pscustomobject]@{Entry=$entry;Mismatch=([bool]($code -band 4) -or ($t -and ($t.Files[3]+$t.Dirs[3]) -gt 0))}
}
foreach($region in $regions){
 $from=Join-Rel $src $region.Path;$to=Join-Rel $dst $region.Path
 # /XD only skips folders below the one robocopy copies, never that folder itself, and a file selected
 # on its own gets no /XF at all. So a selection that is a private folder or key file, or lies inside
 # one, is skipped here, whatever its mode says.
 if($region.Path -and (Test-BackupPathInside ([IO.Path]::GetFullPath($from)) $privateRoots)){$summary.SelectionsSkippedAsPrivate+=$region.Path;continue}
 if(-not(Test-Path -LiteralPath $from)){$summary.SelectionsMissing+=$region.Path;continue}
 $item=Get-Item -LiteralPath $from -Force
 if($region.Path -and ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)){$summary.SelectionsSkippedAsLinks+=$region.Path;continue}
 # A selected folder whose place in the copy is taken by a file: robocopy cannot even start there.
 # A backup moves that file aside first. Where it cannot (or in a content check), the folder counts
 # as one item not copied, and the other selections are still copied. (A selected file whose place
 # is still taken by a folder is only noted here; robocopy reports that mismatch itself.)
 $pair=Test-TypeConflict $region.Path
 if($pair -and -not(Move-TypeSwap $pair) -and $item.PSIsContainer){$rootConflicts++;continue}
 $log=Join-Path $run (Get-MirrorLogName $region.Path $logNames)
 if($item.PSIsContainer){$a=@(Get-RoboArgs $from $to $log $region.Excluded)}
 else{
  # A single file selected on its own (for example README.md at the drive root).
  $a=@((Format-RoboDir (Split-Path -LiteralPath $from)),(Split-Path -LiteralPath $to),$item.Name,'/COPY:DAT','/R:1','/W:1','/NP','/FP','/BYTES',('/UNILOG:'+$log))
 }
 $part=if($region.Path){$region.Path}else{'main'}
 $copied+=[pscustomobject]@{Region=$region;IsFolder=$item.PSIsContainer;Log=$log;Part=$part;Args=$a;Run=$(if(-not $noCopy){Invoke-CopyRun $a $part $log})}
}
# A choice inside a copied folder is left out by robocopy without a word when its own name, or a
# folder name on the way to it, is on the always-skipped list (a folder called venv, say). Such a
# choice is named, so a folder shown as selected is never missing from the copy unnoticed.
$rootPaths=@($copied|ForEach-Object {$_.Region.Path})
$summary.SelectionsSkippedByName=@(foreach($e in $selection.Entries){
 if(-not(Test-BackupModeIncludes $e.Mode 'Mirror')){continue}
 $root=$null
 foreach($r in $rootPaths){if(($r.Length -eq 0 -or [string]::Equals($r,$e.Path,[StringComparison]::OrdinalIgnoreCase) -or $e.Path.StartsWith($r+'\',[StringComparison]::OrdinalIgnoreCase)) -and ($null -eq $root -or $r.Length -gt $root.Length)){$root=$r}}
 if($null -eq $root -or $root.Length -eq $e.Path.Length){continue}   # not in a copied folder, or copied on its own
 $full=Join-Rel $src $e.Path;if(-not(Test-Path -LiteralPath $full)){continue}
 $below=if($root){$e.Path.Substring($root.Length+1)}else{$e.Path}
 if(Get-BackupSkippedName $below $skipNames $personalNames (Test-Path -LiteralPath $full -PathType Container)){$e.Path}
})
# An earlier version could copy a private folder. Such a copy holds readable recovery keys; it is
# reported so it can be deleted by hand, never deleted here.
$summary.PrivateCopiesOnDrive=@($privateInSource|Where-Object {$_ -and (Test-Path -LiteralPath (Join-Rel $dst $_))})
if($copied.Count -eq 0 -and $summary.SelectionsSkippedAsPrivate.Count){
 $old=if($summary.PrivateCopiesOnDrive.Count){' An older copy of one is still on the backup drive and holds readable recovery keys; delete it: '+(@($summary.PrivateCopiesOnDrive|ForEach-Object {Join-Rel $dst $_}) -join ', ')+'.'}else{''}
 throw ("Everything selected is one of DevDriveBackup's private folders, which hold passwords and recovery keys and are never copied: "+($summary.SelectionsSkippedAsPrivate -join ', ')+'.'+$old)
}
if($copied.Count -eq 0 -and -not $rootConflicts){throw ('None of the selected paths exist under '+$src+': '+($summary.Selected -join ', '))}
# robocopy gives a folder copied from a drive root the root's hidden/system attributes.
if(-not $noCopy){& attrib.exe -s -h $dst|Out-Null}

# Files in the mirror that are gone from the source: list them, and optionally move them aside.
# Kept in the order Windows compares names, not a dictionary's: two paths that differ by an invisible
# character are two paths, and a folder always comes before what is inside it.
$listed=[Collections.Generic.SortedSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach($c in @($copied|Where-Object {$_.IsFolder -and -not $noCopy})){
 $extrasLog=Join-Path $run ('extras-'+[IO.Path]::GetFileName($c.Log).Substring(5))
 # Directory names must be listed here (no /NDL) so extra directories are reported too.
 # With /MT, robocopy's records can be split over lines or share one; see Get-RoboExtraPaths.
 $list={
  & robocopy.exe @(@(Get-RoboArgs (Join-Rel $src $c.Region.Path) (Join-Rel $dst $c.Region.Path) $extrasLog $c.Region.Excluded @('/L','/PURGE','/NJH','/NJS'))|Where-Object {$_ -ne '/NDL'})|Out-Null
  Get-Content -LiteralPath $extrasLog -Encoding Unicode
 }
 $lines=@(& $list)
 # Where the copy run reported a mismatch, the listing shows which names: it holds every folder of
 # the source and every file that differs. Each is looked up on both sides, so only a real
 # folder-against-file pair counts.
 $swaps={foreach($p in @(Get-RoboExtraPaths $lines $src $dst)){Test-TypeConflict $p.Substring($src.Length).Trim('\')}}
 if($c.Run.Mismatch -and @(& $swaps|Where-Object {Move-TypeSwap $_}).Count){
  # The old items are out of the way now, so the folder is copied once more, which brings the new
  # ones, and listed again. What is still a mismatch after that is reported.
  $c.Run.Entry.Repeated=$true
  $again=Join-Path $run (Get-MirrorLogName ($c.Part+' again') $logNames)
  $c.Run=Invoke-CopyRun @($c.Args|ForEach-Object {if($_ -like '/UNILOG:*'){'/UNILOG:'+$again}else{$_}}) $c.Part $again
  $lines=@(& $list)
 }
 if($c.Run.Mismatch){& $swaps|Out-Null}
 foreach($p in @(Get-RoboExtraPaths $lines $dst $src)){[void]$listed.Add($p)}
}
# Only selected paths count as extras; old copies of unselected folders are reported separately below.
# A path that still exists in the source is never an extra, whatever the log seems to say.
$extras=@($listed|Where-Object {
 $rel=$_.Substring($dst.Length).Trim('\')
 $rel -and (Test-BackupModeIncludes (Get-BackupMode $selection $rel) 'Mirror') -and -not(Test-Path -LiteralPath (Join-Rel $src $rel))
})
# Counted as files: the listing names a deleted folder and every file in it.
$summary.ExtrasFound=@($extras|Where-Object {-not $_.EndsWith('\')}).Count
# Files are moved aside only after a copy that read the whole source: a run where robocopy failed
# (exit code 8 or more) or did not finish may have missed files that still exist, so its extras are
# only reported.
$copyFailed=@($summary.Runs|Where-Object {-not $_.Repeated -and -not $_.Complete}).Count -gt 0
if($MoveExtras -and $copyFailed -and -not $noCopy){$summary.ExtrasNotMovedReason='Some files could not be copied in this run, so nothing was moved aside'}
if($MoveExtras -and $extras.Count -and -not $noCopy -and -not $copyFailed){
 $stamp=Get-RunRecovery
 $moved=0;$movedItems=0;$notMoved=@()
 foreach($item in $extras){
  if(-not(Test-Path -LiteralPath $item)){continue}
  $relative=$item.Substring($dst.Length).TrimStart('\')
  # Checked again here: a file put back in the source while earlier items were moved stays in the copy.
  if(Test-Path -LiteralPath (Join-Rel $src $relative.TrimEnd('\'))){continue}
  # A deleted folder can still hold, in the copy, the old copy of a sub-folder that is no longer
  # selected. Such a copy is kept, so the folder is not moved whole; its own files follow in the list.
  if($item.EndsWith('\') -and @($selection.Entries|Where-Object {-not(Test-BackupModeIncludes $_.Mode 'Mirror') -and $_.Path.StartsWith($relative,[StringComparison]::OrdinalIgnoreCase)}).Count){continue}
  $target=Join-Path $stamp $relative
  # A file another program holds open cannot be moved. It stays in the copy and is named, and the
  # run goes on. A folder that cannot be moved whole is left to its files, which follow in the list.
  try{
   $count=if($item.EndsWith('\')){@(Get-ChildItem -LiteralPath $item -Recurse -File -Force).Count}else{1}
   New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($target.TrimEnd('\'))) -Force|Out-Null
   Move-Item -LiteralPath $item -Destination $target
   $moved+=$count;$movedItems++;$script:recoveryMoves++
  }catch{if(-not $item.EndsWith('\')){$notMoved+=$item}}
 }
 if($movedItems){$summary.ExtrasMovedTo=$stamp}
 # Files really moved; a folder moved whole counts by the files in it.
 $summary.ExtrasMoved=$moved
 $summary.ExtrasNotMoved=$notMoved
}

# The rules of the copy, as the content check, the repair and the look at names below take them: the
# same skips as the copy (names, personal names for files too, Exclude paths, the private folders).
# They apply below each folder robocopy copied, as with robocopy, so the copied folders are passed too.
# ForEach-Object rather than $selection.Entries.Path: under strict mode an empty list (a source
# with no subfolders listed) has no Path property.
$rulePaths=[string[]]@($selection.Entries|ForEach-Object {$_.Path})
$ruleOn=[bool[]]@($selection.Entries|ForEach-Object {Test-BackupModeIncludes $_.Mode 'Mirror'})
$ruleDefault=Test-BackupModeIncludes $selection.DefaultMode 'Mirror'
$ruleRoots=[string[]]@($copied|ForEach-Object {$_.Region.Path})

# --- Repair -----------------------------------------------------------------------------------------
# The files the last content check found different, unreadable or missing in the copy are looked at
# again and, where the copy still differs, copied again (MirrorVerifier.Repair: the new copy is
# compared with the source by SHA-256 before the old version is moved to the recovery folder and the
# new one takes its name). Files only in the copy are not on the list; a file that is no longer
# selected, or gone from the source, is left alone; a file that changed in the source since the
# check is simply copied as it is now. What could not be put right counts as a copy error and stays
# in the record of the check, so the next repair tries it again; what was put right leaves the record.
if($Repair){
 Add-Type -Path (Join-Path $PSScriptRoot 'Backup.MirrorVerifier.cs')
 $wanted=[string[]]@(@($check.Files)|ForEach-Object {$f=([string]$_).Split("`t");if($f.Count -ge 2 -and $f[1] -and $f[0] -cin 'CONTENT','SIZE','MISSING-IN-MIRROR','ERROR'){$f[1]}})
 $done=[string[]]@(if($wanted.Count){[MirrorVerifier]::Repair($dst,$src,(Get-RunRecovery),[math]::Min(8,$Threads),$wanted,$rulePaths,$ruleOn,$ruleDefault,[string[]]$skipNames,[string[]]$personalNames,[string[]]$skipPaths,$ruleRoots)})
 [IO.File]::WriteAllLines((Join-Path $run 'repair.txt'),$done)
 $count={param($what)@($done|Where-Object {$_.StartsWith($what+"`t")}).Count}
 $script:recoveryMoves+=@($done|Where-Object {$_.Split("`t")[2]}).Count
 $when=$check.Checked;if($when -is [datetime]){$when=$when.ToString('o')}
 $summary.Repair=[ordered]@{Requested=$done.Count;Repaired=(& $count 'REPAIRED');StillDifferent=(& $count 'STILL-DIFFERENT');Failed=(& $count 'FAILED');MovedTo=''
  AlreadyMatching=(& $count 'MATCHES');Skipped=(& $count 'SKIPPED');CheckedAt=[string]$when;Details=(Join-Path $run 'repair.txt')}
 $left=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
 foreach($line in $done){if($line -cmatch "^(STILL-DIFFERENT|FAILED)`t"){[void]$left.Add($line.Split("`t")[1])}}
 [ordered]@{Checked=[string]$when;Source=$src;Destination=$dst;RunFolder=[string]$check.RunFolder;Repaired=(Get-Date).ToString('o')
  Files=@(@($check.Files)|Where-Object {$f=([string]$_).Split("`t");$f.Count -ge 2 -and $left.Contains($f[1])})}|ConvertTo-Json -Depth 3|Set-Content -LiteralPath $lastCheck
}
# A run that could move nothing made no recovery folder. The empty folders prepared for it are
# removed, or they would count as this run's folder and push an earlier one out of the kept ones.
if($script:recovery -and -not $script:recoveryMoves){
 if((Test-Path -LiteralPath $script:recovery) -and -not @(Get-ChildItem -LiteralPath $script:recovery -Recurse -File -Force).Count){Remove-Item -LiteralPath $script:recovery -Recurse -Force}
 $script:recovery=''
}
# What was healed, and where this run moved things to ('' when it moved nothing).
$summary.TypeSwapsHealed=@($healed);$summary.RecoveryFolder=$script:recovery
if($Repair){$summary.Repair.MovedTo=$script:recovery}
# Old recovery folders: keep the newest KeepRecovery, delete the rest. Only folders this script
# names (yyyyMMdd-HHmmss) directly inside the recovery root are touched, and never the one this run
# made, whether it holds files gone from the source or an item moved aside by healing. Only a backup
# with -MoveExtras and a number to keep deletes anything; healing alone and a repair never do.
# RecoveryRemoved lists only folders that were really deleted; with -PreviewRecovery the same choice
# is listed in RecoveryWouldRemove and nothing is deleted.
$summary.RecoveryRemoved=@();$summary.RecoveryWouldRemove=@()
if($MoveExtras -and $KeepRecovery -gt 0 -and -not $noCopy -and (Test-Path -LiteralPath $recoveryRoot -PathType Container)){
 $dated=@(Get-ChildItem -LiteralPath $recoveryRoot -Directory -Force|Where-Object {$_.Name -match '^\d{8}-\d{6}$' -and -not($_.Attributes -band [IO.FileAttributes]::ReparsePoint)}|ForEach-Object {$_.Name})
 foreach($old in @(Get-RecoveryFoldersToRemove $dated $KeepRecovery $(if($script:recovery){[IO.Path]::GetFileName($script:recovery)}else{''}))){
  if($PreviewRecovery){$summary.RecoveryWouldRemove+=$old;continue}
  Remove-Item -LiteralPath (Join-Path $recoveryRoot $old) -Recurse -Force
  $summary.RecoveryRemoved+=$old
 }
}

# Old copies in the mirror of folders that are no longer selected. They are kept, never deleted.
$notSelected=[Collections.Generic.List[string]]::new()
function Find-NotSelected([string]$Relative){
 foreach($child in @(Get-ChildItem -LiteralPath (Join-Rel $dst $Relative) -Force -ErrorAction SilentlyContinue)){
  $rel=if($Relative){$Relative+'\'+$child.Name}else{$child.Name}
  if(Test-BackupModeIncludes (Get-BackupMode $selection $rel) 'Mirror'){continue}
  if(@($regions|Where-Object {$_.Path.StartsWith($rel+'\',[StringComparison]::OrdinalIgnoreCase)}).Count){Find-NotSelected $rel}else{$notSelected.Add($rel)}
 }
}
Find-NotSelected ''
$summary.NotSelectedButInMirror=@($notSelected)

# Files that still failed after the retry are counted from robocopy's totals; the ERROR lines
# (one per attempt) are kept in copy-errors.txt for details.
# A run that was repeated after healing is left out: the later run of that folder tells what is left.
$lastRuns=@($summary.Runs|Where-Object {-not $_.Repeated})
$errors=@($lastRuns|Where-Object {Test-Path -LiteralPath $_.Log}|ForEach-Object {Get-Content -LiteralPath $_.Log -Encoding Unicode|Where-Object {$_ -match '\sERROR \d+ ' -or $_ -match '\*MISMATCH'}})
# A run without totals was ended or crashed; robocopy wrote no line about that itself.
$errors+=@($lastRuns|Where-Object {$_.Files -eq ''}|ForEach-Object {"NOT FINISHED`trobocopy ended before it finished copying $($_.Part) (exit code $($_.ExitCode)), so this copy is incomplete. Back up again. Log: $($_.Log)"})
# The same name is a folder on one side and a file on the other: both paths, and what to do.
$errors+=@($conflicts|ForEach-Object {
 $todo=if($noCopy){'The next backup moves it aside and copies the new one.'}else{'It could not be moved aside: a program may be using it, or it holds the old copy of a folder that is no longer selected. Move it yourself, then back up again.'}
 if($_.SourceIsFolder){"TYPE CONFLICT`tThe source has a folder where the copy has a file of the same name, so nothing in that folder is copied. Source: $($_.Source)  Copy: $($_.Copy)  $todo"}
 else{"TYPE CONFLICT`tThe source has a file where the copy has a folder of the same name, so the file is not copied. Source: $($_.Source)  Copy: $($_.Copy)  $todo"}
})
[IO.File]::WriteAllLines((Join-Path $run 'copy-errors.txt'),[string[]]$errors)
$summary.TypeConflicts=@($conflicts|ForEach-Object {$_.Copy})
# What each run left uncopied (see Get-RoboRunResult), plus each selected folder that could not be
# started because a file has its place in the copy. In a repair: each file it could not put right,
# and nothing else, so a repair fails only for what it was asked to do.
$summary.CopyErrors=if($Repair){[long]($summary.Repair.StillDifferent+$summary.Repair.Failed)}else{[long](@($lastRuns|ForEach-Object {$_.NotCopied})|Measure-Object -Sum).Sum+$rootConflicts}

if($Verify){
 Add-Type -Path (Join-Path $PSScriptRoot 'Backup.MirrorVerifier.cs')
 $vf=[long]0;$vb=[long]0
 $bad=[MirrorVerifier]::Compare($dst,$src,[math]::Min(8,[Environment]::ProcessorCount),$rulePaths,$ruleOn,$ruleDefault,[string[]]$skipNames,[string[]]$personalNames,[string[]]$skipPaths,$ruleRoots,[ref]$vf,[ref]$vb)
 [IO.File]::WriteAllLines((Join-Path $run 'verify-differences.txt'),[string[]]$bad)
 # Files only in the mirror (deleted from the source, or now skipped) are expected in a copy that
 # never deletes; they are reported, but are not differences. Selected files missing from the mirror are.
 $onlyInMirror=@($bad|Where-Object {$_.StartsWith("MISSING-IN-SOURCE`t")}).Count
 $summary.Verify=[ordered]@{FilesMatched=$vf;GiBMatched=[math]::Round($vb/1GB,2);Differences=($bad.Count-$onlyInMirror);MissingInMirror=@($bad|Where-Object {$_.StartsWith("MISSING-IN-MIRROR`t")}).Count;OnlyInMirror=$onlyInMirror}
 # What a later -Repair works from: the lines that name a file of the source. Files only in the
 # copy are left out; a repair never touches them. Each check replaces the record of the one before.
 [ordered]@{Checked=(Get-Date).ToString('o');Source=$src;Destination=$dst;RunFolder=$run;Files=@($bad|Where-Object {-not $_.StartsWith("MISSING-IN-SOURCE`t")})}|ConvertTo-Json -Depth 3|Set-Content -LiteralPath $lastCheck
}

# --- Names robocopy treats differently from what the lists say -----------------------------------------
# Two warnings; nothing is copied differently because of them, and neither is a copy error.
# SkippedByShortName: robocopy compares a wildcard name with the short (8.3) name of a file or folder
# too, so *.htm from Exclude also skips page.html, whose short name is PAGE~1.HTM. Only the personal
# names can do that (no short name fits a built-in one), and only where the drive gives short names:
# NTFS and FAT do, a Dev Drive (ReFS) does not.
# CaseCollisions: a folder that keeps letter case apart can hold Makefile and makefile; the backup
# drive holds one file for both, so one of them is not really in the copy.
# Both come from one pass over the names in the selected folders (no file is read), after a backup
# and in a content check. The summary holds the first 100 of each and the count of all; every one is
# in a file in the run folder.
$summary.SkippedByShortName=@();$summary.SkippedByShortNameCount=0;$summary.CaseCollisions=@();$summary.CaseCollisionsCount=0
if(-not $Repair){
 Add-Type -Path (Join-Path $PSScriptRoot 'Backup.MirrorVerifier.cs')
 $shortFs=try{[IO.DriveInfo]::new($src.Substring(0,3)).DriveFormat -in 'NTFS','FAT','FAT32'}catch{$true}
 $shortNames=[string[]]@(if($shortFs){$personalNames|Where-Object {$_ -match '[*?~]'}})
 $seen=@([MirrorVerifier]::Survey($src,$rulePaths,$ruleOn,$ruleDefault,[string[]]$skipNames,[string[]]$personalNames,[string[]]$skipPaths,$ruleRoots,$shortNames))
 $short=@($seen|Where-Object {$_.StartsWith("SHORT`t")}|ForEach-Object {$_.Substring(6)})
 $case=@($seen|Where-Object {$_.StartsWith("CASE`t")}|ForEach-Object {$_.Substring(5).Replace("`t",' | ')})
 if($short.Count){[IO.File]::WriteAllLines((Join-Path $run 'skipped-by-short-name.txt'),[string[]]$short)}
 if($case.Count){[IO.File]::WriteAllLines((Join-Path $run 'case-collisions.txt'),[string[]]$case)}
 $summary.SkippedByShortName=@($short|Select-Object -First 100|ForEach-Object {$_.Split("`t")[0]});$summary.SkippedByShortNameCount=$short.Count
 $summary.CaseCollisions=@($case|Select-Object -First 100);$summary.CaseCollisionsCount=$case.Count
}

$summary.Finished=(Get-Date).ToString('o')
$summary.Minutes=[math]::Round(((Get-Date)-$started).TotalMinutes,1)
$summary.RunFolder=$run
$summary|ConvertTo-Json -Depth 6|Set-Content -LiteralPath (Join-Path $run 'summary.json')
# A selected folder that is missing or became a link was not copied, so the run fails, as the versioned
# backup does. A content check only reads, and a repair copies single files; neither marks the copy
# as complete.
$notCopied=@(@($summary.SelectionsMissing|ForEach-Object {"$_ (missing)"})+@($summary.SelectionsSkippedAsLinks|ForEach-Object {"$_ (now a link or junction)"}))
if(-not $noCopy -and $summary.CopyErrors -eq 0 -and -not $notCopied.Count -and (-not $Verify -or $summary.Verify.Differences -eq 0)){
 Copy-Item -LiteralPath (Join-Path $run 'summary.json') -Destination $lastSuccess -Force
}
if($notCopied.Count){throw ('Selected folders were not copied: '+($notCopied -join ', ')+'. Choose them again on What to back up, or set them to Skip. Details: '+(Join-Path $run 'summary.json'))}
$summary|ConvertTo-Json -Depth 6
# A repair that left a file unrepaired ends with an error code, after the summary, so the caller sees both.
if($Repair -and $summary.CopyErrors -gt 0){exit 1}
