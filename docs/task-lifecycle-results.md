# Task 生命週期實作與驗證結果

驗證日期：2026-10-03。契約見[實作計畫](task-lifecycle-plan.md)。

## 實作結果

工作 slot 在 task entry 返回後自動回收。退出時 IRQ 保持關閉，slot 暫時保留 `TERMINATED`。
組語載入新 ESP 後，在對齊的 C 呼叫區域執行 `_task_reap_switched()`，再還原 frame 與 EFLAGS。
因此首次啟動的新 task 與既有 continuation 都能立即使用釋出的容量。

公開 Task ID 採 `(generation << 2) | slot`，內部排程使用 slot 索引。
回收清除 saved ESP 與 wait channel，並推進 generation。最後有效世代回收後，slot 永久停用。
`task_state()` 拒絕過期、保留編碼與無效 ID，回傳 `0xFF`。

`task_count()` 保留成功建立的累計數。`task_live_count()` 計算存活 task，兩者包含 boot task。
查詢各自保存並恢復 IF。重複 `task_init()` 不修改既有生命週期。
`task_create()` 拒絕 IRQ context。建立失敗不修改計數、generation 或 slot metadata。
成功建立會重設該 slot 的 dispatch、block 與 wake counters。

Boot task 退出或退出時沒有 READY fallback，核心只輸出一次診斷，再執行關閉 IRQ 的永久 halt loop。
Keyboard 阻塞讀取使用完整 Task ID，已移除 ID 必須小於 4 的假設。

## 主機與物件驗證

`make test` 通過，包括既有開機、ISO、console、interrupt、timer、keyboard、shell 與事件等待回歸。
完整輸出保存在 `build/task-lifecycle/make-test.log`。

`tests/task_lifecycle_host.c` 連結轉譯後的 production task 與 keyboard 模組。
每個 task 使用真正的主機 stack，測試在 `-O0` 與 `-O2` 均通過：

- 連續建立、yield、返回及回收 100 個 task，同格 ID 依世代改變，舊 ID 持續失效。
- 填滿三個工作 slot。A 返回後，首次啟動的 B 立即在 A 的 slot 建立新 task。
- 重用 task 的鍵盤讀取成功，wait channel 不繼承，生命週期 counters 歸零。
- 混合 yield、block 與 wake，恢復後保留區域資料與 IF。舊 channel 不會喚醒新 task。
- 未初始化查詢、null entry、stack 準備失敗、容量不足與 IRQ context 建立失敗均符合契約。
- IF=0 與 IF=1 的建立、查詢及初始化保留原 IF。重複初始化保留 table 與 counters。
- 最後有效世代可執行，回收後永久停用。配置跳過停用 slot，且拒絕保留世代與 slot 0 的非零世代。
- 最後三次合法建立使累計數精確到 `0xBFFFFFFE`，即 3,221,225,470。後續失敗不增加計數。
- Boot 退出與沒有 fallback 的退出都只診斷一次，且進入 IF=0 的永久停止 helper。

`tests/task_lifecycle_static.sh` 另檢查 i686 物件。
回收 helper 的呼叫位於載入新 ESP 之後、`popal`／`popfl` 之前，呼叫區域對齊 16 bytes。
永久停止 helper 的指令為 `cli`、`hlt`、跳回 `hlt`。

## QEMU 驗收

以下組合均通過正常流程與兩種致命退出，共 12 個案例：

| 開機方式 | 最佳化 | 正常流程 | Boot 退出 | 沒有 fallback |
| --- | --- | --- | --- | --- |
| direct | `-O0` | PASS | PASS | PASS |
| direct | `-O2` | PASS | PASS | PASS |
| ISO | `-O0` | PASS | PASS | PASS |
| ISO | `-O2` | PASS | PASS | PASS |

每組正常流程完成 100 個短 task，各自執行 yield、真實 i686 block／wake 與返回。
組語 probe 檢查 ESP、EBX、ESI、EDI、EBP 與 IF，task 另檢查 stack 區域資料。
首次啟動容量交接、最後世代停用、真實 PIT IRQ 中建立失敗與重複初始化也通過。

每組生命週期 snapshot 的結果相同：

| 欄位 | 結果 |
| --- | --- |
| `lifecycle_progress` | 100 |
| `lifecycle_handoff_count` | 743 |
| `lifecycle_handoff_error` | 0 |
| `lifecycle_error` | 0 |
| 容量、IRQ、世代邊界結果 | 全部為 1 |
| 累計／存活 task 數 | 109／2 |

743 次交接都在選定的新 stack 上執行 helper，呼叫入口符合 i686 ABI 對齊，且 IF=0。
存活的兩個 task 是 boot 與常駐 shell。
後續 100 輪 PS/2 輸入、Backspace、未知指令、`clear`、VGA 與 PIT 回歸均通過。
沒有鍵盤輸入的 100 個 PIT ticks 期間，shell dispatch counter 不增加。

兩種致命退出各只出現一次指定診斷。兩次相隔 0.1 秒的觀察皆為 IF=0、HLT=1。
觀察間 QEMU 持續執行，PIT 與 interrupt counters 保持相同，未以暫停 VM 代替停止驗證。

## 重現與紀錄

```sh
make test
make test-task-lifecycle-qemu TASK_LIFECYCLE_OPT=-O0 TASK_LIFECYCLE_BOOT=direct
make test-task-lifecycle-qemu TASK_LIFECYCLE_OPT=-O0 TASK_LIFECYCLE_BOOT=iso
make test-task-lifecycle-qemu TASK_LIFECYCLE_OPT=-O2 TASK_LIFECYCLE_BOOT=direct
make test-task-lifecycle-qemu TASK_LIFECYCLE_OPT=-O2 TASK_LIFECYCLE_BOOT=iso
```

每組紀錄位於 `build/task-lifecycle/{boot}-{optimization}/`：

- `results.json`、`result.json`：案例結果。
- `lifecycle-snapshot.json`、`final-snapshot.json`：生命週期與回歸結果。
- `events.json`、`qemu.log`：事件與 serial 紀錄。
- `clear.ppm`、`unknown-command.ppm`、`vga.txt`：畫面證據。
- `panic-1/`、`panic-2/`：致命退出診斷、registers 與兩次 counters snapshot。

`build/` 由 `.gitignore` 排除，本文件保留驗證摘要。
ISO 工具先等待核心的 `shell task: running` 標記，再讀取 globals，避免使用 GRUB 尚未釋放的記憶體內容。

## 審查與範圍

Subagent 審查核心、組語、測試與物件交接，另一位 subagent 獨立審查完整契約與測試。
審查發現的必要 `Path` 匯入缺漏已修正，最終四種組合均重新通過。

維持四格 table、三個 4 KiB 靜態 stack、單 CPU、Ring 0 與協作式排程。
Entry 返回前，外部使用者必須停止借用 stack。新 task 必須初始化自己的資料。
本次實作不加入 join、退出碼、父子關係、整個 stack 清零、動態 stack、SMP 或搶佔式排程。
