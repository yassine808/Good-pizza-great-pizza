$ErrorActionPreference='Continue'
$log='C:\Users\ysmag\AppData\Local\Temp\blanktest.log'
function L($m){Add-Content -Path $log -Value ((Get-Date -Format 'HH:mm:ss')+'  '+$m)}
Set-Content -Path $log -Value ('blank template test '+(Get-Date -Format 'HH:mm:ss'))
L ('elevated=' + ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))

# stop the running VM so we can re-test from scratch
Stop-Process -Name WsaClient -Force -EA SilentlyContinue
Start-Sleep -Seconds 2
& C:\WSA\WsaClient\WsaClient.exe /shutdown 2>$null
Start-Sleep -Seconds 5
Stop-Service WsaService -Force -EA SilentlyContinue
Start-Sleep -Seconds 3
L ('after shutdown: ' + ((Get-Process -EA SilentlyContinue | Where-Object { $_.Name -match 'vmmemWSA|vmwp|WsaClient' } | ForEach-Object { $_.Name }) -join ','))

# remove the WORKING template, replace with a BLANK one created by us
Remove-Item 'C:\WSA\userdata.vhdx' -Force -EA SilentlyContinue
$lc = Join-Path $env:LOCALAPPDATA 'Packages\MicrosoftCorporationII.WindowsSubsystemForAndroid_8wekyb3d8bbwe\LocalCache'
Remove-Item (Join-Path $lc 'userdata.2.vhdx') -Force -EA SilentlyContinue
L ('template removed, LocalCache cleaned')

# can we create a blank dynamic VHDX? (what a fresh PC would have to do)
$blank = 'C:\WSA\userdata.vhdx'
$sw=[Diagnostics.Stopwatch]::StartNew()
try {
    New-VHD -Path $blank -SizeBytes 8GB -Dynamic -ErrorAction Stop | Out-Null
    $sw.Stop()
    L ('New-VHD 8GB dynamic OK in ' + [math]::Round($sw.Elapsed.TotalSeconds,1) + 's  size=' + (Get-Item $blank).Length)
    $v = Get-VHD -Path $blank
    L ('  geom: format=' + $v.VhdFormat + ' type=' + $v.VhdType + ' disk=' + [math]::Round($v.DiskSize/1GB,2) + 'GB')
} catch {
    L ('New-VHD FAILED: ' + $_.Exception.Message.Trim())
}

# boot and see if WSA accepts a blank image
Start-Service WsaService -EA SilentlyContinue
Start-Sleep -Seconds 3
L ('WsaService=' + (Get-Service WsaService).Status + ' -- launch')
try { Start-Process 'wsa://com.android.vending'; L 'submitted' } catch { L ('FAILED: ' + $_.Exception.Message.Trim()) }

Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
function Dismiss {
    $wc = Get-Process WsaClient -EA SilentlyContinue
    if (-not $wc) { return $false }
    $root=[System.Windows.Automation.AutomationElement]::RootElement
    $cond=New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ProcessIdProperty,$wc.Id)
    foreach ($w in $root.FindAll([System.Windows.Automation.TreeScope]::Children,$cond)) {
        if ($w.Current.ClassName -eq '#32770') {
            $bn=New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::NameProperty,'Continue')
            $b=$w.FindFirst([System.Windows.Automation.TreeScope]::Descendants,$bn)
            if ($b) { $inv=$null; if ($b.TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern,[ref]$inv)) { $inv.Invoke(); L 'clicked Continue'; return $true } }
        }
    }
    return $false
}
for ($i=1; $i -le 18; $i++) {
    Start-Sleep -Seconds 10
    Dismiss | Out-Null
    $names=(Get-Process -EA SilentlyContinue | Where-Object { $_.Name -match 'vmmemWSA|vmwp|WsaClient' } | ForEach-Object { $_.Name }) -join ','
    $ud=Get-Item (Join-Path $lc 'userdata.2.vhdx') -EA SilentlyContinue
    $udt = if($ud){'ud='+[math]::Round($ud.Length/1MB,0)+'MB'}else{'ud=none'}
    $tpl = if(Test-Path $blank){'tpl='+[math]::Round((Get-Item $blank).Length/1MB,0)+'MB'}else{'tpl=GONE'}
    $port = Test-NetConnection -ComputerName 127.0.0.1 -Port 58526 -WarningAction SilentlyContinue -InformationLevel Quiet
    L ('  t='+($i*10)+'s ['+$names+'] '+$udt+' '+$tpl+' port='+$port)
    if ($port) { L '>>> PORT OPEN - BLANK TEMPLATE WORKS <<<'; break }
    if (-not $names) { L '(no wsa processes)'; break }
}
$crash = Get-WinEvent -FilterHashtable @{LogName='Application';Id=1000;StartTime=(Get-Date).AddMinutes(-6)} -EA SilentlyContinue | Where-Object { $_.Message -match 'WsaClient' } | Select-Object -First 1
if ($crash) { L ('CRASH '+$crash.TimeCreated); if ($crash.Message -match 'Exception code: (0x[0-9a-f]+)') { L ('  '+$Matches[1]) } } else { L 'no crash' }
L 'done'
