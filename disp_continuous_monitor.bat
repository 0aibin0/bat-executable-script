@echo off
setlocal EnableDelayedExpansion
chcp 936 >nul
title Display Replay Monitor

:: ================================================================
::  disp_continuous_monitor.bat   (优化版)
::  显示问题复现采集: 前基线 -> 并行实时抓取 -> 后快照 -> 截图 -> bugreport
::
::  与原版相比的改动:
::   1. 采集窗口由本脚本自己回收 (taskkill /T), 不再要求"人手关窗口"
::   2. 主窗口不再裸 pause: 按 S 立即停止; 到时长/到体积也会自动停
::   3. 所有 adb 步骤都判退出码, 结束时 session_summary.txt 汇总失败项
::   4. 时间戳只对时间数字补零, 脚本目录含空格不会写进"影子目录"
::   5. 前基线快照之后才清 logcat 缓冲, 复现窗口可用文件边界切分
::   6. 采集命令只写相对路径, 中文/空格路径不进临时 bat
::   7. 停止判定用墙钟时间, 不依赖 choice 的计时精度
:: ================================================================

:: ---------------- 可调参数 (环境变量已存在时尊重外部设置) ----------------
::  用法示例:  set MAX_MIN=60 & set MAX_MB=2000 & disp_continuous_monitor.bat
::
::  MAX_MIN      最长抓取分钟数, 到点自动停止 (0 = 不限制)
::  MAX_MB       实时日志总大小上限 MB, 超过自动停止 (0 = 不限制)
::  POLL_SEC     检查间隔秒数
::  LOGCAT_BUF   设备端 logcat 环形缓冲
::  CLEAR_LOGCAT 1 = 前基线之后清缓冲(只留复现期间); 0 = 保留开机以来
::  KEEP_RUNS    只保留最近 N 个 LOGS_* 目录, 更早的自动删除
::               默认 0 = 不清理, 不会误删历史数据
if not defined MAX_MIN      set "MAX_MIN=30"
if not defined MAX_MB       set "MAX_MB=800"
if not defined POLL_SEC     set "POLL_SEC=5"
if not defined LOGCAT_BUF   set "LOGCAT_BUF=128M"
if not defined CLEAR_LOGCAT set "CLEAR_LOGCAT=1"
if not defined HARD_LIMIT_SEC set "HARD_LIMIT_SEC=0"   :: 0 = 不设硬上限
if not defined ADB_SERIAL    set "ADB_SERIAL="         :: 多设备时指定序列号
if not defined SKIP_BUGREPORT set "SKIP_BUGREPORT=0"   :: 1 = 跳过 bugreport
if not defined KEEP_RUNS      set "KEEP_RUNS=0"        :: 只保留最近 N 个 LOGS_*, 0 = 不清理
:: ---------------------------------------------------------------------

:: 总步数随 SKIP_BUGREPORT 变化, 避免跳过时还显示 9 步
set "TOT=9"
if "%SKIP_BUGREPORT%"=="1" set "TOT=8"

set "FAILCNT=0"
set "WARNCNT=0"
set "STOPWHY=operator"
set "FAILS=failures.tmp"

echo.
echo ================================================================
echo  Display Replay Monitor
echo ================================================================

:: ========== 1. 输出目录 ==========
for /f "delims=" %%t in ('powershell -NoProfile -Command "Get-Date -Format yyyyMMdd_HHmmss"') do set "STAMP=%%t"
if not defined STAMP (
    set "STAMP=%date:~0,4%%date:~5,2%%date:~8,2%_%time:~0,2%%time:~3,2%%time:~6,2%"
    set "STAMP=!STAMP: =0!"
)
set "OUT=%~dp0LOGS_!STAMP!"

mkdir "%OUT%" 2>nul
if not exist "%OUT%\" (
    echo [FAIL] 无法创建输出目录: "%OUT%"
    echo        检查磁盘空间 / 写权限, 或同名文件占位。
    pause
    exit /b 1
)
pushd "%OUT%" || (
    echo [FAIL] 无法进入 "%OUT%"
    pause
    exit /b 1
)
echo [ OK ] 输出目录: %OUT%
:: 采集子脚本写到输出目录, 不写 %TEMP%:
:: McAfee 企业版在"阻止 Temp 创建文件"模式下会拦截
set "TMPD=%OUT%\_collector_tmp"
break> "%FAILS%"

:: ========== 2. 等设备 + root ==========
echo.

:: 先把 ADB 命令前缀定义好, 后面所有调用都走它
:: (之前写在 devices -l 之后, 导致那一行展开为空, 实际执行 "命令不存在")
set "ADB=adb"
if not "!ADB_SERIAL!"=="" set "ADB=adb -s !ADB_SERIAL!"

echo [1/!TOT!] 等待设备 ...
call :wait_device 60
if errorlevel 1 (
    echo [FAIL] 60 秒内没有可用设备。先跑 "adb devices" 确认连接与授权。
    popd
    pause
    exit /b 2
)

:: 多设备检测: adb 在多设备时所有命令都会报 "more than one device"
:: 而原版本不判断这个, 所以全部快照都是空的且仍然报 "Done!"
set /a _DEVN=0
for /f "skip=1 tokens=1" %%d in ('adb devices') do set /a _DEVN+=1
!ADB! devices -l                      > devices.txt 2>&1
if !_DEVN! GTR 1 (
    echo [FAIL] 检测到 !_DEVN! 台设备在线, adb 无法确定目标。
    echo        请用环境变量指定一台:
    echo          set ADB_SERIAL=XXXX
    echo          disp_continuous_monitor.bat
    type devices.txt
    popd
    pause
    exit /b 3
)
if not "!ADB_SERIAL!"=="" (
    echo       Using serial: !ADB_SERIAL!
)
echo [ OK ] 设备已连接
:: 先删旧文件, 避免 adb 失败时留下上一轮的设备信息
if exist model.tmp del /f /q model.tmp >nul 2>&1
if exist build.tmp del /f /q build.tmp >nul 2>&1
!ADB! shell getprop ro.product.model  > model.tmp   2>&1
!ADB! shell getprop ro.build.display.id > build.tmp 2>&1

echo [2/!TOT!] 申请 root ...
:: adb root 的退出码不可依赖: 已经是 root 的设备上,
:: 不同 adb 版本有的返回 0、有的返回 1, 只能看输出文本
:: 不看 adb root 的退出码, 也不靠它的输出文本: 
:: 直接问设备——能跑 id 就说明已 root
!ADB! root > root.txt 2>&1
call :sleep 1
set "ROOTED=0"
:: 先删旧文件: adb 失败时不会覆盖, 会留上一轮的内容导致误判
if exist id.txt del /f /q id.txt >nul 2>&1
!ADB! shell id > id.txt 2>nul
findstr /b /c:"uid=0(" id.txt >nul 2>&1 && set "ROOTED=1"
if "!ROOTED!"=="0" (
    :: 再等一段重试: adb root 会重启 adbd, 重启期间请求可能失败
    call :sleep 3
    if exist id.txt del /f /q id.txt >nul 2>&1
    !ADB! shell id > id.txt 2>nul
    findstr /b /c:"uid=0(" id.txt >nul 2>&1 && set "ROOTED=1"
)
if "!ROOTED!"=="0" (
    echo [WARN] 设备不是 root, dmesg / 部分 dumpsys 可能是空的 (原因见 root.txt)
    set /a WARNCNT+=1
    >>"%FAILS%" echo [WARN] device is not rooted - see root.txt
) else (
    echo [ OK ] 设备已以 root 运行
)
call :wait_device 60
if errorlevel 1 (
    echo [FAIL] adb root 之后设备掉线, 无法继续。
    popd
    pause
    exit /b 2
)

:: ========== 3. 复现前基线快照 (必须在清缓冲之前) ==========
echo.
echo [3/!TOT!] 抓取复现前基线 ...
call :snapshot before
call :grab "cmdline.txt" "!ADB! shell cat /proc/cmdline"

:: ========== 4. logcat 缓冲准备 ==========
echo [4/!TOT!] 准备 logcat 缓冲 ...
if "%CLEAR_LOGCAT%"=="1" (
    echo [ .. ] 清空设备端 logcat 缓冲 ^(前基线已保存^) ...
    !ADB! logcat -c -b all >nul 2>&1
)
!ADB! logcat -G %LOGCAT_BUF% -b all > logcat_G.txt 2>&1
if errorlevel 1 (
    echo [WARN] logcat -G %LOGCAT_BUF% 失败, 按设备默认缓冲抓取 ^(见 logcat_G.txt^)
    set /a WARNCNT+=1
    >>"%FAILS%" echo [WARN] logcat -G %LOGCAT_BUF% failed - see logcat_G.txt
)

:: ========== 5. 并行实时抓取 ==========
echo [5/!TOT!] 启动并行采集窗口 ...
mkdir "%TMPD%" 2>nul

:: 实时日志不要 kernel 缓冲: kernel 已由 dmesg.log 单独覆盖,
:: 否则两路内容重复, 白占磁盘也双倍报错
:: 设备端 timeout 兜底: 即使本机收屹失败(主窗口被直接关掉),
:: 设备端也会自己退出, 不会无限写磁盘
:: 两条采集命令形式不同, 不能共用一个前缀:
::   logcat -> adb logcat ...        (不需 shell)
::   dmesg  -> adb shell dmesg ...   (必须经过 shell, 否则 adb 报 unknown command)
if "%HARD_LIMIT_SEC%"=="0" (
    set "CMD_LOGCAT=!ADB! logcat -b main,system,crash,events -v threadtime"
    set "CMD_DMESG=!ADB! shell dmesg -w"
) else (
    set "CMD_LOGCAT=!ADB! logcat -b main,system,crash,events -v threadtime"
    set "CMD_DMESG=!ADB! shell timeout %HARD_LIMIT_SEC% dmesg -w"
)
call :make_col "DCMON_LOGCAT" "logcat.txt"   "!CMD_LOGCAT!"
call :make_col "DCMON_DMESG"  "dmesg.log"    "!CMD_DMESG!"
:: 需要触摸事件时间线时取消下面两行注释
:: call :make_col "DCMON_GETEV" "getevent.log" "adb shell getevent -tlr"
:: start "DCMON_GETEV" cmd /c ""%TMPD%\DCMON_GETEV.bat""

:: 子窗口继承本窗口当前目录(= 输出目录), 所以临时脚本里只用相对文件名
:: 用 Start-Process -PassThru 启动并直接取回 PID: 停止时按 PID 精确杀,
:: 不用窗口标题匹配(弱标识, 会误杀别人的窗口)
set "PID_LOGCAT="
set "PID_DMESG="
for /f "usebackq delims=" %%p in (`powershell -NoProfile -Command "(Start-Process -FilePath cmd.exe -ArgumentList '/c','%TMPD%\DCMON_LOGCAT.bat' -PassThru).Id"`) do set "PID_LOGCAT=%%p"
for /f "usebackq delims=" %%p in (`powershell -NoProfile -Command "(Start-Process -FilePath cmd.exe -ArgumentList '/c','%TMPD%\DCMON_DMESG.bat' -PassThru).Id"`) do set "PID_DMESG=%%p"
if defined PID_LOGCAT echo       LOGCAT window pid=!PID_LOGCAT!
if defined PID_DMESG  echo       DMESG  window pid=!PID_DMESG!

:: ========== 6. 等待停止 ==========
echo.
echo ================================================================
echo  请开始复现问题。
echo.
echo  停止: 在本窗口按 [S] 立即停止
echo        或到 %MAX_MIN% 分钟 / %MAX_MB% MB 自动停止
echo  停止后本脚本会自动关闭采集窗口并补终点快照, 不需要手动关窗
echo ================================================================
echo.

call :now_sec
set /a T0=!_NOW!
set /a LASTREP=-1
set /a LIMIT_SEC=0
if not "%MAX_MIN%"=="0" set /a LIMIT_SEC=MAX_MIN*60

:WAIT_LOOP
call :now_sec
set /a ITER0=!_NOW!

choice /c SQ /n /t %POLL_SEC% /d Q >nul 2>&1
set "KEYRC=!errorlevel!"
if "!KEYRC!"=="1" (
    set "STOPWHY=operator"
    goto WAIT_DONE
)
if "!KEYRC!"=="255" if not defined NOKEY_WARNED (
    set "NOKEY_WARNED=1"
    echo [WARN] 当前窗口不支持交互按键, 改为仅按上限自动停止
)

:: 无控制台时 choice 会立即返回: 用真实耗时补足间隔, 避免空转烧 CPU
call :now_sec
set /a ITER_USED=!_NOW!-ITER0
if !ITER_USED! LSS 0 set /a ITER_USED+=86400
if !ITER_USED! LSS %POLL_SEC% (
    set /a NEED=%POLL_SEC%-ITER_USED
    call :sleep !NEED!
)

:: 用墙钟计算真实已抓时长
call :now_sec
set /a ELAPSED=!_NOW!-T0
if !ELAPSED! LSS 0 set /a ELAPSED+=86400
set /a MIN=ELAPSED/60

:: -- 体积上限 --
set /a TOTMB=0
for %%F in (logcat.txt dmesg.log getevent.log) do if exist "%%F" set /a TOTMB+=%%~zF/1048576
if not "%MAX_MB%"=="0" if !TOTMB! GEQ %MAX_MB% (
    set "STOPWHY=size"
    goto WAIT_DONE
)

:: -- 时长上限 --
if !LIMIT_SEC! GTR 0 if !ELAPSED! GEQ !LIMIT_SEC! (
    set "STOPWHY=timeout"
    goto WAIT_DONE
)

:: -- 每 60 秒报一次进度 --
if !MIN! GTR !LASTREP! (
    set /a LASTREP=MIN
    set "SZ_L=0"
    set "SZ_D=0"
    for %%F in (logcat.txt) do if exist "%%F" set /a SZ_L=%%~zF/1048576
    for %%F in (dmesg.log)  do if exist "%%F" set /a SZ_D=%%~zF/1048576
    echo   [..] 已抓取 !MIN! 分钟   logcat=!SZ_L!MB  dmesg=!SZ_D!MB  合计=!TOTMB!MB   ^(按 S 停止^)
)
goto WAIT_LOOP

:: ========== 7. 停止采集 ==========
:WAIT_DONE
echo.
if "%STOPWHY%"=="size"     echo [STOP] 达到体积上限 %MAX_MB% MB, 自动停止
if "%STOPWHY%"=="timeout"  echo [STOP] 达到时长上限 %MAX_MIN% 分钟, 自动停止
if "%STOPWHY%"=="operator" echo [STOP] 收到停止指令, 停止采集

echo [6/!TOT!] 关闭采集窗口 ...
:: /T 连子进程一起杀: cmd.exe 被杀时它派生的 adb.exe 也会退出
:: 按 PID 精确回收: 只杀本次启动时记下来的那两个进程,
:: 不会碰到你自己开着的其他窗口
if defined PID_LOGCAT taskkill /PID !PID_LOGCAT! /T /F >nul 2>&1
if defined PID_DMESG  taskkill /PID !PID_DMESG!  /T /F >nul 2>&1
if not defined PID_LOGCAT echo       [WARN] 未取到 LOGCAT 窗口 PID, 请手动关闭该窗口
if not defined PID_DMESG  echo       [WARN] 未取到 DMESG 窗口 PID, 请手动关闭该窗口
:: 双保险: 设备侧进程 (本机杀了但设备端还在灌会写坏文件)
:: 匹配串必须与上面采集命令的实际参数一致, 否则永远杀不掉
!ADB! shell "pkill -f 'logcat -b main,system,crash,events'" >nul 2>&1
!ADB! shell "pkill -f 'dmesg -w'"      >nul 2>&1
call :sleep 2

:: 收尸确认: 静置 2 秒后若实时日志还在长, 说明采集进程没被真正杀掉
set /a _S1=0
set /a _S2=0
for %%F in (logcat.txt) do if exist "%%F" set /a _S1+=%%~zF
for %%F in (dmesg.log)  do if exist "%%F" set /a _S1+=%%~zF
call :sleep 2
for %%F in (logcat.txt) do if exist "%%F" set /a _S2+=%%~zF
for %%F in (dmesg.log)  do if exist "%%F" set /a _S2+=%%~zF
if !_S2! GTR !_S1! (
    echo [WARN] 停止后日志仍在增长 ^(!_S1! -^> !_S2! 字节^), 采集进程可能残留
    set /a WARNCNT+=1
    >>"%FAILS%" echo [WARN] capture still growing after stop ^(!_S1! -^> !_S2!^)
)

:: ========== 8. 复现后终点快照 ==========
echo.
echo [7/!TOT!] 抓取复现后快照 ...
call :snapshot after

:: ========== 9. 截图 ==========
echo [8/!TOT!] 抓取屏幕截图 ...
!ADB! shell screencap -p /sdcard/screenshot.png >nul 2>&1
!ADB! pull /sdcard/screenshot.png ./screenshot.png >pull.txt 2>&1
!ADB! shell "rm -f /sdcard/screenshot.png" >NUL 2>&1
if exist "screenshot.png" (
    for %%F in (screenshot.png) do set "SZP=%%~zF"
    echo [ OK ] screenshot.png  ^(!SZP! 字节^)
) else (
    echo [WARN] 截图拉取失败, 设备可能深睡或 SF 已死 ^(see pull.txt^)
    set /a WARNCNT+=1
    >>"%FAILS%" echo [WARN] screenshot pull failed - see pull.txt
)

:: ========== 10. bugreport ==========
if "%SKIP_BUGREPORT%"=="1" (
    echo [..] 跳过 bugreport ^(由 SKIP_BUGREPORT=1 指定^)
) else (
    echo [!TOT!/!TOT!] 生成 bugreport ^(1-3 分钟, 请勿关闭窗口^) ...
    !ADB! bugreport "%OUT%\bugreport.zip" >bugreport_log.txt 2>&1
    if errorlevel 1 (
        echo [FAIL] bugreport 失败 ^(见 bugreport_log.txt^)
        set /a FAILCNT+=1
        >>"%FAILS%" echo bugreport: adb bugreport failed
    ) else (
        if exist "bugreport.zip" (
            for %%F in (bugreport.zip) do set "SZB=%%~zF"
            if !SZB! LSS 1000000 (
                echo [WARN] bugreport.zip 只有 !SZB! 字节, 疑似截断
                set /a WARNCNT+=1
                >>"%FAILS%" echo [WARN] bugreport.zip suspiciously small ^(!SZB! bytes^)
            ) else (
                echo [ OK ] bugreport.zip  ^(!SZB! 字节^)
            )
        )
    )
)

:: ========== 11. 会话汇总 ==========
echo.
echo 生成会话汇总 ...
(
    echo ================================================================
    echo  Display Replay Monitor - session summary
    echo ================================================================
    echo  时间戳    : !STAMP!
    echo  输出目录  : %OUT%
    echo  停止原因  : !STOPWHY!
    echo  抓取时长  : 约 !MIN! 分钟
    echo  参数      : MAX_MIN=%MAX_MIN% MAX_MB=%MAX_MB% POLL=%POLL_SEC%s BUF=%LOGCAT_BUF% CLEAR=%CLEAR_LOGCAT%
    echo  失败项    : !FAILCNT!
    echo  警告项    : !WARNCNT!
    echo ================================================================
    echo -- 设备 --
    type devices.txt 2>nul
    echo Model:
    type model.tmp 2>nul
    echo Build:
    type build.tmp 2>nul
    echo.
    echo -- 失败明细 --
    type "%FAILS%" 2>nul
    echo.
    echo -- 产物清单 --
    dir /b /a-d /o-n
) > session_summary.txt

echo.
echo ==========================================
if !FAILCNT! GTR 0 (
    echo  [WARN] 有 !FAILCNT! 项失败, 详见 session_summary.txt
) else (
    echo  [ OK ] 快照与实时日志均已生成
)
echo  Done! 日志目录:
echo    %OUT%
echo ==========================================

popd
if exist "%TMPD%" rd /s /q "%TMPD%" >nul 2>&1

:: 保留最近 KEEP_RUNS 个 LOGS_* 目录, 更早的删除
if not "%KEEP_RUNS%"=="0" call :prune_runs

:: 被其他脚本 call 时用 DCMON_NO_EXIT=1 跳过结尾等待
if defined DCMON_NO_EXIT exit /b 0
pause
exit


:: ================================================================
::  子程序
:: ================================================================

:wait_device
:: %1 = 超时秒数; 返回 0 = 设备就绪, 1 = 超时
set /a _wd=0
:wd_loop
!ADB! get-state >nul 2>&1
if not errorlevel 1 exit /b 0
set /a _wd+=2
if !_wd! GEQ %~1 exit /b 1
call :sleep 2
goto wd_loop

:now_sec
:: 把 %time% (HH:MM:SS.cc) 转成"当天秒数", 供墙钟计时使用
set "_t=%time%"
if "!_t:~0,1!"==" " set "_t=0!_t:~1!"
set /a _NOW=1!_t:~0,2!-100
set /a _NOW=_NOW*60+1!_t:~3,2!-100
set /a _NOW=_NOW*60+1!_t:~6,2!-100
exit /b 0

:sleep
:: %1 = 秒数; 用 ping 做延时, 不受 GNU timeout 等 PATH 干扰
:: ping -n N 的实际间隔约为 N-1 秒, 故传 N+1
if "%~1"=="" exit /b 0
set /a _slp=%~1+1
ping -n !_slp! 127.0.0.1 >nul 2>&1
exit /b 0

:grab
:: %1 = 输出文件名   %2 = 命令(不含重定向, 不要含 & | 等)
if exist "%~1" del /f /q "%~1" >nul 2>&1
%~2 > "%~1" 2>&1
if errorlevel 1 (
    set /a FAILCNT+=1
    echo   [FAIL] %~1
    >>"%FAILS%" echo %~1 ^<- %~2
) else (
    for %%F in ("%~1") do set "GBZ=%%~zF"
    if !GBZ! LSS 32 (
        set /a WARNCNT+=1
        echo   [WARN] %~1 只有 !GBZ! 字节, 可能设备不支持或权限不足
        >>"%FAILS%" echo [WARN] %~1 only !GBZ! bytes ^<- %~2
    ) else (
        echo   [ OK ] %~1  ^(!GBZ! 字节^)
    )
)
exit /b 0

:snapshot
:: %1 = before / after
set "TAG=%~1"
call :grab "logcat_all_!TAG!.txt"        "!ADB! logcat -d -v threadtime -b all"
call :grab "dmesg_!TAG!.txt"             "!ADB! shell dmesg"
call :grab "dumpsys_display_!TAG!.txt"   "!ADB! shell dumpsys display"
call :grab "dumpsys_sf_!TAG!.txt"        "!ADB! shell dumpsys SurfaceFlinger"
call :grab "dumpsys_input_!TAG!.txt"     "!ADB! shell dumpsys input"
call :grab "dumpsys_power_!TAG!.txt"     "!ADB! shell dumpsys power"
call :grab "dumpsys_gpu_!TAG!.txt"       "!ADB! shell dumpsys gpu"
call :grab "dumpsys_meminfo_!TAG!.txt"   "!ADB! shell dumpsys meminfo"
call :grab "dumpsys_window_!TAG!.txt"    "!ADB! shell dumpsys window"
call :grab "getprop_!TAG!.txt"           "!ADB! shell getprop"
exit /b 0

:make_col
:: %1 = 窗口标题   %2 = 输出文件名(相对当前目录)   %3 = 采集命令
:: 临时脚本只含 ASCII, 避开中文路径与代码页问题
(
    echo @echo off
    echo title %~1
    echo %~3 ^> %~2 2^>^&1
) > "%TMPD%\%~1.bat"
exit /b 0
:prune_runs
:: 只保留最近 KEEP_RUNS 个 LOGS_* 目录
:: 目录名带时间戳, 按名字降序 = 从新到旧
set /a _keep=%KEEP_RUNS%
set /a _idx=0
set /a _del=0
for /f "delims=" %%D in ('dir /b /ad /o-n "%~dp0LOGS_*" 2^>nul') do (
    set /a _idx+=1
    if !_idx! GTR !_keep! (
        rd /s /q "%~dp0%%D" >nul 2>&1
        set /a _del+=1
    )
)
if !_del! GTR 0 echo [ .. ] 已清理 !_del! 个旧 LOGS 目录
exit /b 0
