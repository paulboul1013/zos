#!/bin/sh
set -eu

file=${1:-kernel/keyboard.zc}

test -f "$file"
grep -q 'KEYBOARD_DATA_PORT: u16 = 0x60' "$file"
grep -q 'KEYBOARD_STATUS_PORT: u16 = 0x64' "$file"
grep -q 'fn keyboard_handle_scancode(scancode: u8) -> u8' "$file"
grep -q 'fn keyboard_poll() -> u8' "$file"
grep -q 'KEYBOARD_LEFT_SHIFT_BREAK' "$file"
grep -q "return (u8)'a'" "$file"
grep -q "return (u8)'1'" "$file"
grep -q "return (u8)' '" "$file"
grep -q 'KEY_EVENT_ENTER' "$file"
grep -q 'KEY_EVENT_BACKSPACE' "$file"
grep -q 'io_inb(KEYBOARD_STATUS_PORT)' "$file"
grep -q 'io_inb(KEYBOARD_DATA_PORT)' "$file"

# Keep this slice independent from the files owned by interrupt/console/shell
# agents; integration is performed by the root agent at a later checkpoint.
! grep -Eq 'kernel/(interrupts|console|kernel)\.zc|arch/i686/io\.zc' "$file"

echo "keyboard static checks passed"
