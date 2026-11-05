# qcom_collect_logs.bat 功能分析

> 对象：`qcom_collect_logs.bat`（209 行，ASCII/UTF-8 无 BOM，CRLF）
> 方式：纯静态阅读，未连设备、未运行任何 adb 命令
> 日期：2026-11-03

---

## 1. 一句话定位

高通（QCOM）显示子系统排障用的**并行日志采集器**：一次性打开多个 cmd 窗口，同时把 logcat、kernel log、DRM/DSI（DRI debug dump）、DCP/HFI 事件、SurfaceFlinger 状态分别落到独立文件里，人手按任意键后统一停掉，再补几份"停机时刻"快照。

关注点很明确——**DCP（Display Core Processor）/ DRM / DSI 面板链路**，不是通用安卓日志抓取玩具。

---

## 2. 执行流程（按脚本顺序）

| 阶段 | 动作 | 说明 |
|---|---|---|
| 1 | PowerShell 取时间戳 `yyyyMMdd_HHmmss` | 生成 `%~dp0logs_<时间戳>\`，在脚本所在目录下 |
| 2 | `mkdir` 输出目录 | 已存在时只是报错，不影响后续（重定向会自动建文件） |
| 3 | 打印产物清单 | 此时清单是"预期"，不是实际 |
| 4 | **一次性设备准备** | `adb root` → `adb remount` → 挂 `debugfs` 到 `/sys/kernel/debug` → `echo 31 > /d/dri/0/debug/enable`（打开 DRI 调试等级） |
| 5 | 清空并扩大 logcat 环形缓冲 | `adb logcat -c` + `adb logcat -G 128M`，避免抓的时候被冲掉 |
| 6 | 调 vendor 显示服务 | `vndservice call display.qservice 15 i32 0 i32 1 i32 1`（厂商 display qservice 事务号 15，作用是开某个 display 侧调试/日志开关，具体语义需查 vendor 侧实现） |
| 7 | 在 `%TEMP%` 里现场生成 5 个单路采集子脚本 | 用 `echo` 拼出来再 `start`，每个子窗口自己设 `title` 并 `echo` 目标路径 |
| 8 | **并行启动采集窗口** | 实际只启动 **4 个**：LOGCAT / KERNEL_LOG / XLOG / DCP_EVENTS；`SF_DUMPSYS` 那一行被 `::` 注释掉了 |
| 9 | `pause > nul` 挂住主窗口 | 主窗口是"总开关"，按任意键进入收尾 |
| 10 | `taskkill /fi "WindowTitle eq <名字>" /f` 逐个杀 | 按窗口标题匹配，5 个标题都杀一遍（含未启动的 SF，无副作用） |
| 11 | `timeout /t 2` 等 adb 释放句柄 | |
| 12 | 补 4 份一次性快照 | `dmesg` / `hfi_core_dump_events` / `card0/device/modalias` / `dumpsys SurfaceFlinger` |
| 13 | 删 `%TEMP%` 里的 5 个临时子脚本 | |
| 14 | 打印完整产物路径 + `pause` | 等你看完再关 |

---

## 3. 五路采集到底抓什么

| 窗口标题 | 命令 | 频率 | 用途 |
|---|---|---|---|
| `LOGCAT` | `adb logcat -v threadtime` | 流式 | 安卓侧全量日志（含 display/SF/HWC 打印） |
| `KERNEL_LOG` | `adb shell dmesg -w` | 流式 | 内核日志，DSI 时序、panel 上下电、I2C/regulator 报错都在这 |
| `XLOG` | `adb shell while true; do cat /d/dri/0/debug/dump; done` | **无 sleep 死循环** | DRM/KMS 侧 DSI 命令、面板状态、commit 状态机的完整 dump |
| `DCP_EVENTS` | `adb shell while true; do cat /sys/kernel/debug/hfi_core/hfi_core_dump_events; done` | **无 sleep 死循环** | 高通 HFI/DCP 核事件流（DPU 与 DCP 之间的消息） |
| `SF_DUMPSYS` | `dumpsys SurfaceFlinger` 循环 + `---SF_DUMP---` 分隔 | 默认关闭 | SF 层合成/图层状态时间线 |

对应产物：`logcat.log`、`kernel_log.txt`、`xlog_out.txt`、`dcp_events_stream.txt`（+ 停机快照 `dmesg_final.txt`、`dcp_events_final.txt`、`dcp_state_modalias.txt`、`sf_final.txt`）。

设计思路是"**流式全程 + 终点快照**"：现象发生时前面有完整时间线，复现结束时再补一份完整状态，方便前后对照。

---

## 4. 依赖与前置条件

- Windows 下可用 `adb`（在 PATH 里），且设备授权正常。
- 设备需**可 root**：`adb root`、`adb remount` 失败时脚本不会报错、继续往下跑，于是后续 `mount debugfs`、`/d/dri/0/debug/enable`、`hfi_core_dump_events` 全部失效——XLOG 与 DCP_EVENTS 两个文件里只会是一遍遍的 `No such file or directory`。
- 依赖 PowerShell（取时间戳）与 `taskkill`/`timeout`。
- 路径权限：输出目录建在**脚本所在目录**（当前就是含中文的 `D:\Desktop\debug_temp\bat脚本\`）。

---

## 5. 值得注意的几点（不改代码也能规避）

1. **默认只跑 4 路，但界面说 5 路**。`SF_DUMPSYS` 的 `start` 被注释（第 127 行），而启动提示和结尾清单仍写着 5 个采集窗口、仍列出 `sf.log`。实际不会有 `sf.log`，只有停机时的 `sf_final.txt`。想要 SF 时间线，取消第 127 行注释即可。
2. **两个 `while true` 无 `sleep`，日志体量不可控**。`XLOG` 和 `DCP_EVENTS` 是紧密循环，会同时拉高设备 CPU 并让本机文件快速膨胀；加上 logcat 128M 缓冲，长时间挂着很容易出现单文件上百 MB。当前 `LOGS_20261103_1015\` 里 `logcat.txt` 已约 75 MB，属同一量级。建议按复现窗口控制时长。
3. **脚本没有任何退出码校验**。`adb root` / `remount` / `mount` / `vndservice call` / `taskkill` 全都不看返回码，任一失败都表现为"看起来照常运行"。判断是否真的抓到了东西，只能事后看 `xlog_out.txt` / `dcp_events_stream.txt` 里是不是有真实 dump 而不是报错文本。
4. **按窗口标题 `taskkill` 的回收方式**。`start "LOGCAT"` 建的窗口标题会被子脚本里的 `title LOGCAT` 再固定一次，标题匹配是可靠的；但 `/f` 杀的是 cmd 宿主进程，若 adb 子进程没跟着退出，可能出现残留进程继续写文件的情况。收尾后建议顺手看一眼任务管理器里有没有多余的 `adb`。
5. **停采集靠人手按一次键**，脚本自身没有超时、没有体积上限。按了键才有终点快照，忘了按就等于一直在抓。
6. **中文路径 + 临时子脚本的编码**。子脚本是把 `%LOG_DIR%`（含中文 `bat脚本`）用 `echo` 写进 `%TEMP%\*.bat` 再由新窗口执行的。父/子窗口 codepage 一致时没问题；如果某个窗口事先 `chcp 65001` 过，中文目录名有可能被写坏、重定向到错误路径。脚本本身没 `chcp` 语句。此项为推演，若真遇到"文件生成在奇怪目录"，按这条排查。
7. `adb logcat -c` 与 `-G 128M` 的顺序：先清再改大小，多数版本上改大小本身也会清缓冲，效果一样；但 `-G` 之后缓冲区被显式放大，会影响设备全局状态（其他人在抓 log 时要注意）。
8. 主窗口 `pause` 结束时脚本目录下会多出一个 `logs_<时间戳>` 目录，脚本不负责清理旧目录，多次运行会持续堆积。

---

## 6. 与同目录其他脚本的关系

同目录 `BAT_SCRIPTS_ANALYSIS.md` 里审计的 9 个脚本走的是"复现前后双快照 + bugreport"路线（`disp_continuous_monitor.bat` 等），而本脚本走的是**多路并行长时流式 + 终点快照**，更偏向显示链路的时序级排查。两者可以叠加使用：本脚本负责拿到 DSI/DPU/DCP 的完整时间线，另一个负责 before/after 基线与整机 bugreport。
