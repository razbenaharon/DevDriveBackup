# Downloads an official, pinned Restic release; never changes PATH or requires admin.
$ErrorActionPreference='Stop'
$version='0.19.1'
$expected='DA948AD707ED690426473AABA2046CD61F8F90F6F0E7DAB6BE0D5796531DE67D'
$dir=Join-Path $PSScriptRoot 'bin'
New-Item -ItemType Directory -Path $dir -Force | Out-Null
$zip=Join-Path $dir "restic_${version}_windows_amd64.zip"
if(-not(Test-Path -LiteralPath $zip)){
 # Download under a temporary name and keep it only if the checksum matches, so a broken or
 # interrupted download never blocks the next attempt.
 $part=$zip+'.part'
 try{
  Invoke-WebRequest "https://github.com/restic/restic/releases/download/v$version/restic_${version}_windows_amd64.zip" -OutFile $part
  if((Get-FileHash -LiteralPath $part -Algorithm SHA256).Hash -ne $expected){throw 'Downloaded engine checksum mismatch. Refusing to execute it.'}
  Move-Item -LiteralPath $part -Destination $zip
 }finally{if(Test-Path -LiteralPath $part){Remove-Item -LiteralPath $part}}
}
if((Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash -ne $expected){throw 'The engine archive in bin does not match the pinned checksum. Delete it and run this script again.'}
Expand-Archive -LiteralPath $zip -DestinationPath $dir -Force
& (Join-Path $dir "restic_${version}_windows_amd64.exe") version
if($LASTEXITCODE -ne 0){throw 'Backup engine self-check failed'}
