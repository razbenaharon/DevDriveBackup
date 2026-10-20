@echo off
rem Starts Backup Center with PowerShell 7.2 or newer. Problems are shown, never swallowed.
where pwsh.exe >nul 2>&1
if errorlevel 1 (
 echo PowerShell 7.2 or newer is required. Install it from https://aka.ms/powershell and try again.
 pause
 exit /b 1
)
pwsh.exe -NoProfile -Command "exit [int]($PSVersionTable.PSVersion -lt [version]'7.2')"
if errorlevel 1 (
 echo PowerShell 7.2 or newer is required. Update it from https://aka.ms/powershell and try again.
 pause
 exit /b 1
)
start "" /b pwsh.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0Backup-Center.ps1"
