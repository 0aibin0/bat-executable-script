# A 组静态审计：流程控制 / 错误处理 / adb 用法

审计范围：工作区 `D:\Desktop\debug_temp\bat脚本` 下 9 个 `.bat`，纯静态读取。
约束遵守：**未执行任何 `.bat`、未调用任何 `adb` 命令、未连接任何设备、未修改任何 `.bat`**（9 个 `.bat` 的 mtime 全部保持原样：2026-09/10/11 月批次，无一处变更）。未读取 `LOGS_20261103_1015/logcat.txt` 全文（78 MB），只对其做过 `head`/`tail`/`stat` 的有界抽样。

> **探针说明（重要，便于复核）**：本文所有"实测"结论，均来自 `analysis/probes_A/` 下自建的探针脚本与 stub 文本（`stub_gpiodetect.bat`、`chips.txt`、`ginfo.txt` 等）——它们**只复现 cmd.exe 语义**，不包含、也没有执行任何一条 `adb` 命令（stub 只 `echo` 文本）。所有 `.bat` 原文引用都来自对源文件的直接读取。
> `PM_GPIO_CTRL-mimo.bat` 为 GBK 编码，本文引用其内容时用 `iconv -f GBK -t UTF-8` 转换后按**原文件行号**标注（766 行，行号与转换结果一一对应）。

条目格式：`[严重度] 文件:行号 — 现象 / 根因 / 影响 / 修复建议`
严重度定义：**阻断**＝必然产生错误行为或数据损坏；**高**＝常见环境下静默给出错误结果或残留进程；**中**＝健壮性/可维护性缺陷；**低**＝可读性/一致性问题。

---

## 0. 先给结论：一张表看清"哪条失败路径真的被捕获了"

| 脚本 | adb 调用数 | 有 `errorlevel`/`&&`/`||` 校验 | 设备预检查 | 清理步骤 | 结论 |
|---|---|---|---|---|---|
| `PM_GPIO_CTRL-mimo.bat` | 23 | 40 处（最完善） | ✅ `:dev_check`(L682) + `get-state`(L265) | 不需要（无临时文件） | 校验最全，但**校验本身有 3 处系统性失效**（见 A-04/A-05/A-06） |
| `current_display.bat` | 13 | **0** | ⚠️ 只有 `wait-for-device`(L13)，无超时 | 无 | 13 条 adb 全部不校验退出码 |
| `disp_continuous_monitor.bat` | 31 | **0** | ⚠️ 同上 | ❌ 无（见 A-01） | **最严重**：31 条 adb + 2 个后台窗口，全程零校验、零清理 |
| `备用脚本/capture_disp_log.bat` | 11 | **0** | ⚠️ 同上 | 无 | 11 条全裸奔 |
| `备用脚本/monitor.bat` | 6 | **0** | ⚠️ 同上 | ❌ 无 | 3 个后台窗口，零清理 |
| `auto_shot.bat` | 6 | **0** | ❌ 无 | 无 | 无限循环 + 假成功 |
| `power-key.bat` | 3 | **0** | ❌ 无 | 无 | 固定 100 次，循环内无任何校验 |
| `push_apk.bat` | 8 | 4 处 | ❌ 无 | 无 | 校验存在但**判定方式不可靠**（A-02/A-03） |
| `push_msm_drm_ko.bat` | 7 | 4 处 | ❌ 无 | 无 | 同上 |

（统计方式：`grep -c -E "(^|[^a-z])adb "` 与 `grep -c -E "errorlevel|&&|\|\|"`。）

---

## A-01 [阻断] disp_continuous_monitor.bat:49,51 + :54 + :90 — 后台抓取子窗口无回收机制，"停止"完全依赖人工 Ctrl+C；父脚本 `pause` 后径直 `exit`

**现象（三处互锁）**
- `L49`：`start "Logcat" cmd /c "adb shell logcat -b all -v threadtime > logcat.txt 2>&1"`
- `L51`：`start "Dmesg"  cmd /c "adb shell dmesg -w > dmesg.log 2>&1"`
- `L54`：`pause`（唯一"停止"手段）
- `L90`：`exit`（裸 `exit`，直接结束整个 `cmd.exe` 进程）

`L41` 的提示是 `echo  复现结束后需要手动关闭 Logcat/Dmesg 窗口` —— 全脚本**没有任何 `taskkill` / `adb shell pkill` / `adb kill-server`**（全仓 9 个脚本 `grep -i -E "taskkill|kill-server|adb kill|wmic"` 结果为 `NONE`）。

**根因**：`start` 起的是**独立子进程**，与父脚本没有父子生命周期绑定；父脚本 `exit` 只杀自己。`pause` 只是时间闸门，不是信号量——它无法通知那两个 `cmd /c` 窗口停止。

**实测（本地探针 `probes_A/p_child.bat`，用 `ping` 代替 `adb`，不碰设备）**
```
parent exiting now
t+2s  size=142        ← 父脚本已经 exit
t+6s  size=387        ← 子进程仍在往同一个文件写
t+11s size=625        ← 证实子进程完全脱离父脚本存活
```

**现场物证（工作区 `LOGS_20261103_1015/`，均为本约束允许的只读 `stat`/`head`/`tail`，未读全文）**
```
logcat.txt   78973584 字节  mtime 11:12:51   末尾 0d 0a 5e 43  → "...\r\n^C"
dmesg.log     1783230 字节  mtime 11:12:52   末尾 0d 0d 0a 0d 0a 5e 43 → "...^C"
logcat_all_before.txt  14211546  mtime 10:15:13   ← 早于实时抓取 57 分钟
logcat_all_after.txt   21192521  mtime 11:12:55   ← 实时抓取停止后 4 秒
bugreport.zip          6705875  mtime 11:14:57
```
两个实时日志的**末两字节都是 `0x5E 0x43`（`^C`）**：这不是脚本写进去的，是**用户手动在子窗口按 Ctrl+C** 留下的。`dmesg.log` 末尾还有 `0d 0d 0a`（`\r\r\n`），说明它被打断在**半个行尾**上——典型的"人手动掐断"而非程序化收尾。

**时间线还原**（依据文件 mtime 与被审计脚本的行号顺序）：
```
10:15:13  L24-25   before 快照（logcat_all_before / dmesg_before）
11:11:05  实测采样：logcat.txt 正在增长（78,839,218 字节，6 秒后 78,846,863）  ← 此时脚本仍卡在 L54
11:12:51  用户手动 Ctrl+C 掐断 Logcat 子窗口
11:12:52  用户手动 Ctrl+C 掐断 Dmesg 子窗口
11:12:55  L58-59   after 快照（logcat_all_after / dmesg_after）—— 说明用户是在主窗口按了回车
11:13:00  L71-74   截图
11:14:57  L84      bugreport
```
即：**"停止抓取"这一步 100% 由人工在两个子窗口里按 Ctrl+C 完成，脚本自己一行代码都没参与**；`L54` 的 `pause` 只是"等你回来按回车去拍终点快照"。写报告时（11:5x）`logcat.txt` 已停止增长（mtime 停在 11:12:51），说明本次操作者**记得**手动关窗口——这正是本缺陷最危险的地方：**它依赖人的记性，忘了就会一直残留**。

> 关于"残留进程"的边界说明：本次现场**当前没有**残留的 logcat/dmesg 子进程（`logcat.txt`/`dmesg.log` 的 mtime 已停止推进；`tasklist` 里只有 `adb fork-server`，那是 adb 服务端守护进程，属正常）。但"子进程会脱离父脚本长时间存活"这一点已由本地探针独立证实，且本次现场也确实需要人工干预才停下——缺陷成立，只是尚未在最坏时刻暴露。

**影响**
1. **盘占**：`logcat.txt` 单次运行 78 MB 且**无上限**（无 `-n`/`-r` 轮转，见 A-09）。
2. **数据不自洽**：`logcat.txt` 覆盖 10:15→11:12 的**全部历史 + 实时增量**（`L47` 的 `logcat -c` 被注释，见 A-23），与 `logcat_all_after.txt`（11:12:55 的快照）在时间上重叠 21 MB，无法用文件边界切分"复现窗口"。
3. **进程残留（条件性但真实）**：`start` 出的两个 `cmd.exe` + 两个 `adb.exe` 与父脚本无生命周期绑定。本次操作者手动 Ctrl+C 收掉了；**一旦遗忘**，它们会继续灌盘直到写满，且下次运行会**叠加第二份**同名抓取。本地探针已证实子进程在父进程 `exit` 后仍持续写文件（`t+11s size=625`）。

**修复建议**：`start` 出来的进程必须由脚本自己收尸，且"停止"用信号而不是 `pause`：
```bat
:: L49/L51 改为记录 PID（start /b + 重定向不能让窗口显示，但可控）
start "Logcat" cmd /c "adb shell logcat -b all -v threadtime -n 8 -r 65536 > logcat.%%03d.txt 2>&1"

:: L54 的 pause 之后，立刻按窗口标题杀子进程（比按 PID 稳，因为 cmd /c 会再派生 adb）
echo Stopping background capture...
taskkill /FI "WINDOWTITLE eq Logcat*" /F >nul 2>&1
taskkill /FI "WINDOWTITLE eq Dmesg*"  /F >nul 2>&1
:: 双保险：断掉设备端 logcat/dmesg 进程，避免 PC 端杀了但设备端还在灌
adb shell "pkill -f 'logcat -b all'" >nul 2>&1
adb shell "pkill -f 'dmesg -w'"      >nul 2>&1
```
并把 `L54` 的 `pause` 改成带说明的等待：`pause >nul & echo 已停止后台抓取`。

---

## A-02 [高] push_apk.bat:6 / push_msm_drm_ko.bat:6 — `adb root | findstr "restarting"` 这一句在三种真实场景下**全部走 WARN 分支，连"设备没连上"都被说成"可能已经是 root"**

**现象**
```bat
adb root | findstr /i "restarting" >nul && echo       OK: adbd restarted as root || echo       WARN: Device may already be rooted or not supported
```

**根因**：`&&`/`||` 取的是**管道最后一个命令（`findstr`）的退出码**，不是 `adb` 的。`adb root` 的退出码被整条管道吃掉了。

**实测（`probes_A/p_fs2.bat`、`v4.bat`，用 stub 复刻 adb 的两种真实输出）**
```
A. adb 已 root，输出 "adbd is already running as root"，rc=0
   → findstr "restarting" 不匹配(rc=1) → 走 WARN 分支        【文案侥幸正确】
B. 设备没插，stderr 输出 "error: no devices/emulators found"，rc=1
   → findstr 无可匹配输入(rc=1)     → 走 WARN 分支            【文案完全误导】
C. adb 不存在/PATH 错，rc=9009
   → 同上，仍是同一个 WARN                                    【文案完全误导】
```

**影响**：这是 9 个脚本里**唯一一处"看起来做了失败判定、实际上三种失败都汇入同一条无害文案"的假校验**。用户看到 `WARN: Device may already be rooted or not supported` 会以为"设备在、只是已经 root"，继续往下走，然后在 L9 `adb remount` 处失败——而 L9 的失败文案又指向"检查 remount"，把根因（根本没设备）藏得更深。

**修复建议**：先判连接，再判 root，全部用退出码：
```bat
adb get-state >nul 2>&1
if errorlevel 1 (echo       FAIL: no device / adb not found. Run "adb devices". & pause & exit /b 1)

adb root >nul 2>&1
if errorlevel 1 (echo       WARN: adb root failed (production build? user build?) & echo       Root is REQUIRED for remount. & pause & exit /b 1)
echo       OK: root
```

---

## A-03 [高] push_apk.bat:9 / push_msm_drm_ko.bat:9 — `adb remount | findstr "succeeded"`：remount 失败但输出里带 "succeeded" 就放行；失败分支还把 `pause` 排在 `exit /b` 之前，无人值守必卡死

**现象**
```bat
adb remount | findstr /i "succeeded" >nul && echo       OK: Remount succeeded || (echo       FAIL: Remount failed! & pause & exit /b 1)
```

**根因（两重）**
1. 同样是**管道吞退出码**（同 A-02）。`findstr /i "succeeded"` 只要有 `succeeded` 子串就 `rc=0`。真实世界里 `adb remount` 的失败输出可能是 `remount failed: /vendor not remountable, but overlayfs succeeded` 这类含 `succeeded` 的句子 → **判定为成功**，后续 `push` 全部写进只读分区然后失败。
2. `exit /b` 写在 `( ... & ... & exit /b 1 )` 里。实测（`probes_A/p_final.bat`）`exit /b` 在括号组内**会正常终止整个脚本**（输出停在 `inside-block`，`SHOULD-NOT-PRINT` 未打印），这一点**没问题**；但同一行里 `pause` 在 `exit /b` **之前**，意味着任何自动化/CI 调用都会**卡在 pause 上等人按键**——无法无人值守。

**影响**：`/vendor` 没真正可写时，`adb push`（L19）会失败，L20 的 `errorlevel` 判定能兜住（见 A-11），但用户会先被 L9 的 "OK: Remount succeeded" 误导，把排查方向带到 push/网络上去。

**修复建议**
```bat
adb remount > "%TEMP%\remount.txt" 2>&1
if errorlevel 1 (
    type "%TEMP%\remount.txt"
    echo       FAIL: remount failed (see above). Root + disable-verity + reboot required.
    exit /b 1
)
echo       OK: Remount succeeded
```
（失败分支不要塞 `pause`；无人值守时它会永久阻塞。若确需交互，用 `if "%CI%"=="" pause` 之类的开关。）

---

## A-04 [高] PM_GPIO_CTRL-mimo.bat:265-266 / 684-685 — `adb get-state` 判"设备在线"是对的，但**只判这一件事**；`get-state` 成功 ≠ 目标设备正确、≠ 有 root、≠ regmap 可写

**现象**
```bat
264| set "step=ADB device check"
265| call adb get-state >nul 2>&1
266| if errorlevel 1 goto step_error
...
682| :dev_check
684| call adb get-state >nul 2>&1
685| if errorlevel 1 exit /b 1
```

**根因**：全仓 9 个脚本 `grep -E "\-s [A-Za-z0-9]|ANDROID_SERIAL"` 结果为 **`NONE`** —— 没有任何脚本指定序列号。当 `adb devices` 里有两台以上时，`adb get-state` 会直接**失败**（`error: more than one device/emulator`，rc=1），被 L266 正确拦下，这没问题；但**只有一台时它永远通过**，而"这一台是不是你想操作的那台 PMIC 设备"完全没验证。

**影响**：实验室里常见"一台目标机 + 一台无关的调试机"同时连着 adb。此时 `get-state` 通过，`!REGMAP!`（`L48` 硬编码 `/d/regmap/1-00`）会在**错误设备**上被探测。`detect_iface`(L746) 又带有**进程内缓存**（`if defined iface exit /b 0`），一旦第一次探测落在错设备上，后续所有步骤都用这个错误结论。

**修复建议**
```bat
:: 统一入口处
set "SERIAL=%~1"? 不行，参数位已被 GPIO 号占用 → 用环境变量
if not defined PM_GPIO_SERIAL (
    for /f "skip=1 tokens=1" %%d in ('adb devices') do if not defined PM_GPIO_SERIAL set "PM_GPIO_SERIAL=%%d"
)
adb -s %PM_GPIO_SERIAL% get-state >nul 2>&1
if errorlevel 1 (set "step=ADB device check" & goto step_error)
```
并打印 `adb -s %PM_GPIO_SERIAL% shell getprop ro.product.device` 让用户确认对象。

---

## A-05 [高] PM_GPIO_CTRL-mimo.bat:691-694 / 693 — `:reg_write` 的 `%~2` 未加引号就直接进 `adb shell`，`0x1` 之外的取值可能被远端 shell 拆词；更关键的是**写入是否被内核拒绝完全没校验**

**现象**
```bat
689| :reg_write
690| set "reg_addr=0x!BH!%~1"
691| call adb shell "echo !reg_addr! > !REGMAP!/address"
692| if errorlevel 1 exit /b 1
693| call adb shell "echo %~2 > !REGMAP!/data"
694| if errorlevel 1 exit /b 1
695| exit /b 0
```

**根因**：脚本自己的注释（`L32-34`）就写明了：
```
32| ::   若该 PMIC 外设的写权限不归当前 EE, 内核会打印
33| ::        disallowed SPMI write to sid=... addr=...
34| ::   此时该 GPIO 无法从系统内修改, 脚本会在对应步骤报错
```
——**但代码并没有"在对应步骤报错"**。内核拒绝 SPMI 写时，`echo 0x1 > /d/regmap/1-00/data` 这条**远端 shell 命令依然 `rc=0`**（重定向本身成功了，只是内核层面丢弃/报错），`adb shell` 于是返回 0，`L692/L694` 的 `if errorlevel 1` 不成立，脚本继续往下走并打印 OK。注释承诺的行为与实现不符。

**实测佐证（cmd 语义层面，`probes_A/p_sa.bat`）**：`adb shell` 的 stdout 若包含 `Permission denied` 这类文本，`errorlevel` 仍是 0；脚本唯一"看输出"的地方只有 `L306` 的回读，而回读在失败时只是 `echo read-back not available, skip`（见 A-06），不会升级为错误。

**影响**：**这是本脚本最危险的一类失败**——注释里明确写着这种情况会发生，脚本也本该报错，实际却打印 `applied OK` 并 `exit /b 0`。上层自动化（若有）会认为 GPIO 已经设好。

**修复建议**：写入后必须**回读校验**，并把不匹配当作失败：
```bat
:reg_write
set "reg_addr=0x!BH!%~1"
call adb shell "echo !reg_addr! > !REGMAP!/address" || exit /b 1
call adb shell "echo %~2 > !REGMAP!/data" || exit /b 1
:: 回读（data 当前指向的正是刚写的 address）
set "rb="
for /f "delims=" %%v in ('call adb exec-out "cat !REGMAP!/data" 2^>nul') do set "rb=%%v"
if not defined rb exit /b 1
call :reg_parse
set /a "want=%~2" 2>nul
if not "!read_num!"=="!want!" (
    echo       [FAIL] write verify: wrote %~2, read back !rb!  ^(kernel rejected? see "disallowed SPMI write"^)
    exit /b 1
)
exit /b 0
```
另：`%~2` 建议加引号——远端 `[`/`>` 等字符一旦出现在参数里会被远端 shell 解释（虽然当前调用点只传 `0x1`/`0x80`/`0x00`/`0x!BH!!offset!`，但这是子程序的契约漏洞）。

---

## A-06 [高] PM_GPIO_CTRL-mimo.bat:306-317 — 回读失败被降级为 `skip`，紧接着无条件打印 `applied OK` 并 `exit /b 0`

**现象**
```bat
303| set "step=Read back"
304| echo [check] Reading back OUT_SRC_CTL...
305| set "readback="
306| for /f "delims=" %%v in ('call adb exec-out "cat !REGMAP!/data" 2^>nul') do set "readback=%%v"
307| if defined readback (
308|     echo       OUT_SRC_CTL = !readback!
309| ) else (
310|     echo       read-back not available, skip
311| )
313| echo ========================================
314| echo  !GPIO_NAME! applied OK: !level! = !out_val!
315| echo ========================================
317| if defined cli exit /b 0
```

**根因**：`L306` 的 `for /f` 在远端命令无输出时**一次都不迭代**，`readback` 保持未定义；`L307` 的 `else` 分支只打印一句 `skip`，**既不 `set "step="` 也不 `goto step_error`**，于是流程照常落到 `L314` 的 `applied OK`。

**实测（`probes_A/clean/v9.bat`，逐行复刻 L302-317）**
```
      read-back not available, skip
applied OK (L314 unconditionally printed)
would pause
```

**影响**：这是 A-05 的放大版——**回读是脚本里唯一的"写入是否生效"证据，而它失败时脚本给出的结论仍是 OK**。`exit /b 0` 让上层完全无法区分"写成功"和"没读回来"。

**修复建议**：把回读失败变成真正的失败（区分"读不到"与"值不对"）：
```bat
if not defined readback (
    set "step=Read back OUT_SRC_CTL"
    goto step_error
)
if /i not "!readback!"=="!out_val!" (
    echo       [FAIL] read-back mismatch: want !out_val!, got !readback!
    set "step=Read back OUT_SRC_CTL"
    goto step_error
)
```
（注意 `readback` 的格式还受 `:reg_fmt_detect`(L723) 影响：可能是 `0x80` / `80` / `128`，直接字符串比较会误判，需要先经 `:reg_parse` 归一化。）

---

## A-07 [中] PM_GPIO_CTRL-mimo.bat:717-718 — `:reg_parse` 的 `if not defined read_num` 只在"含 `0x` 前缀"或"含空格"的垃圾输入上生效；`regfmt=dec` 分支下**单个词**的错误文本会被静默当成 0

**现象**
```bat
715| :reg_parse_num
716| set "read_num="
717| set /a "read_num=!rv!" 2>nul
718| if not defined read_num exit /b 1
```

**根因**：`set /a` 把无法解析的 token 当作**环境变量名**求值，未定义则取 0，**并且赋值照样发生**——所以 `L718` 的"未定义"检测抓不住"值是 0"。

**实测（`probes_A/clean/v21.bat`，按 L710-719 精确复刻两条分支）**
```
=== regfmt=dec 分支（L713，不加 0x 前缀）===
  raw=[Permission]                              → read_num=[0]  PASSED_L718  ← 漏检
  raw=[cat: /d/regmap/1-00/data: Permission denied] → CAUGHT_by_L718      ← 多词，能抓住

=== regfmt=hex 分支（L714，加了 0x 前缀）===
  raw=[Permission]  → 0xPermission → CAUGHT_by_L718                       ← 前缀救了它
  raw=[80]          → read_num=[128] OK                                    ← 正常路径
```
（另一组 `probes_A/v10.bat`：`set /a "n+=0"` → `defined n = YES`；`set /a "read_num=Permission"` → `read_num=0` 已定义。）

**影响（收敛后的准确表述）**：漏检需要同时满足两个条件——(a) `:reg_fmt_detect` 判定 `regfmt=dec`（`L729`：`TYPE` 读回字面 `16`），且 (b) 读回的垃圾是**单个无空格 token**。两个条件都不常见，所以**不是高概率缺陷**；但一旦命中，`read_num=0` 会一路带着 `:set_dir`/`:set_drive` 的位运算跑完并写寄存器（`0` 在 `MODE_CTL` 里意味着**方向被设成 IN**），而脚本打印 OK。

**修复建议**：先用字符集白名单，再交给 `set /a`：
```bat
:reg_parse_num
set "read_num="
echo !rv!| findstr /r /c:"^0x[0-9A-Fa-f][0-9A-Fa-f]*$" /c:"^[0-9][0-9]*$" >nul || exit /b 1
set /a "read_num=!rv!" 2>nul
if not defined read_num exit /b 1
exit /b 0
```

---

## A-08 [中] PM_GPIO_CTRL-mimo.bat:734-743 — `:dec2hex` 在**正常取值范围（0-255）内是正确的**；只有寄存器值最高位为 1（`set /a` 得到负数）时才产出脏值，而这条路径**确实可达**

> **纠偏记录**：本轮最初怀疑 `dec2hex` 会算错 `240`→`0x0`，经第二轮隔离测试确认那是**探针自身的**变量未赋值错误。实测该子程序对 `0/1/15/16/128/240/255/4095/65535/16777215` **全部正确**（`probes_A/clean/v19.bat`）。以下只保留经复核成立的部分。

**现象**
```bat
734| :dec2hex
735| set /a "dhv=%~1" 2>nul
736| set "hexout="
737| :dec2hex_loop
738| set /a "dhn=dhv %% 16"
739| set "hexout=!HEXD:~%dhn%,1!!hexout!"
740| set /a "dhv=dhv / 16"
741| if !dhv! gtr 0 goto dec2hex_loop
742| set "hexout=0x!hexout!"
743| exit /b 0
```

**根因**：`set /a` 是 **32 位有符号**。`:reg_read`(L699) 把 `data` 读回值经 `:reg_parse`(L710) 转成 `read_num` 后，若寄存器值最高位为 1（如 `FFFFFFFF`、`80000000`、`CC` 以外的高位值），`read_num` 是**负数**。`L738` 的 `dhn = dhv %% 16` 于是为负，`L739` 的 `!HEXD:~%dhn%,1!` 遇到负偏移会**原样吐出未展开的表达式**。

**实测（`probes_A/clean/v19.bat`，逐行复刻 L734-743）**
```
  in=0    out=[0x0]        in=240  out=[0xF0]       ← 正常值全对
  in=15   out=[0xF]        in=255  out=[0xFF]
  in=4095 out=[0xFFF]      in=16777215 out=[0xFFFFFF]

  read_raw=ffffffff → read_num=-1      → dec2hex(-1) = [0xF]   ← 期望 0xFFFFFFFF（错）
  read_raw=80000000 → read_num=-2147483648 → dec2hex = [0x0]   ← 期望 0x80000000（错）
  read_raw=40  → mode_new=65  → 0x41   ✅
  read_raw=cc  → mode_new=205 → 0xCD   ✅
```
关键点：**GPIO 寄存器实际用到的位域（`MODE_CTL` 的 bit6:4、`OUT_SRC_CTL` 的 bit7、`DIG_OUT_CTL` 的 bit5:0）都在低 8 位内**，所以 `set_dir`(L353)/`set_drive`(L418) 的读改写**在正常硬件上不会触发**这个 bug。但 `:reg_read` 读的是 `data` 文件的**整个 32 位字**——如果某颗 GPIO 的 `data` 返回 `0xFFFFFFxx` 这类值（部分 regmap debugfs 实现会这样），`read_num` 就是负数，`(read_num & ~dir_mask)` 依旧正确（位运算在 32 位下自洽），但 `dec2hex` 的输出会变成脏串 → `:reg_write` 把脏串写进 `address` 寄存器。

**影响（收敛后的准确表述）**：不是"随时会算错"，而是**一条在非典型硬件/非典型 regmap 实现下可达的脏数据路径**，失败模式是"往 `address` 写 `0xF` 而不是 `0x0000E8CC`"，之后 `data` 写入落到**错误偏移**。属"低概率、高后果"，故定为**中**而非高。

**修复建议**：加一道范围护栏（简单且彻底）：
```bat
:dec2hex
set /a "dhv=%~1" 2>nul
if !dhv! lss 0 (
    echo       [FAIL] dec2hex: negative value !dhv! - register width assumption broken
    exit /b 1
)
if !dhv! gtr 0xFFFF exit /b 1        :: PMIC 寄存器偏移最大 0x46，值域 8 位
...
```
或直接改用 `powershell` 格式化（见 A-08 备选方案），彻底避开手写进制转换。

---

## A-09 [高] 4 个抓取脚本：`logcat.txt` 无轮转、无 `-c` 清缓冲、无大小上限——单次运行 78 MB，磁盘可被吃满

**现象**：`disp_continuous_monitor.bat:47` 的清缓冲 `::adb logcat -c -b all` **被注释掉**；`L49` 的实时抓取 `adb shell logcat -b all -v threadtime > logcat.txt` 没有 `-n`/`-r`/`-G` 任何限量参数。`备用脚本/monitor.bat:28` 反而有 `adb logcat -c -b all`（两个脚本在这一步行为相反）。

**根因**：`adb shell logcat` 直接输出到文件重定向，没有走 `adb logcat -n 8 -r 65536`（adb 客户端自带的轮转），也没有 `-b` 之外的限制。

**现场物证**：`LOGS_20261103_1015/logcat.txt` = **78,973,584 字节**（单次运行，10:15→11:12）；同目录 `logcat_all_before.txt` 14 MB + `logcat_all_after.txt` 21 MB + `bugreport.zip` 6.7 MB，**单次运行总产出 ≈ 121 MB**。

**影响**：`dmesg -w` 同理（`dmesg.log` 1.78 MB，但内核 printk 速率不可控）。若复现场景是"复现一晚上"，`logcat.txt` 可到 GB 级；磁盘写满后 `bugreport.zip` 会写成**截断的 zip**（本次侥幸完整，尾标记 `50 4b 05 06` 存在），且 `logcat_all_after.txt` 也会截断——**基线/终点快照对不齐，整个分析报废**。

**修复建议**
```bat
:: 用 adb 客户端自身轮转（优先，避免设备端 rm）
start "Logcat" cmd /c "adb logcat -b all -v threadtime -n 16 -r 65536 > /dev/null 2>&1"
```
（`adb logcat -n/-r` 会写 `logcat.NN.txt` 到**当前目录**，因此必须先 `cd /d "%OUT%"`——本脚本 L20 已经这么做了。）若坚持用 `adb shell logcat`，则至少要：
```bat
start "Logcat" cmd /c "adb shell logcat -b all -v threadtime -G 4M -n 8 -r 65536 > logcat.txt 2>&1"
```
并在 `L54` 之后按 A-01 收尸。

---

## A-10 [中] 4 个抓取脚本：`adb wait-for-device` 无超时、无 `devices` 确认、`adb root` 不看结果——设备不在时脚本永久挂起

**现象（4 处逐字相同）**
```
current_display.bat:13          adb wait-for-device
disp_continuous_monitor.bat:13  adb wait-for-device
备用脚本/capture_disp_log.bat:11  adb wait-for-device
备用脚本/monitor.bat:13         adb wait-for-device
```
紧接着：
```
current_display.bat:15          adb root
disp_continuous_monitor.bat:15  adb root
备用脚本/capture_disp_log.bat:14  adb root
备用脚本/monitor.bat:15         adb root
```
全仓 `grep -i -E "retry|attempt"` = **`NONE`**，无任何重试。

**根因**：`adb wait-for-device` **没有内置超时**（新版 adb 也没有 `--timeout`），设备永远不插上就永远阻塞。

**影响**：`dumpsys`/`dmesg` 类抓取大多需要 root（`dmesg` 在 user 版上返回 `Operation not permitted`）；`L15` 的 `adb root` 若失败（user 版、`verity` 锁），脚本**完全不知情**，继续执行，产出一堆 0 字节或只有报错的快照。本次 `dmesg_before.txt` 是 536 KB 正常内容，属环境允许 root 的情形；换台 user 版设备就是 12 个空文件，而脚本最后仍打印 `Done! Logs saved to: %OUT%`。

**修复建议**
```bat
echo Waiting for device (max 60s)...
adb wait-for-device
adb get-state >nul 2>&1 || (echo [FAIL] no device & pause & exit /b 1)

adb root >nul 2>&1
if errorlevel 1 (
    echo [WARN] adb root failed - dmesg/dumpsys may be incomplete
) else (
    adb wait-for-device        :: root 会重启 adbd，必须重新等
)
```
**注意**：`adb root` 成功会重启 adbd，`wait-for-device` 必须**再调一次**——现有代码在 `L15` 之后直接进 `L19` 建目录/`L24` 抓取，中间没有任何重新等待，存在**竞态**（本次现场没有暴露，是因为 10:15:13 的快照都拿到了内容）。

---

## A-11 [中] push_apk.bat:20 / push_msm_drm_ko.bat:20 — `if !errorlevel! neq 0` 写法本身正确，但它与 L9 的 `if errorlevel 1` 家族混用，且**每行都靠 `!errorlevel!` 立即读取**，中间插入任何 `echo` 就会失效

**现象**
```bat
19| adb push "<UNC>" /vendor/overlay/FrameworksResOverlay_Wear.apk
20| if !errorlevel! neq 0 (echo       FAIL: Push failed! Check network/path. & pause & exit /b 1) else (echo       OK: Push completed.)
```
对比 `L9`：`adb remount | findstr ... && ... || (...)` —— 两种风格混用。

**根因/实测（`probes_A/p_pause.bat`、`p_final.bat`）**
- `!errorlevel!` 与 `%errorlevel%` 在 `setlocal EnableDelayedExpansion`(L3) 下等价且都**立即读取当前值**，`if !errorlevel! neq 0` 本身**没问题**（L20 是 9 个脚本里写得最正确的一处失败判定）。
- 但 `neq 0` 与 `if errorlevel 1` 的语义域不同：`if errorlevel 1` 是"≥1"，`neq 0` 是"≠0"。实测 `exit /b -1073741510` 这种**负数退出码**（Windows 上 `0xC0000006` 之类的崩溃码）：
  ```
  real=[-1073741510]
  if errorlevel 1  → MISSES      （-1073741510 < 1）
  if !errorlevel! neq 0 → CATCHES
  ```
  即：**同一个脚本里 L9 用 `&&`/`||`（等价 `errorlevel` 语义）、L20 用 `neq 0`，两套语义并存**。若将来把 L20 改成 `if errorlevel 1`，就会漏掉崩溃码。

**影响**：当前 L20 的判定是对的，但 `pause` 在 `exit /b` 之前（同 A-03），无人值守时阻塞。另外 `adb push` 失败可能输出 `adb: error: failed to copy` 但**返回 0**（部分 adb 版本在远端 `symlink` 场景），此时仍打印 OK。

**修复建议**
```bat
adb push "<UNC>" /vendor/overlay/FrameworksResOverlay_Wear.apk
set "pushrc=!errorlevel!"
if not "!pushrc!"=="0" (
    echo       FAIL: Push failed ^(rc=!pushrc!^). Check network/path/remount.
    exit /b 1
)
:: 用尺寸比对做二次确认，不依赖退出码
for /f "tokens=5" %%s in ('adb shell ls -l /vendor/overlay/FrameworksResOverlay_Wear.apk') do set "rsize=%%s"
if not defined rsize (echo       FAIL: pushed file not visible & exit /b 1)
```

---

## A-12 [中] push_apk.bat:16 / push_msm_drm_ko.bat:16 — `ls ... 2>nul | findstr ...` 把 `2>nul` 放在管道**左侧**，远端错误被丢弃，判定退化

**现象**
```bat
adb shell ls /vendor/overlay/FrameworksResOverlay_Wear.apk 2>nul | findstr /i "No such file" >nul && echo       OK: Old file removed || echo       WARN: File still exists or path invalid
```

**根因**：`2>nul` 只作用于 `adb.exe` 进程自身的 stderr。远端 `ls` 的报错经 adb 协议回传后，在部分 adb 版本上走 **stdout**、部分走 **stderr**；走 stderr 时被 `2>nul` 吞掉，`findstr` 收不到 → 永远走 `WARN` 分支。

（B 组已就 `findstr` 的多个空格分隔子串是 OR 关系做过专题分析；A 组只补充"**管道位置**导致判定退化"这一面，不重复计量误判率。）

**影响**：`WARN: File still exists or path invalid` 这条分支**既可能是真残留、也可能是连接失败、也可能是 `rm` 只读文件系统失败**，三者无法区分；而 `L12` 的 `adb shell rm -rf` 本身**完全没有错误检查**（`grep -n errorlevel push_apk.bat` 只有 L9/L20 两处）。

**修复建议**：改用远端 `test` 的退出码（唯一可靠的办法）：
```bat
adb shell "test -e /vendor/overlay/FrameworksResOverlay_Wear.apk"
if !errorlevel! equ 0 (
    echo       FAIL: old file still exists. rm failed? check "mount | grep vendor"
    pause & exit /b 1
)
echo       OK: Old file removed
```
并对 `L12` 的 `rm -rf` 单独判 `errorlevel`。

---

## A-13 [中] auto_shot.bat:36-43 — `for /f` 循环体不执行时 `file` 保持上一次的值，`adb pull` 拉的是**上一张**图，然后打印 `OK`

**现象**
```bat
36| for /f "delims=" %%i in ('adb shell ls -t %PHONE_PATH%/*.jpg 2^>nul') do (
37|     set file=%%i
38|     goto PULL
39| )
40| :PULL
42| adb pull "!file!" "%SAVE_DIR%\!ts!.jpg" >nul 2>&1
43| echo OK: !ts!.jpg
```

**根因（两重）**
1. `:PULL` 是**顺序落点**：`for` 一次都没迭代时，控制流照样从 L39 落到 L40，`file` 仍是上一轮循环留下的值。
2. 变量 `file` **从未在循环前清空**（L23 `:LOOP` 处没有 `set "file="`）。

**实测（`probes_A/p_fs2.bat` 系列）**
```
循环体不执行时 → 变量保留旧值：
  set "file=AAA"; for /f ... in ('empty') do set file=%%i  →  file 仍 = AAA
goto 跳出 for 会正确保留已赋的值：
  set "file=AAA" 后 goto PULL → file=AAA（这一步没问题）
```

**影响**：相机没起来 / `ls` 因权限失败 / 拍照还没落盘时，如果**上一轮成功过**，脚本会**重新 pull 上一张图**，再用新的时间戳命名 → `Camera_Android\` 里出现重复内容、看似"每秒都在拍"。`L42` 的 `>nul 2>&1` 又把 pull 失败吞掉，`L43` 无条件 `echo OK` → **假成功**。若上一轮也没成功（`file` 未定义），则 `adb pull "" ...` 同样被吞，依旧打印 OK。

**修复建议**
```bat
:LOOP
set "file="
...
for /f "delims=" %%i in ('adb shell ls -t %PHONE_PATH%/*.jpg 2^>nul') do (
    set "file=%%i"
    goto PULL
)
if not defined file (echo [WARN] no jpg on device, retry & timeout /t 2 >nul & goto LOOP)
:PULL
adb pull "!file!" "%SAVE_DIR%\!ts!.jpg" >nul 2>&1
if errorlevel 1 (echo [FAIL] pull failed: !file! & goto LOOP)
echo OK: !ts!.jpg
```

---

## A-14 [中] auto_shot.bat:24-25 — `chcp 65001` 之后的 `%date%` 变成中文序数词，时间戳实测为 `周二022611114952`，是**非法文件名**

**现象**
```bat
2|  chcp 65001 >nul
...
24| set ts=%date:~0,4%%date:~5,2%%date:~8,2%%time:~0,2%%time:~3,2%%time:~6,2%
25| set ts=!ts: =0!
```

**根因**：`chcp 65001` 后 `%date%` 的形态从 `2026/11/03 周二`（cp936）变成 **`周二 2026/11/03`**（中文在前），`%date:~0,4%` 取到的是 `周二 2`。

**实测（`probes_A/clean/p_ts.bat`，与 L24-25 逐字相同）**
```
REAL_TIMESTAMP_SHOULD_BE=YYYYMMDDHHMMSS
ACTUAL=[周二022611114952]
```
（`p_ts.bat` 未执行任何 adb，仅做字符串处理。）

**影响**：`SADIR\周二022611114952.jpg`。`%date:~5,2%`=`26`（来自 `2026` 的中间两位）、`%date:~8,2%`=`11`——**年份丢了、月份变成日期**。文件名排序即失效，且含中文的文件名在跨平台脚本/`adb pull` 回设备时容易炸。这不是"难看"，是**功能错误**。

**修复建议**：不要用 `%date%`/`%time%` 做时间戳，用 WMI（与代码页无关）：
```bat
for /f "delims=" %%t in ('powershell -NoProfile -Command "Get-Date -Format yyyyMMdd_HHmmss"') do set "ts=%%t"
```
（同目录 `current_display.bat:6-8` 等 4 个脚本用 `for /f ... in ('date /t')`，在 65001 下**恰好能正确切出 `2026/11/03`**，实测 `TOK=[2026][11][03]`——但它们仍然依赖"中文在 token1"这个本机化假设，见 A-15。）

---

## A-15 [中] 4 个抓取脚本 + power-key.bat：时间戳全部依赖本机化的 `date /t`/`%date%` 文本布局，最后 `%OUT: =0%` 还会把路径里的空格改成 `0`

**现象**
```
current_display.bat:6-9 / disp_continuous_monitor.bat:6-9 / 备用脚本/monitor.bat:6-9
备用脚本/capture_disp_log.bat:5-8
```
```bat
6| for /f "tokens=2-4 delims=/ " %%a in ('date /t') do set "date=%%a%%b%%c"
7| for /f "tokens=1-2 delims=: " %%a in ('time /t') do set "time=%%a%%b"
8| set "OUT=%~dp0LOGS_%date%_%time%"
9| set "OUT=%OUT: =0%"
```

**根因 / 实测**
- `L9` 的 `%OUT: =0%` 是**全局替换**，`OUT` 里只要含空格就被改成 `0`。实测 `set "OUT=D:\a b\LOGS_x"` → `OUT=[D:\a0b\LOGS_x]` ——**a b 变成 a0b**。工作区路径 `D:\Desktop\debug_temp\bat脚本` 恰好没有空格，所以问题被掩盖；一旦放到 `C:\Users\张三\My Documents\` 下，输出目录会被创建成一个**不存在的路径**，`mkdir`(L19) 失败、`cd /d`(L20) 也失败（见 A-16），所有相对路径的输出文件都落到**脚本当前目录**。
- `%date:...%` / `%time:...%` 的定位假设 `date /t` 输出为 `YYYY/MM/DD 周X`。实测本机 cp936 是 `2026/11/03 周二`、cp65001 是 `周二 2026/11/03`；`chcp 65001` 在 L2，**先切码页再解析**，所以这些脚本实际走的是"中文在前"分支——恰好 `tokens=2-4` 还能切出 `2026/11/03`（实测 `TOK=[2026][11][03]`）。但这个结果**依赖中文序数词恰好占一个 token**，换英文系统（`Tue 11/03/2026`）就是 `11`/`03`/`2026`，目录名变成 `LOGS_11032026_...`（年份跑到后面）。属"本机侥幸正确"。

（与 B 组"覆盖内建 `date`/`time` 变量"的条目互补：A 组只强调**时间戳的正确性/路径安全性**，不重复变量污染部分。）

**修复建议**：用 `wmic`/`powershell` 取时间，并且**不要** `%OUT: =0%`；若确需去空格，应只对时间戳变量做替换，而不是对整条路径：
```bat
for /f "delims=" %%t in ('powershell -NoProfile -Command "Get-Date -Format yyyyMMdd_HHmmss"') do set "TS=%%t"
set "OUT=%~dp0LOGS_%TS%"
mkdir "%OUT%" 2>nul || (echo [FAIL] cannot create "%OUT%" & pause & exit /b 1)
```

---

## A-16 [中] 4 个抓取脚本：`mkdir ... 2>nul` 与 `cd /d` 都**不检查返回值**，失败时相对路径的输出文件静默落到脚本目录

**现象**
```
current_display.bat:19-20       mkdir "%OUT%" 2>nul   /  cd /d "%OUT%"
disp_continuous_monitor.bat:19-20
备用脚本/monitor.bat:18-19
（备用脚本/capture_disp_log.bat:17 只 mkdir，不 cd，全部用 "%OUT%\..." 绝对路径——这一处反而是对的）
```

**根因/实测（`probes_A/p_cdcol.bat`）**：先造一个**同名文件** `LOGS_collision`，使 `mkdir` 必然失败：
```
mkdir_rc=[1]
The directory name is invalid.
cd_rc=[1]
cwd=[D:\Desktop\debug_temp\bat脚本\analysis\probes_A]      ← 没切走
LANDED_IN_SCRIPT_DIR                                        ← 输出落到了脚本目录
```
即：`mkdir` 失败 → `cd /d` 失败 → **`cd` 默默停在原目录**，此后 `L24` `adb logcat -d ... > logcat_all_before.txt` 全部写进**脚本所在目录**，与真正的 `LOGS_*` 目录混在一起。而脚本最后仍打印 `Done! Logs saved to: %OUT%`（`L88`）——指向一个空目录。

**注意（易错点，已复核）**：`mkdir` 对"已存在目录"返回 **1**，对"已存在同名文件"也返回 1；而 `cd /d` 到**不存在的盘符**（`Z:\...`）实测**返回 0 且 `%cd%` 显示该路径**（`probes_A/p_cdfail2.bat`：`cd_err=[0] cwd=[Z:\no_such_volume\LOGS_x]`）——这是因为 `cd /d` 只改**逻辑当前目录**字符串，不校验物理存在性。所以"不检查 `cd` 返回值"这个问题比看起来更隐蔽：`cd` 往往返回 0。

**修复建议**
```bat
mkdir "%OUT%" 2>nul
if not exist "%OUT%\" ( echo [FAIL] cannot create "%OUT%" & pause & exit /b 1 )
cd /d "%OUT%" || ( echo [FAIL] cannot enter "%OUT%" & pause & exit /b 1 )
pushd "%OUT%" || (echo [FAIL] & exit /b 1)    :: pushd 更可靠，且结尾 popd
:: 建议用 pushd/popd 而不是 cd，避免污染调用者的 CWD
```

---

## A-17 [中] power-key.bat:19,22 — 循环体里的两条 `adb shell input keyevent` 完全不判退出码；固定 100 次、每次 15 秒 ≈ 25 分钟，中途掉线不会被发现

**现象**
```bat
5|  set max=100
9|  if %i% gtr %max% goto end
19| adb shell input keyevent 26
22| adb shell input keyevent 26
```

**根因**：无 `errorlevel` 判定、无 `adb get-state` 预检查、无重试。`grep -c -E "errorlevel|&&|\|\|" power-key.bat` = **0**。

**影响**：设备 USB 掉线后，`adb shell` 每次返回 `error: no devices/emulators found`（rc=1）被忽略，脚本**照常跑满 100 轮**、`timeout` 照常等 15 秒，累计空转 **25 分钟**后才打印 `脚本执行完毕，共运行 100 次`——用户以为"压测跑完了"，实际一次都没点。对"按键唤醒稳定性"这类测试，**结论直接作废**。

**修复建议**
```bat
:loop
if %i% gtr %max% goto end
adb get-state >nul 2>&1 || (echo [ABORT] device lost at iteration %i% & goto end)
adb shell input keyevent 26
if errorlevel 1 (echo [ABORT] keyevent failed at %i% & goto end)
...
:end
echo 完成 %i% / %max% 次（若中断，i 会小于 max）
```
并把 `%max%` 改成命令行可传：`if not "%~1"=="" set "max=%~1"`。

---

## A-18 [中] PM_GPIO_CTRL-mimo.bat:534-597 — gpiod 回退路径拿"18 条线"当唯一指纹，多 chip 时可能选错；`gpioset` 的语义与 `set_dir_gpiod_out` 的"保持电平"注释不符

**现象**
```
757| for /f "tokens=1" %%c in ('call adb shell gpiodetect 2^>nul ^| findstr /l /c:"(18 lines)"') do if not defined chip set "chip=%%c"
```
```bat
538| set /a "gline_no=n-1"
544| call adb shell "gpioset !chip! !gline_no!=!out_bit!"
```
```bat
587| call adb shell "gpioset !chip! !gline_no!=!lvl!"
589| echo       direction = OUTPUT   level kept = !lvl!
```

**根因**
1. `:find_chip` 用"行数=18"识别 PMIC chip。`grep` 全仓无其他识别条件（未用 `pinctrl-`/chip label）。若 SoC 上有**另一个也是 18 线的 gpiochip**（例如某些 `gpio-keys` 聚合 chip），`if not defined chip` 会取**第一个**匹配——顺序由 `gpiodetect` 输出决定，不可控。
2. `gpioset <chip> <line>=<value>` 在 libgpiod v1 中是**一次性请求后立即释放**（除非加 `--mode=wait`），释放后引脚回到默认态。脚本 `L589` 声称 `level kept`（电平保持），但 `gpioset` 的默认行为**不保证保持**；`L544` 的 `apply_level_gpiod` 同理（它自己也承认 `L550` "gpiochip has no output readback"）。
3. `L757` 的 `findstr /l /c:"(18 lines)"` 依赖 `gpiodetect` 的**英文单复数与格式**：libgpiod v1 输出 `gpiochip2 [pinctrl-msm] (18 lines)`；**libgpiod v2 已改为 `gpiochip2 [pinctrl-msm] 18 lines`（无括号）**。实测（`probes_A/clean/v7.bat`，用与 v1 同格式的 stub 文本）：
   ```
   [T1] findstr /l /c:"(18 lines)"  → 命中 gpiochip2 [pinctrl-msm] (18 lines)   rc=0
   [T2] for/f 同 pattern            → chip=[gpiochip2]
   ```
   即**在 v1 上是对的**；但换成 v2 设备就永远找不到 chip → `L758 if not defined chip exit /b 1` → `:step_error`（`L657`）。这不是"当前就坏"，是**硬编码了 libgpiod 版本**。

**影响**：`set_drive` 走 gpiod 时直接给 `exit /b 3`（`L616`，这是**正确的降级**，见 A-19）；但 `apply_level` / `set_dir` 走 gpiod 时会**选错 chip 或设完即失效**，而脚本打印 `OK via gpioset`。

**修复建议**
```bat
:: 1) 用 chip 名做二次确认，而不是只看行数
for /f "tokens=1,2" %%c in ('call adb shell gpiodetect 2^>nul ^| findstr /i "18"') do (
    if not defined chip set "chip=%%c"
)
adb shell "gpioinfo !chip!" | findstr /i "pinctrl" >nul || (set "step=Find PMIC gpiochip" & goto step_error)

:: 2) 需要"保持"就用 wait 模式或改用 gpio 的 debugfs 值（但可写性同样受限）
::    gpioset --mode=wait !chip! !line!=!val!   ← 会阻塞，不适合批处理
::    更稳的做法：明确告知用户 gpiod 模式不保持，输出改成 WARN 而不是 OK
```

---

## A-19 [中] PM_GPIO_CTRL-mimo.bat:160-161,317,668,616 — 退出码契约 `0/1/2/3` 名义上自洽，实际**漏了"交互模式"和"根因不可区分"两个缺口**

**现象**
```bat
160| echo   exit code: 0 ok, 1 failed, 2 bad usage, 3 unsupported here
161| exit /b 2
```
```
317| if defined cli exit /b 0      (apply_level 成功)
394| if defined cli exit /b 0      (set_dir 成功)
429| if defined cli exit /b 0      (set_drive 成功)
529| if defined cli exit /b 0      (read_status 成功)
553| if defined cli exit /b 0      (apply_level_gpiod 成功)
577| if defined cli exit /b 0      (set_dir_gpiod INPUT 成功)
595| if defined cli exit /b 0      (set_dir_gpiod OUTPUT 成功)
653| if defined cli exit /b 0      (read_status_gpiod 成功)
616| if defined cli exit /b 3      (set_drive 不支持)
668| if defined cli exit /b 1      (任何 step_error)
675| exit /b 0                    (:exit_program, 交互菜单 Q/0)
```

**逐条核对结果**
| 路径 | 承诺 | 实际 | 结论 |
|---|---|---|---|
| 成功（cli 模式，8 处） | 0 | `exit /b 0` | ✅ 一致 |
| 参数错（`cli_usage`） | 2 | `L161 exit /b 2` | ✅ 一致 |
| 失败（`step_error`） | 1 | `L668 exit /b 1` | ⚠️ "失败"把**设备未连接 / regmap 不存在 / 内核拒绝写 / 回读为空**全部压成 1（K8s 式调用方无法区分） |
| 驱动能力不支持 | 3 | `L616 exit /b 3` | ✅ 一致 |
| **交互模式非 0 退出** | 契约未定义 | `L95/L228/L256` 的 `pause >nul` 后 `goto`，**永不返回**；`L318/L395/L430/L530/L554/L578/L596/L617/L654/L669` 的 `pause` 后 `goto`，同样永不返回 | ❌ 交互模式**没有任何退出码语义**——但它又是默认入口（`L60` 无参数时进菜单） |
| **交互模式按 Q** | 契约未定义 | `L675 exit /b 0` | ⚠️ 用户主动取消也报"成功" |

**根因**：`if defined cli` 守卫只覆盖 `cli` 模式；交互模式下脚本是"永远循环"的 UI。而 `cli` 模式一旦进入，任何**未预期的交互**（如 stdin 是终端时的误触）都会因为 `cli` 已定义而 `exit /b 0`（见 A-20）。

**影响**：CI/自动化只能得到"1"，无法区分"没设备"（应重试）与"寄存器不可写"（应换设备/换内核）。这是**契约层面的信息丢失**。

**修复建议**
```bat
:: 细分退出码（保持向后兼容：非 0 仍是失败）
:: 0 ok / 1 generic / 2 usage / 3 unsupported / 4 no device / 5 no regmap / 6 write rejected
:step_error
if /i "!step!"=="ADB device check"          if defined cli exit /b 4
if /i "!step!"=="Detect available register interface" if defined cli exit /b 5
if /i "!step!"=="Read back"                 if defined cli exit /b 6
if defined cli exit /b 1
```
交互模式则在 `Q/0` 时统一 `exit /b 0`（现状 OK），但应在 `L160` 的 usage 里**显式写明"交互模式无退出码契约"**。

---

## A-20 [低] PM_GPIO_CTRL-mimo.bat:100 + 317 — `cli` 是普通环境变量（非 `setlocal` 私有作用域之外的防污染变量），父进程若已 `set cli=1`，交互菜单会立刻被当成命令行模式并 `exit /b 0`

**现象**
```bat
2|   setlocal enabledelayedexpansion
...
100| set "cli=1"
317| if defined cli exit /b 0
```

**根因**：`setlocal`(L2) 只隔离**本脚本对外的污染**，不隔离**从父进程继承进来的**变量。若调用者环境里已有 `cli`（很常见的通用名），`L60 if not "%~1"=="" goto cli_args` 仍走交互分支，`cli` 保持父进程的 `1`，于是 `L317` 判定为 cli 模式。

**实测（`probes_A/p_e2.bat` + `child_env.bat`）**
```
父: set "cli=1"
子: child_cli_defined=[1]   ← 子脚本里 !cli! 已存在
```

**影响**：用户在交互菜单里按 `Y` 设电平，脚本执行完直接 `exit /b 0`，**菜单消失、窗口关闭**，没有任何提示。用户会认为"脚本崩了"。

**修复建议**：进交互分支时显式清除：
```bat
:select_gpio
set "cli="            :: 交互模式，清掉可能被继承的 cli
```
同样地，`:detect_iface`(L746 `if defined iface exit /b 0`)、`:find_chip`(L755 `if defined chip`)、`:reg_fmt_detect`(L724 `if defined regfmt`) 的缓存变量也都会被父环境"预置"——若父进程恰好定义了 `iface`/`chip`/`regfmt`，探测会被整体跳过。建议统一加 `FOR_` / `PM_` 前缀。

---

## A-21 [低] PM_GPIO_CTRL-mimo.bat:727 — `:reg_fmt_detect` 内部 `if errorlevel 1 exit /b 0`：探测失败被吞掉，`regfmt` 停在默认 `hex`，后续解析按错误格式进行

**现象**
```bat
723| :reg_fmt_detect
724| if defined regfmt exit /b 0
725| set "regfmt=hex"
726| call :reg_read !OFF_TYPE!
727| if errorlevel 1 exit /b 0
728| if /i "!read_raw:~0,2!"=="0x" exit /b 0
729| if "!read_raw!"=="16" set "regfmt=dec"
730| if "!read_raw!"=="10" set "regfmt=hex"
731| exit /b 0
```

**根因**：`L727` 在"读 TYPE 失败"时返回**成功（0）**，把 `regfmt` 留在 `hex`。而两个调用点（`L334`、`L411`、`L443`）都**没有检查** `:reg_fmt_detect` 的返回值（它们紧接着就 `call :reg_read`）。

**影响**：若设备的 `data` 文件读回是**十进制**（`regfmt` 本应为 `dec`），但 `TYPE` 那一次读失败，`regfmt` 会停在 `hex` → `:reg_parse`(L714) 给值拼上 `0x` 前缀 → `set /a "read_num=0x16"` = 22（而实际十进制 `22`）——**恰好对上**？不对：若读回是十进制 `128`，拼成 `0x128` = 296，**位运算全部错位**。

**修复建议**：让探测失败成为真失败，或至少打印警告：
```bat
:reg_fmt_detect
if defined regfmt exit /b 0
set "regfmt="
call :reg_read !OFF_TYPE!
if errorlevel 1 ( echo [WARN] cannot read TYPE, data format unknown & set "regfmt=hex" & exit /b 1 )
...
```

---

## A-22 [低] 备用脚本/capture_disp_log.bat:36 + disp_continuous_monitor.bat:84 — `adb bugreport "绝对路径"` 用了 `%OUT%`（正确），但 `cd` 之后 `%OUT%` 已含尾部 `\`，与 `L20` 的 `cd /d` 形成"双保险其实只有一重"

**现象**
```bat
36| adb bugreport "%OUT%\bugreport.zip"      (capture_disp_log.bat)
84| adb bugreport "%OUT%\bugreport.zip"      (disp_continuous_monitor.bat)
```
`%OUT%` 由 `L8 set "OUT=%~dp0LOGS_%date%_%time%"` 生成，**不带尾随反斜杠**（`%~dp0` 带，但后面拼了 `LOGS_...`）。所以 `"%OUT%\bugreport.zip"` 是**正确**的双反斜杠写法——这一点没问题（B 组已单独澄清）。

**A 组要补充的是**：`bugreport` 是**整条流程里最慢的一步**（`L83` 自己写"1-3 minutes"），而它**没有超时、没有失败判定、没有"磁盘不足"预检查**。`bugreport.zip` 会先写进 `%TEMP%` 再复制，`L84` 不检查 `errorlevel`，静默失败时脚本仍打印 `Done!`。

**影响**：磁盘紧张时 `bugreport.zip` 是**截断的**（本次 6.7 MB 完整，属环境宽裕）。更隐蔽的是：`bugreport` 期间 `adb` 会持续拉取，若此时后台 `logcat` 窗口还在跑（A-01），两者共享 adb 连接，**可能互相拖慢甚至超时**。

**修复建议**
```bat
echo Generating bugreport (1-3 min)...
adb bugreport "%OUT%\bugreport.zip"
if errorlevel 1 ( echo [WARN] bugreport failed or truncated & del /q "%OUT%\bugreport.zip" 2>nul ) else (
    for %%z in ("%OUT%\bugreport.zip") do if %%~zz LSS 100000 echo [WARN] bugreport suspiciously small (%%~zz bytes)
)
```

---

## A-23 [低] disp_continuous_monitor.bat:45,47 — 两个"功能开关"被注释掉且无说明，其中 `logcat -c` 的缺失直接导致 A-09

**现象**
```bat
45| ::start "GetEvent" cmd /c "adb shell getevent -tlr > getevent.log 2>&1"
47| ::adb logcat -c -b all
```

**根因**：推测是为"保留复现前的上下文"而关掉清缓冲，但**没有任何注释说明**，而同源脚本 `备用脚本/monitor.bat:28` 却**保留了** `adb logcat -c -b all`。两个脚本在这点上行为相反。

**影响**：`logcat.txt` 从 buffer 里**已有的全部历史**开始写（本次 78 MB 大部分是历史 + 复现期间增量），事后无法区分"复现前"与"复现中"，`before`/`after` 快照的意义被削弱。

**修复建议**：显式二选一并写清理由：
```bat
:: 方案 A（推荐）：保留上下文，靠 before/after 快照切分 —— 那就把 L47 删掉并注释
:: 方案 B：只要复现期间 —— 取消 L47 注释，并在 L49 之前执行
adb logcat -c -b all
start "Logcat" cmd /c "adb shell logcat -b all -v threadtime > logcat.txt 2>&1"
```

---

## A-24 [低] 备用脚本/monitor.bat:37,40 — `pause >nul` + 裸 `exit`：成功路径与失败路径都无法被调用者感知，且 `exit` 会关掉整个 cmd.exe（含调用者）

**现象**
```bat
36| :: ========== 5. 阻塞等待手动停止 ==========
37| pause >nul
39| :: 优雅退出整个脚本，防止残留
40| exit
```

**根因/实测（`probes_A/p_exit_scope.bat` + `child_exit.bat`）**
```
=== bare exit inside called child ===
caller-before
child-running
                                  ← 调用者的 "caller-after" 和 "PARENT_CMDLINE_STILL_ALIVE" 都没打印
=== exit /b inside called child ===
caller-before
child-running
caller-after-EXIT_B_OK
PARENT_CMDLINE_STILL_ALIVE
```
即：裸 `exit` 会**连同调用者的 cmd.exe 一起关掉**。`L39` 的注释写"防止残留"，但它防的是**自己这个窗口**，代价是调用者也被杀。

**影响**：用户若在另一个 `.bat` 里 `call 备用脚本\monitor.bat`，外层脚本会被中途杀掉；`disp_continuous_monitor.bat:90` 同样是裸 `exit`。两者都**没有任何清理残留子进程的代码**（A-01），所以"防止残留"这个注释是**名不副实**。

**修复建议**
```bat
pause >nul
echo Stopping capture...
taskkill /FI "WINDOWTITLE eq Logcat*" /F >nul 2>&1
taskkill /FI "WINDOWTITLE eq Dmesg*"  /F >nul 2>&1
taskkill /FI "WINDOWTITLE eq GetEvent*" /F >nul 2>&1
exit /b 0
```

---

## A-25 [低] push_apk.bat:28 / push_msm_drm_ko.bat:27 — `adb reboot` 不判退出码，`L29` 照样打印 `OK: Reboot command sent. Script finished.`

**现象**
```bat
27| echo [7/7] Rebooting device...
28| adb reboot
29| echo       OK: Reboot command sent. Script finished.
30| pause
```

**根因**：`adb reboot` 的 `errorlevel` 未检查。设备掉线/多设备/权限不足时，这条只是把错误打到 stderr。

**影响**：用户在"以为已经重启"的状态下拔线/断电，下次连上发现 `msm_drm.ko` 还是旧的（因为 `push` 其实也没成——见 A-11/A-12）。**7 步流程里第 7 步失败最容易被忽略，因为它恰好是"收尾"**。

**修复建议**
```bat
adb reboot
if errorlevel 1 ( echo       FAIL: reboot failed - do NOT unplug, check "adb devices" & pause & exit /b 1 )
echo       OK: Reboot sent. Wait ~60s, then verify:
echo            adb shell ls -l /vendor_dlkm/lib/modules/msm_drm.ko
```

---

## A-26 [低] 全仓：9 个脚本中 6 个没有任何 `errorlevel` 校验，失败一律静默；「成功文案」是唯一的反馈通道

**现象（机械统计）**
```
PM_GPIO_CTRL-mimo.bat        adb=23  errorlevel/&&/||=40
auto_shot.bat                adb=6   errorlevel/&&/||=0
current_display.bat          adb=13  errorlevel/&&/||=0
disp_continuous_monitor.bat  adb=31  errorlevel/&&||=0
power-key.bat                adb=3   errorlevel/&&||=0
push_apk.bat                 adb=8   errorlevel/&&||=4
push_msm_drm_ko.bat          adb=7   errorlevel/&&||=4
备用脚本/capture_disp_log.bat adb=11 errorlevel/&&||=0
备用脚本/monitor.bat         adb=6   errorlevel/&&||=0
```

**影响**：4 个抓取脚本合计 **61 条 adb 调用、0 条校验**，而它们的结尾统一是 `Done! Logs saved to: %OUT%`。**产出一堆空文件也报成功**——这是这批脚本最大的共性问题，也是"结论必须带行号"之外最值得写进汇总的一条。

**修复建议**：加一个通用的包装子程序，所有 adb 调用走它：
```bat
:: call :run adb shell dumpsys display > dumpsys_display_before.txt
:run
%~*
if errorlevel 1 ( echo [WARN] command failed: %~* & set /a FAILS+=1 )
exit /b 0
```
结尾统一：
```bat
if defined FAILS (echo [WARN] %FAILS% command^(s^) failed - logs may be incomplete) else (echo [OK] all captures succeeded)
```

---

## 附 A：A 组复核过的"已知线索"（结论：一条成立、一条已纠偏）

| 线索 | 复核结论 | 证据 |
|---|---|---|
| "日志类脚本的 before/after 快照与实时抓取可能写在同一目录" | **成立**，且比线索更严重：不只是同目录，**`logcat_all_before.txt` / `logcat.txt` / `logcat_all_after.txt` 三者时间跨度 57 分钟，且 `logcat.txt` 是"从 buffer 开头 + 实时增量"的混合体**，无法用文件边界切分复现窗口 | `LOGS_20261103_1015/` 的 `stat`：`logcat_all_before.txt` 10:15:13 / `logcat.txt` 11:12:51 / `logcat_all_after.txt` 11:12:55；`logcat.txt` 末尾 `^C` |
| "PM_GPIO 脚本存在 regmap 接口探测分支" | **成立**：`:detect_iface`(L745-751) 用 `[ -e /d/regmap/1-00/address ]` 二选一，REG_MAP → 寄存器模式，否则 GPIOID → gpiod 模式；`L269/L330/L407/L442` 四处分发。**但探测结果被全局缓存在 `iface` 里（L746），且 `iface` 无前缀、可被父环境预置**（A-20） | `grep -n "iface" PM_GPIO_CTRL-mimo.bat` = L269,330,407,442,746-751 |
| （B 组线索）`findstr /l /c:"(18 lines)"` 在 `for /f` 里可能失效 | **不成立**——实测在 libgpiod **v1** 输出格式下完全正常（`probes_A/clean/v7.bat`：`chip=[gpiochip2]`）。真正的问题是它**硬编码了 v1 的格式**，v2（`18 lines` 无括号）会失效，见 A-18 | `probes_A/clean/v7.bat` 输出；`probes_A/clean/v6.bat` 的 T4 证实 `/c:"(18 lines)"` 在**无括号文本**上不匹配（符合预期，非 bug） |

## 附 B：A 组条目优先级建议（交给汇总用）

**必须写进汇总（阻断/高）**
1. A-01 后台抓取零清理 + 裸 `exit`（`disp_continuous_monitor.bat:49,51,54,90`；`备用脚本/monitor.bat:25,31,34,37,40`）
2. A-02/A-03 管道吞退出码导致的假判定（`push_apk.bat:6,9`；`push_msm_drm_ko.bat:6,9`）
3. A-04/A-05/A-06 设备预检查不足 + 写入/回读失败被降级为 OK（`PM_GPIO_CTRL-mimo.bat:265,691-694,306-317`）
4. A-07 `set /a` 让"解析失败检测"在 dec 分支下漏检（`PM_GPIO_CTRL-mimo.bat:717-718`）
5. A-09 日志无轮转（`disp_continuous_monitor.bat:47,49`；`备用脚本/monitor.bat:31`）

**建议写进汇总（中）**：A-07、A-08、A-10、A-11、A-12、A-13、A-14、A-15、A-16、A-17、A-18、A-19
**汇总可精简（低）**：A-20、A-21、A-22、A-23、A-24、A-25、A-26（A-26 建议合并成汇总文档里的一句"全局统计"）

---

## 附 C：本轮自纠记录（保证交给汇总的数字可信）

| 初判 | 复核结果 | 处置 |
|---|---|---|
| `dec2hex` 把 `240` 算成 `0x0`，读改写路径必错 | **探针 bug**（探针里 `read_num_b` 没被赋值，直接用了空值）。子程序对 0-16777215 全对 | A-08 从"高"降为"中"，只保留"高位为 1 时产脏值"这一条；正文加分节说明 |
| `logcat.txt`/`dmesg.log` 当前仍有残留进程在写 | **当前没有**（mtime 停在 11:12:51/11:12:52，实测 30 秒无增长） | A-01 改为"人工 Ctrl+C 收的尾，缺陷在于**依赖人工**"；"子进程可脱离父脚本存活"改由探针证据支撑 |
| `findstr /l /c:"(18 lines)"` 在 `for /f` 里失效（B 组存疑项） | **不成立**：在 libgpiod v1 输出格式下完全正常（`probes_A/clean/v7.bat` → `chip=[gpiochip2]`） | 附 A 表格中明确写"不成立"；A-18 改为"硬编码 v1 格式，v2 会失效" |
| `exit /b` 写在 `( ... & exit /b 1 )` 括号组里会失效 | **不成立**：实测正常终止整个脚本（`probes_A/p_final.bat`） | A-03 中明确写"这一点没问题"，只保留 pause 阻塞与管道吞码两个真问题 |
| `%OUT: =0%` 会改坏路径 | **成立**且已实测（`D:\a b\LOGS_x` → `D:\a0b\LOGS_x`） | 保留在 A-15 |
| `cd /d` 失败会返回非 0 | **部分不成立**：`cd` 到不存在的盘符返回 **0**（`probes_A/p_cdfail2.bat`）；到"同名文件被占"的目录才返回 1 | A-16 中如实写出两种情形 |
