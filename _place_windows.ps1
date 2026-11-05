param(
    [Parameter(Mandatory=$true)][string]$Pids,
    [string]$Lay = 'a'
)
# Place the collector console windows so they do not overlap.
# Called from disp_continuous_monitor.bat right after the windows start.
#   $Pids : comma separated process ids, e.g. "1234,5678"
#   $Lay  : "a" = left/right side by side, "b" = top/bottom stacked

Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
Add-Type -Name Win -Namespace Prb -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
'@ -ErrorAction SilentlyContinue

$ids = @($Pids -split ',' | Where-Object { $_ -match '^\d+$' } | ForEach-Object { [int]$_ })
if ($ids.Count -eq 0) { exit 0 }

# Wait until every window handle shows up: a new console needs a moment.
$procs = @()
for ($t = 0; $t -lt 40; $t++) {
    $procs = @()
    foreach ($id in $ids) {
        $p = Get-Process -Id $id -ErrorAction SilentlyContinue
        if ($p -and $p.MainWindowHandle -ne [IntPtr]::Zero) { $procs += $p }
    }
    if ($procs.Count -eq $ids.Count) { break }
    Start-Sleep -Milliseconds 150
}
if ($procs.Count -eq 0) { exit 0 }

$w = 1920
$h = 1080
try {
    $scr = [System.Windows.Forms.Screen]::PrimaryScreen
    if ($scr) { $w = $scr.Bounds.Width; $h = $scr.Bounds.Height }
} catch { }

for ($i = 0; $i -lt $procs.Count; $i++) {
    if ($Lay -eq 'b') {
        $x = 40
        $y = [int]($h * 0.04) + $i * [int]($h * 0.46)
    } else {
        $x = 40 + $i * [int]($w * 0.48)
        $y = 40
    }
    if ($x -lt 0) { $x = 0 }
    if ($y -lt 0) { $y = 0 }
    [Prb.Win]::SetWindowPos($procs[$i].MainWindowHandle, [IntPtr]::Zero, $x, $y, 0, 0, 0x0001) | Out-Null
}
exit 0
