$ErrorActionPreference = 'Continue'
$log = 'C:\Users\ysmag\AppData\Local\Temp\repro.log'
function L($m) { Add-Content -Path $log -Value ((Get-Date -Format 'HH:mm:ss') + '  ' + $m) }
Set-Content -Path $log -Value ('repro ' + (Get-Date -Format 'HH:mm:ss'))

Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes

function Dismiss-Consent {
    $wc = Get-Process WsaClient -ErrorAction SilentlyContinue
    if (-not $wc) { return $false }
    $root = [System.Windows.Automation.AutomationElement]::RootElement
    $cond = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ProcessIdProperty, $wc.Id)
    foreach ($w in $root.FindAll([System.Windows.Automation.TreeScope]::Children, $cond)) {
        if ($w.Current.ClassName -eq '#32770') {
            $bn = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::NameProperty, 'Continue')
            $btn = $w.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $bn)
            if ($btn) {
                $inv = $null
                if ($btn.TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern, [ref]$inv)) {
                    $inv.Invoke(); L 'clicked Continue (consent dialog)'; return $true
                }
            }
        }
    }
    return $false
}

L 'launching wsa://com.android.vending'
try { Start-Process 'wsa://com.android.vending'; L 'submitted' } catch { L ('FAILED: ' + $_.Exception.Message.Trim()) }

for ($i = 1; $i -le 12; $i++) {
    Start-Sleep -Seconds 10
    Dismiss-Consent | Out-Null
    $names = (Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'vmmemWSA|vmwp|WsaClient' } | ForEach-Object { $_.Name }) -join ','
    $pkgDir = Join-Path $env:LOCALAPPDATA 'Packages\MicrosoftCorporationII.WindowsSubsystemForAndroid_8wekyb3d8bbwe'
    $ud = Test-Path (Join-Path $pkgDir 'LocalCache\userdata.2.vhdx')
    $port = Test-NetConnection -ComputerName 127.0.0.1 -Port 58526 -WarningAction SilentlyContinue -InformationLevel Quiet
    L ('  t=' + ($i * 10) + 's [' + $names + '] userdata=' + $ud + ' port=' + $port)
    if ($port) { L '>>> PORT OPEN <<<'; break }
    if (-not $names) { L '  (no wsa processes)'; break }
}

$crash = Get-WinEvent -FilterHashtable @{LogName = 'Application'; Id = 1000; StartTime = (Get-Date).AddMinutes(-4) } -ErrorAction SilentlyContinue |
         Where-Object { $_.Message -match 'WsaClient' } | Select-Object -First 1
if ($crash) { L ('CRASH: ' + $crash.TimeCreated) } else { L 'no crash' }

$d = 'C:\WSAdumps'
if (Test-Path $d) {
    $f = Get-ChildItem $d -File -ErrorAction SilentlyContinue
    L ('dumps: ' + $f.Count)
    $f | ForEach-Object { L ('   ' + $_.Name + '  ' + $_.Length + '  ' + $_.LastWriteTime) }
} else { L 'no dumps dir' }
L 'done'
