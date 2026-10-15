$ErrorActionPreference = 'Continue'
$log = 'C:\Users\ysmag\AppData\Local\Temp\uidump.log'
function L($m) { Add-Content -Path $log -Value $m }
Set-Content -Path $log -Value ('UI dump ' + (Get-Date -Format 'HH:mm:ss'))

Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type -AssemblyName System.Windows.Forms

$root = [System.Windows.Automation.AutomationElement]::RootElement
$pidW = (Get-Process WsaClient -ErrorAction SilentlyContinue).Id
if (-not $pidW) { L 'WsaClient not running'; exit }

$cond = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ProcessIdProperty, $pidW)
$wins = $root.FindAll([System.Windows.Automation.TreeScope]::Children, $cond)
L ('windows for pid ' + $pidW + ': ' + $wins.Count)

foreach ($w in $wins) {
    L ('---- WINDOW: name="' + $w.Current.Name + '" class="' + $w.Current.ClassName + '" ctrl=' + $w.Current.ControlType.ProgrammaticName + ' rect=' + $w.Current.BoundingRectangle)
    $all = $w.FindAll([System.Windows.Automation.TreeScope]::Subtree, [System.Windows.Automation.Condition]::TrueCondition)
    L ('  elements: ' + $all.Count)
    foreach ($e in $all) {
        $patterns = @()
        foreach ($pn in 'Invoke','Toggle','SelectionItem','Value','ExpandCollapse') {
            $p = $null
            if ($e.TryGetCurrentPattern(([System.Windows.Automation.Patterns]::$pn + 'Pattern'), [ref]$p)) { $patterns += $pn }
        }
        $b = $e.Current.BoundingRectangle
        L ('  [' + $e.Current.ControlType.ProgrammaticName + '] name="' + $e.Current.Name + '" class="' + $e.Current.ClassName + '" enabled=' + $e.Current.IsEnabled + ' rect=' + $b + ' pat=' + ($patterns -join '+'))
    }
}
L 'done'
