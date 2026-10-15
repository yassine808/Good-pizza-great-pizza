$ErrorActionPreference = 'Continue'
$log = 'C:\Users\ysmag\AppData\Local\Temp\reg.log'
function L($m) { Add-Content -Path $log -Value ((Get-Date -Format 'HH:mm:ss') + '  ' + $m) }
Set-Content -Path $log -Value ('elevated registration ' + (Get-Date -Format 'HH:mm:ss'))
L ('elevated=' + ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))

try {
    Add-AppxPackage -ForceApplicationShutdown -ForceUpdateFromAnyVersion -Register 'C:\WSA\AppxManifest.xml' -ErrorAction Stop
    L 'register OK'
} catch {
    L ('register FAILED: ' + $_.Exception.Message.Trim())
}
Start-Sleep -Seconds 3
$p = Get-AppxPackage -Name 'MicrosoftCorporationII.WindowsSubsystemForAndroid' -ErrorAction SilentlyContinue
if ($p) { L ('registered: status=' + [string]$p.Status + ' ver=' + $p.Version + ' loc=' + $p.InstallLocation) }
else { L 'NOT REGISTERED' }
L 'done'
