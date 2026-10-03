# 事件等待實作與驗證紀錄

日期：2026-10-02。狀態：實作與自動驗收完成，QMP 畫面已檢視。
範圍：單 CPU、i686 Ring 0、協作式排程、4 個 task slot、
63 字元有效容量的 keyboard queue。設計依據：[event-wait-plan.md](event-wait-plan.md)。

## 已完成的實作

- IRQ flags 保存與 IF-only 還原；`zos_cpu_safe_halt` 使用相鄰 `sti; hlt`。
- `TASK_BLOCKED = 4`、每個 task 的 wait channel、`task_block_on_locked`、
  `task_wake`、`task_idle`；create/yield/exit 的狀態交接均有 IRQ 保護。
- Keyboard 在同一 IRQ 保護區內檢查 queue 與登記等待，成功 enqueue 後通知。
  喚醒後重查，契約錯誤回傳 0。Shell 輸出一次診斷並返回。
- Boot task 保留 `shell task: running` 標記，之後進入安全 idle。
- Test build 才包含 per-task dispatch/block/wake counters；IRQ 無新增日誌。

## 驗證與可重現指令

| 驗證 | 結果與證據 |
|---|---|
| 實作前 `make test` | PASS，建立原有行為基準 |
| `make test-irq-flags` | PASS，i686 objdump 確認 save、IF-only restore、相鄰 STI/HLT |
| `make test-event-wait` | PASS，production Zenc 轉譯後以主機 GCC `-O0`、`-O2` 執行 |
| `make test` | PASS，ABI、console、interrupt/memory、timer、keyboard、queue、shell、task、direct boot、GRUB ISO 與新增主機測試 |
| QEMU direct `-O0` | PASS，100 輪鍵盤／VGA／context／IF／worker／PIT |
| QEMU direct `-O2` | PASS，同上 |
| QEMU ISO `-O0` | PASS，同上，正式 GRUB 設定 |
| QEMU ISO `-O2` | PASS，同上，正式 GRUB 設定 |
| Subagent review | 未發現本次變更的阻擋性問題；保留舊測試並新增 enqueue/wake 與 shell 錯誤返回斷言 |

主機測試使用 `ucontext` 暫停與恢復真實 C stack，並為每個 context 保存模擬
IF；context-switch stub 不會在 current ID 已改變時直接返回原讀取函式。
涵蓋：已有字元 FIFO／無切換、空 queue block、channel 0／異 channel、
同 channel 多等待者、重複 wake／TERMINATED、不合法前置條件、巢狀 IF、
空通知後重等、所有 task 等待時回到 boot、有 READY 時不 halt，以及 worker 進度。

固定交錯包括：檢查前、檢查與登記間、切換後、醒來重查時、idle 最後檢查與
halt 之間。IF=0 時事件只標記 pending，開 IRQ 後才交付；各案例只送一個
字元。另驗證 FIFO、wrap、overflow、Shift/break、通知順序與每次 IRQ 一個 EOI。

## 真實 i686 驗證

QEMU 測試用 `--wrap=task_create` 加入測試專用 context 與 worker tasks，
保留 production kernel entry、keyboard、shell、scheduler 與 interrupt modules。
Context probe 驗證跨 block/wake 的 stack 局部陣列、ESP、EBX/ESI/EDI/EBP，
等待恢復時 IF=0、還原後 IF=1；worker 在 shell BLOCKED 時完成 64 輪 yield。

每種 QEMU 組合均執行：100 PIT ticks 無 shell dispatch 增量、100 輪單次按鍵、
每輪恰好一次 wake/dispatch、queue 排空後再次 BLOCKED、Backspace、Enter、
clear、未知指令與 VGA 內容比對。事件序列是固定的，無隨機 seed。

```sh
make test-event-wait-qemu
make test-event-wait-qemu EVENT_WAIT_OPT=-O2
make test-event-wait-qemu EVENT_WAIT_BOOT=iso
make test-event-wait-qemu EVENT_WAIT_OPT=-O2 EVENT_WAIT_BOOT=iso
```

產物位於 `build/event-wait/{direct,iso}-{O0,O2}/`：`events.json` 記錄可重現的
按鍵序列，`final-snapshot.json` 保存 counters 與狀態，`qemu.log` 保存開機資訊，
`vga.txt`、`clear.ppm`、`unknown-command.ppm` 保存文字及畫面。

已檢視 direct-O0 的 QMP 畫面：clear 後僅保留 prompt；未知指令輸入、結果及
下一個 prompt 的位置正常。
這是 headless QEMU 畫面檢視，未另外進行真人桌面鍵盤操作。

生成 C 的 IRQ helpers 是無 pure/const 屬性的外部呼叫；共享 queue/task globals
的交接維持在保存／還原呼叫之間。物件中的 context switch 仍為
`pushf; pusha; ... ESP switch ...; popa; popf; ret`，新 context flags 為 `0x202`。
最佳化整合測試補充驗證此編譯器邊界。既有 generated-C unused-variable、
GNU-stack 與 RWX link warnings 仍存在。

本次四組 QEMU 均完成 110 個按鍵事件（100 輪加命令／編輯驗證），
每組 context probe 成功，worker 進度為 64。最終 shell 回到 BLOCKED。
另已檢視 ISO `-O2` 未知指令畫面，顯示正常。
QMP 本機 socket 需 sandbox 外執行；首次受限失敗不算通過。
ISO 啟動前 RAM 的非 ASCII 內容曾使測試 decode 失敗；harness 已容許 boot
等待期間的非 ASCII 快照，再以完整啟動條件及精確字元斷言驗證結果。

本次證據不延伸至 SMP、搶佔式排程、timer deadline sleep 或 task slot 回收。
