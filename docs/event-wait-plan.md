# ZOS 事件等待／喚醒計畫：概念、架構與驗收

版本：第一版，2026-10-02。依據協作式 task、keyboard queue 與 shell 實作。
本文件保留設計與驗收要求；實作與逐項驗證結果見 [事件等待驗證紀錄](event-wait-results.md)。

## 1. 我們要得到甚麼行為

**讓 shell 沒有輸入時安心等待，有輸入時繼續處理。**

使用者仍然看見 `zos> `、輸入回顯、Backspace、Enter、`clear` 和未知指令提示。
改變的是核心內部：沒有字元可讀時，shell 會離開可執行名單；鍵盤收到字元後，再把它放回名單。
其他有工作的 task 可以繼續執行，全部工作都在等待時由 idle 使用 `hlt`。

這版採用以下範圍：

- 單 CPU、i686、Ring 0，沿用 4 個 task slot 和各新建 task 的 4 KiB 靜態 stack。
- 排程仍是協作式；第一個等待事件是「keyboard queue 有字元」。
- 沿用 64-byte keyboard queue，實際最多保存 63 個字元，以及現有 overflow 政策。
- PIT 保持約 100 Hz。計時中斷仍會喚醒 idle，但不應每次都讓沒有輸入的 shell 執行。
- Timer deadline sleep、task slot 回收、搶佔式排程、paging、Ring 3 留給各自的後續里程碑。

因此這版的收益是減少空 queue 檢查與無效切換，並建立可供其他裝置重用的等待機制。
不把「CPU 不再收到任何中斷」當成完成條件。

現況依據：[shell](../kernel/shell.zc)、[task](../kernel/task.zc)、[keyboard](../kernel/keyboard.zc)、[boot idle](../kernel/kernel.zc)。

## 2. 先理解五個概念

可以把 task 想成櫃台人員：手上有資料就處理，沒有資料就登記等待，有新資料時再通知他回來。
登記等待後，他的工作進度、變數和 stack 都保留，之後從原本停下來的地方繼續。

| 名詞 | 在這份計畫中的意思 |
|---|---|
| `RUNNING` | 這個 task 正在使用 CPU |
| `READY` | 這個 task 可以執行，正在等排程器選它 |
| `BLOCKED` | 這個 task 正在等特定事件，排程器暫時跳過它 |
| queue | 真正保存輸入字元的信箱 |
| wait channel | 登記「我在等甚麼」的事件代號，例如鍵盤輸入 |

**資料放在 queue，通知改變 task 狀態。** 通知本身不保存字元，也不保證喚醒後一定還有資料。
因此 task 醒來後要重新檢查 queue；即使被多通知一次，也不能讀出假資料。

`yield` 只讓出這一輪 CPU，task 仍可在下一輪被選中。`block` 則會等到有人通知，才重新加入可執行名單。
喚醒表示 `BLOCKED → READY`；接著由排程器完成 `READY → RUNNING`。
正在執行的其他 task 仍需主動讓出 CPU，這版沒有時間片強制切換。

```text
[READY] -- scheduler --> [RUNNING] -- yield --> [READY]
                            |
                            +-- wait --> [BLOCKED] -- wake --> [READY]
                            |
                            +-- return --> [TERMINATED]
```

這是條件等待的通用模型；MIT xv6 的 sleep/wakeup 也強調條件重查與避免漏喚醒。
[MIT xv6：Sleep and Wakeup](https://mit-pdos.github.io/xv6-riscv-book/sleep.html)

## 3. 哪一個模組負責甚麼

IRQ 路徑：先加入字元，再通知等待者，最後返回被中斷的 task。

```text
          [Key press]
               |
               v
    [IRQ1: decode scancode]
               |
               v
    [Character enqueued?] -- no ----------------+
               |                                |
              yes                               |
               v                                |
    [Wake keyboard channel]                     |
               |                                |
               v                                |
[Matching BLOCKED tasks -> READY]               |
               |                                |
               +--------------------------------+
               |
               v
    [Send EOI once + IRQ return]
               |
               v
    [Resume interrupted task]
```

一般 task context 的排程與讀取路徑；`(A)`、`(B)` 表示回到同名節點。

```text
(A) [Scheduler selects a READY task]
                 |
                 +-- shell --> (B) [Blocking read: recheck queue]
                 |                            |
                 |                            +-- data --> [shell_feed_char()] --> (B)
                 |                            |
                 |                            +-- empty --> [Block + switch] --> (A)
                 |
                 +-- other work --> [Run until yield / exit] --> (A)
                 |
                 +-- only idle --> [task_idle: safe wait for IRQ] --> (A)
```

| 模組 | 要負責的事 |
|---|---|
| `kernel/task.zc` | 增加 `BLOCKED` 和每個 task 的 wait channel；管理 block/wake、選擇 READY task、idle 判斷 |
| `kernel/keyboard.zc` | 提供阻塞讀取；協調 queue 檢查與等待登記；收到字元後通知 channel |
| `kernel/shell.zc` | 使用阻塞讀取取得字元，再呼叫既有 `shell_feed_char()` |
| `kernel/kernel.zc` | 建立 shell，讓 boot task 0 執行新的 idle 流程 |
| `kernel/interrupts.zc`、`arch/i686/interrupts.S` | 提供保存／恢復 IRQ 狀態和安全 halt 的架構介面 |
| `arch/i686/tasks.S` | 沿用 stack switch；確認保存與還原 EFLAGS 的行為符合等待流程 |

IRQ1 每次仍只讀取一個 scancode、更新 queue／通知等待者、送一次 EOI。
它不執行 shell 指令、不寫 VGA，也不直接切換 task。
是否成功加入 queue 必須能被 producer 判斷：只有有可消費資料時才需通知；Shift 和 break code 不新增字元。
Queue 已滿時維持丟棄新字元與增加 dropped counter 的政策，既有字元與 FIFO 順序不受破壞。

只需在 4 個 task slot 上掃描相同的事件代號，第一版不需要動態 linked list 或 heap 配置的 wait queue。
排程器只比較代號，鍵盤模組自己擁有鍵盤事件代號；shell 不需要知道其值。

## 4. 兩個必須處理的交接問題

### 4.1 檢查 queue 與登記等待之間，不能漏掉通知

以下是新等待功能如果寫得不完整，可能出現的順序：

```text
Time     Shell task                      Keyboard IRQ1
 |       ----------                      -------------
 |       Check queue: empty
 |                                       Enqueue 'a'
 |                                       Wake channel: no waiter
 |       Register channel
 |       Set state: BLOCKED
 v       (no further key press)

Result: queue = ['a'], shell = BLOCKED
```

這叫 lost wakeup，也就是「資料到了，通知卻在登記等待之前用掉了」。
這不是對現有輪詢實作的 bug 判定，而是新增阻塞機制必須防止的情況。

第一版利用單 CPU 的特性，暫時遮罩可遮罩 IRQ，把下列交接保護起來：

```text
(A) [Save IRQ flags + disable IRQ]
                  |
                  v
          [Queue has a char?]
                  |
                  +-- yes --> [Dequeue] --> [Restore flags] --> [Return char]
                  |
                  +-- no --> [Register channel + BLOCKED]
                                          |
                                          v
                             [Switch to another READY task]
                                          |
                                          v
                             [Next task uses its own EFLAGS]
                                          |
                             (wake + schedule waiting task)
                                          |
                                          v
                             [Resume with saved IF = 0]
                                          |
                                          v
                             [Restore original IRQ flags]
                                          |
                                          +--> (A)
```

IRQ 暫停期間，硬體事件可以成為 pending；恢復後才交給 handler。
這不是停止鍵盤。保護期間保持短小，不在裡面執行 shell 指令或 VGA 輸出。

Block 時保存的原 task context 會帶著關閉的 IF。另一個 task 使用自己的 EFLAGS 繼續執行；
當等待者日後恢復時，先返回原本的保護區，再恢復進入讀取前的 IRQ 狀態，然後重查條件。
不能因為某個 task 等待，就讓整個 CPU 從此無法接收 IRQ。

IRQ helpers 必須保留原狀態：原本關閉就維持關閉，不能一律用 `sti` 收尾。
編譯器也必須知道這些交接會讀寫共享記憶體，避免把 queue 或 task 狀態的讀寫移到保護區外。
實作時檢查生成 C 的外部呼叫／compiler barrier，並在最佳化建置下驗證。

### 4.2 決定閒置與進入 `hlt` 之間，不能遺漏已就緒的工作

Idle 也有同類交接：剛判斷沒有 READY task，IRQ 就把 shell 喚醒，隨後 idle 卻去 `hlt`。
第一版的 boot task 0 永遠作為 fallback，流程如下：

```text
(A) [Disable IRQ + check other READY tasks]
                       |
                       +-- found --> [Switch to READY task]
                       |                       |
                       |                       v
                       |                [Idle resumes]
                       |                       |
                       |                       +--> (A)
                       |
                       +-- none --> [Adjacent asm: sti; hlt]
                                               |
                                               v
                                    [IRQ runs + returns]
                                               |
                                               +--> (A)
```

`(A)` 代表重新暫停 IRQ 並檢查 READY task；idle 恢復或 IRQ 返回後，都回到這一步。

`sti` 與 `hlt` 必須在同一段 assembly 裡相鄰，不能分成兩個普通函式呼叫。
Linux 的 x86 `native_safe_halt` 使用這個模式，可作為架構實作的參考。
[Linux x86 IRQ flags / safe halt](https://github.com/torvalds/linux/blob/master/arch/x86/include/asm/irqflags.h)

## 5. 介面草案與一定要成立的規則

以下名稱作為實作起點，與現有 `task_`、`keyboard_`、`zos_` 前綴一致。

| 擬定介面 | 呼叫者與約定 |
|---|---|
| `zos_irq_save() -> u32` | 保存 flags 並暫停 IRQ，回傳稍後恢復用的值 |
| `zos_irq_restore(flags: u32)` | 恢復原先的 IF，不擅自開啟原本關閉的 IRQ |
| `task_block_on_locked(channel: u32) -> bool` | 只供一般非 idle task 在 IRQ 已暫停時呼叫；成功時等到被重新排程才返回；無效條件返回 false，不改 task 狀態 |
| `task_wake(channel: u32) -> u32` | 可從 IRQ 或一般 task 呼叫；只將符合 channel 的 BLOCKED task 改為 READY，返回本次喚醒數量 |
| `task_idle()` | 只由 boot task 0 呼叫；執行上節的 ready-check／switch／safe-halt 流程 |
| `keyboard_read_blocking() -> u8` | 由已初始化、IRQ 已啟用的 shell task 呼叫；有資料立即返回，沒有資料等待；正常成功返回非零 ASCII |

`task_block_on_locked` 的有效條件是 scheduler 已初始化、channel 非零、目前是 task 1–3 的 RUNNING context，且 IRQ 已暫停。
它不可從 IRQ handler 呼叫，必須能選到其他 READY task；boot fallback 的存在保證正常路徑符合這個條件。
拒絕呼叫是契約錯誤，不當成「暫時沒有輸入」反覆重試。
`keyboard_read_blocking` 的這種錯誤路徑回傳 0，shell 應輸出一次 task-context 診斷並返回，讓現有 task-exit 流程接手。
正常路徑中的喚醒後 queue 仍空則繼續等待，不回傳 0。

`task_wake` 自己保存／恢復 IRQ 狀態，保護 channel 掃描與狀態更新；從 IRQ 呼叫時恢復為 IF=0，再由 `iret` 還原被中斷的 context。
`task_idle` 的前置條件是 scheduler 已初始化、目前為 task 0，且呼叫前 IRQ 已啟用。
`task_init/create/yield/exit` 的共享狀態交接也要一起檢查與保護，避免新 wakeup path 看見半完成的 scheduler 更新。

Shell 的正常路徑可讀成這樣；實作另包含錯誤診斷：

```zc
fn shell_task() {
    shell_init();
    while true {
        let ch: u8 = keyboard_read_blocking();
        if ch == (u8)0 {
            // 契約錯誤：在一般 task context 記錄診斷後退出。
            return;
        }
        shell_feed_char(ch);
    }
}
```

以下規則是驗收時的共同判準：

1. Scheduler 只選 READY task；BLOCKED／TERMINATED task 不被選中。
2. 每個 BLOCKED task 有一個非零 wait channel；喚醒時清除它，重複通知不重複加入 READY。
3. 正常 task context 的可觀察交接點，恰有一個 RUNNING task，且符合 current task ID。
4. Task 0 不 block，常駐作為 idle fallback；只有沒有其他 READY task 時才 halt。
5. 檢查 queue 和登記等待共用 IRQ 保護；通知方先更新 queue，再 wake。
6. Wake 不等於 context switch；IRQ 路徑只更新狀態，EOI 每個 IRQ 恰好一次。
7. 保存的 stack 和 IRQ 狀態能在恢復後延續；IRQ0 持續正常計時。
8. 等待恢復後重新檢查條件，空通知或重複通知不能產生假字元。

原有狀態的數值保持相容，新增 `TASK_BLOCKED` 使用新的值；channel 0 保留為「沒有等待」。
不同 channel 不互相通知。核心 primitive 可喚醒同 channel 的所有等待者，但本里程碑的鍵盤仍只有 shell 一個 consumer。

## 6. 功能完整要用哪些證據驗證

「可以開機」只能證明啟動路徑；「按一次鍵有回應」只能證明一種事件順序。
完整驗收要對應上述規則，在本里程碑範圍內，同時驗證安全性、進度與既有行為。

### 6.1 主機上的邏輯測試：把容易漏掉的順序固定下來

沿用 repo 的做法：`zc transpile --freestanding` 後，以主機 GCC 和 I/O／context-switch stub 驗證 production 模組。
測試必須直接使用實作，另寫的參考狀態模型只用來比較結果，不能成為唯一被測的程式。

| 情境 | 必須看到的結果 |
|---|---|
| Queue 已有字元 | 立即按 FIFO 返回，沒有 block 或額外切換 |
| Queue 空 | 記錄 channel、變 BLOCKED、切到其他 READY task |
| 正確 channel 的事件 | BLOCKED 變 READY；之後排程才變 RUNNING |
| 不同 channel、channel 0 | 不喚醒該等待者，不改錯誤 task 的狀態 |
| 同 channel 有多個等待者 | 全部符合者變 READY；回傳喚醒數量正確 |
| 重複 wake，或 task 已 READY／TERMINATED | 不重複切換、不復活已退出 task |
| 醒來後 queue 仍空 | 重新等待，不生成假字元 |
| 所有工作 task 都 BLOCKED | Task 0 仍可執行，沒有選回 BLOCKED task |
| 有其他 READY 工作 | Idle 不 halt，Round-Robin 繼續推進 |
| 原 IF 為 0 或 1、巢狀保存／恢復 | 回到原 IF；內層 restore 不提前開 IRQ |
| 無效 block 前置條件 | 明確拒絕，task table 和 channel 不受部分更新 |
| Queue 滿載／wrap／Shift／break | FIFO、drop counter 和每次 IRQ 的 EOI 維持正確 |

Lost-wakeup 測試會刻意安排事件在：檢查前、檢查與登記交接期間、已切到其他 task 後、醒來準備重查時。
在模擬 IF=0 的區間，只把 IRQ 設為 pending，不能假裝硬體 handler 可以直接插入。
每個關鍵案例只送一個字元，之後不再送鍵盤事件；queue 中的字元必須仍能被取出，不能靠第二次按鍵補救。
另測 idle 最後 ready-check 與 halt 的交接，確認 pending IRQ 被交付後重新檢查工作。

主機 stub 需要模擬 producer／idle 的執行和等待者恢復，不能在 current ID 已切到別的 task 時，直接讓原讀取函式照常繼續而宣稱成功。
這層證明的是邏輯與事件交接；真實 ESP、EFLAGS 與硬體中斷留給下一層。

### 6.2 i686 物件檢查：確認真正生成的指令與 ABI

- Cross compile 成 freestanding i686 objects，確認新增 symbols 的名稱、參數與連結一致，沒有引入 hosted runtime。
- 用 objdump 檢查 IRQ flags helper 和相鄰的 `sti; hlt`，以及保存／恢復 context 的相對位置。
- 檢查生成 C 的共享記憶體交接，並重跑 `-O2` 的邏輯與 QEMU 測試，避免測試只在未最佳化時成立。

物件檢查不會單獨證明事件順序正確，需與其他測試的行為證據一起判讀。

### 6.3 QEMU 整合測試：真的 block、真的中斷、真的恢復

新增 Python 標準函式庫的 QMP 測試工具，以 headless QEMU 和暫存 Unix socket 注入真實鍵盤事件。
先用 direct ELF 快速定位，再以 GRUB ISO 驗證正式開機路徑。
用受測 ELF 的 symbols 定位 test-build 的 per-task dispatch/block/wake counter 和 queue 資料，取得狀態快照。
生產版不新增 IRQ 裡的 serial／VGA 日誌；QMP 讀取測試 counters 作為觀察，不把每次中斷都印出來。

| 驗收流程 | 可觀察的通過條件 |
|---|---|
| 開機並不按鍵 | 出現 prompt；shell 進入 BLOCKED；boot idle 與 timer 仍工作 |
| 等待 100 個 PIT tick | Shell dispatch counter 不增加，timer counter 增加 |
| 只按一次 `a`，之後不再按鍵 | IRQ enqueue／wake，shell 取出唯一的 `a`，畫面只回顯一次，然後再次 BLOCKED |
| 重複等待／按鍵 100 輪 | 每輪資料都被處理，沒有卡住、重複字元或等待狀態殘留 |
| 輸入 Enter、Backspace、`clear`、未知指令 | prompt、編輯與指令結果維持既有行為；用 VGA 記憶體內容比對，再輔以人工畫面檢查 |
| 另外建立可主動 yield 的工作 task | Shell BLOCKED 時工作 task 的進度增加；有 READY task 時 idle 不先 halt |
| 特製測試入口跨實際 block／wake | Stack 上的局部值、執行位置、必要暫存器及 IF 保持正確；恢復後 timer 還能繼續 |
| `-O2` 版本與 GRUB ISO | 同樣的等待／輸入／恢復流程通過 |

100 輪是第一版的固定回歸門檻，不是所有事件組合的數學證明。
窗口內的精確交錯由主機模型控制；QEMU 證明真實 stack、IRQ 與輸入路徑的整合，人工檢查則確認操作體驗。
驗證發生在單 CPU 和合作讓出的假設下，這份結果不延伸宣稱 SMP 或 preemption 已正確。

### 6.4 既有功能回歸與「完成」定義

現有 task、keyboard queue、shell、console、timer、ABI、direct boot 和 ISO 測試都要繼續通過。
目前 `tests/shell_task_static.sh` 固定搜尋 shell 的 `task_yield` 和 boot 的直接 `hlt`；
切換到封裝介面後須更新這類檢查，以新的 IRQ 邊界和實際行為為判準，不能保留失效文字檢查，也不能刪掉既有行為驗收。
既有 `shell task: running` marker 仍保留其「shell 真正執行過並返回 boot」的意義，新增狀態／輸入證據補足等待驗收。

只有當狀態／交錯測試、cross-object 檢查、direct ELF 和 ISO 的 QEMU 流程、最佳化版本及全部既有回歸都通過，
才將本里程碑標記完成。交付測試摘要、每項驗收的結果與失敗時可重現的 seed／事件序列，以及必要的畫面證據。

## 7. 按依賴順序實作，每一步都可驗證

以下是本次實作的依賴順序。測試 target 與各步驟一同建立，結果記錄於驗證紀錄。

```text
[1. IRQ save/restore + safe halt]
                 |
                 v
[2. BLOCKED/channel + block/wake]
                 |
                 v
[3. Idle ready-check + switch/halt]
                 |
                 v
[4. Blocking keyboard read + enqueue/wake]
                 |
                 v
[5. Shell uses blocking read]
                 |
                 v
[6. QEMU keyboard + context tests]
                 |
                 v
[7. -O2 + ISO + all regressions + docs]
```

| 步驟 | 工作與驗收 | 預計涉及檔案 | 驗證 |
|---|---|---|---|
| 1 | IRQ save/restore 與 safe-halt helpers；原 IF 能恢復，`sti; hlt` 相鄰 | `arch/i686/interrupts.S`、`kernel/interrupts.zc`、新增 `tests/irq_flags_static.sh`、`Makefile` | 新 `make test-irq-flags`；cross-object 檢查；既有 interrupt tests |
| 2 | BLOCKED／channel、block／wake、保護排程狀態切換；其他 task 使用自己的 IF，task 0 可作 fallback | `kernel/task.zc`、`tests/task_static.sh`、新增 `tests/event_wait_static.sh`、`Makefile` | 新 `make test-event-wait`；模型中的狀態、交錯與原 IF 測試 |
| 3 | 新 idle ready-check／switch／safe-halt 流程 | `kernel/task.zc`、`kernel/kernel.zc`、`tests/event_wait_static.sh`、`tests/shell_task_static.sh` | 有 READY 時不 halt；沒有 READY 時走 idle；`make test-task test-shell-task` |
| 4 | Keyboard 阻塞讀取與 IRQ 的 enqueue-then-wake | `kernel/keyboard.zc`、`tests/keyboard_queue_static.sh`、`tests/event_wait_static.sh` | 快速返回、單字元 lost-wakeup、FIFO／overflow／EOI，`make test-keyboard-queue test-event-wait` |
| 5 | Shell 使用新讀取介面，更新 shell harness | `kernel/shell.zc`、`tests/shell_static.sh`、`tests/shell_task_static.sh` | `make test-shell test-shell-task test-task`；prompt／clear／Backspace 等回歸 |
| 6 | 真實鍵盤事件、states/counters 的 QEMU 自動驗收 | 新 `tests/event_wait_qemu.py`、`tests/event_wait_static.sh`、`kernel/task.zc`、`Makefile` | 新 `make test-event-wait-qemu`；必要時以 test-only hooks 建立實際 context 保存測試 |
| 7 | 最佳化版本、ISO、完整回歸與文件一致 | `tests/event_wait_qemu.py`、`Makefile`、`README.md`、`docs/task-contract.md`、`docs/shell-task-contract.md` | `make test`；新 QEMU target 的 `-O2`／ISO 模式；人工 `make qemu` |

第 6 步的 test-only 觀察點按需要加入，若超過上述小範圍，先拆成「觀察資料」與「QMP 驅動」兩步。
它們不成為一般 shell 指令，也不改變 production 的排程政策。

檢查點：完成 1–3 後檢查 IRQ／scheduler 基礎；完成 4–5 後檢查完整輸入路徑；完成 6–7 後對照全部驗收條件。
因共用 task 與 keyboard 的契約，先採順序實作；不把條件檢查、狀態登記與 IRQ 通知拆成互不協調的修改。

## 8. 操作指令與實作邊界

既有基準與回歸指令：

```sh
make check-tools
make test-toolchain
make test
```

本次新增的驗證指令：

```sh
make test-irq-flags
make test-event-wait
make test-event-wait-qemu
make test-event-wait-qemu EVENT_WAIT_OPT=-O2 EVENT_WAIT_BOOT=iso
```

最後的回歸與人工操作：

```sh
make test
make qemu
git diff --check
```

`EVENT_WAIT_OPT`（`-O0`／`-O2`）與 `EVENT_WAIT_BOOT`（`direct`／`iso`）是 QEMU 測試選項。
測試工具自行管理暫存產物、QMP socket、QEMU 啟停與 timeout；timeout 視為失敗，不能只看見開機 marker 就通過。

實作時一定要維持：短小的 IRQ、一次 EOI、非 IRQ 的 shell 執行、獨立 context、已有 queue 與 shell 行為，以及每個交接的可重現測試。
若要更改 task／queue 容量、改成 SMP、從 IRQ 切換 task，或改成搶佔式排程，需另立規格；這版不包含這些設計。
不在 heap 上配置第一版 wait channel／task stack，不以忙迴圈代替等待，也不以第二次按鍵掩蓋漏喚醒。

第一版的 API 與範圍以上述契約為準。實際測試結果與畫面證據另列於
[驗證紀錄](event-wait-results.md)，不以設計描述代替測試結果。
