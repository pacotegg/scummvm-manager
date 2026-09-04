<#
  Genera app.ico (icono de la aplicacion) usando System.Drawing.
  Fondo oscuro redondeado + borde de acento + rotulo "SVM".
  Se guarda un .ico con una entrada PNG de 256x256 (Windows Vista+).
#>
param(
    [string]$OutFile = (Join-Path (Split-Path $PSScriptRoot -Parent) 'app.ico'),
    [string]$Accent = '#22D3EE'
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

function New-RoundedPath {
    param([int]$x, [int]$y, [int]$w, [int]$h, [int]$r)
    $p = New-Object System.Drawing.Drawing2D.GraphicsPath
    $d = $r * 2
    $p.AddArc($x, $y, $d, $d, 180, 90)
    $p.AddArc($x + $w - $d, $y, $d, $d, 270, 90)
    $p.AddArc($x + $w - $d, $y + $h - $d, $d, $d, 0, 90)
    $p.AddArc($x, $y + $h - $d, $d, $d, 90, 90)
    $p.CloseFigure()
    return $p
}

function ConvertFrom-Hex {
    param([string]$Hex)
    $Hex = $Hex.TrimStart('#')
    return [System.Drawing.Color]::FromArgb(
        [Convert]::ToInt32($Hex.Substring(0, 2), 16),
        [Convert]::ToInt32($Hex.Substring(2, 2), 16),
        [Convert]::ToInt32($Hex.Substring(4, 2), 16))
}

$size = 256
$bmp = New-Object System.Drawing.Bitmap $size, $size
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
$g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit
$g.Clear([System.Drawing.Color]::Transparent)

$accentColor = ConvertFrom-Hex $Accent
$bg = [System.Drawing.Color]::FromArgb(28, 28, 36)

# Cuerpo redondeado.
$body = New-RoundedPath 16 16 ($size - 32) ($size - 32) 46
$brush = New-Object System.Drawing.SolidBrush $bg
$g.FillPath($brush, $body)

# Borde de acento.
$pen = New-Object System.Drawing.Pen $accentColor, 10
$g.DrawPath($pen, $body)

# Rotulo "SVM".
$font = New-Object System.Drawing.Font ('Segoe UI', 74, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
$fmt = New-Object System.Drawing.StringFormat
$fmt.Alignment = [System.Drawing.StringAlignment]::Center
$fmt.LineAlignment = [System.Drawing.StringAlignment]::Center
$textBrush = New-Object System.Drawing.SolidBrush $accentColor
$rect = New-Object System.Drawing.RectangleF 0, 8, $size, ($size - 40)
$g.DrawString('SVM', $font, $textBrush, $rect, $fmt)

# Subtitulo.
$font2 = New-Object System.Drawing.Font ('Segoe UI', 22, [System.Drawing.FontStyle]::Regular, [System.Drawing.GraphicsUnit]::Pixel)
$subBrush = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(154, 154, 165))
$rect2 = New-Object System.Drawing.RectangleF 0, 158, $size, 40
$g.DrawString('ScummVM', $font2, $subBrush, $rect2, $fmt)

$g.Dispose()

# --- Guardar como .ico con una entrada PNG 256x256 ---
$ms = New-Object System.IO.MemoryStream
$bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
$png = $ms.ToArray()
$ms.Dispose()
$bmp.Dispose()

$fs = [System.IO.File]::Open($OutFile, [System.IO.FileMode]::Create)
$bw = New-Object System.IO.BinaryWriter $fs
$bw.Write([UInt16]0)      # reservado
$bw.Write([UInt16]1)      # tipo = icono
$bw.Write([UInt16]1)      # numero de imagenes
$bw.Write([byte]0)        # ancho (0 = 256)
$bw.Write([byte]0)        # alto  (0 = 256)
$bw.Write([byte]0)        # colores paleta
$bw.Write([byte]0)        # reservado
$bw.Write([UInt16]1)      # planos
$bw.Write([UInt16]32)     # bits por pixel
$bw.Write([UInt32]$png.Length)   # tamano de la imagen
$bw.Write([UInt32]22)     # offset (6 + 16)
$bw.Write($png)
$bw.Flush(); $bw.Close(); $fs.Close()

"Icono generado: $OutFile ($([math]::Round((Get-Item $OutFile).Length/1KB,1)) KB)"
