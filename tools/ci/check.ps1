<#
  CI checks for the Good Pizza, Great Pizza launcher.

  One script, several checks, so that CI and a local run execute the exact same
  bytes:

      powershell -ExecutionPolicy Bypass -File tools\ci\check.ps1 -Check hygiene

  Checks
    hygiene    the files that ship to users (src + README) carry no personal
               paths, no session temp dirs, no scratch test dirs, no
               unfinished-work markers
    manifest   the exe still self-elevates (requireAdministrator) and declares
               PerMonitorV2 - losing either silently breaks a clean-machine run
    readme     every relative link / image in README.md resolves to a file that
               exists, so screenshots cannot rot
    dialogs    user-facing questions and failures go through AskPrompt /
               Attention; MessageBox stays allowed only for the one
               single-instance notice
    tray       every literal Tray.SetStatus string still fits the 63-char
               NotifyIcon.Text budget after the 25-char title prefix - two
               statuses shipped once silently cut off in the tray
    icon       tools\goodpizza.ico exists with a valid ICO header (build input)

  Exit 0 = pass, 1 = fail. Every message starts with PASS or FAIL, so the run is
  readable straight from the Actions page.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('hygiene', 'manifest', 'readme', 'dialogs', 'tray', 'icon')]
    [string]$Check
)

# NB: $ErrorActionPreference stays at Continue on purpose. These checks are
# about reporting a failing fact, not about throwing; an exception in CI shows
# up as a stack trace, which reads like a broken check rather than a broken repo.
# tools\ci\check.ps1 -> tools -> repo root
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

function Fail([string]$m) { Write-Output "FAIL  $m"; exit 1 }
function Pass([string]$m) { Write-Output "PASS  $m"; exit 0 }

switch ($Check) {

    'hygiene' {
        # Scoped deliberately: tools\lab\* documents real local paths because it
        # is the experiment log behind this README, and scanning it would only
        # teach contributors to work around the check. The exe's own source and
        # the README are what users actually get.
        $files = @('src\AppLauncher.cs', 'README.md')
        $patterns = [ordered]@{
            'personal path'          = 'C:\\Users\\'
            'local user name'        = 'ysmag'
            'session temp dir'       = 'Temp\\opencode'
            'local backup reference' = 'WSA-backup'
            'scratch test dir'       = 'wsatest'
            'hold marker'            = '\.hold'
            'unfinished work'        = 'TODO|FIXME'
        }
        $bad = 0
        foreach ($f in $files) {
            $p = Join-Path $root $f
            if (-not (Test-Path -LiteralPath $p)) { Fail "missing tracked file: $f" }
            $lines = Get-Content -LiteralPath $p
            foreach ($k in $patterns.Keys) {
                for ($i = 0; $i -lt $lines.Count; $i++) {
                    if ($lines[$i] -match $patterns[$k]) {
                        Write-Output ("FAIL  {0}:{1} matched '{2}': {3}" -f $f, ($i + 1), $k, $lines[$i].Trim())
                        $bad++
                    }
                }
            }
        }
        if ($bad -gt 0) { exit 1 }
        Pass ("hygiene: {0} shipped files clean ({1} patterns)" -f $files.Count, $patterns.Count)
    }

    'manifest' {
        $m = Join-Path $root 'tools\app.manifest'
        if (-not (Test-Path -LiteralPath $m)) { Fail 'tools\app.manifest is missing' }
        $raw = [IO.File]::ReadAllText($m)
        # Without requireAdministrator: Add-AppxPackage -Register fails 0x80073D28
        # on a clean machine (packaged service), and the Hyper-V cmdlets fail too.
        if ($raw -notmatch 'requestedExecutionLevel[^>]*level="requireAdministrator"') {
            Fail 'app.manifest no longer requests requireAdministrator - registration would fail 0x80073D28'
        }
        # Without PerMonitorV2 the hard-coded prompt layout renders wrong at
        # non-100% display scaling (measured: the download prompt has a 6 px gap).
        if ($raw -notmatch 'PerMonitorV2') {
            Fail 'app.manifest no longer declares PerMonitorV2 DPI awareness'
        }
        Pass 'manifest: requireAdministrator + PerMonitorV2 present'
    }

    'readme' {
        $rp = Join-Path $root 'README.md'
        if (-not (Test-Path -LiteralPath $rp)) { Fail 'README.md is missing' }
        $raw = [IO.File]::ReadAllText($rp)
        $missing = 0
        $checked = 0
        foreach ($m in [regex]::Matches($raw, '\]\(([^)]+)\)')) {
            $link = $m.Groups[1].Value
            if ($link -match '^(https?:|mailto:|#)') { continue }   # external / in-page anchor
            $clean = ($link -split '#')[0].Trim()
            if (-not $clean) { continue }                            # pure anchor
            $checked++
            if (-not (Test-Path -LiteralPath (Join-Path $root $clean))) {
                Write-Output "FAIL  README.md links to a file that does not exist: $clean"
                $missing++
            }
        }
        if ($missing -gt 0) { exit 1 }
        Pass ("readme: all {0} relative links resolve" -f $checked)
    }

    'dialogs' {
        $sp = Join-Path $root 'src\AppLauncher.cs'
        if (-not (Test-Path -LiteralPath $sp)) { Fail 'src\AppLauncher.cs is missing' }
        $src = Get-Content -LiteralPath $sp
        # MessageBox cannot take focus reliably from an elevated background
        # process (observed opening behind the user's windows), which reads as
        # "the exe did nothing". Every question and failure therefore goes
        # through AskPrompt/Attention, which flash the taskbar when they cannot
        # take focus. The single-instance notice is the one accepted MessageBox.
        $code = @($src | Where-Object { $_ -notmatch '^\s*//' })
        $mb = @($code | Where-Object { $_ -match 'MessageBox\.Show' })
        $stray = @($mb | Where-Object { $_ -notmatch 'already running' })
        if ($stray.Count -gt 0) {
            foreach ($s in $stray) { Write-Output ("FAIL  MessageBox.Show outside the allowlist: {0}" -f $s.Trim()) }
            Fail 'use Attention()/AskPrompt() for user-facing windows (MessageBox opens behind other windows when elevated)'
        }
        if ($mb.Count -eq 0) { Fail 'the single-instance MessageBox notice disappeared; if that was on purpose, drop this assertion too' }
        $ask = @($src | Where-Object { $_ -match 'new AskPrompt\(' }).Count
        $att = @($src | Where-Object { $_ -match 'Attention\(' }).Count
        if ($ask -eq 0) { Fail 'AskPrompt is no longer used - questions would fall back to MessageBox' }
        if ($att -eq 0) { Fail 'Attention() is no longer called - prompts could open behind other windows' }
        Pass ("dialogs: AskPrompt x{0}, Attention x{1}, MessageBox allowlisted x{2}" -f $ask, $att, $mb.Count)
    }

    'tray' {
        $sp = Join-Path $root 'src\AppLauncher.cs'
        if (-not (Test-Path -LiteralPath $sp)) { Fail 'src\AppLauncher.cs is missing' }
        $src = Get-Content -LiteralPath $sp -Raw
        # NotifyIcon.Text throws past 63 characters on the .NET Framework, and
        # SetText() prefixes "Good Pizza, Great Pizza - " (25 chars), leaving 38
        # for the status itself. Two statuses overran that budget once and were
        # silently cut in the tray, so the literals are measured here. Only pure
        # literals: the concatenated statuses end in a small variable part
        # (MB counts, minutes) that is bounded by construction.
        $bad = 0
        $checked = 0
        foreach ($m in [regex]::Matches($src, 'Tray\.SetStatus\("([^"]*)"\)')) {
            $s = $m.Groups[1].Value
            $checked++
            if ((25 + $s.Length) -gt 63) {
                Write-Output ("FAIL  tray status is {0} chars, {1} with the title prefix (limit 63): {2}" -f `
                              $s.Length, (25 + $s.Length), $s)
                $bad++
            }
        }
        if ($checked -eq 0) { Fail 'no literal Tray.SetStatus call found - the status line changed shape and this check rotted' }
        if ($bad -gt 0) { exit 1 }
        Pass ("tray: {0} literal statuses fit the 63-char tray budget" -f $checked)
    }

    'icon' {
        $ip = Join-Path $root 'tools\goodpizza.ico'
        if (-not (Test-Path -LiteralPath $ip)) { Fail 'tools\goodpizza.ico is missing - the build would need network to regenerate it' }
        $b = [IO.File]::ReadAllBytes($ip)
        if ($b.Length -lt 76) { Fail ("ico is only {0} bytes" -f $b.Length) }
        if (-not ($b[0] -eq 0 -and $b[1] -eq 0 -and $b[2] -eq 1 -and $b[3] -eq 0)) {
            Fail ("ico header is {0:X2} {1:X2} {2:X2} {3:X2}, expected 00 00 01 00" -f $b[0], $b[1], $b[2], $b[3])
        }
        Pass ("icon: {0} bytes, valid ICO header" -f $b.Length)
    }
}
