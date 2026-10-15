$ErrorActionPreference = 'Continue'
$log = 'C:\Users\ysmag\AppData\Local\Temp\click.log'
function L($m) { Add-Content -Path $log -Value ((Get-Date -Format 'HH:mm:ss') + '  ' + $m) }
Set-Content -Path $log -Value ('consent click test ' + (Get-Date -Format 'HH:mm:ss'))

Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes

Add-Type @'
using System;using System.Text;using System.Runtime.InteropServices;
public class W32 {
 [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
 public delegate bool EnumProc(IntPtr h, IntPtr l);
 [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
 [DllImport("user32.dll")] public static extern int GetWindowTextW(IntPtr h, [MarshalAs(UnmanagedType.LPWStr)] StringBuilder s, int n);
 [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr h, uint msg, IntPtr w, IntPtr l);
 [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
 [DllImport("user32.dll")] public static extern short GetDlgCtrlID(IntPtr h);
 public const uint WM_COMMAND = 0x0111;
}
'@

function Find-Dialog([int]$pidW) {
    $root = [System.Windows.Automation.AutomationElement]::RootElement
    $cond = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ProcessIdProperty, $pidW)
    foreach ($w in $root.FindAll([System.Windows.Automation.TreeScope]::Children, $cond)) {
        if ($w.Current.ClassName -eq '#32770') { return $w }
    }
    return $null
}

$pidW = (Get-Process WsaClient -ErrorAction SilentlyContinue).Id
if (-not $pidW) { L 'WsaClient not running'; exit 1 }
L ('WsaClient pid ' + $pidW)

$dlg = Find-Dialog $pidW
if (-not $dlg) { L 'no consent dialog found (already dismissed?)' }
else {
    L ('dialog: "' + $dlg.Current.Name + '"')
    $byname = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::NameProperty, 'Continue')
    $btn = $dlg.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $byname)
    if (-not $btn) { L 'Continue button not found' }
    else {
        L ('button found: class=' + $btn.Current.ClassName + ' rect=' + $btn.Current.BoundingRectangle + ' enabled=' + $btn.Current.IsEnabled)
        # --- method 1: UIA Invoke
        $inv = $null
        if ($btn.TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern, [ref]$inv)) {
            try { $inv.Invoke(); L 'method 1: UIA Invoke() -> submitted' } catch { L ('method 1 failed: ' + $_.Exception.Message) }
        } else { L 'method 1: no InvokePattern' }
    }
}

Start-Sleep -Seconds 3
# verify dismissal
$dlg2 = Find-Dialog $pidW
if ($dlg2) {
    L 'dialog STILL present -> method 2: WM_COMMAND by control id'
    $h = [IntPtr]::Zero
    $tid = [uint32]$pidW
    [W32]::EnumWindows({
        param($hh,$ll)
        $p = 0; [W32]::GetWindowThreadProcessId($hh, [ref]$p) | Out-Null
        $sb = New-Object System.Text.StringBuilder 256
        [W32]::GetWindowTextW($hh, $sb, 256) | Out-Null
        if ($p -eq $script:tid -and $sb.ToString() -like 'Optional diagnostic data*') { $script:h = $hh }
        return $true
    }, [IntPtr]::Zero) | Out-Null
    if ($h -ne [IntPtr]::Zero) {
        $kids = [W32]::SendMessage($h, 0x041E, [IntPtr]::Zero, [IntPtr]::Zero) # DM_GETDEFID-ish fallback, harmless
        # find child buttons via GetWindow chain
        Add-Type @'
using System;using System.Runtime.InteropServices;
public class W32b {
 [DllImport("user32.dll")] public static extern IntPtr GetWindow(IntPtr h, uint cmd);
 [DllImport("user32.dll")] public static extern int GetWindowTextW(IntPtr h, [MarshalAs(UnmanagedType.LPWStr)] System.Text.StringBuilder s, int n);
 [DllImport("user32.dll")] public static extern short GetDlgCtrlID(IntPtr h);
 [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
 public const uint GW_CHILD=5, GW_HWNDNEXT=2;
}
'@
        $k = [W32b]::GetWindow($h, 5)
        while ($k -ne [IntPtr]::Zero) {
            $sb = New-Object System.Text.StringBuilder 256
            [W32b]::GetWindowTextW($k, $sb, 256) | Out-Null
            $id = [W32b]::GetDlgCtrlID($k)
            L ('   child: id=' + $id + ' text="' + $sb.ToString() + '"')
            if ($sb.ToString() -eq 'Continue') {
                $r = [W32]::SendMessage($h, 0x0111, [IntPtr]($id), [IntPtr]$k)
                L ('   WM_COMMAND sent, result=' + $r)
            }
            $k = [W32b]::GetWindow($k, 2)
        }
    } else { L '   could not find dialog hwnd' }
}
else { L 'dialog gone -> consent accepted' }

# --- observe the boot ---------------------------------------------------
L 'observing...'
for ($i = 1; $i -le 15; $i++) {
    Start-Sleep -Seconds 10
    $names = (Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'vmmemWSA|vmwp|WsaClient' } | ForEach-Object { $_.Name }) -join ','
    $pkgDir = Join-Path $env:LOCALAPPDATA 'Packages\MicrosoftCorporationII.WindowsSubsystemForAndroid_8wekyb3d8bbwe'
    $ud = Test-Path (Join-Path $pkgDir 'LocalCache\userdata.2.vhdx')
    $port = Test-NetConnection -ComputerName 127.0.0.1 -Port 58526 -WarningAction SilentlyContinue -InformationLevel Quiet
    $v = Get-Process -Name vmmemWSA -ErrorAction SilentlyContinue
    $mb = if ($v) { ' vmmemMB=' + [math]::Round($v.WorkingSet64 / 1MB, 0) } else { '' }
    $wc = Get-Process WsaClient -ErrorAction SilentlyContinue
    $alive = if ($wc) { 'wc=alive' } else { 'wc=GONE' }
    L ('  t=' + ($i * 10) + 's [' + $names + ']' + $mb + ' ' + $alive + ' userdata=' + $ud + ' port=' + $port)
    if ($port) { L '  >>> PORT 58526 OPEN - BOOT WORKED <<<'; break }
}

$crash = Get-WinEvent -FilterHashtable @{LogName = 'Application'; Id = 1000; StartTime = (Get-Date).AddMinutes(-8) } -ErrorAction SilentlyContinue |
         Where-Object { $_.Message -match 'WsaClient' } | Select-Object -First 1
if ($crash) { L ('CRASH: ' + $crash.TimeCreated) } else { L 'no crash' }
L 'done'
