# ZOS 協作式核心執行緒規格

## 目標

為 i686 核心實作最小且可觀察的 task 抽象。每個新建 task 都是 Ring 0
執行環境，包含 ID、生命週期狀態、已保存的 stack pointer、進入函式，
以及獨立的 4 KiB stack。Task 0 則沿用 `boot.S` 建立的 16 KiB stack。
Task 主動 yield、block、exit 或由 idle 排程時才會切換；PIT IRQ0 仍只作為時脈來源，
不會搶佔正在執行的 task。

Hosted scheduler model 會驗證多 task Round-Robin 與安全退出；實際 QEMU
則由常駐 shell task 初始化後 block 回開機 task，驗證真實 stack switch。

## 技術堆疊

- 使用 Zenc freestanding 模組管理 task 狀態與 Round-Robin 排程策略。
- 使用 i686 GNU assembly 保存與還原暫存器、EFLAGS 和 ESP。
- 使用既有的 Zenc-to-C 與 `i686-elf-gcc` 建置流程。
- 使用 GRUB Multiboot v1 與 QEMU 進行執行期驗證。

本里程碑不包含 paging、Ring 3、system call、FPU/SSE context、動態 stack
或搶佔式排程。

## 指令

```sh
make check-tools
make kernel
make test-task
make test
make qemu
```

## 專案結構

```text
kernel/task.zc          Task table、生命週期與 create/yield/exit 策略
arch/i686/tasks.S       i686 context switch 實作
kernel/kernel.zc        常駐 shell task 建立與 boot idle loop
tests/task_static.sh    ABI、初始 stack frame 與 hosted scheduler 檢查
tests/task_boot_test.sh QEMU 中的 cooperative switch 執行順序檢查
tests/iso_test.sh       QEMU serial 標記驗證
docs/task-contract.md   本規格與實作指南
```

## 公開 API 與程式碼風格

```zc
def TASK_MAX: u32 = 4;
def TASK_STACK_SIZE: u32 = 4096;

fn task_init();
fn task_create(entry: fn*()) -> u32;
fn task_yield();
fn task_block_on_locked(channel: u32) -> bool;
fn task_wake(channel: u32) -> u32;
fn task_idle();
fn task_current() -> u32;
fn task_count() -> u32;
fn task_live_count() -> u32;
fn task_state(id: u32) -> u8;
```

Task slot 0 代表開機執行環境，slot 1 至 3 供 kernel threads 使用。公開
task 函式使用 `task_` 前綴；架構相關輔助函式使用 `_zos_task_`；私有
scheduler 資料使用 `_task_`。

生命週期狀態包含 `UNUSED`、`READY`、`RUNNING`、`TERMINATED` 與 `BLOCKED`。
當進入函式為 null、task table 已滿、slot 世代全部用盡或呼叫來自 IRQ context 時，
`task_create` 會回傳 `TASK_INVALID_ID`。失敗不修改計數、世代或 slot metadata。

Task ID 為 `(generation << 2) | slot`。Boot ID 固定為 0，工作 slot 首次 ID 為 1、2、3。
`task_current()` 回傳完整 ID。未初始化時回傳 `TASK_INVALID_ID`。
`task_state()` 對無效、過期、已回收或停用 slot 的 ID 回傳 `TASK_INVALID_STATE = 0xFF`。
查詢各自保存並恢復 IF。連續查詢不保證代表同一瞬間。
`task_count()` 累計成功建立數；`task_live_count()` 計算 `READY`、`RUNNING` 與 `BLOCKED`。
兩者包含 boot task，未初始化時回傳 0。

## Context switch 約定

`_zos_task_context_switch(old_sp, new_sp)` 使用 i686 cdecl ABI：

1. 將 EFLAGS 與所有通用暫存器推入 stack。
2. 透過 `old_sp` 保存目前的 ESP。
3. 將 `new_sp` 載入 ESP。
4. 對齊 C 呼叫區域，在新 stack 上呼叫 `_task_reap_switched()`。
5. 還原暫存器與 EFLAGS。
6. 返回並繼續執行被恢復的 task。

新 task 的 stack 包含相同格式的已保存 frame，後面接著進入函式位址與
task-exit trampoline。因此進入函式返回時會將 task 標記為已終止，而不會
跳到未定義的位址。

```text
saved ESP -> EDI, ESI, EBP, saved-ESP, EBX, EDX, ECX, EAX
             EFLAGS
             task entry
             task-exit trampoline
```

## 排程策略

- `task_init` 將目前的開機 stack 註冊為 `RUNNING` 狀態的 task 0。後續呼叫直接返回。
- `task_create` 配置編號最小的可用工作 slot，並準備其初始 stack。
- `task_yield` 以循環方式尋找下一個 `READY` task。
- 如果沒有其他可執行的 task，`task_yield` 會直接返回而不切換。
- 除非正在終止或等待事件，否則目前執行中的 task 會在切換前變成 `READY`。
- 已返回的 task 會變成 `TERMINATED`，之後不再被排程。
- CPU 切離終止 task 的 stack 後，核心清除 saved ESP 與 wait channel，再推進 generation。
- 回收在新 task 首次啟動或既有 task 恢復前完成，且 IRQ 仍關閉。
- 最後有效 generation 為 `0x3FFFFFFE`。回收後永久停用該 slot，不循環回 0。
- Boot task 終止或退出時沒有 READY fallback，核心輸出一次診斷，關閉 IRQ 並永久停止。

Entry 返回前，外部使用者必須停止存取該 task 的 stack 資料。
重建只初始化必要的 frame 與 metadata，不保證整個 stack 為零。
新 task 必須初始化自己使用的資料。公開 join、退出碼與父子關係另行設計。

## 測試策略

- RED/GREEN hosted scheduler 測試：使用 context-switch stub 驗證初始化、
  容量、Round-Robin 狀態、無效 ID，以及沒有 ready task 時的行為。
- 真實主機 stack 測試：在 `-O0` 與 `-O2` 驗證重用、ID、計數、容量與退出邊界。
- Cross-object 測試：確認產生的 task 模組是 freestanding i686 程式碼，
  能輸出規格定義的 ABI，且不依賴 hosted runtime。
- Relocatable assembly link：確認 context-switch symbol 與 task 模組一致。
- QEMU 整合測試：serial 輸出包含 `shell task: running`，證明 shell task
  已使用獨立 stack 執行，並成功 block 回 boot task。
- 完整回歸測試：`make test` 必須繼續通過所有既有測試。

## 範圍界線

- 一定要做：保留既有 IDT/PIC/PIT/keyboard 行為；IRQ0 維持非搶佔式；
  使用 object 與 QEMU 測試驗證 stack-frame offset。
- 需要先詢問：變更 task 數量、stack 大小，或加入搶佔式排程。
- 絕對不做：從 bump heap 配置 task stack、切換 privilege ring、啟用
  paging，或在此階段於 PIT handler 內執行 scheduler policy。

## 實作計畫與任務

- [x] 新增會失敗的 task ABI、scheduler model 與 context-frame 測試。
  - 驗收：因 task 原始碼與 switch symbol 尚不存在，測試必須失敗。
  - 驗證：`./tests/task_static.sh` 以非零狀態結束。
- [x] 新增 `kernel/task.zc`，包含靜態 task table 與協作式排程策略。
  - 驗收：hosted 狀態測試與 i686 object 檢查通過。
  - 驗證：`./tests/task_static.sh`。
- [x] 新增 `arch/i686/tasks.S` 與初始 stack 建構邏輯。
  - 驗收：新 task 能進入指定函式，並在返回時進入 task exit。
  - 驗證：relocatable link 與 QEMU 標記。
- [x] 將常駐 shell task 整合至開機與建置 target。
  - 驗收：shell task 使用獨立 stack 初始化並 block，且開機 task 繼續存活。
  - 驗證：`make test`。
- [x] 更新 README，說明協作式排程行為與限制。
  - 驗收：文件內容與實際公開 API 一致。
  - 驗證：`git diff --check`。

## 成功條件

- Task 0 是開機執行環境；shell task 使用獨立的 4 KiB stack 執行。
- Serial 的 `shell task: running` 證明 shell 已 block 回開機 task。
- Hosted model 驗證多 task Round-Robin、容量與生命週期狀態。
- Task switch 只發生在一般 task context；IRQ wake 只更新 READY 狀態。
- 既有 keyboard、shell、timer、VGA、ISO 與 direct-boot 測試全部通過。

## 待確認問題

本里程碑沒有待確認問題。搶佔式排程、動態 wait queue 與
user mode 留待後續設計。Task slot 重複使用的契約見 `docs/task-lifecycle-plan.md`。
Shell 移出 IRQ context 的已完成設計與驗證
記錄在 `docs/shell-task-contract.md`。

## 事件等待契約

既有狀態值 0–3 保持不變，`TASK_BLOCKED = 4`。Channel 0 表示沒有等待。
`task_block_on_locked` 僅接受已初始化、IRQ 已關閉的非 idle RUNNING task，
且必須存在其他 READY task；IRQ context 與無效條件會回傳 false，不修改狀態。
等待者恢復時 IF 仍為 0，由呼叫者恢復原 flags 並重查條件。

`task_wake` 自行保存／恢復 IF，只喚醒相同 channel 的 BLOCKED tasks，
清除 channel，回傳數量，不立即切換。`task_idle` 僅供 IRQ 已開啟的 boot
context 使用；在同一 IRQ 保護區內檢查 READY 工作，沒有工作才 safe halt。
IRQ depth 由 dispatcher 維護，阻止 IRQ path 誤用 block/yield。

`make test-event-wait` 以真實主機 context 檢查交接；
`make test-event-wait-qemu` 檢查真實 i686 stack、IF、暫存器與 IRQ 整合。
