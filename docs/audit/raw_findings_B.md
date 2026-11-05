# B 组静态审计：编码 / 换行 / 参数解析 / 时间戳 / UNC 路径 / 跨脚本一致性

审计范围：工作区 `D:\Desktop\debug_temp\bat脚本` 下 9 个 `.bat`，纯静态读取。
约束遵守：**未执行任何 `.bat`、未调用 `adb`、未连接设备、未修改任何 `.bat`**。所有 `.bat` 的 mtime 均保持原样（2026-09/10 月批次）。
（复现实验均在 `%TEMP%\batprobe\*` 下的自建探针脚本与 stub 文本上完成，与工作区文件无关；未读取 `LOGS_20261103_1015/logcat.txt`。）

条目格式：`[严重度] 文件:行号 — 现象 / 根因 / 影响 / 修复建议`

严重度定义：**阻断**＝会直接导致脚本行为错误或数据损坏；**高**＝在常见环境下会静默产出错误结果；**中**＝可移植性/健壮性缺陷；**低**＝可读性/维护性问题。

---

## A. 编码混杂（B 组核心）

### 编码事实基线（实测，逐文件）

| 文件 | 编码判定 | 非 ASCII 行数 | BOM | CRLF | 文件末换行 | `chcp` |
|---|---|---|---|---|---|---|
| `PM_GPIO_CTRL-mimo.bat` | **GBK(936)**，1170 个非 ASCII 字节，`decode('utf-8')` 在 77 行失败 | 77（**全部是 `::` 注释行**） | 无 | 766/766 全 CRLF | 有 | **无** |
| `auto_shot.bat` | pure ASCII | 0 | 无 | 47/47 | **无** | L2 `65001` |
| `current_display.bat` | UTF-8 | 4（全注释） | 无 | 39/39 | **无** | L2 `65001` |
| `disp_continuous_monitor.bat` | UTF-8 | 12（**2 行是 `echo` 正文**） | 无 | 89/89 | **无** | L2 `65001` |
| `power-key.bat` | UTF-8 | 7（**1 行是 `echo` 正文**） | 无 | 30/30 | **无** | **无** |
| `push_apk.bat` | pure ASCII | 0 | 无 | 29/29 | **无** | L2 `65001` |
| `push_msm_drm_ko.bat` | pure ASCII | 0 | 无 | 28/28 | **无** | L2 `65001` |
| `备用脚本\capture_disp_log.bat` | pure ASCII | 0 | 无 | 44/44 | **无** | L2 `65001` |
| `备用脚本\monitor.bat` | UTF-8 | 10（全注释） | 无 | 39/39 | **无** | L2 `65001` |

结论：9 个文件中 **7 个声明了 `chcp 65001`，2 个没有**（`PM_GPIO_CTRL-mimo.bat`、`power-key.bat`）。这 2 个恰好也是"文件编码与控制台代码页不匹配"的文件——一个 GBK 无 chcp（反而是自洽的），一个 UTF-8 无 chcp（不自洽，见 B-01）。

---

### [高] power-key.bat:1,30 — UTF-8 中文 `echo` 但全脚本无 `chcp`，默认 936 控制台下输出乱码
- **现象**：`power-key.bat` 第 30 行 `echo 脚本执行完毕，共运行 %max% 次。` 是 UTF-8 字节（`e8 84 9a e6 9c ac …`），而脚本没有任何 `chcp` 调用，进程沿用父控制台的 936 代码页。
- **根因**：`cmd.exe` 按当前代码页解释批处理字节流里的 `echo` 参数并转成控制台输出。UTF-8 双/三字节序列在 936 下被按字节拆开映射，产生"鑴氭湰鎵ц…"式乱码；末尾 `。`(U+3002 的 UTF-8 为 `e3 80 82`) 只剩 `?`。
- **实测**（探针 `%TEMP%\batprobe\p8\u8_nochcp.bat`，与 L30 同字节）：
  - cp936 下输出十六进制 `e8849ae69ca…e3803f` → 末字节变 `3f`(`?`)，且终端呈乱码；
  - 同文件加 `chcp 65001` 后输出 `e38082` 正常。
- **影响**：用户完全看不到这行完成提示（它恰恰是脚本唯一的收尾反馈）；乱码不影响 `adb` 调用本身，故属"看起来能跑但反馈失效"。同一文件第 4/11/13/18/20/23 行是中文 `::` 注释，乱码只影响阅读，不影响执行。
- **修复建议**：在 `@echo off` 之后加 `chcp 65001 >nul`；或把第 30 行改成 ASCII 英文（与同目录 `auto_shot.bat`/`push_*.bat` 的纯英文风格一致）；或用等价的 Unicode 写法 `chcp 936` + 将文件另存为 GBK。

### [中] PM_GPIO_CTRL-mimo.bat:1 — 全仓唯一 GBK 文件且不声明代码页，与同目录 UTF-8 脚本形成"编码双轨"
- **现象**：该文件 1170 个非 ASCII 字节、77 行中文注释，`utf-8` 解码在 77 行失败、`gbk` 解码 0 失败 → 确为 GBK。而 `current_display.bat` / `disp_continuous_monitor.bat` / `power-key.bat` / `备用脚本\monitor.bat` 是 UTF-8（这 4 个在 GBK 下解码分别有 4/11/7/10 行失败）。
- **根因**：历史上不同作者/不同编辑器保存，仓库没有统一的 `.editorconfig` 或保存约定。
- **实测结论（重要，用于纠偏）**：GBK 注释行在 cp936 与 cp65001 两种代码页下**都能被 `cmd.exe` 正常跳过，不会报语法错**（探针 `%TEMP%\batprobe\p16\gbk_comments.bat`，逐字节复制该文件 L4–L46，两种代码页均输出 `REACHED-END-GBK`）。另有专项扫描确认该文件 **不存在"GBK 尾字节恰好是 `\ | & > < % ^ ( ) " !` 等元字符"的行**（`gbk_risky_trail_pairs=NONE`），所以不存在"CJK 尾字节吞掉引号/管道"的隐患。
- **影响**：不影响运行，但**只要有人用 VS Code / Notepad++ 默认 UTF-8 打开并保存一次，77 行注释即全部损坏**（这是该文件真正的风险点，不是运行期）；同时 GBK 文件在 Git 里 diff 不可读、code review 困难。
- **修复建议**：统一转 UTF-8（保留一份 GBK 备份到归档目录）；在仓库根加 `.gitattributes`（`*.bat text eol=crlf working-tree-encoding=UTF-8`）与 `.editorconfig`(`charset=utf-8`)。注意该文件**不要**加 `chcp 65001`——它是纯 ASCII 输出 + GBK 注释，加 65001 反而让注释在编辑器外错乱，正确的是转码。

### [低] 备用脚本\monitor.bat:3 — `title` 与 disp_continuous_monitor.bat:3 完全相同，两个窗口无法区分
- **现象**：两者 `title` 均为 `Continuous Log Monitor`；`current_display.bat:3` 为 `Current Log Monitor`，`备用脚本\capture_disp_log.bat:3` 为 `Quick Log Capture`。
- **根因**：从 `disp_continuous_monitor.bat` 复制派生时未改 title。
- **影响**：同时开两个窗口时无法凭标题栏判断哪个在跑，容易关错窗口丢掉 `dmesg -w` 采集（`disp_continuous_monitor.bat:51`）。
- **修复建议**：`备用脚本\monitor.bat:3` 改为 `title Legacy Continuous Monitor (getevent+logcat+dmesg)`。

---

## B. 本机化日期/时间解析 与 覆盖内建变量（B 组核心）

### [阻断] current_display.bat:6-9 — 覆盖 `date`/`time` 内建伪变量，且输出目录名依赖代码页，路径含中文/空格时被 `%OUT: =0%` 改坏
这是 4 个抓取脚本（`current_display.bat:6-9`、`disp_continuous_monitor.bat:6-9`、`备用脚本\capture_disp_log.bat:5-8`、`备用脚本\monitor.bat:6-9`）共有的同一段代码，下列三个缺陷叠加：

**B-01 覆盖内建变量 `date` / `time`**
- 现象：`current_display.bat:6` `for /f "tokens=2-4 delims=/ " %%a in ('date /t') do set "date=%%a%%b%%c"`；`L7` 同法 `set "time=..."`。`date`/`time` 是 `cmd.exe` 的动态伪变量，一旦 `set` 就变成普通环境变量。
- 根因：直接复用变量名，未加前缀。
- **实测**（探针 `%TEMP%\batprobe\p7`）：父脚本从 `date=2026/11/03 周二` 变为 `date=1103周二`；**且因为 `current_display.bat` 没有 `setlocal`（实测确认 4 个抓取脚本全都没有 `setlocal`），这个污染会向上泄漏回调用者**：
  ```
  [parent before] date=2026/11/03 周二
    [child] date=1103周二 time=1114
  [parent after ] date=1103周二 time=1114     ← 父进程也被改
  [parent check] dynamic date still live? 1103周二   ← %date% 已不是日期
  ```
- 影响：(a) 同脚本后续任何 `%date%`/`%time%` 都拿到无分隔符残值（本例 L38 `echo Done! Logs saved to: %OUT%` 无碍，但任何后来插入的日期逻辑会静默错）；(b) **如果用户把脚本 `call` 进自己的批处理/CI 包装脚本，对方的 `%date%`/`%time%` 会被污染**；(c) `time` 被覆盖后，`disp_continuous_monitor.bat` 之后若再 `time /t` 也拿不到真值。
- 修复建议：改名 `set "TS_DATE=%%a%%b%%c"` / `set "TS_TIME=%%a%%b%%c"`；并给 4 个脚本都补 `setlocal EnableDelayedExpansion`（同时解决泄漏）。

**B-02 解析结果依赖当前代码页——同一段代码在 936 / 65001 下产出完全不同的目录名**
- 现象：这 4 个脚本 `chcp 65001` 在 `L2/L2/L2/L2`，**先切码页再解析**，于是 `date /t` 的输出变了，`tokens=2-4 delims="/ "` 的切分结果也随之改变。
- **实测**（探针 `%TEMP%\batprobe\p14`，同一脚本内先后两次解析）：
  ```
  cp936   : date /t = "2026/11/03 <D6DC><B6FE>"   →  d936  =[1103周二]     ← token2/3/4 = 11,03,周二
  cp65001 : date /t = "<E591A8><E4BABA> 2026/11/03" → d65001=[20261103]   ← token2/3/4 = 2026,11,03
  ```
  即：**同样 `tokens=2-4`，936 下丢掉年份、65001 下正确**。`chcp 65001` 把周几从"尾部"搬到了"头部"，token 位置整体平移。
- 影响：目录名 `LOGS_1103周二_1121` vs `LOGS_20261103_1121` 二义；跨机器（不同 Windows 语言版本）目录名不可预期，后续任何按名字排序/解析的脚本都会错。
- 修复建议：不要解析 `date /t`。用与语言无关的来源：
  ```bat
  for /f "tokens=2 delims==" %%i in ('wmic os get localdatetime /value ^| findstr "="') do set "DT=%%i"
  set "STAMP=%DT:~0,8%_%DT:~8,6%"
  ```
  （实测 `wmic os get localdatetime` 输出 `20261103112936.943000+480`，与代码页/区域无关；`powershell -NoProfile -Command "Get-Date -Format yyyyMMdd_HHmmss"` 亦可，实测得到 `20261103_112937`。）

**B-03 `set "OUT=%OUT: =0%"` 会把"路径中的空格"也替换成 `0`——只要脚本目录含空格就写错地方**
- 现象：`current_display.bat:9`、`disp_continuous_monitor.bat:9`、`备用脚本\capture_disp_log.bat:8`、`备用脚本\monitor.bat:9` 的 `set "OUT=%OUT: =0%"`。作者本意是给"个位数小时"补 0（如 `9:05` → `0905`），但 `%OUT%` 里已经含 `%~dp0` 的**完整绝对路径**。
- **实测**（探针 `%TEMP%\batprobe\p13\dir with space\sp.bat`，逻辑与 L6–L9 一致且带 `chcp 65001`）：
  ```
  SCRIPT_DIR=[C:\...\p13\dir with space\]
  OUT_RAW   =[C:\...\p13\dir with space\LOGS_20261103_1123]
  OUT_SUB   =[C:\...\p13\dir0with0space\LOGS_20261103_1123]   ← 目录名被改
  CWD_NOW   =[C:\...\p13\dir0with0space\LOGS_20261103_1123]
  ```
  最终在 `dir0with0space\` 下建了目录、`cd` 过去、日志写在那里。
- **对照实验（证明问题只出在这行替换，不涉及中文/65001）**：同一目录 `%TEMP%\batprobe\中文 目录\`（含中文 **且** 含空格），脚本带 `chcp 65001`：
  - **去掉** `set "OUT=%OUT: =0%"` 的版本 → `mkdir_err=0`、`EXIST_YES`，目录建在 `中文 目录\LOGS_test`（正确）；
  - **保留**该替换的版本 → 目录被建到 `中文目录0空格\LOGS_test`（错位）。
  两者唯一差异就是那一行替换，因此中文与 65001 本身不是元凶，空格替换才是。
- 影响：**阻断级数据错位**——日志不会出现在你以为的目录旁，而会静默落到一个同级的、名字被改过的"影子目录"；`mkdir "%OUT%" 2>nul`（`current_display.bat:19` / `disp_continuous_monitor.bat:19` / `capture_disp_log.bat:17` / `monitor.bat:18`）会**顺手创建这个错名字的目录**，`cd /d "%OUT%"`（`current_display.bat:20` / `disp_continuous_monitor.bat:20` / `monitor.bat:19`）随后切进去，于是整轮日志都写错地方却"看起来一切正常"。
- 修复建议：先算时间戳、再拼路径：
  ```bat
  for /f "tokens=1-2 delims=: " %%a in ('time /t') do set "TS=%%a%%b"
  set "TS=%TS: =0%"
  set "OUT=%~dp0LOGS_%STAMP%_%TS%"
  ```
  即**只对纯时间戳做空格替换**，绝不把 `%~dp0` 一起卷进去。

### [中] current_display.bat:7 / disp_continuous_monitor.bat:7 / capture_disp_log.bat:6 / monitor.bat:7 — `time /t` 只有 HH:MM，个位数小时补零逻辑基本是死代码，且目录名有"同分钟覆盖"风险
- 现象：`for /f "tokens=1-2 delims=: " %%a in ('time /t') do set "time=%%a%%b"`。`time /t` 实测输出 `11:11`（只有时:分，无秒）。
- **实测**（探针 `%TEMP%\batprobe\p10\loc.bat` 与 `%TEMP%\batprobe\p8\p9`）：
  - `"11:11"` → `t=[1111]`；`" 9:05"`（单数字小时，前导空格）→ `t=[905]`，因 `delims` 含空格，前导空格被吃掉，`%t: =0%` 无事可做；
  - 所以 `set "OUT=%OUT: =0%"` 里"补零"的分支**只在 `time /t` 输出带前导空格且 `delims` 不含空格时才有意义**——这里 `delims` 已含空格，逻辑上永远是死代码（副作用只剩 B-03 的路径破坏）。
- 影响：目录名精度只到分钟 → **同一分钟内连跑两次会写进同一个目录、互相覆盖**（`adb logcat -d … > logcat_all_current.txt` 直接截断）。
- 修复建议：时间戳加秒（见 B-02 的 `wmic` 方案，天然含秒）；或在 `%OUT%` 已存在时追加 `_%RANDOM%`。

### [中] power-key.bat:12,14,16 — `%time%` 含毫秒与尾随空格，`tokens=1,2 delims= ` 只对"个位数小时"补零，输出时间戳格式不稳定
- 现象：`L12` `for /f "tokens=1,2 delims= " %%a in ("%time%") do set "cur_time=%%a %%b"`；`L14` `if "%cur_time:~1,1%"==":" set "cur_time=0%cur_time%"`；`L16` `echo [%date% %cur_time%] Iteration: %i%`。
- **实测**（探针 `p12\pk.bat`，用与 `%time%` 等价的字符串）：
  - 两小时制：`%time% = 11:22:34.36` → `cur_time=[11:11:06.05 ]`（token2 是 `11:06.05`，**带毫秒**，且末尾多一个空格）
  - 单数字小时：`" 9:05:03.12"` → `cur_time=[9:05:03.12 ]`，`L14` 判 `cur_time:~1,1==":"` 成立 → `[09:05:03.12 ]`
  - 但若 `%time%` 形如 `9:05:03.12`（无前导空格，某些区域/某些 `cmd` 启动方式）→ `cur_time=[9:05:03.12]`，`L14` 同样生效。
- 影响：日志行形如 `[2026/11/03 周二 11:22:34.36 ] Iteration: 1`，**中英混排 + 毫秒 + 多余空格**，人读不整齐，机器解析（`findstr`/正则）易踩坑；`%cur_time%` 在 `setlocal` 之外但本脚本有 `setlocal`(L2)，不外泄。
- 修复建议：`set "cur_time=!cur_time: =0!"` 之外，改用 `for /f "tokens=1-3 delims=:.," %%a in ("%time%")` 显式取时:分:秒，再 `if "%%a" lss "10" set "h=0%%a"`。

### [中] power-key.bat:12 — 与 4 个抓取脚本的做法不一致：这里没覆盖 `time`，抓取脚本覆盖了
- 现象：`power-key.bat:12` 用 `set "cur_time=..."`（正确做法）；`current_display.bat:7` 等用 `set "time=..."`（覆盖内建）。
- 根因：同一个人/同一批脚本里两套写法，说明覆盖内建是随手写的，不是有意为之。
- 影响：跨脚本一致性差，后续维护者容易照抄错误的那一套。
- 修复建议：统一为 `TS_` 前缀（见 B-01）。

---

## C. 换行 / 文件末尾 / BOM

### [低] 9/9 文件 CRLF 完全一致、均无 BOM；但 8/9 文件末尾缺换行
- 实测（逐字节）：全部 9 个文件 `loneLF=0`、`loneCR=0`、`BOM=no` —— **CRLF 一致性没有问题，BOM 没有混入**（这是本项最好的结论，可直接写进结论章"不需整改"）。
- **这个一致性很重要，不要"顺手转成 LF"**：`.bat` 对换行极敏感。实测对照（探针 `%TEMP%\batprobe\p19\`，内容完全相同、仅换行不同）：
  ```
  LF-only 版 → '5001' is not recognized… / 'UT' is not recognized… / 'A]' is not recognized…
               （chcp 行被拆成 "chcp"+"65001"、set 行被拆、if 行被拆）exit=1
  CRLF  版 → 全部正常：mkdir_err=0 / EXISTS / 测试中文 echo          exit=1→0
  ```
  即**只要有人把某个 `.bat` 按 LF 保存，整个脚本立刻碎掉**。这也是为什么本轮把"CRLF 一致"列为已验证的好结论。
- 末尾换行：仅 `PM_GPIO_CTRL-mimo.bat`（L766 `exit /b 0` + CRLF）以换行结尾；其余 8 个（`auto_shot.bat` 末 `goto LOOP`、`power-key.bat` 末 `pause`、`current_display.bat`、`disp_continuous_monitor.bat`、`push_apk.bat`、`push_msm_drm_ko.bat`、`capture_disp_log.bat`、`monitor.bat`）**末行无行尾**。
- **实测影响 = 无**（探针 `%TEMP%\batprobe\p15`）：`cmd.exe` 会把最后一行的 EOF 当作行结束；无换行时 `echo` 正常、`goto` 正常、`exit /b 3` 仍返回 3。
  ```
  nonl.bat        → FIRST / LAST-LINE-NO-TRAILING-NEWLINE   exit=0
  nonl_label.bat  → END-REACHED-NO-NL                        exit=0
  nonl_exitb.bat  → BEFORE                                   exit=3
  ```
- **影响**：仅 diff/代码评审噪音（显示 `\ No newline at end of file`），以及某些老式构建/打包工具对末行做拼接时会粘连。
- **修复建议**：加 `.gitattributes` 的 `*.bat text eol=crlf`（**务必保留 `eol=crlf`**，不要写成 `eol=lf`）；编辑器开启"保存时确保末尾换行"。**不必逐文件手改**。

### [低] 工作区存在 `nul` 文件（67 字节，内容为一条 adb 报错文本）——非 `.bat`，但是 A/B 两组管道问题的直接物证
- 现象：工作区根有 `nul` 文件，`xxd` 显示内容为 `ls: /vendor/overlay/does_not_exist.apk: No such file or directory\r\n`。这是**重定向写错位置**留下的产物（把本该丢弃的输出写成了名为 `nul` 的真实文件）。
- **实测**（探针 `%TEMP%\batprobe\p18`）：一旦工作目录里存在名为 `nul` 的**普通文件**，`2>nul` 仍然丢弃到 NUL 设备、**不会**写入该文件（`dir /b` 只显示 `t.cmd`，文件内容不变）。所以此 artifact 说明当时是**显式**写文件（如 `> nul` 之外的拼写、或从别处复制），不是 `2>nul` 的常规副作用。
- **影响**：`nul` 是 Windows 保留设备名，普通工具很难删除（`del nul` 会静默无效），会长期污染目录、干扰 `dir` 与打包；且它是"误把错误输出当归档"的直接证据。
- **修复建议**：不要删除（本轮禁改工作区非分析产物），在正式报告中作为证据列出；清理时用 `del \\.\D:\Desktop\debug_temp\bat脚本\nul`。

---

## D. UNC 路径写法（B 组核心）

### [严重度：无问题（已复核澄清）] push_apk.bat:19 / push_msm_drm_ko.bat:19 — 双反斜杠是**正确的**，不是多转义
- 现象（`grep` 显示为 `\\\\` 是 grep 转义假象）：**逐字节 `xxd` 与 `cat -A` 确认磁盘上就是两个反斜杠**：
  ```
  push_apk.bat:19       "\\10.71.255.189\yxb_sdc1\kdo_nj\LINUX\android\out\target\product\neo\vendor\overlay\FrameworksResOverlay_Wear.apk"
  push_msm_drm_ko.bat:19 "\\10.71.255.189\yxb_sdc1\kc3\VENDOR\out\target\product\vienna\dlkm\lib\modules\msm_drm.ko"
  ```
- 结论：`.bat` 里**不做反斜杠转义**，UNC 前缀恰好就是两个反斜杠 → 写法正确，路径合法，且已用双引号包裹。**这一条不需要改**（把"双反斜杠是 bug"写进报告会是误报，特此澄清）。

### [高] push_apk.bat:19 / push_msm_drm_ko.bat:19 — 但源路径是**内网私有构建机绝对路径 + 内网 IP**，硬编码且必然失效
- 现象：`\\10.71.255.189\yxb_sdc1\...`，含内网 IP、共享名 `yxb_sdc1`、个人目录 `kdo_nj`、私有构建树 `LINUX\android\out\target\product\neo\...` / `kc3\VENDOR\out\target\product\vienna\...`。
- 影响：(a) 离开该内网/该账号立刻失败；(b) 构建输出路径随产品分支变化（`neo` vs `vienna` 两套），脚本必然过期；(c) 凭据/拓扑信息外泄到脚本。
- 修复建议：改为脚本参数或环境变量：`adb push "%~1" /vendor/overlay/...`，并在 `if "%~1"=="" goto usage` 里提示；或 `set "SRC=%APK_SRC%"` 从外部传入。

### [中] auto_shot.bat:11 — `set SAVE_DIR=%cd%\Camera_Android` 未加引号，且依赖当前工作目录而非脚本目录
- 现象：L11 用 `%cd%`（**cwd**）而不是 `%~dp0`（脚本目录）；后续 L13 `if not exist "%SAVE_DIR%" mkdir "%SAVE_DIR%"` 与 L42 才加引号。
- 影响：双击运行时 cwd=脚本目录，尚可；但从"以管理员身份"/计划任务/IDE 调用时 cwd 可能是 `C:\Windows\System32`，截图会散落到系统目录；`set` 不加引号在路径含 `&`/`^` 时会截断（当前 Windows 路径很少含这些，属潜在）。
- 修复建议：`set "SAVE_DIR=%~dp0Camera_Android"`（**加引号 + 用脚本目录**）。

### [中] disp_continuous_monitor.bat:84 / 备用脚本\capture_disp_log.bat:36 — `adb bugreport "<绝对路径>\bugreport.zip"` 跨 `cd` 的路径依赖
- 现象：`disp_continuous_monitor.bat:84` `adb bugreport "%OUT%\bugreport.zip"`；该脚本 L20 已 `cd /d "%OUT%"`，于是 `%OUT%` 是**绝对路径**（`%~dp0` 派生）→ 实际调用变成 `adb bugreport "D:\...\LOGS_x\bugreport.zip"`。`capture_disp_log.bat` 则**从不 `cd`**（L17 后无 `cd`），却同样写 `"%OUT%\bugreport.zip"`。
- 影响：两脚本行为不一致（一个在 `%OUT%` 里跑、一个在原 cwd 里跑）；`adb bugreport` 的本地目标参数在部分 adb 版本上对含空格/中文的绝对路径敏感，而 `%OUT%` 恰好可能含中文（见 B-02/B-03）。
- 修复建议：统一 `cd /d "%OUT%"` 后写 `adb bugreport bugreport.zip`（相对名，最短路径），或统一用绝对路径，二选一。

---

## E. 管道与重定向顺序（B 组核心）

### [高] push_apk.bat:16 / push_msm_drm_ko.bat:16 — `2>nul` 放在管道左侧只丢弃**本机** stderr；远端 `ls` 的错误若走 stderr 就进不了 `findstr`，判定永远落到 WARN
- 现象（原文，`push_apk.bat:16`；`push_msm_drm_ko.bat:16` 同）：
  ```bat
  adb shell ls /vendor/overlay/FrameworksResOverlay_Wear.apk 2>nul | findstr /i "No such file" >nul && echo OK: Old file removed || echo WARN: File still exists or path invalid
  ```
- 根因：`2>nul` 只重定向 **`adb.exe` 进程自身的 stderr**。远端 `ls` 的报错由 `adbd` 通过 adb 协议回传，通常被 `adb` 打到 **stdout**（`adb shell` 默认合并远端 stdout+stderr 到本机 stdout，本机 stderr 只装 adb 客户端自身错误）。**顺序很关键**：`2>nul` 写在 `|` 左边、且没有 `2>&1`，因此"远端错误走 stderr"的那条路径被彻底吞掉。
- **实测**（探针 `%TEMP%\batprobe\redir2.cmd`）：
  ```
  A. 错误文本在 STDOUT, 2>nul 在管道左侧  → RESULT=removed        （能匹配）
  B. 错误文本在 STDERR, 2>nul 在管道左侧  → RESULT=still-exists   （匹配不到，误报）
  C. 错误文本在 STDERR, 2>&1 在管道左侧   → RESULT=removed        （修好后能匹配）
  ```
- 影响：**`OK: Old file removed` 这条成功判定不可靠**——在 `adb` 自身报错（`error: no devices/emulators found`、`adb server didn't ACK`、`more than one device`）时会走进 `|| WARN` 分支（尚算安全）；而在"远端错误走 stderr"的实现/版本上，**即使文件已经删掉也会误报 WARN**，让人以为 `rm` 没生效。真实采集环境里该分支的语义已经不可信。
- 修复建议（三选一，按推荐序）：
  1. 别用文本匹配，用退出码：`adb shell "test -e /path"` + `if !errorlevel! neq 0`（远端 `test` 的退出码会经 adb 传回）。**这是唯一稳的做法**。
  2. 若要保留文本匹配：`adb shell ls /path 2>&1 | findstr /i /c:"No such file" >nul`（`2>&1` 必须在 `|` **左边**、且用 `/c:` 字面量）。
  3. 至少改成 `adb shell ls /path 2>&1 | findstr /c:"No such file" >nul`，并补 `/c:`。

### [高] push_apk.bat:16 / push_msm_drm_ko.bat:16 — `findstr /i "No such file"` 是**三个独立子串**（OR 关系），不是整句，误判概率很高
- 现象：引号内的空格是**分隔符**，`findstr` 把它当作 `"No"` 或 `"such"` 或 `"file"` 三个 pattern 的 OR。
- **实测**（探针 `%TEMP%\batprobe\fp2.cmd`、`fp.cmd`）：
  ```
  'no'   MATCHES      （"No worries" 命中！）
  'such' MATCHES      （"contains the word such here" 命中）
  'file' MATCHES      （"the word File appears" 命中）
  rm: /vendor/overlay/X.apk: Read-only file system  → RESULT=OK_Old_file_removed  ← 假阳性
  failed to copy 'x.apk' to '/vendor/overlay/x.apk': remote No space left → RESULT=OK_removed  ← 假阳性
  改用 /c:"No such file" 后 → RESULT=still-exists（正确）
  ```
- 影响：**只要远端输出里出现 `no`/`such`/`file` 任意一个词（大小写不敏感），就打印"Old file removed"**。`rm -rf` 因"Read-only file system"失败时照样报 OK，用户被引导去 `reboot`（L28/L27）期待生效，实际 `FrameworksResOverlay_Wear.apk` 仍是旧的 —— **最坏情况：刷了旧 overlay 还以为成功了**。
- 修复建议：`findstr /i /c:"No such file"`（字面量整句）；更好的是按上一条改用 `test -e` + `errorlevel`。

### [低] push_apk.bat:6,9 / push_msm_drm_ko.bat:6,9 — 用 `findstr` 匹配 adb 成功关键字，同样受本地化/版本影响
- 现象：`adb root | findstr /i "restarting"`、`adb remount | findstr /i "succeeded"`。
- 影响：`adb root` 在"已经是 root"时输出 `adbd is already running as root`（不含 `restarting`）→ 走 WARN 分支（文案已承认）；`adb remount` 在 newer adb 上是 `remount succeeded`，老版本可能是 `remount succeeded` / `No such file or directory`，失败时若输出里恰好含 `succeeded` 也会误判。属中低风险，且这两条**已有兜底文案**，故列"低"。
- 修复建议：改判 `errorlevel`：`adb root >nul 2>&1 & if errorlevel 1 echo WARN...`；`adb remount` 同理。

### [低] PM_GPIO_CTRL-mimo.bat:757 — `findstr /l /c:"(18 lines)"` 在 `for /f '...'` 单引号里嵌套 `/c:` 是可疑组合（未复现，标注为待验证）
- 现象：L757 `for /f "tokens=1" %%c in ('call adb shell gpiodetect 2^>nul ^| findstr /l /c:"(18 lines)"') do if not defined chip set "chip=%%c"`。
- 说明：本机用 stub 文本复现 `for /f ... findstr /l /c:"(18 lines)"` 时**未产生输出**（`%TEMP%\batprobe\fin.cmd`），而同一探针里 `findstr /r /c:"line *3:"`（对应 L764）**正常匹配**。差异点在于 `/c:` 参数里含**空格与圆括号**，且处于 `for /f` 的单引号命令串中。因无法运行真实 `adb`，本轮**不下定论**，只标为"需真机验证"。
- 影响：若确实失效，`:find_chip`(L754-759) 永远 `exit /b 1` → `gpiod` 回退路径（L534/558/621 三处）全部无法工作，只剩 regmap 路径。
- 修复建议：改用不需要 `/c:` 的写法：`for /f "tokens=1" %%c in ('call adb shell gpiodetect 2^>nul ^| findstr "(18 lines)"')`，或用 `find "18 lines"`；并在真机上验证 `adb shell gpiodetect` 输出确实含字面 `(18 lines)`（不同 libgpiod 版本措辞不同）。

### [中] auto_shot.bat:36-42 — `for /f` 取 `ls -t` 结果后**无空值保护**，`file` 未定义时仍会执行 `adb pull ""`
- 现象：L36-39 `for /f "delims=" %%i in ('adb shell ls -t %PHONE_PATH%/*.jpg 2^>nul') do ( set file=%%i & goto PULL )`；`:PULL` 在 L40，**即使 for 一次都没进（循环体没执行）也会顺序落到 L40**，随后 L42 `adb pull "!file!" "%SAVE_DIR%\!ts!.jpg"`。
- **实测**（探针 `fin.cmd`）：`set "file="` 后无任何 `if defined` 检查，注释性验证输出 `file is EMPTY -> adb pull "" would run (no guard)`。
- 影响：设备上无 jpg / 相机没起来时，`adb pull ""` 报错被 `>nul 2>&1` 吞掉，L43 仍打印 `OK: !ts!.jpg`——**假成功**，`Camera_Android` 里积累一堆 0 字节/缺失文件而无人察觉。
- 修复建议：`if not defined file (echo [WARN] no jpg found, skip & goto LOOP)`；并把 L43 改成只在 pull 成功（`if !errorlevel! equ 0`）时打印。

### [中] auto_shot.bat:36 — `%PHONE_PATH%/*.jpg` 未加引号、通配符经本机→远端二次解释
- 现象：L10 `set PHONE_PATH=/sdcard/DCIM/Camera`，L36 `adb shell ls -t %PHONE_PATH%/*.jpg`。`*.jpg` 由**远端 shell** 展开（正确），但整串未加引号，若 `PHONE_PATH` 含空格（如 `/sdcard/My Pictures`）会拆成两个参数。
- 修复建议：`adb shell "ls -t '%PHONE_PATH%'/*.jpg"`。

---

## F. 参数解析（B 组核心）

### [高] PM_GPIO_CTRL-mimo.bat:102,138-141 — `set /a "n+=%~1"` 把命令行 GPIO 号当**八进制**解析：`08`/`09`/`010`/`016`/`018` 全部错
- 现象：L101-102
  ```bat
  set /a "n=0"
  set /a "n+=%~1" 2>nul
  ```
  `set /a` 的整数字面量规则：前导 `0` = **八进制**。
- **实测**（探针 `%TEMP%\batprobe\p9\oct2.bat`）：
  ```
  arg=8   -> n=8
  arg=08  -> 报 "Invalid number."，n=0   （被 2>nul 吞掉）
  arg=010 -> n=8                          ← 十进制 10 被当成八进制 010
  arg=016 -> n=14                         ← 十进制 16 被当成八进制 016
  arg=18  -> n=18
  ```
- 影响（关键，与 L103-104 的 `if !n! lss 1` / `if !n! gtr 18` 组合）：
  - `PM_GPIO_CTRL-mimo.bat 08 high` → `n=0` → 命中 `L103 if !n! lss 1` → 打印 usage、`exit /b 2`。**用户以为不支持 08，其实 08 是合法 GPIO**。
  - `... 010 read` → `n=8` → **静默操作 **PM_GPIO_08**！** 打印的还是 `PM_GPIO_08`（L177 `pad=0!n!`），用户可能不看名字就直接执行了。
  - `... 016 ...` → `n=14` → 静默操作 **PM_GPIO_14**。
  - `... 018 ...` → 八进制 018 非法 → `n=0` → usage。
  - 交互菜单路径（L84 `if "!choice:~0,1!"=="0" … set "choice=!choice:~1!"`）**已经处理了前导零**，所以只有**命令行**通道有这个 bug —— "同一个脚本两条入口行为不一致"。
- 修复建议：去掉前导零再算，或用十进制强制：
  ```bat
  set "arg=%~1"
  if "!arg:~0,1!"=="0" set "arg=!arg:~1!"
  set /a "n=1!arg!-1000"
  ```
  （`1!arg!-1000` 是十进制安全技巧：`1008-1000=8`、`1010-1000=10`。）

### [中] PM_GPIO_CTRL-mimo.bat:88 — 交互输入同样走 `set /a "n+=choice"`，但 L84 已剥前导零，故与命令行路径不一致
- 现象：L84 剥零、L88 `set /a "n+=choice" 2>nul`。
- 影响：`08` 在菜单里可用、在命令行里不可用 —— 用户会认为脚本"有时好用有时不好用"。
- 修复建议：两条路径抽成同一个 `:parse_gpio` 子程序。

### [中] PM_GPIO_CTRL-mimo.bat:60,102 — 无参数时 `%~1` 为空串，`set /a "n+=%~1"` 变成裸 `set /a "n+="` ；依赖 L60 先分流才没炸
- 现象：L60 `if not "%~1"=="" goto cli_args` 保证进 `:cli_args` 时 `%~1` 非空；但 `:cli_args`(L99) 作为子程序被别处 `call` 时无此保护。
- 影响：当前不会触发（L60 守着），属结构性隐患；`set /a "n+="` 会把错误信息打出去。
- 修复建议：`:cli_args` 开头加 `if "%~1"=="" goto cli_usage`，让子程序自我保护。

### [中] PM_GPIO_CTRL-mimo.bat:1-46 — 注释里的用法示例写的是 `PM_GPIO_CTRL-new.bat`，与实际文件名 `PM_GPIO_CTRL-mimo.bat` 不符
- 现象：L37-45 共 9 处 `PM_GPIO_CTRL-new.bat`，实际文件是 `PM_GPIO_CTRL-mimo.bat`。
- 影响：用户按注释敲命令会"文件名不存在"。（`L152-158` 的 usage 用的是 `%~nx0`，是对的 —— 说明注释是旧版本残留。）
- 修复建议：注释里改用 `%~nx0` 或直接写 `PM_GPIO_CTRL-mimo.bat`。

### [低] power-key.bat:5,9,27,30 — `max` 变量名过于通用；循环用 `%i%` + `goto`，无输入参数
- 现象：L5 `set max=100`、L9 `if %i% gtr %max% goto end`。`max`/`i` 在 `setlocal`(L2) 内不外泄，安全。
- 修复建议：改 `MAX_ITER`/`ITER`，与其它脚本的 `UPPER_SNAKE` 命名（`SAVE_DIR`/`PHONE_PATH`/`REGMAP`）统一。

---

## G. 跨脚本重复与不一致（4 个抓取脚本）

### [高] 4 个抓取脚本的"抓取项矩阵"互不一致，且都不清缓冲就抓，`logcat.txt` 会无限增长
| 抓取项 | current_display | disp_continuous_monitor | 备用脚本\capture_disp_log | 备用脚本\monitor |
|---|---|---|---|---|
| `logcat -d -b all` 快照 | ✅ L24 `logcat_all_current.txt` | ✅ L24(before) + L58(after) | ✅ L20 `logcat_all.txt` | ❌ |
| 实时 `logcat`（`start`） | ❌ | ✅ L49 | ❌ | ✅ L31 |
| `dmesg` 快照 | ✅ L25 | ✅ L25+59 | ✅ L23 | ❌ |
| 实时 `dmesg -w` | ❌ | ✅ L51 | ❌ | ✅ L34 |
| `getevent -tlr` | ❌（L45 被注释） | ❌（L45 被注释） | ❌ | ✅ L25 |
| **清缓冲 `logcat -c`** | ❌ | ❌（L47 被注释） | ❌ | ✅ L28 |
| `dumpsys display/sf/input/power/meminfo/window` | ✅ L26-32 | ✅ L26-32 + 60-66 | ✅ L26-29（**缺 meminfo/window**） | ❌ |
| `dumpsys gpu` | ✅ L30 | ✅ L30+64 | ❌ | ❌ |
| `getprop` | ✅ L33 | ✅ L33+67 | ✅ L32 | ❌ |
| `/proc/cmdline` | ✅ L34 | ✅ L34 | ✅ L33 | ❌ |
| 截图 | ❌ | ✅ L71-74 | ❌ | ❌ |
| `bugreport` | ❌ | ✅ L84 | ✅ L36 | ❌ |
| 复现前后对比 | ❌（只有 after） | ✅（before+after） | ❌ | ❌ |
- **影响**：
  1. **只有 `备用脚本\monitor.bat:28` 清缓冲**，其余 3 个不清。不清缓冲时 `adb shell logcat` 会先吐出**历史缓冲区**（可能几十 MB），`disp_continuous_monitor.bat` 的 `before` 快照与 `monitor.bat` 的 `logcat.txt` 里混着大量与本次复现无关的旧日志，**"复现前/后对比"失去意义**。
  2. 现场证据显示 `logcat.txt` 已膨胀到 **77 MB**（`LOGS_20261103_1015/logcat.txt`，仅 `ls` 看到大小，未读内容），而 `dmesg.log` 1.7 MB —— **采集不设上限**。
  3. `capture_disp_log.bat` 缺 `dumpsys meminfo`/`dumpsys window`（另两个脚本有），**同一次问题换个脚本抓就少两个关键证据**。
- **修复建议**：合并为一个带参数的脚本，例如
  ```bat
  adb_collect.bat /mode:snapshot|continuous /dur:60 /items:logcat,dmesg,dumpsys,screenshot,bugreport /tag:before|after
  ```
  内部固定 `adb logcat -c -b all`（清缓冲）→ 抓 → `logcat -d > tag.txt`；并给实时 `logcat` 加 `-b all -v threadtime` 与体积上限（`logcat -G 16M`）。

### [中] 4 个脚本 90% 代码重复（时间戳 4 行 + 等待/root 5 行 + dumpsys 9 行 + 结尾 6 行逐字相同）
- **实测 diff**：
  - `current_display.bat` vs `disp_continuous_monitor.bat`：`diff` 只报 `3c3`（`title` 不同）与 `22,33c22,33` → **L1–L21 逐字节相同**（L3 除外），L22–33 仅 `_current`→`_before` 后缀不同。
  - `备用脚本\monitor.bat` vs `disp_continuous_monitor.bat`：`diff` 只报 `17a18`（`disp` 多一行 `echo Creating output dir...`）与 `20d20` → **L1–L17 逐字节相同**，之后整体错位 1 行（`monitor.bat:18` = `disp:19` 的 `mkdir`）。
  - `备用脚本\capture_disp_log.bat` vs `current_display.bat`：`diff` 只报 `3c3`（`title`）与 `4a5`（`current_display` 多一行 `:: ==== 1. …` 注释）→ 时间戳 4 行代码块完全一致，仅相差 1 行注释的位移。
- **影响**：同一 bug（B-01/B-03/E 组）要改 4 遍；已经出现了"改了 3 个漏 1 个"（清缓冲只有 `monitor.bat` 有）和"抓取项不一致"（上表）。
- **修复建议**：抽取 `lib_collect.bat`（时间戳/建目录/日志函数），或按上一条彻底合并为单脚本 + 参数；`备用脚本\` 里保留旧版但加 `@echo off` 后第一行 `echo [DEPRECATED] use disp_continuous_monitor.bat` 提示。

### [中] disp_continuous_monitor.bat:49,51 — 实时抓取用 `adb shell logcat` / `adb shell dmesg -w`（多套一层远端 shell），与 L24/L51 的 `adb logcat -d` 不一致
- 现象：L49 `start "Logcat" cmd /c "adb shell logcat -b all -v threadtime > logcat.txt 2>&1"`；L51 `start "Dmesg" cmd /c "adb shell dmesg -w > dmesg.log 2>&1"`；而 L24 用 `adb logcat -d ...`（**不带** `shell`）。
- 影响：`adb shell logcat` 与 `adb logcat` 的 Ctrl-C/断开行为不同（前者可能因 adbd 断开留下半个缓冲）；两者同时跑时本机端可能争用同一 transport。命名也不一致（`logcat.txt` vs `logcat_all_before.txt`）。
- 修复建议：统一用 `adb logcat`（客户端侧），并给实时流加 `-b all -v threadtime` 与 `| findstr` 之外的明确停止方式。

### [中] disp_continuous_monitor.bat:54 — `pause` 阻塞期间无法判断 `start` 出来的窗口是否还在跑，L49/L51 的 `logcat.txt`/`dmesg.log` 可能仍是 buffer 状态
- 现象：L54 `pause`（无提示文案之外的检测）。用户在 L39-42 被告知"复现结束后需要手动关闭 Logcat/Dmesg 窗口"，但脚本**不校验**窗口是否已关。
- 影响：L56-67 的 after 快照可能在 `logcat.txt` 仍在写入时读取；`adb logcat -d` 与后台 `logcat` 并存时，`logcat_all_after.txt` 可能截断。
- 修复建议：改用 `timeout /t %DUR%` 自动停止，或 `tasklist /fi "WINDOWTITLE eq Logcat"` 轮询等待窗口关闭。

### [中] current_display.bat:24,26-34 / capture_disp_log.bat:20-33 — 未 `cd` 到 `%OUT%` 直接写相对文件名 vs 已 `cd`，两套写法混用
- 现象：`current_display.bat:20` `cd /d "%OUT%"` 后写裸文件名（L24-34）；`capture_disp_log.bat` **不 cd**（L17 后直接 `"%OUT%\xxx"`）；`disp_continuous_monitor.bat:20` cd + 裸名（L24-34），但 L84 又用 `"%OUT%\bugreport.zip"`（cd 之后仍拼绝对路径）。
- 影响：同目录下三份脚本的行为依赖"从哪启动"，`dir` 结果不一致；`bugreport.zip` 的落点在三份脚本里是三种规则。
- 修复建议：统一"先 `cd /d "%OUT%"` 且失败即 `exit /b 1`，之后一律用裸文件名"。

### [低] 4 个脚本输出文件名五花八门，无统一后缀约定
- 现象：`_current.txt`（current_display）/ `_before.txt`+`_after.txt`（disp_continuous_monitor）/ 裸名 `.txt`（capture_disp_log）/ `logcat.txt`+`dmesg.log`（monitor，且混用 `.txt` 与 `.log`）。
- 修复建议：统一 `<item>_<phase>.<ext>`，扩展名统一 `.txt` 或 `.log` 择一。

### [低] disp_continuous_monitor.bat:45,47 — 被注释掉的 `getevent` 与 `logcat -c` 是"功能开关"，但没有任何注释说明为何禁用
- 现象：L45 `::start "GetEvent" cmd /c "adb shell getevent -tlr > getevent.log 2>&1"`、L47 `::adb logcat -c -b all`；`monitor.bat:25,28` 里这两行是**启用**的。
- 影响：读者无法判断该不该开；而 `logcat -c` 的禁用直接导致 G-01 的"不清缓冲"问题。
- 修复建议：改成变量开关：`set "WITH_GETEVENT=0"` / `set "CLEAR_LOGCAT=1"`，并在 `if` 里判断。

---

## H. 其它一致性问题（B 组视角：`exit` vs `exit /b`、`setlocal`、`2>nul`）

### [高] disp_continuous_monitor.bat:90 / 备用脚本\monitor.bat:40 — 裸 `exit` 关闭整个 `cmd.exe`（含调用者）
- 现象：L90 `exit`（`disp_continuous_monitor.bat`）、L40 `exit`（`monitor.bat`）。对比 `PM_GPIO_CTRL-mimo.bat` 全篇用 `exit /b 0/1/2/3`（实测命中 L161,317,394,429,529,553,577,595,616,653,668,675,685,686,692,694,695,702,705,707,718,719,724,727,728,731,743,746,750,751,755,758,759,765,766）。
- **实测**（探针 `%TEMP%\batprobe\p8\ex_driver.bat`）：
  ```
  cmd /c "call ex_exit.bat  & echo DRIVER-CONTINUES"  → 只输出 "before exit"，后面全没了
  cmd /c "call ex_exitb.bat & echo DRIVER-CONTINUES"  → 输出 "DRIVER-CONTINUES-AFTER-EXIT-B"
  ```
- **影响**：任何人 `call disp_continuous_monitor.bat`（比如你自己的"先抓 before 再跑测试再抓 after"包装脚本）都会**被强行终止**；在 CI/自动化里表现为"后续步骤凭空消失"。
- **修复建议**：改成 `exit /b 0`。

### [中] 4 个抓取脚本缺少 `setlocal`（`current_display.bat` / `disp_continuous_monitor.bat` / `备用脚本\capture_disp_log.bat` / `备用脚本\monitor.bat`），与另 5 个脚本不一致
- 实测：有 `setlocal` 的：`PM_GPIO_CTRL-mimo.bat:2`、`auto_shot.bat:3`、`power-key.bat:2`、`push_apk.bat:3`、`push_msm_drm_ko.bat:3`；无的：上述 4 个。
- **影响**：直接后果就是 B-01 实测到的**变量泄漏到调用者**（`date`/`time`/`OUT` 全会外泄）；另外 `cd /d "%OUT%"`（L20/L19）**也不会被还原**，`call` 完之后调用者的 cwd 变成了日志目录 —— 这一点比变量泄漏更隐蔽。
- **修复建议**：4 个脚本的 `@echo off` 后统一加 `setlocal EnableDelayedExpansion`。

### [低] PM_GPIO_CTRL-mimo.bat:1 / power-key.bat:1 — 两个脚本没有 `chcp`，与其内部是否用中文无关，但与全仓风格不一致
- 已在 A 节讨论（`PM_GPIO` 纯 ASCII 输出其实**不需要** chcp；`power-key` 输出中文**需要**）。此条仅记录"9 个脚本 7 有 2 无"的事实，供汇总章统一结论。

### [低] 无 `2>nul` vs `>nul 2>&1` vs `2>&1` 的统一约定
- 统计：`>nul 2>&1` 出现在 `auto_shot.bat:27,30,42,45`、`disp_continuous_monitor.bat:72,74`、`PM_GPIO_CTRL-mimo.bat:265,684,701`；裸 `2>nul` 出现在 `current_display.bat:19,25,30`、`disp_continuous_monitor.bat:19,25,30,59,64`、`push_apk.bat:16`、`push_msm_drm_ko.bat:16`、`capture_disp_log.bat:17`、`PM_GPIO_CTRL-mimo.bat:88,102,717,735`。
- 影响：裸 `2>nul` **不重定向 stdout**，在 `for /f` 里搭配 `2^>nul` 时行为易错（见 E 节）；`PM_GPIO_CTRL-mimo.bat:88,102` 用 `set /a ... 2>nul` **吞掉了八进制报错**，正是 F-01 得以长期潜伏的原因。
- 修复建议：全仓统一"要静默就 `>nul 2>&1`"，只在明确只关心 stderr 的地方用裸 `2>nul`，并加注释说明。

---

## I. 硬编码清单（B 组：跨脚本一致性视角汇总，逐条带行号）

| 类别 | 值 | 位置 |
|---|---|---|
| 内网 IP / UNC 共享 | `10.71.255.189` / `yxb_sdc1` | `push_apk.bat:19`、`push_msm_drm_ko.bat:19` |
| 个人账号目录 | `kdo_nj` | `push_apk.bat:19` |
| 私有构建树 | `LINUX\android\out\target\product\neo\vendor\overlay\...` | `push_apk.bat:19` |
| 私有构建树 | `kc3\VENDOR\out\target\product\vienna\dlkm\lib\modules\...` | `push_msm_drm_ko.bat:19` |
| 包名 / Activity | `com.android.camera2` / `com.android.camera.CameraActivity` | `auto_shot.bat:27,30,45` |
| 屏幕坐标（**分辨率相关**） | `TAP_X=243` / `TAP_Y=512` | `auto_shot.bat:8-9,33` |
| 设备路径 | `/sdcard/DCIM/Camera` | `auto_shot.bat:10` |
| 设备路径 | `/sdcard/screenshot.png` | `disp_continuous_monitor.bat:71,72,74` |
| 设备路径 | `/vendor/overlay/FrameworksResOverlay_Wear.apk` | `push_apk.bat:12,16,19,23,24` |
| 设备路径 | `/vendor_dlkm/lib/modules/msm_drm.ko` | `push_msm_drm_ko.bat:12,16,19,23` |
| GPIO 基址表/规律 | `0xE800 + (N-1)*0x100`，`hb=0xE8+n-1` | `PM_GPIO_CTRL-mimo.bat:7-9,26,48,165-174` |
| 寄存器偏移表 | `04/05/10/40/41/44/45/46` | `PM_GPIO_CTRL-mimo.bat:50-57,690,700` |
| regmap 路径 | `/d/regmap/1-00` | `PM_GPIO_CTRL-mimo.bat:48,664` |
| 循环次数/间隔 | `max=100`、`INTERVAL=3`、`CAMERA_WAIT=2` | `power-key.bat:5`、`auto_shot.bat:6-7` |

### [中] auto_shot.bat:8-9 — `TAP_X=243 / TAP_Y=512` 是**特定分辨率**下的快门坐标，跨设备必错
- 影响：换一台分辨率/相机布局不同的机器，`input tap` 会点到预览区或返回键；脚本不校验当前分辨率。
- 修复建议：启动时 `adb shell wm size` 读出分辨率再按比例算，或用 `adb shell input keyevent KEYCODE_CAMERA`（不依赖坐标）。

### [中] push_apk.bat:11,18,23 vs 实际产品线命名 — `neo` 与 `vienna` 两套构建树说明脚本绑定单一项目
- 修复建议：把 `PRODUCT` 与 `SRC` 提为参数（见 D-02）。

---

## J. 可直接写进汇总章的"无需整改"结论（避免过度报告）

1. **UNC 双反斜杠写法正确**：`push_apk.bat:19`、`push_msm_drm_ko.bat:19` 磁盘上是 `\\10.71.255.189\...`，`.bat` 无转义语义，路径合法且已加引号。**不是 bug**。
2. **CRLF 一致性 100%**：9/9 文件全是 CRLF，`loneLF=0`、`loneCR=0`；**均无 BOM**。不需要逐文件处理。
3. **末尾缺换行在 `cmd.exe` 下无功能影响**（实测 `echo`/`goto`/`exit /b` 均正常），只是 diff 噪音。
4. **GBK 文件的中文注释不会破坏解析**：`PM_GPIO_CTRL-mimo.bat` 的 77 行注释在 cp936 与 cp65001 下都能被正确跳过，且不含"尾字节为元字符"的危险行。风险只在"被编辑器按 UTF-8 重存"。
5. **`PM_GPIO_CTRL-mimo.bat` 没有 `chcp` 是合理的**（输出全 ASCII），不要盲目给它加 `chcp 65001`。

---

## 附：本组条目优先级建议（交给汇总用）

| 优先级 | 条目 | 一句话 |
|---|---|---|
| P0 | B-03（4 个抓取脚本 `%OUT: =0%`） | 脚本目录含空格 → 日志写进被改名的影子目录 |
| P0 | E-02（`findstr /i "No such file"`） | 三个词 OR，`rm` 失败也报 "Old file removed"，可能刷了旧 overlay |
| P0 | H-01（裸 `exit`） | `call` 本脚本会把调用者一起杀掉 |
| P1 | F-01（`set /a` 八进制） | `010`/`016` 静默操作错 GPIO；`08` 被误判为非法 |
| P1 | B-01/B-02（覆盖 `date`/`time` + 码页相关） | 污染调用者环境；目录名不可预期 |
| P1 | E-01（`2>nul` 在管道左侧） | 远端 stderr 进不了 findstr，判定语义不可信 |
| P2 | A-01（`power-key.bat` UTF-8 无 `chcp`） | 唯一完成提示是乱码 |
| P2 | G-01（4 脚本抓取项不一致/不清缓冲） | 换脚本抓就少证据；`logcat.txt` 77 MB |
| P3 | C 组（末尾换行）、D-01（UNC） | **无需整改**，写进结论即可 |
