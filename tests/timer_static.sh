#!/usr/bin/env bash
set -eu

# Task 7 owns only timer.zc and this isolated static/object check.  Full
# linking and QEMU execution are intentionally deferred to the root branch.
ZC=${ZC:-/home/paulboul/zenc/zc}
CROSS_CC=${CROSS_CC:-/home/paulboul/osdev/opt/cross/bin/i686-elf-gcc}
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUT=${TMPDIR:-/tmp}/zos-timer-check.$$
trap 'rm -rf "$OUT"' EXIT
mkdir -p "$OUT"

"$ZC" transpile --freestanding "$ROOT/kernel/timer.zc" -o "$OUT/timer.c"

grep -q 'timer_init' "$OUT/timer.c"
grep -q 'timer_ticks' "$OUT/timer.c"
grep -q 'timer_handle_irq' "$OUT/timer.c"
grep -q '1193182' "$OUT/timer.c"
grep -q 'PIT_COMMAND: u16 = 0x43' "$ROOT/kernel/timer.zc"
grep -q 'PIC_MASTER_COMMAND: u16 = 0x20' "$ROOT/kernel/timer.zc"

# The freestanding preamble leaves linkage markers for the build system.
"$CROSS_CC" -ffreestanding -m32 -fno-builtin -fno-stack-protector \
    -Wall -Wextra -DZC_FUNC= -DZC_GLOBAL= -c "$OUT/timer.c" \
    -o "$OUT/timer.o"

"${CROSS_CC%gcc}nm" -g --defined-only "$OUT/timer.o" | \
    grep -Eq '[[:space:]]timer_(init|ticks|handle_irq)$'

echo "timer static/object checks passed"
