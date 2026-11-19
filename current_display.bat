@echo off
setlocal EnableExtensions EnableDelayedExpansion
chcp 65001 >nul
title Current Display Snapshot

:: ================================================================
::  current_display.bat   (optimized)
::  One-shot point-in-time snapshot of the display stack.
::  No streaming, no background windows - just dump state and exit.
::
::  Fixes vs the original:
::   1. Timestamp from PowerShell (not "date /t", which on a Chinese
::      Windows prints "2026/11/05 <weekday>" and produced garbage
::      directory names like "LOGS_1105<weekday>_<hhmm>")
::   2. No more "set OUT=%OUT: =0%" - that rewrote spaces in the PATH
::      too, so a script folder containing a space silently received
::      the logs in a renamed "shadow" folder
::   3. setlocal - no more clobbering the cmd built-ins date / time
::   4. Device / root / mkdir / cd are all checked; failures stop
::      the run instead of silently writing files to the wrong place
::   5. Every adb call is checked and every output file is measured,
::      so an empty or truncated snapshot is visible immediately
::   6. A summary file lists every artifact with its size
::
::  Usage:
::    current_display.bat
::    set SNAP_NO_PAUSE=1 & current_display.bat      (no final pause)
::    set ENABLE_BUGREPORT=1 & current_display.bat   (also run adb bugreport)
::
::  adb bugreport takes 1-3 minutes, so it is OFF by default:
::  this script is meant to be a fast point-in-time check.
:: ================================================================

if not defined SNAP_NO_PAUSE set "SNAP_NO_PAUSE=0"
if not defined ENABLE_BUGREPORT set "ENABLE_BUGREPORT=0"

:: total step count depends on whether bugreport is enabled
set "TOT=4"
if "%ENABLE_BUGREPORT%"=="1" set "TOT=5"

:: ---------------- 1. timestamp + output dir ----------------
set "STAMP="
for /f "usebackq delims=" %%t in (`powershell -NoProfile -Command "Get-Date -Format yyyyMMdd_HHmmss"`) do set "STAMP=%%t"
if not defined STAMP (
    set "STAMP=%date:~0,4%%date:~5,2%%date:~8,2%_%time:~0,2%%time:~3,2%%time:~6,2%"
    set "STAMP=!STAMP: =0!"
)
set "OUT=%~dp0LOGS_!STAMP!"

echo.
echo ================================================================
echo  Current Display Snapshot
echo ================================================================

:: ---------------- 2. device + root ----------------
echo [1/!TOT!] Waiting for device ...
call :wait_dev 60
if errorlevel 1 (
    echo [FAIL] No device within 60 seconds. Run "adb devices" to check.
    goto :fail
)
echo       OK, device is online.

echo [2/!TOT!] Requesting root ...
adb root > root.txt 2>&1
call :sleep 1
:: "adb root" restarts adbd when it was not root yet, so wait again.
call :wait_dev 30
if errorlevel 1 (
    echo [FAIL] Device disappeared after "adb root".
    goto :fail
)
set "ROOTED=0"
adb shell id 2>nul | findstr /b /c:"uid=0(" >nul 2>&1 && set "ROOTED=1"
if "!ROOTED!"=="1" (
    echo       OK, adbd is running as root.
) else (
    echo [WARN] Device is not rooted. dmesg and some dumpsys may be
    echo        empty or permission denied - see root.txt
)

:: ---------------- 3. output dir ----------------
echo [3/!TOT!] Creating output dir ...
mkdir "%OUT%" 2>nul
if not exist "%OUT%\" (
    echo [FAIL] Cannot create output directory:
    echo        "%OUT%"
    echo        Check free disk space and write permission, or a file
    echo        with the same name already exists.
    goto :fail
)
pushd "%OUT%" || (
    echo [FAIL] Cannot enter "%OUT%"
    goto :fail
)
break> snapshot_summary.txt

:: ---------------- 4. snapshots ----------------
echo [4/!TOT!] Capturing snapshots ...
call :snap "device list"      devices.txt                  "adb devices -l"
call :snap "logcat all buffers" logcat_all_current.txt      "adb logcat -d -v threadtime -b all"
call :snap "dmesg"            dmesg_current.txt           "adb shell dmesg"
call :snap "dumpsys display"  dumpsys_display_current.txt "adb shell dumpsys display"
call :snap "dumpsys SurfaceFlinger" dumpsys_sf_current.txt "adb shell dumpsys SurfaceFlinger"
call :snap "dumpsys input"    dumpsys_input_current.txt   "adb shell dumpsys input"
call :snap "dumpsys power"    dumpsys_power_current.txt   "adb shell dumpsys power"
call :snap "dumpsys gpu"      dumpsys_gpu_current.txt     "adb shell dumpsys gpu"
call :snap "dumpsys meminfo"  dumpsys_meminfo_current.txt "adb shell dumpsys meminfo"
call :snap "dumpsys window"   dumpsys_window_current.txt  "adb shell dumpsys window"
call :snap "getprop"          getprop_current.txt         "adb shell getprop"
call :snap "cmdline"          cmdline.txt                 "adb shell cat /proc/cmdline"

:: ---------------- 5. optional bugreport ----------------
if "%ENABLE_BUGREPORT%"=="1" (
    echo [5/!TOT!] Generating bugreport ^(1-3 min, do not close this window^) ...
    adb bugreport "%OUT%\bugreport.zip" >"%OUT%\bugreport_log.txt" 2>&1
    if errorlevel 1 (
        echo   [FAIL] bugreport.zip
        >>snapshot_summary.txt echo  [FAIL] bugreport.zip   ^<- bugreport
    ) else (
        if exist "bugreport.zip" (
            for %%F in (bugreport.zip) do set "SZB=%%~zF"
            if !SZB! LSS 1000000 (
                echo   [WARN] bugreport.zip  !SZB! bytes, looks truncated
                >>snapshot_summary.txt echo  [WARN] bugreport.zip  !SZB! bytes   ^<- bugreport
            ) else (
                echo   [ OK ] bugreport.zip  !SZB! bytes
                >>snapshot_summary.txt echo  [ OK ] bugreport.zip  !SZB! bytes   ^<- bugreport
            )
        )
    )
)

:: ---------------- 6. summary ----------------
echo.
echo ================================================================
echo  Snapshot summary
echo ================================================================
type snapshot_summary.txt
echo.
echo  Artifacts in: "%OUT%"
echo ================================================================

popd
if "!SNAP_NO_PAUSE!"=="1" exit /b 0
pause
exit /b 0

:: ================================================================
::  Subroutines
:: ================================================================

:wait_dev
:: %1 = timeout in seconds. Returns 0 when the device is ready.
set /a _w=0
:wd_loop
adb get-state >nul 2>&1
if not errorlevel 1 exit /b 0
set /a _w+=1
if !_w! GEQ %~1 exit /b 1
call :sleep 1
goto wd_loop

:sleep
:: %1 = seconds. ping -n N actually waits about N-1 seconds.
if "%~1"=="" exit /b 0
set /a _slp=%~1+1
ping -n !_slp! 127.0.0.1 >nul 2>&1
exit /b 0

:snap
:: %1 = label   %2 = output file   %3 = command to run
set "SZ=0"
%~3 > "%~2" 2>&1
set "RC=%errorlevel%"
if exist "%~2" for %%F in ("%~2") do set "SZ=%%~zF"
if "%RC%"=="0" (
    echo   [ OK ] %~2  !SZ! bytes
    >>snapshot_summary.txt echo  [ OK ] %~2  !SZ! bytes   ^<- %~1
) else (
    echo   [FAIL] %~2  rc=%RC%
    >>snapshot_summary.txt echo  [FAIL] %~2  rc=%RC%   ^<- %~1
)
exit /b 0

:fail
echo.
echo [FAIL] Snapshot aborted, nothing was written to "%OUT%".
echo        If a partial folder exists, remove it manually.
if "!SNAP_NO_PAUSE!"=="1" exit /b 1
pause
exit /b 1
