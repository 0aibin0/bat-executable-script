@echo off
setlocal enabledelayedexpansion

:: ============================================================
:: PM GPIO 控制脚本 (GPIO1 - GPIO18) - by nike
::
:: 基地址规律: base(N) = 0xE800 + (N-1)*0x100
::   已用原表验证: 01=E800 03=EA00 04=EB00 05=EC00
::                 08=EF00 11=F200 16=F700 18=F900
::
:: 寄存器 (相对每颗 GPIO 基址 0x100, 与内核 pinctrl-spmi-gpio.c 一致):
::   04  TYPE        只读, 固定 0x10
::   05  SUBTYPE     只读, 0x10~0x15 属于 LV/MV 类型
::   10  RT_STS      只读, bit0 = 引脚实时电平
::   40  MODE_CTL    方向控制
::                   LV/MV:     整个寄存器 0=IN 1=OUT 2=IN+OUT 3=ANALOG
::                   非 LV/MV:  bit6:4 = 方向 (同上取值)
::   41  DIG_VIN_CTL 输入电源域, 0x1 = 1.8V (GPIO08/16 跳过, 与原脚本一致)
::   42  DIG_PULL_CTL 上下拉
::   43  DIG_IN_CTL  输入缓冲
::   44  OUT_SRC_CTL LV/MV 输出电平, bit7=1 高 / 0 低
::   45  DIG_OUT_CTL bit1:0 驱动能力 0=none 1=low 2=medium 3=high
::                   bit5:4 输出类型 0=CMOS推挽 1=开漏NMOS 2=开漏PMOS
::                   改驱动能力时按位保留 bit5:4, 不破坏输出类型
::   46  EN_CTL      bit7 = 主使能
:: 访问方式: adb 写 /d/regmap/1-00 的 address 和 data

:: 接口自动探测:
::   存在 address/data 文件 - 寄存器模式, 全部功能可用
::   不存在                - gpiochip 模式, 方向和电平可用,
::                          驱动能力不可用, 退出码 3
::   若该 PMIC 外设的写权限不归当前 EE, 内核会打印
::        disallowed SPMI write to sid=... addr=...
::   此时该 GPIO 无法从系统内修改, 脚本会在对应步骤报错
::
:: 用法:
::   交互菜单: PM_GPIO_CTRL-new.bat
::   命令行  :
::     PM_GPIO_CTRL-new.bat 1-18 high       输出高电平 0x80
::     PM_GPIO_CTRL-new.bat 1-18 low        输出低电平 0x00
::     PM_GPIO_CTRL-new.bat 1-18 in         方向输入
::     PM_GPIO_CTRL-new.bat 1-18 out        方向输出
::     PM_GPIO_CTRL-new.bat 1-18 drive N    驱动能力 0..3
::     PM_GPIO_CTRL-new.bat 1-18 read       读取状态
::   例: PM_GPIO_CTRL-new.bat 5 drive high
:: ============================================================

set "REGMAP=/d/regmap/1-00"
set "HEXD=0123456789ABCDEF"
set "OFF_TYPE=04"
set "OFF_SUB=05"
set "OFF_RT=10"
set "OFF_MODE=40"
set "OFF_DIG_VIN=41"
set "OFF_OUT=44"
set "OFF_DIG_OUT=45"
set "OFF_EN=46"

:: 有命令行参数则走非交互模式
if not "%~1"=="" goto cli_args

:: ---------------- GPIO 选择菜单 ----------------
:select_gpio
cls
echo ================ PM GPIO Control - by nike ================
echo  Select GPIO to operate          [0 / Q] Exit
echo ----------------------------------------------------------
for /l %%i in (1,1,9) do (
    set /a "jn=%%i+9"
    set "pl=0%%i"
    echo    %%i. PM_GPIO_!pl:~-2!          !jn!. PM_GPIO_!jn!
)
echo ===========================================================
echo.

set "choice="
set /p "choice=Please enter GPIO number [1-18]: "

if not defined choice goto invalid_gpio
if /i "!choice!"=="q" goto exit_program
if "!choice!"=="0" goto exit_program

:: 兼容 01~09 这种带前导零的写法
if "!choice:~0,1!"=="0" if not "!choice:~1!"=="" set "choice=!choice:~1!"

:: 数字校验: 非数字会得到 0, 下面的范围检查会拦住
set /a "n=0"
set /a "n+=choice" 2>nul
if !n! lss 1 goto invalid_gpio
if !n! gtr 18 goto invalid_gpio
goto compute_addr

:invalid_gpio
echo Invalid input, please enter a number 1-18...
pause >nul
goto select_gpio

:: ---------------- 命令行参数解析 ----------------
:cli_args
set "cli=1"
set /a "n=0"
set /a "n+=%~1" 2>nul
if !n! lss 1 goto cli_usage
if !n! gtr 18 goto cli_usage

:: 输出电平
if /i "%~2"=="high" (set "cli_act=level" & set "out_val=0x80" & set "level=HIGH" & goto compute_addr)
if /i "%~2"=="h"    (set "cli_act=level" & set "out_val=0x80" & set "level=HIGH" & goto compute_addr)
if /i "%~2"=="1"    (set "cli_act=level" & set "out_val=0x80" & set "level=HIGH" & goto compute_addr)
if /i "%~2"=="on"   (set "cli_act=level" & set "out_val=0x80" & set "level=HIGH" & goto compute_addr)
if /i "%~2"=="low"  (set "cli_act=level" & set "out_val=0x00" & set "level=LOW"  & goto compute_addr)
if /i "%~2"=="l"    (set "cli_act=level" & set "out_val=0x00" & set "level=LOW"  & goto compute_addr)
if /i "%~2"=="0"    (set "cli_act=level" & set "out_val=0x00" & set "level=LOW"  & goto compute_addr)
if /i "%~2"=="off"  (set "cli_act=level" & set "out_val=0x00" & set "level=LOW"  & goto compute_addr)

:: 方向
if /i "%~2"=="in"     (set "cli_act=dir" & set "dirval=0" & set "dir_txt=INPUT"  & goto compute_addr)
if /i "%~2"=="input"  (set "cli_act=dir" & set "dirval=0" & set "dir_txt=INPUT"  & goto compute_addr)
if /i "%~2"=="out"    (set "cli_act=dir" & set "dirval=1" & set "dir_txt=OUTPUT" & goto compute_addr)
if /i "%~2"=="output" (set "cli_act=dir" & set "dirval=1" & set "dir_txt=OUTPUT" & goto compute_addr)

:: 状态读取
if /i "%~2"=="read"   (set "cli_act=read" & goto compute_addr)
if /i "%~2"=="status" (set "cli_act=read" & goto compute_addr)

:: 驱动能力
if /i "%~2"=="drive" goto cli_drive
goto cli_usage

:cli_drive
set "drv="
if /i "%~3"=="none"   set "drv=0"
if /i "%~3"=="no"     set "drv=0"
if /i "%~3"=="low"    set "drv=1"
if /i "%~3"=="med"    set "drv=2"
if /i "%~3"=="medium" set "drv=2"
if /i "%~3"=="high"   set "drv=3"
if "%~3"=="0" set "drv=0"
if "%~3"=="1" set "drv=1"
if "%~3"=="2" set "drv=2"
if "%~3"=="3" set "drv=3"
if not defined drv goto cli_usage
set "drv_txt=none"
if "!drv!"=="1" set "drv_txt=low"
if "!drv!"=="2" set "drv_txt=medium"
if "!drv!"=="3" set "drv_txt=high"
set "cli_act=drive"
goto compute_addr

:cli_usage
echo Usage:
echo   %~nx0                       interactive menu
echo   %~nx0 1-18 high             set output HIGH 0x80
echo   %~nx0 1-18 low              set output LOW  0x00
echo   %~nx0 1-18 in               direction INPUT
echo   %~nx0 1-18 out              direction OUTPUT
echo   %~nx0 1-18 drive 0-3        drive strength none/low/medium/high
echo   %~nx0 1-18 read             read status

echo   exit code: 0 ok, 1 failed, 2 bad usage, 3 unsupported here
exit /b 2

:: ---------------- 计算基地址与寄存器地址 ----------------
:compute_addr
:: 高字节 = 0xE8 + (N-1), 低字节固定 00/40/41/44
set /a "hb=0xE8 + n - 1"
set /a "t1=hb/16"
set /a "t2=hb - t1*16"
set "BH=!HEXD:~%t1%,1!!HEXD:~%t2%,1!"

set "A_BASE=0x0000!BH!00"
set "A_MODE=0x!BH!!OFF_MODE!"
set "A_DIG=0x!BH!!OFF_DIG_VIN!"
set "A_OUT=0x!BH!!OFF_OUT!"

set "pad=0!n!"
set "GPIO_NAME=PM_GPIO_!pad:~-2!"

if defined cli goto cli_dispatch
goto action_menu

:: ---------------- 命令行分发 ----------------
:cli_dispatch
if "!cli_act!"=="level" goto apply_level
if "!cli_act!"=="dir"   goto set_dir
if "!cli_act!"=="drive" goto set_drive
if "!cli_act!"=="read"  goto read_status
goto cli_usage

:: ---------------- 动作菜单 ----------------
:action_menu
cls
echo ========================================
echo  Current GPIO : !GPIO_NAME!
echo  Base Address  : !A_BASE!
echo  MODE_CTL      : !A_MODE!
echo  DIG_VIN_CTL   : !A_DIG!
echo  OUT_SRC_CTL   : !A_OUT!
echo  DIG_OUT_CTL   : 0x!BH!!OFF_DIG_OUT!
echo  EN_CTL        : 0x!BH!!OFF_EN!
echo ========================================
echo  Select action:
echo    [Y] ON   - Output HIGH 0x80
echo    [N] OFF  - Output LOW  0x00
echo    [I] Direction = INPUT
echo    [O] Direction = OUTPUT
echo    [S] Drive strength
echo    [R] Read status
echo    [B] Back to GPIO selection
echo    [Q] Exit
echo ========================================
echo.

set "action="
set /p "action=Please choose [Y/N/I/O/S/R/B/Q]: "

if /i "!action!"=="Y" (set "out_val=0x80" & set "level=HIGH" & goto apply_level)
if /i "!action!"=="N" (set "out_val=0x00" & set "level=LOW"  & goto apply_level)
if /i "!action!"=="I" (set "dirval=0" & set "dir_txt=INPUT"  & goto set_dir)
if /i "!action!"=="O" (set "dirval=1" & set "dir_txt=OUTPUT" & goto set_dir)
if /i "!action!"=="S" goto drive_menu
if /i "!action!"=="R" goto read_status
if /i "!action!"=="B" goto select_gpio
if /i "!action!"=="Q" goto exit_program

echo Invalid choice, please try again...
pause >nul
goto action_menu

:: ---------------- 驱动能力选择 ----------------
:drive_menu
cls
echo ========================================
echo  Drive strength for !GPIO_NAME!
echo  Register : DIG_OUT_CTL 0x!BH!!OFF_DIG_OUT!
echo  bit1:0 = strength, bit5:4 = buffer type
echo ----------------------------------------
echo    [0] none     [1] low
echo    [2] medium   [3] high
echo    [B] Back to action menu
echo    [Q] Exit
echo ========================================
echo.

set "dsel="
set /p "dsel=Please choose [0-3/B/Q]: "
if /i "!dsel!"=="q" goto exit_program
if /i "!dsel!"=="b" goto action_menu
if "!dsel!"=="0" (set "drv=0" & set "drv_txt=none"   & goto set_drive)
if "!dsel!"=="1" (set "drv=1" & set "drv_txt=low"    & goto set_drive)
if "!dsel!"=="2" (set "drv=2" & set "drv_txt=medium" & goto set_drive)
if "!dsel!"=="3" (set "drv=3" & set "drv_txt=high"   & goto set_drive)

echo Invalid choice, please try again...
pause >nul
goto drive_menu

:: ---------------- 输出高/低电平 (沿用原脚本流程) ----------------
:apply_level
if not defined cli cls
echo [Executing] Set !GPIO_NAME! = !level!  !out_val!
echo.

set "step=ADB device check"
call adb get-state >nul 2>&1
if errorlevel 1 goto step_error
call :detect_iface
if errorlevel 1 goto step_error
if "!iface!"=="GPIOID" goto apply_level_gpiod

set "step=MODE_CTL"
echo [1/3] Setting MODE_CTL to 0x1 - digital output mode...
call adb shell "echo !A_MODE! > !REGMAP!/address"
if errorlevel 1 goto step_error
call adb shell "echo 0x1 > !REGMAP!/data"
if errorlevel 1 goto step_error
echo       OK

set "step=DIG_VIN_CTL"
if !n! equ 8  goto skip_dig
if !n! equ 16 goto skip_dig
echo [2/3] Setting DIG_VIN_CTL to 0x1 - 1.8V...
call adb shell "echo !A_DIG! > !REGMAP!/address"
if errorlevel 1 goto step_error
call adb shell "echo 0x1 > !REGMAP!/data"
if errorlevel 1 goto step_error
echo       OK
goto step3

:skip_dig
echo [2/3] Skipping DIG_VIN_CTL for !GPIO_NAME! - same as original script

:step3
set "step=OUT_SRC_CTL"
echo [3/3] Setting OUT_SRC_CTL to !out_val! - !level!...
call adb shell "echo !A_OUT! > !REGMAP!/address"
if errorlevel 1 goto step_error
call adb shell "echo !out_val! > !REGMAP!/data"
if errorlevel 1 goto step_error
echo       OK

:: 回读校验: address 仍指向 OUT_SRC_CTL, 直接读 data
set "step=Read back"
echo [check] Reading back OUT_SRC_CTL...
set "readback="
for /f "delims=" %%v in ('call adb exec-out "cat !REGMAP!/data" 2^>nul') do set "readback=%%v"
if defined readback (
    echo       OUT_SRC_CTL = !readback!
) else (
    echo       read-back not available, skip
)

echo ========================================
echo  !GPIO_NAME! applied OK: !level! = !out_val!
echo ========================================
echo.
if defined cli exit /b 0
pause
goto action_menu

:: ---------------- 方向控制 (输入 / 输出) ----------------
:set_dir
if not defined cli cls
echo [Executing] Set !GPIO_NAME! direction = !dir_txt!
echo.
call :dev_check
if errorlevel 1 goto step_error
call :detect_iface
if errorlevel 1 goto step_error
if "!iface!"=="GPIOID" goto set_dir_gpiod

:: 先读 SUBTYPE 判断方向位域
set "step=Read SUBTYPE"
call :reg_fmt_detect
call :reg_read !OFF_SUB!
if errorlevel 1 goto step_error
set "sub_num=!read_num!"
set "dir_mask=0x03"
set "dir_sh=0"
if !sub_num! lss 16 set "dir_mask=0x70"
if !sub_num! lss 16 set "dir_sh=4"
echo [detect] SUBTYPE = !read_raw!  mask=!dir_mask! shift=!dir_sh!
echo.

:: 步骤1: MODE_CTL 方向 (读改写, 保留其它位)
set "step=MODE_CTL"
call :reg_read !OFF_MODE!
if errorlevel 1 goto step_error
set "m_old=!read_raw!"
set "mode_new="
set /a "mode_new=(read_num & ~dir_mask) | (dirval << dir_sh)"
if not defined mode_new goto step_error
call :dec2hex !mode_new!
echo [1/3] MODE_CTL: !m_old! to !hexout!  dir=!dir_txt!
call :reg_write !OFF_MODE! !hexout!
if errorlevel 1 goto step_error
echo       OK
echo.

:: 步骤2: DIG_VIN_CTL (GPIO08/16 跳过, 与原脚本一致)
set "step=DIG_VIN_CTL"
if !n! equ 8  goto skip_vin
if !n! equ 16 goto skip_vin
echo [2/3] Setting DIG_VIN_CTL to 0x1 - 1.8V...
call :reg_write !OFF_DIG_VIN! 0x1
if errorlevel 1 goto step_error
echo       OK
echo.
goto vin_done

:skip_vin
echo [2/3] Skipping DIG_VIN_CTL for !GPIO_NAME! - same as original script

:vin_done
:: 步骤3: EN_CTL 主使能 (读改写, 只置 bit7)
set "step=EN_CTL"
call :reg_read !OFF_EN!
if errorlevel 1 goto step_error
set "e_old=!read_raw!"
set "en_new="
set /a "en_new=read_num | 0x80"
if not defined en_new goto step_error
call :dec2hex !en_new!
echo [3/3] EN_CTL: !e_old! to !hexout!  master enable ON
call :reg_write !OFF_EN! !hexout!
if errorlevel 1 goto step_error
echo       OK
echo.

echo ========================================
echo  !GPIO_NAME! direction = !dir_txt!  OK
echo ========================================
echo.
if defined cli exit /b 0
pause
goto action_menu

:: ---------------- 驱动能力 ----------------
:set_drive
if not defined cli cls
echo [Executing] Set !GPIO_NAME! drive strength = !drv_txt!  value=!drv!
echo.
call :dev_check
if errorlevel 1 goto step_error
call :detect_iface
if errorlevel 1 goto step_error
if "!iface!"=="GPIOID" goto set_drive_unsupported

:: 读改写 DIG_OUT_CTL, 保留 bit5:4 输出类型
set "step=DIG_OUT_CTL"
call :reg_fmt_detect
call :reg_read !OFF_DIG_OUT!
if errorlevel 1 goto step_error
set "d_old=!read_raw!"
set "drv_new="
set /a "drv_new=(read_num & ~0x3) | drv"
if not defined drv_new goto step_error
call :dec2hex !drv_new!
echo [1/1] DIG_OUT_CTL: !d_old! to !hexout!  strength=!drv_txt!
call :reg_write !OFF_DIG_OUT! !hexout!
if errorlevel 1 goto step_error
echo       OK
echo.

echo ========================================
echo  !GPIO_NAME! drive strength = !drv_txt!  OK
echo ========================================
echo.
if defined cli exit /b 0
pause
goto action_menu

:: ---------------- 读取状态 ----------------
:read_status
if not defined cli cls
echo [Reading] !GPIO_NAME! registers...
echo.
call :dev_check
if errorlevel 1 goto step_error
call :detect_iface
if errorlevel 1 goto step_error
if "!iface!"=="GPIOID" goto read_status_gpiod
call :reg_fmt_detect

set "step=Read TYPE"
call :reg_read !OFF_TYPE!
if errorlevel 1 goto step_error
set "r_type=!read_raw!"

set "step=Read SUBTYPE"
call :reg_read !OFF_SUB!
if errorlevel 1 goto step_error
set "r_sub=!read_raw!"
set "sub_num=!read_num!"

set "step=Read MODE_CTL"
call :reg_read !OFF_MODE!
if errorlevel 1 goto step_error
set "r_mode=!read_raw!"
set "n_mode=!read_num!"

set "step=Read DIG_VIN_CTL"
call :reg_read !OFF_DIG_VIN!
if errorlevel 1 goto step_error
set "r_vin=!read_raw!"
set "n_vin=!read_num!"

set "step=Read DIG_OUT_CTL"
call :reg_read !OFF_DIG_OUT!
if errorlevel 1 goto step_error
set "r_dout=!read_raw!"
set "n_dout=!read_num!"

set "step=Read EN_CTL"
call :reg_read !OFF_EN!
if errorlevel 1 goto step_error
set "r_en=!read_raw!"
set "n_en=!read_num!"

set "step=Read RT_STS"
call :reg_read !OFF_RT!
if errorlevel 1 goto step_error
set "r_rt=!read_raw!"
set "n_rt=!read_num!"

:: 解码
set /a "d=n_mode & 0x3"
if !sub_num! lss 16 set /a "d=(n_mode >> 4) & 0x7"
set "dir_txt=UNKNOWN"
if !d! equ 0 set "dir_txt=INPUT"
if !d! equ 1 set "dir_txt=OUTPUT"
if !d! equ 2 set "dir_txt=INPUT+OUTPUT"
if !d! equ 3 set "dir_txt=ANALOG PASS"

set /a "vin=n_vin & 0x7"

set /a "s=n_dout & 0x3"
set "s_txt=none"
if !s! equ 1 set "s_txt=low"
if !s! equ 2 set "s_txt=medium"
if !s! equ 3 set "s_txt=high"

set /a "bt=(n_dout >> 4) & 0x3"
set "bt_txt=push-pull"
if !bt! equ 1 set "bt_txt=open-drain NMOS"
if !bt! equ 2 set "bt_txt=open-drain PMOS"

set /a "men=(n_en >> 7) & 1"
set "en_txt=OFF"
if !men! equ 1 set "en_txt=ON"

set /a "lvl=n_rt & 0x1"
set "lvl_txt=LOW"
if !lvl! equ 1 set "lvl_txt=HIGH"

echo ========================================
echo  !GPIO_NAME! status
echo  data format    : !regfmt!
echo  TYPE           : !r_type!
echo  SUBTYPE        : !r_sub!
echo  direction      : !dir_txt!   MODE_CTL=!r_mode!
echo  VIN source     : !vin!       DIG_VIN=!r_vin!
echo  drive strength : !s_txt!     DIG_OUT=!r_dout!
echo  buffer type    : !bt_txt!
echo  master enable  : !en_txt!    EN_CTL=!r_en!
echo  pin level      : !lvl_txt!   RT_STS=!r_rt!
echo ========================================
echo.
if defined cli exit /b 0
pause
goto action_menu

:: ---------------- gpiod 回退: 高低电平 ----------------
:apply_level_gpiod
set "step=Find gpiochip with 18 lines"
call :find_chip
if errorlevel 1 goto step_error
set /a "gline_no=n-1"
set "out_bit=0"
if "!out_val!"=="0x80" set "out_bit=1"
echo [gpiod] interface = gpiochip
echo [gpiod] chip = !chip!   line = !gline_no!   =  !GPIO_NAME!
set "step=gpioset !chip! line !gline_no!"
call adb shell "gpioset !chip! !gline_no!=!out_bit!"
if errorlevel 1 goto step_error
echo       OK
echo.
echo ========================================
echo  !GPIO_NAME! = !level!  OK via gpioset
echo  gpiochip has no output readback, use gpioinfo to inspect.
echo ========================================
echo.
if defined cli exit /b 0
pause
goto action_menu

:: ---------------- gpiod 回退: 方向控制 ----------------
:set_dir_gpiod
set "step=Find gpiochip with 18 lines"
call :find_chip
if errorlevel 1 goto step_error
set /a "gline_no=n-1"
echo [gpiod] interface = gpiochip
echo [gpiod] chip = !chip!   line = !gline_no!   =  !GPIO_NAME!
if "!dirval!"=="1" goto set_dir_gpiod_out

set "step=gpioget !chip! line !gline_no! request INPUT (line may be used by kernel)"
set "lvl="
for /f "delims=" %%v in ('call adb shell "gpioget !chip! !gline_no!" 2^>nul') do set "lvl=%%v"
if not defined lvl goto step_error
echo       direction = INPUT   current level = !lvl!
echo.
echo ========================================
echo  !GPIO_NAME! direction = INPUT  OK via gpioget
echo ========================================
echo.
if defined cli exit /b 0
pause
goto action_menu

:set_dir_gpiod_out
set "step=gpioget !chip! line !gline_no! read current level (line may be used by kernel)"
set "lvl="
for /f "delims=" %%v in ('call adb shell "gpioget !chip! !gline_no!" 2^>nul') do set "lvl=%%v"
if not defined lvl goto step_error
set "step=gpioset !chip! line !gline_no! request OUTPUT"
call adb shell "gpioset !chip! !gline_no!=!lvl!"
if errorlevel 1 goto step_error
echo       direction = OUTPUT   level kept = !lvl!
echo.
echo ========================================
echo  !GPIO_NAME! direction = OUTPUT  OK via gpioset
echo ========================================
echo.
if defined cli exit /b 0
pause
goto action_menu

:: ---------------- gpiod 回退: 驱动能力不支持 ----------------
:set_drive_unsupported
echo.
echo ================================================================
echo  Drive strength CANNOT be changed through the gpiochip interface
echo ================================================================
echo  Needed register : DIG_OUT_CTL = 0x!BH!!OFF_DIG_OUT!
echo  Why it fails on this device:
echo    1. !REGMAP! has no address or data files
echo    2. regmap registers file is read only, kernel write is disabled
echo    3. gpiochip and libgpiod expose no drive-strength API
echo  Workarounds:
echo    - use a kernel with writable regmap debugfs, or
echo    - set qcom,drive-strength in the device tree, or
echo    - use a vendor tool that can write PMIC registers
echo ================================================================
echo.
if defined cli exit /b 3
pause
goto action_menu

:: ---------------- gpiod 回退: 读状态 ----------------
:read_status_gpiod
set "step=Find gpiochip with 18 lines"
call :find_chip
if errorlevel 1 goto step_error
set /a "gline_no=n-1"
set "step=gpioinfo !chip! line !gline_no!"
call :gpiod_line_info !gline_no!
if errorlevel 1 goto step_error

set "dir_txt=UNKNOWN"
if not "!gline!"=="!gline: output =!" set "dir_txt=OUTPUT"
if not "!gline!"=="!gline: input =!" set "dir_txt=INPUT"
set "used_txt=free"
if not "!gline!"=="!gline:[used]=!" set "used_txt=used by kernel"

set "lvl_txt=n/a"
if "!dir_txt!"=="INPUT" if "!used_txt!"=="free" (
    set "lvl="
    for /f "delims=" %%v in ('call adb shell "gpioget !chip! !gline_no!" 2^>nul') do set "lvl=%%v"
    if defined lvl set "lvl_txt=!lvl!"
)

echo ========================================
echo  !GPIO_NAME! status   interface = gpiochip
echo  chip / line     : !chip! / !gline_no!
echo  gpioinfo        : !gline!
echo  direction       : !dir_txt!
echo  line state      : !used_txt!
echo  pin level       : !lvl_txt!
echo  drive strength  : n/a   no gpiochip API for it
echo ========================================
echo.
if defined cli exit /b 0
pause
goto action_menu
:: ---------------- 错误处理 ----------------
:step_error
echo.
echo ========================================
echo  FAILED at step: !step!
echo ========================================
echo  Please check:
echo    - Device connection    adb devices
echo    - Debugfs mounted      ls /d/regmap
echo    - Regmap path exists   !REGMAP!
echo ========================================
echo.
if defined cli exit /b 1
pause
goto action_menu

:exit_program
cls
echo Exit program
exit /b 0

:: ============================================================
:: 以下为子程序
:: ============================================================

:: 设备预检查, 成功 exit /b 0, 失败 exit /b 1
:dev_check
set "step=ADB device check"
call adb get-state >nul 2>&1
if errorlevel 1 exit /b 1
exit /b 0

:: 写寄存器: %1=偏移 如 40, %2=值 如 0x1
:reg_write
set "reg_addr=0x!BH!%~1"
call adb shell "echo !reg_addr! > !REGMAP!/address"
if errorlevel 1 exit /b 1
call adb shell "echo %~2 > !REGMAP!/data"
if errorlevel 1 exit /b 1
exit /b 0

:: 读寄存器: %1=偏移 如 40
:: 结果: !read_raw! 原始字符串, !read_num! 数值
:reg_read
set "reg_addr=0x!BH!%~1"
call adb shell "echo !reg_addr! > !REGMAP!/address" >nul 2>&1
if errorlevel 1 exit /b 1
set "read_raw="
for /f "delims=" %%v in ('call adb exec-out "cat !REGMAP!/data" 2^>nul') do set "read_raw=%%v"
if not defined read_raw exit /b 1
call :reg_parse
exit /b

:: 把 !read_raw! 换算成数值 !read_num!
:reg_parse
set "rv=!read_raw!"
if /i "!rv:~0,2!"=="0x" goto reg_parse_num
if "!regfmt!"=="dec" goto reg_parse_num
set "rv=0x!rv!"
:reg_parse_num
set "read_num="
set /a "read_num=!rv!" 2>nul
if not defined read_num exit /b 1
exit /b 0

:: 探测 data 读回格式: 只读寄存器 TYPE 固定为 0x10
:: 返回 0x10 前缀hex, 返回 10 裸hex, 返回 16 十进制
:reg_fmt_detect
if defined regfmt exit /b 0
set "regfmt=hex"
call :reg_read !OFF_TYPE!
if errorlevel 1 exit /b 0
if /i "!read_raw:~0,2!"=="0x" exit /b 0
if "!read_raw!"=="16" set "regfmt=dec"
if "!read_raw!"=="10" set "regfmt=hex"
exit /b 0

:: 十进制转十六进制: %1=数值, 结果在 !hexout!
:dec2hex
set /a "dhv=%~1" 2>nul
set "hexout="
:dec2hex_loop
set /a "dhn=dhv %% 16"
set "hexout=!HEXD:~%dhn%,1!!hexout!"
set /a "dhv=dhv / 16"
if !dhv! gtr 0 goto dec2hex_loop
set "hexout=0x!hexout!"
exit /b 0
:: 探测可用接口: REGMAP = 有 address/data 文件, GPIOID = 只能走 gpiochip
:detect_iface
if defined iface exit /b 0
set "step=Detect available register interface"
set "iface="
for /f "delims=" %%v in ('call adb shell "if [ -e !REGMAP!/address ]; then echo REGMAP; else echo GPIOID; fi" 2^>nul') do set "iface=%%v"
if not defined iface exit /b 1
exit /b 0

:: 找到 18 条线的 gpiochip, 即 PMIC 的 18 颗 GPIO
:find_chip
if defined chip exit /b 0
set "chip="
for /f "tokens=1" %%c in ('call adb shell gpiodetect 2^>nul ^| findstr /l /c:"(18 lines)"') do if not defined chip set "chip=%%c"
if not defined chip exit /b 1
exit /b 0

:: 取 gpioinfo 里某一行的描述, %1 = line 编号
:gpiod_line_info
set "gline="
for /f "delims=" %%r in ('call adb shell "gpioinfo !chip!" 2^>nul ^| findstr /r /c:"line *%1:"') do set "gline=%%r"
if not defined gline exit /b 1
exit /b 0
