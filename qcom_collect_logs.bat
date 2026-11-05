@echo off
setlocal enabledelayedexpansion

:: ============================================================
::  Parallel Log Collector  -  ADB
::  Collectors (all run simultaneously in separate windows):
::    1. logcat          -> logcat.log
::    2. kernel log      -> kernel_log.txt
::    3. xlog            -> xlog_out.txt
::    4. DCP events      -> dcp_events_stream.txt
::    5. SF dumpsys      -> sf.log
::
::  Press any key in THIS window to stop all collectors.
:: ============================================================

:: ---- Get timestamp via PowerShell ----
for /f %%I in ('powershell -NoProfile -Command "Get-Date -Format yyyyMMdd_HHmmss"') do set TIMESTAMP=%%I

:: ---- Timestamped output directory ----
set LOG_DIR=%~dp0logs_%TIMESTAMP%
mkdir "%LOG_DIR%"

echo.
echo ============================================================
echo  Parallel Log Collector
echo ============================================================
echo.
echo  Log directory:
echo    %LOG_DIR%
echo.
echo  Files that will be collected:
echo    %LOG_DIR%\logcat.log              (logcat stream)
echo    %LOG_DIR%\kernel_log.txt          (dmesg -w stream)
echo    %LOG_DIR%\xlog_out.txt            (DRI debug dump loop)
echo    %LOG_DIR%\dcp_events_stream.txt   (HFI core events loop)
echo    %LOG_DIR%\sf.log                  (SurfaceFlinger dumpsys loop)
echo    %LOG_DIR%\dcp_events_final.txt    (HFI snapshot at stop)
echo    %LOG_DIR%\dcp_state_modalias.txt  (DRM modalias snapshot)
echo    %LOG_DIR%\dmesg_final.txt         (dmesg snapshot at stop)
echo    %LOG_DIR%\sf_final.txt            (SF dumpsys snapshot at stop)
echo.
echo ============================================================

:: ---- One-time device setup ----
echo.
echo [SETUP] start..
adb root
adb remount
adb shell "mount -t debugfs none /sys/kernel/debug"
adb shell "echo 31 > /d/dri/0/debug/enable"

::adb shell "echo 0x10007 > /sys/kernel/debug/hfi_core/hfi_core_debug_level"

::adb shell "echo 1 > /sys/kernel/debug/hfi_core/hfi_core_register_client"

adb logcat -c
adb logcat -G 128M 
adb shell vndservice call display.qservice 15 i32 0 i32 1 i32 1


echo [SETUP] Done.

:: ---- Write per-collector helper scripts to TEMP ----

:: 1. logcat
(
    echo @echo off
    echo title LOGCAT
    echo echo.
    echo echo  [LOGCAT] Saving to:
    echo echo    %LOG_DIR%\logcat.log
    echo echo.
    echo adb logcat -v threadtime ^> "%LOG_DIR%\logcat.log" 2^>^&1
) > "%TEMP%\adb_col_logcat.bat"

:: 2. kernel log  (dmesg -w)
(
    echo @echo off
    echo title KERNEL_LOG
    echo echo.
    echo echo  [KERNEL_LOG] Saving to:
    echo echo    %LOG_DIR%\kernel_log.txt
    echo echo.
    echo adb shell dmesg -w ^> "%LOG_DIR%\kernel_log.txt" 2^>^&1
) > "%TEMP%\adb_col_kernel.bat"

:: 3. xlog  (continuous /d/dri/0/debug/dump loop)
(
    echo @echo off
    echo title XLOG
    echo echo.
    echo echo  [XLOG] Saving to:
    echo echo    %LOG_DIR%\xlog_out.txt
    echo echo.
    echo adb shell "while true; do cat /d/dri/0/debug/dump; done" ^> "%LOG_DIR%\xlog_out.txt" 2^>^&1
) > "%TEMP%\adb_col_xlog.bat"

:: 4. DCP event log  (continuous hfi_core_dump_events poll)
(
    echo @echo off
    echo title DCP_EVENTS
    echo echo.
    echo echo  [DCP_EVENTS] Saving to:
    echo echo    %LOG_DIR%\dcp_events_stream.txt
    echo echo.
    echo adb shell "while true; do cat /sys/kernel/debug/hfi_core/hfi_core_dump_events; done" ^> "%LOG_DIR%\dcp_events_stream.txt" 2^>^&1
) > "%TEMP%\adb_col_dcp.bat"

:: 5. SurfaceFlinger dumpsys  (continuous poll)
(
    echo @echo off
    echo title SF_DUMPSYS
    echo echo.
    echo echo  [SF_DUMPSYS] Saving to:
    echo echo    %LOG_DIR%\sf.log
    echo echo.
    echo adb shell "while true; do dumpsys SurfaceFlinger; echo ---SF_DUMP---; done" ^> "%LOG_DIR%\sf.log" 2^>^&1
) > "%TEMP%\adb_col_sf.bat"

:: ---- Launch all 5 collectors in parallel (each in its own window) ----
echo.
echo [START] Launching all collectors simultaneously ...
start "LOGCAT"     cmd /c "%TEMP%\adb_col_logcat.bat"
start "KERNEL_LOG" cmd /c "%TEMP%\adb_col_kernel.bat"
start "XLOG"       cmd /c "%TEMP%\adb_col_xlog.bat"
start "DCP_EVENTS" cmd /c "%TEMP%\adb_col_dcp.bat"
::start "SF_DUMPSYS" cmd /c "%TEMP%\adb_col_sf.bat"

echo.
echo ============================================================
echo  5 collector windows are now running in parallel:
echo.
echo    [LOGCAT]
echo      %LOG_DIR%\logcat.log
echo.
echo    [KERNEL_LOG]
echo      %LOG_DIR%\kernel_log.txt
echo.
echo    [XLOG]
echo      %LOG_DIR%\xlog_out.txt
echo.
echo    [DCP_EVENTS]
echo      %LOG_DIR%\dcp_events_stream.txt
echo.
echo    [SF_DUMPSYS]
echo      %LOG_DIR%\sf.log
echo.
echo ============================================================
echo.
echo  *** Press any key in THIS window to STOP all collectors ***
echo      and save final snapshots.
echo.
pause > nul

:: ---- Stop all collector windows by title ----
echo.
echo [STOP] Stopping all collector windows ...
taskkill /fi "WindowTitle eq LOGCAT"     /f > nul 2>&1
taskkill /fi "WindowTitle eq KERNEL_LOG" /f > nul 2>&1
taskkill /fi "WindowTitle eq XLOG"       /f > nul 2>&1
taskkill /fi "WindowTitle eq DCP_EVENTS" /f > nul 2>&1
taskkill /fi "WindowTitle eq SF_DUMPSYS" /f > nul 2>&1

:: Give adb a moment to release
timeout /t 2 /nobreak > nul

:: ---- Final one-shot snapshots ----
echo.
echo [SNAPSHOT] Saving final snapshots ...

echo   Writing: %LOG_DIR%\dmesg_final.txt
adb shell dmesg > "%LOG_DIR%\dmesg_final.txt" 2>&1

echo   Writing: %LOG_DIR%\dcp_events_final.txt
adb shell cat /sys/kernel/debug/hfi_core/hfi_core_dump_events > "%LOG_DIR%\dcp_events_final.txt" 2>&1

echo   Writing: %LOG_DIR%\dcp_state_modalias.txt
adb shell cat /sys/class/drm/card0/device/modalias > "%LOG_DIR%\dcp_state_modalias.txt" 2>&1

echo   Writing: %LOG_DIR%\sf_final.txt
adb shell dumpsys SurfaceFlinger > "%LOG_DIR%\sf_final.txt" 2>&1

:: ---- Cleanup temp helpers ----
del "%TEMP%\adb_col_logcat.bat" > nul 2>&1
del "%TEMP%\adb_col_kernel.bat" > nul 2>&1
del "%TEMP%\adb_col_xlog.bat"   > nul 2>&1
del "%TEMP%\adb_col_dcp.bat"    > nul 2>&1
del "%TEMP%\adb_col_sf.bat"     > nul 2>&1

echo.
echo ============================================================
echo  Collection complete!
echo.
echo  All logs saved to:
echo    %LOG_DIR%
echo.
echo  Full file paths:
echo    %LOG_DIR%\logcat.log              (logcat stream)
echo    %LOG_DIR%\kernel_log.txt          (dmesg -w stream)
echo    %LOG_DIR%\xlog_out.txt            (DRI debug dump stream)
echo    %LOG_DIR%\dcp_events_stream.txt   (HFI core events stream)
echo    %LOG_DIR%\sf.log                  (SurfaceFlinger dumpsys stream)
echo    %LOG_DIR%\dcp_events_final.txt    (HFI core events snapshot)
echo    %LOG_DIR%\dcp_state_modalias.txt  (DRM modalias snapshot)
echo    %LOG_DIR%\dmesg_final.txt         (dmesg snapshot)
echo    %LOG_DIR%\sf_final.txt            (SurfaceFlinger snapshot)
echo ============================================================
echo.
pause