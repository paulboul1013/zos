#!/usr/bin/env bash
set -eu

# Static slice check.  Full linking is intentionally deferred to the root
# integrator because this branch does not own Makefile/linker.ld.
ZC=${ZC:-/home/paulboul/zenc/zc}
CROSS_CC=${CROSS_CC:-/home/paulboul/osdev/opt/cross/bin/i686-elf-gcc}
CROSS_NM=${CROSS_NM:-${CROSS_CC%gcc}nm}
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUT=${TMPDIR:-/tmp}/zos-interrupt-memory-check.$$
trap 'rm -rf "$OUT"' EXIT
mkdir -p "$OUT"

"$ZC" transpile --freestanding "$ROOT/kernel/memory.zc" -o "$OUT/memory.c"
"$ZC" transpile --freestanding "$ROOT/kernel/interrupts.zc" -o "$OUT/interrupts.c"

grep -q 'zos_memory_alloc' "$OUT/memory.c"
grep -q 'zos_isr_dispatch' "$OUT/interrupts.c"

# Zenc's freestanding preamble intentionally leaves these linkage hooks to
# the build system.  Defining them empty makes the generated C self-contained
# for this syntax/object check while retaining externally visible symbols.
"$CROSS_CC" -ffreestanding -m32 -fno-builtin -fno-stack-protector \
    -DZC_FUNC= -DZC_GLOBAL= -c "$OUT/memory.c" -o "$OUT/memory.o"
"$CROSS_CC" -ffreestanding -m32 -fno-builtin -fno-stack-protector \
    -DZC_FUNC= -DZC_GLOBAL= -c "$OUT/interrupts.c" -o "$OUT/interrupts.o"

for symbol in \
    zos_memory_init zos_memory_reset zos_memory_used zos_memory_limit \
    zos_memory_alloc zos_memory_alloc_word; do
    "$CROSS_NM" -g --defined-only "$OUT/memory.o" | \
        grep -Eq "[[:space:]]$symbol$"
done

for symbol in \
    zos_isr_dispatch zos_interrupt_get_last_vector zos_interrupt_get_last_error \
    zos_interrupt_get_count zos_interrupt_is_halted zos_interrupt_reset_state \
    zos_interrupts_enable zos_interrupts_disable; do
    "$CROSS_NM" -g --defined-only "$OUT/interrupts.o" | \
        grep -Eq "[[:space:]]$symbol$"
done

# Validate assembler preprocessing and 32-bit syntax where the host toolchain
# provides it.  `-m32 -c` emits no link dependency and is enough for this
# isolated slice.
if command -v "$CROSS_CC" >/dev/null 2>&1; then
    "$CROSS_CC" -ffreestanding -m32 -c "$ROOT/arch/i686/interrupts.S" \
        -o "$OUT/interrupts.S.o"
elif command -v gcc >/dev/null 2>&1; then
    gcc -m32 -c "$ROOT/arch/i686/interrupts.S" -o "$OUT/interrupts.S.o"
fi

echo "interrupt/memory static checks passed"
