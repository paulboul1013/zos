#!/usr/bin/env bash
set -euo pipefail

# This is intentionally independent of the OS Makefile.  It checks the
# console/serial/I/O slice while the boot and linker agents are still working
# on their branches.

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
zc_bin=${ZC:-/home/paulboul/zenc/zc}
cross_prefix=${CROSS_PREFIX:-/home/paulboul/osdev/opt/cross/bin/i686-elf-}

if [[ ! -x "$zc_bin" ]]; then
    echo "console smoke: zc compiler not found: $zc_bin" >&2
    exit 2
fi

if [[ -x "${cross_prefix}gcc" ]]; then
    cc_bin="${cross_prefix}gcc"
else
    cc_bin=${CC:-gcc}
fi

tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/zos-console-smoke.XXXXXX")
trap 'rm -rf "$tmp_dir"' EXIT

sources=(
    "$repo_root/arch/i686/io.zc"
    "$repo_root/kernel/console.zc"
    "$repo_root/kernel/serial.zc"
)

for source in "${sources[@]}"; do
    stem=$(basename "$source" .zc)
    generated="$tmp_dir/$stem.c"
    echo "console smoke: transpile $source"
    "$zc_bin" transpile --freestanding "$source" -o "$generated"
    # The freestanding preamble currently leaves these linkage macros for the
    # OS Makefile.  Defining them here makes this syntax check self-contained.
    "$cc_bin" -std=gnu11 -ffreestanding -fsyntax-only \
        -DZC_FUNC= -DZC_GLOBAL= "$generated"
done

grep -q 'console_putc' "$tmp_dir/console.c"
grep -q 'console_write' "$tmp_dir/console.c"
grep -q 'console_clear' "$tmp_dir/console.c"
grep -q 'volatile uint16_t' "$tmp_dir/console.c"
grep -q 'serial_putc' "$tmp_dir/serial.c"
grep -q 'serial_write' "$tmp_dir/serial.c"
grep -q 'outb' "$tmp_dir/io.c"
grep -q 'inb' "$tmp_dir/io.c"

echo "console smoke: PASS (freestanding transpile + C syntax + API/MMIO checks)"
