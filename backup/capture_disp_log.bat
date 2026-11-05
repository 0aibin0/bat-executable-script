@echo off
chcp 65001 >nul
title Quick Log Capture

for /f "tokens=2-4 delims=/ " %%a in ('date /t') do set "date=%%a%%b%%c"
for /f "tokens=1-2 delims=: " %%a in ('time /t') do set "time=%%a%%b"
set "OUT=%~dp0LOGS_%date%_%time%"
set "OUT=%OUT: =0%"

echo Waiting for device...
adb wait-for-device

echo root...
adb root

echo Creating output dir...
mkdir "%OUT%" 2>nul

echo Capturing logcat...
adb logcat -d -v threadtime -b all > "%OUT%\logcat_all.txt"

echo Capturing dmesg...
adb shell dmesg > "%OUT%\dmesg.txt"

echo Capturing dumpsys info...
adb shell dumpsys display > "%OUT%\dumpsys_display.txt"
adb shell dumpsys SurfaceFlinger > "%OUT%\dumpsys_sf.txt"
adb shell dumpsys power > "%OUT%\dumpsys_power.txt"
adb shell dumpsys input > "%OUT%\dumpsys_input.txt"

echo Capturing system info...
adb shell getprop > "%OUT%\props.txt"
adb shell cat /proc/cmdline > "%OUT%\cmdline.txt"

echo Capturing bugreport...
adb bugreport "%OUT%\bugreport.zip"

echo.
echo ========================================
echo Done! Logs saved to:
echo %OUT%
echo ========================================
dir /b "%OUT%"
echo.
pause