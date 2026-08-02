# i686 IDT integration contract

`kernel/interrupts.zc` now owns the first IDT installation phase.  The raw C
block is intentionally limited to packed gate/IDTR descriptors, the `lidt`
instruction, and the address tables for `zos_isr0..31` and `zos_irq0..1`.

`interrupts_init()` performs these steps with CPU interrupts disabled:

1. install exception gates for vectors `0..31`;
2. install remapped PIC gates for vector `32` (IRQ0) and `33` (IRQ1);
3. execute `lidt` and mark `interrupts_is_initialized()` true.

PIC remapping/masking remains owned by `timer_init()` and the keyboard slice;
the IDT task does not touch ports or issue `sti`.  The root sequence should
call `interrupts_init()` before enabling interrupts and before `timer_init()`
unmasks IRQ0.

Dispatch behavior is deliberately small and explicit:

- vectors `0..31` retain the fatal/halted state policy;
- vector `32` invokes `timer_handle_irq()` (which sends the PIC EOI);
- vector `33` reads a scancode, translates it, and echoes nonzero ASCII via
  `console_putc()` until the shell task takes ownership.

The static test compiles generated C and assembly as i686 freestanding objects
and combines them with `ld -r`; it does not execute privileged instructions.
