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

 # --- Drive identity -----------------------------------------------------------------------
 $letter=$src.Substring(0,1)
 $other=@(Get-Volume|Where-Object {$_.DriveLetter -and [string]$_.DriveLetter -ne $letter -and $_.FileSystem}|Select-Object -First 1)
 if($other.Count){
  $job=Join-Path $root 'job.json'
  [pscustomobject]@{Source=$src+'\';SourceVolumeId=(Get-Volume -DriveLetter $letter).UniqueId;DestinationVolumeId='not-this-drive';DefaultMode='Mirror';Choices=@()}|ConvertTo-Json|Set-Content -LiteralPath $job
  Assert (Throws {& (Join-Path $PSScriptRoot 'Invoke-FastMirror.ps1') -ConfigPath $job -DestinationDrive ([string]$other[0].DriveLetter) -Folder 'never-created'} 'not the backup drive') 'the plain copy refuses a drive that is not the one in the job'
  Assert (-not(Test-Path -LiteralPath ([string]$other[0].DriveLetter+':\never-created'))) 'nothing was created on that drive'
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
