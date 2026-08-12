#!/usr/bin/env bash
set -euo pipefail

# This is intentionally independent of the OS Makefile.  It checks the
# console/serial/I/O slice while the boot and linker agents are still working
# on their branches.

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
zc_bin=${ZC:-/home/paulboul/zenc/zc}
cross_prefix=${CROSS_PREFIX:-/home/paulboul/osdev/opt/cross/bin/i686-elf-}
host_cc=${HOST_CC:-gcc}

if [[ ! -x "$zc_bin" ]]; then
    echo "console smoke: zc compiler not found: $zc_bin" >&2
    exit 2
fi

if [[ -x "${cross_prefix}gcc" ]]; then
    cc_bin="${cross_prefix}gcc"
else
    cc_bin=${CC:-gcc}
fi

command -v "$host_cc" >/dev/null || {
    echo "console smoke: host compiler not found: $host_cc" >&2
    exit 2
}

tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/zos-console-smoke.XXXXXX")
trap 'rm -rf "$tmp_dir"' EXIT

sources=(
    "$repo_root/arch/i686/io.zc"
    "$repo_root/kernel/console.zc"
    "$repo_root/kernel/serial.zc"
)

for source in "${sources[@]}"; do
    stem=$(basename "$source" .zc)
    generated="$tmp_dir/$stem.c"
    echo "console smoke: transpile $source"
    "$zc_bin" transpile --freestanding "$source" -o "$generated"
    # The freestanding preamble currently leaves these linkage macros for the
    # OS Makefile.  Defining them here makes this syntax check self-contained.
    "$cc_bin" -std=gnu11 -ffreestanding -fsyntax-only \
        -DZC_FUNC= -DZC_GLOBAL= "$generated"
done

grep -q 'console_putc' "$tmp_dir/console.c"
grep -q 'console_write' "$tmp_dir/console.c"
grep -q 'console_clear' "$tmp_dir/console.c"
grep -q 'volatile uint16_t' "$tmp_dir/console.c"
grep -q 'CONSOLE_CRTC_INDEX_PORT' "$tmp_dir/console.c"
grep -q 'CONSOLE_CRTC_DATA_PORT' "$tmp_dir/console.c"
grep -q 'CONSOLE_CURSOR_LOW' "$tmp_dir/console.c"
grep -q 'CONSOLE_CURSOR_HIGH' "$tmp_dir/console.c"
grep -q '_console_set_cursor' "$tmp_dir/console.c"
grep -q '_console_scroll' "$tmp_dir/console.c"
grep -q '_zos_vga_scroll_up' "$tmp_dir/console.c"
grep -q 'uint32_t position' "$tmp_dir/console.c"
grep -q '_console_row' "$tmp_dir/console.c"
grep -q 'position & 255' "$tmp_dir/console.c"
grep -q 'position >> 8' "$tmp_dir/console.c"
test "$(grep -c '_console_set_cursor();' "$tmp_dir/console.c")" -ge 2
grep -q 'serial_putc' "$tmp_dir/serial.c"
grep -q 'serial_write' "$tmp_dir/serial.c"
grep -q 'outb' "$tmp_dir/io.c"
grep -q 'inb' "$tmp_dir/io.c"

# Run the generated console against an in-memory VGA buffer. This verifies
# wrapping at column 80, scrolling at row 25, and Backspace across a wrapped
# line without executing privileged I/O instructions on the host.
"$host_cc" -std=gnu11 -Wall -Wextra -DZC_FUNC= -DZC_GLOBAL= \
    -DZOS_VGA_TEST "$tmp_dir/console.c" -x c -o "$tmp_dir/console-harness" - <<'EOF'
#include <assert.h>
#include <stdint.h>

extern void console_clear(void);
extern void console_init(void);
extern void console_putc(uint8_t ch);

uint16_t _zos_vga_test_text[2000];

static uint8_t selected_crtc_register;
static uint16_t cursor_position;

void io_outb(uint16_t port, uint8_t value) {
    if (port == 0x3D4) {
        selected_crtc_register = value;
        return;
    }
    if (port != 0x3D5) {
        return;
    }
    if (selected_crtc_register == 0x0F) {
        cursor_position = (uint16_t)((cursor_position & 0xFF00U) | value);
    } else if (selected_crtc_register == 0x0E) {
        cursor_position = (uint16_t)((cursor_position & 0x00FFU) |
                                     ((uint16_t)value << 8));
    }
}

static uint8_t cell_char(uint32_t index) {
    return (uint8_t)(_zos_vga_test_text[index] & 0xFFU);
}

int main(void) {
    uint32_t row;
    uint32_t column;

    console_init();
    for (column = 0; column < 80; ++column) {
        console_putc((uint8_t)'A');
    }
    assert(cursor_position == 80);
    assert(cell_char(0) == (uint8_t)'A');
    assert(cell_char(79) == (uint8_t)'A');

    console_putc((uint8_t)'\b');
    assert(cursor_position == 79);
    assert(cell_char(79) == (uint8_t)' ');

    console_clear();
    for (row = 0; row < 25; ++row) {
        for (column = 0; column < 80; ++column) {
            console_putc((uint8_t)('A' + row));
        }
    }

    assert(cursor_position == 1920);
    assert(cell_char(0) == (uint8_t)'B');
    assert(cell_char(23 * 80) == (uint8_t)'Y');
    assert(cell_char(24 * 80) == (uint8_t)' ');

    console_putc((uint8_t)'Z');
    assert(cursor_position == 1921);
    assert(cell_char(24 * 80) == (uint8_t)'Z');
    return 0;
}
EOF

"$tmp_dir/console-harness"

echo "console smoke: PASS (freestanding transpile + C syntax + API/MMIO checks)"
