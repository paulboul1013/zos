# ZOS 協作式核心執行緒規格

## 目標

為 i686 核心實作最小且可觀察的 task 抽象。每個新建 task 都是 Ring 0
執行環境，包含 ID、生命週期狀態、已保存的 stack pointer、進入函式，
以及獨立的 4 KiB stack。Task 0 則沿用 `boot.S` 建立的 16 KiB stack。
只有在 task 呼叫 `task_yield()` 時才會切換；PIT IRQ0 仍只作為時脈來源，
不會搶佔正在執行的 task。

當兩個示範 task 能交替輸出 serial 標記、安全返回並進入終止狀態，且
開機 task 能繼續執行時，即完成第一個里程碑。

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
kernel/kernel.zc        兩個有限執行的 serial 示範 task 與開機整合
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
fn task_current() -> u32;
fn task_count() -> u32;
fn task_state(id: u32) -> u8;
```

Task slot 0 代表開機執行環境，slot 1 至 3 供 kernel threads 使用。公開
task 函式使用 `task_` 前綴；架構相關輔助函式使用 `_zos_task_`；私有
scheduler 資料使用 `_task_`。

生命週期狀態包含 `UNUSED`、`READY`、`RUNNING` 與 `TERMINATED`。
當進入函式為 null 或 task table 已滿時，`task_create` 會回傳
`TASK_INVALID_ID`。

## Context switch 約定

`_zos_task_context_switch(old_sp, new_sp)` 使用 i686 cdecl ABI：

1. 將 EFLAGS 與所有通用暫存器推入 stack。
2. 透過 `old_sp` 保存目前的 ESP。
3. 將 `new_sp` 載入 ESP。
4. 還原暫存器與 EFLAGS。
5. 返回並繼續執行被恢復的 task。

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

- `task_init` 將目前的開機 stack 註冊為 `RUNNING` 狀態的 task 0。
- `task_create` 配置下一個靜態 slot，並準備其初始 stack。
- `task_yield` 以循環方式尋找下一個 `READY` task。
- 如果沒有其他可執行的 task，`task_yield` 會直接返回而不切換。
- 除非正在終止，否則目前執行中的 task 會在切換前變成 `READY`。
- 已返回的 task 會變成 `TERMINATED`，之後不再被排程。
- 本里程碑不會重複使用 task slot 與 stack。

## 測試策略

- RED/GREEN hosted scheduler 測試：使用 context-switch stub 驗證初始化、
  容量、Round-Robin 狀態、無效 ID，以及沒有 ready task 時的行為。
- Cross-object 測試：確認產生的 task 模組是 freestanding i686 程式碼，
  能輸出規格定義的 ABI，且不依賴 hosted runtime。
- Relocatable assembly link：確認 context-switch symbol 與 task 模組一致。
- QEMU 整合測試：serial 輸出包含交替的 `task A`、`task B` 步驟與
  `tasks: done`，證明不同 stack 能正確恢復執行。
- 完整回歸測試：`make test` 必須繼續通過所有既有測試。

## 範圍界線

- 一定要做：保留既有 IDT/PIC/PIT/keyboard 行為；IRQ0 維持非搶佔式；
  使用 object 與 QEMU 測試驗證 stack-frame offset。
- 需要先詢問：變更 task 數量、stack 大小、加入搶佔式排程，或在本里程碑
  將 shell 移出 IRQ context。
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
- [x] 將兩個示範 task 整合至開機與建置 target。
  - 驗收：兩個 task 各自交替執行兩次、正常終止，且開機 task 繼續存活。
  - 驗證：`make test`。
- [x] 更新 README，說明協作式排程行為與限制。
  - 驗收：文件內容與實際公開 API 一致。
  - 驗證：`git diff --check`。

## 成功條件

- Task 0 是開機執行環境；至少兩個額外 task 使用不同的 4 KiB stack 執行。
- Serial 標記證明執行順序為 `A1 -> B1 -> A2 -> B2`。
- 任一 task 返回時都不會破壞開機 stack 或 return address。
- 除非程式明確呼叫 `task_yield()`，否則不會發生 task switch。
- 既有 keyboard、shell、timer、VGA、ISO 與 direct-boot 測試全部通過。

## 待確認問題

本里程碑沒有待確認問題。搶佔式排程、wait queue、task slot 重複使用、
user mode，以及將 shell 移至獨立 task，皆刻意延後處理。
