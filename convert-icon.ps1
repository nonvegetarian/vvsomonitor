<#
.SYNOPSIS
    Converts iconlogo.jpg (Downloads) into iconlogo.ico (256x256) next to this script.
    The .ico is used for the desktop shortcut, toast icon, and the compiled EXE.
#>
[CmdletBinding()]
param(
    [string]$Source = (Join-Path $env:USERPROFILE "Downloads\iconlogo.jpg"),
    [string]$Output,
    [int]$Size = 256
)

$ErrorActionPreference = "Stop"
if (-not $Output) { $Output = Join-Path $PSScriptRoot "iconlogo.ico" }
if (-not (Test-Path -LiteralPath $Source)) { throw "Source image not found: $Source" }

Add-Type -AssemblyName System.Drawing

$img = [System.Drawing.Image]::FromFile($Source)
$bmp = New-Object System.Drawing.Bitmap $Size, $Size
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
$g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
$g.Clear([System.Drawing.Color]::Transparent)
$g.DrawImage($img, 0, 0, $Size, $Size)
$g.Dispose()

$ms = New-Object System.IO.MemoryStream
$bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
$png = $ms.ToArray()
$ms.Dispose()

$fs = New-Object System.IO.FileStream($Output, [System.IO.FileMode]::Create)
$bw = New-Object System.IO.BinaryWriter($fs)
$bw.Write([UInt16]0)   # reserved
$bw.Write([UInt16]1)   # type = icon
$bw.Write([UInt16]1)   # image count
$bw.Write([Byte]0)     # width  (0 = 256)
$bw.Write([Byte]0)     # height (0 = 256)
$bw.Write([Byte]0)     # palette
$bw.Write([Byte]0)     # reserved
$bw.Write([UInt16]1)   # color planes
$bw.Write([UInt16]32)  # bits per pixel
$bw.Write([UInt32]$png.Length)  # size of image data
$bw.Write([UInt32]22)  # offset to data
$bw.Write($png)
$bw.Flush()
$bw.Dispose()
$fs.Dispose()
$bmp.Dispose()
$img.Dispose()

Write-Host "Created: $Output ($([math]::Round((Get-Item -LiteralPath $Output).Length / 1KB)) KB)"