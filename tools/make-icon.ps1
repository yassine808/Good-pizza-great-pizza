<#
  Generate tools\goodpizza.ico from the game's Play Store asset.

  The launcher ships with the game's own icon so that in Explorer, the taskbar
  and the Start menu it reads as the game rather than as a generic tool.

  No external image tooling is assumed - System.Drawing only. The multi-size
  .ico container is written by hand (ICONDIR / ICONDIRENTRY + raw BMP frames),
  because System.Drawing has no native ICO encoder.
#>
[CmdletBinding()]
param(
    [string]$OutFile,
    # Play Store listing art for Good Pizza, Great Pizza.
    [string]$Url = 'https://play-lh.googleusercontent.com/G1f17Gp0zcUwTLE4H2TQ-ETcMLFwBwUXckRcggE7z7Aqh0fVN6viqRYDHeg5mNrlv81bXqFLq-ea5Y6fl5cqrQ8=s512',
    [int[]]$Sizes = @(16, 24, 32, 48, 64, 128, 256),
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

$tools = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $OutFile) { $OutFile = Join-Path $tools 'goodpizza.ico' }

if ((Test-Path $OutFile) -and -not $Force) {
    Write-Host "icon already present: $OutFile"
    return
}

Add-Type -AssemblyName System.Drawing

# ---------------------------------------------------------------------------
# Convert one 32bpp frame into an ICO BMP entry: BITMAPINFOHEADER + XOR bitmap
# (bottom-up) + AND mask. Must be declared before the loop that calls it -
# PowerShell defines functions as it executes the script, not at parse time.
# ---------------------------------------------------------------------------
function ConvertTo-IcoBitmapData {
    param([System.Drawing.Bitmap]$Bitmap)

    $w = $Bitmap.Width
    $h = $Bitmap.Height

    # BITMAPINFOHEADER, 32bpp, POSITIVE height => the bottom-up row order that
    # ConvertTo-IcoBitmapData actually emits. A negative (top-down) height here
    # contradicts the row order and makes GDI+ refuse the frame outright.
    $header = New-Object byte[] 40
    [BitConverter]::GetBytes([System.Int32]40).CopyTo($header, 0)        # biSize
    [BitConverter]::GetBytes([System.Int32]$w).CopyTo($header, 4)        # biWidth
    [BitConverter]::GetBytes([System.Int32](2 * $h)).CopyTo($header, 8)  # biHeight (XOR+AND)
    [BitConverter]::GetBytes([System.Int16]1).CopyTo($header, 12)  # biPlanes
    [BitConverter]::GetBytes([System.Int16]32).CopyTo($header, 14) # biBitCount
    [BitConverter]::GetBytes([System.Int32]0).CopyTo($header, 16)        # BI_RGB

    $rect = New-Object System.Drawing.Rectangle(0, 0, $w, $h)
    $data = $Bitmap.LockBits($rect,
        [System.Drawing.Imaging.ImageLockMode]::ReadOnly,
        [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)

    $stride = $data.Stride
    $raw = New-Object byte[] ($stride * $h)
    [Runtime.InteropServices.Marshal]::Copy($data.Scan0, $raw, 0, $raw.Length)
    $Bitmap.UnlockBits($data)

    # Drop stride padding (w*4 bytes/row) and emit bottom-up rows for BMP.
    $xor = New-Object byte[] ($w * 4 * $h)
    for ($y = 0; $y -lt $h; $y++) {
        $srcOff = $stride * ($h - 1 - $y)
        $dstOff = $w * 4 * $y
        [Array]::Copy($raw, $srcOff, $xor, $dstOff, $w * 4)
    }

    # AND mask: 1bpp, rows padded to 32-bit boundaries. Zeroed = fully
    # opaque; the cut-out comes from alpha in the XOR bitmap.
    $maskStride = (($w + 31) -band -32) / 8
    $and = New-Object byte[] ($maskStride * $h)

    $ms = New-Object System.IO.MemoryStream
    $bw = New-Object System.IO.BinaryWriter($ms)
    $bw.Write($header)
    $bw.Write($xor)
    $bw.Write($and)
    $bw.Flush()
    $bytes = $ms.ToArray()
    $bw.Dispose()
    $ms.Dispose()
    return $bytes
}

# ---- fetch ----------------------------------------------------------------
$png = Join-Path $env:TEMP 'gp_icon_src.png'
Write-Host "fetching icon art..."
$wc = New-Object System.Net.WebClient
$wc.Headers.Add('User-Agent', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)')
$wc.DownloadFile($Url, $png)
$wc.Dispose()

if (-not (Test-Path $png)) { throw "download produced no file at $png" }
Write-Host "  downloaded $([math]::Round((Get-Item $png).Length/1KB,1)) KB"

$src = [System.Drawing.Image]::FromFile($png)
Write-Host "  source: $($src.Width)x$($src.Height)"

# ---- build frames ---------------------------------------------------------
# 256px is stored as a PNG blob inside the ICO (the spec-sanctioned way to
# carry a 256x256 frame); smaller frames are uncompressed BMP + AND mask.
$frames = New-Object System.Collections.ArrayList
foreach ($size in $Sizes) {
    if ($size -gt [Math]::Min($src.Width, $src.Height)) { continue }

    $bmp = New-Object System.Drawing.Bitmap($size, $size, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g.SmoothingMode      = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
    $g.PixelOffsetMode    = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $g.Clear([System.Drawing.Color]::Transparent)
    $g.DrawImage($src, 0, 0, $size, $size)
    $g.Dispose()

    if ($size -eq 256) {
        $ms = New-Object System.IO.MemoryStream
        $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
        $data = $ms.ToArray()
        $ms.Dispose()
    } else {
        $data = ConvertTo-IcoBitmapData -Bitmap $bmp
    }

    [void]$frames.Add(@{ Size = $size; Bitmap = $bmp; Data = $data })
    Write-Host "  frame ${size}x${size} -> $($data.Length) bytes"
}

if ($frames.Count -eq 0) { throw "no frames produced - source image too small?" }

# ---- assemble ICO ---------------------------------------------------------
# Order deterministically by an explicit rank derived from $Sizes. Sorting
# hashtables with Sort-Object gave a scrambled header order (observed:
# 48,64,128,16,24,32), which desyncs the entry headers from the data stream.
$ordered = @($frames | Sort-Object -Property @{ Expression = { [int]$_.Size } })
$pngFrame = $ordered | Where-Object { $_.Size -eq 256 } | Select-Object -First 1
$bmpFrames = @($ordered | Where-Object { $_.Size -ne 256 })
$ordered = @($bmpFrames) + $(if ($pngFrame) { @($pngFrame) } else { @() })

$ms = New-Object System.IO.MemoryStream
$bw = New-Object System.IO.BinaryWriter($ms)

$bw.Write([uint16]0)             # reserved
$bw.Write([uint16]1)             # type: icon
$bw.Write([uint16]$ordered.Count)

$offset = 6 + (16 * $ordered.Count)
foreach ($f in $ordered) {
    $dim = if ($f.Size -eq 256) { 0 } else { $f.Size }   # 0 encodes 256
    $bw.Write([byte]$dim)        # width
    $bw.Write([byte]$dim)        # height
    $bw.Write([byte]0)           # palette size
    $bw.Write([byte]0)           # reserved
    $bw.Write([uint16]1)         # colour planes
    $bw.Write([uint16]32)        # bits per pixel
    $bw.Write([uint32]$f.Data.Length)
    $bw.Write([uint32]$offset)
    $offset += $f.Data.Length
}
foreach ($f in $ordered) { $bw.Write([byte[]]$f.Data) }

$bw.Flush()
[IO.File]::WriteAllBytes($OutFile, $ms.ToArray())
$bw.Dispose()
$ms.Dispose()

foreach ($f in $frames) { $f.Bitmap.Dispose() }
$src.Dispose()
Remove-Item $png -Force -ErrorAction SilentlyContinue

$final = Get-Item $OutFile
$names = ($ordered | ForEach-Object { $_.Size }) -join ', '
Write-Host ""
Write-Host "OK  $OutFile  $([math]::Round($final.Length/1KB,1)) KB  ($($ordered.Count) sizes: $names)" -ForegroundColor Green
