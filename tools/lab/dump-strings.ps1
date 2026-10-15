$ErrorActionPreference = 'Continue'
$log = 'C:\Users\ysmag\AppData\Local\Temp\dumpscan.log'
function L($m) { Add-Content -Path $log -Value $m; $m }

$f = 'C:\WSAdumps\WsaClient.exe.11008.dmp'
if (-not (Test-Path $f)) { L 'no dump'; exit 1 }

# literal needles, searched as raw bytes in BOTH encodings (no regex: 100x faster)
$needles = @('userdata', '.vhdx', 'LocalCache', 'WSA', 'AppData', 'metadata', 'C:\WSA', 'package')
$targets = @()
foreach ($n in $needles) {
    $targets += ,@('U16:' + $n, [System.Text.Encoding]::Unicode.GetBytes($n))
    $targets += ,@('ASC:' + $n, [System.Text.Encoding]::ASCII.GetBytes($n))
}

$fs = [System.IO.File]::OpenRead($f)
$size = $fs.Length
L ('scanning ' + [math]::Round($size/1MB,1) + ' MB')

# read the whole file into memory once (98 MB is fine)
$all = New-Object byte[] $size
$off = 0
while ($off -lt $size) {
    $n = $fs.Read($all, $off, [Math]::Min(8MB, $size - $off))
    if ($n -le 0) { break }
    $off += $n
}
$fs.Close()
L ('read ' + [math]::Round($off/1MB,1) + ' MB')

function IndexOf-Bytes([byte[]]$hay, [byte[]]$needle, [int]$from, [int]$limit) {
    $first = $needle[0]
    $max = [Math]::Min($hay.Length - $needle.Length, $from + $limit)
    for ($i = $from; $i -le $max; $i++) {
        if ($hay[$i] -eq $first) {
            $ok = $true
            for ($j = 1; $j -lt $needle.Length; $j++) {
                if ($hay[$i + $j] -ne $needle[$j]) { $ok = $false; break }
            }
            if ($ok) { return $i }
        }
    }
    return -1
}

$found = @{}
foreach ($t in $targets) {
    $label = $t[0]; $nb = $t[1]
    $positions = @()
    $from = 0
    while ($true) {
        $p = IndexOf-Bytes $all $nb $from 40MB
        if ($p -lt 0) { break }
        $positions += $p
        if ($positions.Count -ge 4) { break }
        $from = $p + $nb.Length
    }
    if ($positions.Count) { $found[$label] = $positions }
}

foreach ($k in ($found.Keys | Sort-Object)) {
    L ('--- ' + $k + '  x' + $found[$k].Count)
    foreach ($p in $found[$k]) {
        # pull 100 bytes of context around the hit and keep printable chars
        $s = [Math]::Max(0, $p - 120)
        $len = [Math]::Min(240, $all.Length - $s)
        $chunk = New-Object byte[] $len
        [Array]::Copy($all, $s, $chunk, 0, $len)
        $txt = [System.Text.Encoding]::Unicode.GetString($chunk)
        $clean = ($txt -replace '[^\x20-\x7E\\:]', '.')
        L ('   @' + $p + '  ' + $clean)
    }
}
L 'scan done'
