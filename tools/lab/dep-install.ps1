$ErrorActionPreference = 'Continue'
$log = 'C:\Users\ysmag\AppData\Local\Temp\gpfresh.log'
function L($m) { Add-Content -Path $log -Value ((Get-Date -Format 'HH:mm:ss') + '  ' + $m) }
Set-Content -Path $log -Value ('fresh-registration test ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))

$pkgId = 'MicrosoftCorporationII.WindowsSubsystemForAndroid_8wekyb3d8bbwe'
$pkgDir = Join-Path $env:LOCALAPPDATA ('Packages\' + $pkgId)
$bak = 'D:\WSA-backup-2026-10-15\pkgstate2'

# --- 0. nothing running -------------------------------------------------
Stop-Process -Name PlayGoodPizza, PlayParchisi, WsaClient -Force -ErrorAction SilentlyContinue
Stop-Service WsaService -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 3
L ('pre: WsaService=' + (Get-Service WsaService).Status)

# --- 1. BACKUP the package data folder ---------------------------------
if (Test-Path $bak) { Remove-Item $bak -Recurse -Force -ErrorAction SilentlyContinue }
New-Item -ItemType Directory -Path $bak -Force | Out-Null
if (Test-Path $pkgDir) {
    robocopy $pkgDir $bak /E /NFL /NDL /NJH /NJS /NP | Out-Null
    L ('backed up package data -> ' + $bak)
}
L ('backup files: ' + (Get-ChildItem $bak -Recurse -File -Force -ErrorAction SilentlyContinue).Count)

# --- 2. REMOVE the package (keeps C:\WSA files, drops registration/data)
$pkg = Get-AppxPackage -Name 'MicrosoftCorporationII.WindowsSubsystemForAndroid' -ErrorAction SilentlyContinue
if ($pkg) {
    L ('removing: ' + $pkg.PackageFullName)
    try { Remove-AppxPackage -Package $pkg.PackageFullName -ErrorAction Stop; L 'Remove-AppxPackage OK' }
    catch { L ('Remove-AppxPackage FAILED: ' + $_.Exception.Message) }
} else { L 'package was not registered' }
Start-Sleep -Seconds 3

# --- 3. delete the package data folder: brand-new-PC state --------------
if (Test-Path $pkgDir) {
    Remove-Item -LiteralPath $pkgDir -Recurse -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    L ('pkg data folder removed: ' + (-not (Test-Path $pkgDir)))
}

# --- 4. install the dependency packages ---------------------------------
$depDir = 'C:\WSA\microsoft.system.package.metadata'
foreach ($d in 'Microsoft.UI.Xaml.2.8_x64.appx', 'Microsoft.VCLibs.140.00.UWPDesktop_x64.appx', 'Microsoft.VCLibs.140.00_x64.appx') {
    $f = Join-Path $depDir $d
    if (Test-Path $f) {
        try { Add-AppxPackage -Path $f -ErrorAction Stop; L ('dep installed: ' + $d) }
        catch { L ('dep FAILED: ' + $d + ' -> ' + $_.Exception.Message) }
    } else { L ('dep source missing: ' + $d) }
}

# --- 5. REGISTER (Install.ps1 sequence) ---------------------------------
try {
    Add-AppxPackage -Path 'C:\WSA\AppxManifest.xml' -ForceApplicationShutdown -ForceUpdateFromAnyVersion -ErrorAction Stop
    L 'register OK'
} catch { L ('register FAILED: ' + $_.Exception.Message) }
Start-Sleep -Seconds 4

$p2 = Get-AppxPackage -Name 'MicrosoftCorporationII.WindowsSubsystemForAndroid' -ErrorAction SilentlyContinue
if ($p2) { L ('registered: status=' + [string]$p2.Status + ' ver=' + $p2.Version + ' loc=' + $p2.InstallLocation) }
else { L 'NOT REGISTERED - aborting'; exit 1 }
L ('folder skeleton recreated: ' + (Test-Path $pkgDir))

# --- 6. FIRST BOOT: protocol activation (what a new PC does) ------------
Start-Service WsaService -ErrorAction SilentlyContinue
Start-Sleep -Seconds 2
L ('WsaService=' + (Get-Service WsaService).Status + ' -- launching wsa://com.android.vending')
try { Start-Process 'wsa://com.android.vending'; L 'protocol launch submitted' }
catch { L ('protocol launch FAILED: ' + $_.Exception.Message) }

# --- 7. observe ---------------------------------------------------------
for ($i = 1; $i -le 14; $i++) {
    Start-Sleep -Seconds 10
    $names = (Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'vmmemWSA|vmwp|WsaClient|vmmem' } | ForEach-Object { $_.Name }) -join ','
    $lc = Join-Path $pkgDir 'LocalCache'
    $ud = Test-Path (Join-Path $lc 'userdata.2.vhdx')
    $port = Test-NetConnection -ComputerName 127.0.0.1 -Port 58526 -WarningAction SilentlyContinue -InformationLevel Quiet
    $mem = $null
    $v = Get-Process -Name vmmemWSA -ErrorAction SilentlyContinue
    if ($v) { $mem = [math]::Round($v.WorkingSet64 / 1MB, 0) }
    L ('  t=' + ($i * 10) + 's [' + $names + ']' + $(if ($mem) { ' vmmemMB=' + $mem } else { '' }) + ' userdata=' + $ud + ' port=' + $port)
    if ($port) { L '  >>> PORT 58526 OPEN - BOOT WORKED <<<'; break }
}

# --- 8. any crash? ------------------------------------------------------
$crash = Get-WinEvent -FilterHashtable @{LogName = 'Application'; Id = 1000; StartTime = (Get-Date).AddMinutes(-6) } -ErrorAction SilentlyContinue |
         Where-Object { $_.Message -match 'WsaClient' } | Select-Object -First 1
if ($crash) {
    L ('CRASH: ' + $crash.TimeCreated)
    ($crash.Message -split "`r?`n") | Select-Object -First 6 | ForEach-Object { L ('   ' + $_) }
} else { L 'no WsaClient crash recorded' }

L ('userdata created: ' + (Test-Path (Join-Path $pkgDir 'LocalCache\userdata.2.vhdx')))
L 'done'
