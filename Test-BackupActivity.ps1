#Requires -Version 7.2
# Checks the "are AI sessions still working" rule (Get-CenterAgentActivity) on disposable folders
# shaped like Claude Code's and Codex's conversation stores. Needs no drive.
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'BackupCenter.Data.psm1') -Force
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
 Write-Output 'All activity tests passed.'
}finally{if(Test-Path -LiteralPath $root){[IO.Directory]::Delete($root,$true)}}
