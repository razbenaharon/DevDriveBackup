#Requires -Version 7.2
# Creates a "Backup Center" shortcut with the program icon on the desktop (default) or in the Start menu.
param([ValidateSet('Desktop','StartMenu')][string]$Where='Desktop')
$ErrorActionPreference='Stop'
$folder=if($Where -eq 'Desktop'){[Environment]::GetFolderPath('Desktop')}else{Join-Path ([Environment]::GetFolderPath('Programs')) ''}
$path=Join-Path $folder 'Backup Center.lnk'
$shell=New-Object -ComObject WScript.Shell
$link=$shell.CreateShortcut($path)
$link.TargetPath=(Get-Process -Id $PID).Path
$link.Arguments='-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "'+(Join-Path $PSScriptRoot 'Backup-Center.ps1')+'"'
$link.WorkingDirectory=$PSScriptRoot
$link.IconLocation=(Join-Path $PSScriptRoot 'BackupCenter.ico')+',0'
$link.WindowStyle=7   # start minimised so the console does not flash
$link.Description='Backup Center: backups to your drives, plain copies and versions'
$link.Save()
Write-Output $path
