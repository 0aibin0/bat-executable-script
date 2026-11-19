# current_display.bat 优化说明

> 对象：`current_display.bat`（原版 40 行 → 优化版 192 行）
> 更新：2026-11-19 新增可选 bugreport（`ENABLE_BUGREPORT=1`）
> 备份：`current_display.bat.bak_20261105`（原版原样保留）
> 验证：真机实测（AEOTS / p26-userdebug / 已 root），非桩测试
> 日期：2026-11-05

---

## 1. 这个脚本干什么

一次性抓取当前显示栈的**状态快照**，抓完就退出——没有实时抓取、没有后台窗口、不需要复现操作。

产物（文件名与原版完全一致，便于既有习惯沿用）：
`devices.txt` / `logcat_all_current.txt` / `dmesg_current.txt` / `dumpsys_display_current.txt` / `dumpsys_sf_current.txt` / `dumpsys_input_current.txt` / `dumpsys_power_current.txt` / `dumpsys_gpu_current.txt` / `dumpsys_meminfo_current.txt` / `dumpsys_window_current.txt` / `getprop_current.txt` / `cmdline.txt`

新增一份 `snapshot_summary.txt`，列出每个产物的字节数。

**默认不抓 bugreport**（见第 6 节）：这个脚本定位是"几秒出结果的快速点查"，而 `adb bugreport` 要 1–3 分钟。需要时用 `ENABLE_BUGREPORT=1` 显式开启。

---

## 2. 修了什么

| # | 原版问题 | 后果 | 改法 |
|---|---|---|---|
| 1 | `set "OUT=%OUT: =0%"` | 这行是**对整个路径**做子串替换，脚本目录里的空格被换成 `0`。实测：`my folder` → `my0folder`，日志写进"影子目录"，而结尾还打印"已保存到"那个错误路径 | 删掉整行。时间戳单独去空格，路径原样拼接 |
| 2 | `for /f ... ('date /t')` 拼时间戳 | 中文 Windows 下 `date /t` 输出 `2026/11/05 星期三`，`tokens=2-4` 拼出 `1105星期三`，目录名非法且每日都不同 | 改用 PowerShell `Get-Date -Format yyyyMMdd_HHmmss`；PowerShell 不可用时退回 `%date%`/`%time%` 拼接并去空格 |
| 3 | `set "date="` / `set "time="` | 覆盖 cmd 内建动态伪变量；脚本无 `setlocal`，污染泄漏给调用者 | `setlocal EnableExtensions EnableDelayedExpansion`，不再占用 `date`/`time` 变量名 |
| 4 | `mkdir`/`cd` 不看返回值 | 建目录失败时 cmd 停在原目录继续跑，日志**散落在脚本目录**，而结尾照旧打印"已保存到 %OUT%"（那个空目录） | `mkdir` 后 `if not exist` 判；`pushd` 失败即中止 |
| 5 | `adb wait-for-device` 无超时 | 设备没插就一直卡住，脚本永远不返回 | 自写 `:wait_dev` 带 60 秒超时，超时明确报错并退出码 1 |
| 6 | `adb root` 不判结果、root 后不再等 | `adb root` 会重启 adbd，连接短暂断开；脚本紧接着抓取可能落在断连窗口里 | root 后再 `wait_dev` 一次；并用 `adb shell id` 查真实 uid 判定是否 root（不看 `adb root` 的退出码） |
| 7 | 11 个 adb 调用**零退出码校验** | 全部失败也打印"Done!" | 每次都判退出码，并把字节数打出来；失败项写进 summary |
| 8 | `dmesg_current.txt 2>nul` | `2>nul` 只丢 stderr、不看 stdout，文件空了也不知道原因 | 统一 `2>&1`，错误信息留在文件里 |
| 9 | 无设备/无 root 场景无区分 | 一律报成功 | 非 root 明确 WARN 并说明哪些文件会受影响 |

---

## 3. 真机实测结果

设备：`G0B61W026373000M`，model `AEOTS`，`p26-userdebug 16 SLMAIN16 7918P`，已 root。

```
[1/4] Waiting for device ...
      OK, device is online.
[2/4] Requesting root ...
      OK, adbd is running as root.
[3/4] Creating output dir ...
[4/4] Capturing snapshots ...
  [ OK ] devices.txt  109 bytes
  [ OK ] logcat_all_current.txt  1279950 bytes
  [ OK ] dmesg_current.txt  538741 bytes
  [ OK ] dumpsys_display_current.txt  89389 bytes
  [ OK ] dumpsys_sf_current.txt  34170 bytes
  [ OK ] dumpsys_input_current.txt  29306 bytes
  [ OK ] dumpsys_power_current.txt  91272 bytes
  [ OK ] dumpsys_gpu_current.txt  2844 bytes
  [ OK ] dumpsys_meminfo_current.txt  34782 bytes
  [ OK ] dumpsys_window_current.txt  25489 bytes
  [ OK ] getprop_current.txt  68924 bytes
  [ OK ] cmdline.txt  919 bytes
```

12 项全部成功，退出码 0。

**场景 A：无设备**（PATH 里去掉 adb）
```
[1/4] Waiting for device ...
[FAIL] No device within 60 seconds. Run "adb devices" to check.
[FAIL] Snapshot aborted, nothing was written to "...".
DRIVER-EXITCODE=1
```
正确中止，不写任何文件。

**场景 B：脚本放在含空格的目录里**（同一台机、同一次运行，新旧对比）
```
##### NEW VERSION #####
 Artifacts in: "...\spacetest\my folder\LOGS_20261105_152058"

##### ORIGINAL VERSION #####
 Done! Logs saved to: "...\spacetest\my0folder\LOGS_20261105_1521"
```
原版把 `my folder` 改写成了 `my0folder`，新版保持原样。这就是第 1 条缺陷的现场证据。

---

## 4. 与 disp_continuous_monitor.bat 的分工

| | current_display.bat | disp_continuous_monitor.bat |
|---|---|---|
| 场景 | 平时看当前状态 | 复现一个问题时抓现场 |
| 抓取方式 | 一次快照 | 并行实时 + 前后双快照 |
| 是否清 logcat 缓冲 | **不清**（保留开机以来历史） | 复现期专用时清 |
| 耗时 | 几秒（开 bugreport 后多 1-3 分钟） | 几分钟 |
| bugreport | 可选，`ENABLE_BUGREPORT=1` | 默认抓，`SKIP_BUGREPORT=1` 可跳过 |

两者产物命名不同（`_current` vs `_before`/`_after`），不会互相覆盖。

---

## 5. 编码说明

本脚本**纯 ASCII、CRLF 行尾、无 BOM**。

- 原版是 UTF-8 + `chcp 65001`，脚本正文本身没有中文，所以本来也能跑；改纯 ASCII 是为了彻底避开一类 Windows 批处理编码坑：**cmd 读取 UTF-8 批处理时，若代码块内出现中文，解析器会在字节层面错位**，把注释/命令截断（这个坑在 `disp_continuous_monitor.bat` 上踩过，表现为 `else was unexpected at this time`）。
- 输出目录名里若含中文（如 `bat脚本`），不影响：`%~dp0` 由 cmd 内部按 Unicode 处理，与脚本文件自身编码无关。
- 消息文案沿用原版的英文，保持一致且零风险。

---

## 6. 使用方式

```bat
current_display.bat                              :: 正常抓一次（12 项快照，几秒），结束前 pause
set SNAP_NO_PAUSE=1 && current_display.bat       :: 不 pause，适合被别的脚本 call
set ENABLE_BUGREPORT=1 && current_display.bat    :: 额外抓 bugreport（多花 1-3 分钟）
```

产物目录：`脚本同目录\LOGS_<yyyyMMdd_HHmmss>\`

### 可选：bugreport

| 变量 | 默认 | 含义 |
|---|---|---|
| `ENABLE_BUGREPORT` | 0 | 1 = 额外执行 `adb bugreport`，产出 `bugreport.zip` |
| `SNAP_NO_PAUSE` | 0 | 1 = 跳过结尾 pause |

开启后流程从 4 步变 5 步，编号自动调整（`[1/5]` … `[5/5]`）：

```
[5/5] Generating bugreport (1-3 min, do not close this window) ...
  [ OK ] bugreport.zip  4634864 bytes
```

校验规则与 `disp_continuous_monitor.bat` 一致：
退出码非 0 → `[FAIL]`；`zip` 小于 1 MB → `[WARN]` 疑似截断
（截断的 zip 通常是磁盘不足或设备端 `bugreportz` 异常）。
结果同样记进 `snapshot_summary.txt`。

失败不影响其余快照：12 项快照已经先落盘了。

> **注意**：这一项在 2026-11-19 加进去时**没有连真机验证**（当时 `adb devices` 为空）。
> 逻辑与 `disp_continuous_monitor.bat` 里已实测过的 bugreport 段一致，属于静态验证。

---

## 7. 未覆盖的情况

- 多设备同时在线时没有做序列号绑定（与仓库里 `PM_GPIO_CTRL-mimo.bat` 的 H-07 同类问题，本脚本未引入该复杂度）。
- `dumpsys gpu` 在本机只有 2844 字节，属于该设备 dumpsys gpu 输出本身较短，不是抓取失败。
- 未经长时间挂机验证（本脚本是单次快照，不涉及长时间写入）。
- **`ENABLE_BUGREPORT=1` 分支未在真机验证**（2026-11-19 添加时无设备在线）。
