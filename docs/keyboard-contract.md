# ZOS keyboard contract (Task 8)

`kernel/keyboard.zc` is the PS/2 set-1 input boundary for the i686 MVP.  It
does not install an IRQ handler and does not write to the console; those
responsibilities belong to the interrupt and shell/console tasks.

## Input and output

- `keyboard_has_data() -> u8` reads controller status port `0x64` and returns
  bit 0 (`1` when port `0x60` has a byte).
- `keyboard_read_scancode() -> u8` reads one byte from data port `0x60`.
- `keyboard_poll() -> u8` combines the two calls and returns an ASCII byte, or
  `0` when no byte is ready or the scancode has no ASCII representation.
- `keyboard_handle_scancode(scancode: u8) -> u8` translates one set-1 byte and
  is the preferred entry point for an IRQ dispatcher or deterministic test.

Return bytes are ASCII: letters (`a`–`z`, or `A`–`Z` with Shift), number-row
digits (`0`–`9`, or `!@#$%^&*()` with Shift), space, newline for Enter, and
backspace for Backspace.  Unsupported keys, key releases, and modifiers return
`0`.

## Modifier lifecycle

`0x2a`/`0x36` set Shift; `0xaa`/`0xb6` clear Shift.  `keyboard_reset()` clears
the modifier state and should be called during kernel input initialization.
`keyboard_shift_active() -> u8` exposes the state for diagnostics/tests.

## Integration obligations

The interrupt agent should call `keyboard_handle_scancode()` for IRQ1 after
reading port `0x60`, then pass a non-zero byte to the shell's
`shell_feed_char(u8)` contract.  The shell owns echoing and command buffering;
this driver intentionally does not call `console_putc()`.
