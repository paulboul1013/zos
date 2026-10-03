# Task 生命週期設計

狀態：已實作並通過驗收。使用者確認 Q1–Q14 的完整契約，包含 Q6 的永久停用政策與 Q4 的容量例外。
實作、測試與 subagent 審查結果見[驗證紀錄](task-lifecycle-results.md)。

背景與目前行為見[背景筆記](task-lifecycle-background.md)。領域用語見[詞彙表](../CONTEXT.md)。

## 第一輪已確認的決定

| 題目 | 已確認的契約 |
| --- | --- |
| Q1：回收責任 | 核心確認 stack 可安全重用後自動回收。公開 join、退出碼與父子關係另行設計。 |
| Q2：識別範圍 | Task ID 識別一次 task 生命週期，採 slot 加 generation。查詢拒絕舊 Task ID。 |
| Q3：計數 | `task_count()` 保留包含 boot task 的累計成功建立數。新增 `task_live_count()`，包含 boot task、`READY`、`RUNNING` 與 `BLOCKED`，排除 `TERMINATED`。 |

回收與識別的取捨記錄於 [ADR 0001](adr/0001-generational-task-reclamation.md)。

## 第二輪已確認的決定

| 題目 | 已確認的契約 |
| --- | --- |
| Q4：容量可用時機 | 下一個 task 開始或恢復執行時，剛退出 task 的 slot 必須已可重用。首次啟動的新 task 立即建立另一個 task，也必須能使用剛釋出的容量。Q6 方案的例外是世代用盡後停用該 slot。 |
| Q5：失效與公開查詢 | 回收後不保留終止記錄。`task_state()` 對過期、無效或已回收的 ID 統一回傳 `TASK_INVALID_STATE = 0xFF`。保留既有狀態數值。`task_current()` 回傳完整 Task ID。 |
| Q7：初始化與呼叫 context | `task_init()` 每次開機只初始化一次，後續呼叫直接返回。`task_create()` 只允許一般 task context，從 IRQ 呼叫時回傳 `TASK_INVALID_ID`。查詢與 `task_wake()` 仍可從 IRQ 呼叫。 |
| Q8：stack 借用責任 | Entry 返回前，所有外部使用者必須停止存取其 stack 資料。本里程碑不加入引用計數或資源登記機制。 |
| Q9：stack 清理 | 重建必要的初始 frame，清理生命週期 metadata。本里程碑不保證整個 4 KiB stack 為零。新 task 必須初始化自己使用的資料。 |

## 第三輪已確認的決定

| 題目 | 已確認的契約 |
| --- | --- |
| Q10：slot 選擇與建立失敗 | 選編號最小的可用 slot，排除 slot 0。失敗回傳 `TASK_INVALID_ID`，不增加累計數或存活數、不消耗額外 generation，也不留下半初始化的 slot。 |
| Q11：查詢一致性 | 每次查詢各自取得一致結果，連續查詢不保證代表同一瞬間。未初始化時，`task_current()` 回傳 `TASK_INVALID_ID`，`task_state()` 回傳 `TASK_INVALID_STATE`，兩種 count 都回傳 0。查詢保留原先的 IRQ 狀態。 |
| Q12：退出契約錯誤 | Boot task 被終止，或退出時找不到可執行 fallback，視為核心契約錯誤。輸出一次可辨識的診斷，關閉 IRQ，永久停止核心。容量不足等正常建立失敗仍使用 API 錯誤回傳。 |
| Q13：測試 counters | 成功建立新 task 時，將該 slot 的 dispatch、block 與 wake counters 歸零，表示該次生命週期的活動。Boot counters 持續累計。跨生命週期的驗收進度由 fixture 另外記錄。 |
| Q14：驗收門檻 | 採用下列生命週期、回歸與建置組合驗收。 |

## Q6：世代編碼與用盡方案

採用以下世代編碼、不循環與永久停用政策。
[Linux 調查](linux-task-identity-research.md)記錄參考差異，[ADR 0002](adr/0002-task-id-exhaustion.md)記錄此方案的取捨。

| 項目 | 方案 |
| --- | --- |
| 公開型別 | Task ID 維持 `u32`。 |
| 編碼 | `id = (generation << 2) \| slot`。低 2 位表示 slot，高 30 位表示 generation。 |
| 第一次配置 | 工作 slot 的 generation 從 0 開始，首次 ID 為 1、2、3。 |
| Boot 身分 | Boot ID 固定為 0。Slot 0 的其他 generation 編碼均無效。 |
| 有效世代 | 工作 slot 接受 0 至 `0x3FFFFFFE`。`0x3FFFFFFF` 保留，不配置。 |
| 錯誤 ID | `TASK_INVALID_ID` 保持 `0xFFFFFFFF`。保留世代的所有編碼均不能識別 task。 |
| 世代推進 | 舊 task 回收時，先使其 ID 失效，再準備下一世代。建立失敗不再消耗額外世代。 |
| 用盡 | 最後有效世代的 task 可以正常執行。回收後停用該 slot，後續建立跳過它，generation 不循環。 |
| 容量例外 | Q4 的立即可用保證適用於尚有可用世代的 slot。世代用盡的 slot 清理後保持停用。 |

每個工作 slot 可成功建立 `0x3FFFFFFF`，即 1,073,741,823 次 task。
三格加上 boot task 的累計上限為 3,221,225,470，小於 `u32` 上限 4,294,967,295。
因此 `task_count()` 可以維持 `u32` 與精確累計，不需要循環或飽和計數。
這個上限依賴固定三格工作容量、一次初始化，以及世代不循環的方案。

## 公開 API 與容量界線

新增 `task_live_count() -> u32` 與 `TASK_INVALID_STATE: u8 = 0xFF`。
`task_create()`、`task_current()` 與 `task_state()` 使用完整 Task ID，內部排程仍使用 slot 索引。
查詢必須檢查初始化、編碼、世代，以及該 slot 是否仍保有對應 task 的記錄。
`UNUSED` 與停用 slot 不具有有效 Task ID。`TERMINATED` 只在回收交接中保留，不承諾呼叫者一定能觀察到它。

維持四格 task table、三個靜態 4 KiB stack，以及 boot 的特殊 stack。
維持單 CPU、Ring 0、協作式切換與既有 IRQ／鍵盤／shell 行為。
公開 join、退出碼、父子關係、動態 stack、SMP 與搶佔式排程另行設計。
`task_create()` 允許一般 task context 原先 IF 為 0 或 1，完成或失敗後恢復原 IF。

## 已確認的最低驗收門檻

1. 連續建立、執行、退出至少 100 個短 task，強迫同格重用。
2. 驗證 A 退出後，首次啟動的 B 能立即使用釋出的容量。
3. 驗證舊 continuation 不再返回，舊 ID 被拒絕，建立失敗不改變計數。
4. 混合 yield、block／wake。新 task 不繼承舊 wait channel，shell 與 timer 維持正常。
5. 主機測試涵蓋 `-O0`、`-O2`。QEMU 涵蓋兩種最佳化與 direct／ISO 四種組合。
6. 完成 `make test`，另外執行 QEMU 驗收，保存事件紀錄與結果。

Q6 方案的邊界驗收直接設定測試 fixture，不以實際建立十億次 task 取代邊界檢查：

1. 最後有效世代仍能建立與執行，產生的 ID 不等於 `TASK_INVALID_ID`。
2. 回收最後世代後，該 slot 保持停用。建立會選其他可用 slot，或正常回傳建立失敗。
3. 舊 ID 在回收後及同格重用後均被拒絕，最後世代不循環回 0。
4. 保留世代與 slot 0 的非零世代編碼均被拒絕。
5. 最後一次合法建立與後續失敗的計數保持精確，不超出上述上限。
6. 重複初始化不重設世代、狀態或計數。IRQ context 建立失敗保留原 IF 與 table。

## 回收交接的實作安排

建議在組語載入新 ESP 後、還原 EFLAGS 前執行共同回收程序。
此位置可以涵蓋首次啟動與既有 continuation，並在 IRQ 恢復前完成 metadata 更新。
呼叫 C helper 時，必須維持 i686 ABI 的 stack 對齊，並完整保留待還原的 frame。
Q4 已確認容量可用期限。共同 helper 的名稱、傳參方式與組語對齊由實作處理，並以物件檢查及真實 stack 測試驗證。
回收時清除 saved ESP 與 wait channel，保留世代及停用判斷所需資料。
CPU 離開舊 stack 前，維持 IRQ 關閉，並將該 slot 排除於配置者可用集合。

## 設計與實作狀態

本文是已確認的生命週期實作契約。
核心、真實主機 stack、i686 物件與 QEMU 四種組合均完成驗收，`make test` 通過。
執行期證據與限制見[驗證紀錄](task-lifecycle-results.md)。

## 實作前已核對的程式碼相依

以下記錄實作前的狀態。相關相依已依本契約調整，作為實作範圍的歷史紀錄。

- [切換程序](../arch/i686/tasks.S)先保存舊 ESP，再載入新 ESP，之後還原 EFLAGS。
- [新 task 的初始 frame](../arch/i686/tasks.S)直接進入 entry。首次啟動不會返回先前的 C 切換呼叫。
- [鍵盤阻塞讀取](../kernel/keyboard.zc)目前要求 `task_current()` 小於 4。採世代 Task ID 後，必須調整這個 slot 假設。
- [Task 查詢](../kernel/task.zc)目前以 `UNUSED` 同時表示未使用 slot 與超出範圍的 ID。
- [Task 建立](../kernel/task.zc)目前保護 IRQ 狀態，但沒有拒絕 IRQ context 的檢查。
- 現有[主機 fixture](../tests/event_wait_host.c)以配置次數選擇 context，[QEMU 驗收](../tests/event_wait_qemu.py)則期待終止記錄保留。兩者需依新契約調整。
- 測試建置的 dispatch、block 與 wake counters 依 slot 累計，目前建立與初始化不會清除。
- [主機事件等待測試](../tests/event_wait_static.sh)使用真正的主機 stack，涵蓋 `-O0` 與 `-O2`，但不執行 i686 切換組語。
- [事件等待 QEMU 工具](../tests/event_wait_qemu.py)支援 `-O0`／`-O2` 與 direct／ISO 四種組合。`make test` 不包含 `test-event-wait-qemu`，必須另行執行。
- 現有 `zos_cpu_safe_halt()` 供 idle 等待 IRQ，會開啟 IRQ 並可能返回。目前沒有整合診斷輸出與永久停止的核心 helper。
