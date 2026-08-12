# ZOS Keyboard Queue 與 Ring 0 Shell Task 規格

## 目標

將鍵盤 IRQ 與 shell 指令處理解耦。IRQ1 只讀取並翻譯一個 PS/2 scancode、
將非零 ASCII 字元加入固定大小 queue，最後送出 PIC EOI。常駐的 Ring 0
shell task 是 queue 的唯一消費者，負責呼叫 `shell_feed_char()`。

這能避免 IRQ context 執行 VGA 輸出、清除畫面或指令處理，也讓既有
cooperative task 第一次承擔長期 kernel 工作。

## 技術堆疊

- Zenc freestanding kernel modules。
- i686 Ring 0 cooperative tasks。
- PS/2 keyboard IRQ1 與 master PIC EOI。
- 64-byte 靜態 single-producer/single-consumer ring buffer。
- GRUB Multiboot、QEMU 與 hosted C harness 測試。

本里程碑不加入 Ring 3、paging、搶佔式排程、動態配置或 blocked/wakeup
task state。

## 指令

```sh
make kernel
make test-keyboard-queue
make test-shell-task
make test-task
make test
make qemu
```

## 專案結構

```text
kernel/keyboard.zc              IRQ producer 與 ASCII ring buffer
kernel/interrupts.zc            IRQ1 dispatch 邊界
kernel/shell.zc                 shell state 與常駐 shell task entry
kernel/kernel.zc                task 建立與 boot idle/yield loop
tests/keyboard_queue_static.sh  queue、overflow 與 EOI 測試
tests/shell_static.sh           shell task 消費/yield 與既有指令回歸測試
tests/shell_task_static.sh      IRQ boundary、task 建立與 idle loop 檢查
docs/shell-task-contract.md     本規格
```

## 公開 API 與程式碼風格

```zc
def KEYBOARD_QUEUE_CAPACITY: u32 = 64;

fn keyboard_handle_irq();
fn keyboard_queue_pop() -> u8;
fn keyboard_queue_count() -> u32;
fn keyboard_queue_dropped() -> u32;

fn shell_task();
```

Keyboard 公開函式使用 `keyboard_` 前綴；queue 儲存空間與 index 使用
`_keyboard_queue_` 前綴。Queue 以 head/tail 實作：IRQ1 是唯一 producer，
shell task 是唯一 consumer。保留一個空 slot 區分 full 與 empty，因此
64-byte storage 最多同時保存 63 個字元。

## 執行流程

```text
PS/2 IRQ1
    |
    v
keyboard_handle_irq
    |-- read scancode
    |-- translate ASCII
    |-- enqueue non-zero byte
    `-- PIC EOI

PIT/keyboard wakes boot task from hlt
    |
    v
boot task_yield -> shell_task -> dequeue/feed/yield -> boot hlt
```

Queue 滿載時丟棄新字元，不覆寫尚未消費的舊字元，並增加 dropped
counter。Shift、break code 與不支援的 scancode 仍會完成 EOI，但不進入
queue。

## 測試策略

- Hosted queue harness 驗證 empty、FIFO、wrap-around、63-byte full boundary、
  overflow drop-newest 與 dropped counter。
- Hosted IRQ harness 以 I/O stub 驗證 scancode 會 enqueue 且每次 IRQ 都送
  一次 EOI。
- 靜態 boundary 檢查禁止 `kernel/interrupts.zc` 直接引用
  `shell_feed_char`，也禁止 IRQ path 呼叫 scheduler。
- Shell harness 保留既有 `clear`、未知指令、長輸入與 Backspace 測試，並
  確認輸出 `shell_task` symbol。
- QEMU 驗證 shell task 建立、實際進入後 yield 回 boot task，kernel 能
  持續接受 PIT/keyboard IRQ。
- `make test` 驗證全部既有功能沒有回歸。

## 範圍界線

- 一定要做：IRQ1 保持短小；EOI 不得遺漏；queue 維持 FIFO；沒有輸入時
  shell task 必須 yield；boot idle loop 必須先 yield 再 hlt。
- 需要先詢問：改變 queue 容量、加入 blocked state，或從 IRQ 直接觸發
  context switch。
- 絕對不做：在 IRQ 內執行 shell/console、使用 heap 配置 queue、加入
  Ring 3 或 PIT preemption。

## 實作任務

- [x] 新增會失敗的 queue 與 IRQ boundary 測試。
  - 驗收：目前缺少 queue API，且 interrupt dispatcher 仍直接呼叫 shell，
    所以測試以非零狀態結束。
- [x] 實作 keyboard SPSC ring buffer 並讓 IRQ1 enqueue。
  - 驗收：FIFO、wrap-around、overflow 與 EOI hosted 測試全部通過。
- [x] 新增常駐 `shell_task()` 並整合 cooperative idle loop。
  - 驗收：IRQ dispatcher 不再依賴 shell；shell task 無輸入時會 yield。
- [x] 更新建置、README 與 QEMU marker。
  - 驗收：`make test` 與 `git diff --check` 通過。

## 成功條件

- `zos_isr_dispatch(33, ...)` 不呼叫 shell、console 或 scheduler。
- IRQ1 只完成 scancode read/translate、enqueue 與 EOI。
- Queue 按輸入順序交付字元，滿載時不破壞舊資料。
- Shell task 能持續消費 queue，沒有輸入時不會獨占 CPU。
- Boot task 能在沒有 runnable 工作時使用 `hlt`，並在 IRQ 後繼續排程。
- 既有 task、timer、keyboard、shell、VGA 與 ISO 測試全部通過。

## 未決問題

本里程碑沒有未決問題。真正的 sleep/wakeup、task slot 回收、PIT
preemption、paging 與 Ring 3 shell 留待後續里程碑。
