function New-PrivateTextFile([string]$Path,[string]$Text) {
 $acl=[Security.AccessControl.FileSecurity]::new();$acl.SetAccessRuleProtection($true,$false)
 foreach($sid in @([Security.Principal.WindowsIdentity]::GetCurrent().User,[Security.Principal.SecurityIdentifier]::new('S-1-5-18'))){$acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($sid,'FullControl','Allow'))}
 $stream=[IO.FileSystemAclExtensions]::Create([IO.FileInfo]::new($Path),[IO.FileMode]::CreateNew,[Security.AccessControl.FileSystemRights]::FullControl,[IO.FileShare]::None,4096,[IO.FileOptions]::WriteThrough,$acl)
 try{$bytes=[Text.UTF8Encoding]::new($false).GetBytes($Text);$stream.Write($bytes,0,$bytes.Length);$stream.Flush($true)}finally{$stream.Dispose()}
}
function Set-PrivateTextFile([string]$Path,[string]$Text) {
 $temporary=$Path+'.'+[guid]::NewGuid().ToString('N')+'.dpapi'
 try{New-PrivateTextFile $temporary $Text;if([IO.File]::Exists($Path)){[IO.File]::Replace($temporary,$Path,[System.Management.Automation.Language.NullString]::Value)}else{[IO.File]::Move($temporary,$Path)}}
 finally{if([IO.File]::Exists($temporary)){[IO.File]::Delete($temporary)}}
}
function Assert-NewBackupPassword([string]$Password) {
 if($Password.Length -lt 12 -or $Password.Length -gt 1024 -or $Password -match '[\r\n\x00]' -or $Password -cne $Password.Trim()){throw 'Use 12–1024 characters, with no line breaks or leading/trailing whitespace.'}
}
function Assert-PrivateExportPath([string]$Path,[string[]]$ForbiddenRoots,[string[]]$ReservedPaths) {
 if(-not [IO.Path]::IsPathFullyQualified($Path)){throw 'Choose a full recovery-key file path'}
 $full=[IO.Path]::GetFullPath($Path)
 if($full.StartsWith('\\?\') -or $full.StartsWith('\\.\')){throw 'Choose a regular drive or network file path for the recovery key'}
 foreach($part in $full.Substring([IO.Path]::GetPathRoot($full).Length).Split('\')){if($part.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0){throw 'Recovery-key paths cannot contain alternate streams or invalid filename characters'}}
 foreach($root in $ForbiddenRoots){$boundary=[IO.Path]::GetFullPath($root).TrimEnd('\')+'\';if($full.StartsWith($boundary,[StringComparison]::OrdinalIgnoreCase) -or $full -ieq $boundary.TrimEnd('\')){throw 'Save the recovery key outside the source, repository and project folders'}}
 foreach($reserved in $ReservedPaths){if($full -ieq [IO.Path]::GetFullPath($reserved)){throw 'The recovery-key file must differ from configuration and protected credential files'}}
 $parent=[IO.Path]::GetDirectoryName($full)
 if(-not [IO.Directory]::Exists($parent)){throw 'Choose an existing parent folder for the recovery key'}
 $walk=$full
 while($walk){if(Test-Path -LiteralPath $walk){if((Get-Item -LiteralPath $walk -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Linked recovery-key paths are not allowed'}};$ancestor=[IO.Directory]::GetParent($walk);if(-not $ancestor){break};$walk=$ancestor.FullName}
 $full
}
function Get-RecoveryKeyText([string]$Repository,[string]$Password) {
 "Restic repository recovery key`r`nRepository: $Repository`r`nPassword: $Password`r`nKeep this file in a password manager or separate offline location. Anyone with this password can decrypt the backup.`r`n"
}
function Assert-RotationJournalTarget($Journal,[string]$VolumeId,[string]$Folder,[string]$Repository) {
 # A pending password change belongs to one repository. The backup drive can come back under another
 # letter between the interruption and the resume, so the repository is recognised by its volume and
 # folder. A journal written before those were recorded holds only the path: the same path, or the
 # same path under another drive letter, is accepted (the old password in the journal must still open
 # the repository before anything changes).
 $p=$Journal.PSObject.Properties
 if($p['DestinationVolumeId'] -and $p['RepositoryFolder'] -and $Journal.DestinationVolumeId -and $Journal.RepositoryFolder){
  if([string]$Journal.DestinationVolumeId -cne $VolumeId -or [string]$Journal.RepositoryFolder -ine $Folder){throw 'Password-change journal belongs to another configuration or repository'}
  return
 }
 $old=[string]$Journal.Repository
 if($old -and $old -ieq $Repository){return}
 if($old -match '^[A-Za-z]:\\.' -and $Repository -match '^[A-Za-z]:\\.' -and $old.Substring(1) -ieq $Repository.Substring(1)){return}
 throw 'Password-change journal belongs to another configuration or repository'
}
Export-ModuleMember -Function New-PrivateTextFile,Set-PrivateTextFile,Assert-NewBackupPassword,Assert-PrivateExportPath,Assert-RotationJournalTarget,Get-RecoveryKeyText
