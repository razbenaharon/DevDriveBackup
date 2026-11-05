#Requires -Version 7.2
# Checks the shared per-folder Mode (Backup.Selection.psm1) and that both tools honour it:
# a small plain mirror (Invoke-FastMirror.ps1) and a small versioned backup (Backup-Worker.ps1)
# of a disposable source. Everything it creates carries one random id and is removed at the
# end unless -KeepArtifacts is given. The configured real mirror and repository are never used.
param([Parameter(Mandatory)][ValidatePattern('^[A-Za-z]$')][string]$DestinationDrive,[switch]$KeepArtifacts)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'Backup.Selection.psm1') -Force
function Assert($ok,$message){if(-not $ok){throw "FAIL $message"};Write-Output ('PASS '+$message)}
function Throws([scriptblock]$Block,[string]$Pattern){try{& $Block;$false}catch{$_.Exception.Message -match $Pattern}}
function Config($default,[object[]]$choices){[pscustomobject]@{DefaultMode=$default;NeverBackUp=@('credentials-folder');Choices=@($choices|ForEach-Object {[pscustomobject]@{Path=$_[0];Mode=$_[1];Reason='test'}})}}

# --- Rules, without touching any disk -------------------------------------------------
$sel=Get-BackupSelection (Config 'Mirror' @(@('Temp','Skip'),@('Temp\evidence','Both'),@('Projects','Both'),@('Projects\big','Versioned'),@('Projects\big\cache','Skip'),@('README.md','both')))
Assert ((Get-BackupMode $sel 'Projects\new-project\src') -eq 'Both') 'a new folder follows its parent entry'
Assert ((Get-BackupMode $sel 'Temp\evidence\x.log') -eq 'Both' -and (Get-BackupMode $sel 'Temp\other') -eq 'Skip') 'the most specific entry wins'
Assert ((Get-BackupMode $sel 'somewhere-else') -eq 'Mirror') 'unlisted paths follow DefaultMode'
Assert ((Get-BackupMode $sel 'README.md') -eq 'Both') 'mode names are not case-sensitive'
Assert ((Get-BackupMode $sel 'credentials-folder\.credentials') -eq 'Skip') 'a NeverBackUp folder is always skipped'
$m=@(Get-BackupRegions $sel 'Mirror')
Assert (($m.Path -join '|') -eq '|Temp\evidence') 'mirror roots: the source root and the evidence folder inside a skipped folder'
Assert ((@($m[0].Excluded) -join '|') -eq 'credentials-folder|Projects\big|Projects\big\cache|Temp') 'mirror leaves out Versioned-only and Skip entries'
$v=@(Get-BackupRegions $sel 'Versioned')
Assert ((@($v.Path|Sort-Object) -join '|') -eq 'Projects|README.md|Temp\evidence') 'versioned roots come from Versioned and Both'
Assert ((@(($v|Where-Object Path -eq 'Projects').Excluded) -join '|') -eq 'Projects\big\cache') 'versioned leaves out a skipped folder inside a selected one'
Assert (Throws {Get-BackupSelection (Config 'Mirror' @(,@('Projects','Copy')))} 'needs Mode') 'an unknown mode is refused'
Assert (Throws {Get-BackupSelection (Config 'Sometimes' @(,@('Projects','Both')))} 'DefaultMode') 'an unknown default mode is refused'
Assert (Throws {Get-BackupSelection (Config 'Mirror' @(@('Projects','Both'),@('projects','Skip')))} 'twice') 'a path listed twice is refused'
Assert (Throws {Get-BackupSelection (Config 'Mirror' @(,@('credentials-folder','Both')))} 'NeverBackUp') 'a NeverBackUp folder cannot be selected'
Assert (Throws {Get-BackupSelection (Config 'Mirror' @(,@('E:\Projects','Both')))} 'relative') 'an absolute path is refused'
Assert (Throws {Get-BackupSelection (Config 'Mirror' @(,@('Projects\..\Tools','Both')))} 'relative') 'a path that climbs out is refused'
$legacy=Get-BackupSelection ([pscustomobject]@{Include=@('Projects','README.md');Choices=@([pscustomobject]@{Path='Projects';Reason='x'})})
Assert (-not $legacy.HasModes -and (Get-BackupMode $legacy 'Projects\a') -eq 'Versioned' -and (Get-BackupMode $legacy 'Tools') -eq 'Skip') 'an older Include-only configuration keeps its versioned selection'
$nested=Get-BackupSelection (Config 'Skip' @(@('credentials-folder\keys','Both'),@('Projects','Both')))
Assert ((Get-BackupMode $nested 'credentials-folder\keys') -eq 'Skip' -and (Get-BackupMode $nested 'credentials-folder\keys\id.txt') -eq 'Skip') 'a choice inside a NeverBackUp folder is skipped too'
Assert (-not @(@(Get-BackupRegions $nested 'Mirror')+@(Get-BackupRegions $nested 'Versioned')|Where-Object {$_.Path -like 'credentials-folder*'}).Count) 'neither tool copies a choice inside a NeverBackUp folder'
# A source with no subfolders listed: an empty Choices list follows DefaultMode, also under strict mode.
& {
 Set-StrictMode -Version Latest
 $empty=Get-BackupSelection ([pscustomobject]@{DefaultMode='Mirror';Choices=@()})
 $roots=@(Get-BackupRegions $empty 'Mirror')
 Assert ($empty.HasModes -and $roots.Count -eq 1 -and $roots[0].Path -eq '' -and @($roots[0].Excluded).Count -eq 0 -and (Get-BackupMode $empty 'any\folder') -eq 'Mirror') 'an empty Choices list mirrors the whole source'
 Assert (@($empty.Entries|ForEach-Object {$_.Path}).Count -eq 0 -and @(Get-BackupRegions $empty 'Versioned').Count -eq 0) 'an empty Choices list gives the check an empty list, not an error'
}
$real=Join-Path $PSScriptRoot 'backup.local.json'
if(Test-Path -LiteralPath $real){
 $realConfig=Get-Content -LiteralPath $real -Raw|ConvertFrom-Json
 $realSelection=Get-BackupSelection $realConfig
 $selected=@(Get-BackupRegions $realSelection 'Mirror').Count+@(Get-BackupRegions $realSelection 'Versioned').Count
 Assert ($realSelection.HasModes -and $selected -gt 0) 'the real configuration loads with modes and selects something'
}

# --- Disposable source -----------------------------------------------------------------
$id=[guid]::NewGuid().ToString('N')
$root=Join-Path $PSScriptRoot ('.temporary-worker-test-mode-'+$id)
$private=Join-Path $env:LOCALAPPDATA ('DevDriveMirror\test-mode-'+$id)
$source=Join-Path $root 'source'
$files=[ordered]@{
 'both\a.txt'='both';'both\gone.txt'='deleted later';'both\inner [skip]\f.txt'='skipped inside both';'both\inner [skip]\keep\k.txt'='selected inside a skipped folder';'both\inner s\h.txt'='literal bracket check'
 'both\node_modules\x.txt'='cache';'mirrorOnly\b.txt'='mirror only';'versionedOnly\c.txt'='versioned only'
 'skipped\d.txt'='skipped';'skipped\evidence\e.txt'='evidence';'unlisted\g.txt'='default mode'
 'credentials-folder\secret.txt'='credentials';'both\personal-skip\p.txt'='skipped by name';'unlisted\build\cache\q.txt'='skipped by path';'note.md'='versioned file';'עברית\ש.txt'='hebrew'
}
foreach($k in $files.Keys){$p=Join-Path $source $k;New-Item -ItemType Directory -Path (Split-Path $p) -Force|Out-Null;[IO.File]::WriteAllText($p,$files[$k])}
New-Item -ItemType Directory -Path $private -Force|Out-Null
New-Item -ItemType Junction -Path (Join-Path $source 'link') -Target (Join-Path $source 'versionedOnly')|Out-Null
$config=Get-Content (Join-Path $PSScriptRoot 'config.example.json') -Raw|ConvertFrom-Json
$config.Source=$source+'\';$config.SourceVolumeId=(Get-Volume -DriveLetter $source.Substring(0,1)).UniqueId;$config.DestinationVolumeId=(Get-Volume -DriveLetter $DestinationDrive).UniqueId
$config.RepositoryFolder='DevDriveBackup-ModeTest-'+$id;$config.PasswordDpapiPath=Join-Path $private 'key.dpapi';$config.RecoveryKeyPath=Join-Path $private 'recovery.txt'
$config.Exclude=@('node_modules');$config.RateMBps=0;$config.MemoryMiB=512;$config.ReadConcurrency=1;$config.CpuThreads=1;$config.PackMiB=8
$config.DefaultMode='Mirror'
$config|Add-Member -NotePropertyName NeverBackUp -NotePropertyValue @('credentials-folder') -Force
# Personal skips from Exclude: a folder name anywhere, and one folder by its relative path.
$config.Exclude=@($config.Exclude)+@('personal-skip','unlisted/build/cache')
$config.Choices=@((Config 'Mirror' @(@('both','Both'),@('both\inner [skip]','Skip'),@('both\inner [skip]\keep','Both'),@('mirrorOnly','Mirror'),@('versionedOnly','Versioned'),@('skipped','Skip'),@('skipped\evidence','Both'),@('note.md','Versioned'),@('עברית','Both'))).Choices)
$configPath=Join-Path $private 'settings.json'
function Save-TestConfig{$config|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $configPath}
Save-TestConfig
$folder='DevDriveMirror-ModeTest-'+$id
$mirror=$DestinationDrive.ToUpperInvariant()+':\'+$folder
$runFolders=@()
function Mirror([hashtable]$extra=@{}){
 $out=& (Join-Path $PSScriptRoot 'Invoke-FastMirror.ps1') -ConfigPath $configPath -DestinationDrive $DestinationDrive -Folder $folder -Threads 4 @extra
 $s=($out -join "`n")|ConvertFrom-Json;$script:runFolders+=$s.RunFolder;$s
}
function InMirror([string]$rel){Test-Path -LiteralPath (Join-Path $mirror $rel)}

try{
 # --- Plain mirror ----------------------------------------------------------------------
 $first=Mirror
 Assert ($first.CopyErrors -eq 0 -and $first.Verify.Differences -eq 0 -and $first.Verify.FilesMatched -eq 8) 'first mirror copies and verifies the selected files'
 Assert ((InMirror 'both\a.txt') -and (InMirror 'mirrorOnly\b.txt') -and (InMirror 'unlisted\g.txt') -and (InMirror 'עברית\ש.txt') -and (InMirror 'both\inner s\h.txt')) 'Mirror, Both and unlisted folders are copied'
 Assert ((InMirror 'skipped\evidence\e.txt') -and -not(InMirror 'skipped\d.txt')) 'a Both folder inside a skipped folder is still copied'
 Assert (-not(InMirror 'versionedOnly') -and -not(InMirror 'note.md')) 'Versioned-only entries are not mirrored'
 Assert (-not(InMirror 'both\inner [skip]\f.txt') -and (InMirror 'both\inner [skip]\keep\k.txt') -and -not(InMirror 'both\node_modules') -and -not(InMirror 'credentials-folder') -and -not(InMirror 'link')) 'skipped entries, caches, the runner folder and links are not mirrored'
 Assert (-not(InMirror 'both\personal-skip') -and -not(InMirror 'unlisted\build\cache') -and (InMirror 'unlisted\g.txt')) 'personal skips from Exclude (a name and a relative path) are not mirrored'

 # Change the selection: stop mirroring two folders, mirror one single file, and delete a file.
 $config.DefaultMode='Skip';($config.Choices|Where-Object Path -eq 'mirrorOnly').Mode='Skip';($config.Choices|Where-Object Path -eq 'note.md').Mode='Both';Save-TestConfig
 Remove-Item -LiteralPath (Join-Path $source 'both\gone.txt')
 [IO.File]::WriteAllText((Join-Path $source 'mirrorOnly\b.txt'),'changed after it stopped being mirrored')
 $second=Mirror @{Verify=$true;MoveExtras=$true}
 Assert ($second.CopyErrors -eq 0 -and (InMirror 'note.md') -and -not(InMirror 'versionedOnly')) 'a single file marked Both is mirrored on its own'
 Assert ($second.ExtrasFound -eq 1 -and -not(InMirror 'both\gone.txt') -and (Test-Path -LiteralPath (Join-Path $second.ExtrasMovedTo 'both\gone.txt'))) 'a file deleted from the source is moved to recovery, not deleted'
 Assert ((@($second.NotSelectedButInMirror|Sort-Object) -join '|') -eq 'mirrorOnly|unlisted' -and (InMirror 'mirrorOnly\b.txt') -and (InMirror 'unlisted\g.txt')) 'old copies of folders no longer selected are kept and reported'
 Assert ($second.Verify.Differences -eq 0 -and $second.Verify.FilesMatched -eq 6) 'verification covers only selected files'

 # Keep only the newest recovery folders; anything else in the recovery root is left alone.
 $recoveryRoot=$mirror+'-recovery'
 New-Item -ItemType Directory -Path (Join-Path $recoveryRoot 'my-notes') -Force|Out-Null
 $last=$null
 foreach($i in 1..3){
  [IO.File]::WriteAllText((Join-Path $source "both\temp$i.txt"),"round $i")
  [void](Mirror @{SkipVerify=$true})
  Remove-Item -LiteralPath (Join-Path $source "both\temp$i.txt")
  Start-Sleep -Milliseconds 1100   # recovery folders are named to the second
  $last=Mirror @{SkipVerify=$true;MoveExtras=$true;KeepRecovery=2}
 }
 $dated=@(Get-ChildItem -LiteralPath $recoveryRoot -Directory|Where-Object Name -match '^\d{8}-\d{6}$'|Sort-Object Name)
 Assert ($dated.Count -eq 2 -and (Test-Path -LiteralPath (Join-Path $dated[1].FullName 'both\temp3.txt')) -and (Test-Path -LiteralPath (Join-Path $dated[0].FullName 'both\temp2.txt'))) 'only the newest recovery folders are kept'
 Assert ((Test-Path -LiteralPath (Join-Path $recoveryRoot 'my-notes')) -and @($last.RecoveryRemoved).Count -eq 1) 'pruning removes only dated recovery folders'
 Assert (-not(InMirror 'both\temp3.txt') -and (InMirror 'both\a.txt')) 'the plain copy holds only what the source still has'

 # --- Versioned backup --------------------------------------------------------------------
 $runDir=Join-Path $private ('backup-'+[guid]::NewGuid().ToString('N'))
 & (Join-Path $PSScriptRoot 'Backup-Worker.ps1') -ConfigPath $configPath -Action Backup -RunDirectory $runDir
 $state=Get-Content (Join-Path $runDir 'status.json') -Raw|ConvertFrom-Json
 Assert ($state.State -eq 'Completed') ('versioned backup completes '+$state.Error)
 $expected=@('both','both\inner [skip]\keep','note.md','skipped\evidence','versionedOnly','עברית'|ForEach-Object {Join-Path $source $_})
 Assert ((@($state.Sources|Sort-Object) -join '|') -eq (@($expected|Sort-Object) -join '|')) 'versioned sources are derived from Versioned and Both'
 $target=Join-Path $private 'restored'
 $restoreDir=Join-Path $private ('restore-'+[guid]::NewGuid().ToString('N'))
 & (Join-Path $PSScriptRoot 'Backup-Worker.ps1') -ConfigPath $configPath -Action Restore -Snapshot $state.Snapshot -RestoreTarget $target -RunDirectory $restoreDir
 Assert ((Get-Content (Join-Path $restoreDir 'status.json') -Raw|ConvertFrom-Json).State -eq 'Completed') 'versioned restore completes'
 $names=@(Get-ChildItem -LiteralPath $target -Recurse -File|ForEach-Object Name)
 Assert (@('a.txt','c.txt','e.txt','h.txt','note.md','ש.txt'|Where-Object {$_ -notin $names}).Count -eq 0) 'Versioned and Both files are in the snapshot'
 Assert (@('f.txt','b.txt','d.txt','g.txt','secret.txt','x.txt'|Where-Object {$_ -in $names}).Count -eq 0) 'Mirror-only, Skip, unlisted, cache and runner files are not in the snapshot'
 Assert ('k.txt' -in $names) 'a folder selected inside a skipped folder inside a selected one is in the snapshot'
}finally{
 if($KeepArtifacts){
  Write-Output ('Kept: '+$root+', '+$private+', '+$mirror+', '+$DestinationDrive+':\'+$config.RepositoryFolder)
 }else{
  # Remove only what this run created; every path carries this run's id.
  $remove=@($mirror,($mirror+'-recovery'),($DestinationDrive.ToUpperInvariant()+':\'+$config.RepositoryFolder),$root,$private,
   (Join-Path $env:LOCALAPPDATA ('DevDriveMirror\fast-mirror\last-success-'+((Get-Volume -DriveLetter $DestinationDrive).UniqueId -replace '[^A-Za-z0-9-]+','_').Trim('_')+'-'+$folder+'.json')))
  foreach($p in $remove){if(-not $p.Contains($id)){throw "Refusing to remove $p"};if(Test-Path -LiteralPath $p){Remove-Item -LiteralPath $p -Recurse -Force}}
  foreach($r in @($runFolders|Where-Object {$_})){if(Test-Path -LiteralPath (Join-Path $r 'summary.json')){if((Get-Content -LiteralPath (Join-Path $r 'summary.json') -Raw) -match [regex]::Escape($id)){Remove-Item -LiteralPath $r -Recurse -Force}}}
  Write-Output ('Removed the disposable source, mirror and repository for test '+$id)
 }
}
