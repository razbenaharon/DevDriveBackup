#Requires -Version 7.2
# Downloads an official, pinned smartmontools release (smartctl reads a drive's own health report
# and starts its self-tests) and installs only smartctl and its drive database into bin\smartmontools.
# The Windows release is an installer that always asks for administrator rights. It runs silently
# with just those two parts selected: no service, Start menu entry, PATH change or uninstall entry.
$ErrorActionPreference='Stop'
$version='7.5'
$expected='896337FCC253220614CF8CDBD5CF2321C5AA326A37A04160A672A281E6104C70'
$dir=Join-Path $PSScriptRoot 'bin'
$target=Join-Path $dir 'smartmontools'
$tool=Join-Path $target 'bin\smartctl.exe'
New-Item -ItemType Directory -Path $dir -Force|Out-Null
$setup=Join-Path $dir "smartmontools-$version.win32-setup.exe"
if(-not(Test-Path -LiteralPath $setup)){
 # Download under a temporary name and keep it only if the checksum matches, as Install-BackupEngine.ps1 does.
 $part=$setup+'.part'
 try{
  Invoke-WebRequest "https://github.com/smartmontools/smartmontools/releases/download/RELEASE_$($version -replace '\.','_')/smartmontools-$version.win32-setup.exe" -OutFile $part
  if((Get-FileHash -LiteralPath $part -Algorithm SHA256).Hash -ne $expected){throw 'Downloaded health tool checksum mismatch. Refusing to run it.'}
  Move-Item -LiteralPath $part -Destination $setup
 }finally{if(Test-Path -LiteralPath $part){Remove-Item -LiteralPath $part}}
}
if((Get-FileHash -LiteralPath $setup -Algorithm SHA256).Hash -ne $expected){throw 'The health tool installer in bin does not match the pinned checksum. Delete it and run this script again.'}
# NSIS rules: /D= comes last and is never quoted, even when the path has spaces.
$p=Start-Process -FilePath $setup -ArgumentList "/S /SO x64,smartctl,drivedb /D=$target" -Verb RunAs -Wait -PassThru
if($p.ExitCode){throw "The health tool installer stopped with code $($p.ExitCode)."}
$v=& $tool -V
if($LASTEXITCODE -ne 0 -or -not ($v -match "smartctl $([regex]::Escape($version))")){throw 'Health tool self-check failed'}
Write-Output ($v|Select-Object -First 1)
