# ZOS keyboard contract (Task 8)

`kernel/keyboard.zc` is the PS/2 set-1 input boundary for the i686 MVP.  It
does not install an IRQ handler and does not write to the console; those
responsibilities belong to the interrupt and shell/console tasks.

## Initialization

`keyboard_init()` is the keyboard module's hardware initialization entry
point.  It clears the Shift state, reads the current master PIC data-port mask
at `0x21`, and writes back `mask & ~0x02`.  This unmasks only IRQ1 while
preserving all other master-PIC lines, including IRQ0 for the timer.  IDT gate
installation and global interrupt enable remain owned by the interrupt and
kernel integration code.  The function uses the shared `io_inb`/`io_outb`
port-I/O boundary and does not consume a pending byte from controller data
port `0x60`.

## Input and output

- `keyboard_read_scancode() -> u8` reads one byte from data port `0x60`.
- `keyboard_handle_scancode(scancode: u8) -> u8` translates one set-1 byte and
  is the deterministic translation boundary used by the IRQ producer.
- `keyboard_handle_irq()` reads one IRQ1 scancode, queues non-zero translated
  ASCII, and sends master-PIC EOI `0x20` to command port `0x20`. EOI is sent
  even when there is no translated byte or the queue is full.
- `keyboard_queue_pop() -> u8` lets the Ring 0 shell task consume queued input
  in FIFO order; `0` means the queue is empty.

Return bytes are ASCII: letters (`a`–`z`, or `A`–`Z` with Shift), number-row
digits (`0`–`9`, or `!@#$%^&*()` with Shift), space, newline for Enter, and
backspace for Backspace.  Unsupported keys, key releases, and modifiers return
`0`.

## Modifier lifecycle

`0x2a`/`0x36` set Shift; `0xaa`/`0xb6` clear Shift.  `keyboard_reset()` clears
the modifier state and should be called during kernel input initialization.
`keyboard_shift_active() -> u8` exposes the state for diagnostics/tests.

## Integration obligations

The interrupt dispatcher calls `keyboard_handle_irq()` for IRQ1 and does not
call the shell or console. The Ring 0 shell task drains `keyboard_queue_pop()`
outside interrupt context. The wrapper owns the master-PIC EOI; callers must
not duplicate that write. This driver intentionally does not call
`console_putc()`.
