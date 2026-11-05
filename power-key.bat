@echo off
setlocal enabledelayedexpansion

:: 设置最大循环次数，防止脚本意外无限运行（可根据需要修改）
set max=100
set i=1

:loop
if %i% gtr %max% goto end

:: 获取当前时间并格式化，去除毫秒和多余空格
for /f "tokens=1,2 delims= " %%a in ("%time%") do set "cur_time=%%a %%b"
:: 如果时间是个位数（如 9:00），前面补个0保持美观
if "%cur_time:~1,1%"==":" set "cur_time=0%cur_time%"

echo [%date% %cur_time%] Iteration: %i%

:: 执行 adb 命令
adb shell input keyevent 26
:: 等待 5 秒
timeout /t 5 /nobreak >nul
adb shell input keyevent 26
:: 等待 10 秒
timeout /t 10 /nobreak >nul

set /a i+=1
goto loop

:end
echo 脚本执行完毕，共运行 %max% 次。
pause