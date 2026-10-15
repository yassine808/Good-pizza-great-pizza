$ErrorActionPreference='Continue'
$log='C:\Users\ysmag\AppData\Local\Temp\dumpsetup.log'
function L($m){Add-Content -Path $log -Value ((Get-Date -Format 'HH:mm:ss')+'  '+$m)}
Set-Content -Path $log -Value ('dump setup '+(Get-Date -Format 'HH:mm:ss'))
L ('elevated=' + ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))
$key='HKLM:\SOFTWARE\Microsoft\Windows\Windows Error Reporting\LocalDumps\WsaClient.exe'
New-Item -Path $key -Force | Out-Null
Set-ItemProperty -Path $key -Name DumpFolder -Value 'C:\WSAdumps' -Type ExpandString
Set-ItemProperty -Path $key -Name DumpType -Value 2 -Type DWord
Set-ItemProperty -Path $key -Name DumpCount -Value 5 -Type DWord
New-Item -ItemType Directory -Path 'C:\WSAdumps' -Force | Out-Null
# also allow the packager's full dump for the AppX host
L 'LocalDumps configured for WsaClient.exe -> C:\WSAdumps'
Get-ItemProperty $key | Format-List * | Out-String | ForEach-Object { L ($_ -replace "`r`n",' | ') }
L 'done'
