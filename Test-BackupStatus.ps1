#Requires -Version 7.2
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'Backup.Status.psm1') -Force
$dir=Join-Path $env:TEMP ('DevDrive-StatusTest-'+[guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($dir)
$path=Join-Path $dir 'status.json'
[void](Write-BackupStatus @{State='Old'} $path)
$reader=[IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
try {
 $published=Write-BackupStatus @{State='New'} $path -BestEffort
 if($published -or (Read-BackupStatus $path).State -ne 'Old'){throw 'Locked status was not handled safely'}
 [void](Write-BackupStatus @{State='Completed'} (Join-Path $dir 'result.json'))
 if((Read-BackupStatus (Join-Path $dir 'result.json')).State -ne 'Completed'){throw 'Terminal result was not published independently'}
}finally{$reader.Dispose()}
if(-not(Write-BackupStatus @{State='New'} $path) -or (Read-BackupStatus $path).State -ne 'New'){throw 'Status did not recover after reader released its lock'}
$reader=[IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
try{if(-not(Write-BackupStatus @{State='Newest'} $path)){throw 'A delete-sharing reader blocked publication'}}finally{$reader.Dispose()}
if((Read-BackupStatus $path).State -ne 'Newest'){throw 'Updated status was not readable'}
Write-Output 'PASS: locked status is nonfatal, final results are independent, and delete-sharing readers allow atomic replacement'
