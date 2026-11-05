@echo off
chcp 65001 >nul
title Continuous Log Monitor

:: ========== 1. 生成带时间戳的输出目录 ==========
for /f "tokens=2-4 delims=/ " %%a in ('date /t') do set "date=%%a%%b%%c"
for /f "tokens=1-2 delims=: " %%a in ('time /t') do set "time=%%a%%b"
set "OUT=%~dp0LOGS_%date%_%time%"
set "OUT=%OUT: =0%"

:: ========== 2. 等待设备并获取 Root ==========
echo Waiting for device...
adb wait-for-device
echo Requesting root...
adb root

:: ========== 3. 准备目录 ==========
mkdir "%OUT%" 2>nul
cd /d "%OUT%"

:: ========== 4. 并发启动后台抓取 ==========
echo Monitoring started. Press Ctrl+C to stop and save logs.

:: 抓取按键事件（最小化窗口，错误重定向）
start "GetEvent" cmd /c "adb shell getevent -tlr > getevent.log 2>&1"

:: 清空旧日志缓冲
adb logcat -c -b all

:: 抓取 Logcat（最小化窗口，错误重定向）
start "Logcat" cmd /c "adb shell logcat -b all -v threadtime > logcat.txt 2>&1"

:: 抓取内核日志（最小化窗口，错误重定向）
start "Dmesg" cmd /c "adb shell dmesg -w > dmesg.log 2>&1"

:: ========== 5. 阻塞等待手动停止 ==========
pause >nul

:: 优雅退出整个脚本，防止残留
exit