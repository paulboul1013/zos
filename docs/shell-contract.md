# ZOS shell contract

Task 10 provides the keyboard-to-command boundary for the i686 MVP.  The
keyboard driver translates set-1 scancodes into ASCII bytes; the interrupt or
polling loop forwards each non-zero byte to `shell_feed_char`.

## Public API

```c
void shell_init(void);
void shell_feed_char(uint8_t ch);
```

`shell_init` clears the fixed command buffer and writes the `zos> ` prompt.
`shell_feed_char` accepts printable ASCII, newline/CR, and backspace:

- Printable bytes are echoed and appended up to 63 bytes.
- Backspace removes one byte and emits a console backspace.
- Enter executes the current command, resets the buffer, and writes a prompt.
- Bytes outside this set are ignored.

The command buffer is intentionally fixed at 64 bytes and does not allocate
or call hosted C library code.

## Commands

| Command | Behavior |
| --- | --- |
| `help` | Lists `help`, `clear`, `about`, and `ticks`. |
| `clear` | Calls `console_clear`, then returns to the prompt. |
| `about` | Prints the Zenc OS shell marker. |
| `ticks` | Prints `timer_ticks()` as an unsigned decimal value. |
| anything else | Prints `unknown command`. |

## Integration order

The root integrator should call the APIs in this order after console and timer
initialization:

1. `shell_init()` once after the VGA console is ready.
2. For each keyboard event, call `shell_feed_char(event)` when `event != 0`.
3. Keep the keyboard scancode translator independent of shell command policy.

`kernel/kernel.zc` owns this call sequence during integration; this slice does
not modify that file or the Makefile.
