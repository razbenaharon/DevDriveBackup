#Requires -Version 7.2
# Draws the Backup Center icon: a slate drive label with a green status stripe and two
# label lines, the same marks the window uses for a backup drive. Writes BackupCenter.ico
# with bitmap frames for small sizes and a PNG frame for 256 px.
param([string]$OutputPath=(Join-Path $PSScriptRoot 'BackupCenter.ico'),[string]$PreviewPng)
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Drawing

$ink=[Drawing.Color]::FromArgb(31,42,46);$green=[Drawing.Color]::FromArgb(56,166,104);$line=[Drawing.Color]::FromArgb(214,224,226)

function New-RoundedPath([single]$X,[single]$Y,[single]$W,[single]$H,[single]$R){
 $p=[Drawing.Drawing2D.GraphicsPath]::new();$d=$R*2
 $p.AddArc($X,$Y,$d,$d,180,90);$p.AddArc($X+$W-$d,$Y,$d,$d,270,90);$p.AddArc($X+$W-$d,$Y+$H-$d,$d,$d,0,90);$p.AddArc($X,$Y+$H-$d,$d,$d,90,90);$p.CloseFigure();$p
}
function New-Frame([int]$Size){
 $bmp=[Drawing.Bitmap]::new($Size,$Size,[Drawing.Imaging.PixelFormat]::Format32bppArgb)
 $g=[Drawing.Graphics]::FromImage($bmp);$g.SmoothingMode='AntiAlias';$g.PixelOffsetMode='HighQuality';$g.Clear([Drawing.Color]::Transparent)
 $s=$Size/32.0
 # Body: a drive seen from the front, wider than tall.
 $body=New-RoundedPath (1*$s) (5*$s) (30*$s) (22*$s) ([math]::Max(1.5,3.2*$s))
 $g.FillPath([Drawing.SolidBrush]::new($ink),$body)
 # A light edge keeps the shape visible on a dark taskbar.
 $g.DrawPath([Drawing.Pen]::new([Drawing.Color]::FromArgb(140,150,160),[single][math]::Max(1,0.9*$s)),$body)
 # Status stripe, as in the drive list.
 $g.FillRectangle([Drawing.SolidBrush]::new($green),[single](5*$s),[single](9*$s),[single][math]::Max(2,3*$s),[single](14*$s))
 # Label lines; at 16 px a single line keeps the shape readable.
 $lh=[single][math]::Max(1.5,2.4*$s)
 $g.FillRectangle([Drawing.SolidBrush]::new($line),[single](11*$s),[single](10.5*$s),[single](15*$s),$lh)
 if($Size -ge 24){$g.FillRectangle([Drawing.SolidBrush]::new([Drawing.Color]::FromArgb(150,$line)),[single](11*$s),[single](16*$s),[single](10*$s),$lh)}
 # Activity light, bottom right.
 if($Size -ge 32){$g.FillEllipse([Drawing.SolidBrush]::new($green),[single](24.2*$s),[single](20.2*$s),[single](3*$s),[single](3*$s))}
 $g.Dispose();$bmp
}
function Get-DibBytes([Drawing.Bitmap]$Bmp){
 # 32-bit BGRA bottom-up DIB with an all-zero AND mask, as icon frames expect.
 $n=$Bmp.Width;$ms=[IO.MemoryStream]::new();$w=[IO.BinaryWriter]::new($ms)
 $w.Write([int]40);$w.Write([int]$n);$w.Write([int]($n*2));$w.Write([int16]1);$w.Write([int16]32);$w.Write([int]0);$w.Write([int]0);$w.Write([int]0);$w.Write([int]0);$w.Write([int]0);$w.Write([int]0)
 for($y=$n-1;$y -ge 0;$y--){for($x=0;$x -lt $n;$x++){$c=$Bmp.GetPixel($x,$y);$w.Write([byte]$c.B);$w.Write([byte]$c.G);$w.Write([byte]$c.R);$w.Write([byte]$c.A)}}
 $stride=[int]([math]::Ceiling($n/32.0)*4);$w.Write([byte[]]::new($stride*$n))
 $w.Flush()
 ,$ms.ToArray()   # the comma keeps PowerShell from unrolling the bytes
}

$sizes=@(16,20,24,32,40,48,64,128,256)
$frames=foreach($size in $sizes){
 $bmp=New-Frame $size
 if($size -eq 256){$ms=[IO.MemoryStream]::new();$bmp.Save($ms,[Drawing.Imaging.ImageFormat]::Png);$bytes=$ms.ToArray()}else{$bytes=[byte[]](Get-DibBytes $bmp)}
 if($PreviewPng -and $size -eq 256){$bmp.Save($PreviewPng,[Drawing.Imaging.ImageFormat]::Png)}
 $bmp.Dispose();[pscustomobject]@{Size=$size;Bytes=$bytes}
}
$out=[IO.MemoryStream]::new();$w=[IO.BinaryWriter]::new($out)
$w.Write([int16]0);$w.Write([int16]1);$w.Write([int16]$frames.Count)
$offset=6+16*$frames.Count
foreach($f in $frames){
 $d=if($f.Size -ge 256){0}else{$f.Size}
 $w.Write([byte]$d);$w.Write([byte]$d);$w.Write([byte]0);$w.Write([byte]0);$w.Write([int16]1);$w.Write([int16]32);$w.Write([int]$f.Bytes.Length);$w.Write([int]$offset);$offset+=$f.Bytes.Length
}
foreach($f in $frames){$w.Write([byte[]]$f.Bytes)}
$w.Flush();[IO.File]::WriteAllBytes($OutputPath,$out.ToArray())
Write-Output $OutputPath
