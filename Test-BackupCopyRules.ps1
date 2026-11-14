#Requires -Version 7.2
# Plain copy rules that need no backup drive: the content check (Backup.MirrorVerifier.cs) on two
# disposable folders, the drive identity check of Invoke-FastMirror.ps1, and how DevDriveBackup names
# plain copy folders and saves job files (DevDriveBackup.Data.psm1). Everything lives in one disposable
# folder under the temporary folder and is removed at the end.
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'Backup.Selection.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'DevDriveBackup.Data.psm1') -Force
Add-Type -Path (Join-Path $PSScriptRoot 'Backup.MirrorVerifier.cs')
function Assert($ok,$message){if(-not $ok){throw "FAIL $message"};Write-Output ('PASS '+$message)}
function Throws([scriptblock]$Block,[string]$Pattern){try{& $Block|Out-Null;$false}catch{$_.Exception.Message -match $Pattern}}
$root=Join-Path ([IO.Path]::GetTempPath()) ('dev-drive-backup-copy-rules-'+[guid]::NewGuid().ToString('N'))
function Put([string]$Path,[string]$Text){New-Item -ItemType Directory -Path (Split-Path $Path) -Force|Out-Null;[IO.File]::WriteAllText($Path,$Text)}
try{
 # --- Private folders: a selection that is one of them, or lies inside one, is never copied ----
 $keys='C:\Users\YOUR_USER\DevDriveBackup recovery keys'
 Assert (Test-BackupPathInside $keys @($keys)) 'a selection that is the private folder itself counts as private'
 Assert (Test-BackupPathInside ($keys+'\old') @($keys)) 'a folder inside a private folder counts as private'
 Assert (Test-BackupPathInside 'c:\users\your_user\appdata\local\devdrivemirror\' @('C:\Users\YOUR_USER\AppData\Local\DevDriveMirror')) 'case and a trailing backslash do not matter'
 Assert (Test-BackupPathInside 'D:\Safe\recovery-key.txt' @('C:\Elsewhere','D:\Safe\recovery-key.txt')) 'a key file selected on its own counts as private'
 Assert (-not (Test-BackupPathInside ($keys+' 2') @($keys))) 'a folder whose name only starts the same is not private'
 Assert (-not (Test-BackupPathInside 'C:\Users\YOUR_USER' @($keys))) 'a parent folder is copied (robocopy skips the private folder below it)'
 Assert (-not (Test-BackupPathInside 'C:\Users\YOUR_USER\Projects' @('',$null))) 'empty private paths are ignored'

 # --- Content check ----------------------------------------------------------------------
 $src=Join-Path $root 'source';$dst=Join-Path $root 'mirror'
 foreach($f in 'work\same.txt','work\changed.txt','work\resized.txt','work\not-copied.txt','work\node_modules\x.js','work\build\cache\c.bin','work\notes.secret','private\keys\k.txt','skipped\s.txt'){Put (Join-Path $src $f) $f}
 foreach($f in 'work\same.txt','work\changed.txt','work\resized.txt','work\deleted.txt','work\build\cache\old.bin'){Put (Join-Path $dst $f) $f}
 [IO.File]::WriteAllText((Join-Path $dst 'work\changed.txt'),'work\changed.tXt');[IO.File]::WriteAllText((Join-Path $dst 'work\resized.txt'),'longer than the source')
 $config=[pscustomobject]@{DefaultMode='Mirror';NeverBackUp=@('private');Choices=@([pscustomobject]@{Path='private\keys';Mode='Both'},[pscustomobject]@{Path='skipped';Mode='Skip'})}
 $sel=Get-BackupSelection $config
 $paths=[string[]]@($sel.Entries|ForEach-Object {$_.Path});$on=[bool[]]@($sel.Entries|ForEach-Object {Test-BackupModeIncludes $_.Mode 'Mirror'})
 $vf=[long]0;$vb=[long]0
 $bad=@([MirrorVerifier]::Compare($dst,$src+'\',2,$paths,$on,$true,[string[]]@('node_modules'),[string[]]@('*.secret'),[string[]]@('work\build\cache'),[ref]$vf,[ref]$vb))
 Assert ('MISSING-IN-MIRROR'+"`t"+'work\not-copied.txt' -in $bad) 'a selected source file missing from the copy is a difference'
 Assert (("CONTENT`twork\changed.txt" -in $bad) -and ("SIZE`twork\resized.txt" -in $bad) -and $vf -eq 1) 'changed content and size are differences; only the identical file counts as matched'
 Assert ("MISSING-IN-SOURCE`twork\deleted.txt" -in $bad) 'a file only in the copy is listed'
 Assert (-not @($bad|Where-Object {$_ -match 'node_modules|notes\.secret|build\\cache|private|skipped'}).Count) 'skipped names, personal names, Exclude paths, NeverBackUp (with a choice inside it) and Skip folders are not checked on either side'
 Assert ($bad.Count -eq 4) ('exactly four findings ('+($bad -join '; ')+')')
 # A source with no subfolders listed follows DefaultMode; the empty list must work under strict mode.
 $empty=Get-BackupSelection ([pscustomobject]@{DefaultMode='Mirror';Choices=@()})
 $ep=[string[]]@($empty.Entries|ForEach-Object {$_.Path});$eo=[bool[]]@($empty.Entries|ForEach-Object {Test-BackupModeIncludes $_.Mode 'Mirror'})
 Put (Join-Path $root 'flat\a.txt') 'a';Put (Join-Path $root 'flat-copy\a.txt') 'a'
 $bad=@([MirrorVerifier]::Compare((Join-Path $root 'flat-copy'),(Join-Path $root 'flat'),2,$ep,$eo,$true,[string[]]@(),[string[]]@(),[string[]]@(),[ref]$vf,[ref]$vb))
 Assert ($bad.Count -eq 0 -and $vf -eq 1) 'a source with no subfolders listed is checked in full'

 # --- Repair of single files: the same rules, one path at a time ---------------------------------
 $rec=Join-Path $root 'recovery';Put (Join-Path $root 'outside.txt') 'outside the copy'
 $left=@('work\node_modules\x.js','work\build\cache\c.bin','work\notes.secret','private\keys\k.txt','skipped\s.txt','work\deleted.txt','..\outside.txt','work\..\..\outside.txt',(Join-Path $root 'outside.txt'))
 $done=@([MirrorVerifier]::Repair($dst,$src+'\',$rec,2,[string[]]@(@('work\changed.txt','work\resized.txt','work\not-copied.txt','work\same.txt')+$left),$paths,$on,$true,[string[]]@('node_modules'),[string[]]@('*.secret'),[string[]]@('work\build\cache'),[string[]]@()))
 $what={param($rel)(@($done|Where-Object {$_.Split("`t")[1] -eq $rel})[0]).Split("`t")[0]}
 Assert ((& $what 'work\changed.txt') -eq 'REPAIRED' -and (& $what 'work\resized.txt') -eq 'REPAIRED' -and (& $what 'work\not-copied.txt') -eq 'REPAIRED' -and (& $what 'work\same.txt') -eq 'MATCHES') 'a repair copies again the files that differ or are missing, and leaves a matching file alone'
 Assert (@($left|Where-Object {(& $what $_) -ne 'SKIPPED'}).Count -eq 0) 'it leaves alone skipped names, personal names, Exclude paths, NeverBackUp and Skip folders, files only in the copy, and paths that lead out of the copy'
 Assert ((@(Get-ChildItem -LiteralPath $rec -Recurse -File|ForEach-Object {$_.FullName.Substring($rec.Length+1)}|Sort-Object) -join '|') -eq 'work\changed.txt|work\resized.txt' -and [IO.File]::ReadAllText((Join-Path $rec 'work\changed.txt')) -ceq 'work\changed.tXt') 'the old versions are in the recovery folder, and nothing else is'
 Assert (-not(Test-Path -LiteralPath (Join-Path $dst 'work\node_modules')) -and -not(Test-Path -LiteralPath (Join-Path $dst 'private')) -and [IO.File]::ReadAllText((Join-Path $root 'outside.txt')) -eq 'outside the copy' -and @(Get-ChildItem -LiteralPath (Join-Path $dst 'work') -File).Count -eq 5) 'nothing else was written, and no working file is left'
 $bad=@([MirrorVerifier]::Compare($dst,$src+'\',2,$paths,$on,$true,[string[]]@('node_modules'),[string[]]@('*.secret'),[string[]]@('work\build\cache'),[ref]$vf,[ref]$vb))
 Assert (($bad -join '|') -eq "MISSING-IN-SOURCE`twork\deleted.txt" -and $vf -eq 4) 'after the repair the content check finds only the file that is only in the copy'

 # --- Files gone from the source (robocopy /MT listing) --------------------------------------
 # Line shapes seen in a real /MT log: a record's path on the next line, a path followed by the
 # next record, two records on one line, and an error line that names a folder that is not extra.
 $m='G:\Mirror'
 $log=@(
  "`t  *EXTRA File `t`t     251`tG:\Mirror\a\plain.txt",
  "`t  *EXTRA File `t`t     251`tG:\Mirror\a\first.cmd`t*EXTRA Dir        -1`tG:\Mirror\b\dir\",
  "`t  *EXTRA File `t`t    1382`t",
  "G:\Mirror\c\own-line.py`t  *EXTRA File `t`t    2930`tG:\Mirror\c\after.tsx",
  "`t*EXTRA Dir        -1`tG:\Mirror\d\`t  *EXTRA File `t`t 4`tG:\Mirror\d\G:\Mirror\e\glued.txt",
  '2026/11/06 17:34:00 ERROR 5 (0x00000005) Scanning Destination Directory G:\Mirror\locked\',
  'Access is denied.',
  "`t  *EXTRA File `t`t     9`tG:\Mirror-recovery\elsewhere.txt",
  '')
 $found=@(Get-RoboExtraPaths $log $m|Sort-Object -Unique)
 $want=@('G:\Mirror\a\first.cmd','G:\Mirror\a\plain.txt','G:\Mirror\b\dir\','G:\Mirror\c\after.tsx','G:\Mirror\c\own-line.py','G:\Mirror\d\','G:\Mirror\e\glued.txt')
 Assert (($found -join '|') -eq (($want|Sort-Object) -join '|')) 'every extra in a /MT listing is found, split lines included'
 Assert ('G:\Mirror\locked\' -notin $found) 'a folder named on an error line is not an extra'
 Assert ('G:\Mirror-recovery\elsewhere.txt' -notin $found) 'a path beside the mirror folder is not an extra'
 # Also seen: a record that names a source path, followed at once by one that names a path in the copy
 # (and the reverse). Both paths must come out whole, each for its own side.
 $glued=@("`t  *MISMATCH   `t`t      15`tE:\Src\swap2\yG:\Mirror\swap\x","`t  *EXTRA File `t`t       4`tg:\mirror\f\zE:\Src\q\w\","`t    New File  `t`t      17`tE:\Src\swap\x\new.txt")
 Assert ((@(Get-RoboExtraPaths $glued 'G:\Mirror' 'E:\Src\'|Sort-Object) -join '|') -eq 'g:\mirror\f\z|G:\Mirror\swap\x') 'a path in the copy glued to a source path is still found whole'
 Assert ((@(Get-RoboExtraPaths $glued 'E:\Src\' @('G:\Mirror','')|Sort-Object) -join '|') -eq 'E:\Src\q\w\|E:\Src\swap\x\new.txt|E:\Src\swap2\y') 'and so is the source path'
 Assert ((@(Get-RoboExtraPaths @("`t  *EXTRA File `t`t 1`tG:\x\a.txtE:\y\b.txt") 'G:\' 'E:\') -join '|') -eq 'G:\x\a.txt') 'also when both sides are drive roots'

 # --- Drive identity -----------------------------------------------------------------------
 $letter=$src.Substring(0,1)
 $other=@(Get-Volume|Where-Object {$_.DriveLetter -and [string]$_.DriveLetter -ne $letter -and $_.FileSystem}|Select-Object -First 1)
 if($other.Count){
  $job=Join-Path $root 'job.json'
  [pscustomobject]@{Source=$src+'\';SourceVolumeId=(Get-Volume -DriveLetter $letter).UniqueId;DestinationVolumeId='not-this-drive';DefaultMode='Mirror';Choices=@()}|ConvertTo-Json|Set-Content -LiteralPath $job
  # This runs the real tool against a real drive and relies on the very check it tests. So it only
  # asks for a content check, which never creates a copy, and keeps the run records in the disposable
  # folder: if the check ever let the drive through, nothing would be written to that drive or to
  # the real state folder.
  $realState=$env:LOCALAPPDATA;$env:LOCALAPPDATA=Join-Path $root 'state'
  try{Assert (Throws {& (Join-Path $PSScriptRoot 'Invoke-FastMirror.ps1') -ConfigPath $job -DestinationDrive ([string]$other[0].DriveLetter) -Folder 'never-created' -VerifyOnly} 'not the backup drive') 'the plain copy refuses a drive that is not the one in the job'}
  finally{$env:LOCALAPPDATA=$realState}
  Assert (-not(Test-Path -LiteralPath ([string]$other[0].DriveLetter+':\never-created')) -and -not(Test-Path -LiteralPath (Join-Path $root 'state'))) 'nothing was created on that drive, and no run was recorded'
 }else{Write-Output 'SKIP drive identity: this computer has only one lettered volume'}

 # --- Plain copy folder names and job files ------------------------------------------------
 [void](Set-CenterPaths (Join-Path $root 'center'))
 $data=[pscustomobject]@{Version=1;Profiles=@()}
 $p=New-CenterProfile $data 'Test' 'volume-not-connected'
 foreach($f in 'one\app','two\app'){New-Item -ItemType Directory -Path (Join-Path $root $f) -Force|Out-Null}
 $a=Add-CenterSource -Data $data -ProfileId $p.Id -Path (Join-Path $root 'one\app')
 $b=Add-CenterSource -Data $data -ProfileId $p.Id -Path (Join-Path $root 'two\app')
 Assert ($a.Label -eq $b.Label -and $a.MirrorFolder -ne $b.MirrorFolder) 'two folders with the same name get separate plain copy folders'
 Assert ((Read-CenterJob $a.ConfigPath).MirrorFolder -eq $a.MirrorFolder) 'the job file records its plain copy folder'
 Remove-CenterSource $data $p.Id $a.Id
 $again=Add-CenterSource -Data $data -ProfileId $p.Id -Path (Join-Path $root 'one\app')
 Assert ($again.ConfigPath -eq $a.ConfigPath -and $again.MirrorFolder -eq $a.MirrorFolder) 'adding a folder again adopts its job file and its own plain copy folder'
 Remove-CenterSource $data $p.Id $again.Id;Remove-CenterSource $data $p.Id $b.Id
 $c=Add-CenterSource -Data $data -ProfileId $p.Id -Path (Join-Path $root 'two\app') -MirrorFolder $a.MirrorFolder
 Assert (Throws {Add-CenterSource -Data $data -ProfileId $p.Id -Path (Join-Path $root 'one\app') -MirrorFolder $a.MirrorFolder} 'already used') 'a plain copy folder another source uses is refused'
 $adopted=Add-CenterSource -Data $data -ProfileId $p.Id -Path (Join-Path $root 'one\app')
 Assert ($adopted.ConfigPath -eq $a.ConfigPath -and $adopted.MirrorFolder -ne $c.MirrorFolder) 'an adopted job whose folder name is now used by another source gets a new one'

 # A removed source keeps its copy and versions on the drive, so another folder with the same name,
 # added while the drive is unplugged, must not get its folders.
 $q=New-CenterProfile $data 'Test 2' 'volume-not-connected-2'
 foreach($f in 'three\work','four\work'){New-Item -ItemType Directory -Path (Join-Path $root $f) -Force|Out-Null}
 $x=Add-CenterSource -Data $data -ProfileId $q.Id -Path (Join-Path $root 'three\work')
 Remove-CenterSource $data $q.Id $x.Id
 $y=Add-CenterSource -Data $data -ProfileId $q.Id -Path (Join-Path $root 'four\work')
 $xJob=Read-CenterJob $x.ConfigPath;$yJob=Read-CenterJob $y.ConfigPath
 Assert ($y.MirrorFolder -ne $x.MirrorFolder -and $yJob.RepositoryFolder -ne $xJob.RepositoryFolder) 'a new folder never gets the plain copy or versions folder of a removed source'
 $back=Add-CenterSource -Data $data -ProfileId $q.Id -Path (Join-Path $root 'three\work')
 Assert ($back.ConfigPath -eq $x.ConfigPath -and $back.MirrorFolder -eq $x.MirrorFolder) 'the removed folder added again still gets its own job and folders back'
 # Before this rule, a new source could already share a removed source's repository. Adding the removed
 # folder again must then start fresh instead of a second source writing to the same repository.
 Remove-CenterSource $data $q.Id $back.Id
 $yJob.RepositoryFolder=$xJob.RepositoryFolder;[IO.File]::WriteAllText($y.ConfigPath,($yJob|ConvertTo-Json -Depth 8))
 $fresh2=Add-CenterSource -Data $data -ProfileId $q.Id -Path (Join-Path $root 'three\work')
 Assert ($fresh2.ConfigPath -ne $x.ConfigPath -and (Read-CenterJob $fresh2.ConfigPath).RepositoryFolder -ne $xJob.RepositoryFolder) 'a job whose repository another source uses now is not adopted'

 # Saving a job never reverts a recovery-key location written meanwhile (by a password change).
 $stale=Read-CenterJob $c.ConfigPath
 $fresh=Read-CenterJob $c.ConfigPath;$fresh.RecoveryKeyPath=$fresh.RecoveryKeyPath+'.new';[IO.File]::WriteAllText($c.ConfigPath,($fresh|ConvertTo-Json -Depth 8))
 $stale.DefaultMode='Skip';Save-CenterJob $stale $c.ConfigPath
 $saved=Read-CenterJob $c.ConfigPath
 Assert ($saved.DefaultMode -eq 'Skip' -and $saved.RecoveryKeyPath -eq $fresh.RecoveryKeyPath) 'saving a job keeps the recovery-key location saved meanwhile'
 $load=[pscustomobject]@{Name='Strong';CpuThreads=2;MemoryMiB=1024;ReadConcurrency=2;Priority='Normal'}
 $lock=[IO.File]::Open([IO.Path]::GetFullPath($saved.PasswordDpapiPath)+'.run.lock',[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
 try{Assert (Throws {Sync-CenterJob $p $c $load} 'busy') 'a job in use by a running backup is not rewritten'}finally{$lock.Dispose()}
 Sync-CenterJob $p $c $load
 $synced=Read-CenterJob $c.ConfigPath
 Assert ($synced.Profile -eq 'Strong' -and $synced.MirrorFolder -eq $c.MirrorFolder -and $synced.RecoveryKeyPath -eq $fresh.RecoveryKeyPath -and $synced.DefaultMode -eq 'Skip') 'syncing a job changes only the load, drive and plain copy folder'
}finally{
 [void](Set-CenterPaths '')
 if(Test-Path -LiteralPath $root){Remove-Item -LiteralPath $root -Recurse -Force}
}
