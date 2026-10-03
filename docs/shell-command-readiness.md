# ZOS 實作階段與 shell 指令適配調查

調查日期：2026-10-03。基準：目前工作目錄，包含尚未提交的實作。
本次新增調查文件，沒有新增 shell 指令。以下順位是依現有能力做出的工程判斷。

## 目前的 OS 階段

ZOS 已進入「可互動的 Ring 0 核心與協作式 task」階段。
事件等待與 task 生命週期已完成，下一批指令可以直接呈現這些核心能力。
目前尚未建立檔案、使用者程式與系統呼叫的執行環境。

| 項目 | 目前實作 | 依據 |
| --- | --- | --- |
| 開機與建置 | Zenc 轉譯為 freestanding C，連結為 i686 Multiboot v1 ELF，可由 GRUB ISO 開機 | [Makefile](../Makefile)、[boot.S](../arch/i686/boot.S)、[kernel_main](../kernel/kernel.zc) |
| 輸出 | 80×25 VGA 文字主控台，支援換行、捲動與 Backspace；COM1 用於核心訊息 | [console.zc](../kernel/console.zc)、[serial.zc](../kernel/serial.zc) |
| 中斷與時間 | IDT、PIC、IRQ0／IRQ1，PIT 約 100 Hz；提供 tick、頻率與 divisor 查詢 | [interrupts.zc](../kernel/interrupts.zc)、[timer.zc](../kernel/timer.zc) |
| 輸入與 shell | PS/2 字元 queue，有效容量 63 字元；shell 無輸入時阻塞，成功輸入會喚醒；目前只有 `clear` | [keyboard.zc](../kernel/keyboard.zc)、[shell.zc](../kernel/shell.zc) |
| Task 排程 | 單 CPU、Ring 0、協作式 Round-Robin；4 個 slot，boot 與 shell 各占 1 個；3 個工作 slot 各有 4 KiB 靜態 stack | [task.zc](../kernel/task.zc)、[tasks.S](../arch/i686/tasks.S) |
| Task 生命週期 | 支援 `BLOCKED`、wait channel 與喚醒；entry 返回後換 stack 再回收；ID 含 generation，可拒絕過期 ID | [task.zc](../kernel/task.zc)、[生命週期契約](task-lifecycle-plan.md) |
| 記憶體 | Linker 保留固定 64 KiB heap，使用 bump allocator；沒有逐筆釋放 API，也沒有全機 RAM 統計 | [linker.ld](../arch/i686/linker.ld)、[memory.zc](../kernel/memory.zc) |

Task stack 的重用是固定 slot 的回收，與 heap 配置後不能釋放是兩件事。
`task_count()` 是本次開機累計建立數，`task_live_count()` 是存活數，兩者都包含 boot task。
目前 shell 指令在常駐 shell task 內執行，不會替每條指令建立新 task。
[Task 定義](../CONTEXT.md)、[計數 API](../kernel/task.zc)、[shell 執行路徑](../kernel/shell.zc)

目前沒有 VFS／檔案系統、路徑與工作目錄、檔案讀寫 API、程式載入器、Ring 3、system call、paging、
PIT 搶佔式排程、timer deadline sleep、RTC 日期時鐘、signal 或登入使用者模型。
這些缺口依目前 [kernel 模組](../kernel/)、[架構實作](../arch/i686/)、
[建置模組清單](../Makefile) 與 [README 範圍](../README.md) 判定。
一般 CPU exception 路徑目前只記錄資訊與設定 halted 旗標，仍未完成通用 panic 停止路徑。
Task 契約錯誤另有永久 halt 實作，不能把兩者視為相同能力。
[exception dispatcher](../kernel/interrupts.zc)、[task 契約錯誤](../kernel/task.zc)

## 文件與驗證基準

[next-feature-priority.md](next-feature-priority.md) 記錄的是事件等待與 task 回收之前的基準。
其中「沒有 `BLOCKED`」與「退出後不重用 slot」已不符合目前程式碼。
[shell-contract.md](shell-contract.md) 對指令仍符合現況，但對 queue 消費方式的描述較舊。
目前 shell 使用 `keyboard_read_blocking()`，不是空 queue 時反覆 `task_yield()`。
本次保留歷史文件，依目前程式碼與後續驗收紀錄評估能力。
[事件等待結果](event-wait-results.md)、[Task 生命週期結果](task-lifecycle-results.md)、[shell_task](../kernel/shell.zc)

本次重新執行 `make test`，退出碼為 0。
通過範圍包含核心連結、toolchain、console、interrupt／memory、timer、keyboard、queue、shell、
task、direct boot、GRUB ISO、IRQ flags、事件等待與 task 生命週期。
事件等待與生命週期主機測試均涵蓋 `-O0` 與 `-O2`，生命週期測試包含 100 次返回與重用。
本次輸出保存在 `/tmp/zos-command-research-make-test-20261003.log`，該檔案不納入版本控制。
既有編譯與連結警告仍出現在日誌中，測試通過不代表零警告。
[測試 targets](../Makefile)、[事件等待測試](../tests/event_wait_static.sh)、[生命週期測試](../tests/task_lifecycle_static.sh)

專用的 QEMU 100 輪輸入與生命週期矩陣，本次沒有重新執行。
其先前通過紀錄見 [event-wait-results.md](event-wait-results.md)
與 [task-lifecycle-results.md](task-lifecycle-results.md)。

## 建議順序

第一批適合加入 `help`、`echo`、基本 `uname`，以及明示簡化語意的 `uptime`。
這些指令能改善操作與辨識系統，也能使用現有 console 與 timer。
`uptime` 必須說明計時起點、近似精度及 tick 回繞限制。

建議分成以下可獨立驗收的範圍：

| 順位 | 指令 | 建議第一版範圍 | 所需新增工作 |
| --- | --- | --- | --- |
| 1 | `help` | 列出目前內建指令及用法 | 指令表與說明文字 |
| 2 | `echo` | 輸出簡單文字與換行 | 有界參數解析，明定空白、引號與跳脫規則 |
| 3 | `uname` | 預設輸出 `ZOS`；可支援 `-s` 與目標架構 `-m` | 系統識別常數與選項檢查 |
| 4 | `uptime` | 顯示 timer 啟用後估算的運作時間 | 整數格式化與計時限制說明 |
| 5 | `tasks` | 列出完整 Task ID 與 state，可附存活數和累計數 | 一致的 task snapshot API |
| 6 | `heap` | 顯示 heap 容量、已用與未配置空間 | Heap 範圍與容量查詢 API |

前四項適合先完成一個小里程碑，保留現有 `clear`。
後兩項讓目前核心功能可觀察，但應各自補查詢 API，讓 shell 透過 API 取得資料。
它們不需要先加入 Ring 3、磁碟或完整 Linux ABI。
這個順序是本次工程建議，官方語意與來源見下一節。

`tasks`、`heap`、`ticks` 適合作為 ZOS 自訂診斷指令。
它們能直接對應目前核心中的 task、bump allocator 與 PIT。
`tasks` 仍須先新增安全的 task snapshot 或有效 ID 列舉介面。

`history` 可以稍後加入有限容量的記憶體清單。
`sleep` 應先補足 timer deadline 與 task 喚醒機制。
`ls`、`pwd`、`cd`、`cat`、`date`、`kill`、`exit` 宜等待各自依賴建立。
目前僅有 heap 統計，不適合以 `free` 名稱描述全系統記憶體。

## 官方語意與必要依賴

下表中的「必要依賴」是依據官方語意，以及 ZOS 原始碼提出的工程判斷。
它不是官方文件對 ZOS 的規定。
採用相同名稱時，可以明確提供功能子集。
不能因此宣稱完整 Linux、Bash 或 POSIX 相容。

| 指令 | 官方主要語意 | ZOS 最低依賴與建議 |
| --- | --- | --- |
| `help` | Bash 內建指令，列出內建功能，或顯示指定功能的說明。 | 現有 console 足以支援。第一版列出實際存在的指令及限制。不是 POSIX 所規定的 `help` 指令。[Bash 內建指令](https://www.gnu.org/software/bash/manual/html_node/Bash-Builtins.html) |
| `echo` | 輸出參數，各參數之間加空白，最後加換行。 | 先建立指令名稱與參數的邊界。純文字輸出不需要 filesystem。第一版須明定引號、空白及反斜線行為。POSIX 對 `-n` 與反斜線的跨系統行為有限制。[POSIX echo](https://pubs.opengroup.org/onlinepubs/9699919799.2016edition/utilities/echo.html) |
| `uname` | 顯示系統與機器資訊。未給選項時等同 `-s`。 | 可從真實的核心名稱及建置目標開始，例如 `uname`、`uname -m`。其他欄位須有明確 metadata。[GNU uname](https://www.gnu.org/software/coreutils/manual/html_node/uname-invocation.html) |
| `uptime` | 顯示運作時間。procps-ng 預設也顯示目前時間、登入人數及 1/5/15 分鐘 load average。`-p` 只要求可讀的運作時間格式。 | 可以先提供簡化輸出或 `-p`。現有 PIT 足以估計 timer 啟用後的時間。不可把不存在的使用者、時鐘與 load average 寫成假數值。[procps-ng uptime](https://gitlab.com/procps-ng/procps/-/raw/master/man/uptime.1) |
| `sleep` | 暫停指定時間。GNU 支援多個時間值、單位與小數。GNU 文件指出可攜 POSIX 用法是單一非負整數秒數。 | 建立整數參數解析、時間溢位檢查、deadline 與 task 喚醒。第一版 `sleep N` 可只接受整數秒。避免讓 shell 忙等或阻擋其他 task。[GNU sleep](https://www.gnu.org/software/coreutils/manual/html_node/sleep-invocation.html) |
| `ps` | 顯示所選 process 的快照。Linux 的 `ps -e` 也能列出 kernel threads。 | Ring 3 不是硬性前提。ZOS 目前須先提供有效 ID 列舉及一致的 snapshot。欄位只能顯示已建立的 task 資料。若名稱是 `ps`，須明示這是 ZOS task 的簡化視圖。[procps-ng ps](https://gitlab.com/procps-ng/procps/-/raw/master/man/ps.1) |
| `free` | 顯示全系統實體與 swap 記憶體使用量，也顯示核心 buffers 與 caches。Linux 實作讀取 `/proc/meminfo`。 | 需要真實的可用實體記憶體範圍與分配統計。ZOS 不必建立 `/proc` 才能使用此名稱，但只顯示固定 heap 會改變主要語意。先用 `heap`。[procps-ng free](https://gitlab.com/procps-ng/procps/-/raw/master/man/free.1) |
| `ls` | 列出檔案資訊。未指定路徑時列出目前目錄內容。 | 先建立 filesystem namespace、目錄列舉及目前目錄。可以從 RAM filesystem 開始，不必先有磁碟驅動。不能用 host repo 目錄充當 ZOS 目錄。[GNU ls](https://www.gnu.org/software/coreutils/manual/coreutils.html#ls-invocation) |
| `pwd` | 顯示目前工作目錄的絕對路徑。 | 需要真實的目前目錄與路徑模型。沒有 namespace 時硬編碼 `/` 只會提供假操作環境。[POSIX pwd](https://pubs.opengroup.org/onlinepubs/009695399/utilities/pwd.html) |
| `cd` | 改變目前 shell 執行環境的工作目錄。 | 需要目錄查找、路徑解析及 shell 的目前目錄狀態。完整 POSIX 行為還包含 `HOME`、`PWD`、`OLDPWD`、`CDPATH` 與符號連結政策。[POSIX cd](https://pubs.opengroup.org/onlinepubs/000095399/utilities/cd.html) |
| `cat` | 依序把檔案內容寫到標準輸出。未給檔案，或指定 `-`，則讀標準輸入。 | 檔案版需要檔案查找、讀取及 EOF。僅讀鍵盤的版本仍須建立輸入串流與 EOF 語意。VGA 輸出也要定義控制字元處理。[GNU cat](https://www.gnu.org/software/coreutils/manual/html_node/cat-invocation.html) |
| `date` | 顯示日期與時間，部分用法會設定系統時間。 | 需要真實的民用時間來源、日期換算及時區政策。PIT elapsed time 不能代替日期。可先建立唯讀 RTC 與明確 UTC 政策。[GNU date](https://www.gnu.org/software/coreutils/manual/html_node/date-invocation.html) |
| `kill` | 向 process 發送 signal。預設發送 `TERM`，也能列出 signal。 | 需要 signal 或明定的等效機制、目標 ID 驗證及停止政策。只改 task 狀態不能提供完整 `kill` 語意。先保留此名稱。[GNU kill](https://www.gnu.org/software/coreutils/manual/html_node/kill-invocation.html) |
| `history` | Bash 顯示帶編號的命令清單，也支援操作清單與歷史檔案。 | 基本清單可放在有總容量上限的記憶體緩衝區。明示重開機即清除。檔案持久化、時間戳及歷史展開可延後。[Bash history](https://www.gnu.org/software/bash/manual/html_node/Bash-History-Builtins.html) |
| `exit` | 結束 shell，並將狀態回傳給父程序。 | 先定義 shell 結束後的操作入口、重啟政策與退出狀態。目前唯一 shell 結束後，系統可能只剩 idle。不要把關機、重開機或停機動作混入 `exit`。[Bash exit](https://www.gnu.org/software/bash/manual/html_node/Bourne-Shell-Builtins.html) |

## 容易誤解的名稱

### `uptime` 與 `ticks`

`uptime` 的主要目的仍是顯示系統運作時間。
procps-ng 的 `-p` 格式證明它不必每次顯示 load average。
因此，ZOS 可以先提供明確的運作時間子集。[procps-ng uptime](https://gitlab.com/procps-ng/procps/-/raw/master/man/uptime.1)

現有 `timer_ticks()` 從 `timer_init()` 開始計數。
它沒有包括 timer 啟用前的開機時間。
`timer_frequency()` 回傳整數頻率，而 PIT 的實際頻率取決於 divisor。
用兩者換算秒數是近似值。
`u32` ticks 在 100 Hz 時約 497 天回繞，直接相除會使運作時間突然變小。
若要求跨越這個邊界，應建立可跨 `u32` 回繞的累積時間讀取介面。
現有 tick 計算收到的 IRQ0 次數，長時間關閉 IRQ 也可能使估算時間偏短。
[計時 API 與 IRQ 處理](../kernel/timer.zc)、[開機時的初始化順序](../kernel/kernel.zc)

若只要觀察 IRQ 計數，`ticks` 名稱更直接。
輸出應標示 raw ticks、頻率與 divisor，並說明回繞。
這是 ZOS 自訂診斷名稱，不是 Linux 指令相容性的證據。

### `ps` 與 `tasks`

Linux 的 `ps` 不限於使用者程序。
官方手冊描述 `LIBPROC_HIDE_KERNEL` 可隱藏 `ps -e` 平常會列出的 kernel threads。
因此，缺少 Ring 3 或獨立 user address space，並不單獨阻擋簡化 `ps`。[procps-ng ps](https://gitlab.com/procps-ng/procps/-/raw/master/man/ps.1)

目前 ZOS 的公開 API 提供 `task_current()`、`task_state(id)`、`task_count()` 與 `task_live_count()`。
ID 含 slot 與 generation。
slot 重用後，舊的 `0..3` ID 不再能代表全部 task。
`task_count()` 是累計建立數，也不是可列舉 ID 的上界。
第一步應建立一致的 snapshot，回傳完整有效 ID、狀態與可用欄位。
[Task ID 與查詢 API](../kernel/task.zc)、[生命週期詞彙](../CONTEXT.md)

在短暫的 IRQ 保護區內複製資料，還原 IRQ 狀態後再輸出表格。
執行 `tasks` 時，shell 本身通常是 `RUNNING`，不能把鍵盤等待時的 `BLOCKED` 當成固定輸出。
目前 dispatch／block／wake counters 只在 `ZOS_EVENT_WAIT_TEST` 建置中存在，不能直接用來提供正式版 CPU 使用率。
[Task 狀態交接與測試 counters](../kernel/task.zc)、[shell 執行路徑](../kernel/shell.zc)

`tasks` 能準確描述目前核心的模型。
第一版可以列出 `ID` 與 `STATE`，並標示 boot/idle task 是否包含在內。
尚無資料的 `PID`、`USER`、`TTY`、`TIME`、`COMMAND` 或記憶體欄位不應填入假值。
若日後選用 `ps`，應在 `help` 中明示支援範圍。

### `free` 與 `heap`

Linux `free` 的 `total` 分別統計可用實體記憶體總量與 swap 總量。
它的 `available` 表示可供新應用程式使用的估計量。
這些值與 allocator 剩餘空間不同。[procps-ng free](https://gitlab.com/procps-ng/procps/-/raw/master/man/free.1)

ZOS 的 bump allocator 只追蹤自己的 heap 範圍。
`zos_memory_limit()` 回傳 heap 上界位址，不是容量。
`zos_memory_used()` 包含 cursor 前移所消耗的對齊空間。
這個值不包含核心映像、靜態 task stacks 或其他 heap 以外的記憶體。
所以 `heap` 比 `free` 更符合目前資料。
[Heap 實作](../kernel/memory.zc)、[靜態 task stacks](../kernel/task.zc)、[Heap 保留區](../arch/i686/linker.ld)

建議 `heap` 顯示 `start`、`end`、`capacity`、`used` 與 `remaining`。
`capacity` 需由 `end - start` 計算。
`remaining` 需由 `end - cursor` 計算，並先驗證範圍。
`remaining` 是尚未配置的位元組數，不保證任何 alignment 都能配置全部空間。
輸出也應說明不支援逐筆釋放，正常開機流程會重新初始化 heap。
現有公開 API 尚未提供完整範圍快照，shell 應透過新增查詢介面取得這些值。
[Allocator 與初始化 API](../kernel/memory.zc)、[kernel_main](../kernel/kernel.zc)

### `uname` 的欄位

GNU 定義 `-s` 為核心名稱，`-m` 為機器硬體類型，`-r` 為 release，`-v` 為 version。
`-n` 為 nodename，`-o` 為作業系統名稱。
`-p` 與 `-i` 是不可攜欄位，缺少資料時 GNU 會顯示 `unknown`。[GNU uname](https://www.gnu.org/software/coreutils/manual/html_node/uname-invocation.html)

| 欄位 | ZOS 建議 |
| --- | --- |
| 預設、`-s` | 使用實際核心名稱 `ZOS`。 |
| `-m` | 可使用建置目標 `i686`，但須說明這是目標架構。它不是實際 CPU 型號。 |
| `-r` | 使用專案維護的 release metadata。若尚未定義，先不支援此選項。 |
| `-v` | 使用可追溯的建置版本，例如正式版本或明示的 build ID。不要冒充 Linux version。 |
| `-n` | 先定義固定或可設定的系統名稱。不必先有網路驅動，但名稱來源須明確。 |
| `-o` | 若支援 GNU 擴充，可回傳 `ZOS`。它不是 `GNU/Linux`。 |
| `-p`、`-i` | 可以先不支援。若採 GNU 語意，可在缺少資料時回傳 `unknown`。 |
| `-a` | 等欄位與輸出順序明確後再加入。不要將任意系統摘要稱為 GNU `uname -a`。 |

## 第一版指令解析與契約

現有 shell 只比較整條輸入是否等於 `clear`。
加入 `echo`、`uname -m` 或 `sleep N` 前，必須先定義指令名稱與參數的邊界。
至少要規定前後空白、空參數、額外參數、數字範圍及不支援選項的錯誤。
指令名稱比較必須完整，不能把 `echoes` 誤判成 `echo`。
引號、變數展開、pipe 與重導向可以延後，但應明示限制。
[目前的整行比較與輸入處理](../kernel/shell.zc)

既有指令 buffer 是全域的 4096-byte 陣列，可保存最多 4095 個字元。
Shell task 的 stack 只有 4 KiB，參數解析不宜另建同尺寸的 stack 區域複本。
字元輸出與診斷仍在 task context 執行，IRQ 維持輸入與通知責任。
[Shell buffer](../kernel/shell.zc)、[Task stack](../kernel/task.zc)、[IRQ 邊界測試](../tests/shell_task_static.sh)

目前 [shell-contract.md](shell-contract.md) 明定只有 `clear`。
它也明定 `help`、`about` 與 `ticks` 必須回報 unknown command。
[tests/shell_static.sh](../tests/shell_static.sh) 包含對應的靜態檢查與命令行為預期。
未來加入指令時，須同步修改契約與回歸預期。
這些限制是目前功能範圍，並非禁止日後擴充。

## 尚未定案的事項

- `uname` 的 release、build version 與 nodename metadata 來源尚未定義。
- `uptime` 第一版要採簡化預設輸出，或支援 `-p`，尚未定案。
- 長期運作時間如何跨越 `u32` tick 回繞，尚未定案。
- task snapshot 的公開介面、task 名稱與 state 欄位格式尚未定義。
- `history` 的命令數、總位元組上限，以及是否記錄 `history` 本身，尚未定案。
- shell 結束、重啟與返回狀態的政策尚未定義。

部分 POSIX 頁面於調查時回傳 HTTP 403。
`echo`、`pwd` 與 `cd` 的主要語意使用官方搜尋內容確認。
它們的連結分別指向官方 Issue 7 與 Issue 6 文件。
本文件沒有以這些舊版頁面宣稱 ZOS 符合 POSIX.1-2024。
