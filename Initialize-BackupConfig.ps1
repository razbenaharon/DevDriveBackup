#Requires -Version 7.2
param([Parameter(Mandatory)][string]$Source,[Parameter(Mandatory)][ValidatePattern('^[A-Za-z]$')][string]$DestinationDrive,[string]$ConfigPath=(Join-Path $PSScriptRoot 'backup.local.json'))
$ErrorActionPreference='Stop'
if(Test-Path -LiteralPath $ConfigPath){throw 'Configuration already exists. Edit it explicitly; initialization never overwrites it.'}
$root=[IO.Path]::GetFullPath($Source).TrimEnd('\')+'\'
if(-not(Test-Path -LiteralPath $root -PathType Container)){throw 'Source directory does not exist'}
$src=Get-Volume -DriveLetter $root.Substring(0,1);$dst=Get-Volume -DriveLetter $DestinationDrive
if($src.UniqueId -eq $dst.UniqueId){throw 'Source and backup must use different volumes'}
$config=Get-Content (Join-Path $PSScriptRoot 'config.example.json') -Raw|ConvertFrom-Json
$config.Source=$root;$config.SourceVolumeId=$src.UniqueId;$config.DestinationVolumeId=$dst.UniqueId
$keyId=[guid]::NewGuid().ToString('N')
$config.PasswordDpapiPath=Join-Path $env:LOCALAPPDATA ('DevDriveMirror\'+$keyId+'.dpapi')
$config.RecoveryKeyPath=Join-Path (Join-Path $env:USERPROFILE 'Backup Center recovery keys') ('DevDrive-'+$keyId+'-recovery-key.txt')
$config.Choices=@(Get-ChildItem -LiteralPath $root -Directory -Force|Where-Object {$_.Name -notin @('$RECYCLE.BIN','System Volume Information') -and -not($_.Attributes -band [IO.FileAttributes]::ReparsePoint)}|ForEach-Object {[pscustomobject]@{Path=$_.Name;Mode=$(if($_.Name -in @('Packages','.pnpm-store','Temp','tmp','node_modules','.venv','venv')){'Skip'}else{'Both'});Reason='Review: preserve unique source, data, configuration and local changes'}})
if(@($config.Choices|Where-Object {$_.Mode -eq 'Both'}).Count -eq 0){foreach($c in $config.Choices){$c.Mode='Both'}}
# Include is informational; both tools derive their selection from each Mode.
$config.Include=@($config.Choices|Where-Object {$_.Mode -eq 'Both'}|ForEach-Object {$_.Path})
$config|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $ConfigPath
Write-Output "Created $ConfigPath. Review source selections and exclusions in Backup-Manager.ps1 before backing up."
