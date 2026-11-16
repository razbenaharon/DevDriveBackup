#Requires -Version 7.2
# Checks the "are AI sessions still working" rule (Get-CenterAgentActivity) on disposable folders
# shaped like Claude Code's and Codex's conversation stores. Needs no drive.
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'DevDriveBackup.Data.psm1') -Force
function Assert($ok,[string]$message){if(-not $ok){throw "FAIL $message"};Write-Output "PASS $message"}

$root=Join-Path ([IO.Path]::GetTempPath()) ('backup-activity-test-'+[guid]::NewGuid().ToString('N').Substring(0,10))
$claude=Join-Path $root 'claude';$codex=Join-Path $root 'codex'
try{
 $now=Get-Date
 $proj=Join-Path $claude 'C--Work-site';New-Item -ItemType Directory -Path (Join-Path $proj 'aaaa\subagents'),(Join-Path $codex '2026\01\02') -Force|Out-Null
 function New-Conv([string]$Path,[datetime]$When,[string]$Text=''){[IO.File]::WriteAllText($Path,$Text);[IO.File]::SetLastWriteTime($Path,$When)}
 $a=Get-CenterAgentActivity -ClaudeRoot $claude -CodexRoot $codex -Now $now -SkipProcesses
 Assert (-not $a.Busy -and $a.Sessions.Count -eq 0) 'empty stores: nothing is working'
 $a=Get-CenterAgentActivity -ClaudeRoot (Join-Path $root 'missing') -CodexRoot (Join-Path $root 'missing2') -Now $now -SkipProcesses
 Assert (-not $a.Busy) 'missing stores are not an error'

 New-Conv (Join-Path $proj 'old.jsonl') $now.AddMinutes(-45) '{"type":"custom-title","customTitle":"Old work"}'
 $a=Get-CenterAgentActivity -ClaudeRoot $claude -CodexRoot $codex -Now $now -QuietMinutes 10 -SkipProcesses
 Assert (-not $a.Busy -and ([datetime]$a.LastActivity) -lt $now.AddMinutes(-40)) 'a conversation quiet for 45 minutes does not count, but is the last activity'

 New-Conv (Join-Path $proj 'aaaa.jsonl') $now.AddMinutes(-30) ('{"type":"ai-title","aiTitle":"First name"}'+"`n"+'{"type":"custom-title","customTitle":"Fix the \"menu\" עברית"}')
 New-Conv (Join-Path $proj 'aaaa\subagents\agent-1.jsonl') $now.AddMinutes(-2)
 $a=Get-CenterAgentActivity -ClaudeRoot $claude -CodexRoot $codex -Now $now -QuietMinutes 10 -SkipProcesses
 Assert ($a.Busy -and $a.Sessions.Count -eq 1) 'a working helper agent makes its parent session busy, listed once'
 Assert ($a.Sessions[0].Name -eq 'Fix the "menu" עברית') 'the session is named by its newest title, Hebrew and quotes intact'

 New-Conv (Join-Path $proj 'bbbb.jsonl') $now.AddMinutes(-1) '{"type":"user"}'
 New-Conv (Join-Path $codex '2026\01\02\rollout-x.jsonl') $now.AddMinutes(-3)
 $a=Get-CenterAgentActivity -ClaudeRoot $claude -CodexRoot $codex -Now $now -QuietMinutes 10 -SkipProcesses
 Assert ($a.Sessions.Count -eq 3 -and $a.Sessions[0].Name -eq 'Work-site' -and @($a.Sessions|Where-Object Name -eq 'Codex session').Count -eq 1) 'untitled sessions use the project folder; Codex sessions count too; newest first'
 $a=Get-CenterAgentActivity -ClaudeRoot $claude -CodexRoot $codex -Now $now.AddMinutes(11) -QuietMinutes 10 -SkipProcesses
 Assert (-not $a.Busy) 'after the quiet minutes pass, nothing is working'

 # The 10-minute line itself, and times that are ahead of the clock.
 $edge=Join-Path $root 'edge';New-Item -ItemType Directory -Path (Join-Path $edge 'C--Edge')|Out-Null;$conv=Join-Path $edge 'C--Edge\a.jsonl'
 $busy={(Get-CenterAgentActivity -ClaudeRoot $edge -CodexRoot $codex -Now $now.AddHours(-1) -QuietMinutes 10 -SkipProcesses).Busy}
 New-Conv $conv $now.AddHours(-1).AddMinutes(-10)
 Assert (-not (& $busy)) 'a conversation last written exactly 10 minutes ago is quiet'
 New-Conv $conv $now.AddHours(-1).AddMinutes(-10).AddSeconds(1)
 Assert (& $busy) 'one written 9 minutes 59 seconds ago is still working'
 New-Conv $conv $now.AddHours(-1).AddMinutes(1)
 Assert (& $busy) 'a time one minute ahead (clocks differ a little) counts as now'
 New-Conv $conv $now.AddDays(2)
 $a=Get-CenterAgentActivity -ClaudeRoot $edge -CodexRoot $codex -Now $now.AddHours(-1) -QuietMinutes 10 -SkipProcesses
 Assert (-not $a.Busy -and -not $a.LastActivity) 'a time far ahead (copied file, clock set back) is not work: a waiting backup is not held up for days'

 # A running Codex program counts as work. The name is a parameter so this can be checked with a
 # program that certainly runs (this one) and one that certainly does not.
 $me=(Get-Process -Id $PID).ProcessName
 $a=Get-CenterAgentActivity -ClaudeRoot (Join-Path $root 'missing') -CodexRoot (Join-Path $root 'missing2') -Now $now -ProcessName $me
 Assert ($a.Busy -and $a.CodexPrograms -ge 1 -and $a.Sessions.Count -eq 0) 'a running program of the watched name makes the computer busy without any conversation'
 $a=Get-CenterAgentActivity -ClaudeRoot (Join-Path $root 'missing') -CodexRoot (Join-Path $root 'missing2') -Now $now -ProcessName ('no-such-program-'+[guid]::NewGuid().ToString('N'))
 Assert (-not $a.Busy -and $a.CodexPrograms -eq 0) 'no such program and no conversation: nothing is working'
 Write-Output 'All activity tests passed.'
}finally{if(Test-Path -LiteralPath $root){[IO.Directory]::Delete($root,$true)}}
