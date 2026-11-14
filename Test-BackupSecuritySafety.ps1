#Requires -Version 7.2
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'Backup.Security.psm1') -Force
function Assert($ok,$message){if(-not $ok){throw $message};Write-Output ('PASS '+$message)}
# A refusal counts only when it is the expected one: any other error (a typo, a missing function) fails the test.
function Refuses($action,[string]$like,$message){$refused=$false;try{& $action}catch{if($_.Exception.Message -notlike $like){throw "$message (unexpected error: $($_.Exception.Message))"};$refused=$true};Assert $refused $message}
$root=Join-Path $env:TEMP ('DevDriveSecuritySafety-'+[guid]::NewGuid().ToString('N'));$source=Join-Path $root 'source';$outside=Join-Path $root 'outside';New-Item -ItemType Directory -Path $root,$source,$outside|Out-Null
try{
 Refuses {Assert-NewBackupPassword 'short'} 'Use 12*characters*' 'short password is refused'
 Refuses {Assert-NewBackupPassword "long-enough-but`nmultiline"} 'Use 12*characters*' 'multiline password is refused'
 Refuses {Assert-NewBackupPassword ' leading-space-password'} 'Use 12*characters*' 'leading whitespace is refused'
 $key=Join-Path $outside 'key.txt';New-PrivateTextFile $key 'nonsecret test value'
 $acl=Get-Acl -LiteralPath $key
 Assert ($acl.AreAccessRulesProtected -and $acl.Access.Count -eq 2) 'file starts with a protected two-principal ACL'
 Refuses {New-PrivateTextFile $key 'must not replace'} '*already exists*' 'private file creation never overwrites existing data'
 Assert ([IO.File]::ReadAllText($key) -ceq 'nonsecret test value') 'failed overwrite leaves existing data intact'
 Set-PrivateTextFile $key 'replacement nonsecret value'
 Assert ([IO.File]::ReadAllText($key) -ceq 'replacement nonsecret value' -and (Get-Acl -LiteralPath $key).AreAccessRulesProtected) 'atomic private-file replacement preserves restricted permissions'
 Refuses {Assert-PrivateExportPath (Join-Path $source 'key.txt') @($source) @()} '*outside the source*' 'source directory cannot hold the portable key'
 Refuses {Assert-PrivateExportPath $key @($source) @($key)} '*must differ*' 'credential and configuration paths cannot be overwritten by export'
 Refuses {Assert-PrivateExportPath 'relative-key.txt' @($source) @()} '*full recovery-key file path*' 'relative export paths are refused'
 Refuses {Assert-PrivateExportPath ($key+':hidden.txt') @($source) @()} '*alternate streams*' 'alternate data-stream export is refused'
 $link=Join-Path $root 'linked';New-Item -ItemType Junction -Path $link -Target $outside|Out-Null
 Refuses {Assert-PrivateExportPath (Join-Path $link 'key.txt') @($source) @()} '*Linked recovery-key paths*' 'linked export ancestors are refused'
 # Compare full forms: a temp path with a short (8.3) name, as on CI runners, comes back expanded.
 Assert ((Assert-PrivateExportPath (Join-Path $outside 'new-key.txt') @($source) @()) -eq [IO.Path]::GetFullPath((Join-Path $outside 'new-key.txt'))) 'new outside recovery path is accepted'
}finally{
 # Remove the link first so the clean-up can never follow it out of the test folder.
 if($link -and (Test-Path -LiteralPath $link)){[IO.Directory]::Delete($link)}
 if(Test-Path -LiteralPath $root){Remove-Item -LiteralPath $root -Recurse -Force}
}
