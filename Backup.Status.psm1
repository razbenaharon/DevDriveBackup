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
Export-ModuleMember -Function Read-BackupStatus,Write-BackupStatus
