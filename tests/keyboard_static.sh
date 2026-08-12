#!/bin/sh
set -eu

file=${1:-kernel/keyboard.zc}

test -f "$file"
grep -q 'KEYBOARD_DATA_PORT: u16 = (u16)0x60' "$file"
grep -q 'PIC_MASTER_DATA_PORT: u16 = (u16)0x21' "$file"
grep -q 'PIC_MASTER_COMMAND_PORT: u16 = (u16)0x20' "$file"
grep -q 'PIC_END_OF_INTERRUPT: u8 = (u8)0x20' "$file"
grep -q 'KEYBOARD_IRQ_MASK: u8 = (u8)0x02' "$file"
grep -q 'fn keyboard_init()' "$file"
grep -q 'fn keyboard_handle_irq()' "$file"
grep -q 'fn keyboard_handle_scancode(scancode: u8) -> u8' "$file"
grep -q 'KEYBOARD_LEFT_SHIFT_BREAK' "$file"
grep -q '"qwertyuiop"' "$file"
grep -q '"asdfghjkl"' "$file"
grep -q '"zxcvbnm"' "$file"
grep -q '"1234567890"' "$file"
grep -Fq '"!@#$%^&*()"' "$file"
grep -q "return (u8)' '" "$file"
grep -q 'KEY_EVENT_ENTER' "$file"
grep -q 'KEY_EVENT_BACKSPACE' "$file"
grep -q 'io_inb(KEYBOARD_DATA_PORT)' "$file"
grep -q 'io_inb(PIC_MASTER_DATA_PORT)' "$file"
grep -q 'io_outb(PIC_MASTER_DATA_PORT' "$file"
grep -q 'io_outb(PIC_MASTER_COMMAND_PORT, PIC_END_OF_INTERRUPT)' "$file"
grep -q 'master_mask & ~KEYBOARD_IRQ_MASK' "$file"
grep -q 'fn keyboard_queue_pop() -> u8' "$file"
! grep -Eq 'keyboard_poll|keyboard_has_data|KEYBOARD_STATUS_PORT|_keyboard_shifted_number' "$file"

# Keep the keyboard module independent from interrupt/console/shell source
# files; integration behavior is covered by shell_task_static.sh.
! grep -Eq 'kernel/(interrupts|console|kernel)\.zc|arch/i686/io\.zc' "$file"

echo "keyboard static checks passed"
