#Requires -Version 7.2
# Blocks private backup details from reaching the public repository.
# Without switches it checks every tracked file and the last commit (CI). -Staged checks what the next
# commit would publish (pre-commit hook); -MessageFile checks a commit message (commit-msg hook).
# Generic rules run everywhere. On your own computer it also blocks the specific values found in your
# git-ignored settings (*.local.json) and drive inventory (hardware.json): volume and key identifiers,
# drive models and labels, folder names, computer name and personal email. Those values are read at run
# time and never stored in the repository.
# -ListTerms prints the private values it found on this computer and checks nothing.
param([switch]$Staged,[string]$MessageFile,[switch]$ListTerms)
$ErrorActionPreference='Stop'
[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
$ci=[bool]$env:GITHUB_ACTIONS
function Invoke-Git{$out=& git -C $PSScriptRoot @args;if($LASTEXITCODE){throw ('git '+($args -join ' ')+' failed')};$out}
function Split-Zero($text){@(($text -join "`n") -split "`0"|Where-Object {$_})}
function Read-Blob($id){
 $psi=[Diagnostics.ProcessStartInfo]::new('git');foreach($a in 'cat-file','blob',$id){[void]$psi.ArgumentList.Add($a)}
 $psi.WorkingDirectory=$PSScriptRoot;$psi.RedirectStandardOutput=$true;$psi.UseShellExecute=$false
 $p=[Diagnostics.Process]::Start($psi);$ms=[IO.MemoryStream]::new();$p.StandardOutput.BaseStream.CopyTo($ms);$p.WaitForExit()
 if($p.ExitCode){throw ('git cat-file blob '+$id+' failed')};$ms.ToArray()
}
function Get-Strings($node){
 if($node -is [string]){$node}elseif($node -is [pscustomobject]){foreach($p in $node.PSObject.Properties){Get-Strings $p.Value}}elseif($node -is [Collections.IEnumerable]){foreach($i in $node){Get-Strings $i}}
}

# Values that are public by design: generic folder and volume names, and everything in the example configuration.
$generic=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach($g in 'Projects','Tools','Archive','Temp','Packages','README.md','test-results','android','avd','Dev Drive','DevDrive','DevDrive-Mirror','DevDrive-Backup','Windows','WinRE','Recovery','System Reserved','Msft Virtual Disk','Generic MassStorageClass','User','Users','Backup','Data','Documents','Desktop',(Split-Path -Leaf $PSScriptRoot)){[void]$generic.Add($g)}
foreach($s in Get-Strings (Get-Content -LiteralPath (Join-Path $PSScriptRoot 'config.example.json') -Raw|ConvertFrom-Json)){[void]$generic.Add($s);foreach($part in $s -split '[\\/]'){[void]$generic.Add($part)}}

# Private values from this computer. Free-text notes are skipped; identifiers, names and folder paths are kept.
$terms=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
# Only distinctive values count (a digit, separator, inner capital or 10+ letters), so plain words such as "source" never block.
# -FolderName relaxes that to 5+ characters for the names of folders found in a selected region (project names).
function Add-Term($value,[switch]$FolderName){$v=([string]$value).Trim();if($v.Length -ge 4 -and ($v -cmatch '[\d_.@ -]|[a-z][A-Z]|^.{10,}$' -or ($FolderName -and $v.Length -ge 5)) -and $v -notmatch '[*?]' -and $v -notmatch '^[A-Za-z]:\\?$' -and -not $generic.Contains($v)){[void]$terms.Add($v)}}
function Add-Values($node,$key){
 if($null -eq $node){return}
 if($node -is [string]){
  foreach($m in [regex]::Matches($node,'(?i)[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}|(?<![0-9a-f])[0-9a-f]{32}(?![0-9a-f])')){Add-Term $m.Value}
  if($key -in 'Id','Name','Label','DriveModel','FriendlyName','FileSystemLabel'){Add-Term $node}
  if($key -in 'Path','Include','Exclude','RecommendedExclude','NeverBackUp'){foreach($part in $node -split '[\\/]'){Add-Term $part}}
  return
 }
 if($node -is [pscustomobject]){foreach($p in $node.PSObject.Properties){if($p.Name -notin 'Reason','ReportNotes'){Add-Values $p.Value $p.Name}};return}
 if($node -is [Collections.IEnumerable]){foreach($i in $node){Add-Values $i $key}}
}
if(-not $ci){
 $app=if($env:LOCALAPPDATA){Join-Path $env:LOCALAPPDATA 'DevDriveMirror'}
 $folders=@($PSScriptRoot,(Join-Path $PSScriptRoot 'jobs'),$app)|Where-Object {$_ -and (Test-Path -LiteralPath $_)}
 foreach($f in @($folders|ForEach-Object {Get-ChildItem -LiteralPath $_ -Filter '*.local.json' -File})){
  try{
   $c=Get-Content -LiteralPath $f.FullName -Raw|ConvertFrom-Json;Add-Values $c ''
   # Folders directly inside a top-level selected region (Projects, Tools...) that are not listed yet, such as a new project.
   if($c.PSObject.Properties['Source'] -and $c.PSObject.Properties['Include'] -and $c.Source -and $c.Source -notmatch '(?i)\.temporary-|[\\/]test-' -and (Test-Path -LiteralPath $c.Source)){
    foreach($i in @($c.Include|Where-Object {$_ -notmatch '[\\/]'})){$region=Join-Path $c.Source $i;if(Test-Path -LiteralPath $region -PathType Container){Get-ChildItem -LiteralPath $region -Directory -Force -ErrorAction SilentlyContinue|ForEach-Object {Add-Term $_.Name -FolderName}}}
   }
  }catch{Write-Warning ('Could not read '+$f.FullName+'; its values are not checked.')}
 }
 # Drives attached now, in case hardware.json is older than a renamed label or a new drive.
 try{Add-Values @(Get-Disk|Select-Object FriendlyName) '';Add-Values @(Get-Volume|Select-Object FileSystemLabel) ''}catch{}
 $hardware=if($app){Join-Path $app 'hardware.json'}
 if($hardware -and (Test-Path -LiteralPath $hardware)){try{$h=Get-Content -LiteralPath $hardware -Raw|ConvertFrom-Json;Add-Values $h.Disks '';Add-Values $h.Volumes ''}catch{Write-Warning ('Could not read '+$hardware)}}
 foreach($scope in '--global','--system'){$email=& git config $scope --get user.email 2>$null;if($email -and $email -notmatch 'noreply'){Add-Term $email}}
 Add-Term $env:COMPUTERNAME;Add-Term $env:USERNAME
}
if($ListTerms){@($terms)|Sort-Object;return}

$rules=@(
 @{Name='volume identifier';Pattern='(?i)Volume\{[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}\}'},
 @{Name='user profile path';Pattern='(?i)\b[a-z]:[\\/]+Users[\\/]+(?!(YOUR_USER|Public|Default)\b)(?![%$<{])[^\\/\s"''<>|*?]+'},
 @{Name='email address';Pattern='(?i)[a-z0-9._%+-]+@[a-z0-9-]+(\.[a-z0-9-]+)*\.[a-z]{2,}\b';Allow='(?i)noreply|@example\.(com|org|net)$'}
)
if($terms.Count){$rules+=@{Name='private value from your local settings';Pattern='(?i)(?<![a-z0-9])('+((@($terms)|Sort-Object Length -Descending|ForEach-Object {[regex]::Escape($_)}) -join '|')+')(?![a-z0-9])'}}

$findings=[Collections.Generic.List[string]]::new()
# CI logs are public, so there the matched text is not repeated.
function Test-Text($label,[string]$text){
 $n=0
 foreach($line in $text -split '\r?\n'){$n++;foreach($r in $rules){foreach($m in [regex]::Matches($line,$r.Pattern)){
  if($r.Allow -and $m.Value -match $r.Allow){continue}
  $findings.Add($label+':'+$n+'  '+$r.Name+$(if(-not $ci){'  "'+$m.Value+'"'}))
 }}}
}

$scanned=0
if($MessageFile){
 $message=([IO.File]::ReadAllText($MessageFile) -split '(?m)^# -+ >8 -+\r?$')[0]
 Test-Text 'commit message' (($message -split '\r?\n'|Where-Object {$_ -notmatch '^#'}) -join "`n");$scanned=1
}else{
 $entries=foreach($e in Split-Zero (Invoke-Git ls-files -s -z)){$meta,$path=$e -split "`t",2;$parts=$meta -split ' ';[pscustomobject]@{Mode=$parts[0];Id=$parts[1];Path=$path}}
 $ignored=Split-Zero (Invoke-Git ls-files -ci --exclude-standard -z)
 if($Staged){
  $changed=Split-Zero (Invoke-Git diff --cached --name-only --diff-filter=ACMR -z)
  $entries=@($entries|Where-Object {$_.Path -in $changed});$ignored=@($ignored|Where-Object {$_ -in $changed})
 }
 foreach($p in $ignored){$findings.Add($p+'  file matches .gitignore and was added by force')}
 foreach($e in $entries){
  $scanned++;Test-Text ('file name '+$e.Path) $e.Path
  if($e.Path -match '(?i)\.local\.json$|\.dpapi$|\.password$|recovery-key\.txt$'){$findings.Add($e.Path+'  private settings or key file')}
  if($e.Mode -eq '160000'){continue}
  $bytes=Read-Blob $e.Id;if([Array]::IndexOf($bytes,[byte]0) -ge 0){continue}
  Test-Text $e.Path ([Text.UTF8Encoding]::new($false).GetString($bytes))
 }
 if($Staged){foreach($v in 'GIT_AUTHOR_IDENT','GIT_COMMITTER_IDENT'){Test-Text $v ((Invoke-Git var $v) -replace '\s+\d+\s+[+-]\d{4}$','')}}
 else{& git -C $PSScriptRoot rev-parse --verify -q HEAD *>$null;if(-not $LASTEXITCODE){Test-Text 'last commit' ((Invoke-Git log -1 --format='%an <%ae>%n%cn <%ce>%n%B') -join "`n")}}
}

if($findings.Count){
 Write-Host ('Blocked: '+$findings.Count+' private detail(s) would be published.') -ForegroundColor Red
 foreach($f in $findings){Write-Host ('  '+$f)}
 Write-Host 'Keep personal values in git-ignored *.local.json files or %LOCALAPPDATA%\DevDriveMirror; in examples use placeholders such as YOUR_USER or X:\.'
 exit 1
}
Write-Output ('PASS no private details in '+$scanned+' item(s); '+$terms.Count+' private values from this computer were checked')
