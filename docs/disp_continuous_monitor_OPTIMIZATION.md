# disp_continuous_monitor.bat 优化与问题排查全记录

> 对象：`disp_continuous_monitor.bat`（原版 90 行 → 现状 ~460 行）
> 备份：`.bak_20261105`（第二轮前）、`.bak_gbk`（GBK 版）、`.bak_ascii`（纯 ASCII 版）
> 审计依据：`BAT_SCRIPTS_ANALYSIS.md`（BLK-01 / H-01 / H-02 / H-03 / M-01 / M-03 / M-04 / L-06）
> 日期：2026-11-05
> 本文由 5 份分阶段文档合并而成，末尾保留「未解决」与「踩坑记录」两节。

---

# 一、脚本定位

显示问题复现采集器，保留原脚本骨架：

```
复现前基线快照 → 并行实时抓取 → 复现后快照 → 截图 → bugreport
```

核心改进：把「靠人手关采集窗口」换成**脚本自己按 PID 回收 + 墙钟/体积双上限**，并给每一步 adb 加退出码判定与产物字节数校验，最后落一份 `session_summary.txt`。

---

# 二、相对原版修复的缺陷

| # | 原版问题 | 修复做法 |
|---|---|---|
| 1 | **BLK-01** 两个采集窗口零回收，`pause` 是唯一"停止"手段，父脚本 `exit` 后子进程仍在灌盘 | 按 **PID** `taskkill /PID <pid> /T /F`（启动时用 `Start-Process -PassThru` 拿 PID）+ 设备端 `pkill -f` 双保险；收尾后**用"日志是否还在增长"实测确认**没残留 |
| 2 | 停止完全靠人手 | 主窗口 5 秒轮询：**按 [S] 立即停**、到 `MAX_MIN` 分钟停、到 `MAX_MB` MB 停 |
| 3 | 停止时刻不可复现 | 用 `%time%` 墙钟算真实已抓时长，写入 `session_summary.txt` |
| 4 | **H-01** `set "OUT=%OUT: =0%"` 把路径里的空格替换成 `0` → 日志写进"影子目录" | 时间戳用 PowerShell 取，**只对时间戳去空格**，路径原样拼接；路径一律加引号 |
| 5 | **H-02** 覆盖 cmd 内建 `date`/`time` 伪变量、无 `setlocal` | `setlocal EnableExtensions EnableDelayedExpansion`，不再占用 `date`/`time` |
| 6 | **H-03** `logcat` 不清缓冲、无上限，before/after 混进开机历史 | **先存前基线 → 再 `logcat -c` 清缓冲 → 再开抓**；`logcat -G` 可调缓冲 |
| 7 | **M-03** `mkdir`/`cd` 不看返回值 | `mkdir` 后 `if not exist` 判；`pushd` 失败即中止 |
| 8 | **M-04** `wait-for-device` 无超时、`adb root` 不判结果、root 后不再等 | 自写 `:wait_device`（带超时）；`adb root` 改用 `adb shell id` 查真实 uid 判定；root 后**再等一次设备** |
| 9 | **L-06** `adb bugreport` 无判定 | 判退出码 + 校验 zip 字节数（<1MB 提示截断） |
| 10 | 全脚本 0 处退出码校验 | 每次 adb 落盘后判退出码 + 字节数（`<32` 字节记 WARN，`≠0` 记 FAIL），失败项全部写进 `session_summary.txt` |

---

# 三、新增的可调参数

全部支持用环境变量覆盖，不用改文件：

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
| `DCMON_NO_EXIT` | 未设 | 1 = 跳过结尾 pause，供自动化调用 |

用法示例：

```bat
set MAX_MIN=60 & set MAX_MB=2000 & disp_continuous_monitor.bat
set SKIP_BUGREPORT=1 & disp_continuous_monitor.bat
set ADB_SERIAL=G0B61W026373000M & disp_continuous_monitor.bat
```

---

# 四、真机实测结果

设备：`G0B61W026373000M` / AEOTS / `p26-userdebug 16 SLMAIN16 7918P` / 已 root。

```
[ OK ] Output directory / 输出目录: ...\LOGS_20261105_xxxxxx
[1/9] 等待设备 ...      OK
[2/9] 申请 root ...      OK, adbd is running as root
[3/9] 抓取复现前基线 ... 10 项全 [ OK ]
[4/9] 准备 logcat 缓冲 ...
[5/9] 启动并行采集窗口 ...
[STOP] 达到时长上限 1 分钟, 自动停止
[6/9] 关闭采集窗口 ...
[7/9] 抓取复现后快照 ... 10 项全 [ OK ]
[8/9] 抓取屏幕截图 ...   [ OK ] screenshot.png (2386 bytes)
[9/9] 跳过 bugreport ...
Done! 退出码 0
```

各项改动对应的验证：

| 验证项 | 方法 | 结果 |
|---|---|---|
| 实时 logcat 去 kernel 缓冲 | `grep -c "beginning of kernel" logcat.txt` | **0**（改前 1） |
| 采集进程无残留 | `adb shell ps -A \| grep logcat\|dmesg` | **空** |
| 设备端硬上限 | `HARD_LIMIT_SEC=20`，40 秒后查设备端 | **空**，已自行退出 |
| SKIP_BUGREPORT | 查输出目录 | `bugreport.zip` 未生成 |
| root 检测 | 脚本输出 | `adbd is running as root`（无 `/system/bin/sh: can't create nul`）|
| 文件不外泄 | 跑完检查工作区根目录 | `root.txt` / `id.txt` / `devices.txt` 全在输出目录内 |

---

# 五、编码：当前为 GBK + 中文

当前文件是 **GBK 编码、含中文注释与提示**（约 123 行中文），CRLF 换行、无 BOM。

历史上有过两次来回，记录如下：

| 版本 | 编码 | 原因 | 结果 |
|---|---|---|---|
| 原版 | UTF-8 | — | 正常 |
| 第一轮 | GBK | 避开「UTF-8 + 块内中文」导致 cmd 解析器字节错位（`else was unexpected`） | 正常 |
| 第二轮 | 纯 ASCII | 误以为 GBK 导致双击弹窗 | **误判**，弹窗未消失 |
| 现状 | **GBK + 中文** | 按用户要求恢复 | 待验证 |

**关键结论**：双击弹窗与编码**无关**（见第七节）。

---

# 六、Windows 批处理语法坑（实测踩出来的，复用价值最高）

括号块 `( ... )` 内，以下字符会**提前闭合括号**或**被原样传给远端**：

| 写法 | 现象 | 正确做法 |
|---|---|---|
| 块内 `echo a & echo b` | `& was unexpected at this time.` | 拆成多行，或用 `^&` |
| 块内 `set "X=1" :: 注释` | `'X' is not recognized` | 注释单独占行 |
| 块内注释含 `(` 或 `)` | `else was unexpected at this time.` | 注释里避开括号 |
| 块内裸 `\|` | 管道提前截断块 | 改成先落文件再 `findstr` |
| `adb shell x 2^>nul`（**直接命令**） | 设备端收到字面量 `2>nul`，报 `can't create nul: Read-only file system` | 直接命令写 `2>nul`；只有 `for /f` 内的命令才需要 `^>` |
| `call :label "带(括号)的参数"` | cmd 会把括号当块语法，命令被拆成两半执行 | 参数里不要有括号 |
| 文件写成 LF 换行 | cmd 整段解析错乱（`mmss"') do set "STAMP'` 这类半截命令） | 必须 CRLF |
| UTF-8 批处理 + `chcp 65001`，块内含中文 | 解析器字节层面错位 | 用 GBK，或整份文件纯 ASCII |

其它：

- **`choice` 在无控制台（stdin 被重定向）时返回 255**，不是 1/2。用 `if errorlevel 1` 判"用户按了 S"会把 255 误判为停止。正确做法：`set "KEYRC=!errorlevel!"` 后精确比对。
- **`timeout` 可能被 Git-Bash 的 GNU `timeout` 抢占**（`timeout: invalid time interval '/t'`）。延时改用 `ping -n N+1 127.0.0.1 >nul`。
- **`find` 同样会被 GNU find 抢占**，脚本里判断文本请用 `findstr`。
- **`taskkill /F /IM adb.exe` 会杀光全机器所有 adb**，包括使用者自己终端里跑的。验证残留请用 `tasklist /v` 查询，不要批量杀。

---

# 七、双击弹窗问题（**未解决**）

## 7.1 现象

双击 `disp_continuous_monitor.bat` 弹出：

```
開啟檔案 - 安全性警告
無法確認發行者，您確定要執行這個軟體?
    名稱:    ...debug_temp\bat脚本\disp_continuous_monitor.bat
    發行者:  發行者不明
    類型:    Windows 批次檔案
    從:      D:\Desktop\debug_temp\bat脚本\disp_continuous_...
    [執行(R)] [取消]
    這個檔案沒有有效的數位簽章以確認它的發行者，您應該只執行來自您所信任發行者的軟體。
```

点「執行」后脚本能正常工作，**功能不受影响**。

## 7.2 已确认的事实（抓窗口现场得到的硬证据）

用一个 Win32 `EnumWindows` 探针在弹窗出现时抓取，结果：

```
DLG   pid=8832 (explorer)  class=#32770  title=[開啟檔案 - 安全性警告]
      child SysLink : ...debug_temp\bat脚本\disp_continuous_monitor.bat
      child Static  : 發行者不明
      child Static  : Windows 批次檔案
      child Button  : 執行(&R)
      child Button  : 取消
OWNER pid=8832 (explorer)  class=CabinetWClass  title=[bat脚本]
```

**结论：弹窗由 `explorer.exe` 在你打开的那个文件夹窗口（`CabinetWClass [bat脚本]`）上弹出**，不是 cmd.exe、不是 McAfee、不是编码问题。

## 7.3 已排除的可能

| 假设 | 排除依据 |
|---|---|
| GBK 编码导致 | 改成纯 ASCII 后**仍然弹窗** |
| MOTW / `Zone.Identifier` | 用 Win32 `FindFirstStreamW` 直接读文件流：只有 `::$DATA`（文件本身），**无 Zone.Identifier**；目录上返回 `err=38`（无任何流）；父目录链四级全查过 |
| 父目录 MOTW 继承 | `D:\Desktop` 里确有带标记的文件（`60 4k.json` 等），但 `debug_temp`、`bat脚本` 两级都没有 |
| 硬链接 / 重解析点 | `LinkType` 空、`ReparsePoint` False |
| McAfee 拦 `%TEMP%` 写入 | 采集脚本已移出 `%TEMP%`，**仍然弹窗**（McAfee 日志里那些 257 事件实际是我自己跑测试时产生的） |
| 附件管理器策略 | `ScanWithAntiVirus=3` 是默认值；无 `Attachment Manager` 策略键 |
| IE 区域「启动应用程序」设置 | Zone0–4 的 1806/2101 全为默认空值 |
| 文件关联被改 | `assoc .bat` = `batfile`，`ftype batfile` = `"%1" %*`，标准 |

## 7.4 用户提供的关键线索

- **`current_display.bat` 双击不弹窗**
- **`disp_continuous_monitor.bat` 最早（原版）也不弹窗**，是后来某个改动之后才开始弹的
- 弹窗上**没有**「開啟這個檔案前一定要先詢問」复选框

## 7.5 下一步（如果还要继续查）

「最早不弹、后来才弹」是最有价值的线索。建议用二分法定位到引入问题的具体改动：

1. 依次用历史备份双击测试：`.bak_20261105`（第二版）→ `.bak_gbk` → `.bak_ascii` → 当前 GBK 版，找出**第一个开始弹窗的版本**
2. 找到之后，把该版本与上一个不弹的版本做 diff，改动处就是根因
3. 重点怀疑：脚本里新增的 **PowerShell 调用**（`Start-Process`）——这是与 `current_display.bat` 差异最大的地方，而 `current_display.bat` 只用 PowerShell 取时间戳、不弹窗

## 7.6 可能的规避办法（若能接受）

1. 用快捷方式或 `.cmd` 包装层通过 `cmd /c` 调起，绕开 explorer 的直接执行路径
2. 找 IT 给该目录或该文件加白名单
3. 给文件加数字签名（需企业证书）

---

# 八、已知遗留问题

1. **双击弹窗**（见第七节）——功能不受影响，仅多一次确认。
2. **`qcom_collect_logs.bat` 也往 `%TEMP%` 写 5 个 `adb_col_*.bat`**，在这台机器上双击可能同样弹窗，尚未处理。
3. **多设备路径未在真机验证**（当前只连 1 台），检测与 `-s` 注入逻辑是静态验证的。
4. **`HARD_LIMIT_SEC` 依赖设备端 `toybox timeout`**。极老设备若无此命令，采集窗口会**立即退出而非报错**——真机上若发现 `dmesg.log` 为空且秒退，先查这条。
5. **长时间挂机（>30 分钟）的磁盘占用未验证**，只跑过 1–2 分钟窗口。

---

# 九、相关文件

| 文件 | 说明 |
|---|---|
| `disp_continuous_monitor.bat` | 主脚本（GBK + 中文） |
| `disp_continuous_monitor.bat.bak_20261105` | 第二轮改动前的版本 |
| `disp_continuous_monitor.bat.bak_gbk` | GBK 版本备份 |
| `disp_continuous_monitor.bat.bak_ascii` | 纯 ASCII 版本备份 |
| `current_display.bat` | 单次快照脚本（纯 ASCII，双击正常） |
| `current_display_OPTIMIZATION.md` | 该脚本的优化说明 |
| `BAT_SCRIPTS_ANALYSIS.md` | 全仓 9 个 .bat 的静态审计报告 |
