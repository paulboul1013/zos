# ZOS（Zenc 作業系統）

本目錄是使用 Zenc 編譯器進行的獨立 i686 作業系統實驗專案。原始碼位於
Zenc 編譯器儲存庫之外；本專案透過 [Zenc 編譯器儲存庫](https://github.com/zenc-lang/zenc)，使用全AI撰寫的作業系統

## 功能

目前的可以啟動獨立執行的 i686 Multiboot v1 核心，並完成第一條互動式
裝置輸入路徑：

- VGA 文字主控台與 COM1 序列輸出；
- IDT/PIC/PIT 中斷設定與計時器 tick；
- PS/2 鍵盤掃描碼轉換、Shift 按鍵處理，以及 IRQ EOI；
- 具備固定大小緩衝區的 shell，支援 `clear` 指令與未知指令處理。

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

## 可重現的指令

```sh
make check-tools
make transpile
make check-abi
make kernel
make iso
make qemu
make test
```

`make test` 會對每個模組執行獨立轉譯與物件檔檢查、使用 QEMU 直接啟動
ELF、建立 GRUB ISO，並使用 QEMU 啟動該 ISO。ISO 測試需要四個執行期標記：
`Zenc OS booted`、`keyboard: ready`、`shell: ready` 與 `timer: ok`。

手動執行方式：

```sh
make qemu
```

`make qemu` 會先自動建立 ISO、開啟 QEMU 視窗，並將序列輸出連接到終端機。
在 QEMU 視窗的 `zos>` 提示字元輸入 `clear`。`help`、`about` 與 `ticks` 等
資訊查詢指令並未內建。若要以無頭模式只使用序列輸出執行：

```sh
make qemu QEMU_FLAGS='-serial stdio -display none -monitor none'
```
