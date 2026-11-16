#Requires -Version 7.2
# One style rule that has caught real mistakes here: a variable or parameter that takes the name of
# one PowerShell sets itself ($args, $input, $matches, $error, $_ ...). Assigning to such a name can
# silently change or lose a value. Needs the PSScriptAnalyzer module, in the version this was checked with:
#   Install-Module PSScriptAnalyzer -RequiredVersion 1.25.0 -Scope CurrentUser
# Three names are allowed, because the code uses them on purpose and they are harmless there:
# $Profile (a backup drive's profile, a parameter name throughout; PowerShell's own $PROFILE is only
# the path of a start-up script) and $sender / $event (the two arguments of a window event handler;
# nothing here uses Register-ObjectEvent, where $Event has a meaning of its own, and this test fails
# if that ever changes). A finding this script cannot read is a failure, never a pass.
$ErrorActionPreference='Stop'
$version='1.25.0'
if(-not (Get-Module -ListAvailable PSScriptAnalyzer|Where-Object {$_.Version -eq $version})){throw "PSScriptAnalyzer $version is not installed. Run: Install-Module PSScriptAnalyzer -RequiredVersion $version -Scope CurrentUser"}
Import-Module PSScriptAnalyzer -RequiredVersion $version
$allowed=@('Profile','sender','event')
$files=@(Get-ChildItem -LiteralPath $PSScriptRoot -File|Where-Object {$_.Extension -in '.ps1','.psm1'})
$bad=@()
foreach($f in $files){
 foreach($r in @(Invoke-ScriptAnalyzer -Path $f.FullName -IncludeRule PSAvoidAssignmentToAutomaticVariable)){
  if($r.Message -match "^The Variable '(?<name>[^']+)' is an automatic variable\b" -and $Matches['name'] -in $allowed){continue}
  $bad+='{0}:{1} {2}' -f $f.Name,$r.Line,$r.Message
 }
 # Only a real call counts, not the word in a comment or a text.
 $tokens=$null;$errors=$null;$tree=[System.Management.Automation.Language.Parser]::ParseFile($f.FullName,[ref]$tokens,[ref]$errors)
 if(@($tree.FindAll({param($node)$node -is [System.Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Register-ObjectEvent'},$true)).Count){$bad+="$($f.Name) uses Register-ObjectEvent: there `$Event is PowerShell's own, so the name can no longer be allowed here"}
}
foreach($b in $bad){Write-Output "FAIL $b"}
if($bad.Count){Write-Output "$($bad.Count) problem(s) with names of built-in variables.";exit 1}
Write-Output "PASS no built-in variable is assigned to in $($files.Count) files"
