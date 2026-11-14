# One per-folder selection shared by the plain mirror and the versioned backup.
#
# Each entry in Choices has a Path relative to the source root and a Mode:
#   Mirror     plain copy only (Invoke-FastMirror.ps1)
#   Versioned  encrypted history only (Backup-Worker.ps1)
#   Both       both tools
#   Skip       neither tool
# A path follows the most specific entry that equals it or contains it; anything
# not covered by an entry follows DefaultMode. Entries can nest, so a skipped
# folder can still contain a selected one (Temp = Skip, Temp\evidence = Both).
$script:Modes=@('Mirror','Versioned','Both','Skip')
# Never copied by either tool, whatever the configuration says.
# Paths listed in the configuration's NeverBackUp (relative to the source root) are skipped by
# both tools whatever their mode, for example a folder holding credentials. That includes
# everything inside them, even a nested entry marked Mirror, Versioned or Both.

function Get-BackupModeNames {$script:Modes}

function Test-BackupModeIncludes([string]$Mode,[ValidateSet('Mirror','Versioned')][string]$Tool) {
 $Mode -eq 'Both' -or $Mode -eq $Tool
}

function Test-SameName([string]$A,[string]$B) {
 # Names are compared the way Windows compares them: character by character, in any case. PowerShell's
 # own -eq and -in compare the way a dictionary sorts and take an invisible character (a direction
 # mark, a zero-width space) or another spelling of an accented letter as no difference, so two
 # folders Windows keeps apart counted as one, and a name made only of such a character as empty.
 [string]::Equals($A,$B,[StringComparison]::OrdinalIgnoreCase)
}

function ConvertTo-SelectionPath([string]$Path) {
 $p=$Path.Replace('/','\').Trim().Trim('\')
 if($p.Length -eq 0 -or [IO.Path]::IsPathRooted($Path) -or $p.Contains(':') -or @($p.Split('\')|Where-Object {$_.Length -eq 0 -or $_.Equals('.') -or $_.Equals('..')}).Count){throw "Choice path must be relative to the source root: '$Path'"}
 $p
}

function Get-BackupSelection($Config) {
 $choices=@(if($Config.PSObject.Properties['Choices']){$Config.Choices})
 # A DefaultMode alone also counts: a source with no subfolders listed follows it entirely.
 $hasModes=@($choices|Where-Object {$_.PSObject.Properties['Mode']}).Count -gt 0 -or [bool]$Config.PSObject.Properties['DefaultMode']
 $entries=[Collections.Generic.List[object]]::new()
 if($hasModes){
  $given=if($Config.PSObject.Properties['DefaultMode']){[string]$Config.DefaultMode}else{'Skip'}
  $default=$script:Modes|Where-Object {Test-SameName $_ $given.Trim()}
  if(-not $default){$default=$given}
  foreach($c in $choices){
   $given=if($c.PSObject.Properties['Mode']){[string]$c.Mode}else{''}
   $mode=$script:Modes|Where-Object {Test-SameName $_ $given.Trim()}
   if(-not $mode){throw "Choice '$($c.Path)' needs Mode Mirror, Versioned, Both or Skip (found '$given')"}
   $entries.Add([pscustomobject]@{Path=(ConvertTo-SelectionPath $c.Path);Mode=$mode})
  }
 }else{
  # Older configuration: only Include existed, and only the versioned backup read it.
  $default='Skip'
  foreach($p in @(if($Config.PSObject.Properties['Include']){$Config.Include})){if($p){$entries.Add([pscustomobject]@{Path=(ConvertTo-SelectionPath $p);Mode='Versioned'})}}
 }
 if($default -cnotin $script:Modes){throw "DefaultMode must be Mirror, Versioned, Both or Skip (found '$default')"}
 $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
 foreach($e in $entries){if(-not $seen.Add($e.Path)){throw "Choice path listed twice: $($e.Path)"}}
 foreach($never in @(if($Config.PSObject.Properties['NeverBackUp']){$Config.NeverBackUp|Where-Object {$_}|ForEach-Object {ConvertTo-SelectionPath $_}})){
  $hit=@($entries|Where-Object {Test-SameName $_.Path $never})
  if($hit.Count -and $hit[0].Mode -ne 'Skip'){throw "$never is listed in NeverBackUp; set its Mode to Skip"}
  if(-not $hit.Count){$entries.Add([pscustomobject]@{Path=$never;Mode='Skip'})}
  # A choice inside a NeverBackUp folder cannot bring part of it back: it is skipped too.
  foreach($e in @($entries|Where-Object {Test-IsUnder $_.Path $never})){$e.Mode='Skip'}
 }
 [pscustomobject]@{HasModes=$hasModes;DefaultMode=$default;Entries=@($entries)}
}

function Test-IsUnder([string]$Path,[string]$Parent) {
 # True when Path is strictly inside Parent; '' is the source root.
 if($Parent.Length -eq 0){return $Path.Length -gt 0}
 $Path.StartsWith($Parent+'\',[StringComparison]::OrdinalIgnoreCase)
}

function Test-BackupPathInside([string]$Path,[string[]]$Roots) {
 # True when the full path Path is one of Roots or lies below one of them. Whole folder names count,
 # in any case, trailing backslashes ignored: C:\Data2 is not inside C:\Data.
 $p=$Path.TrimEnd('\')
 foreach($r in @($Roots|Where-Object {$_}|ForEach-Object {([string]$_).TrimEnd('\')})){
  if([string]::Equals($p,$r,[StringComparison]::OrdinalIgnoreCase) -or $p.StartsWith($r+'\',[StringComparison]::OrdinalIgnoreCase)){return $true}
 }
 $false
}

function Get-BackupMode($Selection,[string]$Path) {
 $p=if($Path){ConvertTo-SelectionPath $Path}else{''}
 $best=$null
 foreach($e in $Selection.Entries){if(((Test-SameName $e.Path $p) -or (Test-IsUnder $p $e.Path)) -and (-not $best -or $e.Path.Length -gt $best.Path.Length)){$best=$e}}
 if($best){$best.Mode}else{$Selection.DefaultMode}
}

function Get-BackupRegions($Selection,[ValidateSet('Mirror','Versioned')][string]$Tool) {
 # Returns the smallest set of roots to copy for one tool. Each root lists the
 # entries inside it that this tool must leave out. A selected entry inside a
 # left-out one becomes its own root.
 $roots=@()
 if(Test-BackupModeIncludes $Selection.DefaultMode $Tool){$roots+=''}
 foreach($e in @($Selection.Entries|Sort-Object {$_.Path.Length})){
  if(-not(Test-BackupModeIncludes $e.Mode $Tool)){continue}
  $parent=$null
  foreach($o in $Selection.Entries){if((Test-IsUnder $e.Path $o.Path) -and (-not $parent -or $o.Path.Length -gt $parent.Path.Length)){$parent=$o}}
  $parentMode=if($parent){$parent.Mode}else{$Selection.DefaultMode}
  if(-not(Test-BackupModeIncludes $parentMode $Tool)){$roots+=$e.Path}
 }
 foreach($r in $roots){
  [pscustomobject]@{
   Path=$r
   Excluded=@($Selection.Entries|Where-Object {(Test-IsUnder $_.Path $r) -and -not(Test-BackupModeIncludes $_.Mode $Tool)}|ForEach-Object {$_.Path}|Sort-Object)
  }
 }
}

function Get-RoboExtraPaths([string[]]$Lines,[string]$Root,[string[]]$OtherRoots=@()) {
 # The paths under Root that a robocopy /L /PURGE listing reports as extra. With /MT several threads
 # write into one log, so a record is not always one line: its path can land on the next line on its
 # own, and one line can hold the end of one record and the start of the next. Every tab-separated
 # field is therefore read, and a field is split again wherever a new path under Root starts.
 # A path of the other side of the copy can follow at once as well (...\source\a\bX:\Copy\c\d), so
 # the listing is read with that side's root in OtherRoots, and a field is split there too; a full
 # path with its drive letter cannot stand inside a name. Only the paths under Root are returned.
 # Error lines are skipped: they can name a destination folder that is not extra.
 $prefix=$Root.TrimEnd('\')+'\'
 $starts=@($prefix)+@($OtherRoots|Where-Object {$_}|ForEach-Object {$_.TrimEnd('\')+'\'})
 $split=[regex]::new('(?='+(@($starts|ForEach-Object {[regex]::Escape($_)}) -join '|')+')',[Text.RegularExpressions.RegexOptions]'IgnoreCase,CultureInvariant')
 foreach($line in $Lines){
  if($line -match '\sERROR \d+ '){continue}
  foreach($field in ($line -split "`t")){
   foreach($p in $split.Split($field)){
    $p=$p.Trim()
    if($p.Length -gt $prefix.Length -and $p.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){$p}
   }
  }
 }
}

function Get-RoboTotals([string]$Log) {
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

function Get-RoboRunResult([string]$Log,[int]$ExitCode) {
 # What one robocopy run left uncopied. NotCopied adds up the files and folders in its totals that
 # failed or are a mismatch (a folder in the source where the copy has a file of that name, or the
 # reverse: robocopy copies nothing there and still exits below 8). A log without totals means
 # robocopy was ended or crashed before it finished, whatever exit code that left: ending it from
 # Task Manager leaves 1, which otherwise means "files were copied". And an exit code that reports
 # failures or a mismatch never ends as nothing uncopied, whatever the totals read say.
 # Complete: the run read the whole source, so a file the copy has beyond it is really gone from it.
 $t=if(Test-Path -LiteralPath $Log){Get-RoboTotals $Log}else{$null}
 $n=[long]0
 if($t){$n=$t.Files[3]+$t.Files[4]+$t.Dirs[3]+$t.Dirs[4]}
 if($n -eq 0 -and (-not $t -or $ExitCode -lt 0 -or $ExitCode -ge 8 -or ($ExitCode -band 4))){$n=1}
 [pscustomobject]@{Totals=$t;NotCopied=$n;Complete=([bool]$t -and $ExitCode -ge 0 -and $ExitCode -lt 8)}
}

function Get-MirrorLogName([string]$Relative,[Collections.Generic.HashSet[string]]$Used) {
 # The log file of one selected folder ('' is the source root). Characters a file name cannot hold
 # become _, so two folders (a\b and a_b) can end up with one name; the later one then gets a number,
 # or its log would replace the other's and hide what that run could not copy.
 $base='copy-'+$(if($Relative){$Relative -replace '[\\/:*?"<>|]','_'}else{'main'})
 $name=$base
 for($n=2;-not $Used.Add($name+'.log');$n++){$name=$base+'-'+$n}
 $name+'.log'
}

function Get-RecoveryFoldersToRemove([string[]]$Names,[int]$Keep,[string]$Own='') {
 # The dated recovery folders to delete so that only the newest Keep stay. Their names are local
 # times (yyyyMMdd-HHmmss), so the order of the names is the order of their age, except after the
 # clock went back (another time zone, the end of daylight saving, a corrected clock): the folder
 # this run just made (Own) can then sort as an old one. It holds the files moved a moment ago, so
 # it always stays, and counts as one of the Keep.
 if($Keep -le 0){return}
 $others=[string[]]@($Names|Where-Object {-not $Own -or -not $_.Equals($Own)})
 [Array]::Sort($others,[StringComparer]::Ordinal);[Array]::Reverse($others)
 $others|Select-Object -Skip $(if($Own -and $others.Count -lt @($Names).Count){$Keep-1}else{$Keep})
}

function Move-BackupTypeSwap([string]$Source,[string]$Copy,[string]$Target) {
 # Moves the item at Copy to Target when it stands in the way of the item at Source: one of the two
 # is a folder and the other a file, so robocopy can copy nothing there. Both are looked at again
 # here, at the moment of the move: nothing is moved once the source item is gone or the two are the
 # same kind again, and a link on either side is left alone. Nor where the source folder holds the
 # name twice in different letter case (a file Build beside a folder build, in a folder that keeps
 # case apart): the copy can hold only one of the two, and moving it would change which one on every
 # run. Returns whether the item was moved. A move that fails (a file another program holds open)
 # changes nothing. Paths are full paths; they are used in their \\?\ form, which keeps a name that
 # ends in a dot and has no length limit.
 $long={param($p)if($p.StartsWith('\\')){$p}else{'\\?\'+$p}}
 $folder=[IO.FileAttributes]::Directory
 # Whether the two are a file against a folder right now, neither of them a link. A missing item throws.
 $swapped={$s=[IO.File]::GetAttributes((& $long $Source));$c=[IO.File]::GetAttributes((& $long $Copy));-not(($s -bor $c) -band [IO.FileAttributes]::ReparsePoint) -and [bool]($s -band $folder) -ne [bool]($c -band $folder)}
 try{
  if(-not(& $swapped)){return $false}
  $name=[IO.Path]::GetFileName($Source)
  if(@([IO.Directory]::EnumerateFileSystemEntries((& $long ([IO.Path]::GetDirectoryName($Source))))|Where-Object {[string]::Equals([IO.Path]::GetFileName($_),$name,[StringComparison]::OrdinalIgnoreCase)}).Count -gt 1){return $false}
  [IO.Directory]::CreateDirectory((& $long ([IO.Path]::GetDirectoryName($Target))))|Out-Null
  # Looked at once more, as the last thing before the move: the steps above take a moment.
  if(-not(& $swapped)){return $false}
  if([IO.File]::GetAttributes((& $long $Copy)) -band $folder){[IO.Directory]::Move((& $long $Copy),(& $long $Target))}else{[IO.File]::Move((& $long $Copy),(& $long $Target))}
  $true
 }catch{$false}
}

function Test-BackupLinkOnPath([string]$Root,[string]$Relative) {
 # True when a folder on the way from Root down to the item at Relative (the item itself not
 # counted) is a link or junction, or cannot be looked at. What lies behind a link is not part of
 # the source or of the copy, so nothing is moved out of there.
 $p=$Root.TrimEnd('\')
 foreach($part in @($Relative.Split('\')|Where-Object {$_.Length}|Select-Object -SkipLast 1)){
  $p+='\'+$part
  try{if([IO.File]::GetAttributes($(if($p.StartsWith('\\')){$p}else{'\\?\'+$p})) -band [IO.FileAttributes]::ReparsePoint){return $true}}catch{return $true}
 }
 $false
}

function Get-BackupSameDiskReason($SourceDisk,$DestinationDisk,[scriptblock]$DiskOfLetter) {
 # Why a copy on DestinationDisk would be lost together with the source, or nothing when the two
 # are apart. A virtual disk (a VHDX, a Dev Drive) is a file on another disk, which can be virtual
 # too; a disk that fails takes every disk stored on it with it. So each side is followed down to
 # the disk it really lies on, and the two must not meet anywhere. DiskOfLetter returns the disk
 # of a drive letter.
 $chain={param($d)$n=@();for($i=0;$d -and $i -lt 8;$i++){$n+=[int]$d.Number;if([string]$d.BusType -ne 'File Backed Virtual' -or [string]$d.Location -notmatch '^([A-Za-z]):\\'){break};$d=& $DiskOfLetter $Matches[1]};$n}
 if([int]$SourceDisk.Number -eq [int]$DestinationDisk.Number){return 'Destination is on the same physical disk as the source'}
 $s=@(& $chain $SourceDisk);$d=@(& $chain $DestinationDisk)
 if([int]$DestinationDisk.Number -in $s){return 'Destination is on the disk that holds the Dev Drive file'}
 if(@($d|Where-Object {$_ -in $s}).Count){return 'Destination is a virtual disk whose file is on the same physical disk as the source'}
}

function ConvertTo-NameRegex([string]$Name) {
 # A name with the wildcards * and ? as a pattern for a whole name, in any case.
 [regex]::new('^'+[regex]::Escape($Name).Replace('\*','.*').Replace('\?','.')+'$',[Text.RegularExpressions.RegexOptions]'IgnoreCase,CultureInvariant')
}

function Get-BackupSkippedName([string]$Relative,[string[]]$FolderNames,[string[]]$FileNames,[bool]$IsFolder) {
 # The first name along Relative (a path below a folder robocopy copies) that robocopy skips by
 # name, or nothing: a folder name on FolderNames, or for a file its own name on FileNames.
 $parts=@($Relative.Split('\')|Where-Object {$_.Length})
 $folders=@(if($IsFolder){$parts}elseif($parts.Count -gt 1){$parts[0..($parts.Count-2)]})
 $rx=@($FolderNames|Where-Object {$_}|ForEach-Object {ConvertTo-NameRegex $_})
 foreach($p in $folders){if(@($rx|Where-Object {$_.IsMatch($p)}).Count){return $p}}
 if(-not $IsFolder -and $parts.Count -and @($FileNames|Where-Object {$_}|Where-Object {(ConvertTo-NameRegex $_).IsMatch($parts[-1])}).Count){return $parts[-1]}
}

function Resolve-BackupExcludePath([string]$Root,[string]$Pattern) {
 # The files and folders below Root that an Exclude path with wildcards names, relative to Root.
 # robocopy takes wildcards in a name only and refuses them inside a path, while the versioned
 # backup takes such a path as it is (for example */dist or logs/*.tmp). So the pattern is matched
 # here, one path part at a time, against the names really there: * and ? within a name, ** for any
 # number of folders. Square brackets are plain characters, as in every other Exclude path of the
 # plain copy. Links are not followed.
 $parts=@($Pattern.Replace('/','\').Split('\')|Where-Object {$_.Length})
 while($parts.Count -and $parts[-1].Equals('**')){$parts=@($parts|Select-Object -SkipLast 1)}   # a\** is a itself
 if(-not $parts.Count -or -not [IO.Directory]::Exists($Root)){return}
 $found=[Collections.Generic.SortedSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
 $isFolder={param($e)($e.Attributes -band [IO.FileAttributes]::Directory) -and -not($e.Attributes -band [IO.FileAttributes]::ReparsePoint)}
 function Step([string]$Dir,[string]$Rel,[int]$I){
  # A folder that cannot be read matches nothing here; robocopy reports it when it copies.
  $items=try{@([IO.DirectoryInfo]::new($Dir).GetFileSystemInfos())}catch{@()}
  if($parts[$I].Equals('**')){
   Step $Dir $Rel ($I+1)
   foreach($e in $items){if(& $isFolder $e){Step $e.FullName ($Rel+$e.Name+'\') $I}}
   return
  }
  $rx=ConvertTo-NameRegex $parts[$I]
  foreach($e in $items){
   if(-not $rx.IsMatch($e.Name)){continue}
   if($I -eq $parts.Count-1){[void]$found.Add($Rel+$e.Name)}elseif(& $isFolder $e){Step $e.FullName ($Rel+$e.Name+'\') ($I+1)}
  }
 }
 Step ($Root.TrimEnd('\')+'\') '' 0
 $found
}

Export-ModuleMember -Function Get-BackupModeNames,Test-BackupModeIncludes,ConvertTo-SelectionPath,Get-BackupSelection,Get-BackupMode,Get-BackupRegions,Get-RoboExtraPaths,Test-BackupPathInside,Get-RoboTotals,Get-RoboRunResult,Get-MirrorLogName,Get-RecoveryFoldersToRemove,Move-BackupTypeSwap,Test-BackupLinkOnPath,Get-BackupSameDiskReason,Get-BackupSkippedName,Resolve-BackupExcludePath
