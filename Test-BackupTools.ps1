#Requires -Version 7.2
# Checks rules inside the drive tools that need no drive: which destinations Set-BackupDestination.ps1
# refuses because they share a physical disk with the source. The two functions are taken out of the
# script's text and run on made-up disks, so the script itself (which measures a real drive) never runs.
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
function Assert($ok,$message){if(-not $ok){throw "FAIL $message"};Write-Output ('PASS '+$message)}
$script=Join-Path $PSScriptRoot 'Set-BackupDestination.ps1'
$ast=[Management.Automation.Language.Parser]::ParseFile($script,[ref]$null,[ref]$null)
$functions=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -in 'Get-BackupPhysicalDisk','Get-BackupSameDiskReason'},$true))
Assert ($functions.Count -eq 2) 'Set-BackupDestination.ps1 keeps its same-disk rule in two functions that can be tested'
foreach($f in $functions){. ([scriptblock]::Create($f.Extent.Text))}

# Disk 0: internal drive (C:). Disk 1: USB drive (Y:). Disks 2 and 3: virtual disks whose files are on
# C: (a Dev Drive, E:, and another, Z:). Disk 4: a virtual disk whose file is on the USB drive (V:).
# Disk 5: a virtual disk inside the Dev Drive (W:). Disk 6: a virtual disk on a network share.
function Disk([int]$Number,[string]$Bus,[string]$Location=''){[pscustomobject]@{Number=$Number;BusType=$Bus;Location=$Location}}
$disks=@{C=(Disk 0 'NVMe' 'PCI Slot 4');Y=(Disk 1 'USB' 'Integrated : Adapter 0');E=(Disk 2 'File Backed Virtual' 'C:\vhd\dev.vhdx');Z=(Disk 3 'File Backed Virtual' 'c:\vhd\backup.vhdx')
 V=(Disk 4 'File Backed Virtual' 'Y:\copy.vhdx');W=(Disk 5 'File Backed Virtual' 'E:\inner.vhdx');N=(Disk 6 'File Backed Virtual' '\\server\share\x.vhdx')}
$lookup={param($Letter) $disks[$Letter.ToUpperInvariant()]}
function Reason([string]$Source,[string]$Destination){Get-BackupSameDiskReason $disks[$Source] $disks[$Destination] $lookup}

Assert ((Reason 'C' 'Y') -eq '' -and (Reason 'E' 'Y') -eq '') 'a separate physical drive is accepted, also for a Dev Drive in a file'
Assert ((Reason 'C' 'C') -match 'same disk as the source') 'the source''s own disk is refused'
Assert ((Reason 'E' 'C') -match 'holds the Dev Drive file \(C:\\vhd\\dev\.vhdx\)') 'the disk that holds the Dev Drive file is refused'
Assert ((Reason 'C' 'Z') -match 'virtual disk whose file \(c:\\vhd\\backup\.vhdx\) is on the source''s physical disk') 'a destination that is a virtual disk stored on the source''s disk is refused'
Assert ((Reason 'E' 'Z') -match 'same physical disk') 'two virtual disks whose files share one physical disk are refused'
Assert ((Reason 'W' 'C') -ne '' -and (Reason 'C' 'W') -ne '') 'a virtual disk inside another is followed down to the physical disk'
Assert ((Reason 'Y' 'V') -ne '' -and (Reason 'E' 'V') -eq '' -and (Reason 'C' 'V') -eq '') 'the rule is the same in both directions and only for a shared physical disk'
Assert ((Reason 'C' 'N') -eq '' -and (Reason 'N' 'Y') -eq '') 'a virtual disk whose file has no drive letter is judged by its own disk number'
Assert ((Get-BackupSameDiskReason $disks['E'] $disks['Y'] {param($Letter) throw 'no such drive'}) -eq '') 'a host disk that cannot be found is not reported as the same disk'

$text=Get-Content -LiteralPath $script -Raw
Assert ($text -notmatch 'recovery-key file in Documents' -and $text -match 'Split-Path -Parent \$fresh\.RecoveryKeyPath') 'the closing message names the folder the recovery key is really written to'
Write-Output 'All drive tool rule tests passed.'
