#Requires -Version 7.2
# Creates a "DevDriveBackup" shortcut with the program icon on the desktop (default) or in the Start menu.
param([ValidateSet('Desktop','StartMenu')][string]$Where='Desktop')
$ErrorActionPreference='Stop'
$folder=if($Where -eq 'Desktop'){[Environment]::GetFolderPath('Desktop')}else{Join-Path ([Environment]::GetFolderPath('Programs')) ''}
$path=Join-Path $folder 'DevDriveBackup.lnk'
$shell=New-Object -ComObject WScript.Shell
$link=$shell.CreateShortcut($path)
# The command name, not this process's path: a Store install keeps its version in the path, which
# changes with every update.
$pwsh=(Get-Command pwsh.exe -CommandType Application -ErrorAction SilentlyContinue|Select-Object -First 1).Source
$link.TargetPath=if($pwsh){$pwsh}else{(Get-Process -Id $PID).Path}
$link.Arguments='-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "'+(Join-Path $PSScriptRoot 'DevDriveBackup.ps1')+'"'
$link.WorkingDirectory=$PSScriptRoot
$link.IconLocation=(Join-Path $PSScriptRoot 'DevDriveBackup.ico')+',0'
$link.WindowStyle=7   # start minimised so the console does not flash
$link.Description='DevDriveBackup: backups to your drives, plain copies and versions'
$link.Save()
Write-Output $path
