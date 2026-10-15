$ErrorActionPreference = 'Continue'
$log = 'C:\Users\ysmag\AppData\Local\Temp\shot.log'
function L($m) { Add-Content -Path $log -Value ((Get-Date -Format 'HH:mm:ss') + '  ' + $m) }
Set-Content -Path $log -Value ('screenshot ' + (Get-Date -Format 'HH:mm:ss'))

$pkgDir = Join-Path $env:LOCALAPPDATA 'Packages\MicrosoftCorporationII.WindowsSubsystemForAndroid_8wekyb3d8bbwe'
$settings = Join-Path $pkgDir 'Settings'
$outDir = 'D:\Projects\Good-pizza-great-pizza\docs\screenshots'
New-Item -ItemType Directory -Path $outDir -Force | Out-Null

# --- 0. safety copy of Settings (the consent flag lives in settings.dat)
$bak = 'D:\WSA-backup-2026-10-15\pkgstate2\Settings'
if (-not (Test-Path $bak)) {
    robocopy $settings $bak /E /NFL /NDL /NJH /NJS /NP | Out-Null
    L 'Settings backed up'
}

# --- 1. wipe Settings only -> re-creates the first-run gate
Stop-Process -Name WsaClient -Force -ErrorAction SilentlyContinue
Stop-Service WsaService -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 2
Remove-Item -LiteralPath $settings -Recurse -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 1
L ('Settings wiped: ' + (-not (Test-Path $settings)))
Start-Service WsaService -ErrorAction SilentlyContinue
Start-Sleep -Seconds 3

# --- 2. launch: first-run consent dialog should appear
L 'launching wsa://com.android.vending'
try { Start-Process 'wsa://com.android.vending'; L 'submitted' } catch { L ('FAILED: ' + $_.Exception.Message.Trim()) }

Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes

# UIA reports PHYSICAL pixels; a non-DPI-aware process gets virtualized
# coordinates from CopyFromScreen. Align them before capturing.
Add-Type @'
using System;using System.Runtime.InteropServices;
public class Dpi {
 [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
}
'@
$null = [Dpi]::SetProcessDPIAware()
L 'process marked DPI-aware'

$dlg = $null
for ($i = 1; $i -le 12 -and -not $dlg; $i++) {
    Start-Sleep -Seconds 5
    $wc = Get-Process WsaClient -ErrorAction SilentlyContinue
    if (-not $wc) { L ('  t=' + ($i * 5) + 's no WsaClient'); continue }
    $root = [System.Windows.Automation.AutomationElement]::RootElement
    $cond = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ProcessIdProperty, $wc.Id)
    foreach ($w in $root.FindAll([System.Windows.Automation.TreeScope]::Children, $cond)) {
        if ($w.Current.ClassName -eq '#32770') { $dlg = $w }
    }
    L ('  t=' + ($i * 5) + 's dialog=' + ($dlg -ne $null))
}

if (-not $dlg) { L 'NO DIALOG - nothing to capture'; exit 1 }
L ('dialog: "' + $dlg.Current.Name + '" rect=' + $dlg.Current.BoundingRectangle)

# --- 3. bring it to the front, then capture the region
Add-Type @'
using System;using System.Runtime.InteropServices;
public class Fg {
 [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
 [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
 [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
}
'@
$h = [IntPtr]$dlg.Current.NativeWindowHandle
[Fg]::ShowWindow($h, 9) | Out-Null   # SW_RESTORE
[Fg]::SetForegroundWindow($h) | Out-Null
Start-Sleep -Seconds 2

Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms

$r = $dlg.Current.BoundingRectangle
$pad = 24
# Rect members are DOUBLES; Bitmap ctor needs ints
$x = [int][Math]::Max(0, $r.X - $pad)
$y = [int][Math]::Max(0, $r.Y - $pad)
$w = [int][Math]::Min($r.Width + $pad * 2, [System.Windows.Forms.Screen]::PrimaryScreen.Bounds.Width - $x)
$hgt = [int][Math]::Min($r.Height + $pad * 2, [System.Windows.Forms.Screen]::PrimaryScreen.Bounds.Height - $y)
L ('capture rect: ' + $x + ',' + $y + ' ' + $w + 'x' + $hgt + '  types=' + $w.GetType().Name + '/' + $hgt.GetType().Name)

# grab the WHOLE screen first, crop from memory: immune to coord drift
$sw = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
L ('screen: ' + $sw.Width + 'x' + $sw.Height)
$full = New-Object System.Drawing.Bitmap([int]$sw.Width, [int]$sw.Height)
$g = [System.Drawing.Graphics]::FromImage($full)
$g.CopyFromScreen(0, 0, 0, 0, (New-Object System.Drawing.Size([int]$sw.Width, [int]$sw.Height)))
$g.Dispose()

# keep a full copy in temp for verification only (never committed)
$full.Save((Join-Path $env:TEMP 'full-desktop.png'), [System.Drawing.Imaging.ImageFormat]::Png)

$bmp = $full.Clone((New-Object System.Drawing.Rectangle($x, $y, $w, $hgt)), $full.PixelFormat)
$p1 = Join-Path $outDir 'first-run-consent.png'
$bmp.Save($p1, [System.Drawing.Imaging.ImageFormat]::Png)
$bmp.Dispose(); $full.Dispose()
L ('saved: ' + $p1 + '  ' + (Get-Item $p1).Length + ' bytes')

# --- 4. full-screen shot for context (skipped: contains personal screen content)
L 'skipping full-desktop capture (kept only the dialog crop)'

# --- 5. clean up: do NOT click anything (that is what triggers the crash)
Stop-Process -Name WsaClient -Force -ErrorAction SilentlyContinue
L 'WsaClient killed (consent left unanswered)'
L 'done'
