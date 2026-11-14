#Requires -Version 7.2
# Checks the rules of Test-PrivacyGuard.ps1 on a disposable git repository in the temporary folder.
# It runs the guard as CI does (generic rules only), so no private value of this computer is read
# or printed, and it never touches this repository. The made-up "private" values below are built
# from pieces so that this file itself passes the guard.
$ErrorActionPreference='Stop'
function Assert($ok,$message){if(-not $ok){throw "FAIL $message"};Write-Output ('PASS '+$message)}
$mail='real'+'person@'+'realmail.io'
$path='C:\Us'+'ers\johnsmith\work'
$volume='Volume'+'{12345678-1234-1234-1234-123456789abc}'
$secret="contact $mail path $path $volume"
$root=Join-Path ([IO.Path]::GetTempPath()) ('privacy-guard-test-'+[guid]::NewGuid().ToString('N'))
$keep=@{};foreach($n in 'GITHUB_ACTIONS','GIT_AUTHOR_NAME','GIT_AUTHOR_EMAIL','GIT_COMMITTER_NAME','GIT_COMMITTER_EMAIL','GIT_CONFIG_GLOBAL','GIT_CONFIG_NOSYSTEM','PRIVACY_GUARD_TEST_TERMS'){$keep[$n]=[Environment]::GetEnvironmentVariable($n)}
$env:PRIVACY_GUARD_TEST_TERMS=$null   # a value left in the environment must not reach the clean cases
New-Item -ItemType Directory -Path $root|Out-Null
try{
 Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'Test-PrivacyGuard.ps1'),(Join-Path $PSScriptRoot 'config.example.json') -Destination $root
 # The repository's own identity and settings only: nothing from this computer's git configuration.
 $env:GITHUB_ACTIONS='1';$env:GIT_AUTHOR_NAME='Tester';$env:GIT_COMMITTER_NAME='Tester';$env:GIT_AUTHOR_EMAIL='tester@example.com';$env:GIT_COMMITTER_EMAIL='tester@example.com'
 $env:GIT_CONFIG_GLOBAL=Join-Path $root 'no-global-config';$env:GIT_CONFIG_NOSYSTEM='1'
 function Repo{& git -C $root -c core.autocrlf=false -c commit.gpgsign=false -c core.hooksPath=no-hooks @args 2>&1|Out-Null;if($LASTEXITCODE){throw ('git '+($args -join ' ')+' failed')}}
 function Guard{$out=& pwsh -NoProfile -File (Join-Path $root 'Test-PrivacyGuard.ps1') @args 2>&1;[pscustomobject]@{Code=$LASTEXITCODE;Text=(@($out) -join "`n")}}
 # One commit that adds a file, checked as the last commit, then taken back.
 function Blocks([scriptblock]$Make,[string]$Message='case'){& $Make;Repo add -A;Repo commit -q -m $Message;$r=Guard;Repo reset -q --hard HEAD~1;$r.Code -eq 1}
 function Text([string]$Name,[string]$Value,$Encoding=[Text.UTF8Encoding]::new($false)){[IO.File]::WriteAllText((Join-Path $root $Name),$Value,$Encoding)}
 Repo init -q;Repo add -A;Repo commit -q -m 'base'
 $base=(& git -C $root rev-parse HEAD)
 Assert ((Guard).Code -eq 0) 'a repository without private details passes'
 $r={Text 'a.txt' $secret};& $r;Repo add -A;Repo commit -q -m 'case';$g=Guard;Repo reset -q --hard HEAD~1
 Assert ($g.Code -eq 1 -and $g.Text -match 'volume identifier' -and $g.Text -match 'user profile path' -and $g.Text -match 'email address' -and -not $g.Text.Contains($mail)) 'an email, a profile path and a volume identifier in a text file are blocked, and CI does not repeat them'

 # --- Files that are not plain UTF-8 -------------------------------------------------------------
 Assert (Blocks {Text 'a.txt' $secret ([Text.UnicodeEncoding]::new($false,$true))}) 'a UTF-16 file with a byte order mark is read, not skipped'
 Assert (Blocks {Text 'a.txt' $secret ([Text.UnicodeEncoding]::new($true,$true))}) 'a big-endian UTF-16 file is read too'
 Assert (Blocks {Text 'a.txt' $secret ([Text.UnicodeEncoding]::new($false,$false))}) 'UTF-16 text without a byte order mark is found'
 Assert (Blocks {[IO.File]::WriteAllBytes((Join-Path $root 'a.dat'),[byte[]](0)+[Text.Encoding]::ASCII.GetBytes($secret))}) 'one zero byte in front does not hide plain text'
 $noise=[byte[]]::new(300KB);[Random]::new(20261112).NextBytes($noise)
 Assert (-not (Blocks {[IO.File]::WriteAllBytes((Join-Path $root 'noise.bin'),$noise);Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'DevDriveBackup.ico'),(Join-Path $PSScriptRoot 'design\icon\icon-routes.png') -Destination $root})) 'real binary files (an icon, a picture, random bytes) raise no alarm'

 Text 'empty.txt' '';Text 'one.txt' 'x';Repo add -A;Repo commit -q -m 'small files';$g=Guard;Repo reset -q --hard HEAD~1
 Assert ($g.Code -eq 0 -and $g.Text -match '^PASS') 'an empty file and a one-byte file are checked without an error'

 # --- Profile paths and addresses ----------------------------------------------------------------
 Assert (Blocks {Text 'a.txt' ('cd /c/Us'+'ers/johnsmith/work')}) 'a Git Bash profile path (/c/...) is blocked'
 Assert (Blocks {Text 'a.txt' ('ls /mnt/c/Us'+'ers/johnsmith')}) 'a WSL profile path (/mnt/c/...) is blocked'
 Assert (-not (Blocks {Text 'a.txt' ('see https://example.com/c/Us'+'ers/guide and /c/Us'+'ers/YOUR_USER/x and C:\Us'+'ers\YOUR_USER\x')})) 'a web address and the YOUR_USER placeholder are not profile paths'
 Assert (Blocks {Text 'a.txt' ('john.noreply.smith@'+'realmail.io')}) 'an address that merely contains "noreply" is blocked'
 Assert (-not (Blocks {Text 'a.txt' ('12345+bob@'+'users.noreply.github.com noreply@'+'anthropic.com no-reply@'+'github.com someone@example.com')})) 'no-reply senders, GitHub''s private addresses and example.com stay allowed'
 Assert (Blocks {Text 'a.txt' 'x'} "fix for $mail") 'the last commit''s message is checked'

 # --- Every commit of a push (-Range) --------------------------------------------------------------
 Text 'note.txt' $secret;Repo add -A;Repo commit -q -m 'add a note'
 Remove-Item -LiteralPath (Join-Path $root 'note.txt');Repo add -A;Repo commit -q -m 'remove the note'
 Assert ((Guard).Code -eq 0) 'without a range only the newest state is checked (what the hooks see)'
 $g=Guard -Range "$base..HEAD"
 Assert ($g.Code -eq 1 -and $g.Text -match 'note\.txt' -and -not $g.Text.Contains($mail)) 'a private detail added in one pushed commit and removed in the next is blocked'
 Repo reset -q --hard $base
 Text 'b.txt' 'one';Repo add -A;Repo commit -q -m "note for $mail"
 Text 'b.txt' 'two';Repo add -A;Repo commit -q -m 'tidy'
 Assert ((Guard -Range "$base..HEAD").Code -eq 1) 'the message of every pushed commit is checked, not only the last'
 Repo reset -q --hard $base
 Text 'b.txt' 'one';Repo add -A;Repo commit -q -m 'one';Text 'b.txt' 'two';Repo add -A;Repo commit -q -m 'two'
 Assert ((Guard -Range "$base..HEAD").Code -eq 0) 'clean pushed commits pass'
 $g=Guard -Range ('0123456789abcdef0123456789abcdef01234567'+'..HEAD')
 Assert ($g.Code -eq 0 -and $g.Text -match 'could not be listed') 'a range git cannot resolve (a forced push) falls back to the newest commit and says so'
 Repo reset -q --hard $base

 # --- The hooks ------------------------------------------------------------------------------------
 $m=Join-Path $root 'msg.txt';[IO.File]::WriteAllText($m,"subject`n`nbody $mail`n")
 Assert ((Guard -MessageFile $m).Code -eq 1) 'the commit-msg hook blocks a private detail in the message'
 [IO.File]::WriteAllText($m,"subject`n`nCo-Authored-By: Someone <noreply@"+"anthropic.com>`n")
 Assert ((Guard -MessageFile $m).Code -eq 0) 'a co-author line with a no-reply address passes the commit-msg hook'
 Remove-Item -LiteralPath $m
 Text 'c.txt' $secret ([Text.UnicodeEncoding]::new($false,$true));Repo add c.txt;Text 'c.txt' 'clean'
 Assert ((Guard -Staged).Code -eq 1) 'the pre-commit hook checks what is staged, UTF-16 included, not the working copy'
 Repo reset -q --hard $base

 # --- Private values from the local settings (made-up ones, handed in for the test) ------------------
 $long='Zephyr'+'Workbench';$short='Qu'+'ark7'
 $env:PRIVACY_GUARD_TEST_TERMS="$long;$short"
 Text 'd.txt' "the $long drive";Repo add -A;Repo commit -q -m 'case';$g=Guard;Repo reset -q --hard HEAD~1
 Assert ($g.Code -eq 1 -and $g.Text -match 'Blocked: 1 ') 'a private value on its own is blocked, and reported once'
 Assert (Blocks {Text 'd.txt' ("path=my${long}Copy2")}) 'a long private value (8 characters or more) is found inside a longer word too'
 Assert (Blocks {Text 'd.txt' "label $short here"}) 'a short private value on its own is blocked'
 Assert (-not (Blocks {Text 'd.txt' ("x${short}y is another word")})) 'a short private value inside a longer word is still left alone, so ordinary words raise no alarm'
 $env:PRIVACY_GUARD_TEST_TERMS=$null
 Assert (-not (Blocks {Text 'd.txt' "the $long drive"})) 'without the test values the same text passes: nothing is remembered'
}finally{
 foreach($n in $keep.Keys){[Environment]::SetEnvironmentVariable($n,$keep[$n])}
 if(Test-Path -LiteralPath $root){Remove-Item -LiteralPath $root -Recurse -Force}
}
Write-Output 'All privacy guard rule tests passed.'
