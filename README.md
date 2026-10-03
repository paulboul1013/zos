# ZOS（Zenc 作業系統）

本目錄是使用 Zenc 編譯器進行的獨立 i686 作業系統實驗專案。原始碼位於
Zenc 編譯器儲存庫之外；本專案透過 [Zenc 編譯器儲存庫](https://github.com/zenc-lang/zenc)，使用全AI撰寫的作業系統

## 功能

目前的可以啟動獨立執行的 i686 Multiboot v1 核心，並完成第一條互動式
裝置輸入路徑：

- VGA 文字主控台（自動換行與底部捲動）及 COM1 序列輸出；
- IDT/PIC/PIT 中斷設定與計時器 tick；
- PS/2 鍵盤掃描碼轉換、Shift 按鍵處理、IRQ EOI，以及 64-byte 輸入
  ring buffer；
- 常駐 Ring 0 shell task，從 IRQ queue 消費字元，支援 `clear` 指令與
  未知指令處理；
- 協作式 Ring 0 kernel tasks，具備獨立 stack、Round-Robin 排程、世代 ID 與自動回收。

開機時會建立常駐 shell task。Shell 初始化提示字元並在輸入 queue 為空時
透過 `keyboard_read_blocking()` 進入 `BLOCKED`，讓控制權回到 boot task；
IRQ1 成功 enqueue 後才喚醒 shell，PIT tick 不會重新排程空等的 shell。Serial 會輸出：

```text
shell task: ready
shell task: running
```

目前最多支援 4 個 task：boot task、常駐 shell task，以及兩個尚未使用的
slot；新建 task 各使用 4 KiB 靜態 stack。Keyboard queue 保留一個 slot
區分 full/empty，所以最多暫存 63 個字元；滿載後的新字元會被丟棄。
Task 0 以 IRQ 保護 READY 檢查，再執行相鄰的 `sti; hlt`。
Task entry 返回後，核心切到另一個 stack，再回收原 slot 與 stack。
Task ID 包含 slot 與 generation；過期 ID 的狀態查詢回傳 `0xFF`。
世代用盡後，核心永久停用該 slot。`task_count()` 累計成功建立數，
`task_live_count()` 表示存活數，兩者都包含 boot task。
PIT 尚未用於搶佔式排程，也尚未支援 user mode 或 paging。

`make kernel` 會產生 `build/zenc-os.elf`。`make iso` 會將它與
`iso/boot/grub/grub.cfg` 中的靜態 GRUB 選單封裝成 `build/zenc-os.iso`。

## 前置需求

請先安裝以下工具，並確保它們可以直接從 `PATH` 執行：

```text
zc
i686-elf-gcc
i686-elf-ld
i686-elf-nm
grub-file
grub-mkrescue
qemu-system-i386
```

`Makefile` 會自動從 `PATH` 找到 `zc` 與 `i686-elf-*` 工具鏈，不依賴特定
使用者的主機絕對路徑。

其中 `i686-elf-gcc`、`i686-elf-ld` 與 `i686-elf-nm` 應來自同一套
i686 cross-toolchain。若工具安裝在自訂位置，可以覆寫 `ZC` 或
`CROSS_PREFIX`，例如：

```sh
make ZC=/path/to/zc \
     CROSS_PREFIX=/opt/cross/bin/i686-elf- \
     kernel
```

## 編譯與執行

```sh
make
```

執行
```sh
make qemu
```

## 事件等待驗證

```sh
make test
make test-event-wait-qemu
make test-event-wait-qemu EVENT_WAIT_OPT=-O2 EVENT_WAIT_BOOT=iso
```

`make test` 包含 IRQ 物件檢查與 `-O0`／`-O2` 主機交錯測試。QEMU target
另驗證 100 輪真實鍵盤輸入、無輸入時的 dispatch counter、VGA 內容及
stack／暫存器／IF 恢復。詳見 [事件等待計畫](docs/event-wait-plan.md)
與 [驗證結果](docs/event-wait-results.md)。

## Task 生命週期驗證

```sh
make test-task-lifecycle
make test-task-lifecycle-qemu
make test-task-lifecycle-qemu TASK_LIFECYCLE_OPT=-O0 TASK_LIFECYCLE_BOOT=iso
make test-task-lifecycle-qemu TASK_LIFECYCLE_OPT=-O2 TASK_LIFECYCLE_BOOT=direct
make test-task-lifecycle-qemu TASK_LIFECYCLE_OPT=-O2 TASK_LIFECYCLE_BOOT=iso
```

主機測試包含於 `make test`，使用 `-O0` 與 `-O2` 驗證真實主機 stack。
QEMU 測試另行執行，驗證 100 個 task、首次啟動容量交接、世代用盡、
真實 IRQ 呼叫與兩種致命退出，也執行鍵盤和 shell 回歸。
紀錄保存在 `build/task-lifecycle/`。契約見[實作計畫](docs/task-lifecycle-plan.md)，
完成的驗收見[驗證結果](docs/task-lifecycle-results.md)。
