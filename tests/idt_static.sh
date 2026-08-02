#!/usr/bin/env bash
set -eu

# Validate the IDT/dispatch slice without linking a hosted libc or running
# privileged lidt/sti instructions on the build host.
ZC=${ZC:-/home/paulboul/zenc/zc}
CROSS_CC=${CROSS_CC:-/home/paulboul/osdev/opt/cross/bin/i686-elf-gcc}
CROSS_LD=${CROSS_LD:-/home/paulboul/osdev/opt/cross/bin/i686-elf-ld}
CROSS_NM=${CROSS_NM:-/home/paulboul/osdev/opt/cross/bin/i686-elf-nm}
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUT=${TMPDIR:-/tmp}/zos-idt-check.$$
trap 'rm -rf "$OUT"' EXIT
mkdir -p "$OUT"

"$ZC" transpile --freestanding "$ROOT/kernel/interrupts.zc" -o "$OUT/interrupts.c"

grep -q 'interrupts_init' "$OUT/interrupts.c"
grep -q '_zos_idt_set_gate' "$OUT/interrupts.c"
grep -q '_zos_idt_load' "$OUT/interrupts.c"
grep -q 'timer_handle_irq' "$OUT/interrupts.c"
grep -q 'keyboard_read_scancode' "$OUT/interrupts.c"
grep -q 'keyboard_handle_scancode' "$OUT/interrupts.c"
grep -q 'console_putc' "$OUT/interrupts.c"

# Freestanding Zenc output leaves linkage visibility macros to the build
# system; define them empty for this isolated object check.
"$CROSS_CC" -ffreestanding -m32 -fno-builtin -fno-stack-protector \
    -DZC_FUNC= -DZC_GLOBAL= -c "$OUT/interrupts.c" -o "$OUT/interrupts.o"
"$CROSS_CC" -ffreestanding -m32 -c "$ROOT/arch/i686/interrupts.S" \
    -o "$OUT/stubs.o"

# This catches duplicate/invalid assembly symbols while allowing the later
# timer/keyboard/console modules to remain unresolved until final integration.
"$CROSS_LD" -r "$OUT/interrupts.o" "$OUT/stubs.o" -o "$OUT/idt-reloc.o"

"$CROSS_NM" "$OUT/idt-reloc.o" | grep -q ' T interrupts_init$'

echo "IDT static checks passed"
