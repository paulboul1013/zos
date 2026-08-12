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
- 協作式 Ring 0 kernel tasks，具備獨立 stack、Round-Robin 排程與安全退出。

開機時會建立常駐 shell task。Shell 初始化提示字元並在輸入 queue 為空時
主動呼叫 `task_yield()`，讓控制權回到 boot task；serial 會輸出：

```text
shell task: ready
shell task: running
```

目前最多支援 4 個 task：boot task、常駐 shell task，以及兩個尚未使用的
slot；新建 task 各使用 4 KiB 靜態 stack。Keyboard queue 保留一個 slot
區分 full/empty，所以最多暫存 63 個字元；滿載後的新字元會被丟棄。
PIT 尚未用於搶佔式排程，也尚未支援 user mode、paging、blocked task 或
task stack 回收。

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
