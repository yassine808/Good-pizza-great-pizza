$ErrorActionPreference = 'Continue'
$log = 'C:\Users\ysmag\AppData\Local\Temp\boot.log'
function L($m) { Add-Content -Path $log -Value ((Get-Date -Format 'HH:mm:ss') + '  ' + $m) }
Set-Content -Path $log -Value ('first boot test ' + (Get-Date -Format 'HH:mm:ss'))

$pkgId = 'MicrosoftCorporationII.WindowsSubsystemForAndroid_8wekyb3d8bbwe'
$pkgDir = Join-Path $env:LOCALAPPDATA ('Packages\' + $pkgId)

$p = Get-AppxPackage -Name 'MicrosoftCorporationII.WindowsSubsystemForAndroid' -ErrorAction SilentlyContinue
if (-not $p) { L 'NOT REGISTERED - abort'; exit 1 }
L ('registered: status=' + [string]$p.Status + ' ver=' + $p.Version)
L ('pkg data dir: ' + (Test-Path $pkgDir))
Get-ChildItem $pkgDir -Force -ErrorAction SilentlyContinue | ForEach-Object { L ('   dir: ' + $_.Name) }

# service must be up
Stop-Service WsaService -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 2
Start-Service WsaService -ErrorAction SilentlyContinue
Start-Sleep -Seconds 3
L ('WsaService=' + (Get-Service WsaService).Status)

# FIRST BOOT: the exact thing a new PC does (Install.ps1 Finish)
L 'Start-Process wsa://com.android.vending'
try { Start-Process 'wsa://com.android.vending'; L 'submitted' }
catch { L ('FAILED: ' + $_.Exception.Message.Trim()) }

for ($i = 1; $i -le 15; $i++) {
    Start-Sleep -Seconds 10
    $names = (Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'vmmemWSA|vmwp|WsaClient' } | ForEach-Object { $_.Name }) -join ','
    $ud = Test-Path (Join-Path $pkgDir 'LocalCache\userdata.2.vhdx')
    $port = Test-NetConnection -ComputerName 127.0.0.1 -Port 58526 -WarningAction SilentlyContinue -InformationLevel Quiet
    $v = Get-Process -Name vmmemWSA -ErrorAction SilentlyContinue
    $mb = if ($v) { ' vmmemMB=' + [math]::Round($v.WorkingSet64 / 1MB, 0) } else { '' }
    L ('  t=' + ($i * 10) + 's [' + $names + ']' + $mb + ' userdata=' + $ud + ' port=' + $port)
    if ($port) { L '  >>> PORT 58526 OPEN - BOOT WORKED <<<'; break }
}

$crash = Get-WinEvent -FilterHashtable @{LogName = 'Application'; Id = 1000; StartTime = (Get-Date).AddMinutes(-8) } -ErrorAction SilentlyContinue |
         Where-Object { $_.Message -match 'WsaClient' } | Select-Object -First 1
if ($crash) { L ('CRASH: ' + $crash.TimeCreated); ($crash.Message -split "`r?`n") | Select-Object -First 5 | ForEach-Object { L ('   ' + $_) } }
else { L 'no WsaClient crash recorded' }
L ('userdata created: ' + (Test-Path (Join-Path $pkgDir 'LocalCache\userdata.2.vhdx')))
L 'done'
