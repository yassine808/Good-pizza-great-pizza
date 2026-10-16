<#
  capture.ps1 - capture one specific top-level window of a process as a PNG.

      powershell -NoProfile -ExecutionPolicy Bypass -File tools\lab\capture.ps1 `
          -ProcId 1234 -TitlePattern 'setup problem' -OutPng 'C:\temp\x.png'

  Why this exists (measured, not assumed):
    * Graphics.CopyFromScreen copies whatever is on top of the screen, so the
      target window must genuinely own the foreground or the capture shows a
      different window entirely.
    * A Medium-integrity process cannot make an elevated window take foreground,
      and PrintWindow / PostMessage are blocked across that boundary as well
      (verified: PrintWindow returns FALSE, hide/show diff = 0 pixels).
      => To capture an elevated window, run THIS script elevated.
    * Foreground is re-checked after the wait; if the window still does not own
      the screen, the run fails loudly instead of silently saving a wrong image.
      A wrong-looking screenshot in the docs is worse than no screenshot.

  * The status bubble deliberately uses ShowWithoutActivation (it must never
    steal focus from the app it is launching), so it can never pass the
    foreground test. For such windows pass -NoFocusRequired: the check then
    becomes "the window owns its own centre pixel" (WindowFromPoint), which is
    exactly what CopyFromScreen needs to show the window and not something on
    top of it. Everything else - settle, retries, brightness floor - is
    unchanged.

  Exit 0 = captured and verified, 1 = failed.
#>
param(
    [Parameter(Mandatory = $true)][int]$ProcId,
    [Parameter(Mandatory = $true)][string]$TitlePattern,
    [Parameter(Mandatory = $true)][string]$OutPng,
    [int]$SettleMs = 600,
    [int]$Retries = 4,
    [switch]$NoFocusRequired
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type @'
using System;using System.Runtime.InteropServices;
public class Cap {
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr h);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, IntPtr p);
  [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
  [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint a, uint b, bool f);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int n);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern IntPtr WindowFromPoint(POINT p);
  [DllImport("user32.dll")] public static extern IntPtr GetAncestor(IntPtr h, uint f);
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
}
'@

function Find-Target {
    $root = [System.Windows.Automation.AutomationElement]::RootElement
    $cond = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::ProcessIdProperty, $ProcId)
    foreach ($top in $root.FindAll([System.Windows.Automation.TreeScope]::Children, $cond)) {
        $n = $top.Current.Name
        if ($n -and $n -match $TitlePattern) { return $top }
    }
    return $null
}

# brightness snapshot, to tell a real light dialog from a dark window on top
function Stats([System.Drawing.Bitmap]$bmp) {
    $sum = 0; $min = 255; $max = 0; $n = 0
    $w = [math]::Min(80, $bmp.Width); $h = [math]::Min(60, $bmp.Height)
    for ($y = 0; $y -lt $h; $y += 2) {
        for ($x = 0; $x -lt $w; $x += 2) {
            $c = $bmp.GetPixel($x, $y)
            $b = [int](0.299 * $c.R + 0.587 * $c.G + 0.114 * $c.B)
            $sum += $b; $n++
            if ($b -lt $min) { $min = $b }
            if ($b -gt $max) { $max = $b }
        }
    }
    return @{ avg = [math]::Round($sum / [math]::Max(1, $n), 1); min = $min; max = $max }
}

for ($try = 1; $try -le $Retries; $try++) {
    $el = Find-Target
    if (-not $el) { Write-Output "attempt $try : no window matching '$TitlePattern' (pid $ProcId)"; Start-Sleep -Milliseconds 800; continue }

    $hwnd = [IntPtr]$el.Current.NativeWindowHandle
    if (-not [Cap]::IsWindow($hwnd)) { Write-Output "attempt $try : stale handle"; Start-Sleep -Milliseconds 800; continue }

    $r = New-Object Cap+RECT
    [Cap]::GetWindowRect($hwnd, [ref]$r) | Out-Null
    $W = $r.R - $r.L; $H = $r.B - $r.T
    if ($W -le 0 -or $H -le 0) { Write-Output "attempt $try : bad rect ${W}x${H}"; Start-Sleep -Milliseconds 800; continue }

    if ($NoFocusRequired) {
        # Never force focus (the window must not steal it). Instead prove the
        # window is genuinely what is drawn at its own centre pixel.
        Start-Sleep -Milliseconds $SettleMs
        $mid = New-Object Cap+POINT
        $mid.X = $r.L + [int]($W / 2); $mid.Y = $r.T + [int]($H / 2)
        # WindowFromPoint returns the DEEPEST window at that pixel - for a form
        # whose area is covered by a Label that is the STATIC child, not the
        # form, so a raw comparison never matches. Walk up to the top-level
        # window (GA_ROOT) before comparing.
        $at = [Cap]::GetAncestor([Cap]::WindowFromPoint($mid), 2)
        if ($at -ne $hwnd) {
            $cname = 'unknown'
            try { $cname = ([System.Windows.Automation.AutomationElement]::FromHandle($at).Current.Name) } catch { }
            Write-Output "attempt $try : centre pixel belongs to '$cname', not to this window (something is on top) - not capturing"
            Start-Sleep -Milliseconds 800
            continue
        }
    }
    else {
        [Cap]::ShowWindow($hwnd, 9) | Out-Null                      # SW_RESTORE, never minimise it away
        $fg = [Cap]::GetForegroundWindow()
        $tId = [Cap]::GetWindowThreadProcessId($fg, [IntPtr]::Zero)
        $cId = [Cap]::GetCurrentThreadId()
        if ($tId -ne $cId) { [Cap]::AttachThreadInput($tId, $cId, $true) | Out-Null }
        [Cap]::BringWindowToTop($hwnd) | Out-Null
        [Cap]::SetForegroundWindow($hwnd) | Out-Null
        Start-Sleep -Milliseconds $SettleMs
        if ($tId -ne $cId) { [Cap]::AttachThreadInput($tId, $cId, $false) | Out-Null }

        $owns = ([Cap]::GetForegroundWindow() -eq $hwnd)
        if (-not $owns) {
            $cur = [Cap]::GetForegroundWindow()
            $cname = 'unknown'
            try { $cname = ([System.Windows.Automation.AutomationElement]::FromHandle($cur).Current.Name) } catch { }
            Write-Output "attempt $try : window is NOT foreground (foreground is '$cname') - not capturing, would show the wrong window"
            Start-Sleep -Milliseconds 800
            continue
        }
    }

    $bmp = New-Object System.Drawing.Bitmap($W, $H)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($r.L, $r.T, 0, 0, (New-Object System.Drawing.Size($W, $H)))
    $g.Dispose()

    $s = Stats $bmp
    # a launcher dialog is light (avg well above mid) with a dark title bar;
    # Discord sits far darker. Refuse a capture that cannot be ours.
    if ($s.avg -lt 90) {
        Write-Output ("attempt $try : captured, but avg-brightness={0} - that is not the dialog, refusing to save" -f $s.avg)
        $bmp.Dispose()
        Start-Sleep -Milliseconds 800
        continue
    }

    $bmp.Save($OutPng, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
    Write-Output ("CAPTURED  {0}x{1}  ->  {2}   avg-brightness={3} min={4} max={5}" -f $W, $H, $OutPng, $s.avg, $s.min, $s.max)
    exit 0
}
Write-Output "FAILED  could not capture '$TitlePattern' (pid $ProcId) after $Retries attempts"
exit 1
