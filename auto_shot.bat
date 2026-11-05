@echo off
chcp 65001 >nul
setlocal enabledelayedexpansion
title Android Camera Auto Shot

set INTERVAL=3
set CAMERA_WAIT=2
set TAP_X=243
set TAP_Y=512
set PHONE_PATH=/sdcard/DCIM/Camera
set SAVE_DIR=%cd%\Camera_Android

if not exist "%SAVE_DIR%" mkdir "%SAVE_DIR%"

echo ==============================================
echo Camera started
echo Interval: %INTERVAL% sec
echo Shutter: X=%TAP_X% Y=%TAP_Y%
echo Save to: %SAVE_DIR%
echo Press Ctrl+C to stop
echo ==============================================

:LOOP
set ts=%date:~0,4%%date:~5,2%%date:~8,2%%time:~0,2%%time:~3,2%%time:~6,2%
set ts=!ts: =0!

adb shell am force-stop com.android.camera2 >nul 2>&1
timeout /t 1 /nobreak >nul

adb shell am start -n com.android.camera2/com.android.camera.CameraActivity >nul 2>&1
timeout /t %CAMERA_WAIT% /nobreak >nul

adb shell input tap %TAP_X% %TAP_Y%
timeout /t 2 /nobreak >nul

for /f "delims=" %%i in ('adb shell ls -t %PHONE_PATH%/*.jpg 2^>nul') do (
    set file=%%i
    goto PULL
)
:PULL

adb pull "!file!" "%SAVE_DIR%\!ts!.jpg" >nul 2>&1
echo OK: !ts!.jpg

adb shell am force-stop com.android.camera2 >nul 2>&1
timeout /t %INTERVAL% /nobreak >nul

goto LOOP