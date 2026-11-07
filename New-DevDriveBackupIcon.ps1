#Requires -Version 7.2
# Draws the DevDriveBackup icon from its vector sources in design\icon: a slate drive label with a
# green status stripe, label lines and an activity light, and a light rim that keeps it visible on
# a dark taskbar. 16 to 24 px use the separate small drawing (dev-drive-backup-small.svg), larger
# sizes the full one (dev-drive-backup.svg). Writes DevDriveBackup.ico with a PNG frame per size.
param([string]$OutputPath=(Join-Path $PSScriptRoot 'DevDriveBackup.ico'),[string]$PreviewPng)
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Drawing

# The two drawings as in the SVG files: x, y, width, height and corner radius on their own grid.
# A circle is a square whose corner radius is half its side.
$large=@{Grid=256;Body=@(20,40,216,176,30);Rim=8;Stripe=@(46,66,34,124,17);Light=@(181,159,30,30,15)
 Lines=@(@(104,78,104,26,13,'#ECF0EF'),@(104,124,66,26,13,'#7E9298'))}
$small=@{Grid=16;Body=@(0.5,2.5,15,11,2.5);Rim=1;Stripe=@(3,5,2,6,1);Light=@(11,9,2,2,1)
 Lines=@(,@(7,5,6,2,1,'#ECF0EF'))}

function New-RoundedPath([double[]]$R){
 $x=[single]$R[0];$y=[single]$R[1];$w=[single]$R[2];$h=[single]$R[3];$d=[single]([math]::Min(2*$R[4],[math]::Min($w,$h)))
 $p=[Drawing.Drawing2D.GraphicsPath]::new()
 $p.AddArc($x,$y,$d,$d,180,90);$p.AddArc($x+$w-$d,$y,$d,$d,270,90);$p.AddArc($x+$w-$d,$y+$h-$d,$d,$d,0,90);$p.AddArc($x,$y+$h-$d,$d,$d,90,90);$p.CloseFigure();$p
}
function Use-Brush([string]$Hex,[scriptblock]$Draw){$b=[Drawing.SolidBrush]::new([Drawing.ColorTranslator]::FromHtml($Hex));try{& $Draw $b}finally{$b.Dispose()}}
function New-Frame([int]$Size){
 $d=if($Size -le 24){$small}else{$large}
 $bmp=[Drawing.Bitmap]::new($Size,$Size,[Drawing.Imaging.PixelFormat]::Format32bppArgb)
 $g=[Drawing.Graphics]::FromImage($bmp)
 $paths=[Collections.Generic.List[IDisposable]]::new()
 try{
  $g.SmoothingMode='AntiAlias';$g.PixelOffsetMode='HighQuality';$g.Clear([Drawing.Color]::Transparent)
  $g.ScaleTransform([single]($Size/$d.Grid),[single]($Size/$d.Grid))
  $body=New-RoundedPath $d.Body;$paths.Add($body)
  $stripe=New-RoundedPath $d.Stripe;$paths.Add($stripe)
  $light=New-RoundedPath $d.Light;$paths.Add($light)
  Use-Brush '#1F2A2E' {param($b) $g.FillPath($b,$body)}
  $pen=[Drawing.Pen]::new([Drawing.ColorTranslator]::FromHtml('#6F868D'),[single]$d.Rim)
  try{$g.DrawPath($pen,$body)}finally{$pen.Dispose()}
  Use-Brush '#3FB37A' {param($b) $g.FillPath($b,$stripe);$g.FillPath($b,$light)}
  foreach($l in $d.Lines){$line=New-RoundedPath $l[0..4];$paths.Add($line);Use-Brush $l[5] {param($b) $g.FillPath($b,$line)}}
 }catch{$bmp.Dispose();throw}finally{$g.Dispose();foreach($p in $paths){$p.Dispose()}}
 $bmp
}

$sizes=@(16,20,24,32,40,48,64,96,128,256)
$frames=foreach($size in $sizes){
 $bmp=New-Frame $size;$ms=[IO.MemoryStream]::new()
 try{
  $bmp.Save($ms,[Drawing.Imaging.ImageFormat]::Png)
  if($PreviewPng -and $size -eq 256){$bmp.Save($PreviewPng,[Drawing.Imaging.ImageFormat]::Png)}
  [pscustomobject]@{Size=$size;Bytes=$ms.ToArray()}
 }finally{$bmp.Dispose();$ms.Dispose()}
}
# ICO container: header, one 16-byte entry per frame, then the PNG frames (Windows Vista and later).
$out=[IO.MemoryStream]::new();$w=[IO.BinaryWriter]::new($out)
try{
 $w.Write([int16]0);$w.Write([int16]1);$w.Write([int16]$frames.Count)
 $offset=6+16*$frames.Count
 foreach($f in $frames){
  $edge=if($f.Size -ge 256){0}else{$f.Size}   # 0 means 256 in an icon directory entry
  $w.Write([byte]$edge);$w.Write([byte]$edge);$w.Write([byte]0);$w.Write([byte]0);$w.Write([int16]1);$w.Write([int16]32);$w.Write([int]$f.Bytes.Length);$w.Write([int]$offset);$offset+=$f.Bytes.Length
 }
 foreach($f in $frames){$w.Write([byte[]]$f.Bytes)}
 $w.Flush();[IO.File]::WriteAllBytes($OutputPath,$out.ToArray())
}finally{$w.Dispose()}
Write-Output $OutputPath
