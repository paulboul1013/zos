# Interrupt / memory integration contract

This branch owns the first Task 6 + Task 9 slices.  It deliberately does not
touch `kernel/kernel.zc`, `kernel/timer.zc`, `kernel/keyboard.zc`,
`kernel/console.zc`, `kernel/io.zc`, `arch/i686/linker.ld`, or `Makefile`.

## Interrupt ABI

`arch/i686/interrupts.S` exports `zos_isr0` through `zos_isr31`,
`zos_irq0` through `zos_irq15`, `zos_cpu_cli`, `zos_cpu_sti`, and
`zos_idt_load`.

Every entry reaches the Zenc-generated cdecl symbol:

```c
void zos_isr_dispatch(uint32_t vector, uint32_t error_code);
```

The assembly normalizes vectors with and without architectural error codes;
the normalized value is zero for the synthetic case.  The exception stubs
preserve the CPU error code on the stack for `iret`; IRQs use a synthetic
zero.  `interrupts_enable/disable` in `kernel/interrupts.zc` are wrappers
around `sti/cli` and should only run after a valid IDT is installed.

The current dispatch policy records the most recent vector/error and marks
vectors 0..31 as halted.  Timer and keyboard agents may extend this policy by
calling their own hooks from `zos_isr_dispatch`; they should preserve the
recording functions and avoid editing the assembly stubs.

The state query symbols are `zos_interrupt_get_last_vector`,
`zos_interrupt_get_last_error`, `zos_interrupt_get_count`, and
`zos_interrupt_is_halted`; the names intentionally differ from the backing
global variables.

## Bump allocator ABI

```c
void zos_memory_init(uint32_t start, uint32_t end);
void *zos_memory_alloc(uint32_t size, uint32_t align);
void *zos_memory_alloc_word(uint32_t size);
void zos_memory_reset(void);
uint32_t zos_memory_used(void);
uint32_t zos_memory_limit(void);
```

`start` is normally the linker symbol `__kernel_end` rounded up to a page or
word boundary.  `end` is an exclusive heap limit exported by `linker.ld` (the
preferred name is `__heap_end`; if the linker uses `__kernel_heap_end`, add a
Makefile/linker alias).  The allocator uses identity-mapped 32-bit addresses,
rejects non-power-of-two alignments, and returns null on overflow/exhaustion.
There is no free operation in the MVP.

Root integration should add `__kernel_end` and `__heap_end` symbols to the
linker script, call `zos_memory_init((U32)&__kernel_end, (U32)&__heap_end)`
before timer/keyboard/shell setup, and link this module before consumers.
