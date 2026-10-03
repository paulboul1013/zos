# ZOS 下一個功能的優先順序調查

調查日期：2026-10-02。程式碼基準：`2c2c424687e6494fa2b6ac30e3a57b1c6152c16f`。

**目前最值得實作的是「可阻塞、可由事件喚醒的 kernel task」，第一個使用者是等待鍵盤輸入的 shell。**
以下排名以 README 的 i686 實驗核心定位及既有小步里程碑為依據，是本次調查的建議，並非已採納的 roadmap。
既有規格只將後續功能列為延後項目，沒有規定優先順序。[README](../README.md)、[既有後續項目](shell-task-contract.md#未決問題)

## 目前真正的缺口

- Shell 在 queue 為空時呼叫 `task_yield()`，但仍是可執行的 task；boot task 每輪先 yield，再執行 `hlt`。
  PIT 約每 10 ms 中斷一次，因此閒置時 shell 仍會反覆被排程來檢查空 queue。
  這是已有 `hlt` 的有界輪詢，不是持續 busy spin，也沒有證據顯示 shell 目前會永久錯過鍵盤輸入。
  [shell_task](../kernel/shell.zc)、[boot idle loop](../kernel/kernel.zc)、[PIT](../kernel/timer.zc)
- Task 狀態只有 `UNUSED/READY/RUNNING/TERMINATED`，沒有表達「等待裝置或其他 task」的狀態。
  目前 boot 與 shell 佔兩個 slot，另外兩個 slot 可建立 task，但 `task_create()` 的 ID 單向增加，退出後不會再利用。
  [task table、create、exit](../kernel/task.zc)
- Boot header 有要求記憶體資訊，但 `_start` 尚未把 Multiboot 的資訊交給 `kernel_main()`；heap 是 linker 指定的固定 64 KiB arena，沒有根據機器 memory map 配置實體頁框。
  [boot entry](../arch/i686/boot.S)、[linker](../arch/i686/linker.ld)、[bump allocator](../kernel/memory.zc)

## 建議排名

判斷準則是目前功能可直接受益、後續功能能否重用、所需基礎是否已存在，以及能否以 hosted model 和 QEMU 分段驗證。

| 順位 | 功能與最小範圍 | 為何排在這裡 | 主要風險或前置工作 |
|---|---|---|---|
| 1 | **事件等待與喚醒**：`BLOCKED`、wait channel、IRQ-safe wakeup，接入鍵盤 shell | 現有 shell 立即使用；讓 task 能等待裝置，之後可延伸到 timer、pipe、I/O completion、join | queue 條件檢查與進入等待必須避免 lost wakeup；idle 只在沒有 runnable 工作時 halt |
| 2 | **Task 生命週期與 slot 重用**：退出後安全回收靜態 slot/stack | 目前全開機期間只能新建三次 task，shell 已用掉一次；可反覆執行短期 kernel 工作 | 必須已離開退出 task 的 stack 才能重用；定義舊 task ID、count、等待者的語意 |
| 3 | **Multiboot 資訊與實體頁框管理**：解析 memory map、保留區域、頁框 alloc/free | 補上可靠使用 RAM 的基礎，讓下一步 paging 不依賴猜測可用記憶體 | 保留 kernel、boot stack、boot info、modules 等已佔用範圍；memory map 缺失要有明確處置 |
| 4 | **Paging 與 page-fault 診斷**：先 kernel identity mapping，再 map/unmap 與權限測試 | 提供可管理的映射及 guard page 等保護；為受保護的使用者空間鋪路 | 啟用後 kernel、stack、VGA、IDT/GDT 與頁表本身都必須能存取；先補真實 fault 診斷 |
| 5 | **PIT 搶佔式排程**：time slice、完整中斷 context、臨界區規則 | 能阻止不主動 yield 的 task 獨占 CPU；目前 shell 沒有長時間運算工作，因此不是第一個瓶頸 | scheduler、console、heap 等共享狀態可能被任意中斷；需處理 IRQ frame、IF、EOI 與返回路徑 |
| 6 | **System call 與 Ring 3 shell**：受保護的 user task，最小 read/write/exit | 形成真正的核心／應用程式邊界，但目前改動面最大 | 核心自有 GDT/TSS、user/kernel stack、trap entry/return、syscall ABI、user pointer 驗證、記憶體保護 |

表中的缺口來自 [task](../kernel/task.zc)、[memory](../kernel/memory.zc)、[boot](../arch/i686/boot.S)、
[interrupt entry](../arch/i686/interrupts.S) 與 [shell](../kernel/shell.zc)；順位是本次調查的工程判斷。
第 2 項應以 QEMU 驗證有限 task 真正返回、退出後能累計新建超過三次；目前 hosted harness 只驗證建立與 Round-Robin，
QEMU marker 只證明 shell 啟動及 yield 回 boot，尚未涵蓋真實退出或 slot 重用。[task tests](../tests/task_static.sh)、[boot test](../tests/task_boot_test.sh)

**這不是硬性相依鏈。** Ring 0 preemption 不需要先有 paging；固定靜態頁表也能做第一個 paging 實驗。
此處先排實體頁框管理，是為了可擴充、可回收且能正確辨識 RAM 的 paging。
IA-32 也能利用 segmentation 在沒有 paging 時進行 privilege protection；本建議選擇以 paging 建立後續 user memory protection。
[Intel SDM Volume 3A，§3.2、§4.1、§5.6](https://cdrdv2-public.intel.com/812386/253668-sdm-vol-3a.pdf)

如果下一個明確目標改為「讓兩個 CPU-bound task 不必 yield 也能輪流執行」，應將第 5 項提前到第 3 項；
如果目標改為「執行受保護的應用程式」，則第 3、4、6 項應成為主線。目前 repo 沒有這兩種更具體的目標。
[現有里程碑範圍](task-contract.md#目標)、[README](../README.md)

## 為何先做事件等待

MIT xv6 將 sleep/wakeup 用於 pipe、裝置完成與子程序退出等條件等待：sleep 讓 task 離開 runnable 集合，
wakeup 將符合 wait channel 的 task 變回 runnable。Linux 的 `wait_event` 也在喚醒後重查條件，要求 producer
先更新條件再 wakeup。這些來源支持的是可重用的等待模型；ZOS 不必直接搬入它們的多核心鎖或完整 API。
[MIT xv6：Sleep and Wakeup](https://mit-pdos.github.io/xv6-riscv-book/sleep.html)、
[Linux：wait_event](https://docs.kernel.org/driver-api/basics.html#wait-event)

就目前 ZOS 而言，queue、IRQ producer、常駐 consumer 與 stack switch 都已存在，新增等待狀態即可完成現有輸入路徑的下一步。
反之，preemption 會把原本只在明確 yield 點發生的切換改為任意指令位置，需要一起審核共享狀態與 context 保存。
目前 cooperative switch 使用 `pushfl/pushal/ret`，interrupt entry 則以 `iret` 返回；要明確設計兩條路徑的組合。
MIT 的 x86 xv6 雖在 timer trap 呼叫 yield，但其 scheduler 同時檢查鎖與 interrupts-disabled 約定，不能只參考那一行。
[ZOS switch](../arch/i686/tasks.S)、[ZOS IRQ entry](../arch/i686/interrupts.S)、
[x86 xv6 trap](https://raw.githubusercontent.com/mit-pdos/xv6-public/master/trap.c)、
[x86 xv6 sched/sleep/wakeup](https://raw.githubusercontent.com/mit-pdos/xv6-public/master/proc.c)

實體頁框管理的具體工作是保留 boot information，驗證 Multiboot flags，再使用 memory map 中可用的 RAM。
Multiboot v1 的記憶體表有長度可變的 entry，`type == 1` 表示可用 RAM；不能把所有實體位址當成可配置空間。
[GNU Multiboot v1：Boot information format](https://www.gnu.org/software/grub/manual/multiboot/multiboot.html#Boot-information-format)

安全的 Ring 3 shell 還需要受控的 kernel 入口、kernel stack 與 user memory 檢查；paging 一項不等於完整應用程式隔離。
Intel 說明 TSS 提供跨 privilege 的 stack 資訊，以及 PDE/PTE 的 U/S 欄位限制 user memory access。
[Intel SDM Volume 3A，§4.3、§6.12、§10.8.4](https://cdrdv2-public.intel.com/812386/253668-sdm-vol-3a.pdf)

## 下一個可驗收的里程碑

建議名稱：**「Keyboard event wait 與 IRQ-safe task wakeup」**。先完成事件等待，再另開 timer deadline sleep 小里程碑。
4-slot 靜態 task table 足以用 wait channel 掃描，不必一開始就建立動態 wait queue。

1. 新增 blocked/wait-channel 語意，以及保存並恢復原先 IF 的 IRQ critical-section helpers；
   將「檢查 keyboard queue → 登記等待 → 改為 blocked → 讓出 CPU」設計為不會漏接 IRQ 的流程。
   喚醒後以 loop 重查 queue。[lost wakeup 與條件重查](https://mit-pdos.github.io/xv6-riscv-book/sleep.html)
2. IRQ1 成功 enqueue 後只將等待者改為 `READY`；維持一次 EOI，返回 IRQ 後才在 task context 排程。
   Shell 不在 IRQ 裡執行。保留 boot task 作為永遠存在的 idle fallback。
   [現有 IRQ／shell 邊界](shell-task-contract.md#範圍界線)
3. Idle 在沒有其他 runnable task 時才 halt；其最後一次 ready 檢查與開啟 IRQ／halt 的交接也須避免競態。
   保持 PIT 的 100 Hz tick，所以完成後仍有 timer wakeup；收益是減少無輸入時的 shell 檢查與切換，不承諾零中斷或大幅節電。
   [現有 idle](../kernel/kernel.zc)、[timer](../kernel/timer.zc)
4. Hosted model 驗證 blocked task 不被選中、不同 channel 不互相喚醒、重複 wakeup 安全、所有非 idle task blocked 時仍有 fallback；
   刻意插入 enqueue/wakeup，覆蓋檢查前、登記等待／切換交接時、已 blocked 後，以及沒有後續按鍵的情況。
   QEMU 以真實 keyboard IRQ 驗證等待後醒來、連續輸入 FIFO、重複 wait/wake、timer 持續與 shell 可操作；
   觀察閒置期間 shell 執行次數不因每個 tick 增長。最後保留 `make test` 全部既有功能回歸。
   [現有 hosted task harness](../tests/task_static.sh)、[現有 QEMU task marker](../tests/task_boot_test.sh)、[測試 targets](../Makefile)

在 paging 或 preemption 之前，另需補最小 panic/fault 診斷：目前 exception dispatcher 只設定 `zos_interrupt_halted` 後返回，
production code 沒有據此真的停止。應以真實 fault 驗證 serial 診斷和穩定 halt，而非只測 flag。
這是程式碼審查發現的待補能力，沒有在本次調查聲稱已觀察到 runtime crash。
[exception policy](../kernel/interrupts.zc)、[既有 hosted exception tests](../tests/interrupt_memory_static.sh)
