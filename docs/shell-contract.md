# ZOS shell contract

Task 10 provides the keyboard-to-command boundary for the i686 MVP. The
keyboard IRQ translates set-1 scancodes and queues non-zero ASCII bytes. A
long-lived Ring 0 shell task consumes the queue and forwards each byte to
`shell_feed_char` outside interrupt context. The shell keeps only the `clear`
command; informational commands are intentionally omitted.

## Public API

```c
void shell_init(void);
void shell_feed_char(uint8_t ch);
void shell_task(void);
```

`shell_init` clears the fixed command buffer and writes the `zos> ` prompt.
`shell_feed_char` accepts printable ASCII, newline/CR, and backspace:

- Printable bytes are echoed and appended up to 4095 bytes. The VGA console
  wraps at column 80 and scrolls upward after the final row.
- Backspace removes one byte and emits a console backspace.
- Enter executes the current command, resets the buffer, and writes a prompt.
- Bytes outside this set are ignored.

The command buffer is intentionally fixed at 4096 bytes and does not allocate
or call hosted C library code. `shell_task` initializes this state, drains the
keyboard queue in FIFO order, and calls `task_yield` whenever the queue is
empty.

## Commands

| Command | Behavior |
| --- | --- |
| `clear` | Calls `console_clear`, then returns to the prompt. |
| anything else | Prints `unknown command`. |

`help`, `about`, and `ticks` are not built-in commands. They are treated as
unknown commands and print `unknown command`.

## Integration order

1. `kernel/kernel.zc` creates `shell_task` after keyboard and task
   initialization.
2. IRQ1 translates and queues keyboard input without calling shell or console
   code.
3. `shell_task` calls `shell_init()` once, drains `keyboard_queue_pop()`, and
   forwards non-zero bytes to `shell_feed_char()`.
4. When no byte is available, `shell_task` yields so the boot task can halt
   until the next interrupt.
