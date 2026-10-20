param([string]$OutputPath=(Join-Path $env:LOCALAPPDATA 'DevDriveMirror\hardware.json'))
$ErrorActionPreference='Stop'
$result=[ordered]@{
 CPU=Get-CimInstance Win32_Processor|Select-Object Name,NumberOfCores,NumberOfLogicalProcessors,MaxClockSpeed
 System=Get-CimInstance Win32_ComputerSystem|Select-Object Manufacturer,Model,TotalPhysicalMemory
 OS=Get-CimInstance Win32_OperatingSystem|Select-Object Caption,Version,FreePhysicalMemory,TotalVisibleMemorySize
 RAM=Get-CimInstance Win32_PhysicalMemory|Select-Object Manufacturer,Capacity,Speed,ConfiguredClockSpeed
 GPU=Get-CimInstance Win32_VideoController|Select-Object Name,DriverVersion
 Disks=Get-Disk|Select-Object Number,FriendlyName,BusType,Size,OperationalStatus
 Partitions=Get-Partition|Select-Object DiskNumber,DriveLetter,Size
 Volumes=Get-Volume|Select-Object DriveLetter,FileSystemLabel,FileSystem,Size,SizeRemaining
}
New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($OutputPath))) -Force|Out-Null
$result|ConvertTo-Json -Depth 6|Set-Content -LiteralPath $OutputPath
Write-Output $OutputPath
