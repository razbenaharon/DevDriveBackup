# Atomic status delivery must not interrupt the backup engine when a UI reader
# briefly holds the previous file without delete sharing (common on Windows).
function Read-BackupStatus {
 param([Parameter(Mandatory)][string]$Path)
 $stream=[IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
 $reader=[IO.StreamReader]::new($stream)
 try {$reader.ReadToEnd()|ConvertFrom-Json} finally {$reader.Dispose()}
}
function Write-BackupStatus {
 param([Parameter(Mandatory)]$Value,[Parameter(Mandatory)][string]$Path,[switch]$BestEffort)
 $temp=$Path+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
 try {
  [IO.File]::WriteAllText($temp,($Value|ConvertTo-Json -Depth 8))
  for($attempt=0;$attempt -lt 20;$attempt++){
   try {
    if([IO.File]::Exists($Path)){[IO.File]::Replace($temp,$Path,[System.Management.Automation.Language.NullString]::Value)}
    else{[IO.File]::Move($temp,$Path)}
    return $true
   }
   catch [IO.IOException] {if($attempt -eq 19){if($BestEffort){return $false};throw}}
   catch [UnauthorizedAccessException] {if($attempt -eq 19){if($BestEffort){return $false};throw}}
   Start-Sleep -Milliseconds 25
  }
 }catch{if($BestEffort){return $false};throw}
 finally{if([IO.File]::Exists($temp)){try{[IO.File]::Delete($temp)}catch{}}}
}
function Get-EngineFailureText([string]$Stage,[int]$ExitCode,[string]$LockDetail='') {
 # What a failed restic step means, in plain words. Exit code 11 is a repository lock: a run that was
 # stopped, crashed or ran out of memory leaves its lock file behind and restic then refuses every
 # step that needs the repository to itself. This only explains it. The worker removes a lock that a
 # run on this computer left behind; $LockDetail is why it left this one in place (another computer,
 # a backup that is still running, a lock it could not judge), when it found out.
 $hint=if($ExitCode -eq 11 -and $LockDetail){"The backup repository is locked: $LockDetail Nothing is damaged and no saved version was lost, but this step could not run."}
  elseif($ExitCode -eq 11){'The backup repository is locked. An earlier run was stopped or crashed before it finished and left its lock behind, or another backup program is using this repository right now. Nothing is damaged and no saved version was lost, but this step could not run. Until the lock is removed, backups, checks and clean-up of this source will stop here.'}
  elseif($ExitCode -eq 12){'The stored password does not open this backup repository.'}
  elseif($Stage -eq 'DeletingHistory'){'History deletion may be partial. Refresh history before retrying.'}
  elseif($Stage -eq 'BackingUp'){'Code 3 means an incomplete snapshot.'}
  else{'The operation did not complete successfully.'}
 "Restic $Stage returned exit code $ExitCode. $hint See $Stage.errors.log."+$(if($ExitCode -notin 11,12){' A memory allocation failure requires a higher memory budget.'})
}
Export-ModuleMember -Function Read-BackupStatus,Write-BackupStatus,Get-EngineFailureText
