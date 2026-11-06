#Requires -Version 7.2
# DevDriveBackup colours: built-in themes, a custom theme derived from four chosen colours, the
# status colours that suit a light or dark theme, WCAG contrast, and the saved choice.
# Colours are '#RRGGBB' strings here; the window turns them into System.Drawing colours.
Set-StrictMode -Version Latest

# Roles: Paper = window background, Surface = panels and fields, Ink = text, Muted = secondary text,
# Line = borders and dividers, Select = selected rows and hover, Accent = main buttons,
# OnAccent = text on Accent, AccentHover = Accent under the mouse.
$script:Roles='Paper','Surface','Ink','Muted','Line','Select','Accent','OnAccent','AccentHover'
$script:Themes=[ordered]@{
 'Light'      =[ordered]@{Dark=$false;Paper='#ECF0EF';Surface='#FFFFFF';Ink='#1F2A2E';Muted='#56636A';Line='#CED6D8';Select='#DCE5E9';Accent='#1F2A2E';OnAccent='#FFFFFF';AccentHover='#37464C'}
 'Dark'       =[ordered]@{Dark=$true; Paper='#151A1C';Surface='#1F2629';Ink='#E6ECEB';Muted='#A3B1B5';Line='#3A4549';Select='#2E3A3F';Accent='#3FB37A';OnAccent='#0D1A13';AccentHover='#57C48D'}
 'Sand'       =[ordered]@{Dark=$false;Paper='#F2EEE6';Surface='#FFFDF8';Ink='#2B2620';Muted='#665D52';Line='#DDD5C8';Select='#ECE4D6';Accent='#8A4B2A';OnAccent='#FFFFFF';AccentHover='#A05A35'}
 'Ocean'      =[ordered]@{Dark=$true; Paper='#0F1724';Surface='#172233';Ink='#E4ECF5';Muted='#A2B3C7';Line='#2E3E54';Select='#22324A';Accent='#4C9BE8';OnAccent='#06111E';AccentHover='#6AAFF0'}
 'High contrast'=[ordered]@{Dark=$true;Paper='#000000';Surface='#101010';Ink='#FFFFFF';Muted='#D6D6D6';Line='#9A9A9A';Select='#2E2E2E';Accent='#FFD400';OnAccent='#000000';AccentHover='#FFE34D'}
}
# Status colours: Color for stripes and the large age number, Ink for small status text.
$script:States=@{
 Light=@{Color=@{Fresh='#2E8B57';OK='#5C7C8F';Stale='#C7822A';Never='#9AA3A8';Error='#B22222'};Ink=@{Fresh='#1E6E42';OK='#425E6E';Stale='#8A520A';Never='#5A6469';Error='#B22222'}}
 Dark =@{Color=@{Fresh='#3FB37A';OK='#7FA6BD';Stale='#E0A040';Never='#7E8B90';Error='#E5534B'};Ink=@{Fresh='#6BD19B';OK='#A7C4D6';Stale='#F2BC66';Never='#AEB9BD';Error='#FF8A80'}}
}

function ConvertFrom-CenterHex([string]$Hex){
 if($Hex -notmatch '^#?([0-9A-Fa-f]{6})$'){throw "Not a colour: '$Hex' (use #RRGGBB)"}
 $v=[Convert]::ToInt32($matches[1],16);@((($v -shr 16) -band 255),(($v -shr 8) -band 255),($v -band 255))
}
function ConvertTo-CenterHex([int[]]$Rgb){'#{0:X2}{1:X2}{2:X2}' -f [math]::Max(0,[math]::Min(255,$Rgb[0])),[math]::Max(0,[math]::Min(255,$Rgb[1])),[math]::Max(0,[math]::Min(255,$Rgb[2]))}
function Get-CenterLuminance([string]$Hex){
 $c=ConvertFrom-CenterHex $Hex|ForEach-Object {$s=$_/255.0;if($s -le 0.04045){$s/12.92}else{[math]::Pow(($s+0.055)/1.055,2.4)}}
 0.2126*$c[0]+0.7152*$c[1]+0.0722*$c[2]
}
function Get-CenterContrast([string]$A,[string]$B){
 # WCAG 2.2 contrast ratio, unrounded. 4.5 is the minimum for normal text, 3 for large text and borders.
 $l1=Get-CenterLuminance $A;$l2=Get-CenterLuminance $B
 (([math]::Max($l1,$l2))+0.05)/(([math]::Min($l1,$l2))+0.05)
}
function Join-CenterColor([string]$From,[string]$To,[double]$Amount){
 # $Amount 0 = $From, 1 = $To.
 $a=ConvertFrom-CenterHex $From;$b=ConvertFrom-CenterHex $To
 ConvertTo-CenterHex @(0..2|ForEach-Object {[int][math]::Round($a[$_]+($b[$_]-$a[$_])*$Amount)})
}

function Get-CenterThemeNames {@($script:Themes.Keys)+'Custom'}
function Get-CenterTheme([string]$Name,$Custom) {
 # A theme as an ordered table of roles, plus Dark and Name. 'Custom' needs -Custom (the four chosen colours).
 if($Name -eq 'Custom'){
  if(-not $Custom){throw 'A custom theme needs its colours.'}
  $t=New-CenterCustomTheme -Background $Custom.Background -Panels $Custom.Panels -Text $Custom.Text -Accent $Custom.Accent
 }else{
  if(-not $script:Themes.Contains($Name)){$Name='Light'}
  $t=[ordered]@{};foreach($k in $script:Themes[$Name].Keys){$t[$k]=$script:Themes[$Name][$k]}
 }
 $t['Name']=$Name;$t
}
function New-CenterCustomTheme {
 # Four colours in, a full theme out: secondary text, lines, selection and button text are derived so
 # they stay readable. Text that cannot reach 4.5:1 on the panels is left as chosen; the contrast check reports it.
 param([Parameter(Mandatory)][string]$Background,[Parameter(Mandatory)][string]$Panels,[Parameter(Mandatory)][string]$Text,[Parameter(Mandatory)][string]$Accent)
 foreach($c in $Background,$Panels,$Text,$Accent){[void](ConvertFrom-CenterHex $c)}
 $Background=ConvertTo-CenterHex (ConvertFrom-CenterHex $Background);$Panels=ConvertTo-CenterHex (ConvertFrom-CenterHex $Panels)
 $Text=ConvertTo-CenterHex (ConvertFrom-CenterHex $Text);$Accent=ConvertTo-CenterHex (ConvertFrom-CenterHex $Accent)
 $dark=(Get-CenterLuminance $Panels) -lt 0.18
 $select=Join-CenterColor $Panels $Text 0.10
 # Secondary text: as far toward the panels as it can go while staying readable on panels, background and selection.
 $muted=$Text
 foreach($t in 0.45,0.40,0.35,0.30,0.25,0.20,0.15,0.10,0.05){
  $m=Join-CenterColor $Text $Panels $t
  if((Get-CenterContrast $m $Panels) -ge 4.6 -and (Get-CenterContrast $m $Background) -ge 4.6 -and (Get-CenterContrast $m $select) -ge 4.6){$muted=$m;break}
 }
 $onAccent=if((Get-CenterContrast '#FFFFFF' $Accent) -ge (Get-CenterContrast '#000000' $Accent)){'#FFFFFF'}else{'#000000'}
 $hover=Join-CenterColor $Accent $(if($dark){'#FFFFFF'}else{'#000000'}) 0.15
 $t=[ordered]@{Dark=$dark;Paper=$Background;Surface=$Panels;Ink=$Text;Muted=$muted;Line=(Join-CenterColor $Panels $Text 0.22);Select=$select;Accent=$Accent;OnAccent=$onAccent;AccentHover=$hover}
 Resolve-CenterThemeClash $t
}
function Resolve-CenterThemeClash($Theme){
 # The window recolours a control by finding which role its old colour had, so two roles may not
 # share one colour. Nudge a later role by one step until all differ (invisible to the eye).
 $seen=@{}
 foreach($r in $script:Roles){
  $v=$Theme[$r];$rgb=ConvertFrom-CenterHex $v;$step=if((Get-CenterLuminance $v) -gt 0.5){-1}else{1}
  while($seen.ContainsKey($v)){$rgb=@($rgb|ForEach-Object {$_+$step});$v=ConvertTo-CenterHex $rgb}
  $seen[$v]=$true;$Theme[$r]=$v
 }
 $Theme
}
function Get-CenterStateColors([bool]$Dark){if($Dark){$script:States.Dark}else{$script:States.Light}}
function Test-CenterTheme($Theme) {
 # The pairs the window actually draws, with their WCAG ratio and the minimum each needs.
 $s=Get-CenterStateColors $Theme.Dark
 $pairs=@(
  @('Text on panels',$Theme.Ink,$Theme.Surface,4.5),@('Text on background',$Theme.Ink,$Theme.Paper,4.5),@('Text on selection',$Theme.Ink,$Theme.Select,4.5)
  @('Secondary text on panels',$Theme.Muted,$Theme.Surface,4.5),@('Secondary text on background',$Theme.Muted,$Theme.Paper,4.5),@('Secondary text on selection',$Theme.Muted,$Theme.Select,4.5)
  @('Button text',$Theme.OnAccent,$Theme.Accent,4.5),@('Button text, mouse over',$Theme.OnAccent,$Theme.AccentHover,4.5),@('Main button against panels',$Theme.Accent,$Theme.Surface,3)
 )
 foreach($k in 'Fresh','OK','Stale','Never','Error'){$pairs+=,@("Status '$k' text on panels",$s.Ink[$k],$Theme.Surface,4.5);$pairs+=,@("Status '$k' text on selection",$s.Ink[$k],$Theme.Select,4.5)}
 foreach($p in $pairs){$r=Get-CenterContrast $p[1] $p[2];[pscustomobject]@{Pair=$p[0];Ratio=[math]::Round($r,2);Needs=$p[3];Pass=($r -ge $p[3])}}
}

function Read-CenterAppearance([string]$Path) {
 $default=[pscustomobject]@{Theme='Light';Custom=[pscustomobject]@{Background='#ECF0EF';Panels='#FFFFFF';Text='#1F2A2E';Accent='#2E8B57'}}
 if(-not $Path -or -not(Test-Path -LiteralPath $Path)){return $default}
 try{$a=Get-Content -LiteralPath $Path -Raw|ConvertFrom-Json}catch{return $default}
 $theme=if($a.PSObject.Properties['Theme'] -and ([string]$a.Theme) -in (Get-CenterThemeNames)){[string]$a.Theme}else{'Light'}
 $custom=$default.Custom
 if($a.PSObject.Properties['Custom'] -and $a.Custom){
  $c=[ordered]@{};$ok=$true
  foreach($k in 'Background','Panels','Text','Accent'){if($a.Custom.PSObject.Properties[$k] -and [string]$a.Custom.$k -match '^#[0-9A-Fa-f]{6}$'){$c[$k]=([string]$a.Custom.$k).ToUpperInvariant()}else{$ok=$false}}
  if($ok){$custom=[pscustomobject]$c}
 }
 [pscustomobject]@{Theme=$theme;Custom=$custom}
}
function Save-CenterAppearance($Appearance,[string]$Path) {
 New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($Path)) -Force|Out-Null
 $tmp="$Path.tmp";($Appearance|ConvertTo-Json -Depth 4)|Set-Content -LiteralPath $tmp -Encoding utf8NoBOM;Move-Item -LiteralPath $tmp -Destination $Path -Force
}

Export-ModuleMember -Function ConvertFrom-CenterHex,ConvertTo-CenterHex,Get-CenterLuminance,Get-CenterContrast,Join-CenterColor,
 Get-CenterThemeNames,Get-CenterTheme,New-CenterCustomTheme,Get-CenterStateColors,Test-CenterTheme,Read-CenterAppearance,Save-CenterAppearance
