# BAT 脚本静态审计分析报告

> **审计对象**：`D:\Desktop\debug_temp\bat脚本` 下全部 9 个 `.bat`（含 `备用脚本\` 子目录）
> **审计方式**：纯静态阅读 + 本地 cmd 语义探针（探针脚本位于 `analysis/probes_doc/`，只 `echo` 文本，**不含任何 adb 命令**）
> **报告日期**：2026-11-03

---

## 0. 阅读须知

### 0.1 约束声明（务必先读）

**本次为纯静态分析：未连接任何设备、未执行任何 `adb` 命令、未运行被审计的任何一个 `.bat`、未修改任何 `.bat` 文件。**

- 9 个 `.bat` 的修改时间（mtime）在审计前后保持原值，未被触碰。
- 本报告所有"实测"结论，均来自 `analysis/probes_doc/` 下自建探针脚本与 stub 文本对 **cmd.exe 语义**的复现（例如用 `echo` 打出一段假 adb 输出，再验证管道/退出码/`findstr` 行为），**不是**在真机或真 adb 上跑出来的。
- 凡是必须真机才能定论的点，一律归入 **第 5 章 待确认项**，不写进正文结论。
- `LOGS_20261103_1015\` 目录是本次审计之前的历史产物，**不作为脚本缺陷的因果证据**；全文共引用它 5 处，全部是只读的大小/末字节抽样（未读内容）：`L33`（§0.3 说明产物量级）、`L93`（BLK-01 用末两字节 `0x5E 0x43` 即 `^C` 作为"停止动作由人手完成、脚本自己没有任何停止代码"的旁证）、`L237`（H-03 的量级描述，已就地标注"不是脚本缺陷证据"）、`L1637`（Q-09 明确指出比例未知、结论不依赖它）。

### 0.2 严重度定义

| 级别 | 定义 | 判定要点 |
|---|---|---|
| **阻断** | 脚本**结构上不存在**任何防呆/回收机制，正常使用路径上就会造成不可逆的资源损害，且损害是**累积的、使用者无法自检**的 | 全表**仅 1 条**（见 BLK-01） |
| **高** | 会**静默**产出错误结果，或把失败**误判为成功** | 使用者看输出看不出来，会据此做出错误决策 |
| **中** | 不可靠或维护困难 | 会失败、但失败可见；或每次修改都要改多处 |
| **低** | 风格、可读性、一致性问题 | 不影响功能 |

> 严重度不按"改起来费不费劲"衡量，而按"出错时使用者会不会被骗"衡量。这是本报告压制严重度通胀的原则：全表只有 1 条阻断，其余最高为高。
>
> **关于"阻断"的边界（本轮复核补充说明，避免分级自相矛盾）**：BLK-01 的进程残留**确实需要"使用者忘了关窗口"这个条件**才发生——严格按"必然 + 完全不可规避"读，它够不上"阻断"。本报告仍判它为阻断，理由是三条同时成立、且互相放大：①脚本里**没有任何一行**回收代码（全仓 grep 零命中），也没有任何超时/上限，使用者唯一的止损手段是**人工去点那两个窗口**；②脚本只打印一句"复现结束后需要手动关闭 Logcat/Dmesg 窗口"（`disp_continuous_monitor.bat:41`），**既不提示文件会无限增长、也不提示忘关的后果**，使用者无法从脚本行为自检；③损害是**累积且不可逆**的（磁盘写满 → 后续 `bugreport.zip` 截断 → 整轮 before/after 基线作废）。换言之：它落在"谨慎可规避、但脚本从不告知需要谨慎"的区间，本报告按"能否被使用者察觉"而非"是否需要额外动作"来定级。

### 0.3 现场产物的量级（只作背景，不作证据）

审计前已存在的 `LOGS_20261103_1015\` 目录中（只做了只读的大小/尾部抽样，未读全文）：

| 产物 | 大小 | 末两字节 |
|---|---|---|
| `logcat.txt` | 78,973,584 字节（约 75 MB） | `0x5E 0x43`（即 `^C`） |
| `dmesg.log` | 1,783,230 字节（约 1.7 MB） | `0x5E 0x43`（`^C`，前置 `0d 0d 0a 0d 0a`） |
| `bugreport.zip` | 6,705,875 字节 | — |

这两个 `^C` 不是脚本写进去的，是**人手在子窗口按 Ctrl+C** 留下的。这一点是 BLK-01 的关键背景：**脚本自己从来没有"停止抓取"的代码**。请注意：该目录是本次审计之外的历史产物，其体积只能说明"量级"，脚本"无上限"这个缺陷本身由代码（`disp_continuous_monitor.bat:49`）直接证明。

---

## 1. 总览

### 1.1 脚本清单

| # | 文件 | 行数 | 用途 | 严重度 |
|---|---|---|---|---|
| 1 | `disp_continuous_monitor.bat` | 90 | 复现前后 dumpsys/logcat 双快照 + 实时 logcat/dmesg + 截图 + bugreport | **阻断** |
| 2 | `备用脚本\monitor.bat` | 40 | 同上精简版：getevent + logcat + dmesg 三路实时抓取 | **阻断**（与 #1 同属 BLK-01） |
| 3 | `current_display.bat` | 40 | 单次终点快照（无 before 基线） | 高 |
| 4 | `备用脚本\capture_disp_log.bat` | 45 | 一次性抓包（logcat/dmesg/dumpsys/bugreport） | 高 |
| 5 | `push_apk.bat` | 30 | 推 `FrameworksResOverlay_Wear.apk` 到 `/vendor/overlay`，7 步带 reboot | 高 |
| 6 | `push_msm_drm_ko.bat` | 29 | 推 `msm_drm.ko` 到 `/vendor_dlkm/lib/modules`，7 步带 reboot | 高 |
| 7 | `PM_GPIO_CTRL-mimo.bat` | 766 | PMIC GPIO1–18 电平/方向/驱动强度调试（regmap 与 gpiod 双路径，交互菜单 + 命令行） | 高 |
| 8 | `auto_shot.bat` | 48 | 相机自动连拍并 `adb pull` 回本机 | 中 |
| 9 | `power-key.bat` | 31 | 电源键压测 100 轮（开/关屏各 1 次 + 15 秒间隔） | 中 |

（行数为按 CRLF 切分后的物理行数。9 个文件编码：`PM_GPIO_CTRL-mimo.bat` 为 **GBK** 且无 `chcp`，`power-key.bat` 为 **UTF-8** 且无 `chcp`，其余 7 个为 UTF-8/纯 ASCII 且都声明了 `chcp 65001`；全部 CRLF、全部无 BOM。）

### 1.2 一句话结论

**这批脚本"能跑通"和"跑对了"是两件互不相关的事**——4 个日志抓取脚本合计 59 条 `adb` 调用、**0 处退出码校验**，2 个 push 脚本的"成功判定"用的是 `findstr` 而非退出码，1 个 GPIO 脚本在"内核拒绝写入"时依然打印 `applied OK`；因此**失败时它们几乎一律报成功**，唯一的真实反馈来自使用者自己盯着屏幕看。最危险的不是任何单点 bug，而是"脚本的自信程度"与"脚本实际的可信程度"严重不匹配。

---

## 2. 问题清单

> 每条固定五段式：**现象 → 位置 → 根因 → 影响 → 修复建议**。
> 所有行号均以磁盘上的实际文件为准（GBK 文件按原字节逐行核对后编号）。
> 修复片段可直接替换，但请先备份。

### 2.1 阻断（1 条）

#### BLK-01 后台抓取子窗口零回收：脚本没有任何"停止抓取"的代码，父脚本裸 `exit` 且不清理

- **现象**
  - `disp_continuous_monitor.bat:49` `start "Logcat" cmd /c "adb shell logcat -b all -v threadtime > logcat.txt 2>&1"`
  - `disp_continuous_monitor.bat:51` `start "Dmesg"  cmd /c "adb shell dmesg -w > dmesg.log 2>&1"`
  - `disp_continuous_monitor.bat:54` `pause`（这是全脚本**唯一**的"停止"手段）
  - `disp_continuous_monitor.bat:90` `exit`（裸 `exit`）
  - `备用脚本\monitor.bat:25,31,34` 三处 `start`（GetEvent / Logcat / Dmesg），`:37 pause >nul`，`:40 exit`
  - 而 `disp_continuous_monitor.bat:41` 只是**用文字请用户自己关窗口**：`echo  复现结束后需要手动关闭 Logcat/Dmesg 窗口`

- **位置**：`disp_continuous_monitor.bat:49,51,54,90`；`备用脚本\monitor.bat:25,31,34,37,40`

- **根因**：`start` 起的是**独立子进程**（新的 `cmd.exe`，各自再派生一个 `adb.exe`），与父脚本之间没有任何父子生命周期绑定。父脚本的 `exit` 只结束它自己那个 `cmd.exe`，杀不到别人。`pause` 是**时间闸门**，不是**信号量**——它不具备通知那两个 `cmd /c` 窗口停下来的能力。

  这不是推测，有两条互证：
  1. **代码层**：对全部 9 个 `.bat` 做 `taskkill|kill-server|adb kill|pkill|wmic` 全文匹配，**零命中**（本报告独立复核，匹配数为 0）。也就是说，整个仓库**不存在任何一行回收代码**。
  2. **产物层**：`LOGS_20261103_1015\logcat.txt` 与 `dmesg.log` 的**末两字节都是 `0x5E 0x43`（`^C`）**。`^C` 是终端在收到键盘中断时回显的字符，程序化的 `taskkill`/`pkill` 不会产生它。`dmesg.log` 末尾还是 `0d 0d 0a 0d 0a 5e 43`，被打断在**半个行尾**上——典型的"人手掐断"而非"程序收尾"。

- **影响**
  1. **进程残留（条件性但真实）**：一旦使用者忘了去点那两个窗口，`cmd.exe` + `adb.exe` ×2 会继续往盘里灌，直到磁盘写满；下次运行还会**再叠一份**同名抓取。本地的父子进程探针已证实：父脚本 `exit` 之后，子进程仍持续往同一个文件写入。
  2. **磁盘被吃满**：`logcat.txt` 无上限（见 H-03），单次 75 MB 量级；写满后 `bugreport.zip`（`disp_continuous_monitor.bat:84`）会生成**截断的 zip**，`logcat_all_after.txt`（`:58`）也会截断——**基线/终点快照对不齐，整轮分析作废**。
  3. **"停止时刻"不可复现**：日志的结束时间取决于人手速，不取决于复现结束时间，`before`/`after` 的窗口边界无从切分。
  4. 本项与 **M-01（裸 `exit`）**、**H-03（无轮转）** 三者互锁，是本报告唯一判为**阻断**的组合。

- **修复建议**：把"停止"从"人工关窗口"改成"脚本主动收尸"，并给日志加轮转。

  ```bat
  :: ---- 替换 disp_continuous_monitor.bat:49 / :51 ----
  :: 用 adb 客户端侧轮转，单份 64 MB、最多 16 份（写 .1 .2 ... .15 到当前目录）
  start "Logcat" cmd /c "adb logcat -b all -v threadtime -n 16 -r 65536 > logcat_main.txt 2>&1"
  start "Dmesg"  cmd /c "adb shell dmesg -w > dmesg.log 2>&1"

  :: ---- 替换 :54 的 pause ----
  echo.
  echo  复现结束后按任意键 -> 脚本会自动停止抓取并保存终点快照
  pause >nul

  echo Stopping background capture...
  :: 双保险 1：杀掉本机侧窗口（按窗口标题匹配，比按 PID 稳，因为 cmd /c 会再派生 adb）
  taskkill /FI "WINDOWTITLE eq Logcat*" /F >nul 2>&1
  taskkill /FI "WINDOWTITLE eq Dmesg*"  /F >nul 2>&1
  taskkill /FI "WINDOWTITLE eq GetEvent*" /F >nul 2>&1
  :: 双保险 2：断掉设备端进程，避免"PC 端杀了、设备端还在灌"
  adb shell "pkill -f 'logcat -b all'" >nul 2>&1
  adb shell "pkill -f 'dmesg -w'"      >nul 2>&1
  timeout /t 2 /nobreak >nul
  ```

  `备用脚本\monitor.bat` 同理：把 `:37 pause >nul` 之后、`:40 exit` 之前插入同一段 `taskkill`，并把 `:40` 的 `exit` 改为 `exit /b 0`（见 M-01）。

---

### 2.2 高（9 条）

#### H-01 `set "OUT=%OUT: =0%"` 把**路径里的空格**也替换成 `0`：脚本目录一旦含空格，日志静默写进"影子目录"

- **现象**：抓取四件套都用这行给"个位数小时"补零，但 `%OUT%` 此刻**已经包含 `%~dp0` 的完整绝对路径**：

  ```bat
  set "OUT=%~dp0LOGS_%date%_%time%"
  set "OUT=%OUT: =0%"          ← 全局替换，路径里的空格一起中招
  ```

- **位置**：`current_display.bat:9`、`disp_continuous_monitor.bat:9`、`备用脚本\capture_disp_log.bat:8`、`备用脚本\monitor.bat:9`

- **根因**：`%VAR: =0%` 是**对整个变量值**做子串替换，不区分"哪一段是时间戳"。作者本意只想处理时间戳里的前导空格，但它作用在了拼接完成后的整条路径上。

- **影响**：实测（本地探针，逻辑与源文件逐字相同）

  ```
  输入  D:\p dir with space\LOGS_x
  输出  D:\p0dir0with0space\LOGS_x        ← dir with space 变成 dir0with0space
  ```

  后果链条是**静默的**：`mkdir "%OUT%" 2>nul`（`current_display.bat:19`）会兴高采烈地创建这个**错名字**的目录（返回 0），`cd /d "%OUT%"`（`:20`）也会成功切进去，于是整轮日志写在一个"影子宫格"里，而结尾的 `Done! Logs saved to: %OUT%` 打印的也是这个错路径——**看起来一切正常**。本工作区路径 `D:\Desktop\debug_temp\bat脚本` 恰好不含空格，所以问题一直被掩盖；一旦放到 `C:\Users\张三\My Documents\` 或 `D:\team share\` 下就**会**触发（"必然触发"的前提是脚本目录含空格；目录不含空格时这一行无副作用）。

  > ⚠ **两个必须写清的细节**（本轮补测）：
  > 1. `mkdir` 对含空格的**多级路径会一次建成**（`mkdir "…\p0dir0with0space\LOGS_x"` 返回 0，中间层 `p0dir0with0space` 被自动创建）——所以影子目录**确实会被建出来**，不会因为"父目录不存在"而失败。这一点是 H-01 成立的关键，已实测。
  > 2. 下面"修复建议"第一段用了 `!STAMP!` 延迟展开，**前提是脚本先有 `setlocal EnableDelayedExpansion`**。这 4 个脚本目前**都没有** `setlocal`；若不补，`!STAMP!` 会被当成字面量（实测输出 `LOGS_!STAMP!`），必须与 H-02 的 `setlocal` 一起上。

  > 对照实验已做：在同一台机器上，对"含中文**且**含空格"的目录，去掉这一行 → 目录建在正确位置；保留这一行 → 建到被改名的位置。因此中文与 `chcp 65001` 都不是元凶，**空格替换才是**。

- **修复建议**：**先算时间戳、再拼路径**，替换只作用于纯时间戳变量（顺带把时:分升级为含秒，见 H-02）：

  ```bat
  :: 替换 current_display.bat:6-9（以及另外 3 个脚本的对应行）
  for /f "delims=" %%t in ('wmic os get localdatetime ^| findstr /r "^[0-9]"') do set "DT=%%t"
  set "STAMP=!DT:~0,8!_!DT:~8,6!"        :: yyyymmdd_hhmmss
  set "OUT=%~dp0LOGS_!STAMP!"
  :: 注意：不要再对 %OUT% 做任何替换
  ```

  如果暂时不想动时间戳来源，最小改动是"只替换时间戳、再把结果拼进路径"：

  ```bat
  set "TS=%time: =0%"
  set "OUT=%~dp0LOGS_%date%_%TS%"
  ```

---

#### H-02 覆盖 cmd 内建伪变量 `date` / `time`，且四脚本都没有 `setlocal` → 污染向上泄漏到调用者；目录名同时随代码页漂移

- **现象**

  ```bat
  6| for /f "tokens=2-4 delims=/ " %%a in ('date /t') do set "date=%%a%%b%%c"
  7| for /f "tokens=1-2 delims=: " %%a in ('time /t') do set "time=%%a%%b"
  ```

  `date` / `time` 是 `cmd.exe` 的**动态伪变量**，一旦被 `set`，就变成普通环境变量，`%date%` 从此不再是日期。

- **位置**：`current_display.bat:6-9`、`disp_continuous_monitor.bat:6-9`、`备用脚本\capture_disp_log.bat:5-8`、`备用脚本\monitor.bat:6-9`
  （这 4 个脚本**均无 `setlocal`**；而 `PM_GPIO_CTRL-mimo.bat:2`、`auto_shot.bat:3`、`power-key.bat:2`、`push_apk.bat:3`、`push_msm_drm_ko.bat:3` 都有。）

- **根因（两重）**
  1. 直接复用 `date`/`time` 这两个通用名做自己的变量名，且缺少 `setlocal` 隔离。
  2. **先 `chcp 65001` 再解析 `date /t`**（`chcp` 在 L2，解析在 L6）。中文 Windows 下 `date /t` 的输出形态会随代码页改变 token 位置。实测对照：

     | 代码页 | `date /t` 实际输出 | `tokens=2-4 delims="/ "` 得到 |
     |---|---|---|
     | cp936 | `2026/11/03 周二` | `11` / `03` / `周二` → **`1103周二`**（年份丢失） |
     | cp65001 | `周二 2026/11/03` | `2026` / `11` / `03` → `20261103`（正确） |

     也就是说，这 4 个脚本之所以"看起来对"，是因为它们**先切了 65001**，把周几从尾部搬到了头部，token 才刚好落在年月日上。这是**本机侥幸**：换英文系统（`Tue 11/03/2026`）就变成 `11032026`，年份跑到后面。

- **影响**
  1. **变量泄漏到调用者**：若有人写一个包装脚本 `call current_display.bat`，调用者的 `%date%` / `%time%` / `%OUT%` 会被永久改写；更隐蔽的是 `cd /d "%OUT%"`（`current_display.bat:20`）**也不会被还原**，`call` 返回后调用者的当前目录变成了日志目录。
  2. **目录名跨机器不可预期**：`LOGS_1103周二_1111` 与 `LOGS_20261103_1111` 两种形态并存，后续任何按名字排序/解析的脚本都会错。
  3. 目录名精度只到分钟（`time /t` 只有 `HH:MM`），**同一分钟内连跑两次会写进同一个目录互相覆盖**。

- **修复建议**：用与语言/代码页完全无关的来源取时间，变量加前缀，并补 `setlocal`。

  ```bat
  :: 在 @echo off 之后补一行
  setlocal EnableDelayedExpansion

  :: 用 WMI 取时间（与区域设置、代码页无关，且自带秒）
  for /f "delims=" %%t in ('wmic os get localdatetime ^| findstr /r "^[0-9]"') do set "DT=%%t"
  set "STAMP=!DT:~0,8!_!DT:~8,6!"       :: 20261103_112936
  set "OUT=%~dp0LOGS_!STAMP!"
  ```

  `wmic` 在你机器上的实测输出为 `20261103112936.943000+480`，取前 8 位 + 第 9–14 位即可，不受 `chcp` 影响。若目标是较新的 Windows（`wmic` 已弃用），备选：

  ```bat
  for /f "delims=" %%t in ('powershell -NoProfile -Command "Get-Date -Format yyyyMMdd_HHmmss"') do set "STAMP=%%t"
  ```

---

#### H-03 `logcat` 无轮转、无大小上限，`logcat -c` 清缓冲在 4 个脚本里有 3 个没有（唯一有的那个还被注释在另一个脚本里）

- **现象**
  - `disp_continuous_monitor.bat:49` 实时抓取无任何限量参数：`adb shell logcat -b all -v threadtime > logcat.txt 2>&1`
  - `disp_continuous_monitor.bat:47` 的 `::adb logcat -c -b all` **被注释掉**（无任何说明）
  - `备用脚本\monitor.bat:28` 反而**有** `adb logcat -c -b all`——两个同源脚本在这步行为相反
  - `current_display.bat:24`、`备用脚本\capture_disp_log.bat:20` 直接 `adb logcat -d ... -b all` 全量落盘，同样不清缓冲

- **位置**：`disp_continuous_monitor.bat:47,49`；`备用脚本\monitor.bat:28,31`

- **根因**：`adb shell logcat` 的输出直接重定向到文件，没有 `-n`/`-r`/`-G` 任何限量；也没有先 `logcat -c` 清掉历史缓冲，于是"本次复现期间的日志"和"设备开机以来的历史日志"混在同一个文件里。

- **影响**
  1. **单次运行量级不可控**：现场观察到的产物大小为约 75 MB（`LOGS_20261103_1015\logcat.txt`，**仅指该历史产物的大小，不是脚本缺陷证据**）；缺陷本身由代码直接证明——`disp_continuous_monitor.bat:49` 的重定向没有任何限量参数，所以若复现挂一晚上可到 GB 级。
  2. **`before`/`after` 对比失去意义**：3 个脚本不清缓冲，快照里掺进几十 MB 与本次复现无关的历史日志，无法用文件边界切分复现窗口。
  3. 磁盘写满的连带损害见 BLK-01 影响 2。

- **修复建议**：清缓冲 + 客户端侧轮转 + 显式说明开关。

  ```bat
  :: ---- 把 L47 的注释改成显式开关（二选一，并写清理由）----
  :: 方案 A（推荐）：只保留复现期间 —— 清缓冲后再抓
  adb logcat -c -b all
  :: 方案 B：要保留历史上下文 —— 删掉上行，改为在文件名上区分
  ::   adb logcat -d -b all > logcat_from_boot.txt

  :: ---- 实时抓取改为带轮转（L49）----
  start "Logcat" cmd /c "adb logcat -b all -v threadtime -n 16 -r 65536 > logcat_main.txt 2>&1"
  ```

  `adb logcat -n 16 -r 65536` 表示单份 64 MB、最多 16 份，写 `logcat_main.txt.1` … `.15` 到**当前目录**——因为脚本 L20 已经 `cd /d "%OUT%"`，落点正确。注意：用 `adb logcat`（客户端侧）才有 `-n/-r`；`adb shell logcat` 的这些参数语义不同。

---

#### H-04 `adb root | findstr "restarting"` 取的是 `findstr` 的退出码，不是 `adb` 的——"已 root"和"根本没连设备"输出同一条文案

- **现象**

  ```bat
  6| adb root | findstr /i "restarting" >nul && echo       OK: adbd restarted as root || echo       WARN: Device may already be rooted or not supported
  ```

- **位置**：`push_apk.bat:6`、`push_msm_drm_ko.bat:6`（两处逐字相同）

- **根因**：`cmd` 的 `&&` / `||` 判定的是**管道最后一个命令**（这里是 `findstr`）的退出码。`adb root` 自己的退出码被整条管道吞掉了。于是**四种**完全不同的现实被压成同一个分支：

  | 场景 | `adb` 实际输出 | `findstr` 结果 | 脚本走的分支 |
  |---|---|---|---|
  | 成功 root | 含 `restarting` | 命中（rc=0） | `OK: adbd restarted as root` |
  | 已经是 root | `adbd is already running as root` | 不命中（rc=1） | `WARN: Device may already be rooted...` |
  | **设备没连上** | `error: no devices/emulators found` | 不命中（rc=1） | **同一条 `WARN: Device may already be rooted...`** |
  | `adb` 不在 PATH | （无输出） | 不命中（rc=1） | 同一条 `WARN` |

  （四行输入的分支归属已用 stub 逐条复现，结论与上表一致。）

- **影响**：这是本仓**"用文本匹配冒充退出码判定"这一类问题的原型**（同类还有 H-05 的 `remount | findstr "succeeded"`、H-06 的 `ls | findstr "No such file"`）：四条互不相干的现实汇入同一条无害文案。用户看到 `WARN: Device may already be rooted or not supported`，会理解成"设备在、只是已经 root"，于是继续往下走，然后在 `:9` 的 `adb remount` 处失败；而 `:9` 的失败文案又指向"检查 remount"，把真正原因（根本没设备）埋得更深。排查时间被白白拉长。

- **修复建议**：先判连接、再判 root，全部走退出码，不要走文本匹配。

  ```bat
  :: ---- 替换 push_apk.bat:5-6 / push_msm_drm_ko.bat:5-6 ----
  echo [1/7] Requesting root access...
  adb get-state >nul 2>&1
  if errorlevel 1 (
      echo       FAIL: no device / adb not found. Run "adb devices" first.
      pause & exit /b 1
  )
  adb root >nul 2>&1
  if errorlevel 1 (
      echo       FAIL: "adb root" failed - production build or verity locked.
      echo       Root is REQUIRED for remount. Aborting.
      pause & exit /b 1
  )
  echo       OK: adbd is running as root
  ```

---

#### H-05 `adb remount | findstr "succeeded"`：同款管道吞码，且失败分支把 `pause` 排在 `exit /b` 之前，无人值守必卡死

- **现象**

  ```bat
  9| adb remount | findstr /i "succeeded" >nul && echo       OK: Remount succeeded || (echo       FAIL: Remount failed! & pause & exit /b 1)
  ```

- **位置**：`push_apk.bat:9`、`push_msm_drm_ko.bat:9`（两处逐字相同）

- **根因（两重）**
  1. **管道吞退出码**（同 H-04）：只要 `adb remount` 的输出里出现 `succeeded` 子串就判成功。真实世界里的 remount 失败消息可能长这样：`remount failed: /vendor not remountable, but overlayfs succeeded` —— 含 `succeeded`，**被判为成功**。
  2. **`pause` 在 `exit /b` 之前**：`(echo ... & pause & exit /b 1)` 的执行顺序是先 `pause` 后退出。任何自动化 / CI / 计划任务调用这条脚本，都会在失败时**永久阻塞等人按键**。

- **影响**：`/vendor` 实际不可写时，用户先被 L9 的 `OK: Remount succeeded` 误导，把排查方向带到 `push` 或网络共享上；真正的"分区只读 / verity 未关"被掩盖。

- **修复建议**：判退出码，并把 remount 的完整输出打出来给用户看。

  ```bat
  :: ---- 替换 push_apk.bat:8-9 / push_msm_drm_ko.bat:8-9 ----
  echo [2/7] Remounting filesystem...
  adb remount > "%TEMP%\remount.txt" 2>&1
  if errorlevel 1 (
      type "%TEMP%\remount.txt"
      echo       FAIL: remount failed ^(see the output above^).
      echo       Require: root + "adb disable-verity" + reboot.
      exit /b 1
  )
  echo       OK: Remount succeeded
  ```

  失败分支**不要**放 `pause`。若确实需要"双击运行时停一下"，用开关控制：`if not defined CI pause`。

---

#### H-06 `adb shell ls ... 2>nul | findstr /i "No such file"` 这一整行判定在两个层面上都是坏的：`2>nul` 位置错 + 三个子串 OR

> 这一条把两个互相耦合的缺陷合并叙述，因为它们在**同一行代码**（`push_apk.bat:16` / `push_msm_drm_ko.bat:16`）上叠加，单独修任何一个都不足以让这条判定可信。

- **现象**

  ```bat
  16| adb shell ls /vendor/overlay/FrameworksResOverlay_Wear.apk 2>nul | findstr /i "No such file" >nul && echo       OK: Old file removed || echo       WARN: File still exists or path invalid
  ```

- **位置**：`push_apk.bat:16`、`push_msm_drm_ko.bat:16`（两处逐字相同）

- **根因（两层，彼此独立）**

  **第一层：`2>nul` 写在管道左侧，只吞本机 stderr。** 它的重定向作用域是**它左边那个进程**（`adb.exe`）自身的 stderr；管道只把该进程的 **stdout** 送进 `findstr`。当远端 `ls` 的报错文本是从 stderr 回来的（取决于 adb 版本/实现），这段文本被 `2>nul` 直接丢弃，`findstr` 收不到任何东西 → 永远不命中 → 永远走 `WARN`。实测三分支（stub 复现）：

  | 分支 | 错误文本位置 | 写法 | 结果 |
  |---|---|---|---|
  | A | stdout | `2>nul \| findstr` | 命中（能匹配） |
  | B | **stderr** | `2>nul \| findstr` | **不命中**（误报 WARN） |
  | C | stderr | `2>&1 \| findstr` | 命中（修好后能匹配） |

  **第二层：`findstr /i "No such file"` 是三个子串的 OR，不是整句。** 引号内的空格是**分隔符**，`findstr` 把它当成 `No` **或** `such` **或** `file` 三个 pattern 的并集。实测同一份输入、两种写法对比：

  ```
  输入包含： "No worries mate"
             "failed to copy: No space left on device"
             "error: no devices/emulators found"
  findstr /i "No such file"        → 命中    ← 上面每一行都碰到了 no/such/file
  findstr /i /c:"No such file"     → 不命中  ← 只对真消息命中
  ```

- **影响（⚠ 必须按这个口径理解，不要扩大化）**

  **这条判定匹配的是 `adb shell ls` 的输出（L16），不是 `rm` 的输出。** `rm` 在 `L12`，它的输出根本没有进入这条 `findstr`。因此"`rm` 报 Read-only 也被判成功"这个因果链**不成立**，不要这样写。

  真正成立的误判有两种（**都取决于这段文本走 stdout 还是 stderr，见下方实测矩阵**）：

  1. **`adb` 自身报错被判成"旧文件已删除"**。设备没连上时 `adb` 输出 `error: no devices/emulators found`——这句里含子串 `no`。**若这段文本走本机 stdout**，`findstr /i "No such file"` 直接命中，脚本打印 `OK: Old file removed`，然后继续往下走 `adb push`；用户看到的是"删除成功、正在推送"，完全不知道设备根本没连。
  2. **`ls` 的任何含 `no` / `such` / `file` 的输出都被判成"已删除"**。`ls` 只要回显出这三个词中的任意一个（如 `No space left`、`file exists`、`such file` 之类），就判"删除成功"。

  本轮实测矩阵（`analysis/probes_review/t1..t8.bat`，stub 只 `echo` 固定文本，不含 adb）。它是上面 A/B/C 三行的扩展版，把"三子串 OR"这一层也叠加进来：

  | # | 场景 | 写法 | 结果 |
  |---|---|---|---|
  | t1 | adb 报错在 **stdout** | `2>nul \| findstr /i "No such file"`（脚本原样） | **命中 → 误报 `OK: Old file removed`** |
  | t2 | adb 报错在 **stderr** | 同上 | 不命中（被 `2>nul` 吞掉）→ 走 `WARN` |
  | t3 | adb 报错在 stdout，去掉 `2>nul` | `\| findstr /i "No such file"` | 命中 → 仍误报 |
  | t4 | adb 报错在 stdout，改 `/c:` | `\| findstr /i /c:"No such file"` | 不命中 → **判对了** |
  | t5 | `ls` 回显 `No space left on device`（stdout） | `2>nul \| findstr /i "No such file"` | **命中 → 误报** |
  | t6 | 文件确已删除、`No such file` 在 stdout | 脚本原样 | 命中 → 判对 |
  | t7 | 文件确已删除、`No such file` 在 **stderr** | 脚本原样 | **不命中 → 误报 `WARN`**（方向相反） |
  | t8 | 同 t7，改 `2>&1 \| findstr /i /c:"No such file"` | 修好 | 命中 → 判对 |

  一句话：**这条判定在两种 stderr 实现下各错一半**。走 stdout 时把"没设备 / 无空间"读成"已删除"；走 stderr 时把"确实已删除"读成"文件还在"。哪种实现为真取决于 adb 版本，故列在 Q-01。

  同时，第一层让这条判定在**另一个方向上**也失效：远端错误若走 stderr，即使文件确已删除，也会误报 `WARN: File still exists or path invalid`。

  合起来看：这一步（`[4/7] Verifying old file removal`）是脚本里**唯一**声称"旧文件已经清掉"的检查，而它**既会在文件仍在时报 OK、也会在文件确已删除时报 WARN**——这个检查在语义上已经完全失效，不能作为任何判断依据。

  连带后果分两种：
  - 若 `rm`（`L12`）其实失败、旧文件仍在，而 `push` 成功覆盖，结果无害——但用户已经得不到"rm 失败"的任何提示。
  - 若 `push` 也失败，`L20` 的 `if !errorlevel! neq 0` 能兜住（这点 `push_apk.bat` 做得比其余脚本好）。**唯一的缝隙**是：某些 adb 版本在远端 symlink 场景下 `push` 失败仍返回 0（属待确认，见 Q-01），此时"旧文件 + 报成功"才会同时成立。

  所以这一条的准确定性是：**一个假的验证步骤**，会把排障方向带偏（让人以为删除成功 / 或以为删除失败），而不是"必然刷了旧 overlay"。

- **修复建议**

  **首选：彻底不用文本匹配，改用远端 `test` 的退出码**（唯一可靠，两种 stderr 实现下都正确）：

  ```bat
  :: ---- 替换 L11-16 ----
  echo [3/7] Removing old FrameworksResOverlay_Wear.apk...
  adb shell rm -f /vendor/overlay/FrameworksResOverlay_Wear.apk
  if errorlevel 1 (
      echo       FAIL: rm failed. Is /vendor writable? Check "adb remount".
      exit /b 1
  )

  echo [4/7] Verifying old file removal...
  adb shell "test -e /vendor/overlay/FrameworksResOverlay_Wear.apk"
  if not errorlevel 1 (
      echo       FAIL: old file still exists after rm - do NOT continue.
      exit /b 1
  )
  echo       OK: Old file removed
  ```

  远端 `test` 的退出码会经 adb 协议传回本机，这是唯一不依赖输出文案的做法。

  **次选（若必须保留文本匹配）**：两层缺陷要一起修，缺一不可。

  ```bat
  :: 必须同时：① 2>&1 提到管道左侧  ② 用 /c: 变成字面量整句
  adb shell ls /vendor/overlay/FrameworksResOverlay_Wear.apk 2>&1 | findstr /i /c:"No such file" >nul && echo       OK: Old file removed || echo       WARN: File still exists or path invalid
  ```

  只加 `/c:` 不修 `2>&1` → stderr 分支仍会误报 WARN；只修 `2>&1` 不加 `/c:` → `adb` 自身报错仍会被判成"删除成功"。

---

#### H-07 `PM_GPIO_CTRL-mimo.bat` 的设备预检查只判"有一台设备在线"，从不确认是**哪一台**

- **现象**

  ```bat
  265| call adb get-state >nul 2>&1
  266| if errorlevel 1 goto step_error
  ...
  684| call adb get-state >nul 2>&1
  685| if errorlevel 1 exit /b 1
  ```

- **位置**：`PM_GPIO_CTRL-mimo.bat:265-266`、`PM_GPIO_CTRL-mimo.bat:682-685`

- **根因**：全仓 9 个脚本**没有任何一处**指定序列号（无 `-s <serial>`、无 `ANDROID_SERIAL`）。当 `adb devices` 里有两台以上时，`adb get-state` 会因 `more than one device/emulator` 失败并被 L266 正确拦下——这没问题；但**只有一台连接时它永远通过**，而"这一台是不是你想操作的 PMIC 设备"完全没验证。

- **影响**：实验室里"一台目标机 + 一台无关调试机"同时连着 adb 是常态。此时 `get-state` 通过，`!REGMAP!`（`L48` 硬编码 `/d/regmap/1-00`）会在**错误设备**上被探测；更糟的是 `:detect_iface`（`L746`）带**进程内缓存** `if defined iface exit /b 0`，一旦第一次探测落在错设备上，后续所有步骤都沿用这个错误结论，而脚本一路打印 OK。写寄存器到错误的板子，属于"静默产出错误结果"的典型。

- **修复建议**：显式绑定序列号，并在入口打印设备身份让用户确认。

  ```bat
  :: ---- 替换 L264-266（以及 :dev_check 的 L682-685）----
  set "step=ADB device check"
  if not defined PM_GPIO_SERIAL (
      for /f "skip=1 tokens=1" %%d in ('adb devices') do if not defined PM_GPIO_SERIAL set "PM_GPIO_SERIAL=%%d"
  )
  if not defined PM_GPIO_SERIAL (
      echo       [FAIL] no adb device found. Run "adb devices".
      goto step_error
  )
  echo       using device: !PM_GPIO_SERIAL!
  call adb -s !PM_GPIO_SERIAL! shell getprop ro.product.device
  call adb -s !PM_GPIO_SERIAL! get-state >nul 2>&1
  if errorlevel 1 goto step_error
  ```

  同时把全文所有 `call adb ` 改为 `call adb -s !PM_GPIO_SERIAL! `（共 21 处）。

---

#### H-08 `:reg_write` 只看 `adb` 的退出码，内核拒绝 SPMI 写入时仍返回成功 → 脚本打印 `applied OK`

- **现象**

  ```bat
  689| :reg_write
  690| set "reg_addr=0x!BH!%~1"
  691| call adb shell "echo !reg_addr! > !REGMAP!/address"
  692| if errorlevel 1 exit /b 1
  693| call adb shell "echo %~2 > !REGMAP!/data"
  694| if errorlevel 1 exit /b 1
  695| exit /b 0
  ```

- **位置**：`PM_GPIO_CTRL-mimo.bat:689-695`（配合 `L32-34` 的注释）

- **根因**：**脚本自己的注释就写明了这件事会发生**：

  ```
  32| ::   若该 PMIC 外设的写权限不归当前 EE, 内核会打印
  33| ::        disallowed SPMI write to sid=... addr=...
  34| ::   此时该 GPIO 无法从系统内修改, 脚本会在对应步骤报错
  ```

  但代码**并没有"在对应步骤报错"**。内核层面拒绝写时，远端 `echo 0x1 > /d/regmap/1-00/data` 这条 shell 命令本身是"成功"的（重定向成功、写 sysfs 文件成功，被丢弃的是内核之后的处理），远端 shell 返回 0，`adb shell` 于是返回 0，`L692`/`L694` 的 `if errorlevel 1` 不成立。**注释承诺的行为与实现不符。**

  > **确定性分级（必读）**：这条链的上半段是 **Linux/`adb` 语义层面的确定事实**——重定向失败才会让 shell 返回非 0，而"内核丢弃了写入"不属于重定向失败，因此远端 `echo` 必然返回 0。下半段（该 PMIC 在本机是否真的会拒绝写）**取决于具体 EE 权限配置**，属 Q-02。所以 H-08 的结论是"**脚本没有任何能力发现这类拒绝**"，不是"这台机器上一定已经写失败过"。同理，`L32-34` 的注释是否是作者实测得来，也列在 Q-02。

- **影响**：这是本脚本最危险的一类失败——注释里明确写着"会发生"，脚本也本该报错，实际却一路打印 `applied OK: ... = ...` 并在 `L317` `exit /b 0`。任何上层自动化（CI、测试流水线）都会认为 GPIO 已经设好，后续测量/判定全部建立在错误前提上。**注意这是"检测能力缺失"，不等于"每次写都被拒绝"**；一旦设备侧的 EE 权限确实拦下了写，脚本给出的仍是一句 `applied OK`。

- **修复建议**：写后**必须回读校验**，把"读不到"和"值不对"都当作失败。

  ```bat
  :: ---- 替换 L689-695 ----
  :reg_write
  set "reg_addr=0x!BH!%~1"
  call adb shell "echo !reg_addr! > !REGMAP!/address"
  if errorlevel 1 exit /b 1
  call adb shell "echo %~2 > !REGMAP!/data"
  if errorlevel 1 exit /b 1

  :: 回读校验：此时 address 正指向刚写的偏移
  set "rb="
  for /f "delims=" %%v in ('call adb exec-out "cat !REGMAP!/data" 2^>nul') do set "rb=%%v"
  if not defined rb (
      echo       [FAIL] write unverified: cannot read back !REGMAP!/data
      exit /b 1
  )
  :: ⚠ :reg_parse 不接参数，它读的是 !read_raw!，所以必须先赋值
  set "read_raw=!rb!"
  call :reg_parse
  if errorlevel 1 (
      echo       [FAIL] write unverified: unparsable read-back "!rb!"
      exit /b 1
  )
  set /a "want=%~2" 2>nul
  if not "!read_num!"=="!want!" (
      echo       [FAIL] write verify: wrote %~2, read back !rb! ^(kernel rejected? see "disallowed SPMI write"^)
      exit /b 1
  )
  exit /b 0
  ```

  > ⚠ **本轮复核修正**：上面 `:reg_parse` 的调用方式很关键。该子程序`L711` 的第一行就是 `set "rv=!read_raw!"`，**它不读 `%1`**。所以写成 `call :reg_parse !rb!` 是无效的（参数被忽略，实际解析的是上一次 `:reg_read` 留下的旧 `read_raw`）。必须先 `set "read_raw=!rb!"` 再 `call :reg_parse`。

  另：`%~2` 直接拼进远端 shell 命令，建议加引号 `"%~2"`，避免参数里的 `[`、`>`、`&` 被远端 shell 解释（当前调用点只传 `0x1`/`0x80`/`0x00`，属子程序契约漏洞）。

---

#### H-09 回读失败被降级为 `skip`，紧接着**无条件**打印 `applied OK` 并 `exit /b 0`

- **现象**

  ```bat
  303| set "step=Read back"
  305| set "readback="
  306| for /f "delims=" %%v in ('call adb exec-out "cat !REGMAP!/data" 2^>nul') do set "readback=%%v"
  307| if defined readback (
  308|     echo       OUT_SRC_CTL = !readback!
  309| ) else (
  310|     echo       read-back not available, skip        ← 只打印一句，不 goto step_error
  311| )
  313| echo ========================================
  314| echo  !GPIO_NAME! applied OK: !level! = !out_val!
  315| echo ========================================
  317| if defined cli exit /b 0
  ```

- **位置**：`PM_GPIO_CTRL-mimo.bat:303-317`（关键行：`306`、`307-311`、`314`、`317`）

- **根因**：`for /f` 在远端命令无输出时**一次都不迭代**，`readback` 保持未定义；`L310` 的 `else` 分支只打一句 `skip`，既没 `set "step="` 也没 `goto step_error`，控制流于是**顺次落到** `L314` 的 `applied OK`。这是"回读是唯一证据、但证据缺失时结论照旧"的典型。

- **影响**：这是 H-08 的放大版。回读是脚本里**唯一**能证明"写入生效"的环节，它失败时脚本给出的结论仍是 OK；`exit /b 0` 让上层完全无法区分"写成功"与"没读回来"。使用者会拿着一个"看起来成功"的结果去做后续判定。

- **修复建议**：把回读失败变成真正的失败，并区分"读不到"与"值不对"。

  ```bat
  :: ---- 替换 L307-311 ----
  if not defined readback (
      echo       [FAIL] read-back not available - cannot verify the write.
      set "step=Read back OUT_SRC_CTL"
      goto step_error
  )
  echo       OUT_SRC_CTL = !readback!
  ```

  若还想顺带校验数值（推荐），注意 `readback` 的文本格式受 `:reg_fmt_detect`（`L723`）影响，可能是 `0x80` / `80` / `128` 三种，**不能直接字符串比较**，要先经 `:reg_parse`（`L710`）归一化再比。另外 `:reg_parse` 只在 `L712` 对 `0x` 前缀、`L713` 对 `regfmt=dec` 放行，**`readback` 拿到 `80`（无前缀的十六进制字面量）时会被 `L714` 补成 `0x80` 后走 `set /a`**——这条路径本身是对的，但它依赖 `regfmt` 已经探测过（见 Q-03）：

  ```bat
  :: ⚠ :reg_parse 不接参数（L711 是 set "rv=!read_raw!"），必须先赋值
  set "read_raw=!readback!"
  call :reg_parse
  if errorlevel 1 (
      echo       [FAIL] read-back unparsable: !readback!
      set "step=Read back OUT_SRC_CTL" & goto step_error
  )
  :: 注意：!out_num! 在 :apply_level 里并不存在，需从 !out_val! 换算（见下）
  set /a "want=!out_val!" 2>nul
  if not "!read_num!"=="!want!" (
      echo       [FAIL] read-back mismatch: want !want!, got !read_num!
      set "step=Read back OUT_SRC_CTL" & goto step_error
  )
  ```

  > ⚠ **本轮复核修正两处**（原片段照抄会直接失败）：
  > 1. `call :reg_parse !readback!` 是无效调用——`:reg_parse`（`L710-719`）**不读 `%1`**，第一步就是 `set "rv=!read_raw!"`，必须先把 `readback` 塞进 `read_raw`。
  > 2. `!out_num!` **在脚本里根本不存在**。`:apply_level` 用的是 `!out_val!`（`0x80` / `0x00`，在 `L261`、`L295-299` 使用），全文没有 `out_num` 这个变量。这里应为 `set /a "want=!out_val!"`（`set /a` 能直接求值 `0x80`）。

---

### 2.3 中（17 条）

#### M-01 裸 `exit` 会连调用者一起杀掉——但这是**设计意图**，不是必须改；若改 `exit /b`，必须同时补上子窗口清理

- **现象**：`disp_continuous_monitor.bat:90` 与 `备用脚本\monitor.bat:40` 结尾是裸 `exit`（无 `/b`）。对比 `PM_GPIO_CTRL-mimo.bat` 全篇用 `exit /b 0/1/2/3`。
- **位置**：`disp_continuous_monitor.bat:90`；`备用脚本\monitor.bat:40`
- **根因**：`exit` 结束**整个 `cmd.exe` 进程**，而 `exit /b` 只结束当前批处理。实测（本地探针）：
  ```
  cmd /c "call drv_exit.bat & echo OUTER-CONTINUES"
  → driver-before / child-before            （OUTER-CONTINUES 没有出现）
  ```
  即 `call` 到一个裸 `exit` 的子脚本后，调用者的后续命令**凭空消失**。
- **影响**
  - **这是有意为之的**：这两个脚本本就设计成"双击独立运行、跑完自动关窗"，裸 `exit` 正好实现"窗口自己关掉"，对普通用户是友好体验。因此**不建议无条件改成 `exit /b`**。
  - 代价是：任何人想把它 `call` 进自己的包装脚本（例如"先抓 before → 跑测试 → 再抓 after"），外层会被中途杀死；在 CI / 计划任务里表现为"后续步骤凭空消失且无报错"。
  - `备用脚本\monitor.bat:39` 的注释写 `:: 优雅退出整个脚本，防止残留`——但它防的只是**自己这个窗口**，对 `start` 出来的 Logcat/Dmesg/GetEvent 子进程**毫无作用**（见 BLK-01）。这条注释名不副实。
- **修复建议**：按使用方式二选一，**不要只改一半**。
  - **方案 A（保持独立运行，推荐给当前用法）**：不改 `exit`，但把子进程清理补在前面（否则"防止残留"仍是空话）：
    ```bat
    :: 在 L37 pause >nul 之后、L40 exit 之前插入
    echo Stopping capture...
    taskkill /FI "WINDOWTITLE eq Logcat*"   /F >nul 2>&1
    taskkill /FI "WINDOWTITLE eq Dmesg*"    /F >nul 2>&1
    taskkill /FI "WINDOWTITLE eq GetEvent*" /F >nul 2>&1
    exit
    ```
  - **方案 B（改成可被 call）**：把 `exit` 换成 `exit /b 0`。**但请注意：改成 `exit /b` 后，那两个 `start` 出来的 Logcat/Dmesg 子窗口仍会残留**——`exit /b` 只影响"谁被杀"，不影响"谁活着"。所以方案 B 必须**同时**加上面那三行 `taskkill`，否则只是把"关窗"的好处去掉了、残留问题一点没解决。

---

#### M-02 `set /a "n+=%~1"` 把命令行 GPIO 号按**八进制**解析：`010` 静默操作 PM_GPIO_08、`016` 静默操作 PM_GPIO_14

- **现象**

  ```bat
  101| set /a "n=0"
  102| set /a "n+=%~1" 2>nul
  103| if !n! lss 1 goto cli_usage
  104| if !n! gtr 18 goto cli_usage
  ```

- **位置**：`PM_GPIO_CTRL-mimo.bat:101-104`（命令行入口 `:cli_args`，`L100` 置 `cli=1`）

- **根因**：`set /a` 的整数字面量规则里，**前导 `0` 表示八进制**。实测（本机 cmd，逐项复现源文件写法）：

  ```
  参数   n 的值   是否通过 L103/L104   实际行为
  8     8        通过               正常操作 PM_GPIO_08
  08    0        被 L103 拦下        【误判非法】—— 08 本是合法 GPIO
  010   8        通过                【静默操作 PM_GPIO_08】（用户以为是 10 号）
  016   14       通过                【静默操作 PM_GPIO_14】（用户以为是 16 号）
  018   0        被 L103 拦下        【误判非法】—— 018 也是合法 GPIO
  18    18       通过               正常
  ```

  （`2>nul` 把 `Invalid number.` 报错吞掉了，这正是此 bug 能长期潜伏的原因。）

- **影响**
  1. **静默操作错误的 GPIO**：`PM_GPIO_CTRL-mimo.bat 010 high` 实际改的是 **GPIO_08**。脚本会在 `L177` 打印 `PM_GPIO_08`，但用户如果不逐字核对这一行、只看"applied OK"，就会在错误的引脚上量到电平，得出"代码改错了"的错误结论——**排查方向会被彻底带偏**。
  2. **合法输入被拒**：`08`、`018` 报 usage，用户会以为脚本不支持带前导零的写法。
  3. **两条入口行为不一致**：交互菜单在 `L84` 已经剥掉前导零（`if "!choice:~0,1!"=="0" ... set "choice=!choice:~1!"`），所以 `08` 在**菜单里能用、命令行里不能用**。同一个脚本两种行为，最容易被判成"这脚本有时好使有时不好使"。

- **修复建议**：统一到一个 `:parse_gpio` 子程序，两条入口都走它。十进制安全技巧是**先补零到 3 位**、再 `1<3位> - 1000`（`008-1000=8`、`010-1000=10`、`018-1000=18`）：

  > ⚠ **上一版给出的 `1!arg!-1000` 是错的**（本轮复核发现并已改正）：`arg=8` 时它算的是十进制 `18-1000 = -982`，`arg=10` 时是 `110-1000 = -890`，**所有合法输入都会被判非法**。必须先补到固定 3 位。下面的版本已实测通过（`8/08/1/10/010/18/018` → `8/8/1/10/10/18/18`，全部 PASS）。

  ```bat
  :: ---- 新增子程序，并让 L88 / L102 都改为 call :parse_gpio ----
  :parse_gpio
  set "arg=%~1"
  if not defined arg exit /b 1
  :: 只允许纯数字
  echo !arg!| findstr /r /c:"^[0-9][0-9]*$" >nul || exit /b 1
  :: 剥掉全部前导零（保留单个 "0"）
  :pg_strip
  if "!arg:~0,1!"=="0" if not "!arg!"=="0" (set "arg=!arg:~1!" & goto pg_strip)
  :: 补到固定 3 位，再做"减 1000"的十进制解析（避免八进制）
  set "p3=00!arg!"
  set "p3=!p3:~-3!"
  set /a "n=1!p3!-1000" 2>nul
  if !n! lss 1 exit /b 1
  if !n! gtr 18 exit /b 1
  exit /b 0
  ```

  调用侧：

  ```bat
  :: L102 处
  call :parse_gpio %~1
  if errorlevel 1 goto cli_usage
  :: L88 处（菜单）
  call :parse_gpio !choice!
  if errorlevel 1 goto invalid_gpio
  ```

---

#### M-03 `mkdir "%OUT%" 2>nul` 与 `cd /d "%OUT%"` 都不看返回值，失败时输出静默落到脚本目录

- **现象**

  ```bat
  19| mkdir "%OUT%" 2>nul
  20| cd /d "%OUT%"
  ```

  之后 L24 起全部写**相对文件名**。

- **位置**：`current_display.bat:19-20`、`disp_continuous_monitor.bat:19-20`、`备用脚本\monitor.bat:18-19`
  （`备用脚本\capture_disp_log.bat:17` 只 `mkdir` 不 `cd`，全部用 `"%OUT%\..."` 绝对路径——这一处反而是对的）

- **根因**：`mkdir` 失败（磁盘满、权限、同名文件占位）时只返回 1 并被 `2>nul` 静默；`cd /d` 随后失败也无人检查，`cmd` 就**停在原目录**继续跑。实测（先造一个同名文件让 `mkdir` 必然失败）：

  ```
  mkdir_rc=[1]        "The directory name is invalid."
  cd_rc=[1]
  cwd 仍在原处        → 后续输出全部落到脚本目录
  ```

  **补充实测（本轮复核重做）**：`cd /d` 失败**确实返回 1**，四种情形都验过（每次先用 `cmd /c exit 0` 复位 errorlevel，排除上一条命令残留）：

  ```
  cd /d "Q:\no_such_dir\LOGS_1"        rc=1   cwd 未变     (err: The system cannot find the drive specified.)
  cd /d "C:\no_such_dir_zz\LOGS_1"     rc=1   cwd 未变     (err: The system cannot find the path specified.)
  cd /d "C:\Windows"                   rc=0   cwd=C:\Windows
  cd /d "C:\Windows\notepad.exe"       rc=1   cwd 未变     (err: The directory name is invalid.)
  ```

  所以**"检查 `cd /d` 返回码"是可行的**（这一点很重要，别被上一版说法误导）。真正的问题只有一个：脚本**压根没检查**——`mkdir` 的错误被 `2>nul` 吞掉，`cd /d` 的返回值无人过问，于是失败静默通过。

- **影响**：`logcat_all_before.txt`、`dumpsys_*.txt` 等散落到脚本所在目录，与真正的 `LOGS_*` 目录混在一起；脚本结尾仍打印 `Done! Logs saved to: %OUT%`，指向一个空目录。使用者按提示去 `%OUT%` 找日志，只能看到空文件夹或旧文件。

- **修复建议**：用 `exist` 判目录、用 `pushd` 替代 `cd`（`pushd` 会校验并可 `popd` 还原，不污染调用者 cwd）。

  ```bat
  :: ---- 替换 19-20 ----
  mkdir "%OUT%" 2>nul
  if not exist "%OUT%\" (
      echo [FAIL] cannot create output dir: "%OUT%"
      echo        Check disk space / permissions, or a file with the same name exists.
      pause & exit /b 1
  )
  pushd "%OUT%" || (
      echo [FAIL] cannot enter "%OUT%"
      pause & exit /b 1
  )
  ```

  结尾处（`disp_continuous_monitor.bat:88` 前后）补 `popd`。

---

#### M-04 `adb wait-for-device` 无超时、`adb root` 不看结果，且 root 会重启 adbd 却不再等一次

- **现象（4 处逐字相同）**

  ```
  13| adb wait-for-device
  15| adb root
  ```

- **位置**：`current_display.bat:13,15`、`disp_continuous_monitor.bat:13,15`、`备用脚本\capture_disp_log.bat:11,14`、`备用脚本\monitor.bat:13,15`

- **根因**
  1. `adb wait-for-device` **没有内置超时**（新版 adb 也没有 `--timeout`），设备永远不插上就永远阻塞。全仓 `grep -i -E "retry|attempt"` = 零命中，无任何重试。
  2. `adb root` 的退出码未检查。user 版 / verity 锁定的设备上它会失败，脚本毫不知情地继续。
  3. `adb root` **成功时会重启 adbd**，连接会短暂断开——正确做法是**再 `wait-for-device` 一次**。现有代码在 L15 之后直接进 L19 建目录、L24 抓取，中间没有任何重新等待，存在竞态（本次现场侥幸没暴露）。

- **影响**：`dmesg` 在 user 版上返回 `Operation not permitted`，`dumpsys` 也可能残缺；脚本产出一堆 0 字节或只有报错的快照，最后照样打印 `Done! Logs saved to: %OUT%`。换台没 root 的设备，就是"12 个空文件 + 一句成功"。

- **修复建议**

  ```bat
  :: ---- 替换 12-15 ----
  echo Waiting for device (Ctrl+C to abort)...
  adb wait-for-device
  adb get-state >nul 2>&1 || (echo [FAIL] no device. Run "adb devices". & pause & exit /b 1)

  echo Requesting root...
  adb root >nul 2>&1
  if errorlevel 1 (
      echo [WARN] "adb root" failed - dmesg/dumpsys may be incomplete or empty.
  ) else (
      echo [INFO] adbd restarting, waiting for it to come back...
      timeout /t 3 /nobreak >nul
      adb wait-for-device
      adb get-state >nul 2>&1 || (echo [FAIL] device lost after "adb root". & pause & exit /b 1)
  )
  ```

---

#### M-05 `auto_shot.bat`：`for /f` 循环体不执行时变量保留上一轮的值，`adb pull` 拉的是**上一张**图，然后打印 `OK`

- **现象**

  ```bat
  36| for /f "delims=" %%i in ('adb shell ls -t %PHONE_PATH%/*.jpg 2^>nul') do (
  37|     set file=%%i
  38|     goto PULL
  39| )
  40| :PULL
  42| adb pull "!file!" "%SAVE_DIR%\!ts!.jpg" >nul 2>&1
  43| echo OK: !ts!.jpg
  ```

- **位置**：`auto_shot.bat:36-43`（关键：`23` 处 `:LOOP` 未清空 `file`、`40` 的 `:PULL` 是顺序落点、`42` 吞掉错误、`43` 无条件 `OK`）

- **根因（两重）**
  1. `:PULL` 是**顺序落点**：`for` 一次都没迭代时，控制流照样从 L39 落到 L40，`file` 仍是**上一轮**留下的值。
  2. `file` 从未在循环前清空（`L23` 的 `:LOOP` 处没有 `set "file="`）。实测：`set "file=AAA"` 后跑一个输出为空的 `for /f`，`file` 仍是 `AAA`。

- **影响**：相机没起来 / `ls` 因权限失败 / 照片还没落盘时，只要**上一轮成功过**，脚本就会把**上一张图**再 pull 一遍，用新的时间戳命名 → `Camera_Android\` 里出现内容重复、看似"每 3 秒都在拍"。`L42` 的 `>nul 2>&1` 把 pull 失败吞掉，`L43` 无条件 `echo OK` → **假成功**。若上一轮也没成功，则 `adb pull "" ...` 同样被吞，依旧打印 OK。

- **修复建议**

  ```bat
  :: ---- 替换 23-43 ----
  :LOOP
  set "file="
  set ts=%date:~0,4%%date:~5,2%%date:~8,2%%time:~0,2%%time:~3,2%%time:~6,2%
  set ts=!ts: =0!
  ...
  for /f "delims=" %%i in ('adb shell "ls -t '%PHONE_PATH%'/*.jpg" 2^>nul') do (
      set "file=%%i"
      goto PULL
  )
  if not defined file (
      echo [WARN] no jpg found on device, retry in %INTERVAL%s
      timeout /t %INTERVAL% /nobreak >nul
      goto LOOP
  )
  :PULL
  adb pull "!file!" "%SAVE_DIR%\!ts!.jpg" >nul 2>&1
  if errorlevel 1 (
      echo [FAIL] pull failed: !file!
      goto LOOP
  )
  echo OK: !ts!.jpg
  ```

---

#### M-06 `auto_shot.bat` 的时间戳在 `chcp 65001` 之后是 `周二022611114952`——非法文件名，且年月日全错

- **现象**

  ```bat
  2|  chcp 65001 >nul
  ...
  24| set ts=%date:~0,4%%date:~5,2%%date:~8,2%%time:~0,2%%time:~3,2%%time:~6,2%
  ```

- **位置**：`auto_shot.bat:2,24-25`（对比 4 个抓取脚本用的是 `for /f` 解析，见 H-02）

- **根因**：`chcp 65001` 后 `%date%` 的形态从 `2026/11/03 周二`（cp936）变成 **`周二 2026/11/03`**（周几跑到最前）。`%date:~0,4%` 于是取到 `周二 2`。实测：

  ```
  CP65001 下 %date% = 周二 2026/11/03
  SUB0_4=[周二 2]   SUB5_2=[26]   SUB8_2=[11]
  → 拼接结果 周二022611114952
  ```

- **影响**：文件名 `周二022611114952.jpg`——**年份丢了（`26` 是 `2026` 的中间两位）、月份变成了日期**。按文件名排序完全失效；含中文的文件名在跨平台处理/回推设备时容易出问题。这不是"难看"，是**功能错误**。

- **修复建议**：不要用 `%date%` 做时间戳，改用与代码页无关的来源（同 H-02）：

  ```bat
  :: ---- 替换 24-25 ----
  for /f "delims=" %%t in ('wmic os get localdatetime ^| findstr /r "^[0-9]"') do set "DT=%%t"
  set "ts=!DT:~0,8!_!DT:~8,6!"       :: 20261103_112936
  ```

---

#### M-07 `power-key.bat` 循环体内两条 `adb shell input keyevent` 完全不判退出码，掉线后仍跑满 100 轮

- **现象**

  ```bat
  5|  set max=100
  19| adb shell input keyevent 26
  22| adb shell input keyevent 26
  ```

- **位置**：`power-key.bat:9,19,22,26`（全文 `errorlevel`/`&&`/`||` 命中数为 **0**）

- **根因**：无 `errorlevel` 判定、无 `adb get-state` 预检查、无重试、无中断。

- **影响**：设备 USB 掉线后，`adb shell` 每次返回 `error: no devices/emulators found`（rc=1）被忽略，脚本照常跑满 100 轮，每轮 `timeout 5 + 10 = 15` 秒，累计**空转约 25 分钟**后打印 `脚本执行完毕，共运行 100 次。`。用户以为压测跑完了，实际一次都没点——**"按键唤醒稳定性"这类测试的结论直接作废**。

- **修复建议**

  ```bat
  :: ---- 替换 8-27 ----
  :loop
  if %i% gtr %max% goto end
  adb get-state >nul 2>&1 || (
      echo [ABORT] device lost before iteration %i%
      goto end
  )
  adb shell input keyevent 26
  if errorlevel 1 ( echo [ABORT] keyevent failed at iteration %i% & goto end )
  timeout /t 5 /nobreak >nul
  adb shell input keyevent 26
  if errorlevel 1 ( echo [ABORT] keyevent failed at iteration %i% & goto end )
  timeout /t 10 /nobreak >nul
  set /a i+=1
  goto loop

  :end
  echo 完成 %i% / %max% 次（若中途中断，%i% 会小于 %max%）
  ```

  并把 `max` 改成命令行可传：`if not "%~1"=="" set "max=%~1"`。

---

#### M-08 回读解析：`set /a` 把**单个无空格**的垃圾 token 当成变量名求值，结果是 0 但变量"已定义"，`if not defined` 抓不住

- **现象**

  ```bat
  715| :reg_parse_num
  716| set "read_num="
  717| set /a "read_num=!rv!" 2>nul
  718| if not defined read_num exit /b 1
  ```

- **位置**：`PM_GPIO_CTRL-mimo.bat:715-718`（`regfmt=dec` 分支由 `L713` 进入；`hex` 分支在 `L714` 先加 `0x` 前缀）

- **根因**：`set /a` 把无法解析的 token 当作**环境变量名**求值，未定义则取 0，**并且赋值照样发生**。所以 `L718` 的"未定义"检测抓不住"值是 0"。实测：

  ```
  set /a "read_num=Permission"  →  read_num=[0]  DEFINED      ← 漏检
  ```

  在 `hex` 分支里 `L714` 会把值拼成 `0xPermission`，非法前缀让 `set /a` 真的失败、变量保持未定义 → **能抓住**。所以只有 `regfmt=dec` 分支有这个洞。

- **影响（收敛后的准确表述）**：漏检需要**同时**满足 (a) `:reg_fmt_detect` 判定 `regfmt=dec`（`L729`：读回字面 `16`），且 (b) 读回的垃圾是**单个无空格 token**。两个条件都不常见，所以不是高概率缺陷。但一旦命中，`read_num=0` 会带着 `:set_dir`/`:set_drive` 的位运算跑完并写寄存器（`0` 在 `MODE_CTL` 里意味着**方向被设成 IN**），而脚本打印 OK。

- **修复建议**：先用字符集白名单挡一道，再交给 `set /a`：

  ```bat
  :reg_parse_num
  set "read_num="
  echo !rv!| findstr /r /c:"^0x[0-9A-Fa-f][0-9A-Fa-f]*$" /c:"^[0-9][0-9]*$" >nul || exit /b 1
  set /a "read_num=!rv!" 2>nul
  if not defined read_num exit /b 1
  exit /b 0
  ```

---

#### M-09 gpiod 回退路径：chip 识别硬编码 libgpiod **v1** 的输出格式；`gpioset` 释放后电平不保证保持，而脚本声称 `level kept`

- **现象**

  ```bat
  757| for /f "tokens=1" %%c in ('call adb shell gpiodetect 2^>nul ^| findstr /l /c:"(18 lines)"') do if not defined chip set "chip=%%c"
  ...
  587| call adb shell "gpioset !chip! !gline_no!=!lvl!"
  589| echo       direction = OUTPUT   level kept = !lvl!
  ```

- **位置**：`PM_GPIO_CTRL-mimo.bat:754-759`（`:find_chip`）、`L534-553`（`:apply_level_gpiod`）、`L558-595`（`:set_dir_gpiod`）、`L587,589`

- **根因（两条，彼此独立）**
  1. **chip 指纹是"18 条线"**，且没有第二重确认（未用 chip label / `pinctrl-`）。若 SoC 上另有一个也是 18 线的 gpiochip，`if not defined chip` 会取**第一个**匹配，顺序由 `gpiodetect` 输出决定、不可控。此外这个指纹**绑死了 libgpiod v1 的措辞**（`gpiochip2 [pinctrl-msm] (18 lines)`）；libgpiod v2 改成 `18 lines` 无括号，届时永远找不到 chip → `L758 exit /b 1`。
  2. `gpioset <chip> <line>=<value>` 在 libgpiod v1 中是**一次性请求后立即释放**（除非加 `--mode=wait`），释放后引脚回到默认态。`L589` 声称 `level kept`，`L544` 的 `apply_level_gpiod` 同理（它自己在 `L550` 承认 `gpiochip has no output readback`）。

- **影响**：`set_drive` 走 gpiod 时直接 `exit /b 3`（`L616`）——这是**正确的降级**。但 `apply_level` / `set_dir` 走 gpiod 时会**选错 chip** 或**设完即失效**，而脚本打印 `OK via gpioset`。使用者按"电平已保持"的假设去测量，会得到与日志矛盾的读数。

- **修复建议**

  ```bat
  :: 1) chip 加第二重确认
  for /f "tokens=1" %%c in ('call adb shell gpiodetect 2^>nul ^| findstr /i "lines"') do if not defined chip set "chip=%%c"
  call adb shell "gpioinfo !chip!" 2>nul | findstr /i "pinctrl" >nul || (
      echo       [FAIL] cannot confirm "!chip!" is the PMIC gpiochip
      set "step=Find PMIC gpiochip" & goto step_error
  )

  :: 2) 别谎报 "level kept"
  echo       direction = OUTPUT
  echo       [NOTE] gpioset releases the line immediately; level is NOT guaranteed to hold.
  ```

- **补充**：`L757` 的 `findstr /l /c:"(18 lines)"` 这个写法本身**语法没有问题**（已在 libgpiod v1 格式的 stub 文本上验证可正常匹配）。这里要修的是"硬编码 v1 格式"，**不是**"findstr 写错了"。

---

#### M-10 `rm` 完全没有错误检查；`push` 的 `pause` 又排在 `exit /b` 之前；同一脚本里两套 errorlevel 语义混用

- **现象**

  ```bat
  12| adb shell rm -rf /vendor/overlay/FrameworksResOverlay_Wear.apk
  13| echo       Done.
  ...
  20| if !errorlevel! neq 0 (echo       FAIL: Push failed! Check network/path. & pause & exit /b 1) else (echo       OK: Push completed.)
  ```

- **位置**：`push_apk.bat:12-13,20`；`push_msm_drm_ko.bat:12-13,20`

- **根因（三重）**
  1. `L12` 的 `rm -rf` 后**没有任何判定**，`L13` 直接打印 `Done.`——即使 `rm` 因只读分区失败也照打。
  2. `L20` 的 `if !errorlevel! neq 0` 写法本身**是对的**（是全仓写得最正确的一处失败判定），但失败分支 `pause` 在 `exit /b 1` 之前，无人值守必卡死。
  3. **两套语义并存**：`L9` 用 `&&`/`||`（等价 `errorlevel ≥ 1` 语义），`L20` 用 `neq 0`。`neq 0` 能抓住负的崩溃码（如 `0xC0000006`），`if errorlevel 1` 抓不住。将来若有人把 L20 "统一"成 `if errorlevel 1`，就会漏掉崩溃码。

- **影响**：`rm` 失败 → 旧文件仍在 → `L16` 的验证因 H-06 判不出来 → `push` 覆盖 → 若 push 也失败，`L20` 能兜住（这点值得肯定，比其余脚本强），但用户已经被 `L9` 的"remount succeeded"、`L13` 的 `Done.`、`L16` 的"Old file removed"连续三次误导过。

- **修复建议**：三个 L 一起改。

  ```bat
  :: ---- L11-13 ----
  echo [3/7] Removing old file...
  adb shell rm -f /vendor/overlay/FrameworksResOverlay_Wear.apk
  if errorlevel 1 (
      echo       FAIL: rm failed ^(read-only fs? run "adb remount" first^).
      exit /b 1
  )
  echo       Done.

  :: ---- L20 ----
  set "pushrc=!errorlevel!"
  if not "!pushrc!"=="0" (
      echo       FAIL: Push failed ^(rc=!pushrc!^). Check network path / remount.
      exit /b 1
  )
  echo       OK: Push completed.

  :: 二次确认（不依赖退出码）：比对远端文件大小/存在性
  adb shell "ls -l /vendor/overlay/FrameworksResOverlay_Wear.apk"
  if errorlevel 1 ( echo       FAIL: pushed file not visible on device. & exit /b 1 )
  ```

---

#### M-11 源路径硬编码内网 IP、共享名与个人构建树，离开该网络/该分支立刻失效

- **现象**

  ```
  19| adb push "\\10.71.255.189\yxb_sdc1\kdo_nj\LINUX\android\out\target\product\neo\vendor\overlay\FrameworksResOverlay_Wear.apk" ...
  19| adb push "\\10.71.255.189\yxb_sdc1\kc3\VENDOR\out\target\product\vienna\dlkm\lib\modules\msm_drm.ko" ...
  ```

- **位置**：`push_apk.bat:19`、`push_msm_drm_ko.bat:19`

- **根因**：把一个人的构建机路径写死进脚本。两条路径还分属**两套产品树**（`neo` / `vienna`），说明脚本本来就是为某次特定任务临时写的。

- **影响**：换机器、换人、换分支、甚至只是共享名变更，脚本立刻失效；同时把内网 IP、共享名、个人账号目录（`kdo_nj`）**泄露到脚本源码里**——如果这个目录会被打包或提交，属于信息暴露。

- **修复建议**：改为参数 + 环境变量双通道，并在缺参时给 usage。

  ```bat
  :: ---- 替换 L18-19 ----
  if "%~1"=="" (
      echo usage: %~nx0 ^<local-apk-path^>
      echo    or: set APK_SRC=\\server\share\...\FrameworksResOverlay_Wear.apk
      pause & exit /b 2
  )
  set "SRC=%~1"
  echo [5/7] Pushing "%SRC%" ...
  adb push "%SRC%" /vendor/overlay/FrameworksResOverlay_Wear.apk
  ```

  或保留默认值但允许覆盖：`if not defined APK_SRC set "APK_SRC=\\10.71.255.189\..."`，且该默认值应挪到单独的配置文件里。

---

#### M-12 `auto_shot.bat` 的保存目录用 `%cd%` 而不是脚本目录，且 `set` 未加引号

- **现象**

  ```bat
  11| set SAVE_DIR=%cd%\Camera_Android
  ```

  后续 `L13`、`L42` 才给它加引号。

- **位置**：`auto_shot.bat:11`（对比 `L13` `if not exist "%SAVE_DIR%" mkdir "%SAVE_DIR%"`、`L42` `adb pull ... "%SAVE_DIR%\!ts!.jpg"`）

- **根因**：用 `%cd%`（**当前工作目录**）而不是 `%~dp0`（**脚本所在目录**）；且 `set` 语句整体没加引号。

- **影响**：双击运行时 cwd 恰好等于脚本目录，所以"看起来正常"。但从"以管理员身份运行"、计划任务、或 IDE/CI 调用时，cwd 可能是 `C:\Windows\System32`，几百张截图会散落到系统目录。`set` 不加引号在路径含 `&` / `^` 时会截断（当前 Windows 路径很少含这些，属潜在风险）。

- **修复建议**

  ```bat
  set "SAVE_DIR=%~dp0Camera_Android"
  if not exist "%SAVE_DIR%\" mkdir "%SAVE_DIR%"
  ```

---

#### M-13 `auto_shot.bat` 的快门坐标与包名全是硬编码，换分辨率/换机型必错

- **现象**

  ```bat
  8|  set TAP_X=243
  9|  set TAP_Y=512
  27| adb shell am force-stop com.android.camera2 >nul 2>&1
  30| adb shell am start -n com.android.camera2/com.android.camera.CameraActivity >nul 2>&1
  33| adb shell input tap %TAP_X% %TAP_Y%
  ```

- **位置**：`auto_shot.bat:8-10,27,30,33,45`

- **根因**：`(243, 512)` 是某台特定分辨率设备上快门按钮的坐标，脚本不校验当前分辨率，也不校验 `input tap` 是否真的点到了快门。

- **影响**：换一台机器，`input tap` 会点到预览区、参数栏或返回键——脚本仍然 pull 到一张图（可能是上一张，见 M-05）并打印 OK，**"拍到了"和"没拍到"完全无法区分**。

- **修复建议**：优先用不依赖坐标的方式；若必须用坐标，先读分辨率再按比例换算。

  ```bat
  :: 首选：不依赖坐标（多数相机 App 支持）
  adb shell input keyevent KEYCODE_CAMERA

  :: 备选：按屏幕比例换算
  for /f "tokens=2 delims=: " %%s in ('adb shell wm size ^| findstr /i "Physical"') do set "SCR=%%s"
  for /f "tokens=1,2 delims=x" %%w in ("!SCR!") do (
      set /a "TAP_X=%%w * 45 / 100"
      set /a "TAP_Y=%%h * 92 / 100"
  )
  ```

---

#### M-14 四个抓取脚本的"落盘规则"有三种写法混用：先 `cd` 用相对名 / 不 `cd` 用绝对名 / `cd` 之后又拼绝对名

- **现象**

  | 脚本 | 是否 `cd` | 落盘写法 |
  |---|---|---|
  | `current_display.bat` | `L20 cd /d "%OUT%"` | L24-34 裸文件名 |
  | `disp_continuous_monitor.bat` | `L20 cd /d "%OUT%"` | L24-34 裸名，但 `L84` 又用 `"%OUT%\bugreport.zip"` |
  | `备用脚本\capture_disp_log.bat` | **不 cd** | 全程 `"%OUT%\..."` |
  | `备用脚本\monitor.bat` | `L19 cd /d "%OUT%"` | 裸名 |

- **位置**：`current_display.bat:20,24-34`；`disp_continuous_monitor.bat:20,24-34,84`；`备用脚本\capture_disp_log.bat:17,20-36`；`备用脚本\monitor.bat:19`

- **根因**：同一套代码被复制改写了 4 次，每次都有人按自己的习惯调一下落盘方式，没有统一约定。

- **影响**：`bugreport.zip` 的落点在三份脚本里是三种规则；同目录下 `dir` 的结果取决于"从哪启动"；后续想加一个"自动汇总目录"的功能时，无法用统一规则扫描。

- **修复建议**：统一成"先 `pushd "%OUT%"`（失败即退出），之后**一律用裸文件名**"（与 M-03 的修复一起做）。`disp_continuous_monitor.bat:84` 改成 `adb bugreport bugreport.zip`。

---

#### M-15 退出码契约 `0/1/2/3` 名义自洽，但"失败=1"把四种不同根因压成同一个码，且交互模式无退出码语义

- **现象**

  ```
  160| echo   exit code: 0 ok, 1 failed, 2 bad usage, 3 unsupported here
  ```

- **位置**：`PM_GPIO_CTRL-mimo.bat:160-161`（契约声明）、`:317,394,429,529,553,577,595,653`（成功 `exit /b 0`，8 处）、`:616`（不支持 `exit /b 3`）、`:668`（失败 `exit /b 1`）、`:675`（菜单 Q `exit /b 0`）

- **根因 / 逐条核对**

  | 路径 | 承诺 | 实际 | 结论 |
  |---|---|---|---|
  | 成功（cli 模式，8 处） | 0 | `exit /b 0` | ✅ 一致 |
  | 参数错（`:cli_usage`） | 2 | `L161 exit /b 2` | ✅ 一致 |
  | 失败（`:step_error`） | 1 | `L668 exit /b 1` | ⚠️ 见下 |
  | 驱动不支持 | 3 | `L616 exit /b 3` | ✅ 一致 |
  | 交互模式非 0 退出 | 契约未定义 | `L95-96`、`L227-228`、`L255-256`、`L669-670` 都是 `pause` 后 `goto` 回菜单，**永不返回** | ❌ 无退出码语义 |
  | 交互模式按 Q | 契约未定义 | `L675 exit /b 0` | ⚠️ 用户主动取消也报"成功" |

- **影响**：退出码契约的信息丢失分两层，**不要混为一谈**（本轮复核修正了上一版的表述）：

  | 失败根因 | 实际走向 | 实际退出码 |
  |---|---|---|
  | 设备未连接（`L265-266`） | `goto step_error`，`!step!`=`ADB device check` | **1** |
  | 无 regmap 接口（`L267-268` → `:detect_iface` 失败） | `goto step_error`，`!step!`=`Detect available register interface` | **1** |
  | **内核拒绝 SPMI 写**（H-08，`L691-694`） | `:reg_write` 返回 0 → **不进 step_error** → 打印 `applied OK` → `L317 exit /b 0` | **0（报成功）** |
  | **回读为空**（H-09，`L307-311`） | 只打印 `skip` → 打印 `applied OK` → `L317 exit /b 0` | **0（报成功）** |

  所以准确说法是：**"失败=1" 只覆盖了前两种（本该可重试 vs 该换设备这两类，CI 分不开）；后两种更糟——它们根本没走到错误路径，直接返回 0**（详见 H-08 / H-09）。这是**契约层面的信息丢失 + 两个假成功**，不是单纯"码不够用"。

- **修复建议**：细分退出码（保持向后兼容：非 0 仍是失败），并在 usage 里显式写明交互模式无退出码契约。

  ```bat
  :: 0 ok / 1 generic / 2 usage / 3 unsupported / 4 no device / 5 no regmap / 6 write rejected
  :step_error
  if /i "!step!"=="ADB device check"                     if defined cli exit /b 4
  if /i "!step!"=="Detect available register interface"  if defined cli exit /b 5
  if /i "!step!"=="Read back OUT_SRC_CTL"                if defined cli exit /b 6
  if defined cli exit /b 1
  ```

  并在 `L160` 补一句：`echo   (interactive mode has NO exit-code contract)`。

---

#### M-16 `cli` / `iface` / `chip` / `regfmt` 都是通用名，父环境预置会让脚本走错分支

- **现象**

  ```bat
  2|   setlocal enabledelayedexpansion
  ...
  100| set "cli=1"
  317| if defined cli exit /b 0
  ...
  746| if defined iface exit /b 0
  755| if defined chip exit /b 0
  724| if defined regfmt exit /b 0
  ```

- **位置**：`PM_GPIO_CTRL-mimo.bat:2,100,317`；缓存守卫在 `L724`(`regfmt`)、`L746`(`iface`)、`L755`(`chip`)

- **根因**：`setlocal`（L2）只隔离"本脚本对外的污染"，**不隔离"从父进程继承进来的"变量**。这四个名字都极其通用。

- **影响**：
  - 若调用者环境里已有 `cli`（很常见），`L60` 仍会走交互菜单（因为判的是 `%~1`），但 `L317` 会认为处于命令行模式，于是用户按一下 `Y` 之后脚本直接 `exit /b 0`——**菜单消失、窗口关闭**，用户会以为脚本崩了。
  - 若父环境恰好定义了 `iface` / `chip` / `regfmt`，探测会被**整体跳过**，后续所有操作基于一个从未验证过的假设。

- **修复建议**：统一加 `PM_` 前缀，并在入口显式清空。

  ```bat
  :select_gpio
  set "PM_CLI="          :: 交互模式，清掉可能被继承的值
  ...
  :: 全部改名：cli → PM_CLI、iface → PM_IFACE、chip → PM_CHIP、regfmt → PM_REGFMT
  ```

---

#### M-17 开头注释里的用法示例写的是 `PM_GPIO_CTRL-new.bat`，与实际文件名不符

- **现象**：`L37-45` 共 **8 处** `PM_GPIO_CTRL-new.bat`，而实际文件是 `PM_GPIO_CTRL-mimo.bat`（`L152-158` 的 usage 用的是 `%~nx0`，所以那段是对的）。
- **位置**：`PM_GPIO_CTRL-mimo.bat:37,39,40,41,42,43,44,45`
- **根因**：脚本改过名（`-new` → `-mimo`），注释是旧版本残留。
- **影响**：用户照注释敲命令会得到"文件名不存在"；新同事会以为还有另一个 `-new.bat` 在别处。
- **修复建议**：把注释里的 8 处改为 `PM_GPIO_CTRL-mimo.bat`，或统一改成 `%~nx0` 由运行时展开。

---

### 2.4 低（10 条）

> 本节条目**不影响执行逻辑**，只影响显示、可读性与一致性。逐条同样给出五段式，便于直接照改。

#### L-01 `power-key.bat` 是 UTF-8 却没有 `chcp`，脚本唯一的收尾提示在默认控制台下是乱码

- **现象**：`L30` 的 `echo 脚本执行完毕，共运行 %max% 次。` 是 UTF-8 字节；脚本全文没有任何 `chcp` 调用，沿用父控制台的 936 代码页。
- **位置**：`power-key.bat:1`（无 `chcp`）、`power-key.bat:30`（UTF-8 中文 `echo`）
- **根因**：`cmd.exe` 按**当前代码页**解释批处理字节流里的 `echo` 参数。UTF-8 三字节序列在 936 下被按字节拆开映射，产生乱码；句末的 `。`（U+3002，UTF-8 为 `e3 80 82`）退化成一个 `?`。用该行的**原始字节**在 cp936 下实测：输出末字节变成 `3f`（`?`）；同一份字节在 cp65001 下则完整保留 `e3 80 82`。
- **影响**：用户看不到这行完成提示——而它恰恰是脚本**唯一**的收尾反馈（前 100 轮的进度行 `L16` 也只依赖 `%time%`，没有成功/失败汇总）。乱码不影响任何 `adb` 调用，属"看起来能跑但反馈失效"。同文件 `L4/L11/L13/L18/L20/L23` 的中文 `::` 注释同样乱码，但注释不参与执行。
- **修复建议**（三选一，① 最省事）
  ```bat
  :: ① 在 @echo off 之后加一行（推荐）
  chcp 65001 >nul

  :: ② 或把 L30 改成 ASCII 英文，与 auto_shot.bat / push_*.bat 的纯英文风格一致
  echo Finished. Ran %max% iterations.

  :: ③ 或把整个文件另存为 GBK，并加 chcp 936
  ```

#### L-02 两个脚本的 `title` 完全相同，窗口无法区分

- **现象**：`disp_continuous_monitor.bat:3` 与 `备用脚本\monitor.bat:3` 都写 `title Continuous Log Monitor`。
- **位置**：`disp_continuous_monitor.bat:3`、`备用脚本\monitor.bat:3`
- **根因**：`备用脚本\monitor.bat` 是从 `disp_continuous_monitor.bat` 复制派生的（两者 L1–L17 逐字节相同，见 3.2），派生时没改 `title`。
- **影响**：同时开两个窗口时无法凭标题栏判断哪个在跑，容易关错窗口——而错误地关掉 `disp_continuous_monitor` 的 `Dmesg` 窗口（`L51`）会直接丢掉 `dmesg -w` 采集。
- **修复建议**
  ```bat
  :: 备用脚本\monitor.bat:3
  title Legacy Continuous Monitor (getevent+logcat+dmesg)
  ```

#### L-03 `:reg_fmt_detect` 在"读 TYPE 寄存器失败"时返回**成功**，`regfmt` 停在默认 `hex`

- **现象**：`L726` 调 `:reg_read` 读 TYPE，`L727` 失败时直接 `exit /b 0`（返回**成功**），`regfmt` 保持 `L725` 设的 `hex`。
- **位置**：`PM_GPIO_CTRL-mimo.bat:723-731`（关键行 `L725`、`L726`、`L727`）
- **根因**：把"探测失败"当成"用默认值继续"处理，且三名调用点（`L334`、`L411`、`L443`）都不检查返回值。
- **影响**：若设备的 `data` 文件其实是**十进制**（`regfmt` 本应为 `dec`），而 TYPE 那一次读恰好失败，则 `regfmt` 停在 `hex` → `:reg_parse`（`L714`）给值拼上 `0x` 前缀 → 位运算整体错位（例如十进制 `128` 被当成 `0x128`=296）。属"双重故障叠加才触发"，故定低。
- **修复建议**：让探测失败成为可感知的事件，而不是静默降级。
  ```bat
  :reg_fmt_detect
  if defined PM_REGFMT exit /b 0
  set "PM_REGFMT="
  call :reg_read !OFF_TYPE!
  if errorlevel 1 (
      echo       [WARN] cannot read TYPE register - assuming hex data format
      set "PM_REGFMT=hex"
      exit /b 1
  )
  ```

#### L-04 `:dec2hex` 在寄存器值最高位为 1 时会产生脏串（低概率、高后果）

- **现象**：`:reg_read` 把 `data` 读回值经 `:reg_parse` 转成 `read_num` 后，若该值最高位为 1（如 `0xFFFFFFFF`、`0x80000000`），`read_num` 是**负数**，`L738` 的余数随之变负，`L739` 的负偏移在 cmd 里是"从末尾倒数"，于是吐出**错误的单个十六进制位**（不是报错，也不是空串）。
- **位置**：`PM_GPIO_CTRL-mimo.bat:734-743`（关键行 `L738 set /a "dhn=dhv %% 16"`、`L739 set "hexout=!HEXD:~%dhn%,1!!hexout!"`）
- **根因**：`set /a` 是 **32 位有符号**整数运算，手写的进制转换没有考虑负输入；而 `!VAR:~-N,1!` 在 cmd 里不是"越界报错"，而是**从字符串末尾倒数取字符**，所以负 `dhn` 会静默取到一个真实存在的字符。
- **影响**：**先明确一件事以免误读**——该子程序对 `0 / 1 / 15 / 16 / 128 / 240 / 255 / 4095 / 65535 / 16777215` 的输出**全部正确**，正常取值范围内**没有 bug**。GPIO 实际用到的位域（`MODE_CTL` 的 bit6:4、`OUT_SRC_CTL` 的 bit7、`DIG_OUT_CTL` 的 bit5:0）都在低 8 位，所以 `:set_dir`(`L353`)/`:set_drive`(`L418`) 的读改写在正常硬件上不会触发。只有当某些 regmap debugfs 实现让 `data` 返回 `0xFFFFFFxx` / `0x80000000` 这类值时才会触发。

  负输入下的实际输出（本轮实测，输入为 `set /a` 求值后的有符号数）：

  ```
  dec2hex(-1)          = 0xF      ← 错（应为 0xFFFFFFFF）
  dec2hex(-2)          = 0xE      ← 错
  dec2hex(-15)         = 0x1      ← 错
  dec2hex(-16)         = 0x0      ← 错
  dec2hex(-128)        = 0x0      ← 错
  dec2hex(-256)        = 0x0      ← 错
  dec2hex(-2147483648) = 0x0      ← 错
  dec2hex(0xFFFFFF80)  = 0x0      ← 错
  dec2hex(0x80000000)  = 0x0      ← 错
  ```

  表现为**一个远小于真实值的 1 位十六进制数**（`0xF` / `0x0` 等）。若这个值被写进 `address` 寄存器，后续 `data` 会落到完全错误的偏移——属"低概率、高后果"。
- **修复建议**：加一道范围护栏即可，简单且彻底。
  ```bat
  :dec2hex
  set /a "dhv=%~1" 2>nul
  if !dhv! lss 0 (
      echo       [FAIL] dec2hex: negative value !dhv! - register width assumption broken
      exit /b 1
  )
  if !dhv! gtr 0xFFFFFF exit /b 1
  ...
  ```

#### L-05 `push_msm_drm_ko.bat` 少了 `push_apk.bat` 里那一步 `chmod`，两个脚本不一致

- **现象**：`push_apk.bat:24` 有 `adb shell chmod 644 /vendor/overlay/FrameworksResOverlay_Wear.apk`；`push_msm_drm_ko.bat` 的 `[6/7]` 段（`L22-24`）只有 `ls -l`，**没有 chmod**。
- **位置**：`push_apk.bat:24`、`push_msm_drm_ko.bat:22-24`
- **根因**：两份脚本是同源复制，派生出 `.ko` 版本时删掉了 `chmod`（`push_apk.bat` 是 7 步，`push_msm_drm_ko.bat` 名义上也是 7 步，但 `[6/7]` 少了一个动作）。
- **影响**：`.ko` 落盘后的权限取决于源文件权限与 remount 状态；某些构建里 kernel module 需要严格的 `644`（且不可执行）。两脚本行为不一致，让人无法判断这是遗漏还是有意为之。
- **修复建议**：明确二选一，并在注释里写清理由。
  ```bat
  :: 若需要 644（推荐，与 push_apk.bat 对齐）
  adb shell chmod 644 /vendor_dlkm/lib/modules/msm_drm.ko
  :: 若确认不需要（vendor_dlkm 由 kernel 侧处理权限），就把注释补上：
  :: [6/7] Verify only - chmod NOT needed here because <理由>
  ```

#### L-06 `adb bugreport` 无超时、无失败判定、无磁盘空间预检

- **现象**：`disp_continuous_monitor.bat:84` 与 `备用脚本\capture_disp_log.bat:36` 都是裸的 `adb bugreport "<绝对路径>"`，前后没有任何判定。
- **位置**：`disp_continuous_monitor.bat:83-84`、`备用脚本\capture_disp_log.bat:35-36`
- **根因**：把 `bugreport` 当作"一定会成功"的一步；`bugreport` 是整条流程里最慢的一步（脚本 `L83` 自己写了 `1-3 minutes`），却没有超时、没有 `errorlevel` 检查、没有"磁盘是否够"的预检。
- **影响**：磁盘紧张时 `bugreport.zip` 是**截断的 zip**，脚本仍打印 `Done!`。更隐蔽的是：若此时后台 `logcat` 窗口还在跑（BLK-01），两者共享同一条 adb 连接，可能互相拖慢甚至超时。
- **修复建议**
  ```bat
  echo Generating bugreport (1-3 min)...
  adb bugreport bugreport.zip
  if errorlevel 1 (
      echo [WARN] bugreport failed or truncated
  ) else (
      for %%z in (bugreport.zip) do if %%~zz LSS 1000000 echo [WARN] bugreport suspiciously small (%%~zz bytes)
  )
  ```

#### L-07 `adb reboot` 不判退出码，最后一步的失败最容易被忽略

- **现象**：`adb reboot` 之后紧接着就打印 `OK: Reboot command sent. Script finished.`，中间没有 `errorlevel` 判定。
- **位置**：`push_apk.bat:27-29`、`push_msm_drm_ko.bat:26-28`
- **根因**：把 `reboot` 当作"发出去就算成功"的收尾动作。
- **影响**：设备掉线 / 多设备 / 权限不足时，`adb reboot` 只是把错误打到 stderr，脚本照样打印 OK。用户在"以为已经重启"的状态下拔线，下次连上发现模块还是旧的——而这个"旧的"往往是因为前面几步其实也没成，只是前面几步同样没报错。
- **修复建议**
  ```bat
  adb reboot
  if errorlevel 1 (
      echo       FAIL: reboot failed - do NOT unplug. Check "adb devices".
      pause & exit /b 1
  )
  echo       OK: Reboot sent. Wait ~60s, then verify:
  echo            adb shell ls -l /vendor_dlkm/lib/modules/msm_drm.ko
  ```

#### L-08 `2>nul` 与 `>nul 2>&1` 用法全仓不统一，且 `set /a ... 2>nul` 恰好吞掉了关键报错

- **现象**：同一仓库里两种写法混用，且**裸 `2>nul` 只重定向 stderr、不重定向 stdout**。
  - `>nul 2>&1`：`auto_shot.bat:27,30,42,45`、`disp_continuous_monitor.bat:72,74`、`PM_GPIO_CTRL-mimo.bat:265,684,701`
  - 裸 `2>nul`：`current_display.bat:19,25,30`、`disp_continuous_monitor.bat:19,25,30,59,64`、`push_apk.bat:16`、`push_msm_drm_ko.bat:16`、`备用脚本\capture_disp_log.bat:17`、`PM_GPIO_CTRL-mimo.bat:88,102,717,735`
- **位置**：见上（关键行 `PM_GPIO_CTRL-mimo.bat:88`、`PM_GPIO_CTRL-mimo.bat:102`）
- **根因**：没有统一的静默约定，属"随手写"。
- **影响**：在 `for /f` 里搭配 `2^>nul` 时极易出错（详见 H-06）；而 `PM_GPIO_CTRL-mimo.bat:88,102` 的 `set /a ... 2>nul` 正好吞掉了八进制输入的 `Invalid number.` 报错，**这是 M-02 能长期潜伏的直接原因**。
- **修复建议**：全仓统一"要静默就 `>nul 2>&1`"；只在明确只关心 stderr 的地方用裸 `2>nul` 并加注释说明。**唯独 `set /a` 处的 `2>nul` 建议直接去掉**，让非法输入当场暴露。

#### L-09 四个抓取脚本的输出命名没有统一约定

- **现象**：四份脚本对同类产物用了四套命名：
  - `current_display.bat:24-34` → `*_current.txt`
  - `disp_continuous_monitor.bat:24-34`、`:58-67` → `*_before.txt` + `*_after.txt`
  - `备用脚本\capture_disp_log.bat:20-33` → 裸名 `*.txt`
  - `备用脚本\monitor.bat:25,31,34` → `logcat.txt` + `dmesg.log` + `getevent.log`（`.txt` 与 `.log` 混用）
- **位置**：上列各行
- **根因**：四份副本各自演化，没有命名规范。
- **影响**：跨脚本汇总/比对时无法用一个通配符扫全；`.txt`/`.log` 混用让"按扩展名过滤"失效。
- **修复建议**：统一 `<item>_<phase>.<ext>`，扩展名择一（推荐 `.txt`），例如 `logcat_before.txt` / `logcat_after.txt` / `dmesg_before.txt`。

#### L-10 `power-key.bat` 的变量名 `max` / `i` 过于通用

- **现象**：`L5 set max=100`、`L6 set i=1`、`L9 if %i% gtr %max% goto end`。
- **位置**：`power-key.bat:5,6,9`
- **根因**：随手命名，没有遵循同仓库其它脚本的 `UPPER_SNAKE` 习惯。
- **影响**：本脚本有 `setlocal`（`L2`），不会外泄，所以**不影响执行**；但作为同目录下的第 9 个脚本，它与 `SAVE_DIR` / `PHONE_PATH` / `REGMAP` / `OFF_*` 的风格割裂，且 `i` / `max` 这种名字在 `PM_GPIO_CTRL-mimo.bat`（无 `setlocal` 隔离父环境，见 M-16）那种脚本里会直接引发冲突。
- **修复建议**：改为 `MAX_ITER` / `ITER`，并在 `PM_GPIO` 侧统一加 `PM_` 前缀。

---

### 2.5 不需要整改 / 已核实为正确写法（防止误报）

以下几条在初稿里曾被列为缺陷，经逐字节/探针复核后**确认不是问题**，明确写在这里，避免后续被"顺手改坏"。

#### N-01 UNC 双反斜杠是**正确**写法，不是转义错误

- **位置**：`push_apk.bat:19`、`push_msm_drm_ko.bat:19`
- 逐字节核对（hex）确认磁盘上就是两个反斜杠 `5c 5c`，后面跟 `10.71.255.189\...`。`.bat` 文件里**没有反斜杠转义语义**，UNC 前缀恰好就是两个反斜杠。路径合法、已用双引号包裹。**不要改成一个反斜杠**，那会真的坏掉。
- 这条路径真正的问题是**硬编码内网地址**（见 M-11），与反斜杠写法无关。

#### N-02 9/9 文件 CRLF 一致、全部无 BOM——不需要整改，但**任何人都不得改成 LF**

- 逐字节统计：9 个文件的独立 LF 数均为 0、BOM 均为无。这是本批代码最好的一个属性。
- **警告**：`.bat` 对换行极其敏感。实测把一份内容完全相同、仅换行改为 LF 的脚本拿去跑，`chcp 65001` 被拆成 `chcp` + `65001`、`set` 行被拆、`if` 行被拆，满屏 `'5001' is not recognized`、`'A]' is not recognized`，脚本直接碎掉。**任何"格式化/统一换行"的操作都必须保留 `eol=crlf`**（`.gitattributes` 写 `*.bat text eol=crlf`，不要写成 `eol=lf`）。

#### N-03 文件末尾缺换行对 `cmd.exe` **没有功能影响**，只是 diff 噪音

- 实测：8/9 文件末行无行尾（仅 `PM_GPIO_CTRL-mimo.bat` 以 CRLF 结尾）。`cmd.exe` 会把最后一行的 EOF 当行结束，`echo` / `goto` / `exit /b` 全部正常。
- 影响仅限：`diff`/代码评审显示 `\ No newline at end of file`；某些老式打包工具拼接末行时会粘连。**不必逐文件手改**。

#### N-04 GBK 注释**不会**破坏解析；`PM_GPIO_CTRL-mimo.bat` 不加 `chcp 65001` 是**合理的**

- `PM_GPIO_CTRL-mimo.bat` 是 GBK（766 行中 77 行含中文，全部是 `::` 注释行），且全文**没有任何 `chcp`**。
- 复核结论：这些注释行在 cp936 与 cp65001 两种代码页下都能被正常跳过，不会产生语法错误；也**不存在**"GBK 尾字节恰好是 `| & > < % ^ ( ) " !` 等元字符"的危险行，所以没有"中文吞掉引号/管道"的隐患。
- 该文件的**所有输出都是纯 ASCII**，因此**不需要** `chcp 65001`；盲目加反而会让中文注释在编辑器之外显示错乱。正确做法是"**把文件转码成 UTF-8**"（并保留 GBK 备份），而不是加 `chcp`。
- 真正的风险在运行期之外：只要有人用 VS Code / Notepad++ 以默认 UTF-8 打开并保存一次，77 行注释就会全部损坏。建议在仓库根放 `.editorconfig`（`charset=utf-8`）+ `.gitattributes`，并做一次转码提交。

#### N-05 `power-key.bat` 的 UTF-8 无 `chcp` 是**真 bug**，但只影响显示

- **位置**：`power-key.bat:1`（无 `chcp`）、`L30`（UTF-8 中文 `echo`）
- 实测（用该行原始字节在 cp936 下执行）：末字节 `e3 80 82`（`。`）退化为 `3f`（`?`），整行呈乱码；同一份字节在 cp65001 下则完全正常。
- 即：**唯一的收尾提示在默认 936 控制台下是乱码**。因为它不影响任何 `adb` 调用与执行逻辑，严重度按"低"处理（见 L-01 的修复建议）。

#### N-06 `adb bugreport "%OUT%\bugreport.zip"` 的路径拼接与引号写法正确

- **位置**：`disp_continuous_monitor.bat:84`、`备用脚本\capture_disp_log.bat:36`
- 逐字节确认磁盘上是 `"%OUT%\bugreport.zip"`（单个反斜杠）。`%OUT%` 由 `%~dp0` 派生且**不带尾随反斜杠**，拼出来路径正确。这两行本身没有写法问题；它们的真问题是"不检查退出码、无超时、无空间预检"（见 L-06）。

---

## 3. 跨脚本共性缺陷与重复代码

### 3.1 全局统计：失败判定的覆盖率

（统计口径：注释行 `::` / `rem` 不计；`adb` 调用按"含 `adb <子命令>` 的实时行"计；校验数按 `errorlevel` / `&&` / `||` 出现次数计。）

| 脚本 | 实时 adb 调用 | 校验计数 | 设备预检 | 清理步骤 | 退出码语义 |
|---|---|---|---|---|---|
| `PM_GPIO_CTRL-mimo.bat` | 21 | 40 | ✅ `get-state`(L265,684) | 不需要（无临时文件） | 0/1/2/3（见 M-15） |
| `disp_continuous_monitor.bat` | 29 | **0** | ⚠️ 仅 `wait-for-device`(L13) | ❌ 无 | ❌ 无 |
| `current_display.bat` | 13 | **0** | ⚠️ 同上 | 无 | ❌ 无 |
| `备用脚本\capture_disp_log.bat` | 11 | **0** | ⚠️ 同上 | 无 | ❌ 无 |
| `备用脚本\monitor.bat` | 6 | **0** | ⚠️ 同上 | ❌ 无 | ❌ 无 |
| `push_apk.bat` | 8 | 7 | ❌ 无 | 无 | ⚠️ 两套语义混用 |
| `push_msm_drm_ko.bat` | 7 | 7 | ❌ 无 | 无 | ⚠️ 同上 |
| `auto_shot.bat` | 6 | **0** | ❌ 无 | 无 | ❌ 无 |
| `power-key.bat` | 2 | **0** | ❌ 无 | 无 | ❌ 无 |
| **合计** | **103** | 54 | — | — | — |

> 口径说明（本轮复核已对齐）：`PM_GPIO_CTRL-mimo.bat` 的真实 adb 调用是 **21** 处（21 行、每行 1 次），不是 22 —— 上一版把 `L663` 的 `echo    - Device connection    adb devices`（**纯提示文本，不是调用**）算了进去。`chk_stats.py` 报 22 就是因为把这条 `echo` 计入了。其余 8 个脚本的数字不变，故合计由 104 修正为 **103**。

**关键数字**：4 个日志抓取脚本合计 **59 条 adb 调用、0 处退出码校验**，而它们的结尾统一是 `Done! Logs saved to: %OUT%`。**产出一堆空文件也报成功**——这是这批脚本最大的共性问题，比任何一个单点 bug 都更值得优先处理。

### 3.2 四个抓取脚本的重复度（实测 diff）

| 对比 | diff 结果（本轮实测复核） | 结论 |
|---|---|---|
| `current_display.bat` vs `disp_continuous_monitor.bat` | 4 个 hunk：`3c3`（`title`）、`22,33c22,33`（`_current` → `_before` 后缀）、`35a36,85`（后半段多出 after 快照 / 截图 / bugreport）、`40c90`（`pause` → `exit`） | **L1–L21 逐字节相同**（仅 `3c3` 一行 title 不同） |
| `disp_continuous_monitor.bat` vs `备用脚本\monitor.bat` | 首个 hunk 是 `18d17`（少了 `echo Creating output dir...`），随后从 `22` 起整体错位（`22,43c21,22` 等 8 个 hunk） | **L1–L17 逐字节相同** |
| `备用脚本\capture_disp_log.bat` vs `current_display.bat` | 9 个 hunk：`3c3`（`title`）、`4a5`/`9a11`/`15a17`（多 3 行 `:: =====` 分节注释）、`12,13c14`、`19,29c22,34`（抓取方式不同：capture 用 `"%OUT%\..."` 绝对路径且不 `cd`）等 | **时间戳代码块（`for /f ... set "date"`…`set "OUT=%OUT: =0%"`）完全一致**——逐行 diff 该 4 行块为 0 差异 |

也就是说，**同一段"取时间戳 + 建目录 + 等待设备 + dumpsys 九连"被复制了 4 份**。这直接导致了两类已经发生的漂移：

1. **改了 3 个漏 1 个**：`logcat -c` 只有 `备用脚本\monitor.bat:28` 有，其余 3 个没有（H-03）。
2. **抓取项矩阵不一致**——换个脚本抓，就少几样证据：

| 抓取项 | current_display | disp_continuous_monitor | capture_disp_log | monitor |
|---|---|---|---|---|
| `logcat -d -b all` 快照 | ✅ L24 | ✅ L24 + L58 | ✅ L20 | ❌ |
| 实时 `logcat`（`start`） | ❌ | ✅ L49 | ❌ | ✅ L31 |
| `dmesg` 快照 | ✅ L25 | ✅ L25 + L59 | ✅ L23 | ❌ |
| 实时 `dmesg -w` | ❌ | ✅ L51 | ❌ | ✅ L34 |
| `getevent -tlr` | ❌（L45 注释） | ❌（L45 注释） | ❌ | ✅ L25 |
| **清缓冲 `logcat -c`** | ❌ | ❌（L47 注释） | ❌ | ✅ L28 |
| `dumpsys display/sf/input/power` | ✅ L26-29 | ✅ L26-29 + L60-63 | ✅ L26-29 | ❌ |
| `dumpsys meminfo` / `window` | ✅ L31-32 | ✅ L31-32 + L65-66 | ❌ **缺** | ❌ |
| `dumpsys gpu` | ✅ L30 | ✅ L30 + L64 | ❌ | ❌ |
| `getprop` | ✅ L33 | ✅ L33 + L67 | ✅ L32 | ❌ |
| `/proc/cmdline` | ✅ L34 | ✅ L34 | ✅ L33 | ❌ |
| 截图 | ❌ | ✅ L71-74 | ❌ | ❌ |
| `bugreport` | ❌ | ✅ L84 | ✅ L36 | ❌ |
| 前后对比 | ❌（只有 after） | ✅（before + after） | ❌ | ❌ |

**建议：合并为一个带参数的脚本。** 四份副本的存在价值已经低于维护成本，且它们的分歧本身就是 bug 来源。

```bat
:: adb_collect.bat
::   /mode:snapshot | continuous   快照 或 连续抓取
::   /dur:60                       连续抓取时长（秒），到点自动停
::   /tag:before | after | single  输出文件名后缀
::   /items:logcat,dmesg,dumpsys,screenshot,bugreport
::
:: 内部固定流程：
::   1) pushd 到输出目录（失败即退）
::   2) 可选 adb logcat -c -b all
::   3) 按 items 逐项抓取，每项判 errorlevel 并累计 FAILS
::   4) 连续模式下用带轮转的 adb logcat -n 16 -r 65536，timeout /t %DUR% 自动停
::   5) 结尾：if defined FAILS (echo [WARN] %FAILS% item(s) failed) else (echo [OK] all items captured)
```

迁移时的分配建议：

- `current_display.bat` → `adb_collect.bat /mode:snapshot /tag:single`
- `disp_continuous_monitor.bat` → 两次调用：`/mode:snapshot /tag:before` + `/mode:continuous /dur:%DUR% /tag:after`
- `备用脚本\capture_disp_log.bat` → `/mode:snapshot`，补齐 `meminfo` / `window` / `gpu`
- `备用脚本\monitor.bat` → `/mode:continuous`，把 `getevent` 做成可选 item（默认关）
- 旧的 4 份保留但加废弃提示：`echo [DEPRECATED] use adb_collect.bat - see BAT_SCRIPTS_ANALYSIS.md`

### 3.3 四个共性缺陷（同一段代码复制 4 份，所以每条要改 4 处）

| 缺陷 | 位置 | 一句话 |
|---|---|---|
| `%OUT: =0%` 破坏含空格路径 | 4 脚本 L9/L9/L8/L9 | H-01 |
| 覆盖 `date`/`time` + 无 `setlocal` | 4 脚本 L6-9（capture_disp_log 为 L5-8） | H-02 |
| `wait-for-device` 无超时 + `adb root` 不判 | current_display:13,15｜disp:13,15｜monitor:13,15｜capture_disp_log:11,14 | M-04 |
| `mkdir` / `cd` 不判返回值 | 3 脚本 L19-20（current_display/disp）与 L18-19（monitor）+ capture_disp_log L17（只有 `mkdir`，无 `cd`） | M-03 |

### 3.4 四个 push/调试脚本的共性

1. **"用文本匹配代替退出码"**：`push_apk.bat:6,9,16`、`push_msm_drm_ko.bat:6,9,16` 共 6 处。这三个位置恰好是"root / remount / 删除验证"——**最需要准确判定的三步**。
2. **失败分支里 `pause` 在 `exit /b` 之前**：`push_apk.bat:9,20`、`push_msm_drm_ko.bat:9,20`。共 4 处，全部会在失败时阻塞无人值守调用。
3. **`adb reboot` 不判定**：`push_apk.bat:28`、`push_msm_drm_ko.bat:27`（L-07）。
4. **版本不一致**：`push_apk.bat` 有 `chmod 644`（L24），`push_msm_drm_ko.bat` 没有（L-05）。两个脚本都写了 `[1/7]`…`[7/7]` 七步，但 `push_msm_drm_ko.bat` 的 `[6/7]`（L22）只有 `ls -l`、缺了 `chmod` 这个动作——步数对得上，**内容不对等**。

### 3.5 命名与硬编码的一致性

- 变量命名风格两套：`UPPER_SNAKE`（`SAVE_DIR` / `PHONE_PATH` / `REGMAP` / `OFF_*`）与全小写裸名（`max` / `i` / `cli` / `iface` / `chip` / `regfmt` / `file` / `ts` / `out_val`）。后者正是 M-16 的成因。
- 硬编码清单（跨脚本汇总，逐条带行号）：

| 类别 | 值 | 位置 |
|---|---|---|
| 内网 IP / 共享 | `10.71.255.189` / `yxb_sdc1` | `push_apk.bat:19`、`push_msm_drm_ko.bat:19` |
| 个人账号目录 | `kdo_nj` | `push_apk.bat:19` |
| 私有构建树 | `...\product\neo\vendor\overlay\...` | `push_apk.bat:19` |
| 私有构建树 | `kc3\VENDOR\...\product\vienna\dlkm\...` | `push_msm_drm_ko.bat:19` |
| 包名 / Activity | `com.android.camera2` / `...CameraActivity` | `auto_shot.bat:27,30,45` |
| 屏幕坐标（分辨率相关） | `TAP_X=243` / `TAP_Y=512` | `auto_shot.bat:8-9,33` |
| 设备路径 | `/sdcard/DCIM/Camera` | `auto_shot.bat:10` |
| 设备路径 | `/sdcard/screenshot.png` | `disp_continuous_monitor.bat:71,72,74` |
| 设备路径 | `/vendor/overlay/FrameworksResOverlay_Wear.apk` | `push_apk.bat:12,16,19,23,24` |
| 设备路径 | `/vendor_dlkm/lib/modules/msm_drm.ko` | `push_msm_drm_ko.bat:12,16,19,23` |
| GPIO 地址规律 | `0xE800 + (N-1)*0x100`，`hb=0xE8+n-1` | `PM_GPIO_CTRL-mimo.bat:7-8,166` |
| 寄存器偏移表 | `04/05/10/40/41/44/45/46` | `PM_GPIO_CTRL-mimo.bat:50-57,690` |
| regmap 路径 | `/d/regmap/1-00` | `PM_GPIO_CTRL-mimo.bat:48` |
| 循环次数 / 间隔 | `max=100`、`INTERVAL=3`、`CAMERA_WAIT=2` | `power-key.bat:5`、`auto_shot.bat:6-7` |

---

## 4. 修复优先级与建议执行顺序

排序原则：**先修"会骗人"的，再修"会崩"的，最后修"难维护"的**。同一批次内的条目可以并行改。

#### P0 — 立即修（每一条都在"静默骗人"或"必然残留"）

| 序 | 条目 | 位置 | 最小改动 | 好处 |
|---|---|---|---|---|
| 1 | **BLK-01** 子窗口零回收 | `disp_continuous_monitor.bat:49,51,54,90`；`备用脚本\monitor.bat:25,31,34,37,40` | `pause` 后加 3 行 `taskkill` | 消灭进程残留 + 磁盘被灌满的根源 |
| 2 | **H-01** `%OUT: =0%` | 4 脚本 L9/L9/L8/L9 | 删掉那一行的全局替换，只替换时间戳 | 消灭"日志写进影子目录" |
| 3 | **H-04** `adb root \| findstr` | `push_apk.bat:6`、`push_msm_drm_ko.bat:6` | 改 `adb get-state` + `errorlevel` | 让"没连设备"能被报出来 |
| 4 | **H-05** `adb remount \| findstr` | `push_apk.bat:9`、`push_msm_drm_ko.bat:9` | 改 `adb remount` + `errorlevel`，去掉 `pause` | 让 remount 失败可见、不阻塞 |
| 5 | **H-06** `findstr "No such file"`（`2>nul` 位置 + 子串 OR 两层） | `push_apk.bat:16`、`push_msm_drm_ko.bat:16` | 改 `adb shell "test -e ..."` + `errorlevel` | 让"旧文件删没删"可信 |
| 6 | **H-08 + H-09** 写入/回读失败报 OK | `PM_GPIO_CTRL-mimo.bat:689-695`、`303-317` | 回读失败 → `goto step_error` | 让 GPIO 写入结果可信 |

> P0 共 6 组、涉及 6 个文件。**这 6 组修完后，脚本"报成功"这件事才开始有意义。**

#### P1 — 紧随其后（数据正确性）

| 序 | 条目 | 位置 |
|---|---|---|
| 7 | **H-02** 时间戳：覆盖 `date`/`time` + 码页依赖 + 无 `setlocal` | 4 脚本 L6-9 |
| 8 | **H-03** `logcat` 清缓冲与轮转 | `disp_continuous_monitor.bat:47,49`；另 3 脚本 |
| 9 | **H-07** 设备序列号绑定 | `PM_GPIO_CTRL-mimo.bat:265-266,682-685` + 全文 21 处 `call adb` |
| 10 | **M-02** 八进制 GPIO 号 | `PM_GPIO_CTRL-mimo.bat:101-104` |
| 11 | **M-11** 硬编码 UNC 路径 → 参数化 | `push_apk.bat:19`、`push_msm_drm_ko.bat:19` |

> 第 7 项**必须早于**任何"新建目录"的操作，否则历史目录名会与新目录名混在一起。

#### P2 — 健壮性补齐

| 序 | 条目 |
|---|---|
| 12 | M-03 `mkdir`/`cd` 返回值（4 脚本） |
| 13 | M-04 `wait-for-device` 无超时 + root 后重等（4 脚本） |
| 14 | M-05 / M-13 `auto_shot.bat` 假成功与硬编码坐标 |
| 15 | M-07 `power-key.bat` 循环内判定 |
| 16 | M-08 / M-09 `PM_GPIO` 的解析与 gpiod 路径 |
| 17 | M-10 push 脚本的 `rm` 判定与 `pause` 位置 |
| 18 | M-01 裸 `exit`（按需，见该条的方案 A/B） |
| 19 | M-15 退出码细分 |

#### P3 — 一致性 / 可维护性

| 序 | 条目 |
|---|---|
| 20 | **3.2 合并四件套为 `adb_collect.bat`**（一次性消除 4 份副本） |
| 21 | L-01 `power-key.bat` 加 `chcp`（1 行） |
| 22 | L-02 title、L-05 chmod、L-09 命名、L-10 变量名 |
| 23 | L-03 / L-04 `PM_GPIO` 的边缘路径 |
| 24 | L-06 / L-07 `bugreport` / `reboot` 判定 |
| 25 | L-08 `2>nul` 统一 |
| 26 | M-17 注释里的旧文件名 |

#### 执行顺序上的三条硬约束

1. **P0-1（BLK-01）与 P0-2（H-01）必须一起上**。只修 H-01 而不修 BLK-01，日志会正确地写进正确目录——然后无限增长把盘写满。
2. **P1-7（时间戳）上线前，先把历史 `LOGS_*` 目录归档**。时间戳格式一旦改变（`LOGS_20261103_1129` 变成 `LOGS_20261103_112936`），新旧目录会在同一父目录下共存；如果后续有脚本按名字排序，会读到两种格式。
3. **P3-20（合并四件套）必须放在 P0/P1 之后**。先合并再修 bug，等于把 4 个已知 bug 搬进新文件，还多了"旧版是否还有人在用"的不确定性。**先让每个脚本都正确，再谈合并。**

---

## 5. 待确认项

以下条目**静态分析无法定论**，需要真机、特定 adb 版本或原作者确认。**不要把它们当作已确认的缺陷写进任何下游结论。**

#### Q-01 `adb shell` 的远端 stderr 到底走本机 stdout 还是 stderr

- **相关**：H-06（`2>nul` 在管道左侧）、`push_apk.bat:16`、`push_msm_drm_ko.bat:16`
- **为何无法定论**：这在**不同 adb 版本/不同平台**上行为不同。某些版本把远端 stderr 合并进本机 stdout，某些版本单独转发。我只能用 stub 证明"若走 stderr 则 `2>nul` 会吞掉"（这是 cmd 语义，确定），但**不能确定**真机上走哪条。
- **验证方法**：接一台设备，执行 `adb shell "echo AAA 1>&2" 2>nul | findstr AAA`，看是否命中。命中 = 走 stdout（当前写法侥幸可用）；不命中 = 走 stderr（H-06 在真机上成立）。
- **无论结果如何都建议修**：改用 `test -e` + `errorlevel`，两种实现下都正确。

#### Q-02 `PM_GPIO_CTRL-mimo.bat` 注释里承诺的"内核拒绝 SPMI 写时脚本会报错"，到底是"没实现"还是"曾实现过"

- **相关**：H-08、`PM_GPIO_CTRL-mimo.bat:32-34` vs `:689-695`
- **已确定的部分**：`echo > /d/regmap/.../data` 在内核拒绝时，**远端 shell 仍返回 0** 是 Linux 重定向语义决定的；`adb shell` 于是返回 0；`L692/L694` 的 `errorlevel` 判定不成立。这条**是确定的**。
- **待确认**：内核拒绝时 `/d/regmap/.../data` 的**回读值**是什么？是保持旧值、还是变成 `0`？这决定 H-08 的"回读校验"方案中，`want != read` 这条能否区分"被拒绝"与"值本来就没变"。需要真机 + 一个已知会被拒绝的地址来验证。
- **需要**：原作者确认 `L32-34` 的注释是基于实测还是"理论上会"。

#### Q-03 `:reg_fmt_detect` 在目标设备上实际判定成 `hex` 还是 `dec`

- **相关**：M-08（`set /a` 单 token 漏检）、L-03（探测失败退回 `hex`）
- **为何无法定论**：这取决于目标 SoC 的 regmap debugfs 实现——`data` 文件读回的是 `0x16` 还是 `16`。脚本 `L728-730` 用"读回字面是否等于 `16`"来判断，说明作者见过 `dec` 的机器。
- **需要**：在目标设备上 `adb shell "cat /d/regmap/1-00/data"` 看实际格式（这一步需要设备，本次审计未做）。

#### Q-04 `adb root` 之后需要等待多久才能重新连上

- **相关**：M-04 的修复片段里我写了 `timeout /t 3`，这个值是**经验值，未经本机实测**。不同平台（userdebug 与 eng）、不同 adbd 重启速度差异很大。
- **建议**：修复时不要用固定 `timeout`，改用轮询。**注意 `goto` 和标签不能写在 `( )` 括号块内部**——本轮实测这种写法直接报 `) was unexpected at this time.` 并中止脚本，所以正确的写法是把标签放在块外的顺序流里：

  ```bat
  adb root >nul 2>&1
  if errorlevel 1 goto root_failed
  echo [INFO] adbd restarting, polling for it to come back...
  set /a "retry=0"
  :wait_root
  adb get-state >nul 2>&1 && goto root_ok
  set /a "retry+=1"
  if !retry! gtr 20 (
      echo [FAIL] adbd did not come back after 20s
      exit /b 1
  )
  timeout /t 1 /nobreak >nul
  goto wait_root
  :root_ok
  echo [OK] adbd is back
  goto after_root
  :root_failed
  echo [WARN] "adb root" failed - dmesg/dumpsys may be incomplete or empty.
  :after_root
  ```

  > 上一版把 `:wait_root` / `:root_ok` 写在 `if not errorlevel 1 ( ... )` 内部，**那是跑不起来的**，已按上面的形式改正（本轮实测新写法可用）。

#### Q-05 四个抓取脚本"目标场景"是什么——决定 `logcat -c` 该开还是该关

- **相关**：H-03、`disp_continuous_monitor.bat:47`（`logcat -c` 被注释）vs `备用脚本\monitor.bat:28`（启用）
- **为何无法定论**：如果场景是"复现一个偶发问题"，那**保留历史缓冲**是对的（现场证据可能已经被覆盖）；如果是"对比复现前后"，那**必须清缓冲**（否则基线里掺着开机以来的日志）。两种需求相反，而代码里**没有任何注释说明为什么选了这一种**。
- **需要**：原作者说明 `L45`（`getevent` 被注释）与 `L47`（`logcat -c` 被注释）这两处"功能开关"的用意。在此之前，建议按 3.2 的合并方案做成显式参数 `/clearlog:0|1`。

#### Q-06 `PM_GPIO_CTRL-mimo.bat` 的 766 行里，`L37-45` 的 8 处 `PM_GPIO_CTRL-new.bat` 是笔误还是"另有一个 -new 版本仍在别处使用"

- **相关**：M-17
- **待确认**：如果团队里确实还有一份 `PM_GPIO_CTRL-new.bat`（未在本工作区），那这份 `-mimo` 可能是"分叉副本"，存在两套并行维护的风险。需要原作者确认是否存在 `-new`。

#### Q-07 `auto_shot.bat` 的 `TAP_X=243 / TAP_Y=512` 对应哪台设备

- **相关**：M-13
- **待确认**：这个坐标是 1080×2340 还是别的分辨率下的快门位置？换设备时是否有换算规则？若该脚本只服务于一台固定样机，那它属于"一次性工具"，可以不改，但应在文件头注明"仅适用于 <机型>"。

#### Q-08 上层是否有人用 `call` 方式调用这些脚本

- **相关**：M-01（裸 `exit`）、M-16（变量污染）
- **为何重要**：这两条的严重度完全取决于"有没有人 `call` 它们"。
  - 如果只双击运行 → 裸 `exit` 反而是**优点**（自动关窗），变量泄漏也无害；
  - 如果被包装脚本 `call` → 裸 `exit` 会杀掉调用者，`date`/`time`/`OUT` 会污染外层，两者都必须修。
- **需要**：确认 CI / 测试流水线里是否有 `.bat` 包装层。

#### Q-09 现场 `LOGS_20261103_1015\` 里 `logcat.txt` 的 75 MB 中，历史缓冲与复现期各占多少

- **相关**：H-03 的"影响 2"
- **为何无法定论**：我没有读全文（只做了大小/尾部抽样），因此**不能**断言"其中大部分是历史日志"。这个比例需要按时戳切分统计才能给出。
- **说明**：H-03 的结论（"没有轮转、没有上限、3 个脚本不清缓冲"）由**代码直接证明**，不依赖这个比例；比例只影响"影响有多大"的量化描述。

---

## 附录 A 审计方法与被否决的初判

本报告在定稿前否决了几条**乍看成立、复核后不成立**的初判，记录在此以免下游误用：

| 初判 | 复核结果 | 处置 |
|---|---|---|
| `dec2hex` 会把 `240` 算成 `0x0`，读改写路径必错 | 子程序对 0–16777215 **全部正确**；只有输入为负（32 位最高位为 1）时才产脏值，且脏值是**一个错误的 1 位十六进制数**（如 `-1 → 0xF`、`-16 → 0x0`），不是空串也不是报错 | 降为 L-04，正文明确写"正常范围无 bug"，并补上本轮实测的负输入输出表 |
| `%OUT: =0%` 只是"补零死代码"，无害 | **成立但远不止**：它会改坏路径 | 升级为 H-01 |
| `cd /d` 失败一定返回非 0 | **成立**（本轮复核重测：不存在盘符 rc=1、不存在目录 rc=1、路径是文件 rc=1，均 cwd 未变）。上一版"返回 0"的结论是探针写错导致（`mkdir` 先成功，`cd /d` 自然 rc=0），**已撤销** | M-03 保留"脚本压根不检查返回值"这一条，并明确写"检查 `cd /d` 返回码是可行的" |
| UNC 的双反斜杠是转义错误 | **不成立**，磁盘上就是两个反斜杠，写法正确 | 写入 N-01（"不需要整改"） |
| GBK 中文注释会破坏解析 | **不成立**，两种代码页下都能正常跳过，且无"尾字节为元字符"的危险行 | 写入 N-04 |
| 现场仍有残留的 logcat/dmesg 进程 | **当前没有**（两个文件 mtime 已停止推进；且 `tasklist` 里只剩 adb server，无 logcat/dmesg 客户端）。但本轮复核用父子进程探针确认了**机制**：父脚本裸 `exit` 之后，`start` 出来的子进程会继续写文件直到自己结束 | BLK-01 保持"依赖人工、忘关就残留"，并用父子进程探针支撑"会脱离父脚本存活"这一点 |

**本轮复核（reviewer）追加的探针**位于 `analysis/probes_review/`，与上表互补，可重跑：

| 脚本 | 验证内容 |
|---|---|
| `r_cd.bat` | `cd /d` 四种失败的返回码（撤销"返回 0"的旧结论） |
| `r_out.bat` | `%OUT: =0%` 把 `D:\p dir with space\LOGS_x` → `D:\p0dir0with0space\LOGS_x` |
| `r_fs.bat` / `t1..t8.bat` | `findstr /i "No such file"` 三子串 OR vs `/c:` 字面量；`2>nul` 在管道左侧对 stdout/stderr 的差别 |
| `r_oct.bat` | `set /a` 八进制：`8→8 / 08→0 / 010→8 / 016→14 / 018→0 / 18→18` |
| `r_date.bat` / `d65001.bat` / `d936.bat` | 两代码页下 `date /t` 的 token 位置（cp936 丢年份、cp65001 正确） |
| `r_ts.bat` | `auto_shot.bat` 的时间戳在 cp65001 下变成 `周二 226111…` |
| `r_drv_exit.bat` / `r_drv_exitb.bat` | 裸 `exit` 杀掉调用者；`exit /b` 正常返回 |
| `r_parent6.bat` / `r_writer6.bat` | `start` 出的子进程在父脚本 `exit` 后继续写文件 |
| `r_dec2hex.bat` / `r_d2h.bat` | `:dec2hex` 正数全对 + 负输入的实际脏值 |
| `r_parse.bat` | `set /a` 单 token 漏检（`Permission → 0` DEFINED） |
| `r_errlvl2.bat` | `if errorlevel 1` 漏掉负码、`neq 0` 抓住负码 |
| `r_docfix2.bat` / `r_pad3.bat` | 上一版 `:parse_gpio` 修复片段是错的；补零到 3 位后正确 |
| `r_u8_crlf.bat` | `power-key.bat:30` 原始字节在 cp936 下 `e3 80 82` → `3f` |
| `r_mk.bat` | `mkdir` 会自动创建中间目录，所以 H-01 的"影子目录"确实会被建出来 |
| `cite_report.txt` | 全文 302 处行号引用逐条回查（0 处越界 / 0 处文件解析失败） |

**所有"实测"的复核脚本**位于 `analysis/probes_doc/`，可重跑：

| 脚本 | 验证内容 |
|---|---|
| `p_date.bat` | cp936 / cp65001 下 `date /t` 的 token 位置变化 |
| `p_key.bat` | `%OUT: =0%` 改坏路径、`findstr` 多子串 OR、`set /a` 八进制、`set /a` 单 token 漏检 |
| `p_pipe.bat` | 管道吞退出码（root 三分支）、`2>nul` 在管道左侧 vs `2>&1` |
| `drv_exit.bat` / `p_child_exit.bat` | 裸 `exit` 杀掉调用者 |
| `drv_cp.bat` / `p_u8_crlf.bat` | UTF-8 无 `chcp` 在 cp936 下的乱码（末字节 `。`→`?`） |
| `chk_artifacts.py` | 9 个 `.bat` 的 CRLF / BOM / 末尾换行；`logcat.txt` / `dmesg.log` 的大小与末字节 |
| `chk_backslash.py` | UNC 路径逐字节 hex |
| `chk_stats.py` / `chk_adbcount.py` | 每个脚本的 adb 调用数、校验数、`setlocal`/`chcp` 有无 |
| `chk_cp2.py` | 用 `power-key.bat:30` 的**原始字节**构造探针，验证乱码 |

> 所有探针只 `echo` 文本或做字符串处理，**不包含任何 `adb` 命令**，也**没有执行**被审计的 9 个 `.bat`。

---

## 附录 B 术语与判定口径

| 术语 | 含义 |
|---|---|
| **静默失败** | 命令失败但脚本不报错、继续执行，最终输出"成功" |
| **假校验** | 写了看起来像判定的代码（如 `\| findstr`），但实际判的不是命令的退出码 |
| **吞码** | 管道把左侧命令的退出码丢弃，`&&`/`\|\|`/`errorlevel` 拿到的是右侧命令的码 |
| **影子目录** | 因路径被字符串替换改坏而创建出来的、名字与预期不同的目录 |
| `errorlevel` 语义 | `if errorlevel 1` 是"**≥ 1**"，会**漏掉负数**（如 `0xC0000006` 崩溃码）；`if !errorlevel! neq 0` 是"**≠ 0**"，两者不等价 |

---

**报告结束。**
本报告为纯静态分析产物：**未连接任何设备、未执行任何 adb 命令、未修改任何 .bat 文件**。
所有结论均标注 `文件:行号`，可直接回到源文件核对。


