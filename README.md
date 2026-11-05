# bat_scripts — Android 显示排查批处理脚本集

Windows 批处理脚本，用于 Android 显示问题的日志采集与排查。

> 最后更新：2026-11-05

---

## 目录结构

```
bat_scripts/
├── disp_continuous_monitor.bat      显示问题复现采集（主力脚本，单文件无依赖）
├── current_display.bat              当前显示栈单次快照
├── qcom_collect_logs.bat            高通平台多路并行采集
├── PM_GPIO_CTRL-mimo.bat            PMIC GPIO 电平/方向/驱动强度调试
├── push_apk.bat                     推送 APK 到 /vendor/overlay
├── push_msm_drm_ko.bat              推送 msm_drm.ko 到 /vendor_dlkm/lib/modules
├── auto_shot.bat                    相机自动连拍并拉回本机
├── power-key.bat                    电源键压测
├── backup/                          早期精简版脚本（monitor / capture_disp_log）
├── docs/                            分析与优化文档
└── tools/                           排查用的窗口/对话框探针（备用）
```

---

## 脚本清单

| 脚本 | 用途 | 编码 | 双击运行 |
|---|---|---|---|
| `disp_continuous_monitor.bat` | 复现前基线 → 并行实时抓取 → 复现后快照 → 截图 → bugreport | GBK + 中文 | 可能弹签名确认框，点「執行」即可 |
| `current_display.bat` | 当前显示栈一次快照（点查） | 纯 ASCII | 正常 |
| `qcom_collect_logs.bat` | logcat/dmesg/DRI dump/DCP 事件/SF 多路并行 | 纯 ASCII | 可能弹签名确认框 |
| `PM_GPIO_CTRL-mimo.bat` | PMIC GPIO1–18 调试（交互菜单 + 命令行） | GBK + 中文 | 正常 |
| `push_apk.bat` / `push_msm_drm_ko.bat` | 推送文件 + reboot | 纯 ASCII | 正常 |
| `auto_shot.bat` / `power-key.bat` | 相机连拍 / 电源键压测 | 纯 ASCII | 正常 |

---

## 环境要求

- Windows 10 / 11
- `adb` 在 PATH 中，设备已授权
- 目标设备需可 `adb root`（否则 `dmesg` / 部分 `dumpsys` 会为空）
- PowerShell（脚本用 `Get-Date` 取时间戳、用 `Start-Process` 管理采集窗口）

---

## disp_continuous_monitor.bat 用法

双击运行，按提示复现问题，**按 S 停止**（或到时长/体积上限自动停止）。
停止后脚本自己关闭采集窗口并补终点快照，不需要手动关窗。

### 可调参数（环境变量覆盖，不用改文件）

```bat
set MAX_MIN=60 & set MAX_MB=2000 & disp_continuous_monitor.bat
set SKIP_BUGREPORT=1 & disp_continuous_monitor.bat
set ADB_SERIAL=<序列号> & disp_continuous_monitor.bat
```

| 变量 | 默认 | 含义 |
|---|---|---|
| `MAX_MIN` | 30 | 最长抓取分钟数，0 = 不限 |
| `MAX_MB` | 800 | 实时日志总大小上限 MB，0 = 不限 |
| `POLL_SEC` | 5 | 检查间隔秒数 |
| `LOGCAT_BUF` | 128M | 设备端 logcat 环形缓冲 |
| `CLEAR_LOGCAT` | 1 | 1 = 前基线之后清缓冲；0 = 保留开机以来 |
| `HARD_LIMIT_SEC` | 0 | 采集进程**设备端**硬上限秒数，0 = 不限 |
| `ADB_SERIAL` | 空 | 多设备时指定序列号 |
| `SKIP_BUGREPORT` | 0 | 1 = 跳过 bugreport（省 1–3 分钟）|
| `KEEP_RUNS` | 0 | 只保留最近 N 个 `LOGS_*` 目录，更早的自动删除；0 = 不清理 |
| `DCMON_NO_EXIT` | 未设 | 1 = 跳过结尾 pause，供自动化调用 |

### 产物

每次运行在脚本同目录生成 `LOGS_<yyyyMMdd_HHmmss>/`：

```
logcat.txt / dmesg.log              实时采集流
logcat_all_before.txt               复现前 logcat 基线
dmesg_before.txt 等 10 项           复现前 dumpsys 快照
logcat_all_after.txt 等 10 项       复现后快照
screenshot.png                      屏幕截图
bugreport.zip                       整机报告
session_summary.txt                 会话汇总（参数、时长、失败项、产物清单）
```

### 采集窗口

启动两个独立窗口并行抓取：

- `DCMON_LOGCAT` → `logcat.txt`（不含 kernel 缓冲，避免与 dmesg 重复）
- `DCMON_DMESG`  → `dmesg.log`

两个窗口可能重叠显示，把其中一个拖开即可。

> 曾经用 `_place_windows.ps1` 自动摆位，现已移除（重叠不影响功能，减少一个依赖文件）。

---

## 已知问题

### 1. 双击时可能弹「開啟檔案 - 安全性警告」

现象：双击 `.bat` 弹出未签名文件确认框，点「執行」后功能完全正常。

已确认：

- 弹窗由 `explorer.exe` 弹出（窗口类 `#32770`，所有者是文件夹窗口 `CabinetWClass`）
- 文件**没有** Zone.Identifier（用 Win32 `FindFirstStreamW` 直接验证）
- 与编码无关：纯 `@echo off` + `pause` 的三行脚本同样弹窗
- 与 `%TEMP%` 写入、McAfee、SmartScreen 策略均无关

**推测与中文路径有关**：用户反馈改到英文路径后弹窗会带「開啟這個檔案前一定要先詢問」复选框（不同的系统代码路径）。中文路径下退化为无复选框的简版确认框。

**规避建议**：把脚本放在纯英文路径下运行，例如 `D:\bat_scripts\`。

### 2. `qcom_collect_logs.bat` 往 `%TEMP%` 写临时脚本

企业环境若启用了「阻止 Temp 执行」策略（McAfee VirusScan Enterprise 等），可能被拦截。
`disp_continuous_monitor.bat` 已改为写入输出目录；`qcom_collect_logs.bat` 尚未处理。

---

## 文档

- `docs/BAT_SCRIPTS_ANALYSIS.md` — 全仓脚本静态审计报告（9 个脚本、70+ 问题条目）
- `docs/disp_continuous_monitor_OPTIMIZATION.md` — 主脚本优化与排查全过程
- `docs/current_display_OPTIMIZATION.md` — 快照脚本优化说明
- `docs/qcom_collect_logs_ANALYSIS.md` — 高通采集脚本功能分析
- `docs/audit/` — 审计原始素材（探针结论、复核记录）

---

## 编码约定

| 文件类型 | 编码 | 换行 | BOM |
|---|---|---|---|
| `.bat` | GBK（含中文时）或纯 ASCII | **CRLF** | 无 |
| `.ps1` | 纯 ASCII | CRLF | 无 |
| `.md` | UTF-8 | 不限 | 无 |

**改 `.bat` 时的硬性要求**：必须 CRLF。写成 LF 会导致 cmd 整段解析错乱
（表现为 `mmss"') do set "STAMP'` 这类半截命令）。

常见语法坑见 `docs/disp_continuous_monitor_OPTIMIZATION.md` 第六节。
