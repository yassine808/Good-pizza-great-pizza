$ErrorActionPreference = 'Continue'
$log = 'C:\Users\ysmag\AppData\Local\Temp\tmpl.log'
function L($m) { Add-Content -Path $log -Value ((Get-Date -Format 'HH:mm:ss') + '  ' + $m); }
Set-Content -Path $log -Value ('userdata template test ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))

L ('elevated=' + ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))

$pkgDir = Join-Path $env:LOCALAPPDATA 'Packages\MicrosoftCorporationII.WindowsSubsystemForAndroid_8wekyb3d8bbwe'
$src = 'D:\WSA-backup-2026-10-15\userdata.2.vhdx'
$dst = 'C:\WSA\userdata.vhdx'

# --- 0. geometry of the known-good image (needs admin) -------------------
if (Test-Path $src) {
    try {
        $v = Get-VHD -Path $src
        L ('backup geom: VhdFormat=' + $v.VhdFormat + ' Type=' + $v.VhdType + ' DiskSize=' + [math]::Round($v.DiskSize/1GB,2) + 'GB FileSize=' + [math]::Round($v.FileSize/1GB,2) + 'GB')
    } catch { L ('Get-VHD failed: ' + $_.Exception.Message.Trim()) }
} else { L 'backup userdata MISSING - cannot seed'; exit 1 }

# --- 1. put the template where WsaClient looks for it --------------------
Stop-Process -Name WsaClient -Force -ErrorAction SilentlyContinue
Stop-Service WsaService -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 2

if (Test-Path $dst) { L 'template already present at C:\WSA\userdata.vhdx' }
else {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    Copy-Item -LiteralPath $src -Destination $dst -Force
    $sw.Stop()
    L ('copied template -> C:\WSA\userdata.vhdx  in ' + [math]::Round($sw.Elapsed.TotalSeconds,1) + 's  size=' + (Get-Item $dst).Length)
}

# --- 2. ensure a true first-run state ------------------------------------
$settings = Join-Path $pkgDir 'Settings'
if (Test-Path $settings) { Remove-Item -LiteralPath $settings -Recurse -Force -ErrorAction SilentlyContinue; L 'Settings wiped (first-run gate armed)' }
$lc = Join-Path $pkgDir 'LocalCache'
if (-not (Test-Path $lc)) { New-Item -ItemType Directory -Path $lc -Force | Out-Null }
L ('LocalCache now contains: ' + ((Get-ChildItem $lc -Force -EA SilentlyContinue | ForEach-Object { $_.Name }) -join ', '))
L ('LocalState exists: ' + (Test-Path (Join-Path $pkgDir 'LocalState')))

# --- 3. boot -------------------------------------------------------------
$reg = Get-AppxPackage -Name 'MicrosoftCorporationII.WindowsSubsystemForAndroid' -EA SilentlyContinue
if (-not $reg) { L 'NOT REGISTERED - abort'; exit 1 }
L ('registered: status=' + [string]$reg.Status + ' ver=' + $reg.Version)

Start-Service WsaService -ErrorAction SilentlyContinue
Start-Sleep -Seconds 3
L ('WsaService=' + (Get-Service WsaService).Status + ' -- launching wsa://com.android.vending')

$launchSw = [Diagnostics.Stopwatch]::StartNew()
try { Start-Process 'wsa://com.android.vending'; L 'protocol launch submitted' }
catch { L ('protocol launch FAILED: ' + $_.Exception.Message.Trim()) }

# --- 4. watch for the template being consumed ----------------------------
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes

function Dismiss-Consent {
    $wc = Get-Process WsaClient -EA SilentlyContinue
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
                    $inv.Invoke(); L 'clicked Continue (consent)'; return $true
                }
            }
        }
    }
    return $false
}

for ($i = 1; $i -le 18; $i++) {
    Start-Sleep -Seconds 10
    Dismiss-Consent | Out-Null
    $names = (Get-Process -EA SilentlyContinue | Where-Object { $_.Name -match 'vmmemWSA|vmwp|WsaClient' } | ForEach-Object { $_.Name }) -join ','
    $ud = Get-Item (Join-Path $lc 'userdata.2.vhdx') -EA SilentlyContinue
    $udTxt = if ($ud) { 'ud=' + [math]::Round($ud.Length/1MB,0) + 'MB' } else { 'ud=none' }
    $tpl = if (Test-Path $dst) { 'tpl=' + [math]::Round((Get-Item $dst).Length/1MB,0) + 'MB' } else { 'tpl=GONE' }
    $port = Test-NetConnection -ComputerName 127.0.0.1 -Port 58526 -WarningAction SilentlyContinue -InformationLevel Quiet
    L ('  t=' + ($i * 10) + 's [' + $names + '] ' + $udTxt + ' ' + $tpl + ' port=' + $port)
    if ($port) { L ('  >>> PORT 58526 OPEN after ' + [math]::Round($launchSw.Elapsed.TotalSeconds,0) + 's - BOOT WORKED <<<'); break }
    if (-not $names) { L '  (no wsa processes at all)'; break }
}

# --- 5. outcome ----------------------------------------------------------
$ud2 = Get-Item (Join-Path $lc 'userdata.2.vhdx') -EA SilentlyContinue
L ('LocalCache userdata.2.vhdx: ' + $(if ($ud2) { [math]::Round($ud2.Length/1MB,0) + 'MB' } else { 'NOT created' }))
L ('template still at C:\\WSA: ' + (Test-Path $dst))

$crash = Get-WinEvent -FilterHashtable @{LogName='Application'; Id=1000; StartTime=(Get-Date).AddMinutes(-6)} -EA SilentlyContinue |
         Where-Object { $_.Message -match 'WsaClient' } | Select-Object -First 1
if ($crash) {
    L ('CRASH: ' + $crash.TimeCreated)
    if ($crash.Message -match 'Exception code: (0x[0-9a-f]+)') { L ('  code ' + $Matches[1]) }
} else { L 'no crash' }
L 'done'
