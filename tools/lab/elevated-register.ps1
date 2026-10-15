$ErrorActionPreference = 'Continue'
$log = 'C:\Users\ysmag\AppData\Local\Temp\gpfresh2.log'
function L($m) { Add-Content -Path $log -Value ((Get-Date -Format 'HH:mm:ss') + '  ' + $m) }
Set-Content -Path $log -Value ('repair + fresh boot ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))

$pkgId = 'MicrosoftCorporationII.WindowsSubsystemForAndroid_8wekyb3d8bbwe'
$pkgDir = Join-Path $env:LOCALAPPDATA ('Packages\' + $pkgId)

# --- 0. state -----------------------------------------------------------
$p = Get-AppxPackage -Name 'MicrosoftCorporationII.WindowsSubsystemForAndroid' -ErrorAction SilentlyContinue
L ('pre: registered=' + $(if ($p) { [string]$p.Status } else { 'NO' }) + ' pkgdir=' + (Test-Path $pkgDir) + ' C:\\WSA manifest=' + (Test-Path 'C:\WSA\AppxManifest.xml'))
Stop-Process -Name WsaClient -Force -ErrorAction SilentlyContinue
Stop-Service WsaService -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 2

# --- 1. dependencies (correct location: package root) -------------------
$found = @(Get-ChildItem 'C:\WSA' -Filter '*.appx' -File -ErrorAction SilentlyContinue)
L ('appx at package root: ' + ($found.Name -join ', '))
foreach ($f in $found) {
    try { Add-AppxPackage -Path $f.FullName -ErrorAction Stop; L ('  dep ok: ' + $f.Name) }
    catch { L ('  dep skip: ' + $f.Name + ' -> ' + $_.Exception.Message.Trim()) }
}
foreach ($n in 'Microsoft.UI.Xaml.2.8', 'Microsoft.VCLibs.140.00.UWPDesktop', 'Microsoft.VCLibs.140.00') {
    $v = Get-AppxPackage -Name $n -ErrorAction SilentlyContinue | Select-Object -First 1
    L ('  present: ' + $n + ' = ' + $(if ($v) { $v.Version } else { 'MISSING' }))
}

# --- 2. REGISTER with -Register (Install.ps1 sequence) ------------------
try {
    Add-AppxPackage -ForceApplicationShutdown -ForceUpdateFromAnyVersion -Register 'C:\WSA\AppxManifest.xml' -ErrorAction Stop
    L 'register OK'
} catch {
    L ('register FAILED: ' + $_.Exception.Message.Trim())
}
Start-Sleep -Seconds 4

$p = Get-AppxPackage -Name 'MicrosoftCorporationII.WindowsSubsystemForAndroid' -ErrorAction SilentlyContinue
if (-not $p) { L 'STILL NOT REGISTERED - abort'; exit 1 }
L ('registered: status=' + [string]$p.Status + ' ver=' + $p.Version + ' loc=' + $p.InstallLocation)
L ('folder skeleton recreated: ' + (Test-Path $pkgDir))
if (Test-Path $pkgDir) { Get-ChildItem $pkgDir -Force -ErrorAction SilentlyContinue | ForEach-Object { L ('   ' + $_.Name) } }

# --- 3. FIRST BOOT via protocol activation ------------------------------
Start-Service WsaService -ErrorAction SilentlyContinue
Start-Sleep -Seconds 2
L ('WsaService=' + (Get-Service WsaService).Status + ' -- Start-Process wsa://com.android.vending')
try { Start-Process 'wsa://com.android.vending'; L 'protocol launch submitted' }
catch { L ('protocol launch FAILED: ' + $_.Exception.Message.Trim()) }

# --- 4. observe ---------------------------------------------------------
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

# --- 5. crash? ----------------------------------------------------------
$crash = Get-WinEvent -FilterHashtable @{LogName = 'Application'; Id = 1000; StartTime = (Get-Date).AddMinutes(-7) } -ErrorAction SilentlyContinue |
         Where-Object { $_.Message -match 'WsaClient' } | Select-Object -First 1
if ($crash) { L ('CRASH: ' + $crash.TimeCreated); ($crash.Message -split "`r?`n") | Select-Object -First 5 | ForEach-Object { L ('   ' + $_) } }
else { L 'no WsaClient crash recorded' }
L ('userdata: ' + (Test-Path (Join-Path $pkgDir 'LocalCache\userdata.2.vhdx')))
L 'done'
