#Requires -Version 7.2
# Colour themes (DevDriveBackup.Theme.psm1): every built-in theme is readable by WCAG 2.2, custom themes
# derive readable colours, roles never share a colour, and the saved choice survives bad files. Needs no drive.
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'DevDriveBackup.Theme.psm1') -Force
function Assert($ok,[string]$message){if(-not $ok){throw "FAIL $message"};Write-Output "PASS $message"}
$roles='Paper','Surface','Ink','Muted','Line','Select','Accent','OnAccent','AccentHover'

Assert ([math]::Abs((Get-CenterContrast '#000000' '#FFFFFF')-21) -lt 0.001 -and [math]::Abs((Get-CenterContrast '#777777' '#777777')-1) -lt 0.001) 'contrast of black on white is 21:1, of a colour on itself 1:1'
Assert ((Get-CenterContrast '#767676' '#FFFFFF') -ge 4.5 -and (Get-CenterContrast '#777777' '#FFFFFF') -lt 4.5) 'the 4.5:1 line falls between #767676 and #777777 on white, unrounded'

$names=@(Get-CenterThemeNames)
Assert ($names[0] -eq 'Light' -and 'Dark' -in $names -and $names[-1] -eq 'Custom' -and $names.Count -ge 6) 'Light first, Dark among them, Custom last'
foreach($n in $names|Where-Object {$_ -ne 'Custom'}){
 $t=Get-CenterTheme $n
 $bad=@(Test-CenterTheme $t|Where-Object {-not $_.Pass})
 Assert (-not $bad.Count) ("theme '$n' passes every contrast pair"+$(if($bad.Count){': '+(($bad|ForEach-Object {"$($_.Pair) $($_.Ratio)"}) -join ', ')}))
 # The window recolours by role: background, panels, text, secondary text, lines and selection must differ.
 Assert (@($roles[0..5]|ForEach-Object {$t[$_]}|Select-Object -Unique).Count -eq 6) "theme '$n' keeps its six main roles apart"
}
Assert ((Get-CenterTheme 'No such theme').Name -eq 'Light') 'an unknown theme name falls back to Light'
# The check covers every text the window draws, also the large coloured ones (3:1 for large text): the age
# readout on the overview and the drive check summary use the status colour itself, not the status text colour.
$checked=@(Test-CenterTheme (Get-CenterTheme 'Light'))
Assert (@($checked|Where-Object {$_.Pair -like "Large status*on panels" -and $_.Needs -eq 3}).Count -eq 5 -and @($checked|Where-Object {$_.Pair -like "Status*text on background"}).Count -eq 5) 'the check includes the large status readouts and status text on the window background'
foreach($n in 'Light','Sand'){
 $never=@(Test-CenterTheme (Get-CenterTheme $n)|Where-Object {$_.Pair -eq "Large status 'Never' on panels"})[0]
 Assert ($never.Pass -and $never.Ratio -ge 3) "the large 'Never' readout is readable in theme '$n' ($($never.Ratio):1)"
}

$c=New-CenterCustomTheme -Background '#101418' -Panels '#1A2026' -Text '#F0F0F0' -Accent '#E86A33'
Assert ($c.Dark -and -not @(Test-CenterTheme $c|Where-Object {-not $_.Pass}).Count) 'a dark custom theme gets readable secondary text, selection and button text'
Assert (@($roles|ForEach-Object {$c[$_]}|Select-Object -Unique).Count -eq $roles.Count) 'custom roles never share a colour'
$same=New-CenterCustomTheme -Background '#FFFFFF' -Panels '#FFFFFF' -Text '#000000' -Accent '#000000'
Assert (@($roles|ForEach-Object {$same[$_]}|Select-Object -Unique).Count -eq $roles.Count) 'identical picks are nudged apart so the window can still tell the roles apart'
$poor=New-CenterCustomTheme -Background '#808080' -Panels '#8A8A8A' -Text '#9A9A9A' -Accent '#999999'
Assert (@(Test-CenterTheme $poor|Where-Object {-not $_.Pass -and $_.Pair -eq 'Text on panels'}).Count -eq 1) 'unreadable custom picks are reported, not hidden'
Assert ((New-CenterCustomTheme -Background '#ffffff' -Panels '#f5f5f5' -Text '#222222' -Accent '#ffd400').OnAccent -eq '#000000') 'a light button colour gets black text'
# Under the mouse a button moves away from its text colour, so the text never gets harder to read.
$start=(Read-CenterAppearance $null).Custom
$bad=@(Test-CenterTheme (Get-CenterTheme 'Custom' $start)|Where-Object {-not $_.Pass})
Assert (-not $bad.Count) ("the custom colours a new user starts from pass the check"+$(if($bad.Count){': '+(($bad|ForEach-Object {"$($_.Pair) $($_.Ratio)"}) -join ', ')}))
foreach($accent in '#2E8B57','#777777','#5A5A5A','#FFD400','#1F2A2E','#E86A33','#FFFFFF','#000000'){foreach($panels in '#FFFFFF','#1A2026'){
 $t=New-CenterCustomTheme -Background $panels -Panels $panels -Text $(if($panels -eq '#FFFFFF'){'#111111'}else{'#F0F0F0'}) -Accent $accent
 # Pure black and white have nowhere further to go and move toward the text, from 21:1 down to about 15:1.
 $rest=Get-CenterContrast $t.OnAccent $t.Accent;$over=Get-CenterContrast $t.OnAccent $t.AccentHover
 Assert ($t.AccentHover -ne $t.Accent -and ($over -ge $rest -or $over -ge 7)) "button $accent on $panels panels: under the mouse it changes and its text stays as readable ($([math]::Round($rest,1)) to $([math]::Round($over,1)):1)"
}}
try{[void](New-CenterCustomTheme -Background 'red' -Panels '#FFFFFF' -Text '#000000' -Accent '#000000');throw 'FAIL no error'}catch{Assert ($_.Exception.Message -like 'Not a colour*') 'a colour that is not #RRGGBB is refused'}

$dir=Join-Path ([IO.Path]::GetTempPath()) ('backup-theme-test-'+[guid]::NewGuid().ToString('N').Substring(0,8))
try{
 $f=Join-Path $dir 'appearance.json'
 $a=Read-CenterAppearance $f
 Assert ($a.Theme -eq 'Light' -and $a.Custom.Background -match '^#[0-9A-F]{6}$') 'no saved choice: Light, with starting custom colours'
 $a.Theme='Custom';$a.Custom.Accent='#123456';Save-CenterAppearance $a $f
 $b=Read-CenterAppearance $f
 Assert ($b.Theme -eq 'Custom' -and $b.Custom.Accent -eq '#123456') 'the choice and custom colours survive saving'
 Set-Content -LiteralPath $f -Value '{ broken'
 Assert ((Read-CenterAppearance $f).Theme -eq 'Light') 'a damaged file falls back to Light instead of stopping the window'
 Set-Content -LiteralPath $f -Value '{"Theme":"Purple","Custom":{"Background":"blue","Panels":"#FFFFFF","Text":"#000000","Accent":"#000000"}}'
 $d=Read-CenterAppearance $f
 Assert ($d.Theme -eq 'Light' -and $d.Custom.Background -ne 'blue') 'unknown theme names and bad colours in the file are ignored'
 foreach($odd in 'null','','[1]','"Dark"','{"Theme":5}','{"Theme":"Custom","Custom":"x"}'){
  [IO.File]::WriteAllText($f,$odd)
  $d=$null;try{$d=Read-CenterAppearance $f}catch{}
  Assert ($d -and $d.Theme -in (Get-CenterThemeNames) -and $d.Custom.Background -match '^#[0-9A-F]{6}$' -and [IO.File]::ReadAllText($f) -ceq $odd) "a file holding $(if($odd){$odd}else{'nothing'}) gives the default look and is left as it is"
 }
}finally{if(Test-Path -LiteralPath $dir){Remove-Item -LiteralPath $dir -Recurse -Force}}
Write-Output 'All theme tests passed.'
