$ErrorActionPreference = 'Continue'
Add-Type -Path "D:\Desktop\debug_temp\bat脚本\analysis\WinEnum.cs"

$target = 'D:\Desktop\debug_temp\bat脚本\disp_continuous_monitor.bat'
Write-Host "=== launching via ShellExecute (same as double click) ==="

$si = New-Object System.Diagnostics.ProcessStartInfo
$si.FileName = $target
$si.UseShellExecute = $true

$started = $false
try {
    $p = [System.Diagnostics.Process]::Start($si)
    Write-Host ("Process.Start returned, pid=" + $p.Id)
    $started = $true
} catch {
    Write-Host ("Process.Start THREW: " + $_.Exception.Message)
}

if ($started) {
    for ($i = 1; $i -le 8; $i++) {
        Start-Sleep -Milliseconds 700
        $hits = [WinEnum]::List() | Where-Object { $_ -match '安全性|Security|Warning|警告|無法|Open File' }
        if ($hits) {
            Write-Host ("--- t=" + ($i * 0.7) + "s dialog found ---")
            foreach ($h in $hits) { Write-Host ("  " + $h) }
        }
    }
}

Write-Host "=== cmd / conhost / DCMON windows ==="
[WinEnum]::List() | Where-Object { $_ -match 'cmd|conhost|DCMON' } | ForEach-Object { Write-Host ("  " + $_) }
