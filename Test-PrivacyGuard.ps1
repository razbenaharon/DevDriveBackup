#Requires -Version 7.2
# Blocks private backup details from reaching the public repository.
# Without switches it checks every tracked file and the last commit (CI). -Staged checks what the next
# commit would publish (pre-commit hook); -MessageFile checks a commit message (commit-msg hook).
# -Range OLD..NEW also checks every commit in that range, its message and each file version it adds
# or changes, so that a detail added in one pushed commit and removed in the next is still caught (CI).
# Generic rules run everywhere. On your own computer it also blocks the specific values found in your
# git-ignored settings (*.local.json) and drive inventory (hardware.json): volume and key identifiers,
# drive models and labels, folder names, computer name and personal email. Those values are read at run
# time and never stored in the repository.
# -ListTerms prints the private values it found on this computer and checks nothing.
param([switch]$Staged,[string]$MessageFile,[switch]$ListTerms,[string]$Range)
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
function Get-BlobText([byte[]]$bytes){
 # The text to check in a file's bytes. A zero byte used to mean "binary, skip", which let UTF-16
 # text and plain text behind a single zero byte through. Now: a byte order mark decides the
 # encoding; without one and without zero bytes it is UTF-8; anything else is searched the way the
 # "strings" tool does, for runs of 8 or more printable characters as single bytes and as UTF-16,
 # one run per line. Compressed data in a picture or icon has no such runs that look like a rule.
 if(-not $bytes){return ''}
 if($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE){return [Text.Encoding]::Unicode.GetString($bytes)}
 if($bytes.Length -ge 2 -and $bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF){return [Text.Encoding]::BigEndianUnicode.GetString($bytes)}
 if([Array]::IndexOf($bytes,[byte]0) -lt 0){return [Text.UTF8Encoding]::new($false).GetString($bytes)}
 $raw=[Text.Encoding]::Latin1.GetString($bytes)
 $runs=foreach($m in [regex]::Matches($raw,'(?:[\x20-\x7E\t]\x00){8,}|(?:\x00[\x20-\x7E\t]){8,}|[\x20-\x7E\t]{8,}')){$m.Value.Replace("`0",'')}
 @($runs) -join "`n"
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
# For Test-PrivacyGuardRules.ps1 only: made-up values to check the rules with, so the test never needs
# this computer's real ones. They can only add to what is blocked.
if($env:PRIVACY_GUARD_TEST_TERMS){foreach($t in $env:PRIVACY_GUARD_TEST_TERMS -split ';'){Add-Term $t}}
if($ListTerms){@($terms)|Sort-Object;return}

$rules=@(
 @{Name='volume identifier';Pattern='(?i)Volume\{[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}\}'},
 # The second form is the same folder as Git Bash and WSL write it (drive letter as a folder, with
 # /mnt in front under WSL); it must start the word, so the path part of a web address does not count.
 @{Name='user profile path';Pattern='(?i)(\b[a-z]:[\\/]+|(?<![\w.:/-])/(mnt/)?[a-z]/)Users[\\/]+(?!(YOUR_USER|Public|Default)\b)(?![%$<{])[^\\/\s"''<>|*?]+'},
 # Allowed: a sender named noreply or no-reply, GitHub's private commit addresses, and example.com.
 # An address that merely contains "noreply" somewhere is a real address and is not.
 @{Name='email address';Pattern='(?i)[a-z0-9._%+-]+@[a-z0-9-]+(\.[a-z0-9-]+)*\.[a-z]{2,}\b';Allow='(?i)^no-?reply@|@users\.noreply\.github\.com$|@example\.(com|org|net)$'}
)
# A short value counts only as a word of its own, or ordinary words would raise alarms. A value of 8
# characters or more is found inside a longer word as well (myDriveNameCopy). Two rules over two
# separate sets, so one place is never reported twice.
$join={param($set)(@($set)|Sort-Object Length -Descending|ForEach-Object {[regex]::Escape($_)}) -join '|'}
$longTerms=@(@($terms)|Where-Object {$_.Length -ge 8});$shortTerms=@(@($terms)|Where-Object {$_.Length -lt 8})
if($shortTerms.Count){$rules+=@{Name='private value from your local settings';Pattern='(?i)(?<![a-z0-9])('+(& $join $shortTerms)+')(?![a-z0-9])'}}
if($longTerms.Count){$rules+=@{Name='private value from your local settings';Pattern='(?i)('+(& $join $longTerms)+')'}}

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
 $seen=[Collections.Generic.HashSet[string]]::new()
 foreach($e in $entries){
  $scanned++;Test-Text ('file name '+$e.Path) $e.Path
  if($e.Path -match '(?i)\.local\.json$|\.dpapi$|\.password$|recovery-key\.txt$'){$findings.Add($e.Path+'  private settings or key file')}
  if($e.Mode -eq '160000'){continue}
  [void]$seen.Add($e.Id);Test-Text $e.Path (Get-BlobText (Read-Blob $e.Id))
 }
 # Every commit of a push: what it says and each file version it adds or changes. Emails on commits
 # are left out for the reason given below. A merge adds no content of its own.
 $commits=@()
 if($Range -and -not $Staged){
  $commits=@(& git -C $PSScriptRoot rev-list $Range 2>$null)
  # After a forced push the old end of the range is no longer in the repository.
  if($LASTEXITCODE){$commits=@();Write-Warning 'The commits of this push could not be listed; only the newest commit is checked.'}
 }
 foreach($c in $commits){
  $scanned++;$short=$c.Substring(0,7)
  Test-Text ('commit '+$short) ((Invoke-Git log -1 --format='%an%n%cn%n%B' $c) -join "`n")
  $raw=Split-Zero (Invoke-Git diff-tree -r --root --no-commit-id --no-abbrev --diff-filter=ACMR -z $c)
  for($i=0;$i+1 -lt $raw.Count;$i+=2){
   $meta=$raw[$i] -split ' ';$path=$raw[$i+1];$id=$meta[3]
   Test-Text ('file name '+$path+' in commit '+$short) $path
   if($meta[1] -eq '160000' -or -not $seen.Add($id)){continue}
   Test-Text ($path+' in commit '+$short) (Get-BlobText (Read-Blob $id))
  }
 }
 if($Staged){foreach($v in 'GIT_AUTHOR_IDENT','GIT_COMMITTER_IDENT'){Test-Text $v ((Invoke-Git var $v) -replace '\s+\d+\s+[+-]\d{4}$','')}}
 # The last commit's author and committer emails are not checked: merges on GitHub (and its pull request
 # test merges) carry the account's own email, which the owner chose to show. Names and the message still are.
 elseif(-not $commits.Count){& git -C $PSScriptRoot rev-parse --verify -q HEAD *>$null;if(-not $LASTEXITCODE){Test-Text 'last commit' ((Invoke-Git log -1 --format='%an%n%cn%n%B') -join "`n")}}
}

if($findings.Count){
 Write-Host ('Blocked: '+$findings.Count+' private detail(s) would be published.') -ForegroundColor Red
 foreach($f in $findings){Write-Host ('  '+$f)}
 Write-Host 'Keep personal values in git-ignored *.local.json files or %LOCALAPPDATA%\DevDriveMirror; in examples use placeholders such as YOUR_USER or X:\.'
 exit 1
}
Write-Output ('PASS no private details in '+$scanned+' item(s); '+$terms.Count+' private values from this computer were checked')
