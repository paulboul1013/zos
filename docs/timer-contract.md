# Timer integration contract

This slice owns `kernel/timer.zc`.  It does not modify the common interrupt
dispatcher, keyboard code, `arch/i686/io.zc`, `Makefile`, or the linker.

## Public API

```c
void timer_init(uint32_t hz);
uint32_t timer_ticks(void);
uint32_t timer_frequency(void);
uint16_t timer_divisor(void);
bool timer_is_initialized(void);
void timer_handle_irq(void);
```

`timer_init(0)` uses 100 Hz.  The PIT divisor is derived from the nominal
1,193,182 Hz PIT input clock and is clamped to the 16-bit range accepted by
channel 0.  `timer_ticks` is a 32-bit counter and wraps after 2^32 timer IRQs;
using a 32-bit value keeps reads atomic on the first i686 target.

After the first handled IRQ0, the handler writes the one-time serial marker
`timer: ok\n` through `serial_write`.  A private boolean guard prevents output
on subsequent ticks; re-running `timer_init` resets the guard for the next
boot/test cycle.

## Hardware behavior

- PIT channel 0 (port `0x40`) is programmed in mode 2 through command port
  `0x43`.
- The legacy PIC is remapped to vectors `0x20`–`0x27` (master) and
  `0x28`–`0x2F` (slave), matching `zos_irq0`–`zos_irq15` in
  `arch/i686/interrupts.S`.
- Existing PIC masks are restored, except master IRQ0 is unmasked so the
  timer can fire.  IRQ1 and all other lines remain unchanged for later
  keyboard/device tasks.
- `timer_handle_irq` increments the counter, sends a master-PIC EOI
  (`outb(0x20, 0x20)`), then emits the one-time `timer: ok` serial marker.  It
  never enables CPU interrupts itself.

## Root dispatcher wiring

The root integrator must call `timer_handle_irq()` from the shared dispatch
function when `vector == 32` (the remapped PIT IRQ0).  The existing interrupt
state recording and fatal exception policy must remain intact.  A minimal
dispatch branch is:

```text
if vector == 32 {
    timer_handle_irq();
    return;
}
```

Call `timer_init(hz)` only after the port-I/O module is linked.  Install a
valid IDT gate for `zos_irq0`, then call `interrupts_enable()` after all
handlers are ready.  `timer_init` intentionally does not execute `sti`.

## Verification

`tests/timer_static.sh` transpiles this module with `zc transpile
--freestanding`, compiles the generated C as i686 freestanding code, and
checks the exported API and PIT/PIC constants.  Hardware behavior still needs
an integration smoke test in QEMU after the dispatcher and IDT are wired.
