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
# Backup Center's own password, key and state folders are never copied.
param(
 [string]$ConfigPath=(Join-Path $PSScriptRoot 'backup.local.json'),
 [string]$Source,
 [Parameter(Mandatory)][ValidatePattern('^[A-Za-z]$')][string]$DestinationDrive,
 # One folder name, or two separated by a backslash (for example Drive-C-Mirror\Projects).
 [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]{0,79}(\\[A-Za-z0-9][A-Za-z0-9._-]{0,79})?$')][string]$Folder='DevDrive-Mirror',
 [ValidateRange(1,64)][int]$Threads=16,
 [switch]$MoveExtras,
 # With -MoveExtras: keep only this many dated recovery folders (the newest) and delete older
 # ones from the backup drive. 0 keeps every recovery folder.
 [ValidateRange(0,100)][int]$KeepRecovery=0,
 [switch]$Verify,
 [switch]$SkipVerify,
 # Compare the mirror with the source without copying anything.
 [switch]$VerifyOnly
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
$srcRoot=[IO.Path]::GetFullPath($(if($Source){$Source}else{[string]$config.Source})).TrimEnd('\')+'\'
foreach($entry in @(if($config.PSObject.Properties['Exclude']){$config.Exclude})){
 $e=([string]$entry).Trim();if(-not $e){continue}
 if($e -notmatch '[\\/]'){if($e -notin $skipNames){$skipNames+=$e;$personalNames+=$e};continue}
 $e=$e.Replace('/','\').TrimEnd('\')
 if($e -match '^[A-Za-z]:\\'){
  if(-not $e.StartsWith($srcRoot,[StringComparison]::OrdinalIgnoreCase)){continue}  # belongs to another source
  $e=$e.Substring($srcRoot.Length)
 }
 if($e){$skipPaths+=$e.TrimStart('\')}
}
# Backup Center's private folders (protected passwords, run state, plaintext recovery keys) are never
# copied, whatever the selection: the copy would not keep their private permissions. The job's own key
# files count too, in case the configuration keeps them somewhere else.
$privatePaths=@((Join-Path $env:LOCALAPPDATA 'DevDriveMirror'),(Join-Path $env:USERPROFILE 'Backup Center recovery keys'))+@('PasswordDpapiPath','RecoveryKeyPath'|Where-Object {$config.PSObject.Properties[$_] -and $config.$_}|ForEach-Object {[string]$config.$_})
foreach($p in @($privatePaths|ForEach-Object {[IO.Path]::GetFullPath($_).TrimEnd('\')})){
 if($srcRoot.StartsWith($p+'\',[StringComparison]::OrdinalIgnoreCase)){throw "The source is inside $p, which holds Backup Center's passwords and recovery keys and is never copied"}
 if($p.StartsWith($srcRoot,[StringComparison]::OrdinalIgnoreCase)){$skipPaths+=$p.Substring($srcRoot.Length)}
}

$src=[IO.Path]::GetFullPath($Source).TrimEnd('\')+'\'
$srcVolume=Get-Volume -DriveLetter $src.Substring(0,1)
$dstVolume=Get-Volume -DriveLetter $DestinationDrive
if($srcVolume.UniqueId -eq $dstVolume.UniqueId){throw 'Destination is the source volume'}
# The copy goes only to the backup drive this configuration was made for, not another drive that took its letter.
if($config.PSObject.Properties['DestinationVolumeId'] -and $config.DestinationVolumeId -and $dstVolume.UniqueId -ne $config.DestinationVolumeId){throw "Drive $($DestinationDrive.ToUpperInvariant()): is not the backup drive this configuration was made for (its volume identity differs). Check which drive has this letter now."}
# The configured source must still be the same volume, not another drive that took its letter.
$configured=if($config.PSObject.Properties['Source'] -and $config.Source){[IO.Path]::GetFullPath([string]$config.Source).TrimEnd('\')+'\'}else{''}
if($config.PSObject.Properties['SourceVolumeId'] -and $config.SourceVolumeId -and $configured -and $src.StartsWith($configured,[StringComparison]::OrdinalIgnoreCase) -and $srcVolume.UniqueId -ne $config.SourceVolumeId){throw 'The source drive is not the one this configuration was made for (its volume identity changed). Check which drive has this letter now.'}
$sourceDisk=Get-Partition -DriveLetter $src.Substring(0,1)|Get-Disk
$destDisk=Get-Partition -DriveLetter $DestinationDrive|Get-Disk
if($sourceDisk.Number -eq $destDisk.Number){throw 'Destination is on the same physical disk as the source'}
if($sourceDisk.BusType -eq 'File Backed Virtual' -and $sourceDisk.Location -match '^([A-Za-z]):\\'){
 if((Get-Partition -DriveLetter $Matches[1]|Get-Disk).Number -eq $destDisk.Number){throw 'Destination is on the disk that holds the Dev Drive file'}
}
$dst=$DestinationDrive.ToUpperInvariant()+':\'+$Folder
$recoveryRoot=$DestinationDrive.ToUpperInvariant()+':\'+$Folder+'-recovery'
$run=Join-Path $env:LOCALAPPDATA ('DevDriveMirror\fast-mirror\'+(Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Path $run -Force|Out-Null
# A content check compares an existing copy; it never creates one.
if($VerifyOnly){if(-not(Test-Path -LiteralPath $dst -PathType Container)){throw "There is no plain copy at $dst to check. Back up first."}}else{New-Item -ItemType Directory -Path $dst -Force|Out-Null}
# Keyed by the drive's volume identity, so another drive that takes this letter still gets its first full check.
$lastSuccess=Join-Path $env:LOCALAPPDATA ('DevDriveMirror\fast-mirror\last-success-'+($dstVolume.UniqueId -replace '[^A-Za-z0-9-]+','_').Trim('_')+'-'+($Folder -replace '\\','_')+'.json')
$firstRun=-not(Test-Path -LiteralPath $lastSuccess)
if(($firstRun -and -not $SkipVerify) -or $VerifyOnly){$Verify=$true}

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
 & robocopy.exe @RoboArgs|Out-Null
 $code=$LASTEXITCODE
 if($code -ge 16){throw "robocopy $Label failed with exit code $code. See $($RoboArgs|Where-Object {$_ -like '/UNILOG:*'})"}
 $code
}
function Get-RoboTotals([string]$Log){
 # The summary rows (directories, files, bytes) each hold six numbers: total, copied, skipped,
 # mismatch, failed, extras. Reading the numbers rather than the labels also works on Windows
 # in other languages.
 $rows=@(Get-Content -LiteralPath $Log -Encoding Unicode -Tail 14|ForEach-Object {
  $m=[regex]::Match($_,'^\s*[^\d\s][^:]*:\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s*$')
  if($m.Success){,@(1..6|ForEach-Object {[long]$m.Groups[$_].Value})}
 })
 if($rows.Count -lt 3){return $null}
 [pscustomobject]@{Dirs=$rows[0];Files=$rows[1];Bytes=$rows[2]}
}
function Get-LogName([string]$Relative){'copy-'+$(if($Relative){$Relative -replace '[\\/:*?"<>|]','_'}else{'main'})+'.log'}

$started=Get-Date
$summary=[ordered]@{Source=$src;Destination=$dst;Started=$started.ToString('o');DefaultMode=$selection.DefaultMode;Selected=@($regions|ForEach-Object {if($_.Path){$_.Path}else{'(source root)'}});Runs=@();SelectionsMissing=@();SelectionsSkippedAsLinks=@()}
$copied=@()
foreach($region in $regions){
 $from=Join-Rel $src $region.Path;$to=Join-Rel $dst $region.Path
 if(-not(Test-Path -LiteralPath $from)){$summary.SelectionsMissing+=$region.Path;continue}
 $item=Get-Item -LiteralPath $from -Force
 if($region.Path -and ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)){$summary.SelectionsSkippedAsLinks+=$region.Path;continue}
 $log=Join-Path $run (Get-LogName $region.Path)
 if($item.PSIsContainer){$a=@(Get-RoboArgs $from $to $log $region.Excluded)}
 else{
  # A single file selected on its own (for example README.md at the drive root).
  $a=@((Format-RoboDir (Split-Path -LiteralPath $from)),(Split-Path -LiteralPath $to),$item.Name,'/COPY:DAT','/R:1','/W:1','/NP','/FP','/BYTES',('/UNILOG:'+$log))
 }
 $part=if($region.Path){$region.Path}else{'main'}
 if(-not $VerifyOnly){$summary.Runs+=[ordered]@{Part=$part;ExitCode=(Invoke-Robo $a $part);Log=$log}}
 $copied+=[pscustomobject]@{Region=$region;IsFolder=$item.PSIsContainer}
}
if($copied.Count -eq 0){throw ('None of the selected paths exist under '+$src+': '+($summary.Selected -join ', '))}
# robocopy gives a folder copied from a drive root the root's hidden/system attributes.
if(-not $VerifyOnly){& attrib.exe -s -h $dst|Out-Null}

# Files in the mirror that are gone from the source: list them, and optionally move them aside.
$extras=@()
foreach($c in @($copied|Where-Object {$_.IsFolder -and -not $VerifyOnly})){
 $extrasLog=Join-Path $run ('extras-'+(Get-LogName $c.Region.Path).Substring(5))
 # Directory names must be listed here (no /NDL) so extra directories are reported too.
 & robocopy.exe @(@(Get-RoboArgs (Join-Rel $src $c.Region.Path) (Join-Rel $dst $c.Region.Path) $extrasLog $c.Region.Excluded @('/L','/PURGE','/NJH','/NJS'))|Where-Object {$_ -ne '/NDL'})|Out-Null
 # With /MT, robocopy's records can be split over lines or share one; see Get-RoboExtraPaths.
 $extras+=@(Get-RoboExtraPaths (Get-Content -LiteralPath $extrasLog -Encoding Unicode) $dst)
}
# Only selected paths count as extras; old copies of unselected folders are reported separately below.
# A path that still exists in the source is never an extra, whatever the log seems to say.
$extras=@($extras|Sort-Object -Unique|Where-Object {
 $rel=$_.Substring($dst.Length).Trim('\')
 $rel -and (Test-BackupModeIncludes (Get-BackupMode $selection $rel) 'Mirror') -and -not(Test-Path -LiteralPath (Join-Rel $src $rel))
})
$summary.ExtrasFound=$extras.Count
# Files are moved aside only after a copy that could read the source: a run where robocopy failed
# (exit code 8 or more) may have missed files that still exist, so its extras are only reported.
$copyFailed=@($summary.Runs|Where-Object {$_.ExitCode -ge 8}).Count -gt 0
if($MoveExtras -and $copyFailed){$summary.ExtrasNotMovedReason='Some files could not be copied in this run, so nothing was moved aside'}
if($MoveExtras -and $extras.Count -and -not $VerifyOnly -and -not $copyFailed){
 $stamp=Join-Path $recoveryRoot (Get-Date -Format 'yyyyMMdd-HHmmss')
 foreach($item in $extras){
  if(-not(Test-Path -LiteralPath $item)){continue}
  $relative=$item.Substring($dst.Length).TrimStart('\')
  # Checked again here: a file put back in the source while earlier items were moved stays in the copy.
  if(Test-Path -LiteralPath (Join-Rel $src $relative.TrimEnd('\'))){continue}
  $target=Join-Path $stamp $relative
  New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($target.TrimEnd('\'))) -Force|Out-Null
  Move-Item -LiteralPath $item -Destination $target
 }
 $summary.ExtrasMovedTo=$stamp
 $summary.ExtrasMoved=$extras.Count
}
# Old recovery folders: keep the newest KeepRecovery, delete the rest. Only folders this script
# names (yyyyMMdd-HHmmss) directly inside the recovery root are touched.
$summary.RecoveryRemoved=@()
if($MoveExtras -and $KeepRecovery -gt 0 -and -not $VerifyOnly -and (Test-Path -LiteralPath $recoveryRoot -PathType Container)){
 $dated=@(Get-ChildItem -LiteralPath $recoveryRoot -Directory -Force|Where-Object {$_.Name -match '^\d{8}-\d{6}$' -and -not($_.Attributes -band [IO.FileAttributes]::ReparsePoint)}|Sort-Object Name -Descending)
 foreach($old in @($dated|Select-Object -Skip $KeepRecovery)){
  Remove-Item -LiteralPath $old.FullName -Recurse -Force
  $summary.RecoveryRemoved+=$old.Name
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
$errors=@($summary.Runs|ForEach-Object {Get-Content -LiteralPath $_.Log -Encoding Unicode|Where-Object {$_ -match '\sERROR \d+ ' -or $_ -match '\*MISMATCH'}})
[IO.File]::WriteAllLines((Join-Path $run 'copy-errors.txt'),[string[]]$errors)
$failed=[long]0
foreach($r in $summary.Runs){
 $t=Get-RoboTotals $r.Log
 if($t){
  $r.Files='Files : '+($t.Files -join ' ');$r.Bytes='Bytes : '+($t.Bytes -join ' ')
  # Mismatch (a folder in the source where the copy has a file of that name, or the reverse): robocopy
  # copies nothing there and still exits below 8, so it counts as not copied, like a failed file.
  $failed+=$t.Files[3]+$t.Files[4]+$t.Dirs[3]+$t.Dirs[4]
 }else{$r.Files='';$r.Bytes='';if($r.ExitCode -ge 8 -or ($r.ExitCode -band 4)){$failed+=1}}
}
$summary.CopyErrors=$failed

if($Verify){
 Add-Type -Path (Join-Path $PSScriptRoot 'Backup.MirrorVerifier.cs')
 $vf=[long]0;$vb=[long]0
 # ForEach-Object rather than $selection.Entries.Path: under strict mode an empty list (a source
 # with no subfolders listed) has no Path property.
 $paths=[string[]]@($selection.Entries|ForEach-Object {$_.Path})
 $on=[bool[]]@($selection.Entries|ForEach-Object {Test-BackupModeIncludes $_.Mode 'Mirror'})
 # The same skips as the copy: names, personal names (files too), Exclude paths and the private folders.
 $bad=[MirrorVerifier]::Compare($dst,$src,[math]::Min(8,[Environment]::ProcessorCount),$paths,$on,(Test-BackupModeIncludes $selection.DefaultMode 'Mirror'),[string[]]$skipNames,[string[]]$personalNames,[string[]]$skipPaths,[ref]$vf,[ref]$vb)
 [IO.File]::WriteAllLines((Join-Path $run 'verify-differences.txt'),[string[]]$bad)
 # Files only in the mirror (deleted from the source, or now skipped) are expected in a copy that
 # never deletes; they are reported, but are not differences. Selected files missing from the mirror are.
 $onlyInMirror=@($bad|Where-Object {$_.StartsWith("MISSING-IN-SOURCE`t")}).Count
 $summary.Verify=[ordered]@{FilesMatched=$vf;GiBMatched=[math]::Round($vb/1GB,2);Differences=($bad.Count-$onlyInMirror);MissingInMirror=@($bad|Where-Object {$_.StartsWith("MISSING-IN-MIRROR`t")}).Count;OnlyInMirror=$onlyInMirror}
}

$summary.Finished=(Get-Date).ToString('o')
$summary.Minutes=[math]::Round(((Get-Date)-$started).TotalMinutes,1)
$summary.RunFolder=$run
$summary|ConvertTo-Json -Depth 6|Set-Content -LiteralPath (Join-Path $run 'summary.json')
# A selected folder that is missing or became a link was not copied, so the run fails, as the versioned
# backup does. A content check only reads; it never marks the copy as complete.
$notCopied=@(@($summary.SelectionsMissing|ForEach-Object {"$_ (missing)"})+@($summary.SelectionsSkippedAsLinks|ForEach-Object {"$_ (now a link or junction)"}))
if(-not $VerifyOnly -and $summary.CopyErrors -eq 0 -and -not $notCopied.Count -and (-not $Verify -or $summary.Verify.Differences -eq 0)){
 Copy-Item -LiteralPath (Join-Path $run 'summary.json') -Destination $lastSuccess -Force
}
if($notCopied.Count){throw ('Selected folders were not copied: '+($notCopied -join ', ')+'. Choose them again on What to back up, or set them to Skip. Details: '+(Join-Path $run 'summary.json'))}
$summary|ConvertTo-Json -Depth 6
