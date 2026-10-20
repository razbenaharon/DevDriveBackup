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
# both tools whatever their mode, for example a folder holding credentials.

function Get-BackupModeNames {$script:Modes}

function Test-BackupModeIncludes([string]$Mode,[ValidateSet('Mirror','Versioned')][string]$Tool) {
 $Mode -eq 'Both' -or $Mode -eq $Tool
}

function ConvertTo-SelectionPath([string]$Path) {
 $p=$Path.Replace('/','\').Trim().Trim('\')
 if(-not $p -or [IO.Path]::IsPathRooted($Path) -or $p.Contains(':') -or @($p.Split('\')|Where-Object {$_ -in @('','.','..')}).Count){throw "Choice path must be relative to the source root: '$Path'"}
 $p
}

function Get-BackupSelection($Config) {
 $choices=@(if($Config.PSObject.Properties['Choices']){$Config.Choices})
 # A DefaultMode alone also counts: a source with no subfolders listed follows it entirely.
 $hasModes=@($choices|Where-Object {$_.PSObject.Properties['Mode']}).Count -gt 0 -or [bool]$Config.PSObject.Properties['DefaultMode']
 $entries=[Collections.Generic.List[object]]::new()
 if($hasModes){
  $given=if($Config.PSObject.Properties['DefaultMode']){[string]$Config.DefaultMode}else{'Skip'}
  $default=$script:Modes|Where-Object {$_ -ieq $given.Trim()}
  if(-not $default){$default=$given}
  foreach($c in $choices){
   $given=if($c.PSObject.Properties['Mode']){[string]$c.Mode}else{''}
   $mode=$script:Modes|Where-Object {$_ -ieq $given.Trim()}
   if(-not $mode){throw "Choice '$($c.Path)' needs Mode Mirror, Versioned, Both or Skip (found '$given')"}
   $entries.Add([pscustomobject]@{Path=(ConvertTo-SelectionPath $c.Path);Mode=$mode})
  }
 }else{
  # Older configuration: only Include existed, and only the versioned backup read it.
  $default='Skip'
  foreach($p in @(if($Config.PSObject.Properties['Include']){$Config.Include})){if($p){$entries.Add([pscustomobject]@{Path=(ConvertTo-SelectionPath $p);Mode='Versioned'})}}
 }
 if($default -cnotin $script:Modes){throw "DefaultMode must be Mirror, Versioned, Both or Skip (found '$default')"}
 $seen=@{}
 foreach($e in $entries){if($seen.ContainsKey($e.Path.ToLowerInvariant())){throw "Choice path listed twice: $($e.Path)"};$seen[$e.Path.ToLowerInvariant()]=$true}
 foreach($never in @(if($Config.PSObject.Properties['NeverBackUp']){$Config.NeverBackUp|Where-Object {$_}|ForEach-Object {ConvertTo-SelectionPath $_}})){
  $hit=@($entries|Where-Object {$_.Path -ieq $never})
  if($hit.Count -and $hit[0].Mode -ne 'Skip'){throw "$never is listed in NeverBackUp; set its Mode to Skip"}
  if(-not $hit.Count){$entries.Add([pscustomobject]@{Path=$never;Mode='Skip'})}
 }
 [pscustomobject]@{HasModes=$hasModes;DefaultMode=$default;Entries=@($entries)}
}

function Test-IsUnder([string]$Path,[string]$Parent) {
 # True when Path is strictly inside Parent; '' is the source root.
 if($Parent -eq ''){return $Path -ne ''}
 $Path.StartsWith($Parent+'\',[StringComparison]::OrdinalIgnoreCase)
}

function Get-BackupMode($Selection,[string]$Path) {
 $p=if($Path){ConvertTo-SelectionPath $Path}else{''}
 $best=$null
 foreach($e in $Selection.Entries){if(($e.Path -ieq $p -or (Test-IsUnder $p $e.Path)) -and (-not $best -or $e.Path.Length -gt $best.Path.Length)){$best=$e}}
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

Export-ModuleMember -Function Get-BackupModeNames,Test-BackupModeIncludes,ConvertTo-SelectionPath,Get-BackupSelection,Get-BackupMode,Get-BackupRegions
